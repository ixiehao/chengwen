import Foundation

enum AppPage: String, CaseIterable { case search, downloads, preferences }
struct MusicSource: Identifiable {
    let id: String
    let name: String
    static let all: [MusicSource] = [
        .init(id:"netease",name:"网易云音乐"), .init(id:"kuwo",name:"酷我音乐"),
        .init(id:"kugou",name:"酷狗音乐"), .init(id:"qq",name:"QQ音乐"),
        .init(id:"migu",name:"咪咕音乐"), .init(id:"qianqian",name:"千千音乐"),
        .init(id:"spotify",name:"Spotify"), .init(id:"youtube_music",name:"YouTube Music"),
        .init(id:"bandcamp",name:"Bandcamp"), .init(id:"soundcloud",name:"SoundCloud"), .init(id:"youtube",name:"YouTube"),
    ]
    static let defaultIDs: Set<String> = ["netease", "kuwo"]
    static var available: [MusicSource] { all.filter { ["netease", "kuwo", "kugou", "qq", "migu", "qianqian"].contains($0.id) } }
}
struct AudioFormat: Identifiable {
    let id: String
    let name: String
    static let all: [AudioFormat] = [.init(id:"original",name:"原始格式"),.init(id:"mp3",name:"MP3"),.init(id:"m4a",name:"M4A"),.init(id:"flac",name:"FLAC"),.init(id:"wav",name:"WAV")]
}
struct AudioTrack: Identifiable {
    var raw: [String:Any]
    var id: String { raw["id"] as? String ?? "" }
    var title: String { raw["title"] as? String ?? "未命名音频" }
    var artist: String { raw["artist"] as? String ?? "未知艺术家" }
    var album: String { raw["album"] as? String ?? "—" }
    var source: String { raw["source"] as? String ?? "" }
    var url: String { raw["url"] as? String ?? "" }
    var sourceName: String { MusicSource.all.first{$0.id == source}?.name ?? source }
    var duration: String { raw["duration"] as? String ?? "—" }
    var ext: String { (raw["ext"] as? String ?? "—").uppercased() }
    var fragment: Bool {
        let metadata = raw["metadata"] as? [String:Any] ?? [:]
        let parts = duration.split(separator:":").compactMap{Double($0)}
        let fallback = parts.count >= 2 ? parts.reduce(0){$0*60+$1} : 0
        let seconds = (metadata["duration_s"] as? NSNumber)?.doubleValue ?? (metadata["duration"] as? NSNumber)?.doubleValue ?? fallback
        return seconds.isFinite && seconds > 0 && seconds < 60
    }
    var history: [String:Any] {
        var value: [String:Any] = [:]
        for key in ["id","title","artist","album","source","duration","ext","size"] { value[key] = raw[key] }
        return value
    }
}
struct ProbeStatus {
    var state: String
    var detail: String = ""
    var solution: String = ""
    var technical: String = ""
    var anonymous: Bool? = nil
    var checkedAt = Date()
    var fresh: Bool { isFresh(at: Date()) }
    func isFresh(at now: Date) -> Bool {
        let age = now.timeIntervalSince(checkedAt)
        return age.isFinite && age >= 0 && age < 300
    }
}
struct AppSettings {
    var directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Music/澄闻").path
    var format = "mp3"
    var sources: Set<String> = MusicSource.defaultIDs
    var limit = 10
    var timeout = 90
    var concurrency = 2
    var saveLyrics = true
    var useConnectedAccounts = false
    var recent: [String] = []
    init(_ value: [String:Any] = [:]) {
        if let path=value["directory"] as? String, !path.isEmpty { directory=(path as NSString).expandingTildeInPath }
        if let id=value["format"] as? String, AudioFormat.all.contains(where:{$0.id == id}) { format=id }
        if let ids=value["sources"] as? [String] {
            sources=Set(ids.filter{id in MusicSource.available.contains{$0.id == id}})
            if sources.isEmpty && !ids.isEmpty { sources=MusicSource.defaultIDs }
        }
        if let v=value["limit"] as? Int { limit=max(1,min(30,v)) }
        if let v=value["timeout"] as? Int { timeout=max(15,min(180,v)) }
        if let v=value["concurrency"] as? Int { concurrency=max(1,min(4,v)) }
        if let v=value["save_lyrics"] as? Bool { saveLyrics=v }
        if let v=value["use_connected_accounts"] as? Bool { useConnectedAccounts=v }
        if let values=value["recent"] as? [String] { recent=Array(values.prefix(8)).map{String($0.prefix(100))} }
    }
    var dictionary: [String:Any] { ["directory":directory,"format":format,"sources":MusicSource.all.filter{sources.contains($0.id)}.map{$0.id},"limit":limit,"timeout":timeout,"concurrency":concurrency,"save_lyrics":saveLyrics,"use_connected_accounts":useConnectedAccounts,"recent":recent] }
}
struct DownloadJob: Identifiable {
    var id = UUID().uuidString.replacingOccurrences(of:"-",with:"").lowercased()
    var track: AudioTrack
    var state = "queued"
    var percent = 0
    var detail = "等待下载"
    var solution = ""
    var technical = ""
    var errorCode = ""
    var format: String
    var directory: String
    var lyrics: Bool
    var path = ""
    var retryCount = 0
    var created = ISO8601DateFormatter().string(from:Date())
    var active: Bool { ["queued","downloading","converting","cancelling"].contains(state) }
    var history: [String:Any] { ["id":id,"track":track.history,"state":state,"percent":percent,"detail":detail,"path":path,"created":created,"directory":directory,"format":format,"lyrics":lyrics,"retry_count":retryCount,"error_code":errorCode,"error_reason":state == "failed" ? detail : "","error_solution":solution,"error_technical":technical,"suggest_switch":retryCount > 0] }
    init(track:AudioTrack,format:String,directory:String,lyrics:Bool) { self.track=track;self.format=format;self.directory=directory;self.lyrics=lyrics }
    init?(history:[String:Any]) {
        guard let value=history["track"] as? [String:Any] else{return nil}
        let savedFormat=history["format"] as? String ?? "mp3"
        self.init(track:AudioTrack(raw:value),format:AudioFormat.all.contains(where:{$0.id==savedFormat}) ? savedFormat : "mp3",directory:history["directory"] as? String ?? "",lyrics:history["lyrics"] as? Bool ?? true)
        if let savedID=history["id"] as? String {
            let candidate=savedID.trimmingCharacters(in:.whitespacesAndNewlines)
            if !candidate.isEmpty,candidate.utf8.count<=128,candidate.rangeOfCharacter(from:.controlCharacters)==nil {id=candidate}
        }
        let savedState=history["state"] as? String ?? "interrupted"
        state=["queued","pending","downloading","converting","cancelling","completed","failed","cancelled","interrupted"].contains(savedState) ? savedState : "interrupted"
        if active || state=="pending" {state="interrupted"}
        percent=max(0,min(100,history["percent"] as? Int ?? 0))
        detail=history["detail"] as? String ?? "";path=history["path"] as? String ?? ""
        retryCount=max(0,min(1000,history["retry_count"] as? Int ?? 0));solution=history["error_solution"] as? String ?? "";technical=history["error_technical"] as? String ?? "";errorCode=history["error_code"] as? String ?? ""
        created=history["created"] as? String ?? created
    }
}
struct AccountInfo {
    var nickname: String
    var verified: Bool
    var method: String
    var blocked: Bool
    var connected: Bool
}
struct EnvironmentItem: Identifiable {
    var id: String
    var title: String
    var state: String
    var version: String
    var path: String
    var detail: String
    var required: Bool
    var isReady: Bool { ["ready", "available", "passed", "ok"].contains(state) }
    var statusText: String {
        if isReady { return version.isEmpty ? "已就绪" : version }
        switch state {
        case "missing": return "未找到"
        case "failed": return id == "engine" ? "检查失败" : "无法运行"
        default: return "待处理"
        }
    }
    init(_ value:[String:Any]) { id=value["key"] as? String ?? "";title=value["title"] as? String ?? id;state=value["state"] as? String ?? "failed";version=value["version"] as? String ?? "";path=value["path"] as? String ?? "";detail=value["detail"] as? String ?? "";required=value["required"] as? Bool ?? true }
}
enum AppFiles {
    /// Existing sessions are scoped to the canonical store path. Keep that path
    /// for upgrades; moving/copying account metadata would invalidate its vault keys.
    /// Fresh installations use the new product name. No files are moved or read here.
    static func root(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        let support = home.appendingPathComponent("Library/Application Support", isDirectory: true)
        let legacy = support.appendingPathComponent("VmDown", isDirectory: true)
        var directory: ObjCBool = false
        if FileManager.default.fileExists(atPath: legacy.path, isDirectory: &directory), directory.boolValue {
            return legacy
        }
        return support.appendingPathComponent("澄闻", isDirectory: true)
    }
    static func read(_ name:String, at root:URL) -> Any? { guard let data=try? Data(contentsOf:root.appendingPathComponent(name)) else{return nil};return try? JSONSerialization.jsonObject(with:data) }
    static func write(_ value:Any,name:String,at root:URL) throws {
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let data=try JSONSerialization.data(withJSONObject:value,options:[.sortedKeys,.prettyPrinted])
        try data.write(to:root.appendingPathComponent(name),options:.atomic)
    }
}
