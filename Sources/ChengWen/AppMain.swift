import AppKit
import SwiftUI

@main struct ChengWenApplication {
    static func main() {
        if CommandLine.arguments.contains("--source-check") { NativeSourceCheck.start() }
        let app=NSApplication.shared
        let delegate=ApplicationDelegate()
        app.delegate=delegate;app.setActivationPolicy(.regular)
        withExtendedLifetime(delegate){app.run()}
    }
}
@MainActor final class ApplicationDelegate:NSObject,NSApplicationDelegate,NSMenuItemValidation {
    var window:NSWindow!
    var model:AppModel!
    var temporaryRoot:URL?
    private var terminating=false
    func applicationDidFinishLaunching(_ notification:Notification) {
        let testing=CommandLine.arguments.contains("--native-smoke") || CommandLine.arguments.contains("--ui-preview")
        if testing {
            temporaryRoot=FileManager.default.temporaryDirectory.appendingPathComponent("chengwen-native-qa-"+UUID().uuidString)
        }
        model=AppModel(storeURL:temporaryRoot ?? AppFiles.root())
        window=NSWindow(contentRect:NSRect(x:0,y:0,width:1220,height:820),styleMask:[.titled,.closable,.miniaturizable,.resizable,.fullSizeContentView],backing:.buffered,defer:false)
        window.title="澄闻";window.titleVisibility = .hidden;window.titlebarAppearsTransparent=true
        window.titlebarSeparatorStyle = .none
        window.backgroundColor = .windowBackgroundColor
        window.isReleasedWhenClosed=false
        window.isMovableByWindowBackground=true;window.tabbingMode = .disallowed
        window.minSize=NSSize(width:1080,height:740);window.setFrame(NSRect(x:180,y:140,width:1220,height:820),display:false)
        if testing && CommandLine.arguments.contains("--compact-preview") {window.setFrame(NSRect(x:180,y:140,width:1080,height:740),display:false)}
        // Production follows the user's system appearance. Overrides exist
        // only for isolated source previews, never ordinary launches.
        if testing,let index=CommandLine.arguments.firstIndex(of:"--appearance"),CommandLine.arguments.count>index+1 {
            switch CommandLine.arguments[index+1] {
            case "light":window.appearance=NSAppearance(named:.aqua)
            case "dark":window.appearance=NSAppearance(named:.darkAqua)
            default:break
            }
        }
        let host=NSHostingView(rootView:NativeRootView().environmentObject(model))
        window.contentView=host
        makeMenu();window.center()
        if !(testing && CommandLine.arguments.contains("--hidden-preview")) {window.makeKeyAndOrderFront(nil)}
        if !CommandLine.arguments.contains("--ui-preview") {model.start()}
        if CommandLine.arguments.contains("--ui-preview") {
            loadPreview()
        } else if CommandLine.arguments.contains("--native-smoke") {
            NativeSmoke.run(model:model,window:window){success in
                if let root=self.temporaryRoot {try? FileManager.default.removeItem(at:root)}
                fflush(stdout);exit(success ? 0 : 1)
            }
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender:NSApplication)->Bool {true}
    func applicationShouldTerminate(_ sender:NSApplication)->NSApplication.TerminateReply {
        guard !terminating else{return .terminateLater}
        terminating=true
        model?.shutdown()
        let cleanup=DispatchGroup()
        cleanup.enter();NativeAccounts.prepareForTermination {cleanup.leave()}
        if let engine=model?.engine {cleanup.enter();engine.shutdown {cleanup.leave()}}
        cleanup.notify(queue:.global(qos:.userInitiated)) {
            RunLoop.main.perform(inModes:[.common]) {sender.reply(toApplicationShouldTerminate:true)}
        }
        return .terminateLater
    }
    func applicationWillTerminate(_ notification:Notification){model?.shutdown();if let root=temporaryRoot{try? FileManager.default.removeItem(at:root)}}
    func applicationShouldHandleReopen(_ sender:NSApplication,hasVisibleWindows:Bool)->Bool {window?.makeKeyAndOrderFront(nil);return true}
    private func makeMenu() {
        let bar=buildMenu();NSApp.mainMenu=bar
        NSApp.windowsMenu=bar.items.last?.submenu
    }
    // Building a menu does not install it or disturb another window's responder
    // chain. In particular, Select All stays untargeted so text editors retain it.
    func buildMenu()->NSMenu {
        let bar=NSMenu()
        let appItem=NSMenuItem(title:"澄闻",action:nil,keyEquivalent:"");bar.addItem(appItem);let menu=NSMenu(title:"澄闻");appItem.submenu=menu
        menu.addItem(withTitle:"关于澄闻",action:#selector(about),keyEquivalent:"").target=self
        menu.addItem(.separator())
        menu.addItem(withTitle:"偏好设置…",action:#selector(preferences),keyEquivalent:",").target=self
        menu.addItem(.separator())
        menu.addItem(withTitle:"隐藏澄闻",action:#selector(NSApplication.hide(_:)),keyEquivalent:"h")
        let hideOthers=menu.addItem(withTitle:"隐藏其他",action:#selector(NSApplication.hideOtherApplications(_:)),keyEquivalent:"h")
        hideOthers.keyEquivalentModifierMask=[.command,.option]
        menu.addItem(withTitle:"显示全部",action:#selector(NSApplication.unhideAllApplications(_:)),keyEquivalent:"")
        menu.addItem(.separator())
        menu.addItem(withTitle:"退出澄闻",action:#selector(NSApplication.terminate(_:)),keyEquivalent:"q")
        let editItem=NSMenuItem(title:"编辑",action:nil,keyEquivalent:"");bar.addItem(editItem);let edit=NSMenu(title:"编辑");editItem.submenu=edit
        edit.addItem(withTitle:"撤销",action:Selector(("undo:")),keyEquivalent:"z")
        let redo=edit.addItem(withTitle:"重做",action:Selector(("redo:")),keyEquivalent:"z");redo.keyEquivalentModifierMask=[.command,.shift]
        edit.addItem(.separator())
        for (title,action,key) in [("剪切",#selector(NSText.cut(_:)),"x"),("复制",#selector(NSText.copy(_:)),"c"),("粘贴",#selector(NSText.paste(_:)),"v"),("全选",#selector(NSText.selectAll(_:)),"a")] {edit.addItem(withTitle:title,action:action,keyEquivalent:key)}
        edit.addItem(.separator())
        edit.addItem(withTitle:"搜索音乐…",action:#selector(focusSearch),keyEquivalent:"f").target=self
        let viewItem=NSMenuItem(title:"显示",action:nil,keyEquivalent:"");bar.addItem(viewItem);let view=NSMenu(title:"显示");viewItem.submenu=view
        view.addItem(withTitle:"搜索音乐",action:#selector(showSearch),keyEquivalent:"1").target=self
        view.addItem(withTitle:"下载管理",action:#selector(showDownloads),keyEquivalent:"2").target=self
        let windowItem=NSMenuItem(title:"窗口",action:nil,keyEquivalent:"");bar.addItem(windowItem);let windows=NSMenu(title:"窗口");windowItem.submenu=windows
        windows.addItem(withTitle:"最小化",action:#selector(NSWindow.performMiniaturize(_:)),keyEquivalent:"m")
        windows.addItem(withTitle:"缩放",action:#selector(NSWindow.performZoom(_:)),keyEquivalent:"")
        windows.addItem(.separator())
        windows.addItem(withTitle:"全部移到前面",action:#selector(NSApplication.arrangeInFront(_:)),keyEquivalent:"")
        return bar
    }
    func validateMenuItem(_ menuItem:NSMenuItem)->Bool {
        guard let action=menuItem.action else{return false}
        if [#selector(preferences),#selector(focusSearch),#selector(showSearch),#selector(showDownloads)].contains(action) {
            return window != nil && window.attachedSheet == nil
        }
        return true
    }
    @objc private func preferences(){guard let window=window,window.attachedSheet==nil else{return};model.page = .preferences;window.makeKeyAndOrderFront(nil)}
    @objc private func showSearch(){guard let window=window,window.attachedSheet==nil else{return};model.page = .search;window.makeKeyAndOrderFront(nil)}
    @objc private func showDownloads(){guard let window=window,window.attachedSheet==nil else{return};model.page = .downloads;window.makeKeyAndOrderFront(nil)}
    @objc private func focusSearch(){
        guard let window=window,window.attachedSheet==nil else{return}
        showSearch()
        focusSearchField(attempts:3)
    }
    private func focusSearchField(attempts:Int){
        DispatchQueue.main.asyncAfter(deadline:.now()+0.05){[weak self] in
            guard let self=self,let window=self.window,window.attachedSheet==nil,self.model.page == .search else{return}
            func searchField(in view:NSView)->NSSearchField? {
                if let field=view as? NSSearchField{return field}
                return view.subviews.lazy.compactMap{searchField(in:$0)}.first
            }
            if let view=window.contentView,let field=searchField(in:view) {
                window.makeFirstResponder(field)
                field.currentEditor()?.selectAll(nil)
            }else if attempts>1 {self.focusSearchField(attempts:attempts-1)}
        }
    }
    @objc private func about(){NSApp.orderFrontStandardAboutPanel(options:[.applicationName:"澄闻",.applicationVersion:AppVersion.current,.credits:NSAttributedString(string:"澄闻 · 音乐下载与收藏\n把喜欢的声音，留给自己。\nMIT License\nSwiftUI / AppKit · 原生音乐引擎\nTabler Icons · 第三方许可随应用提供")])}
    private func loadPreview() {
        func argument(_ key:String)->String? {
            guard let index=CommandLine.arguments.firstIndex(of:key),CommandLine.arguments.count>index+1 else{return nil}
            return CommandLine.arguments[index+1]
        }
        model.settings.directory="~/Music/澄闻"
        if CommandLine.arguments.contains("--preview-connected-account") {
            model.settings.useConnectedAccounts = true
            model.accounts["netease"] = AccountInfo(nickname: "界面测试账号 · Synthetic", verified: true, method: "synthetic-preview", blocked: false, connected: true)
        }
        model.keyword="钢琴 / 环境音乐";model.settings.recent=["钢琴练习","雨声 / 自然采样","Blue Hours"]
        model.tracks=[AudioTrack(raw:["id":"preview1","title":"钢琴练习 No.01","artist":"陈一禾","album":"独处的时间","source":"netease","duration":"3:42","ext":"mp3","url":"https://example.invalid/preview"]),AudioTrack(raw:["id":"preview2","title":"雨声与远处的风","artist":"Field Notes","album":"自然采样","source":"kuwo","duration":"0:18","ext":"m4a","url":"https://example.invalid/preview"])]
        model.searchStatus="搜索完成 · 2 首"
        model.isCheckingEnvironment=false
        let missing=argument("--health-state")=="missing"
        model.healthItems=[
            EnvironmentItem(["key":"engine","title":"Swift 原生音乐引擎","state":"ready","version":AppVersion.current,"detail":"音乐下载与解析能力已就绪。","required":true]),
            EnvironmentItem(["key":"ffmpeg","title":"FFmpeg","state":missing ? "missing":"ready","version":missing ? "":"8.0","path":missing ? "":"/opt/homebrew/bin/ffmpeg","detail":missing ? "尚未找到可运行的 FFmpeg，请按下方说明安装。":"工具可以实际运行。","required":true]),
            EnvironmentItem(["key":"ffprobe","title":"FFprobe","state":missing ? "missing":"ready","version":missing ? "":"8.0","path":missing ? "":"/opt/homebrew/bin/ffprobe","detail":missing ? "尚未找到与 FFmpeg 配套的 FFprobe。":"工具可以实际运行。","required":true]),
        ]
        if ["populated", "downloads"].contains(argument("--preview-data") ?? "") {
            model.selection=["preview1"]
            model.probes["preview1"]=ProbeStatus(state:"passed",detail:"已读到音频数据；完整性以实际下载为准。")
            model.probes["preview2"]=ProbeStatus(state:"failed",detail:"当前版本只返回了 18 秒片段。",solution:"请更换完整版本或其他音源。")
            var completed=DownloadJob(track:model.tracks[0],format:"mp3",directory:"~/Music/澄闻",lyrics:true)
            completed.state="completed";completed.percent=100;completed.detail="已保存音频和歌词。";completed.created="2026-11-03T08:30:00Z"
            var failed=DownloadJob(track:model.tracks[1],format:"m4a",directory:"~/Music/澄闻",lyrics:true)
            failed.state="failed";failed.retryCount=2;failed.detail="当前来源返回的音频片段不完整。";failed.solution="请更换完整版本或其他音源。";failed.created="2026-11-03T09:30:00Z"
            var active=DownloadJob(track:AudioTrack(raw:["id":"preview3","title":"Blue Hours · 夜间散步","artist":"Field Notes","source":"kuwo","duration":"4:08"]),format:"mp3",directory:"~/Music/澄闻",lyrics:false)
            active.state="downloading";active.percent=64;active.detail="正在下载音频…";active.created="2026-11-03T10:30:00Z"
            model.jobs=[completed,failed,active]
            if argument("--preview-data") == "downloads" {
                for index in 0..<7 {
                    var sample = DownloadJob(track: AudioTrack(raw: ["id": "download-sample-\(index)", "title": "钢琴与雨声 · 收藏版本 \(index + 1)", "artist": "样例音乐人", "source": MusicSource.available[index % MusicSource.available.count].id]), format: index % 3 == 0 ? "m4a" : "mp3", directory: "~/Music/澄闻", lyrics: false)
                    sample.state = "completed"; sample.percent = 100; sample.detail = "已保存到本地"
                    model.jobs.insert(sample, at: 0)
                }
            }
        }
        if argument("--preview-data")=="sources" {
            model.tracks=MusicSource.available.enumerated().map { index,source in
                AudioTrack(raw:["id":"source-preview-\(index)","title":"钢琴练习 · 样例版本 \(index+1)","artist":"样例音乐人","album":"界面测试数据","source":source.id,"duration":"3:42","ext":"mp3"])
            }
            model.selection=Set(model.tracks.prefix(1).map(\.id))
            if let first=model.tracks.first {model.probes[first.id]=ProbeStatus(state:"passed",detail:"合成预览：仅模拟少量音频可试读，未验证整首下载。")}
            for source in MusicSource.available {model.sourceStates[source.id]="找到 1 首（界面样例）"}
            model.searchStatus="搜索完成 · \(model.tracks.count) 首（界面样例）"
        }
        if CommandLine.arguments.contains("--stress-preview") {
            model.keyword="夜晚的钢琴与雨声 / Piano and distant rain"
            model.settings.directory="~/Music/澄闻/独立音乐与环境采样/经过完整性校验的音频收藏"
            model.settings.recent=(1...8).map{"夜晚的钢琴与雨声 · 长搜索记录 \($0)"}
            model.tracks=(0..<50).map{index in
                AudioTrack(raw:["id":"stress-\(index)","title":"夜晚的钢琴与远处的雨声 · Long concert recording 第\(index+1)乐章",
                                "artist":"陈一禾 / Field Notes / 很长的合作艺术家名称","album":"独处的时间 · Environmental recordings and piano sessions",
                                "source":MusicSource.available[index % MusicSource.available.count].id,"duration":index % 5 == 0 ? "0:18":"4:38","ext":"mp3"])
            }
            model.selection=Set(model.tracks.prefix(2).map(\.id));model.probes=[:]
            model.searchStatus="搜索完成 · 50 首（长文案界面样例）"
            for index in model.jobs.indices where model.jobs[index].state == "failed" {
                model.jobs[index].detail="当前来源返回的音频片段不完整，尚未通过整首解码与时长检查。该条为界面长文案样例，不含真实账号或媒体数据。"
                model.jobs[index].solution="请确认本地音频工具已就绪，然后重试；仍失败时，换一个音源搜索歌曲的完整版本，并先测试少量音频是否可读。"
            }
        }
        if CommandLine.arguments.contains("--preview-toast") {model.notice="已加入下载队列，预下载测试为可选步骤。"}
        if let index=CommandLine.arguments.firstIndex(of:"--page"),CommandLine.arguments.count>index+1,let page=AppPage(rawValue:CommandLine.arguments[index+1]){model.page=page}
        var componentWindow:NSWindow?
        if let component=argument("--preview-component"),["environment-sheet","installation","source-status","account-connection"].contains(component) {
            let height:CGFloat=component=="account-connection" ? 700:component=="environment-sheet" ? 610:component=="source-status" ? 540:450
            let width:CGFloat=component=="account-connection" ? 900:component=="source-status" ? 420:650
            let preview=NSWindow(contentRect:NSRect(x:0,y:0,width:width,height:height),styleMask:.borderless,backing:.buffered,defer:false)
            preview.isReleasedWhenClosed=false;preview.appearance=window.appearance
            let content:AnyView
            if component=="account-connection" {
                // This owned preview never loads a platform or reads a session.
                let account=NativeAccountViewModel(platform:"netease",storeURL:model.storeURL,request:{_,_,_,completion in
                    completion(.failure(EngineFailure(reason:"界面样例未连接平台。",solution:"",code:"preview")));return {}
                },autoLoadWeb:false,onChange:{})
                account.webView?.loadHTMLString("<html><body style='font:14px -apple-system;text-align:center;padding-top:150px;color:#777'>官方网页登录区域 · 本地界面样例</body></html>",baseURL:URL(string:"https://music.163.com/"))
                content=AnyView(NativeAccountConnectionView(model:account).frame(width:width,height:height))
            }
            else if component=="environment-sheet" {content=AnyView(NativeEnvironmentSheet().environmentObject(model))}
            else if component=="source-status" {content=AnyView(NativeSourceStatusList().environmentObject(model).frame(width:width,height:height,alignment:.top).background(LibraryTheme.background))}
            else {content=AnyView(NativeDependencyGuide().padding(24).frame(width:650,height:height,alignment:.top).background(LibraryTheme.background).font(.system(size:13)).foregroundColor(LibraryTheme.ink))}
            preview.contentView=NSHostingView(rootView:content)
            componentWindow=preview
        }
        DispatchQueue.main.asyncAfter(deadline:.now()+1){
            if let index=CommandLine.arguments.firstIndex(of:"--screenshot"),CommandLine.arguments.count>index+1 {
                // Include this window's own frame and traffic-light controls;
                // rendering only the hosting view can hide titlebar defects.
                let view=componentWindow?.contentView ?? self.window.contentView?.superview ?? self.window.contentView!
                view.layoutSubtreeIfNeeded()
                if let bitmap=view.bitmapImageRepForCachingDisplay(in:view.bounds){view.cacheDisplay(in:view.bounds,to:bitmap);if let data=bitmap.representation(using:.png,properties:[:]){try? data.write(to:URL(fileURLWithPath:CommandLine.arguments[index+1]))}}
            }
            if CommandLine.arguments.contains("--exit-after-preview"){
                if CommandLine.arguments.contains("--close-after-preview") {
                    // A never-ordered hidden window is not counted by AppKit's
                    // last-window-close policy. Order behind other apps for
                    // this isolated QA path without taking keyboard focus.
                    if !self.window.isVisible {self.window.orderBack(nil)}
                    self.window.close()
                }
                else {NSApp.terminate(nil)}
            }
        }
    }
}
