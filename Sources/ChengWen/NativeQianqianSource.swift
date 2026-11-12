import Foundation
import CryptoKit

enum NativeQianqianSource {
    /// Public web-client request signing, referenced from Listen1 (MIT).
    /// These application constants are not an account credential or music key.
    static func signedURL(_ path: String, parameters: [String:String], timestamp: Int = Int(Date().timeIntervalSince1970)) -> URL {
        var parameters = parameters
        parameters["appid"] = "16073360"
        parameters["timestamp"] = String(timestamp)
        parameters.removeValue(forKey: "sign")
        // URLSearchParams.sort() followed by decodeURIComponent(): form spaces
        // remain '+', while the other percent escapes become literal UTF-8.
        let canonical = parameters.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value.replacingOccurrences(of: " ", with: "+"))" }.joined(separator: "&") + "0b50b02fd0d73a9c4c8c3a781c30845f"
        parameters["sign"] = Insecure.MD5.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
        return NativeHTTP.url("https://music.91q.com/v1" + path, query: parameters)
    }

    static func search(keyword: String, limit: Int, request: NativeAdditionalSources.Request) async throws -> [[String:Any]] {
        let url = signedURL("/search", parameters: ["word": keyword, "pageNo": "1", "pageSize": String(limit), "type": "1"])
        return try parseSearch(await request(url, ["Referer": "https://music.91q.com/"], "GET", nil), limit: limit)
    }

    static func parseSearch(_ json: [String:Any], limit: Int) throws -> [[String:Any]] {
        if let state = json["state"] as? Bool, !state { throw NativeAdditionalSources.unavailable("qianqian", detail: "当前搜索请求被平台拒绝。") }
        let data = NativeAdditionalSources.object(json["data"])
        guard let songs = data["typeTrack"] as? [[String:Any]] else { throw NativeAdditionalSources.response("qianqian") }
        let tracks = songs.prefix(max(1, min(30, limit))).compactMap { song -> [String:Any]? in
            guard let id = NativeAdditionalSources.token(song["id"] ?? song["TSID"], pattern: "^[A-Za-z0-9_-]{1,64}$") else { return nil }
            let artists = song["artist"] as? [[String:Any]] ?? []
            let names = artists.map { NativeAdditionalSources.text($0["name"], fallback: "") }.filter { !$0.isEmpty }.joined(separator: " / ")
            return NativeAdditionalSources.track(source: "qianqian", id: id, title: song["title"], artist: names, album: song["albumTitle"], seconds: NativeAdditionalSources.seconds(song["duration"] ?? song["length"]), page: URL(string: "https://music.91q.com/song/\(id)")!, metadata: ["requires_purchase": NativeMusicEngine.number(song["isVip"]) > 0 || NativeMusicEngine.number(song["isPaid"]) > 0])
        }
        return NativeAdditionalSources.unique(tracks, limit: limit)
    }

    static func resolve(_ track: [String:Any], request: NativeAdditionalSources.Request) async throws -> NativeResolvedAudio {
        guard let id = NativeAdditionalSources.token(NativeAdditionalSources.object(track["metadata"])["song_id"], pattern: "^[A-Za-z0-9_-]{1,64}$") else { throw NativeAdditionalSources.response("qianqian") }
        return try parseResolution(await request(signedURL("/song/tracklink", parameters: ["TSID": id]), ["Referer": "https://music.91q.com/"], "GET", nil), track: track)
    }

    static func parseResolution(_ json: [String:Any], track: [String:Any]) throws -> NativeResolvedAudio {
        if let state = json["state"] as? Bool, !state { throw NativeAdditionalSources.permission("qianqian") }
        let data = NativeAdditionalSources.object(json["data"])
        let requested = NativeAdditionalSources.string(NativeAdditionalSources.object(track["metadata"])["song_id"])
        let returned = NativeAdditionalSources.string(data["id"] ?? data["TSID"])
        guard returned.isEmpty || returned == requested else { throw NativeAdditionalSources.response("qianqian") }
        if NativeMusicEngine.number(data["isPreview"]) > 0 || NativeMusicEngine.number(data["is_trial"]) > 0 || NativeMusicEngine.number(data["freePart"]) > 0 { throw NativeAdditionalSources.preview("qianqian") }
        let value = NativeAdditionalSources.string(data["path"])
        guard !value.isEmpty else { throw NativeAdditionalSources.permission("qianqian") }
        let expected = NativeAdditionalSources.duration(track)
        let actual = NativeAdditionalSources.seconds(data["duration"])
        if let expected = expected, expected >= 60, actual > 0, actual < min(expected * 0.85, expected - 15) { throw NativeAdditionalSources.preview("qianqian") }
        let media = try NativeAdditionalSources.mediaURL(value, source: "qianqian")
        return NativeResolvedAudio(url: media, headers: ["Referer": "https://music.91q.com/"], expectedDuration: expected, container: media.pathExtension.lowercased() == "flac" ? "flac" : "mp3")
    }
}
