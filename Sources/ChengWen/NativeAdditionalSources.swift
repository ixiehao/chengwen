import Foundation
import CryptoKit
import CoreFoundation

/// Native adapters for the public catalogue and media endpoints. No interpreter,
/// hosted parsing service, browser cookies or account sessions are involved.
/// Protocol references: Listen1 (MIT), with the exact revision in THIRD_PARTY.
enum NativeAdditionalSources {
    typealias Request = (URL, [String:String], String, Data?) async throws -> [String:Any]
    static let ids: Set<String> = ["kugou", "qq", "migu", "qianqian"]
    static let mediaDomains: [String:[String]] = ["qq": ["qqmusic.qq.com", "qqmusic.com", "qqmusic.tc.qq.com"], "kugou": ["kugou.com", "kugou.net"], "migu": ["migu.cn", "migucloud.com"], "qianqian": ["91q.com", "taihe.com", "qianqian.com", "dmhmusic.com"]]
    static func trustedMediaHost(_ host: String) -> Bool {
        mediaDomains.values.joined().contains { host == $0 || host.hasSuffix("." + $0) }
    }

    static func network(_ url: URL, _ headers: [String:String], _ method: String, _ body: Data?) async throws -> [String:Any] {
        let headers = headers.filter { !["cookie", "authorization", "proxy-authorization"].contains($0.key.lowercased()) }
        let (data, _) = try await NativeHTTP.data(url, headers: headers, method: method, body: body)
        guard let value = try? JSONSerialization.jsonObject(with: data) else {
            throw EngineFailure(reason: "平台没有返回有效的歌曲数据。", solution: "请稍后重试或更换音源。", code: "source_response")
        }
        if let object = value as? [String:Any] { return object }
        if let array = value as? [[String:Any]] { return ["items": array] }
        throw EngineFailure(reason: "平台响应格式不支持。", code: "source_response")
    }

    static func search(source: String, keyword: String, limit: Int, request: Request = network) async throws -> [[String:Any]] {
        let keyword = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty, keyword.count <= 100 else { throw EngineFailure(reason: "请输入歌名或艺术家。", code: "invalid_request") }
        let limit = max(1, min(30, limit))
        switch source {
        case "qq": return try await NativeQQSource.search(keyword: keyword, limit: limit, request: request)
        case "kugou": return try await NativeKugouSource.search(keyword: keyword, limit: limit, request: request)
        case "migu": return try await NativeMiguSource.search(keyword: keyword, limit: limit, request: request)
        case "qianqian": return try await NativeQianqianSource.search(keyword: keyword, limit: limit, request: request)
        default: throw NativeMusicEngine.unsupported()
        }
    }

    static func resolve(_ track: [String:Any], request: Request = network) async throws -> NativeResolvedAudio {
        try Task.checkCancellation()
        switch track["source"] as? String {
        case "qq": return try await NativeQQSource.resolve(track, request: request)
        case "kugou": return try await NativeKugouSource.resolve(track, request: request)
        case "migu": return try await NativeMiguSource.resolve(track, request: request)
        case "qianqian": return try await NativeQianqianSource.resolve(track, request: request)
        default: throw NativeMusicEngine.unsupported()
        }
    }

    static func parseSearch(_ json: [String:Any], source: String, limit: Int = 10) throws -> [[String:Any]] {
        switch source {
        case "qq": return try NativeQQSource.parseSearch(json, limit: limit)
        case "kugou": return try NativeKugouSource.parseSearch(json, limit: limit)
        case "migu": return try NativeMiguSource.parseSearch(json, limit: limit)
        case "qianqian": return try NativeQianqianSource.parseSearch(json, limit: limit)
        default: throw NativeMusicEngine.unsupported()
        }
    }

    static func parseResolution(_ json: [String:Any], track: [String:Any]) throws -> NativeResolvedAudio {
        switch track["source"] as? String {
        case "qq": return try NativeQQSource.parseResolution(json, track: track)
        case "kugou": return try NativeKugouSource.parseResolution(json, track: track)
        case "migu": return try NativeMiguSource.parseResolution(json, track: track)
        case "qianqian": return try NativeQianqianSource.parseResolution(json, track: track)
        default: throw NativeMusicEngine.unsupported()
        }
    }

    static func object(_ value: Any?) -> [String:Any] { value as? [String:Any] ?? [:] }
    static func code(_ value: Any?, equals expected: Int = 0) -> Bool {
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() { return number.doubleValue.isFinite && number.doubleValue == Double(expected) }
        if let text = value as? String, text.range(of: "^-?[0-9]{1,10}$", options: .regularExpression) != nil { return Int(text) == expected }
        return false
    }
    static func string(_ value: Any?) -> String {
        if let value = value as? String { return value.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let value = value as? NSNumber, value.doubleValue.isFinite { return value.stringValue }
        return ""
    }
    static func text(_ value: Any?, fallback: String = "—") -> String {
        let value = NativeMusicEngine.clean(value, fallback: fallback)
        return value.replacingOccurrences(of: "</?(?:em|span|b|font)(?:\\s[^>]*)?>", with: "", options: [.regularExpression, .caseInsensitive])
    }
    static func numericID(_ value: Any?, allowZero: Bool = false) -> String? {
        let value = string(value)
        if allowZero && value == "0" { return value }
        return NativeMusicEngine.validID(value) ? value : nil
    }
    static func token(_ value: Any?, pattern: String) -> String? {
        let value = string(value)
        return value.range(of: pattern, options: .regularExpression) == nil ? nil : value
    }
    static func duration(_ track: [String:Any]) -> Double? {
        let value = NativeMusicEngine.number(object(track["metadata"])["duration_s"])
        return value.isFinite && value > 0 && value < 360_000 ? value : nil
    }
    static func seconds(_ value: Any?) -> Double {
        if let text = value as? String, text.contains(":") {
            let parts = text.split(separator: ":", omittingEmptySubsequences: false)
            guard (2...3).contains(parts.count) else { return 0 }
            var total = 0.0
            for (index, part) in parts.enumerated() {
                guard let number = Double(part), number.isFinite, number >= 0, index == 0 || number < 60 else { return 0 }
                total = total * 60 + number
            }
            return total < 360_000 ? total : 0
        }
        let value = NativeMusicEngine.number(value)
        return value.isFinite && value > 0 && value < 360_000 ? value : 0
    }
    static func track(source: String, id: String, title: Any?, artist: Any?, album: Any?, seconds: Double, page: URL, metadata: [String:Any] = [:], ext: String = "mp3") -> [String:Any] {
        let identity = SHA256.hash(data: Data("\(source):\(id)".utf8)).map { String(format: "%02x", $0) }.joined().prefix(24)
        var metadata = metadata
        metadata["song_id"] = id
        metadata["duration_s"] = seconds.isFinite && seconds > 0 && seconds < 360_000 ? seconds : 0
        return ["id": String(identity), "title": text(title, fallback: "未命名音频"), "artist": text(artist, fallback: "未知艺术家"), "album": text(album), "duration": NativeMusicEngine.duration(seconds), "source": source, "url": page.absoluteString, "ext": ext, "metadata": metadata]
    }
    static func unique(_ tracks: [[String:Any]], limit: Int) -> [[String:Any]] {
        var seen = Set<String>()
        return Array(tracks.filter { seen.insert($0["id"] as? String ?? "").inserted }.prefix(max(1, min(30, limit))))
    }

    /// Only platform-owned audio origins are accepted, and legacy HTTP addresses
    /// are upgraded before any request. Sessions are never sent to media CDNs.
    static func mediaURL(_ value: String, source: String) throws -> URL {
        guard var parts = URLComponents(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = parts.host?.lowercased(), (mediaDomains[source] ?? []).contains(where: { host == $0 || host.hasSuffix("." + $0) }),
              parts.user == nil, parts.password == nil, parts.port == nil || parts.port == 443,
              ["http", "https"].contains(parts.scheme?.lowercased() ?? "") else { throw unavailable(source, detail: "平台没有返回可验证的官方音频地址。") }
        parts.scheme = "https"
        guard let url = parts.url else { throw unavailable(source) }
        let path = parts.path.lowercased()
        guard ![".m3u8", ".mpd", ".qmc", ".mflac", ".mgg", ".kgm", ".vpr"].contains(where: { path.hasSuffix($0) }) else {
            throw EngineFailure(reason: "这个版本返回了当前不支持的流媒体或加密音频。", solution: "请选择普通音质的其他版本，或更换音源。", code: "audio_protected")
        }
        return url
    }
    static func unavailable(_ source: String, detail: String = "当前版本没有可用的完整音频链接。") -> EngineFailure {
        let name = MusicSource.all.first { $0.id == source }?.name ?? "当前来源"
        return EngineFailure(reason: "\(name)：\(detail)", solution: "请重试一次；仍失败时，请换其他音源或同名歌曲的其他版本。", code: "source_unavailable")
    }
    static func permission(_ source: String) -> EngineFailure {
        let name = MusicSource.all.first { $0.id == source }?.name ?? "当前来源"
        return EngineFailure(reason: "\(name)未向当前匿名请求提供完整音频权限。", solution: "请选择该平台允许匿名访问的其他歌曲版本，或换其他音源。", code: "source_permission")
    }
    static func preview(_ source: String) -> EngineFailure {
        let name = MusicSource.all.first { $0.id == source }?.name ?? "当前来源"
        return EngineFailure(reason: "\(name)仅返回试听片段，未作为完整歌曲下载。", solution: "请选择允许匿名访问的完整版本，或换其他音源。", code: "audio_preview")
    }
    static func verification(_ source: String) -> EngineFailure {
        let name = MusicSource.all.first { $0.id == source }?.name ?? "当前来源"
        return EngineFailure(reason: "\(name)要求额外验证，已停止本次匿名请求。", solution: "请稍后再试或更换其他音源，不要连续重试此版本。", code: "source_verification")
    }
    static func response(_ source: String) -> EngineFailure {
        let name = MusicSource.all.first { $0.id == source }?.name ?? "当前来源"
        return EngineFailure(reason: "\(name)接口响应结构已变化。", solution: "请稍后重试，或暂时切换其他音源。", code: "source_response")
    }
    static func body(_ value: [String:Any]) throws -> Data { try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) }
}
