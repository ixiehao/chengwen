import Foundation

/// Shared by the native UI and engine, including source builds without an app plist.
/// Packaging verifies this resource against the distributed Info.plist.
enum AppVersion {
    private static let metadata: [String: String] = {
        guard let url = Bundle.module.resourceURL?.appendingPathComponent("Resources/Version.json"),
              let data = try? Data(contentsOf: url),
              let values = try? JSONSerialization.jsonObject(with: data) as? [String: String] else { return [:] }
        return values
    }()
    static let current = metadata["version"] ?? "development"
    static let build = metadata["build"] ?? "unknown"
}
