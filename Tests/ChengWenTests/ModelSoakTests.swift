import Foundation
import XCTest
@testable import ChengWen

private final class ModelSoakLedger: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var finished = 0
    func enter() { lock.lock(); count += 1; lock.unlock() }
    func leave() { lock.lock(); finished += 1; lock.unlock() }
    var drained: Bool { lock.lock(); defer { lock.unlock() }; return count == finished }
    var requests: Int { lock.lock(); defer { lock.unlock() }; return count }
}

private final class ModelPauseFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var entered = Set<String>()
    private var risk = false
    private var finish = false
    func start(_ id: String) { lock.lock(); entered.insert(id); lock.unlock() }
    func releaseRisk() { lock.lock(); risk = true; lock.unlock() }
    func releaseRemaining() { lock.lock(); finish = true; lock.unlock() }
    var riskReleased: Bool { lock.lock(); defer { lock.unlock() }; return risk }
    var mayFinish: Bool { lock.lock(); defer { lock.unlock() }; return finish }
    var started: Set<String> { lock.lock(); defer { lock.unlock() }; return entered }
}

final class ModelSoakTests: XCTestCase {
    @MainActor private func eventually(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(4)
        while !condition() && Date() < deadline { try await Task.sleep(nanoseconds: 2_000_000) }
        XCTAssertTrue(condition(), "Isolated model did not settle")
    }
    private func track(_ id: String) -> AudioTrack {
        AudioTrack(raw: ["id": id, "title": "Synthetic " + id, "source": "qq", "url": "https://example.invalid/owned-fixture"])
    }
    private func accountTrack(_ id: String, source: String = "netease") -> AudioTrack {
        AudioTrack(raw: ["id": id, "title": "Synthetic " + id, "source": source, "url": "https://example.invalid/owned-fixture"])
    }
    private func pausedRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("chengwen-model-pause-soak-" + UUID().uuidString)
        try AppFiles.write(["schema": 2, "accounts": ["netease": ["revision": String(repeating: "a", count: 32), "nickname": "Synthetic memory-only account"]]], name: "accounts.json", at: root)
        // A directory where the metadata file belongs forces only the pause
        // write to fail. No real Keychain call is needed to exercise block().
        try FileManager.default.createDirectory(at: root.appendingPathComponent("account-blocks.json"), withIntermediateDirectories: false)
        return root
    }
    @MainActor func testRefreshAccountsDisplaysInMemoryRiskPauseWhenMetadataWriteFails() throws {
        let root = try pausedRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(storeURL: root, engine: BackendClient { _, _, _ in XCTFail("Metadata refresh must not request secrets"); return [:] })
        defer { model.shutdown() }
        model.refreshAccounts(); XCTAssertEqual(model.accounts["netease"]?.blocked, false)
        let store = NativeSessionStore(root: root)
        let ref = try XCTUnwrap(store.references()["netease"])
        XCTAssertThrowsError(try store.block(ref))
        model.refreshAccounts()
        XCTAssertEqual(model.accounts["netease"]?.blocked, true, "A failed metadata write cannot hide the engine's process-local pause")
    }
    @MainActor func testRiskProbeCancelsOnlyMatchingAccountAndContinuesOtherSource() async throws {
        let root = try pausedRoot(), fixture = ModelPauseFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let backend = BackendClient { operation, payload, _ in
            XCTAssertEqual(operation, "probe")
            let raw = payload["track"] as! [String: Any], id = raw["id"] as! String
            fixture.start(id)
            if id == "risk" {
                while !fixture.riskReleased { try await Task.sleep(nanoseconds: 1_000_000) }
                let ref = (raw["metadata"] as! [String: Any])["account_ref"] as! [String: Any]
                try? NativeSessionStore(root: root).block(ref)
                throw NativeSessionStore.auth("Synthetic risk pause", code: "account_risk")
            }
            if id == "sibling" { try await Task.sleep(nanoseconds: 10_000_000_000) }
            return ["sample_bytes": 4096]
        }
        let model = AppModel(storeURL: root, engine: backend); defer { model.shutdown() }
        model.refreshAccounts(); model.settings.useConnectedAccounts = true
        model.tracks = [accountTrack("risk"), accountTrack("sibling"), accountTrack("queued"), accountTrack("other", source: "qq")]
        model.selection = Set(model.tracks.map(\.id)); model.probeSelected()
        try await eventually { fixture.started.count == 2 }
        fixture.releaseRisk()
        let deadline = Date().addingTimeInterval(1)
        while model.isProbing && Date() < deadline { try await Task.sleep(nanoseconds: 2_000_000) }
        XCTAssertFalse(model.isProbing, "Risk must revoke the sibling rather than wait for another platform request")
        XCTAssertEqual(model.accounts["netease"]?.blocked, true)
        XCTAssertEqual(model.probes["other"]?.state, "passed")
        XCTAssertFalse(fixture.started.contains("queued"), "A queued request using the paused account must not start")
    }
    @MainActor func testRiskDownloadCancelsMatchingRevisionButKeepsAnonymousAndOtherSource() async throws {
        let root = try pausedRoot(), fixture = ModelPauseFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let backend = BackendClient { operation, payload, _ in
            XCTAssertEqual(operation, "download")
            let raw = payload["track"] as! [String: Any], id = raw["id"] as! String
            fixture.start(id)
            if id == "risk" {
                while !fixture.riskReleased { try await Task.sleep(nanoseconds: 1_000_000) }
                let ref = (raw["metadata"] as! [String: Any])["account_ref"] as! [String: Any]
                try? NativeSessionStore(root: root).block(ref)
                throw NativeSessionStore.auth("Synthetic risk pause", code: "account_risk")
            }
            while !fixture.mayFinish { try await Task.sleep(nanoseconds: 1_000_000) }
            return ["path": "/tmp/synthetic-no-file-\(id).mp3"]
        }
        let model = AppModel(storeURL: root, engine: backend); defer { model.shutdown() }
        model.refreshAccounts(); model.settings.concurrency = 4; model.settings.useConnectedAccounts = true
        model.downloadTrack(accountTrack("risk")); model.downloadTrack(accountTrack("sibling"))
        model.settings.useConnectedAccounts = false; model.downloadTrack(accountTrack("anonymous"))
        model.downloadTrack(accountTrack("other", source: "qq")); model.settings.useConnectedAccounts = true
        try await eventually { fixture.started.count == 4 }
        fixture.releaseRisk()
        try await eventually { model.jobs.first { $0.track.id == "risk" }?.state == "failed" }
        try await Task.sleep(nanoseconds: 25_000_000)
        XCTAssertEqual(model.accounts["netease"]?.blocked, true)
        XCTAssertEqual(model.jobs.first { $0.track.id == "sibling" }?.state, "cancelled")
        XCTAssertEqual(model.jobs.first { $0.track.id == "anonymous" }?.state, "downloading")
        XCTAssertEqual(model.jobs.first { $0.track.id == "other" }?.state, "downloading")
        fixture.releaseRemaining()
        try await eventually { model.activeJobCount == 0 }
        XCTAssertEqual(model.completedJobCount, 2)
    }
    @MainActor func testRiskCancellationPreservesSiblingThatAlreadyCommittedSuccessfully() async throws {
        let root = try pausedRoot(), fixture = ModelPauseFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let backend = BackendClient { _, payload, _ in
            let raw = payload["track"] as! [String: Any], id = raw["id"] as! String
            fixture.start(id)
            if id == "risk" {
                while !fixture.riskReleased { try await Task.sleep(nanoseconds: 1_000_000) }
                let ref = (raw["metadata"] as! [String: Any])["account_ref"] as! [String: Any]
                try? NativeSessionStore(root: root).block(ref)
                throw NativeSessionStore.auth("Synthetic risk pause", code: "account_risk")
            }
            do { try await Task.sleep(nanoseconds: 10_000_000_000) } catch is CancellationError {
                // Synthetic trusted-engine commit already occurred before the
                // cancellation was observed; BackendClient must preserve it.
                return ["path": "/tmp/synthetic-committed-before-pause.mp3"]
            }
            return [:]
        }
        let model = AppModel(storeURL: root, engine: backend); defer { model.shutdown() }
        model.refreshAccounts(); model.settings.concurrency = 2; model.settings.useConnectedAccounts = true
        model.downloadTrack(accountTrack("risk")); model.downloadTrack(accountTrack("committed"))
        try await eventually { fixture.started.count == 2 }; fixture.releaseRisk()
        try await eventually { model.activeJobCount == 0 }
        XCTAssertEqual(model.accounts["netease"]?.blocked, true)
        XCTAssertEqual(model.jobs.first { $0.track.id == "committed" }?.state, "completed")
        XCTAssertEqual(model.jobs.first { $0.track.id == "committed" }?.path, "/tmp/synthetic-committed-before-pause.mp3")
    }
    @MainActor func testOldRiskReplyCannotPauseOrCancelReplacementAccount() async throws {
        let root = try pausedRoot(), fixture = ModelPauseFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NativeSessionStore(root: root), old = try XCTUnwrap(store.references()["netease"])
        let backend = BackendClient { _, payload, _ in
            let raw = payload["track"] as! [String: Any], id = raw["id"] as! String
            fixture.start(id)
            if id == "old" {
                while !fixture.riskReleased { await Task.yield() }
                throw NativeSessionStore.auth("Late synthetic old-account risk", code: "account_risk")
            }
            while !fixture.mayFinish { try await Task.sleep(nanoseconds: 1_000_000) }
            return ["path": "/tmp/synthetic-new-account.mp3"]
        }
        let model = AppModel(storeURL: root, engine: backend); defer { model.shutdown() }
        model.refreshAccounts(); model.settings.concurrency = 2; model.settings.useConnectedAccounts = true
        model.downloadTrack(accountTrack("old")); try await eventually { fixture.started.contains("old") }
        try? store.block(old)
        try AppFiles.write(["schema": 2, "accounts": ["netease": ["revision": String(repeating: "b", count: 32)]]], name: "accounts.json", at: root)
        model.accountChanged("netease"); model.downloadTrack(accountTrack("new"))
        try await eventually { fixture.started.contains("new") }; fixture.releaseRisk()
        try await eventually { model.jobs.first { $0.track.id == "old" }?.state == "cancelled" }
        XCTAssertEqual(model.accounts["netease"]?.blocked, false)
        XCTAssertEqual(model.jobs.first { $0.track.id == "new" }?.state, "downloading")
        fixture.releaseRemaining(); try await eventually { model.completedJobCount == 1 }
    }
    @MainActor func testFiftyCompleteSearchDownloadNoticeShutdownCyclesReleaseModels() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("chengwen-model-soak-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let ledger = ModelSoakLedger()
        for iteration in 0..<50 {
            let song = track("round-\(iteration)")
            let backend = BackendClient { operation, _, event in
                ledger.enter(); defer { ledger.leave() }
                try await Task.sleep(nanoseconds: 1_000_000)
                switch operation {
                case "search": event("track", song.raw); return ["count": 1]
                case "download": event("progress", ["percent": 100]); return ["path": "/tmp/synthetic-no-file-\(iteration).mp3"]
                case "health": return ["items": []]
                default: XCTFail("Unexpected operation \(operation)"); return [:]
                }
            }
            var model: AppModel? = AppModel(storeURL: root.appendingPathComponent("round-\(iteration)"), engine: backend)
            weak var observed = model
            model!.settings.sources = ["qq"]; model!.keyword = "Synthetic \(iteration)"; model!.search(); model!.checkEnvironment()
            try await eventually { model?.isSearching == false && model?.isCheckingEnvironment == false }
            XCTAssertEqual(model!.tracks.map(\.id), [song.id])
            model!.selection = [song.id]; model!.downloadSelected()
            try await eventually { model?.completedJobCount == 1 }
            model!.notice = "Synthetic transient notice"
            model!.shutdown(); model = nil
            XCTAssertNil(observed, "Completed requests and notice timers must not retain a retired model")
            observed = nil
            await withCheckedContinuation { continuation in backend.shutdown { continuation.resume() } }
        }
        XCTAssertTrue(ledger.drained); XCTAssertEqual(ledger.requests, 150)
    }
    @MainActor func testSixtyAbandonedModelsWithPendingSearchProbeAndNoticeRelease() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("chengwen-abandoned-model-soak-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let ledger = ModelSoakLedger()
        for iteration in 0..<60 {
            let backend = BackendClient { _, _, event in
                ledger.enter(); defer { ledger.leave() }
                try? await Task.sleep(nanoseconds: 5_000_000)
                event("track", ["id": "late", "source": "qq"])
                return ["count": 1]
            }
            var model: AppModel? = AppModel(storeURL: root.appendingPathComponent("round-\(iteration)"), engine: backend)
            weak var observed = model
            model!.settings.sources = ["qq"]; model!.keyword = "Synthetic pending"; model!.search()
            model!.probeTrack(track("probe-\(iteration)")); model!.notice = "Synthetic pending notice"
            if iteration % 2 == 0 { model!.shutdown() }
            model = nil
            XCTAssertNil(observed, "Pending weak callbacks must not keep their model alive")
            await withCheckedContinuation { continuation in backend.shutdown { continuation.resume() } }
            XCTAssertNil(observed)
            observed = nil
        }
        XCTAssertTrue(ledger.drained)
    }
}
