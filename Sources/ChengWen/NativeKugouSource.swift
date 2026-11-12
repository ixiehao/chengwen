import Foundation

enum NativeKugouSource {
    static func search(keyword: String, limit: Int, request: NativeAdditionalSources.Request) async throws -> [[String:Any]] {
        let url = NativeHTTP.url("https://songsearch.kugou.com/song_search_v2", query: ["keyword": keyword, "page": "1", "pagesize": String(limit)])
        return try parseSearch(await request(url, ["Referer": "https://www.kugou.com/"], "GET", nil), limit: limit)
    }

    static func parseSearch(_ json: [String:Any], limit: Int) throws -> [[String:Any]] {
        guard NativeAdditionalSources.code(json["status"], equals: 1) else { throw NativeAdditionalSources.unavailable("kugou", detail: "当前搜索请求被平台拒绝。") }
        let data = NativeAdditionalSources.object(json["data"])
        guard let songs = data["lists"] as? [[String:Any]] ?? data["info"] as? [[String:Any]] else { throw NativeAdditionalSources.response("kugou") }
        let tracks = songs.prefix(max(1, min(30, limit))).compactMap { song -> [String:Any]? in
            guard let hash = NativeAdditionalSources.token(song["FileHash"] ?? song["hash"], pattern: "^[0-9a-fA-F]{32}$")?.lowercased() else { return nil }
            let albumID = NativeAdditionalSources.numericID(song["AlbumID"] ?? song["album_id"], allowZero: true) ?? "0"
            let singers = (song["Singers"] as? [[String:Any]] ?? []).map { NativeAdditionalSources.text($0["name"], fallback: "") }.filter { !$0.isEmpty }.joined(separator: " / ")
            let singer = NativeAdditionalSources.string(song["SingerName"]).isEmpty ? singers : NativeAdditionalSources.string(song["SingerName"])
            let title = song["SongName"] ?? song["OriSongName"] ?? song["songname"] ?? song["filename"]
            let seconds = NativeMusicEngine.number(song["Duration"] ?? song["duration"])
            return NativeAdditionalSources.track(source: "kugou", id: hash, title: title, artist: singer, album: song["AlbumName"] ?? song["album_name"], seconds: seconds, page: URL(string: "https://www.kugou.com/song/#hash=\(hash)&album_id=\(albumID)")!, metadata: ["album_id": albumID, "requires_purchase": NativeMusicEngine.number(song["PayType"]) > 0])
        }
        return NativeAdditionalSources.unique(tracks, limit: limit)
    }

    static func resolve(_ track: [String:Any], request: NativeAdditionalSources.Request) async throws -> NativeResolvedAudio {
        let metadata = NativeAdditionalSources.object(track["metadata"])
        guard let hash = NativeAdditionalSources.token(metadata["song_id"], pattern: "^[0-9a-fA-F]{32}$") else { throw NativeAdditionalSources.response("kugou") }
        let url = NativeHTTP.url("https://m.kugou.com/app/i/getSongInfo.php", query: ["cmd": "playInfo", "hash": hash])
        return try parseResolution(await request(url, ["Referer": "https://m.kugou.com/"], "GET", nil), track: track)
    }

    static func parseResolution(_ json: [String:Any], track: [String:Any]) throws -> NativeResolvedAudio {
        let data = (json["data"] as? [String:Any]) ?? json
        if [json["errcode"], json["err_code"]].contains(where: { NativeAdditionalSources.code($0, equals: 30020) }) || NativeAdditionalSources.string(json["error"]).contains("验证") { throw NativeAdditionalSources.verification("kugou") }
        guard NativeAdditionalSources.code(json["status"], equals: 1), [json["errcode"], json["err_code"]].allSatisfy({ $0 == nil || NativeAdditionalSources.code($0) }) else { throw NativeAdditionalSources.permission("kugou") }
        if NativeMusicEngine.number(data["is_free_part"]) > 0 || NativeMusicEngine.number(data["is_trial"]) > 0 || NativeMusicEngine.number(data["free_part"]) > 0 { throw NativeAdditionalSources.preview("kugou") }
        let requested = NativeAdditionalSources.string(NativeAdditionalSources.object(track["metadata"])["song_id"]).lowercased()
        let returned = NativeAdditionalSources.string(data["hash"] ?? data["audio_hash"]).lowercased()
        guard !requested.isEmpty, returned.isEmpty || returned == requested else { throw NativeAdditionalSources.response("kugou") }
        let value = NativeAdditionalSources.string(data["url"] ?? data["play_url"])
        guard !value.isEmpty else { throw NativeAdditionalSources.permission("kugou") }
        let expected = NativeAdditionalSources.duration(track)
        let actual = NativeMusicEngine.number(data["timeLength"] ?? data["timelength"])
        if let expected = expected, expected >= 60, actual > 0, actual < min(expected * 0.85, expected - 15) { throw NativeAdditionalSources.preview("kugou") }
        return NativeResolvedAudio(url: try NativeAdditionalSources.mediaURL(value, source: "kugou"), headers: ["Referer": "https://m.kugou.com/"], expectedDuration: expected, lyric: data["lyrics"] as? String, container: "mp3")
    }
}
