import Foundation
import XCTest
@testable import ChengWen

final class NativeHistoryStoreTests: XCTestCase {
    private func temporaryRoot() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("chengwen-history-test-" + UUID().uuidString) }
    private func record(_ id: String = "legacy-task", state: String = "completed") -> [String: Any] {
        ["id": id, "track": ["id": "song", "title": "Synthetic title", "source": "netease"], "state": state, "format": "mp3", "directory": "/tmp", "path": "/tmp/synthetic.mp3"]
    }
    private func backups(_ root: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix("history-recovery-") }
    }
    func testLegacyArrayMigratesToVersionedPrivateAtomicHistoryWithoutChangingOrder() throws {
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        try AppFiles.write([record("one"), record("two", state: "downloading")], name: "history.json", at: root)
        let store = NativeHistoryStore(root: root), restored = store.load()
        XCTAssertNil(restored.warning); XCTAssertFalse(store.writesBlocked)
        XCTAssertEqual(restored.jobs.map(\.id), ["one", "two"])
        XCTAssertEqual(restored.jobs[1].state, "interrupted")
        try store.save(restored.jobs)
        let object = try XCTUnwrap(AppFiles.read("history.json", at: root) as? [String: Any])
        XCTAssertEqual(object["schema"] as? Int, NativeHistoryStore.schema)
        XCTAssertEqual((object["jobs"] as? [[String: Any]])?.compactMap { $0["id"] as? String }, ["one", "two"])
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: root.path)[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("history.json").path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix(".history-write-") })
        XCTAssertEqual(NativeHistoryStore(root: root).load().jobs.map(\.id), ["one", "two"])
    }
    @MainActor func testActualAppModelStartupRepairsDuplicateAndEmptyIDsBeforeDisplayingHistory() throws {
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        var missing = record(); missing.removeValue(forKey: "id")
        var unknown = record("unknown", state: "future-state"); unknown["format"] = "bad-format"; unknown["retry_count"] = -3
        try AppFiles.write([record("duplicate"), record("duplicate"), record(""), record("   "), missing, unknown], name: "history.json", at: root)
        let model = AppModel(storeURL: root, engine: BackendClient { _, _, _ in XCTFail("History startup must not issue requests"); return [:] })
        defer { model.shutdown() }
        XCTAssertEqual(model.jobs.count, 6)
        XCTAssertEqual(Set(model.jobs.map(\.id)).count, 6)
        XCTAssertTrue(model.jobs.allSatisfy { !$0.id.isEmpty })
        XCTAssertEqual(model.jobs.first?.id, "duplicate")
        XCTAssertEqual(model.jobs.last?.state, "interrupted")
        XCTAssertEqual(model.jobs.last?.format, "mp3")
        XCTAssertEqual(model.jobs.last?.retryCount, 0)
        XCTAssertTrue(model.notice.contains("已修复"))
        model.shutdown()
        let restored = AppModel(storeURL: root, engine: BackendClient { _, _, _ in XCTFail("History reload must remain local"); return [:] })
        defer { restored.shutdown() }
        XCTAssertEqual(restored.jobs.map(\.id), model.jobs.map(\.id), "Repaired identifiers must persist instead of changing at every launch")
    }
    func testMalformedFutureAndInvalidRecordDocumentsArePreservedBeforeNewWrites() throws {
        let cases: [Data] = [
            Data("{malformed-json".utf8),
            try JSONSerialization.data(withJSONObject: ["schema": 2, "jobs": [record()]]),
            try JSONSerialization.data(withJSONObject: ["schema": true, "jobs": []]),
            try JSONSerialization.data(withJSONObject: ["schema": 1, "jobs": [["id": "missing-track"]]]),
        ]
        for original in cases {
            let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try original.write(to: root.appendingPathComponent("history.json"))
            let store = NativeHistoryStore(root: root), loaded = store.load()
            XCTAssertTrue(loaded.jobs.isEmpty); XCTAssertNotNil(loaded.warning); XCTAssertFalse(store.writesBlocked)
            let backup = try XCTUnwrap(backups(root).first)
            XCTAssertEqual(try Data(contentsOf: backup), original)
            XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: backup.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("history.json").path))
            try store.save([])
            XCTAssertEqual(try Data(contentsOf: backup), original, "Saving a fresh list must not overwrite the preserved original")
        }
    }
    func testOversizedSparseHistoryIsPreservedWithoutReadingAnUnboundedFile() throws {
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("history.json")
        XCTAssertTrue(FileManager.default.createFile(atPath: file.path, contents: nil))
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: UInt64(NativeHistoryStore.maximumBytes + 1)); try handle.close()
        let store = NativeHistoryStore(root: root), loaded = store.load()
        XCTAssertTrue(loaded.jobs.isEmpty); XCTAssertNotNil(loaded.warning); XCTAssertFalse(store.writesBlocked)
        let backup = try XCTUnwrap(backups(root).first)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: backup.path)[.size] as? NSNumber)?.intValue, NativeHistoryStore.maximumBytes + 1)
    }
    @MainActor func testFailedRecoveryBlocksAllHistoryReplacementAndShowsModelWarning() throws {
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let original = Data("{original-corrupt-history".utf8), file = root.appendingPathComponent("history.json")
        try original.write(to: file)
        let store = NativeHistoryStore(root: root, moveForRecovery: { _, _ in throw POSIXError(.EACCES) })
        let model = AppModel(storeURL: root, engine: BackendClient { _, _, _ in XCTFail("Recovery must not execute requests"); return [:] }, historyStore: store)
        XCTAssertTrue(store.writesBlocked); XCTAssertTrue(model.notice.contains("暂停保存"))
        XCTAssertThrowsError(try store.save([]))
        model.clearFinishedJobs()
        XCTAssertTrue(model.notice.contains("未能保存"))
        model.shutdown()
        XCTAssertEqual(try Data(contentsOf: file), original)
        XCTAssertTrue(try backups(root).isEmpty)
    }
    @MainActor func testFailedClearRetainsRowsAndVisibleFailureInsteadOfPretendingToClear() throws {
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        try AppFiles.write([record()], name: "history.json", at: root)
        let before = try Data(contentsOf: root.appendingPathComponent("history.json"))
        let store = NativeHistoryStore(root: root, atomicWriter: { _, _ in throw POSIXError(.ENOSPC) })
        let model = AppModel(storeURL: root, engine: BackendClient { _, _, _ in XCTFail("Clearing records must remain local"); return [:] }, historyStore: store)
        model.clearFinishedJobs()
        XCTAssertEqual(model.jobs.count, 1); XCTAssertEqual(model.completedJobCount, 1)
        XCTAssertTrue(model.notice.contains("下载记录未能保存"))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("history.json")), before)
        model.shutdown()
    }
    func testSymlinkHistoryNeverReadsOrOverwritesItsTarget() throws {
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let target = root.appendingPathComponent("target.json"), bytes = Data("keep synthetic target".utf8)
        try bytes.write(to: target)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("history.json"), withDestinationURL: target)
        let store = NativeHistoryStore(root: root), loaded = store.load()
        XCTAssertTrue(loaded.jobs.isEmpty); XCTAssertNotNil(loaded.warning); XCTAssertTrue(store.writesBlocked)
        XCTAssertThrowsError(try store.save([]))
        XCTAssertEqual(try Data(contentsOf: target), bytes)
        XCTAssertTrue(try backups(root).isEmpty)
    }
    func testHistoryRetentionKeepsNewestFiveHundredAndFailedWriteLeavesNoTemporaryFile() throws {
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let jobs = (0..<510).map { DownloadJob(history: record("task-\($0)"))! }
        let store = NativeHistoryStore(root: root)
        try store.save(jobs)
        let restored = store.load().jobs
        XCTAssertEqual(restored.count, 500); XCTAssertEqual(restored.first?.id, "task-10"); XCTAssertEqual(restored.last?.id, "task-509")
        // An unexpected directory at the destination is never replaced.
        try FileManager.default.removeItem(at: root.appendingPathComponent("history.json"))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("history.json"), withIntermediateDirectories: false)
        XCTAssertThrowsError(try store.save([]))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix(".history-write-") })
    }
    func testHistoryRetentionNeverEvictsOlderActiveTasks() throws {
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        var active = DownloadJob(history: record("older-active"))!
        active.state = "downloading"
        let finished = (0..<510).map { DownloadJob(history: record("finished-\($0)"))! }
        let store = NativeHistoryStore(root: root)
        try store.save([active] + finished)
        let restored = store.load().jobs
        XCTAssertEqual(restored.count, 501)
        XCTAssertEqual(restored.first?.id, "older-active")
        XCTAssertEqual(restored.first?.state, "interrupted")
        XCTAssertEqual(restored.dropFirst().first?.id, "finished-10")
        XCTAssertEqual(restored.last?.id, "finished-509")
        try store.save(restored)
        XCTAssertEqual(store.load().jobs.map(\.id), restored.map(\.id), "An interrupted task must survive the next save too")
    }
    func testTooManyActiveTasksCannotWriteAnUnreadableOversizedHistory() throws {
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let store = NativeHistoryStore(root: root)
        try store.save([DownloadJob(history: record("original"))!])
        let before = try Data(contentsOf: root.appendingPathComponent("history.json"))
        let jobs = (0...NativeHistoryStore.maximumRecords).map { index -> DownloadJob in
            var job = DownloadJob(history: record("active-\(index)"))!
            job.state = "queued"
            return job
        }
        XCTAssertThrowsError(try store.save(jobs))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("history.json")), before)
        XCTAssertEqual(store.load().jobs.map(\.id), ["original"])
    }
}
