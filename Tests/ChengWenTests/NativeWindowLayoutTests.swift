import AppKit
import SwiftUI
import WebKit
import Vision
import XCTest
@testable import ChengWen

private final class NativeListWorkGate:@unchecked Sendable {
    private let lock=NSLock()
    private var pending:[CheckedContinuation<Void,Never>]=[]
    private var started:[String]=[]
    private var released=false
    func wait(_ id:String,started signal:XCTestExpectation)async {
        await withCheckedContinuation{continuation in
            lock.lock();started.append(id);let ready=released
            if !ready{pending.append(continuation)}
            lock.unlock();signal.fulfill();if ready{continuation.resume()}
        }
    }
    func release(){lock.lock();released=true;let values=pending;pending=[];lock.unlock();values.forEach{$0.resume()}}
    var calls:[String]{lock.lock();defer{lock.unlock()};return started}
}

final class NativeWindowLayoutTests:XCTestCase {
    @MainActor private func nodes(_ root:Any)->[NSAccessibilityProtocol] {
        var visited=Set<ObjectIdentifier>()
        func visit(_ value:Any,depth:Int)->[NSAccessibilityProtocol] {
            guard depth<30,let node=value as? NSAccessibilityProtocol else{return []}
            let id=ObjectIdentifier(node as AnyObject)
            guard visited.insert(id).inserted else{return []}
            return [node]+(node.accessibilityChildren() ?? []).flatMap{visit($0,depth:depth+1)}
        }
        return visit(root,depth:0)
    }
    @MainActor private func views<T:NSView>(_ root:NSView,_ type:T.Type)->[T]{((root as? T).map{[$0]} ?? [])+root.subviews.flatMap{views($0,type)}}
    @MainActor private func settle(_ view:NSView)async{view.layoutSubtreeIfNeeded();try? await Task.sleep(nanoseconds:60_000_000);view.layoutSubtreeIfNeeded()}
    @MainActor private func eventually(_ condition:()->Bool,timeout:TimeInterval=5)async throws {
        let deadline=Date().addingTimeInterval(timeout)
        while !condition() && Date()<deadline{try await Task.sleep(nanoseconds:20_000_000)}
        XCTAssertTrue(condition(),"Owned native window did not reach the expected state")
    }
    private var evidence:URL {
        URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("维护记录/ChengWen/0.8.0-verification")
    }
    @discardableResult @MainActor private func snapshot(_ view:NSView,name:String)throws->NSBitmapImageRep {
        try FileManager.default.createDirectory(at:evidence,withIntermediateDirectories:true)
        let bitmap=try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in:view.bounds))
        view.cacheDisplay(in:view.bounds,to:bitmap)
        try XCTUnwrap(bitmap.representation(using:.png,properties:[:])).write(to:evidence.appendingPathComponent(name+".png"))
        return bitmap
    }
    @MainActor private func renderedTextRect(_ text:String,in bitmap:NSBitmapImageRep,view:NSView)throws->NSRect {
        let request=VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages=text.unicodeScalars.allSatisfy{$0.isASCII} ? ["en-US"]:["zh-Hans","en-US"]
        request.usesLanguageCorrection=false
        try VNImageRequestHandler(cgImage:try XCTUnwrap(bitmap.cgImage),options:[:]).perform([request])
        let matches=(request.results ?? []).filter{observation in
            observation.topCandidates(5).contains{$0.string.filter{!$0.isWhitespace}.localizedCaseInsensitiveContains(text)}
        }
        let match=try XCTUnwrap(matches.min{$0.boundingBox.minY<$1.boundingBox.minY},"Expected text was not recognized in the actual bitmap: \(text). Visible text: \((request.results ?? []).compactMap{$0.topCandidates(1).first?.string})")
        let box=match.boundingBox
        return NSRect(x:box.minX*view.bounds.width,y:(view.isFlipped ? 1-box.maxY:box.minY)*view.bounds.height,width:box.width*view.bounds.width,height:box.height*view.bounds.height)
    }
    @MainActor private func event(_ characters:String,code:UInt16,window:NSWindow)throws->NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:window.windowNumber,context:nil,characters:characters,charactersIgnoringModifiers:characters,isARepeat:false,keyCode:code))
    }
    @MainActor func testActualEnvironmentSheetReturnAndEscapeDismissAndBlockMainWindowNavigation()async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("chengwen-native-sheet-"+UUID().uuidString)
        let model=AppModel(storeURL:root,engine:BackendClient{_,_,_ in XCTFail("Sheet keyboard checks must not execute any engine requests");return [:]})
        model.settings.directory=root.appendingPathComponent("audio").path
        model.healthItems=[EnvironmentItem(["key":"engine","title":"Synthetic engine","state":"ready","required":true])]
        let window=NSWindow(contentRect:NSRect(x:0,y:0,width:1080,height:740),styleMask:[.titled,.closable],backing:.buffered,defer:false)
        window.isReleasedWhenClosed=false
        let host=NSHostingView(rootView:NativeRootView().environmentObject(model));window.contentView=host
        defer{model.showEnvironment=false;window.makeFirstResponder(nil);window.contentView=nil;window.close();model.shutdown();try? FileManager.default.removeItem(at:root)}
        window.orderBack(nil);await settle(host)
        let owner=ApplicationDelegate();owner.window=window;owner.model=model
        let menu=owner.buildMenu(),navigation=try XCTUnwrap(menu.items.compactMap(\.submenu).first{$0.title=="显示"}?.items.first{$0.keyEquivalent=="2"})
        for (characters,code) in [("\r",UInt16(36)),("\u{1b}",UInt16(53))] {
            model.showEnvironment=true
            try await eventually{window.attachedSheet != nil}
            let sheet=try XCTUnwrap(window.attachedSheet)
            XCTAssertFalse(owner.validateMenuItem(navigation))
            XCTAssertTrue(sheet.performKeyEquivalent(with:try event(characters,code:code,window:sheet)))
            try await eventually{!model.showEnvironment && window.attachedSheet==nil}
            XCTAssertTrue(owner.validateMenuItem(navigation))
        }
    }
    @MainActor func testAccountDefaultReturnAttemptsOnceAndEscapeClosesOwnedWindowWithoutSessions()async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("chengwen-account-keys-"+UUID().uuidString)
        var reads=0,closed=0
        let model=NativeAccountViewModel(platform:"netease",storeURL:root,request:{_,_,_,_ in XCTFail("A failed synthetic login cannot activate a session");return {}},vault:MemoryAccountVault(),autoLoadWeb:false,ownedSessionReader:{completion in
            reads+=1;completion(.failure(NativeAccountProblem(reason:"合成未登录状态。",solution:"请完成登录。")))
        },onChange:{})
        let window=NSWindow(contentRect:NSRect(x:0,y:0,width:800,height:660),styleMask:[.titled,.closable],backing:.buffered,defer:false)
        window.isReleasedWhenClosed=false
        let host=NSHostingView(rootView:NativeAccountConnectionView(model:model));window.contentView=host
        model.requestClose={[weak model,weak window] in closed+=1;model?.close();window?.close()}
        defer{model.requestClose=nil;model.close();window.contentView=nil;window.close();try? FileManager.default.removeItem(at:root)}
        window.orderBack(nil);await settle(host)
        XCTAssertTrue(window.performKeyEquivalent(with:try event("\r",code:36,window:window)))
        try await eventually{reads==1 && !model.isBusy}
        XCTAssertFalse(model.reason.isEmpty)
        XCTAssertTrue(window.performKeyEquivalent(with:try event("\u{1b}",code:53,window:window)))
        XCTAssertEqual(closed,1);XCTAssertFalse(window.isVisible)
    }
    @MainActor func testScrolledDownloadListPaintsRemainingOneToFourJobsAfterFilteringAndClearing()async throws {
        let names=["Alpha","Bravo","Charlie","Delta"]
        for remaining in 1...4 {
            let root=FileManager.default.temporaryDirectory.appendingPathComponent("chengwen-download-viewport-"+UUID().uuidString)
            let gate=NativeListWorkGate(),started=expectation(description:"Controlled native work stays active")
            started.expectedFulfillmentCount=remaining
            let model=AppModel(storeURL:root,engine:BackendClient{operation,payload,_ in
                XCTAssertEqual(operation,"download")
                let id=(payload["track"] as! [String:Any])["id"] as! String
                await gate.wait(id,started:started)
                return ["path":root.appendingPathComponent("synthetic-model-only-\(id).mp3").path]
            })
            model.settings.directory=root.appendingPathComponent("audio").path;model.settings.concurrency=4
            for index in 0..<remaining {
                model.downloadTrack(AudioTrack(raw:["id":"keep-\(index)","title":"Visible keeper \(names[index])","artist":"Synthetic","source":"qq","url":"https://example.invalid/catalog-only"]))
            }
            await fulfillment(of:[started],timeout:3)
            for index in 0..<20 {
                var finished=DownloadJob(track:AudioTrack(raw:["id":"old-\(index)","title":"Old completed row \(index)","artist":"Synthetic","source":"qq"]),format:"mp3",directory:root.path,lyrics:false)
                finished.state="completed";finished.detail="Synthetic completed history";model.jobs.append(finished)
            }
            model.notice="";model.page = .downloads
            let window=NSWindow(contentRect:NSRect(x:0,y:0,width:1080,height:740),styleMask:[.titled,.closable],backing:.buffered,defer:false)
            window.isReleasedWhenClosed=false
            let host=NSHostingView(rootView:NativeRootView().environmentObject(model));window.contentView=host
            defer{gate.release();model.shutdown();window.contentView=nil;window.close();try? FileManager.default.removeItem(at:root)}
            window.orderBack(nil);await settle(host)
            let table=try XCTUnwrap(views(host,NSTableView.self).max{$0.numberOfRows<$1.numberOfRows})
            XCTAssertEqual(table.numberOfRows,20+remaining)
            let scroll=try XCTUnwrap(table.enclosingScrollView)
            table.scrollRowToVisible(table.numberOfRows-1);await settle(host)
            XCTAssertGreaterThan(scroll.contentView.bounds.minY,0)
            let activeFilter=try XCTUnwrap(views(host,NSButton.self).first{$0.accessibilityIdentifier()=="download-filter-active"})
            activeFilter.performClick(nil);await settle(host)
            try await eventually{table.numberOfRows==remaining}
            XCTAssertGreaterThan(table.rows(in:table.visibleRect).length,0)
            let activeBitmap=try snapshot(host,name:"download-filter-visible-\(remaining)")
            _=try renderedTextRect("Visiblekeeper\(names[0])",in:activeBitmap,view:host)
            let allFilter=try XCTUnwrap(views(host,NSButton.self).first{$0.accessibilityIdentifier()=="download-filter-all"})
            allFilter.performClick(nil);await settle(host)
            table.scrollRowToVisible(table.numberOfRows-1);await settle(host)
            model.clearFinishedJobs();await settle(host)
            try await eventually{table.numberOfRows==remaining}
            XCTAssertGreaterThan(table.rows(in:table.visibleRect).length,0)
            let bitmap=try snapshot(host,name:"download-cleared-visible-\(remaining)")
            for index in 0..<remaining{_=try renderedTextRect("Visiblekeeper\(names[index])",in:bitmap,view:host)}
            XCTAssertEqual(model.activeJobCount,remaining)
            XCTAssertEqual(gate.calls.count,remaining,"Filtering/clearing must not restart or cancel native work")
            gate.release();try await eventually{model.completedJobCount==remaining}
            XCTAssertEqual(gate.calls.count,remaining)
        }
    }
    @MainActor func testActualOwnedWebAccountViewFitsSmallWindowWithLongActivationErrorAndVisibleFooter()async throws {
        var records:[[String:Any]]=[]
        for size in [NSSize(width:800,height:660),NSSize(width:900,height:700)] {
            let root=FileManager.default.temporaryDirectory.appendingPathComponent("chengwen-account-window-"+UUID().uuidString)
            let activated=expectation(description:"Synthetic session activation failed locally")
            let model=NativeAccountViewModel(platform:"netease",storeURL:root,request:{operation,payload,_,completion in
                XCTAssertEqual(operation,"activate_account");XCTAssertNil(payload["cookies"])
                completion(.failure(EngineFailure(reason:String(repeating:"合成账号连接说明：请完成平台验证后重试。",count:40),solution:"此测试仅使用本地网页、内存会话与合成响应。",code:"account_risk")))
                activated.fulfill();return {}
            },vault:MemoryAccountVault(),autoLoadWeb:false,onChange:{})
            let web=try XCTUnwrap(model.webView)
            let window=NSWindow(contentRect:NSRect(origin:.zero,size:NSSize(width:1000,height:740)),styleMask:[.titled,.closable,.resizable,.fullSizeContentView],backing:.buffered,defer:false)
            window.isReleasedWhenClosed=false;window.titleVisibility = .hidden;window.titlebarAppearsTransparent=true
            window.contentMinSize=NSSize(width:800,height:660)
            let host=NSHostingView(rootView:NativeAccountConnectionView(model:model));window.contentView=host
            defer {
                model.close();window.makeFirstResponder(nil);window.contentView=nil;window.close()
                try? FileManager.default.removeItem(at:root)
            }
            // Local HTML only. Override fetch inside this owned non-persistent
            // page, so production JS verification never contacts the platform.
            web.loadHTMLString("""
            <html><body>Local synthetic account layout
            <script>window.fetch=async()=>({json:async()=>({code:200,account:{id:123},profile:{userId:123,nickname:'Synthetic UI account'}})});</script>
            </body></html>
            """,baseURL:URL(string:"https://music.163.com/"))
            window.orderBack(nil)
            try await eventually{!web.isLoading}
            let origin=try await web.evaluateJavaScript("location.origin") as? String
            XCTAssertEqual(origin,"https://music.163.com")
            let cookie=try XCTUnwrap(HTTPCookie(properties:[.name:"MUSIC_U",.value:"synthetic-native-ui-only",.domain:".music.163.com",.path:"/",.secure:"TRUE"]))
            await withCheckedContinuation{continuation in web.configuration.websiteDataStore.httpCookieStore.setCookie(cookie){continuation.resume()}}
            model.connectOwnedWebSession()
            await fulfillment(of:[activated],timeout:5)
            try await eventually{!model.isBusy && !model.reason.isEmpty}
            window.setContentSize(size);await settle(host)
            XCTAssertEqual(host.bounds.width,size.width,accuracy:1)
            XCTAssertEqual(host.bounds.height,size.height,accuracy:1,"Hosting must not expand the real window to its ideal content height")
            let bitmap=try snapshot(host,name:"account-native-layout-\(Int(size.width))x\(Int(size.height))")
            // SwiftUI does not expose its virtual AX children in a standalone
            // XCTest host. Inspect the actual rendered text rather than invent
            // button coordinates or changing the product for a test query.
            let footerRect=try renderedTextRect("完成登录并连接",in:bitmap,view:host)
            let webRect=web.convert(web.bounds,to:host)
            records.append(["requested":NSStringFromSize(size),"actualHost":NSStringFromRect(host.bounds),"actualWindow":NSStringFromRect(window.frame),"web":NSStringFromRect(webRect),"footer":NSStringFromRect(footerRect)])
            XCTAssertGreaterThan(webRect.height,200)
            XCTAssertGreaterThan(footerRect.width,40);XCTAssertGreaterThan(footerRect.height,8)
            XCTAssertTrue(host.bounds.insetBy(dx:-1,dy:-1).contains(footerRect),"Footer action must remain inside the requested real host")
            XCTAssertGreaterThan(footerRect.minY,webRect.maxY,"The matched action must be below the web area, not the introductory sentence that mentions the button")
        }
        try FileManager.default.createDirectory(at:evidence,withIntermediateDirectories:true)
        try JSONSerialization.data(withJSONObject:records,options:[.prettyPrinted,.sortedKeys]).write(to:evidence.appendingPathComponent("account-native-layout.json"))
    }
}
