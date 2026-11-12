import AppKit
import Combine
import Foundation

@MainActor final class AppModel: ObservableObject {
    @Published var page:AppPage = .search
    @Published var settings:AppSettings {didSet{if ready {if oldValue.useConnectedAccounts != settings.useConnectedAccounts {stopProbes();probes=[:]};saveSettings();pumpDownloads()}}}
    @Published var keyword=""
    @Published var tracks:[AudioTrack]=[]
    @Published var selection:Set<String>=[]
    @Published var probes:[String:ProbeStatus]=[:]
    @Published var searchStatus=""
    @Published var isSearching=false
    @Published var isProbing=false
    @Published var jobs:[DownloadJob]=[]
    @Published var sourceStates:[String:String]=[:]
    @Published var accounts:[String:AccountInfo]=[:]
    @Published var healthItems:[EnvironmentItem]=[]
    @Published var isCheckingEnvironment=false
    @Published var showEnvironment=false
    @Published var notice="" {didSet{scheduleNoticeDismissal()}}
    let storeURL:URL
    let engine:BackendClient
    private let historyStore:NativeHistoryStore
    private var ready=false
    private var searchTasks:[String:EngineTask]=[:]
    private var downloadTasks:[String:EngineTask]=[:]
    private var downloadAttempts:[String:UUID]=[:]
    private var probeTasks:[String:EngineTask]=[:]
    private var probeReferences:[String:[String:Any]]=[:]
    private var accountTasks:[String:EngineTask]=[:]
    private var accountRevisions:[String:String]=[:]
    private var pendingProbes:[AudioTrack]=[]
    private var searchGeneration=UUID()
    private var probeGeneration=UUID()
    private var resultGeneration=UUID()
    private var healthTask:EngineTask?
    private var healthGeneration=UUID()
    private var shuttingDown=false
    private let noticeDisplayNanoseconds:UInt64
    private var noticeDismissal:Task<Void,Never>?
    private var noticeGeneration=UUID()
    var allSelected:Bool {!tracks.isEmpty && tracks.allSatisfy{selection.contains($0.id)}}
    var partiallySelected:Bool {!selection.isEmpty && !allSelected}
    var selectedCount:Int {tracks.filter{selection.contains($0.id)}.count}
    var activeJobCount:Int {jobs.filter{$0.active}.count}
    var completedJobCount:Int {jobs.filter{$0.state=="completed"}.count}
    var jobsNewestFirst:ReversedCollection<[DownloadJob]> {jobs.reversed()}
    func sourceValidationSummary(_ source:String)->String {
        let values=tracks.filter{$0.source==source}.compactMap{probes[$0.id]}
        let anonymous=values.filter{$0.state=="verified" && $0.anonymous==true}.count
        let authenticated=values.filter{$0.state=="verified" && $0.anonymous==false}.count
        let readable=values.filter{["passed","available","ready"].contains($0.state)}.count
        return "当前结果：匿名整首已验证 \(anonymous) 首 · 登录整首已验证 \(authenticated) 首 · 仅可试读 \(readable) 首"
    }
    init(storeURL:URL=AppFiles.root(),engine:BackendClient=BackendClient(),noticeDisplayDuration:TimeInterval=3,historyStore:NativeHistoryStore?=nil) {
        self.storeURL=storeURL;self.engine=engine;self.historyStore=historyStore ?? NativeHistoryStore(root:storeURL)
        let seconds=noticeDisplayDuration.isFinite ? max(0.05,min(30,noticeDisplayDuration)) : 3
        noticeDisplayNanoseconds=UInt64(seconds*1_000_000_000)
        settings=AppSettings(AppFiles.read("settings.json",at:storeURL) as? [String:Any] ?? [:])
        let restored=self.historyStore.load()
        jobs=restored.jobs
        ready=true
        if let warning=restored.warning {notice=warning}
    }
    private func scheduleNoticeDismissal() {
        noticeGeneration=UUID();noticeDismissal?.cancel();noticeDismissal=nil
        guard !notice.isEmpty,!shuttingDown else{return}
        let generation=noticeGeneration,delay=noticeDisplayNanoseconds
        noticeDismissal=Task{[weak self] in
            do{try await Task.sleep(nanoseconds:delay)}catch{return}
            guard let self=self,!Task.isCancelled,!self.shuttingDown,self.noticeGeneration==generation else{return}
            self.notice=""
        }
    }
    func start() { guard !shuttingDown else{return};refreshAccounts();loadEnvironment() }
    func saveSettings() {do{try AppFiles.write(settings.dictionary,name:"settings.json",at:storeURL)}catch{notice="设置暂未保存，请检查本机目录权限。"}}
    @discardableResult private func saveJobs(_ snapshot:[DownloadJob]?=nil)->Bool {
        do {try historyStore.save(snapshot ?? jobs);return true}
        catch NativeHistoryStore.Failure.oversized {
            notice="下载记录数量或体积超过保存上限，请减少任务或清理已结束记录后重试。音频文件不受影响。"
            return false
        }
        catch {
            notice=historyStore.writesBlocked ? "下载记录未能保存：原记录尚未安全备份。请检查目录权限后重新启动。" : "下载记录未能保存，请检查磁盘空间和目录权限。音频文件不受影响。"
            return false
        }
    }
    func searchRecent(_ value:String) {keyword=value;search()}
    func clearRecent() {settings.recent=[]}
    func toggleSource(_ id:String) {if settings.sources.contains(id){settings.sources.remove(id)}else{settings.sources.insert(id)}}
    func toggleTrack(_ id:String) {if selection.contains(id){selection.remove(id)}else{selection.insert(id)}}
    func toggleAll() {selection=allSelected ? [] : Set(tracks.map{$0.id})}
    func search() {
        guard !shuttingDown else{return}
        let text=String(keyword.trimmingCharacters(in:.whitespacesAndNewlines).prefix(100))
        guard !text.isEmpty else{searchStatus="请输入歌名或艺术家";return}
        guard !settings.sources.isEmpty else{searchStatus="请至少选择一个来源";return}
        stopSearch();stopProbes()
        resultGeneration=UUID()
        keyword=text;tracks=[];selection=[];probes=[:];sourceStates=[:]
        settings.recent=Array(([text]+settings.recent.filter{$0 != text}).prefix(8))
        isSearching=true;searchStatus="正在搜索…"
        let generation=UUID();searchGeneration=generation
        for source in MusicSource.available where settings.sources.contains(source.id) {
            sourceStates[source.id]="搜索中"
            let payload:[String:Any]=["source":source.id,"keyword":text,"limit":settings.limit,"include_restricted":accounts[source.id]?.connected == true]
            let task=engine.request("search",payload:payload,onEvent:{[weak self] event,data in
                guard let self=self,self.searchGeneration==generation,self.isSearching else{return}
                if event=="track" {
                    let track=AudioTrack(raw:data)
                    if !track.id.isEmpty && !self.tracks.contains(where:{$0.id==track.id}) {self.tracks.append(track)}
                    self.searchStatus="正在搜索 · \(self.tracks.count) 首"
                }
            }) {[weak self] result in
                guard let self=self,self.searchGeneration==generation else{return}
                self.searchTasks.removeValue(forKey:source.id)
                switch result {
                case .success(let data): self.sourceStates[source.id]="找到 \(data["count"] as? Int ?? 0) 首"
                case .failure(let error): self.sourceStates[source.id]=error.reason
                }
                if self.searchTasks.isEmpty {self.isSearching=false;self.searchStatus=self.tracks.isEmpty ? "没有找到结果，请换个关键词或来源" : "搜索完成 · \(self.tracks.count) 首"}
            }
            searchTasks[source.id]=task
            DispatchQueue.main.asyncAfter(deadline:.now()+Double(settings.timeout)) {[weak self,weak task] in
                guard let self=self,self.searchGeneration==generation,self.searchTasks[source.id] != nil else{return}
                task?.cancel()
            }
        }
    }
    func stopSearch() {
        let wasSearching=isSearching;searchGeneration=UUID()
        let tasks=searchTasks.values;searchTasks=[:];tasks.forEach{$0.cancel()};isSearching=false
        if wasSearching{searchStatus="已停止 · \(tracks.count) 首"}
    }
    private func authorized(_ track:AudioTrack)->[String:Any] {
        var raw=track.raw,metadata=raw["metadata"] as? [String:Any] ?? [:]
        for key in ["account_ref","use_account","cookie","cookies","authorization","token","music_u","sid"] {metadata.removeValue(forKey:key)}
        let platform=track.source
        if settings.useConnectedAccounts,NativeSessionStore.platforms.contains(platform),let record=(AppFiles.read("accounts.json",at:storeURL) as? [String:Any])?["accounts"] as? [String:[String:Any]],let revision=record[platform]?["revision"] as? String {
            metadata["account_ref"]=["platform":platform,"revision":revision,"store":storeURL.path]
        }
        raw["metadata"]=metadata;raw["cookies"]=[String:String]()
        var headers=raw["headers"] as? [String:String] ?? [:]
        for key in Array(headers.keys) where ["cookie","authorization","proxy-authorization"].contains(key.lowercased()){headers.removeValue(forKey:key)}
        raw["headers"]=headers
        return raw
    }
    func probeSelected() {beginProbes(tracks.filter{selection.contains($0.id)})}
    func probeTrack(_ track:AudioTrack) {beginProbes([track])}
    private func beginProbes(_ tracks:[AudioTrack]) {
        guard !shuttingDown,!isProbing,!tracks.isEmpty else{return}
        probeGeneration=UUID();pendingProbes=tracks;isProbing=true
        for track in tracks {probes[track.id]=ProbeStatus(state:"queued",detail:"等待测试")}
        pumpProbes()
    }
    private func pumpProbes() {
        guard !shuttingDown else{return}
        while probeTasks.count < 2 && !pendingProbes.isEmpty {
            let track=pendingProbes.removeFirst(),generation=probeGeneration,startedAt=Date()
            probes[track.id]=ProbeStatus(state:"checking",detail:"正在试读少量音频…")
            let requestTrack=AudioTrack(raw:authorized(track))
            let payload:[String:Any]=["track":requestTrack.raw,"save_lyrics":false]
            probeReferences[track.id]=accountReference(requestTrack)
            let task=engine.request("probe",payload:payload){[weak self] result in
                guard let self=self,self.probeGeneration==generation,self.probeTasks.removeValue(forKey:track.id) != nil else{return}
                self.probeReferences.removeValue(forKey:track.id)
                if case .failure(let error)=result {self.pauseAccountAfterFailure(error,track:requestTrack)}
                if let newer=self.probes[track.id],newer.state=="verified",newer.checkedAt>=startedAt {self.pumpProbes();return}
                switch result {
                case .success: self.probes[track.id]=ProbeStatus(state:"passed",detail:"已读到音频数据；完整性以实际下载为准。")
                case .failure(let error):self.probes[track.id]=ProbeStatus(state:["authentication","account_expired","account_risk","account_permission"].contains(error.code) ? "authentication" : "failed",detail:error.reason,solution:error.solution,technical:error.technical)
                }
                self.pumpProbes()
            }
            probeTasks[track.id]=task
            DispatchQueue.main.asyncAfter(deadline:.now()+Double(settings.timeout)){[weak self,weak task] in
                guard let self=self,self.probeGeneration==generation,self.probeTasks[track.id] != nil else{return};task?.cancel()
            }
        }
        isProbing = !pendingProbes.isEmpty || !probeTasks.isEmpty
    }
    private func stopProbes() {
        probeGeneration=UUID();let tasks=probeTasks.values;probeTasks=[:];probeReferences=[:];pendingProbes=[];tasks.forEach{$0.cancel()};isProbing=false
        for id in probes.keys.filter({["queued","checking"].contains(probes[$0]?.state ?? "")}) {probes.removeValue(forKey:id)}
    }
    func downloadSelected() {
        guard !shuttingDown else{return}
        let chosen=tracks.filter{selection.contains($0.id)}
        // Optional sample reads are advisory. A download resolves its own URL
        // and performs the normal account, media and filesystem checks.
        for track in chosen {enqueue(track)}
        pumpDownloads()
    }
    func downloadTrack(_ track:AudioTrack) {
        guard !shuttingDown else{return}
        enqueue(track);pumpDownloads()
    }
    private func enqueue(_ track:AudioTrack) {
        guard MusicSource.available.contains(where:{$0.id==track.source}) else{notice="此来源仅保留旧版记录，请选择当前支持的音源重新搜索。";return}
        guard !track.url.isEmpty else{switchSource(track);return}
        guard !jobs.contains(where:{$0.track.id==track.id && $0.active}) else{return}
        let track=AudioTrack(raw:authorized(track))
        jobs.append(DownloadJob(track:track,format:settings.format,directory:settings.directory,lyrics:settings.saveLyrics))
        if saveJobs() {notice="已加入下载队列"}
    }
    private func pumpDownloads() {
        guard !shuttingDown else{return}
        while downloadTasks.count < settings.concurrency,let index=jobs.firstIndex(where:{$0.state=="queued"}) {
            let job=jobs[index],id=job.id
            let attempt=UUID();downloadAttempts[id]=attempt
            let verificationGeneration=resultGeneration
            let accessRevision=((job.track.raw["metadata"] as? [String:Any])?["account_ref"] as? [String:Any])?["revision"] as? String
            jobs[index].state="downloading";jobs[index].detail="正在解析音频…"
            let payload:[String:Any]=["track":job.track.raw,"directory":job.directory,"format":job.format,"save_lyrics":job.lyrics]
            let task=engine.request("download",payload:payload,onEvent:{[weak self] event,data in
                guard let self=self,event=="progress",self.downloadAttempts[id]==attempt,self.downloadTasks[id] != nil,
                      let index=self.jobs.firstIndex(where:{$0.id==id}),self.jobs[index].active,self.jobs[index].state != "cancelling" else{return}
                let stage=data["stage"] as? String ?? "downloading"
                self.jobs[index].state=stage == "converting" ? "converting" : "downloading"
                let percent=data["percent"] as? Int ?? -1
                self.jobs[index].percent=percent<0 ? -1:min(100,percent)
                self.jobs[index].detail=data["detail"] as? String ?? "下载中"
            }) {[weak self] result in
                guard let self=self,self.downloadAttempts[id]==attempt else{return}
                self.downloadTasks.removeValue(forKey:id)
                self.downloadAttempts.removeValue(forKey:id)
                guard let index=self.jobs.firstIndex(where:{$0.id==id}) else{self.pumpDownloads();return}
                switch result {
                case .success(let data):
                    self.jobs[index].state="completed";self.jobs[index].percent=100;self.jobs[index].path=data["path"] as? String ?? ""
                    let warnings=(data["warnings"] as? [String] ?? []).filter{!$0.isEmpty}
                    self.jobs[index].detail=warnings.isEmpty ? "已保存到本地" : "已保存音频 · "+warnings.joined(separator:" ")
                    if !self.shuttingDown,data["full_verified"] as? Bool == true,self.resultGeneration==verificationGeneration,(accessRevision==nil || self.accountRevisions[job.track.source]==accessRevision),self.tracks.contains(where:{$0.id==job.track.id}) {
                        let anonymous=data["anonymous"] as? Bool
                        let detail=anonymous==true ? "此版本已在未登录状态下下载，并通过整段解码和完整性校验。" : anonymous==false ? "此版本已使用已连接账号下载，并通过整段解码和完整性校验；这不代表匿名可下载。" : "此版本已通过完整性校验；访问方式未记录，不能据此判断是否支持匿名下载。"
                        self.probes[job.track.id]=ProbeStatus(state:"verified",detail:detail,anonymous:anonymous)
                    }
                case .failure(let error):
                    self.jobs[index].state=error.code=="cancelled" || self.jobs[index].state=="cancelling" ? "cancelled" : "failed"
                    self.jobs[index].detail=error.reason;self.jobs[index].errorCode=error.code;self.jobs[index].solution=error.solution;self.jobs[index].technical=error.technical
                    if self.jobs[index].retryCount>0{self.jobs[index].solution += " 重试仍失败，请换其他来源或同名歌曲的其他版本。"}
                    self.pauseAccountAfterFailure(error,track:job.track)
                }
                self.saveJobs();self.pumpDownloads()
            }
            downloadTasks[id]=task
        }
    }
    func cancelJob(_ id:String) {
        guard let index=jobs.firstIndex(where:{$0.id==id}),jobs[index].active else{return}
        if let task=downloadTasks[id] {jobs[index].state="cancelling";task.cancel()}
        else {jobs[index].state="cancelled";jobs[index].detail="已取消";saveJobs()}
    }
    func retryJob(_ id:String) {
        guard !shuttingDown else{return}
        guard let index=jobs.firstIndex(where:{$0.id==id}),!jobs[index].active else{return}
        if jobs[index].track.url.isEmpty || !MusicSource.available.contains(where:{$0.id==jobs[index].track.source}) {switchSource(jobs[index].track);return}
        jobs[index].retryCount += 1;jobs[index].track=AudioTrack(raw:authorized(jobs[index].track))
        jobs[index].state="queued";jobs[index].percent=0;jobs[index].detail="等待重试";jobs[index].solution="";jobs[index].technical=""
        saveJobs();pumpDownloads()
    }
    func switchSource(_ track:AudioTrack) {
        guard !shuttingDown else{return}
        page = .search;keyword=track.title+" "+track.artist
        settings.sources=Set(MusicSource.available.map{$0.id}.filter{$0 != track.source});search()
    }
    func clearFinishedJobs(){
        let remaining=jobs.filter{$0.active}
        guard saveJobs(remaining) else{return}
        jobs=remaining
    }
    func chooseDirectory() {
        let panel=NSOpenPanel();panel.canChooseDirectories=true;panel.canChooseFiles=false;panel.canCreateDirectories=true;panel.allowsMultipleSelection=false
        panel.directoryURL=URL(fileURLWithPath:settings.directory)
        if panel.runModal() == .OK,let url=panel.url {settings.directory=url.path}
    }
    func openDirectory() {
        let url=URL(fileURLWithPath:settings.directory);do{try FileManager.default.createDirectory(at:url,withIntermediateDirectories:true);NSWorkspace.shared.open(url)}catch{notice="下载目录无法打开，请重新选择保存位置。"}
    }
    func revealFile(_ path:String) {
        guard !path.isEmpty else {notice="这条下载记录没有保存位置，请重新下载。";return}
        guard FileManager.default.fileExists(atPath:path) else {
            notice="暂时找不到该文件，请确认文件未被移动、删除，且所在磁盘已连接。";return
        }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath:path)])
    }
    func checkEnvironment(){guard !shuttingDown else{return};showEnvironment=true;loadEnvironment()}
    private func loadEnvironment() {
        guard !shuttingDown,!isCheckingEnvironment else{return}
        isCheckingEnvironment=true;let generation=UUID();healthGeneration=generation
        healthTask=engine.request("health",payload:[:]){[weak self] result in
            guard let self=self,!self.shuttingDown,self.healthGeneration==generation else{return}
            self.isCheckingEnvironment=false;self.healthTask=nil
            switch result {
            case .success(let data):self.healthItems=(data["items"] as? [[String:Any]] ?? []).map{EnvironmentItem($0)}
            case .failure(let error):self.healthItems=[EnvironmentItem(["key":"engine","title":"音乐后台","state":"failed","detail":error.reason,"required":true])]
            }
        }
    }
    func refreshAccounts() {
        guard !shuttingDown else{return}
        // Only public metadata is read at startup, never the Keychain.
        let document=AppFiles.read("accounts.json",at:storeURL) as? [String:Any] ?? [:]
        let records=(document["schema"] as? Int == 2 ? document["accounts"] as? [String:[String:Any]] : nil) ?? [:]
        let blocks=AppFiles.read("account-blocks.json",at:storeURL) as? [String:[String:Any]] ?? [:]
        accountRevisions=[:]
        accounts=records.reduce(into:[String:AccountInfo]()) { value,pair in
            let record=pair.value
            guard ["netease","kuwo"].contains(pair.key),let revision=record["revision"] as? String,revision.range(of:"^[0-9a-f]{32}$",options:.regularExpression) != nil else{return}
            accountRevisions[pair.key]=revision
            let paused=blocks[pair.key]?["revision"] as? String == revision || NativeSessionStore.inMemoryPauseCode(storeURL:storeURL,platform:pair.key,revision:revision) != nil
            value[pair.key]=AccountInfo(nickname:record["nickname"] as? String ?? "已连接账号",verified:record["verified"] as? Bool ?? false,method:record["method"] as? String ?? "",blocked:paused,connected:true)
        }
    }
    func connectAccount(_ platform:String) {guard !shuttingDown else{return};NativeAccounts.open(platform:platform,storeURL:storeURL,engine:engine){[weak self] in self?.accountChanged(platform)}}
    func checkAccount(_ platform:String) {accountOperation(platform,action:"check")}
    func disconnectAccount(_ platform:String) {accountOperation(platform,action:"logout")}
    private func accountOperation(_ platform:String,action:String) {
        guard !shuttingDown,accountTasks[platform]==nil else{return}
        accountTasks[platform]=engine.request("account",payload:["store":storeURL.path,"platform":platform,"action":action]){[weak self] result in
            guard let self=self,!self.shuttingDown else{return};self.accountTasks.removeValue(forKey:platform)
            if case .failure(let error)=result{self.notice=error.reason+" "+error.solution}
            self.accountChanged(platform)
        }
    }
    private func accountReference(_ track:AudioTrack)->[String:Any]? {
        (track.raw["metadata"] as? [String:Any])?["account_ref"] as? [String:Any]
    }
    private func pauseAccountAfterFailure(_ error:EngineFailure,track:AudioTrack) {
        guard !shuttingDown,["account_risk","account_expired"].contains(error.code),
              let failed=accountReference(track),let platform=failed["platform"] as? String,
              let revision=failed["revision"] as? String,platform==track.source else{return}
        refreshAccounts()
        // Old account replies must not revoke a replacement account. The
        // engine owns pause creation; this reflects its current public state.
        guard accountRevisions[platform]==revision,accounts[platform]?.blocked==true else{return}
        func matches(_ reference:[String:Any]?)->Bool {
            reference?["platform"] as? String==platform && reference?["revision"] as? String==revision
        }
        for id in probeReferences.keys.filter({matches(probeReferences[$0])}) {
            probeReferences.removeValue(forKey:id)
            probeTasks.removeValue(forKey:id)?.cancel()
            probes[id]=ProbeStatus(state:"authentication",detail:error.reason,solution:error.solution)
        }
        pendingProbes.removeAll { pending in
            guard matches(accountReference(AudioTrack(raw:authorized(pending)))) else{return false}
            probes[pending.id]=ProbeStatus(state:"authentication",detail:error.reason,solution:error.solution)
            return true
        }
        isProbing = !pendingProbes.isEmpty || !probeTasks.isEmpty
        for pending in jobs where pending.active && matches(accountReference(pending.track)) {cancelJob(pending.id)}
    }
    func accountChanged(_ platform:String) {
        guard !shuttingDown else{return}
        let previous=accountRevisions[platform],wasBlocked=accounts[platform]?.blocked ?? false
        refreshAccounts()
        guard previous != accountRevisions[platform] || (!wasBlocked && accounts[platform]?.blocked == true) else{return}
        stopProbes()
        let affected:Set<String> = [platform]
        for track in tracks where affected.contains(track.source){probes.removeValue(forKey:track.id)}
        for job in jobs where job.active && affected.contains(job.track.source){cancelJob(job.id)}
    }
    func shutdown() {
        shuttingDown=true;noticeGeneration=UUID();noticeDismissal?.cancel();noticeDismissal=nil
        stopSearch();stopProbes();healthGeneration=UUID();healthTask?.cancel();healthTask=nil;isCheckingEnvironment=false
        downloadTasks.values.forEach{$0.cancel()};accountTasks.values.forEach{$0.cancel()};saveJobs();saveSettings()
        accountTasks=[:]
    }
}
