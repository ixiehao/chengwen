import Foundation
import XCTest
@testable import ChengWen

private final class SchedulerStressLedger: @unchecked Sendable {
    private let lock = NSLock()
    private var keys: [String] = []
    private var current = 0
    private var peak = 0
    private var permits = Set<String>()
    private var releaseAll = false
    func enter(_ key: String) { lock.lock(); keys.append(key); current += 1; peak = max(peak, current); lock.unlock() }
    func leave() { lock.lock(); current -= 1; lock.unlock() }
    func release(_ key: String) { lock.lock(); permits.insert(key); lock.unlock() }
    func finishAll() { lock.lock(); releaseAll = true; lock.unlock() }
    func mayFinish(_ key: String) -> Bool { lock.lock(); defer { lock.unlock() }; return releaseAll || permits.contains(key) }
    var started: [String] { lock.lock(); defer { lock.unlock() }; return keys }
    var maximum: Int { lock.lock(); defer { lock.unlock() }; return peak }
    var active: Int { lock.lock(); defer { lock.unlock() }; return current }
}

private actor SchedulerReplyGate {
    private var waiting: [CheckedContinuation<Void, Never>] = []
    func wait() async { await withCheckedContinuation { waiting.append($0) } }
    func release() { let values = waiting; waiting = []; values.forEach { $0.resume() } }
    var count: Int { waiting.count }
}

private final class RetryStormEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [(String, [String: Any]) -> Void] = []
    func add(_ event: @escaping (String, [String: Any]) -> Void) -> Int { lock.lock(); defer { lock.unlock() }; events.append(event); return events.count - 1 }
    var count: Int { lock.lock(); defer { lock.unlock() }; return events.count }
    func floodStale() -> Int {
        lock.lock(); let stale = Array(events.dropLast()); lock.unlock()
        for event in stale { event("progress", ["stage": "converting", "percent": 99, "detail": "STALE RETRY EVENT"]) }
        return stale.count
    }
}

private final class BackendStressResults: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = Set<Int>()
    private var duplicates = 0
    private var lateEvents = 0
    func event(_ id: Int) { lock.lock(); if completed.contains(id) { lateEvents += 1 }; lock.unlock() }
    func finish(_ id: Int) { lock.lock(); if !completed.insert(id).inserted { duplicates += 1 }; lock.unlock() }
    var summary: (Int, Int, Int) { lock.lock(); defer { lock.unlock() }; return (completed.count, duplicates, lateEvents) }
}

final class SchedulerStressTests: XCTestCase {
    private func root() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("chengwen-scheduler-stress-" + UUID().uuidString) }
    private func track(_ id: String) -> AudioTrack { AudioTrack(raw: ["id": id, "title": "Synthetic " + id, "source": "qq", "url": "https://example.invalid/catalog-only"]) }
    @MainActor private func eventually(timeout: Double = 10, _ predicate: () -> Bool) async throws {
        let end = Date().addingTimeInterval(timeout)
        while !predicate() && Date() < end { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertTrue(predicate(), "Isolated stress fixture did not reach its required terminal state")
    }

    @MainActor func testShutdownRejectsRepeatedStaleRequestActionsAndDoesNotRequeueHistory() async throws {
        let root = root(), calls = SchedulerStressLedger()
        defer { try? FileManager.default.removeItem(at: root) }
        let backend = BackendClient { operation, _, _ in calls.enter(operation); defer { calls.leave() }; return ["count": 0] }
        let model = AppModel(storeURL: root, engine: backend)
        let song = track("stale-after-shutdown")
        var job = DownloadJob(track: song, format: "mp3", directory: root.path, lyrics: false)
        job.state = "failed"; model.jobs = [job]; model.tracks = [song]; model.selection = [song.id]
        model.shutdown()
        for _ in 0..<40 {
            model.keyword = "Stale synthetic search"; model.search()
            model.start(); model.checkEnvironment()
            model.probeSelected(); model.downloadSelected(); model.downloadTrack(song); model.retryJob(job.id)
            model.checkAccount("netease"); model.disconnectAccount("kuwo")
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(calls.started.isEmpty, "Stale window actions cannot create engine work after model shutdown")
        XCTAssertEqual(model.jobs.count, 1)
        XCTAssertEqual(model.jobs.first?.state, "failed", "A closed model cannot silently queue an unschedulable retry")
        XCTAssertFalse(model.isSearching); XCTAssertFalse(model.isProbing); XCTAssertFalse(model.isCheckingEnvironment)
    }

    @MainActor func testLateHealthReplyCannotRepopulateClosedModel() async throws {
        let root = root(), gate = SchedulerReplyGate()
        defer { try? FileManager.default.removeItem(at: root) }
        let backend = BackendClient { operation, _, _ in
            XCTAssertEqual(operation, "health")
            await gate.wait()
            return ["items": [["key": "late", "title": "Late synthetic tool", "state": "ready"]]]
        }
        let model = AppModel(storeURL: root, engine: backend)
        model.checkEnvironment()
        let end = Date().addingTimeInterval(3)
        while await gate.count == 0 && Date() < end { try await Task.sleep(nanoseconds: 5_000_000) }
        let waiting = await gate.count; XCTAssertEqual(waiting, 1)
        model.shutdown(); await gate.release()
        try await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertFalse(model.isCheckingEnvironment)
        XCTAssertTrue(model.healthItems.isEmpty, "An obsolete health reply cannot replace the closed model's display")
    }

    @MainActor func testLateAccountFailureCannotReopenClosedModelNotice() async throws {
        let root = root(), gate = SchedulerReplyGate()
        defer { try? FileManager.default.removeItem(at: root) }
        let backend = BackendClient { operation, _, _ in
            XCTAssertEqual(operation, "account")
            await gate.wait()
            throw EngineFailure(reason: "Obsolete synthetic account failure", code: "account_response")
        }
        let model = AppModel(storeURL: root, engine: backend)
        model.checkAccount("netease")
        let end = Date().addingTimeInterval(3)
        while await gate.count == 0 && Date() < end { try await Task.sleep(nanoseconds: 5_000_000) }
        let waiting = await gate.count; XCTAssertEqual(waiting, 1)
        model.notice = "退出前提示"; model.shutdown(); await gate.release()
        try await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertEqual(model.notice, "退出前提示")
        XCTAssertTrue(model.accounts.isEmpty)
    }

    @MainActor func testTwoHundredFortyTasksRespectConcurrencyThroughMassCancellationAndRetry() async throws {
        let root = root(), calls = SchedulerStressLedger()
        defer { try? FileManager.default.removeItem(at: root) }
        let backend = BackendClient { operation, payload, event in
            XCTAssertEqual(operation, "download")
            let id = ((payload["track"] as! [String: Any])["id"] as! String)
            calls.enter(id); defer { calls.leave() }
            event("progress", ["stage": "downloading", "percent": 10])
            while !calls.mayFinish(id) { try await Task.sleep(nanoseconds: 2_000_000) }
            event("progress", ["stage": "converting", "percent": 90])
            return ["path": "/tmp/synthetic-stress-only-" + id + ".mp3"]
        }
        let model = AppModel(storeURL: root, engine: backend)
        defer { calls.finishAll(); model.shutdown() }
        model.settings.concurrency = 4
        model.tracks = (0..<240).map { track("task-\($0)") }
        model.selection = Set(model.tracks.map(\.id)); model.downloadSelected()
        try await eventually { calls.started.count == 4 }
        let cancelled = model.jobs.enumerated().filter { $0.offset % 5 == 0 }.map { $0.element.id }
        cancelled.forEach { model.cancelJob($0) }
        try await eventually { model.jobs.filter { $0.state == "cancelled" }.count == 48 }
        XCTAssertLessThanOrEqual(calls.maximum, 4)
        calls.finishAll()
        try await eventually(timeout: 20) { model.activeJobCount == 0 && calls.active == 0 }
        XCTAssertEqual(model.completedJobCount, 192)
        XCTAssertEqual(model.jobs.count, 240)
        cancelled.forEach { model.retryJob($0) }
        try await eventually(timeout: 20) { model.completedJobCount == 240 && calls.active == 0 }
        XCTAssertEqual(model.jobs.filter { $0.retryCount == 1 }.count, 48)
        XCTAssertEqual(Set(model.jobs.map(\.id)).count, 240)
        XCTAssertLessThanOrEqual(calls.maximum, 4)
    }

    @MainActor func testEightySearchReplacementsDiscardOldStreamsAndCompletions() async throws {
        let root = root(), calls = SchedulerStressLedger()
        defer { try? FileManager.default.removeItem(at: root) }
        let backend = BackendClient { operation, payload, event in
            XCTAssertEqual(operation, "search")
            let keyword = payload["keyword"] as! String
            calls.enter(keyword); defer { calls.leave() }
            // Deliberately noncooperative: saved old callbacks must still be
            // filtered by request identity when cancellation cannot stop work.
            try? await Task.sleep(nanoseconds: 10_000_000)
            event("track", ["id": keyword, "title": keyword, "source": "qq"])
            return ["count": 1]
        }
        let model = AppModel(storeURL: root, engine: backend)
        defer { model.shutdown() }
        model.settings.sources = ["qq"]
        for index in 0..<80 {
            model.keyword = "query-\(index)"; model.search()
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        try await eventually { !model.isSearching && calls.active == 0 }
        XCTAssertEqual(model.tracks.map(\.title), ["query-79"])
        XCTAssertEqual(model.sourceStates["qq"], "找到 1 首")
        XCTAssertEqual(model.settings.recent.first, "query-79")
        XCTAssertEqual(model.settings.recent.count, 8)
        XCTAssertEqual(Set(model.settings.recent).count, 8)
    }

    @MainActor func testThirtyRetriesAndFourHundredSixtyFiveStaleEventsKeepSingleJobIdentity() async throws {
        let root = root(), events = RetryStormEvents()
        defer { try? FileManager.default.removeItem(at: root) }
        let backend = BackendClient { operation, _, event in
            XCTAssertEqual(operation, "download")
            let attempt = events.add(event)
            event("progress", ["percent": 15, "detail": "Current synthetic attempt"])
            try await Task.sleep(nanoseconds: 1_000_000)
            if attempt < 30 { throw EngineFailure(reason: "Synthetic retry \(attempt)", code: "source_unavailable") }
            return ["path": "/tmp/synthetic-thirty-retries.mp3"]
        }
        let model = AppModel(storeURL: root, engine: backend)
        defer { model.shutdown() }
        model.downloadTrack(track("retry-storm"))
        try await eventually { model.jobs.first?.state == "failed" }
        let id = model.jobs[0].id
        var emitted = 0
        for retry in 1...30 {
            model.retryJob(id)
            try await eventually { events.count == retry + 1 }
            emitted += events.floodStale()
            try await eventually { model.jobs.first?.state == (retry == 30 ? "completed" : "failed") }
            XCTAssertEqual(model.jobs.count, 1); XCTAssertEqual(model.jobs[0].id, id)
            XCTAssertEqual(model.jobs[0].retryCount, retry)
            XCTAssertNotEqual(model.jobs[0].detail, "STALE RETRY EVENT")
        }
        XCTAssertEqual(model.jobs[0].percent, 100)
        XCTAssertEqual(model.jobs[0].path, "/tmp/synthetic-thirty-retries.mp3")
        XCTAssertEqual(emitted, 465)
    }

    @MainActor func testTwoThousandConcurrentBackendRequestsDrainOnceAcrossThirtyShutdownCalls() async {
        let calls = SchedulerStressLedger(), results = BackendStressResults()
        let complete = expectation(description: "Every accepted or rejected request receives exactly one result")
        complete.expectedFulfillmentCount = 2100
        let backend = BackendClient { _, payload, event in
            let id = payload["id"] as! Int
            calls.enter(String(id)); defer { calls.leave() }
            for progress in 0..<5 { event("progress", ["percent": progress]) }
            try await Task.sleep(nanoseconds: 1_000_000)
            return ["path": "/tmp/synthetic-backend-stress-only"]
        }
        DispatchQueue.concurrentPerform(iterations: 2000) { id in
            let token = backend.request("download", payload: ["id": id], onEvent: { _, _ in results.event(id) }) { _ in results.finish(id); complete.fulfill() }
            if id % 3 == 0 { token.cancel() }
        }
        let drained = expectation(description: "All repeated shutdown waiters observe completed cleanup")
        drained.expectedFulfillmentCount = 30
        for _ in 0..<30 { backend.shutdown { XCTAssertEqual(calls.active, 0); drained.fulfill() } }
        for id in 2000..<2100 {
            backend.request("download", payload: ["id": id]) { result in
                if case .failure(let error) = result { XCTAssertEqual(error.code, "cancelled") }
                else { XCTFail("A request made after shutdown must be rejected") }
                results.finish(id); complete.fulfill()
            }
        }
        await fulfillment(of: [complete, drained], timeout: 15)
        XCTAssertEqual(results.summary.0, 2100)
        XCTAssertEqual(results.summary.1, 0)
        XCTAssertEqual(results.summary.2, 0)
        XCTAssertFalse(calls.started.contains { (Int($0) ?? 0) >= 2000 })
    }
}
