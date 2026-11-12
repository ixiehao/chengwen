import Foundation

enum NativeMiguSource {
    static func search(keyword: String, limit: Int, request: NativeAdditionalSources.Request) async throws -> [[String:Any]] {
        let url = NativeHTTP.url("https://app.u.nf.migu.cn/pc/resource/song/item/search/v1.0", query: ["text": keyword, "pageNo": "1", "pageSize": String(limit)])
        return try parseSearch(await request(url, ["Referer": "https://music.migu.cn/"], "GET", nil), limit: limit)
    }

    static func parseSearch(_ json: [String:Any], limit: Int) throws -> [[String:Any]] {
        if let code = json["code"], !NativeAdditionalSources.code(code) { throw NativeAdditionalSources.unavailable("migu", detail: "当前搜索请求被平台拒绝。") }
        let data = NativeAdditionalSources.object(json["data"])
        let songData = NativeAdditionalSources.object(json["songResultData"])
        guard let songs = json["items"] as? [[String:Any]] ?? json["musics"] as? [[String:Any]] ?? data["items"] as? [[String:Any]] ?? data["results"] as? [[String:Any]] ?? songData["result"] as? [[String:Any]] else { throw NativeAdditionalSources.response("migu") }
        let tracks = songs.prefix(max(1, min(30, limit))).compactMap { song -> [String:Any]? in
            guard let copyrightID = NativeAdditionalSources.token(song["copyrightId"], pattern: "^[A-Za-z0-9]{6,40}$") else { return nil }
            let artists = song["singerList"] as? [[String:Any]] ?? song["artists"] as? [[String:Any]] ?? []
            let names = artists.map { NativeAdditionalSources.text($0["name"], fallback: "") }.filter { !$0.isEmpty }.joined(separator: " / ")
            let artist = names.isEmpty ? NativeAdditionalSources.string(song["singer"]) : names
            let contentID = NativeAdditionalSources.token(song["contentId"], pattern: "^[A-Za-z0-9]{1,40}$") ?? ""
            let seconds = NativeAdditionalSources.seconds(song["duration"] ?? song["length"] ?? song["songDuration"])
            return NativeAdditionalSources.track(source: "migu", id: copyrightID, title: song["songName"] ?? song["name"], artist: artist, album: song["album"] ?? song["albumName"], seconds: seconds, page: URL(string: "https://music.migu.cn/v3/music/song/\(copyrightID)")!, metadata: ["content_id": contentID, "catalog_song_id": NativeAdditionalSources.string(song["songId"])])
        }
        return NativeAdditionalSources.unique(tracks, limit: limit)
    }

    static func resolve(_ track: [String:Any], request: NativeAdditionalSources.Request) async throws -> NativeResolvedAudio {
        let metadata = NativeAdditionalSources.object(track["metadata"])
        guard let copyrightID = NativeAdditionalSources.token(metadata["song_id"], pattern: "^[A-Za-z0-9]{6,40}$"),
              let contentID = NativeAdditionalSources.token(metadata["content_id"], pattern: "^[A-Za-z0-9]{1,40}$") else { throw NativeAdditionalSources.response("migu") }
        let url = NativeHTTP.url("https://app.c.nf.migu.cn/MIGUM3.0/strategy/pc/listen/v1.0", query: ["scene": "", "netType": "01", "resourceType": "2", "copyrightId": copyrightID, "contentId": contentID, "toneFlag": "PQ"])
        return try parseResolution(await request(url, ["Referer": "https://music.migu.cn/", "channel": "0146951"], "GET", nil), track: track)
    }

    static func parseResolution(_ json: [String:Any], track: [String:Any]) throws -> NativeResolvedAudio {
        if let code = json["code"], !NativeAdditionalSources.code(code) { throw NativeAdditionalSources.permission("migu") }
        let data = NativeAdditionalSources.object(json["data"])
        let expectedID = NativeAdditionalSources.string(NativeAdditionalSources.object(track["metadata"])["song_id"])
        let returnedID = NativeAdditionalSources.string(data["copyrightId"])
        guard returnedID.isEmpty || returnedID == expectedID else { throw NativeAdditionalSources.response("migu") }
        if NativeMusicEngine.number(data["auditionsLength"]) > 0 || NativeMusicEngine.number(data["auditionsFlag"]) > 0 || NativeMusicEngine.number(data["isTrial"]) > 0 || NativeMusicEngine.number(data["isPreview"]) > 0 { throw NativeAdditionalSources.preview("migu") }
        var value = NativeAdditionalSources.string(data["url"] ?? data["playUrl"])
        guard !value.isEmpty else { throw NativeAdditionalSources.permission("migu") }
        if value.hasPrefix("//") { value = "https:" + value }
        value = value.replacingOccurrences(of: "+", with: "%2B")
        let expected = NativeAdditionalSources.duration(track)
        let actual = NativeAdditionalSources.seconds(data["duration"])
        if let expected = expected, expected >= 60, actual > 0, actual < min(expected * 0.85, expected - 15) { throw NativeAdditionalSources.preview("migu") }
        return NativeResolvedAudio(url: try NativeAdditionalSources.mediaURL(value, source: "migu"), headers: ["Referer": "https://music.migu.cn/"], expectedDuration: expected, container: "mp3")
    }
}
