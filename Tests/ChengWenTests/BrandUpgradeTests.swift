import Foundation
import XCTest
@testable import ChengWen

final class BrandUpgradeTests: XCTestCase {
    private func home() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("chengwen-brand-upgrade-" + UUID().uuidString)
    }

    func testFreshInstallUsesNewStoreWithoutCreatingDirectories() {
        let home = home()
        XCTAssertEqual(AppFiles.root(home: home), home.appendingPathComponent("Library/Application Support/澄闻", isDirectory: true))
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.path))
    }

    func testUpgradeRetainsPathScopedSessionKeysAndExistingFiles() throws {
        let home = home(); defer { try? FileManager.default.removeItem(at: home) }
        let legacy = home.appendingPathComponent("Library/Application Support/VmDown", isDirectory: true)
        let new = home.appendingPathComponent("Library/Application Support/澄闻", isDirectory: true)
        // Both locations may exist (for example, tools were installed first).
        try FileManager.default.createDirectory(at: new, withIntermediateDirectories: true)
        try AppFiles.write(["schema": 2, "accounts": ["netease": ["revision": String(repeating: "a", count: 32)]]], name: "accounts.json", at: legacy)
        try AppFiles.write(["recent": ["保留搜索历史"], "directory": "/Volumes/Music/My collection"], name: "settings.json", at: legacy)
        let before = try Data(contentsOf: legacy.appendingPathComponent("accounts.json"))
        let selected = AppFiles.root(home: home)
        XCTAssertEqual(selected, legacy)
        XCTAssertEqual(NativeAccountValidation.candidateAccount(storeURL: selected, platform: "netease", revision: "r"), NativeAccountValidation.candidateAccount(storeURL: legacy, platform: "netease", revision: "r"))
        XCTAssertEqual(try Data(contentsOf: selected.appendingPathComponent("accounts.json")), before)
        let settings = AppSettings(try XCTUnwrap(AppFiles.read("settings.json", at: selected) as? [String: Any]))
        XCTAssertEqual(settings.recent, ["保留搜索历史"])
        XCTAssertEqual(settings.directory, "/Volumes/Music/My collection")
        XCTAssertFalse(FileManager.default.fileExists(atPath: new.appendingPathComponent("accounts.json").path))
    }

    func testLegacyFileDoesNotBecomeStoreAndVaultIdentityStaysCompatible() throws {
        let home = home(); defer { try? FileManager.default.removeItem(at: home) }
        let legacy = home.appendingPathComponent("Library/Application Support/VmDown")
        try FileManager.default.createDirectory(at: legacy.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("unrelated file".utf8).write(to: legacy)
        XCTAssertEqual(AppFiles.root(home: home).lastPathComponent, "澄闻")
        XCTAssertEqual(try String(contentsOf: legacy), "unrelated file")
        XCTAssertEqual(NativeSystemAccountVault.service, "local.vmdown.accounts.v2")
    }
}
