import Foundation
import XCTest
@testable import ChengWen

final class ProbeClockTests: XCTestCase {
    func testFutureProbeIsNotFreshAfterClockRollsBack() {
        let future = ProbeStatus(state: "failed", checkedAt: Date().addingTimeInterval(3600))
        XCTAssertFalse(future.fresh, "A future failure must not block retries until the clock catches up")
    }
    @MainActor func testFutureFailedProbeDoesNotPermanentlyBlockDownloadRetry() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("chengwen-clock-soak-" + UUID().uuidString)
        let entered = expectation(description: "New download request is allowed after clock rollback")
        let model = AppModel(storeURL: root, engine: BackendClient { operation, _, _ in
            XCTAssertEqual(operation, "download"); entered.fulfill()
            return ["path": root.appendingPathComponent("synthetic.mp3").path]
        })
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        let track = AudioTrack(raw: ["id": "clock-song", "source": "netease", "title": "Synthetic clock fixture", "url": "https://music.163.com/song?id=123"])
        model.tracks = [track]
        model.probes[track.id] = ProbeStatus(state: "failed", detail: "Synthetic old failure", checkedAt: Date().addingTimeInterval(3600))
        model.downloadTrack(track)
        await fulfillment(of: [entered], timeout: 1)
        XCTAssertEqual(model.jobs.count, 1)
        let deadline = Date().addingTimeInterval(2)
        while model.completedJobCount != 1 && Date() < deadline { try await Task.sleep(nanoseconds: 1_000_000) }
        XCTAssertEqual(model.completedJobCount, 1)
    }
    func testTenThousandClockChangesRespectBothFreshnessBoundaries() {
        let origin = Date(timeIntervalSince1970: 1_700_000_000)
        let probe = ProbeStatus(state: "failed", checkedAt: origin)
        let ages: [TimeInterval] = [-86400, -1, -0.001, 0, 0.001, 299.999, 300, 301, 86400]
        for index in 0..<10_000 {
            let age = ages[index % ages.count]
            XCTAssertEqual(probe.isFresh(at: origin.addingTimeInterval(age)), age >= 0 && age < 300)
        }
    }
}
