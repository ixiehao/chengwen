import Foundation
import XCTest
@testable import ChengWen

private final class FIFOFixture:@unchecked Sendable {
    private let lock=NSLock()
    private var starts:[String]=[]
    private var released=Set<String>()
    func start(_ id:String){lock.lock();starts.append(id);lock.unlock()}
    func release(_ id:String){lock.lock();released.insert(id);lock.unlock()}
    func canFinish(_ id:String)->Bool{lock.lock();defer{lock.unlock()};return released.contains(id)}
    var order:[String]{lock.lock();defer{lock.unlock()};return starts}
}

final class NoticeAndOrderingTests:XCTestCase {
    private func temporaryRoot()->URL{FileManager.default.temporaryDirectory.appendingPathComponent("chengwen-notice-order-"+UUID().uuidString)}
    @MainActor private func eventually(_ condition:()->Bool,timeout:Double=2) async throws {
        let end=Date().addingTimeInterval(timeout)
        while !condition() && Date()<end{try await Task.sleep(nanoseconds:10_000_000)}
        XCTAssertTrue(condition(),"Model did not reach the expected state")
    }
    @MainActor private func noNetworkModel(_ root:URL,duration:TimeInterval=0.4)->AppModel {
        AppModel(storeURL:root,engine:BackendClient{_,_,_ in XCTFail("Notice/history tests must not execute engine operations");return [:]},noticeDisplayDuration:duration)
    }
    @MainActor func testSameNoticeResetsExpiryAndOldTimerCannotDismissRetriggeredMessage() async throws {
        let root=temporaryRoot(),model=noNetworkModel(root)
        defer{model.shutdown();try? FileManager.default.removeItem(at:root)}
        model.notice="已加入下载队列"
        try await Task.sleep(nanoseconds:240_000_000)
        model.notice="已加入下载队列"
        try await Task.sleep(nanoseconds:240_000_000)
        XCTAssertEqual(model.notice,"已加入下载队列","An old timer must not hide a repeated message")
        try await eventually{model.notice.isEmpty}
    }
    @MainActor func testDismissThenNewNoticeIsNotClearedByEitherPreviousExpiry() async throws {
        let root=temporaryRoot(),model=noNetworkModel(root)
        defer{model.shutdown();try? FileManager.default.removeItem(at:root)}
        model.notice="第一个提示"
        try await Task.sleep(nanoseconds:150_000_000)
        model.notice="第二个提示"
        try await Task.sleep(nanoseconds:150_000_000)
        model.notice=""
        XCTAssertTrue(model.notice.isEmpty)
        model.notice="新的提示"
        try await Task.sleep(nanoseconds:280_000_000)
        XCTAssertEqual(model.notice,"新的提示","Neither dismissed timer may clear the replacement")
        try await eventually{model.notice.isEmpty}
    }
    @MainActor func testShutdownCancelsNoticeExpiryAndDoesNotStartAnotherTimer() async throws {
        let root=temporaryRoot(),model=noNetworkModel(root,duration:0.08)
        defer{try? FileManager.default.removeItem(at:root)}
        model.notice="退出前的提示";model.shutdown()
        try await Task.sleep(nanoseconds:150_000_000)
        XCTAssertEqual(model.notice,"退出前的提示")
        model.notice="已退出"
        try await Task.sleep(nanoseconds:150_000_000)
        XCTAssertEqual(model.notice,"已退出")
    }
    @MainActor func testPendingNoticeDoesNotKeepAnAbandonedModelAlive() {
        let root=temporaryRoot();defer{try? FileManager.default.removeItem(at:root)}
        var model:AppModel?=noNetworkModel(root,duration:3)
        weak var observed=model
        model?.notice="临时提示";model=nil
        XCTAssertNil(observed)
        observed=nil
    }
    @MainActor func testNewestFirstDisplaySurvivesReloadAndFiltersWithoutChangingStoredOrder() throws {
        let root=temporaryRoot(),model=noNetworkModel(root)
        defer{try? FileManager.default.removeItem(at:root)}
        func job(_ id:String,_ state:String,_ created:String)->DownloadJob {
            var job=DownloadJob(track:AudioTrack(raw:["id":id,"title":id,"source":"netease"]),format:"mp3",directory:root.path,lyrics:false)
            job.id=id;job.state=state;job.created=created;return job
        }
        // Legacy dates may be missing or inconsistent. Array insertion order
        // remains the authority for both history and the FIFO scheduler.
        model.jobs=[job("old","completed","2099-01-01"),job("legacy-pending","pending","2001-01-01"),job("middle","failed","2000-01-01"),job("new","downloading","")]
        XCTAssertEqual(model.jobsNewestFirst.map{$0.id},["new","middle","legacy-pending","old"])
        XCTAssertEqual(model.jobsNewestFirst.filter{$0.state=="failed"}.map{$0.id},["middle"])
        XCTAssertEqual(model.jobsNewestFirst.filter{$0.active}.map{$0.id},["new"])
        XCTAssertEqual(model.jobs.map{$0.id},["old","legacy-pending","middle","new"])
        model.shutdown()
        let document=try XCTUnwrap(AppFiles.read("history.json",at:root) as? [String:Any])
        let stored=try XCTUnwrap(document["jobs"] as? [[String:Any]])
        XCTAssertEqual(stored.compactMap{$0["id"] as? String},["old","legacy-pending","middle","new"])
        let restored=noNetworkModel(root)
        XCTAssertEqual(restored.jobsNewestFirst.map{$0.id},["new","middle","legacy-pending","old"])
        XCTAssertEqual(restored.jobs[1].state,"interrupted")
        XCTAssertEqual(restored.jobs[3].state,"interrupted")
        XCTAssertEqual(restored.activeJobCount,0)
        XCTAssertTrue(restored.jobsNewestFirst.filter{$0.active}.isEmpty)
        restored.jobs.append(job("just-added","queued","1999-01-01"))
        XCTAssertEqual(restored.jobsNewestFirst.first?.id,"just-added")
        restored.clearFinishedJobs()
        XCTAssertEqual(restored.jobsNewestFirst.map{$0.id},["just-added"])
        restored.shutdown()
    }
    @MainActor func testNewestFirstPresentationKeepsInternalFIFOAndCancelsNewestQueuedJobByID() async throws {
        let root=temporaryRoot(),fixture=FIFOFixture()
        let backend=BackendClient{operation,payload,_ in
            XCTAssertEqual(operation,"download")
            let id=(payload["track"] as! [String:Any])["id"] as! String
            fixture.start(id)
            while !fixture.canFinish(id){try await Task.sleep(nanoseconds:10_000_000)}
            return ["path":"/tmp/synthetic-order-only-\(id).mp3"]
        }
        let model=AppModel(storeURL:root,engine:backend)
        defer{model.shutdown();try? FileManager.default.removeItem(at:root)}
        model.settings.concurrency=1
        for id in ["one","two","three","four"] {
            model.downloadTrack(AudioTrack(raw:["id":id,"title":id,"source":"netease","url":"https://music.163.com/song?id=123"]))
        }
        try await eventually{fixture.order.count==1}
        XCTAssertEqual(model.jobsNewestFirst.map{$0.track.id},["four","three","two","one"])
        let newestID=try XCTUnwrap(model.jobsNewestFirst.first?.id)
        model.cancelJob(newestID)
        XCTAssertEqual(model.jobs.first(where:{$0.track.id=="four"})?.state,"cancelled")
        fixture.release("one");try await eventually{fixture.order.count==2}
        XCTAssertEqual(fixture.order,["one","two"])
        fixture.release("two");try await eventually{fixture.order.count==3}
        fixture.release("three");try await eventually{model.activeJobCount==0}
        XCTAssertEqual(fixture.order,["one","two","three"])
        XCTAssertEqual(model.jobsNewestFirst.map{$0.track.id},["four","three","two","one"])
        XCTAssertEqual(model.completedJobCount,3)
    }
}
