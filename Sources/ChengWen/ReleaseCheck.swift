import Foundation

enum ReleaseCheck: Equatable {
    case upToDate
    case available(version: String, page: URL)
    case noPublicRelease
    case rateLimited(until: Date)
    case unavailable

    private static let latestAPI = URL(string: "https://api.github.com/repos/ixiehao/chengwen/releases/latest")!
    private static let releases = URL(string: "https://github.com/ixiehao/chengwen/releases")!

    static func latest(
        installedVersion: String,
        load: (URLRequest) async throws -> (Data, URLResponse) = fetch
    ) async -> Self {
        guard let installed = components(installedVersion) else { return .unavailable }
        var request = URLRequest(url: latestAPI, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("ChengWen", forHTTPHeaderField: "User-Agent")
        do {
            let (data, reply) = try await load(request)
            guard let response = reply as? HTTPURLResponse, response.url == latestAPI else { return .unavailable }
            if response.statusCode == 404 { return .noPublicRelease }
            if response.statusCode == 429 || (response.statusCode == 403 &&
                (response.value(forHTTPHeaderField: "X-RateLimit-Remaining") == "0" ||
                 response.value(forHTTPHeaderField: "Retry-After") != nil)) {
                let now = Date()
                let retryAfter = response.value(forHTTPHeaderField: "Retry-After").flatMap(UInt.init)
                let reset = response.value(forHTTPHeaderField: "X-RateLimit-Reset").flatMap(UInt.init)
                let retryAt = retryAfter.map { now.addingTimeInterval(TimeInterval($0)) }
                    ?? reset.map { Date(timeIntervalSince1970: TimeInterval($0)) }
                    ?? now.addingTimeInterval(60)
                return .rateLimited(until: max(now.addingTimeInterval(1), retryAt))
            }
            guard response.statusCode == 200,
                  data.count <= 1_048_576,
                  let release = try? JSONDecoder().decode(Release.self, from: data) else { return .unavailable }
            if release.draft || release.prerelease { return .noPublicRelease }
            let tagParts = release.tag_name.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
            guard let baseTag = tagParts.first, let offered = components(String(baseTag)) else { return .unavailable }
            // A preview can still be marked Latest on GitHub by the publisher.
            if tagParts.count == 2 { return tagParts[1].isEmpty ? .unavailable : .noPublicRelease }
            let page = releases.appendingPathComponent("tag").appendingPathComponent(release.tag_name)
            guard release.html_url == page.absoluteString else { return .unavailable }
            let version = offered.map(String.init).joined(separator: ".")
            for architecture in ["arm64", "x86_64"] {
                let name = "chengwen-\(version)-\(architecture).dmg"
                for filename in [name, name + ".sha256"] {
                    let download = releases.appendingPathComponent("download")
                        .appendingPathComponent(release.tag_name).appendingPathComponent(filename)
                    guard release.assets?.contains(where: {
                        $0.name == filename && $0.state == "uploaded" && $0.size > 0 &&
                        $0.browser_download_url == download.absoluteString
                    }) == true else { return .unavailable }
                }
            }
            guard installed.lexicographicallyPrecedes(offered) else { return .upToDate }
            return .available(version: version, page: page)
        } catch {
            return .unavailable
        }
    }

    private static func fetch(_ request: URLRequest) async throws -> (Data, URLResponse) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForResource = 15
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        return try await session.data(for: request)
    }

    private static func components(_ tag: String) -> [UInt]? {
        let parts = (tag.hasPrefix("v") ? tag.dropFirst() : tag[...]).split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        let numbers = parts.compactMap { part -> UInt? in
            guard !part.isEmpty, part.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
            return UInt(part)
        }
        return numbers.count == 3 ? numbers : nil
    }

    private struct Release: Decodable {
        let tag_name: String
        let draft: Bool
        let prerelease: Bool
        let html_url: String?
        let assets: [Asset]?
    }

    private struct Asset: Decodable {
        let name: String
        let state: String
        let size: Int
        let browser_download_url: String
    }
}
