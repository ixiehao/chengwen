import Foundation
import XCTest
@testable import ChengWen

private final class ModelRequests:@unchecked Sendable {
    private let lock=NSLock()
    private var requests:[String]=[]
    private var active=0
    private var peak=0
    private var release=false
    func begin(_ key:String){lock.lock();requests.append(key);active+=1;peak=max(peak,active);lock.unlock()}
    func end(){lock.lock();active-=1;lock.unlock()}
    func finish(){lock.lock();release=true;lock.unlock()}
    var released:Bool{lock.lock();defer{lock.unlock()};return release}
    var keys:[String]{lock.lock();defer{lock.unlock()};return requests}
    var maximum:Int{lock.lock();defer{lock.unlock()};return peak}
}
final class AppModelFunctionalTests:XCTestCase {
    @MainActor private func eventually(_ predicate:()->Bool,timeout:Double=3) async throws {
        let end=Date().addingTimeInterval(timeout)
        while !predicate() && Date()<end{try await Task.sleep(nanoseconds:10_000_000)}
        XCTAssertTrue(predicate(),"Synthetic native operation exceeded deadline")
    }
    @MainActor func testLyricWarningPreservesSuccessfulAudioAndVisibleHistoryDetail() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:root)}
        let model=AppModel(storeURL:root,engine:BackendClient{_,_,_ in ["path":"/tmp/synthetic-model-only.mp3","warnings":["歌词未能保存。"]]})
        model.downloadTrack(AudioTrack(raw:["id":"warning","source":"netease","url":"https://music.163.com/song?id=123"]))
        try await eventually{model.jobs.first?.state=="completed"}
        XCTAssertEqual(model.jobs[0].path,"/tmp/synthetic-model-only.mp3")
        XCTAssertTrue(model.jobs[0].detail.contains("歌词未能保存"));XCTAssertEqual(model.jobs[0].percent,100)
        model.shutdown()
        let restored=AppModel(storeURL:root,engine:BackendClient{_,_,_ in XCTFail();return [:]})
        XCTAssertEqual(restored.jobs[0].state,"completed");XCTAssertTrue(restored.jobs[0].detail.contains("歌词未能保存"));restored.shutdown()
    }
    @MainActor func testMultiSourceStreamingReplacementHistoryAndHeaderSelection() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:root)}
        let calls=ModelRequests()
        let backend=BackendClient{operation,payload,event in
            XCTAssertEqual(operation,"search")
            let source=payload["source"] as! String,keyword=payload["keyword"] as! String
            calls.begin(source+":"+keyword);defer{calls.end()}
            event("track",["id":source+":"+keyword+":1","title":keyword,"source":source])
            if keyword=="old" {try? await Task.sleep(nanoseconds:500_000_000)}
            else {try await Task.sleep(nanoseconds:150_000_000)}
            let extra:[String:Any]=["id":source+":"+keyword+":2","title":keyword,"source":source]
            event("track",extra);event("track",extra)
            return ["count":2]
        }
        let model=AppModel(storeURL:root,engine:backend)
        model.settings.sources=["netease","kuwo"];model.keyword="old";model.search()
        try await eventually{model.tracks.count==2}
        model.keyword="new";model.search()
        try await eventually{model.tracks.count==2}
        model.toggleAll();XCTAssertTrue(model.allSelected)
        try await eventually{!model.isSearching}
        XCTAssertEqual(model.tracks.count,4)
        XCTAssertTrue(model.tracks.allSatisfy{$0.title=="new"})
        XCTAssertEqual(model.selectedCount,2);XCTAssertTrue(model.partiallySelected)
        XCTAssertEqual(model.sourceStates.count,2);XCTAssertEqual(model.searchStatus,"搜索完成 · 4 首")
        XCTAssertEqual(model.settings.recent,["new","old"])
        model.clearRecent();XCTAssertEqual(model.keyword,"new")
        model.settings.format="flac";model.settings.limit=30;model.settings.timeout=180;model.settings.concurrency=4
        model.shutdown()
        let restored=AppModel(storeURL:root,engine:BackendClient{_,_,_ in XCTFail("Reopening must not execute operations");return [:]})
        XCTAssertTrue(restored.settings.recent.isEmpty);XCTAssertEqual(restored.settings.format,"flac")
        XCTAssertEqual(restored.settings.limit,30);XCTAssertEqual(restored.settings.timeout,180);XCTAssertEqual(restored.settings.concurrency,4)
        restored.shutdown()
        XCTAssertEqual(calls.keys.count,4)
    }
    @MainActor func testQueueConcurrencyCancelQueuedAndRunningThenContinue() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:root)}
        let calls=ModelRequests()
        let backend=BackendClient{operation,payload,event in
            XCTAssertEqual(operation,"download")
            let id=(payload["track"] as! [String:Any])["id"] as! String
            calls.begin(id);defer{calls.end()}
            event("progress",["stage":"downloading","percent":25,"detail":"Synthetic transfer"])
            while !calls.released{try await Task.sleep(nanoseconds:10_000_000)}
            return ["path":"/tmp/synthetic-model-only-\(id).mp3"]
        }
        let model=AppModel(storeURL:root,engine:backend);model.settings.concurrency=2
        for id in ["one","two","three","four"]{model.downloadTrack(AudioTrack(raw:["id":id,"title":id,"source":"netease","url":"https://music.163.com/song?id=123"]))}
        try await eventually{calls.keys.count==2}
        let first=model.jobs[0].id,last=model.jobs[3].id
        model.cancelJob(last);model.cancelJob(first)
        try await eventually{calls.keys.count==3}
        XCTAssertFalse(calls.keys.contains("four"))
        model.clearFinishedJobs();XCTAssertEqual(model.jobs.filter{$0.active}.count,2)
        calls.finish();try await eventually{model.activeJobCount==0}
        XCTAssertEqual(model.completedJobCount,2);XCTAssertEqual(calls.maximum,2)
        model.shutdown()
        let restored=AppModel(storeURL:root,engine:BackendClient{_,_,_ in XCTFail("History must not start downloads");return [:]})
        XCTAssertEqual(restored.completedJobCount,2)
        XCTAssertTrue(restored.jobs.allSatisfy{$0.track.url.isEmpty})
        restored.shutdown()
    }
    @MainActor func testRetryFailureGivesSwitchSourceAndLegacyHistoryOnlySearchesDomesticSources() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:root)}
        let calls=ModelRequests()
        let backend=BackendClient{operation,payload,_ in
            calls.begin(operation+":"+(payload["source"] as? String ?? ""));defer{calls.end()}
            if operation=="download"{throw EngineFailure(reason:"Synthetic audio unavailable",solution:"请选择其他来源。",code:"source_unavailable")}
            return ["count":0]
        }
        let model=AppModel(storeURL:root,engine:backend)
        model.downloadTrack(AudioTrack(raw:["id":"fail","source":"netease","url":"https://music.163.com/song?id=123"]))
        try await eventually{model.jobs.first?.state=="failed"}
        model.retryJob(model.jobs[0].id);try await eventually{model.jobs.first?.state=="failed"}
        XCTAssertEqual(model.jobs[0].retryCount,1);XCTAssertTrue(model.jobs[0].solution.contains("重试仍失败"))
        let legacy=DownloadJob(history:["id":"legacy","track":["id":"old","title":"Archived","source":"spotify"],"state":"failed"])!
        model.jobs.append(legacy);model.retryJob(legacy.id)
        try await eventually{!model.isSearching}
        XCTAssertEqual(Set(model.sourceStates.keys),["netease","kuwo","kugou","qq","migu","qianqian"])
        XCTAssertFalse(calls.keys.contains("search:spotify"))
        model.shutdown()
    }
}
