import Foundation

/// Explicit command-line QA path: anonymous endpoints and a disposable directory.
/// It creates no AppModel, reads no settings/accounts and opens no GUI window.
enum NativeSourceCheck {
    static func start() -> Never {
        Task.detached {
            let report = await run(CommandLine.arguments)
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), let text = String(data: data, encoding: .utf8) { print(text) }
            fflush(stdout)
            exit(report["passed"] as? Bool == true ? 0 : 1)
        }
        dispatchMain()
    }

    private static func run(_ arguments: [String]) async -> [String:Any] {
        func argument(_ key: String) -> String? {
            guard let index = arguments.firstIndex(of: key), arguments.count > index + 1 else { return nil }
            return arguments[index + 1]
        }
        let source = argument("--source") ?? "", keyword = argument("--keyword") ?? "小星星"
        let limit = max(1, min(10, Int(argument("--limit") ?? "5") ?? 5))
        var report: [String:Any] = ["source": source, "keyword": keyword, "implementation": "Swift", "anonymous": true, "account_access": false, "validation_scope": arguments.contains("--download") ? "full_download" : "bounded_preview", "passed": false]
        guard MusicSource.available.contains(where: { $0.id == source }) else { report["error"] = "Unknown source"; return report }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("chengwen-public-source-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var tracks = [[String:Any]]()
        do {
            let result = try await NativeMusicEngine.execute("search", payload: ["source": source, "keyword": keyword, "limit": limit]) { event, value in if event == "track" { tracks.append(value) } }
            report["search_count"] = result["count"]
            report["tracks"] = tracks.map { AudioTrack(raw: $0).history }
        } catch { report["search_failure"] = failure(error); return report }
        guard !tracks.isEmpty else { report["error"] = "No matching songs"; return report }
        var attempts = [[String:Any]]()
        // At most two songs, one resolution each. Do not repeatedly request
        // rejected authorisation or cycle through hosted parsing services.
        let candidates = tracks.enumerated().sorted {
            let left = (NativeAdditionalSources.object($0.element["metadata"])["requires_purchase"] as? Bool ?? false) ? 1 : 0
            let right = (NativeAdditionalSources.object($1.element["metadata"])["requires_purchase"] as? Bool ?? false) ? 1 : 0
            return left == right ? $0.offset < $1.offset : left < right
        }.map(\.element)
        for track in candidates.prefix(2) {
            var attempt: [String:Any] = ["track": AudioTrack(raw: track).history]
            do {
                let resolved = try await NativeMusicEngine.resolve(track)
                attempt["media_host"] = resolved.url.host
                let preview = try await NativeMusicEngine.probe(resolved)
                attempt["probe"] = preview
                if arguments.contains("--download") {
                    let result = try await NativeMusicEngine.download(track, resolved: resolved, directory: root, format: "original", saveLyrics: false, event: { _, _ in })
                    let attributes = (try? FileManager.default.attributesOfItem(atPath: result["path"] as? String ?? "")) ?? [:]
                    let bytes: Int64 = (attributes[.size] as? NSNumber)?.int64Value ?? 0
                    let fullVerified = (result["full_verified"] as? Bool) ?? false
                    let anonymous = (result["anonymous"] as? Bool) ?? false
                    let download: [String:Any] = ["duration": result["duration"] ?? 0, "codec": result["codec"] ?? "", "bytes": bytes, "full_verified": fullVerified, "anonymous": anonymous]
                    attempt["download"] = download
                }
                report["passed"] = true
                attempts.append(attempt)
                break
            } catch {
                attempt["failure"] = failure(error)
                attempts.append(attempt)
                if let failure = error as? EngineFailure, ["rate_limited", "source_verification"].contains(failure.code) { break }
            }
        }
        report["attempts"] = attempts
        return report
    }

    private static func failure(_ error: Error) -> [String:String] {
        if let failure = error as? EngineFailure { return ["code": failure.code, "reason": failure.reason, "solution": failure.solution, "technical": failure.technical] }
        let value = error as NSError
        // Avoid serialising URLs, response bodies or URLSession userInfo.
        return ["domain": value.domain, "code": String(value.code)]
    }
}
