import Foundation
import Security
import XCTest
@testable import ChengWen

private final class SoakSessionVault: NativeSessionVault, NativeAccountVault, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    func load(account: String) throws -> Data? { lock.lock(); defer { lock.unlock() }; return values[account] }
    func save(account: String, data: Data) throws { lock.lock(); values[account] = data; lock.unlock() }
    func delete(account: String) throws { lock.lock(); values.removeValue(forKey: account); lock.unlock() }
    func stage(account: String, data: Data) -> OSStatus { try? save(account: account, data: data); return errSecSuccess }
    func remove(account: String) { try? delete(account: account) }
    var count: Int { lock.lock(); defer { lock.unlock() }; return values.count }
}
private final class SoakClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval = 0
    func read() -> TimeInterval { lock.lock(); defer { lock.unlock() }; return value }
    func advance(to value: TimeInterval) { lock.lock(); self.value = value; lock.unlock() }
}

final class AccountSoakTests: XCTestCase {
    private func root() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("chengwen-account-soak-" + UUID().uuidString) }
    private var profile: [String: Any] { ["code": 200, "account": ["id": 123], "profile": ["userId": 123, "nickname": "Synthetic soak"]] }
    private func candidate(_ store: NativeSessionStore) throws -> [String: Any] {
        let revision = String(repeating: "c", count: 32)
        let value: [String: Any] = ["cookies": [["name": "MUSIC_U", "value": "synthetic-soak-only", "domain": ".music.163.com", "path": "/"]], "user_agent": "Synthetic Soak UA", "revision": revision, "staged_at": Date().timeIntervalSince1970, "native_identity": ["code": 200, "origin": "https://music.163.com", "uid": "123", "profile_uid": "123", "verified": true]]
        try store.vault.save(account: store.key("netease", revision), data: JSONSerialization.data(withJSONObject: value))
        return ["store": store.root.path, "platform": "netease", "revision": revision]
    }
    func testLogoutWhileActivationWaitsForGateMustInvalidateThatCandidate() async throws {
        let root = root(), vault = SoakSessionVault(), profile = self.profile
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NativeSessionStore(root: root, vault: vault, api: { _, _, _, _ in profile })
        let payload = try candidate(store), gate = store.root.path + ":netease"
        try await NativeAccountGate.shared.acquire(gate)
        let activation = Task { try await store.perform("activate_account", payload: payload) }
        // The gate remains owned, so this candidate cannot validate or commit.
        try await Task.sleep(nanoseconds: 80_000_000)
        try store.logout("netease")
        await NativeAccountGate.shared.release(gate)
        do {
            _ = try await activation.value
            XCTFail("A queued pre-logout activation must not resurrect the account")
        } catch let error as EngineFailure { XCTAssertEqual(error.code, "account_changed") }
        XCTAssertTrue(store.references().isEmpty)
        XCTAssertEqual(vault.count, 0)
    }
    func testRiskPauseSurvivesFailureToPersistTheBlockFile() async throws {
        let root = root(), vault = SoakSessionVault()
        defer { try? FileManager.default.removeItem(at: root) }
        var requests = 0
        let store = NativeSessionStore(root: root, vault: vault, api: { _, _, _, _ in
            requests += 1
            return ["code": -462]
        })
        _ = try candidate(store)
        let revision = String(repeating: "c", count: 32)
        try AppFiles.write(["schema": 2, "accounts": ["netease": ["revision": revision, "storage": "revision"]]], name: "accounts.json", at: root)
        let reference = try XCTUnwrap(store.references()["netease"])
        // A directory at the file destination deterministically rejects the
        // atomic persistence without modifying host permissions or Keychain.
        try FileManager.default.createDirectory(at: root.appendingPathComponent("account-blocks.json"), withIntermediateDirectories: false)
        for _ in 0..<2 {
            do {
                _ = try await NativeAccountAdapters.request(URL(string: "https://music.163.com/api/w/nuser/account/get")!, reference: reference, store: store)
                XCTFail("Risk challenge must stop the operation")
            } catch let error as EngineFailure { XCTAssertEqual(error.code, "account_risk") }
        }
        XCTAssertEqual(requests, 1, "A disk failure must not permit repeated requests after risk detection")
        XCTAssertEqual(NativeSessionStore.inMemoryPauseCode(storeURL: root, platform: "netease", revision: revision), "account_risk")
        XCTAssertNil(NativeSessionStore.inMemoryPauseCode(storeURL: root, platform: "netease", revision: String(repeating: "a", count: 32)))
        try store.logout("netease")
        XCTAssertNil(NativeSessionStore.inMemoryPauseCode(storeURL: root, platform: "netease", revision: revision))
    }
    func testSixtyFourCancelledGateWaitersNeverEnterAndDoNotSkipCooldown() async throws {
        let gate = NativeAccountGate(), key = UUID().uuidString
        try await gate.acquire(key)
        let waiters = (0..<64).map { _ in Task { () -> Bool in
            do { try await gate.acquire(key); await gate.release(key); return true }
            catch is CancellationError { return false }
            catch { XCTFail("Unexpected gate error: \(error)"); return true }
        } }
        waiters.forEach { $0.cancel() }
        for waiter in waiters { let entered = await waiter.value; XCTAssertFalse(entered) }
        await gate.release(key)
        let began = ProcessInfo.processInfo.systemUptime
        try await gate.acquire(key)
        XCTAssertGreaterThanOrEqual(ProcessInfo.processInfo.systemUptime - began, 1.8, "Cancellation cannot bypass the production two-second spacing")
        await gate.release(key)
    }
    func testGateQueueDeadlineUsesMonotonicBudgetWithoutWaitingThirtyFiveSeconds() async throws {
        let clock = SoakClock(), gate = NativeAccountGate(now: { clock.read() }), key = UUID().uuidString
        try await gate.acquire(key)
        let waiter = Task { () -> String in
            do { try await gate.acquire(key); await gate.release(key); return "unexpected-entry" }
            catch let error as EngineFailure { return error.code }
            catch { return "unexpected-error" }
        }
        try await Task.sleep(nanoseconds: 80_000_000)
        clock.advance(to: 36)
        let code = await waiter.value
        XCTAssertEqual(code, "account_busy")
        await gate.release(key)
    }
    func testSuccessfulReconnectionClearsOnlyTheOlderInMemoryPause() throws {
        let root = root(), vault = SoakSessionVault()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NativeSessionStore(root: root, vault: vault, api: { _, _, _, _ in XCTFail("No request expected"); return [:] })
        _ = try candidate(store)
        let revision = String(repeating: "c", count: 32)
        let previous: [String: Any] = ["revision": revision, "storage": "revision"]
        try AppFiles.write(["schema": 2, "accounts": ["netease": previous]], name: "accounts.json", at: root)
        let reference = try XCTUnwrap(store.references()["netease"])
        try FileManager.default.createDirectory(at: root.appendingPathComponent("account-blocks.json"), withIntermediateDirectories: false)
        XCTAssertThrowsError(try store.block(reference))
        XCTAssertEqual(NativeSessionStore.inMemoryPauseCode(storeURL: root, platform: "netease", revision: revision), "account_risk")
        let payload = try XCTUnwrap(vault.load(account: store.key("netease", revision)))
        let secret = try XCTUnwrap(JSONSerialization.jsonObject(with: payload) as? [String: Any])
        _ = try store.connect("netease", payload: secret, profile: ["nickname": "New synthetic connection"], previous: previous, expectedEpoch: "")
        let current = try XCTUnwrap(store.references()["netease"])
        XCTAssertNoThrow(try store.assertCurrent(current))
        XCTAssertThrowsError(try store.assertCurrent(reference))
        XCTAssertNil(NativeSessionStore.inMemoryPauseCode(storeURL: root, platform: "netease", revision: revision))
        XCTAssertEqual(vault.count, 1)
    }
    @MainActor func testFortyClosedCandidateModelsCleanUpAndReleaseWithoutActivation() async throws {
        let root = root(), vault = SoakSessionVault()
        defer { try? FileManager.default.removeItem(at: root) }
        let identity: [String: Any] = ["code": 200, "uid": "123", "profile_uid": "123", "origin": "https://music.163.com", "nickname": "Synthetic", "userAgent": "Synthetic Soak UA"]
        let cookie = try XCTUnwrap(HTTPCookie(properties: [.name: "MUSIC_U", .value: "synthetic-soak-only", .domain: ".music.163.com", .path: "/"]))
        let weakModels = NSHashTable<NativeAccountViewModel>.weakObjects()
        let cleaned = expectation(description: "All closed candidates settle"); cleaned.expectedFulfillmentCount = 40
        var activations = 0, notifications = 0
        for _ in 0..<40 {
            let model = NativeAccountViewModel(platform: "netease", storeURL: root, request: { _, _, _, _ in activations += 1; return {} }, vault: vault, autoLoadWeb: false, ownedSessionReader: { $0(.success(NativeOwnedAccountSession(identityResponse: identity, cookies: [cookie]))) }, onChange: { notifications += 1 })
            weakModels.add(model)
            model.connectOwnedWebSession(); model.close(); model.close(); model.connectOwnedWebSession()
            model.finishCandidateCleanup { cleaned.fulfill() }
        }
        await fulfillment(of: [cleaned], timeout: 5)
        try await Task.sleep(nanoseconds: 40_000_000)
        XCTAssertEqual(activations, 0)
        XCTAssertEqual(notifications, 40)
        XCTAssertEqual(vault.count, 0)
        XCTAssertTrue(weakModels.allObjects.isEmpty, "Closed candidate models must not be retained by staging callbacks")
    }
    func testInvalidRiskReferencesNeverBlockTheCurrentAccount() throws {
        let root = root(), vault = SoakSessionVault()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NativeSessionStore(root: root, vault: vault, api: { _, _, _, _ in XCTFail("No request expected"); return [:] })
        _ = try candidate(store)
        let revision = String(repeating: "c", count: 32)
        try AppFiles.write(["schema": 2, "accounts": ["netease": ["revision": revision, "storage": "revision"]]], name: "accounts.json", at: root)
        let current = try XCTUnwrap(store.references()["netease"])
        for invalid: [String: Any] in [[:], ["platform": "other"], ["platform": "netease", "revision": revision], ["platform": "netease", "revision": revision, "store": root.appendingPathComponent("different").path]] {
            XCTAssertNoThrow(try store.block(invalid))
        }
        XCTAssertNoThrow(try store.assertCurrent(current))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("account-blocks.json").path))
    }
}
