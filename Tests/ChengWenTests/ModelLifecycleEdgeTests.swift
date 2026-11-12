import Foundation
import XCTest
@testable import ChengWen

private final class SavedEngineEvents:@unchecked Sendable {
    private let lock=NSLock()
    private var callbacks:[(String,[String:Any])->Void]=[]
    func save(_ callback:@escaping(String,[String:Any])->Void)->Int{lock.lock();defer{lock.unlock()};callbacks.append(callback);return callbacks.count-1}
    func emit(_ attempt:Int,stage:String,percent:Int,detail:String) {
        lock.lock();let callback=callbacks[attempt];lock.unlock()
        callback("progress",["stage":stage,"percent":percent,"detail":detail])
    }
}
private actor RetryReplyGate {
    private var pending:CheckedContinuation<Void,Never>?
    func wait(_ started:XCTestExpectation)async{await withCheckedContinuation{pending=$0;started.fulfill()}}
    func release(){let value=pending;pending=nil;value?.resume()}
}
final class ModelLifecycleEdgeTests:XCTestCase {
    private func root()->URL{FileManager.default.temporaryDirectory.appendingPathComponent("chengwen-model-lifecycle-"+UUID().uuidString)}
    private func track()->AudioTrack{AudioTrack(raw:["id":"stable-song","title":"Synthetic lifecycle song","source":"qq","url":"https://example.invalid/catalog-only"])}
    @MainActor private func eventually(_ condition:()->Bool)async throws {
        let deadline=Date().addingTimeInterval(3)
        while !condition() && Date()<deadline{try await Task.sleep(nanoseconds:10_000_000)}
        XCTAssertTrue(condition(),"Owned synthetic engine callback did not complete")
    }
    @MainActor func testCompletedJobCannotBeReactivatedBySavedLateProgress()async throws {
        let root=root(),events=SavedEngineEvents()
        let model=AppModel(storeURL:root,engine:BackendClient{_,_,event in _=events.save(event);return ["path":"/tmp/synthetic-committed-only.mp3"]})
        defer{model.shutdown();try? FileManager.default.removeItem(at:root)}
        model.settings.directory=root.appendingPathComponent("audio").path
        model.downloadTrack(track());try await eventually{model.completedJobCount==1}
        events.emit(0,stage:"downloading",percent:12,detail:"Late event after committed result")
        try await Task.sleep(nanoseconds:60_000_000)
        XCTAssertEqual(model.jobs[0].state,"completed");XCTAssertEqual(model.activeJobCount,0)
        XCTAssertEqual(model.jobs[0].percent,100);XCTAssertEqual(model.jobs[0].path,"/tmp/synthetic-committed-only.mp3")
    }
    @MainActor func testOldAttemptCannotPolluteRetryButCurrentProgressStillUpdates()async throws {
        let root=root(),events=SavedEngineEvents(),gate=RetryReplyGate(),started=expectation(description:"Retry began")
        let model=AppModel(storeURL:root,engine:BackendClient{_,_,event in
            let attempt=events.save(event)
            if attempt==0{throw EngineFailure(reason:"Synthetic first attempt failed",code:"source_unavailable")}
            await gate.wait(started);return ["path":"/tmp/synthetic-retry-only.mp3"]
        })
        defer{model.shutdown();try? FileManager.default.removeItem(at:root)}
        model.settings.directory=root.appendingPathComponent("audio").path
        model.downloadTrack(track());try await eventually{model.jobs.first?.state=="failed"}
        model.retryJob(model.jobs[0].id);await fulfillment(of:[started],timeout:2)
        events.emit(0,stage:"converting",percent:99,detail:"Stale first-attempt progress")
        try await Task.sleep(nanoseconds:50_000_000)
        XCTAssertEqual(model.jobs[0].state,"downloading")
        XCTAssertNotEqual(model.jobs[0].detail,"Stale first-attempt progress")
        events.emit(1,stage:"downloading",percent:35,detail:"Current retry progress")
        try await eventually{model.jobs[0].percent==35}
        XCTAssertEqual(model.jobs[0].detail,"Current retry progress")
        await gate.release();try await eventually{model.completedJobCount==1}
        XCTAssertEqual(model.jobs[0].retryCount,1)
    }
    @MainActor func testStaleCancelDoesNotChangeACompletedJobOrPublishedPath()async throws {
        let root=root()
        let model=AppModel(storeURL:root,engine:BackendClient{_,_,_ in ["path":"/tmp/synthetic-finished-before-cancel.mp3"]})
        defer{model.shutdown();try? FileManager.default.removeItem(at:root)}
        model.settings.directory=root.appendingPathComponent("audio").path
        model.downloadTrack(track());try await eventually{model.completedJobCount==1}
        let id=model.jobs[0].id
        // A previously drawn Cancel button can invoke this after completion
        // has already reached the model but before SwiftUI redraws its row.
        model.cancelJob(id);model.cancelJob(id)
        XCTAssertEqual(model.jobs[0].state,"completed")
        XCTAssertEqual(model.jobs[0].path,"/tmp/synthetic-finished-before-cancel.mp3")
        XCTAssertEqual(model.jobs[0].percent,100)
    }
    @MainActor func testBackendDeliversQueuedProgressThenResultButNeverPostResultEvents()async throws {
        for fail in [false,true] {
            let events=SavedEngineEvents(),complete=expectation(description:"Native request completed")
            var sequence:[String]=[]
            let client=BackendClient{_,_,event in
                _=events.save(event);event("progress",["stage":"downloading","percent":25,"detail":"Valid queued progress"])
                if fail{throw EngineFailure(reason:"Synthetic failure",code:"source_unavailable")}
                return ["path":"/tmp/synthetic-result-only.mp3"]
            }
            client.request("download",payload:[:],onEvent:{event,_ in sequence.append(event)}){_ in sequence.append("result");complete.fulfill()}
            await fulfillment(of:[complete],timeout:2)
            XCTAssertEqual(sequence,["progress","result"],"Already queued progress must not be discarded merely because execute returned quickly")
            events.emit(0,stage:"downloading",percent:99,detail:"Invalid post-result event")
            try await Task.sleep(nanoseconds:60_000_000)
            XCTAssertEqual(sequence,["progress","result"],"Saved callbacks cannot deliver events after their result")
        }
    }
    @MainActor func testUnexpectedProgressCannotMakeAnOwnedRunningJobClearable()async throws {
        let root=root(),events=SavedEngineEvents(),gate=RetryReplyGate(),started=expectation(description:"Running attempt began")
        let model=AppModel(storeURL:root,engine:BackendClient{_,_,event in
            _=events.save(event);await gate.wait(started);return ["path":"/tmp/synthetic-normalized-progress.mp3"]
        })
        defer{model.shutdown();try? FileManager.default.removeItem(at:root)}
        model.settings.directory=root.appendingPathComponent("audio").path
        model.downloadTrack(track());await fulfillment(of:[started],timeout:2)
        events.emit(0,stage:"future_stage",percent:Int.max,detail:"Synthetic future progress")
        try await Task.sleep(nanoseconds:50_000_000)
        XCTAssertEqual(model.jobs[0].state,"downloading");XCTAssertEqual(model.jobs[0].percent,100)
        XCTAssertEqual(model.activeJobCount,1)
        model.clearFinishedJobs()
        XCTAssertEqual(model.jobs.count,1,"A running attempt cannot be cleared due to an unexpected progress stage")
        events.emit(0,stage:"converting",percent:-99,detail:"Synthetic indeterminate conversion")
        try await Task.sleep(nanoseconds:50_000_000)
        XCTAssertEqual(model.jobs.first?.state,"converting");XCTAssertEqual(model.jobs.first?.percent,-1)
        await gate.release();try await eventually{model.completedJobCount==1}
    }
}
