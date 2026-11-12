import Foundation

enum NativeQQSource {
    private static let gateway = URL(string: "https://u.y.qq.com/cgi-bin/musicu.fcg")!
    private static let headers = ["Referer": "https://y.qq.com/", "Origin": "https://y.qq.com", "Content-Type": "application/json"]

    static func search(keyword: String, limit: Int, request: NativeAdditionalSources.Request) async throws -> [[String:Any]] {
        let envelope: [String:Any] = [
            "comm": ["ct": "19", "cv": "1859", "uin": "0"],
            "req": ["module": "music.search.SearchCgiService", "method": "DoSearchForQQMusicDesktop", "param": ["grp": 1, "num_per_page": limit, "page_num": 1, "query": keyword, "search_type": 0]]
        ]
        return try parseSearch(await request(gateway, headers, "POST", NativeAdditionalSources.body(envelope)), limit: limit)
    }

    static func parseSearch(_ json: [String:Any], limit: Int) throws -> [[String:Any]] {
        guard NativeAdditionalSources.code(json["code"]) else { throw NativeAdditionalSources.unavailable("qq", detail: "歌曲搜索被平台拒绝，请稍后重试。") }
        let req = NativeAdditionalSources.object(json["req"])
        guard req.isEmpty || NativeAdditionalSources.code(req["code"]) else { throw NativeAdditionalSources.unavailable("qq", detail: "当前搜索接口暂不可用。") }
        let body = NativeAdditionalSources.object(NativeAdditionalSources.object(req["data"])["body"])
        let modern = NativeAdditionalSources.object(body["song"])["list"] as? [[String:Any]]
        let legacy = NativeAdditionalSources.object(NativeAdditionalSources.object(json["data"])["song"])["list"] as? [[String:Any]]
        guard let songs = modern ?? legacy else { throw NativeAdditionalSources.response("qq") }
        let tracks = songs.prefix(max(1, min(30, limit))).compactMap { song -> [String:Any]? in
            guard let mid = NativeAdditionalSources.token(song["mid"] ?? song["songmid"], pattern: "^[A-Za-z0-9]{10,32}$") else { return nil }
            let album = NativeAdditionalSources.object(song["album"])
            let singers = (song["singer"] as? [[String:Any]] ?? []).map { NativeAdditionalSources.text($0["name"], fallback: "") }.filter { !$0.isEmpty }.joined(separator: " / ")
            let file = NativeAdditionalSources.object(song["file"])
            let mediaMID = NativeAdditionalSources.token(file["media_mid"], pattern: "^[A-Za-z0-9]{10,32}$") ?? mid
            let pay = NativeAdditionalSources.object(song["pay"])
            let type = NativeMusicEngine.number(song["type"])
            return NativeAdditionalSources.track(source: "qq", id: mid, title: song["title"] ?? song["name"] ?? song["songname"], artist: singers, album: album["name"] ?? song["albumname"], seconds: NativeMusicEngine.number(song["interval"]), page: URL(string: "https://y.qq.com/n/ryqq/songDetail/\(mid)")!, metadata: ["media_mid": mediaMID, "song_type": type.isFinite && type >= 0 && type < 1000 ? Int(type) : 0, "requires_purchase": NativeMusicEngine.number(pay["pay_down"]) > 0], ext: "m4a")
        }
        return NativeAdditionalSources.unique(tracks, limit: limit)
    }

    static func resolve(_ track: [String:Any], request: NativeAdditionalSources.Request) async throws -> NativeResolvedAudio {
        let metadata = NativeAdditionalSources.object(track["metadata"])
        guard let mid = NativeAdditionalSources.token(metadata["song_id"], pattern: "^[A-Za-z0-9]{10,32}$") else { throw NativeAdditionalSources.response("qq") }
        let envelope: [String:Any] = [
            "comm": ["uin": "0", "format": "json", "ct": 24, "cv": 0],
            "req_1": ["module": "vkey.GetVkeyServer", "method": "CgiGetVkey", "param": ["guid": String(UInt64.random(in: 1_000_000_000...9_999_999_999)), "songmid": [mid], "songtype": [metadata["song_type"] as? Int ?? 0], "uin": "0", "loginflag": 0, "platform": "20"]]
        ]
        return try parseResolution(await request(gateway, headers, "POST", NativeAdditionalSources.body(envelope)), track: track)
    }

    static func parseResolution(_ json: [String:Any], track: [String:Any]) throws -> NativeResolvedAudio {
        let mid = NativeAdditionalSources.string(NativeAdditionalSources.object(track["metadata"])["song_id"])
        let req = NativeAdditionalSources.object(json["req_1"])
        guard NativeAdditionalSources.code(json["code"]), NativeAdditionalSources.code(req["code"]) else { throw NativeAdditionalSources.permission("qq") }
        let data = NativeAdditionalSources.object(req["data"])
        guard let items = data["midurlinfo"] as? [[String:Any]], let item = items.first else { throw NativeAdditionalSources.response("qq") }
        guard !mid.isEmpty, NativeAdditionalSources.string(item["songmid"]) == mid else { throw NativeAdditionalSources.response("qq") }
        guard NativeAdditionalSources.code(item["result"]) else {
            var failure = NativeAdditionalSources.permission("qq")
            if let code = NativeAdditionalSources.token(item["result"], pattern: "^-?[0-9]{1,10}$") { failure.technical = "QQ VKey result \(code)" }
            throw failure
        }
        if NativeMusicEngine.number(item["is_trial"]) > 0 || NativeMusicEngine.number(item["trial"]) > 0 { throw NativeAdditionalSources.preview("qq") }
        let purl = NativeAdditionalSources.string(item["purl"])
        guard !purl.isEmpty else {
            var failure = NativeAdditionalSources.permission("qq")
            if let code = NativeAdditionalSources.token(item["result"], pattern: "^-?[0-9]{1,10}$") { failure.technical = "QQ VKey result \(code)" }
            throw failure
        }
        var candidates = [URL]()
        if purl.hasPrefix("https://") || purl.hasPrefix("http://") { candidates = [try NativeAdditionalSources.mediaURL(purl, source: "qq")] }
        else {
            guard !purl.hasPrefix("//"), !purl.hasPrefix("/") else { throw NativeAdditionalSources.response("qq") }
            for sip in data["sip"] as? [String] ?? [] {
                guard let base = try? NativeAdditionalSources.mediaURL(sip, source: "qq"),
                      let url = URL(string: purl, relativeTo: base)?.absoluteURL,
                      let safe = try? NativeAdditionalSources.mediaURL(url.absoluteString, source: "qq") else { continue }
                candidates.append(safe)
            }
        }
        guard let media = candidates.first else { throw NativeAdditionalSources.unavailable("qq") }
        return NativeResolvedAudio(url: media, headers: ["Referer": "https://y.qq.com/"], expectedDuration: NativeAdditionalSources.duration(track), container: media.pathExtension.lowercased() == "m4a" ? "m4a" : "mp3")
    }
}
