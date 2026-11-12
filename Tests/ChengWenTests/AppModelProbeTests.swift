import Foundation
import XCTest
@testable import ChengWen

private actor ProbeHarness {
    var started:[String]=[]
    var waiting:[CheckedContinuation<Void,Never>]=[]
    func run(_ payload:[String:Any]) async->[String:Any] {
        let id=(payload["track"] as? [String:Any])?["id"] as? String ?? ""
        started.append(id)
        await withCheckedContinuation{waiting.append($0)}
        return ["sample_bytes":4096,"detail":"Synthetic late success"]
    }
    func count()->Int{started.count}
    func release(){let values=waiting;waiting=[];values.forEach{$0.resume()}}
}
final class AppModelProbeTests:XCTestCase {
    @MainActor func testAccountSwitchInvalidatesRunningAndQueuedProbesIncludingLateSuccess() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("chengwen-native-probe-"+UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:root)}
        func records(_ revision:String,_ name:String)->[String:Any]{["schema":2,"accounts":["netease":["revision":revision,"nickname":name,"verified":true,"method":"synthetic"]]]}
        try AppFiles.write(records(String(repeating:"a",count:32),"Old synthetic account"),name:"accounts.json",at:root)
        let harness=ProbeHarness()
        let backend=BackendClient{_,payload,_ in await harness.run(payload)}
        let model=AppModel(storeURL:root,engine:backend)
        model.refreshAccounts()
        model.tracks=[AudioTrack(raw:["id":"running-account","source":"netease"]),AudioTrack(raw:["id":"running-public","source":"kuwo"]),AudioTrack(raw:["id":"queued-public","source":"kuwo"])]
        model.probes["cached-public"]=ProbeStatus(state:"passed",detail:"Existing independent result")
        model.selection=Set(model.tracks.map{$0.id});model.probeSelected()
        let deadline=Date().addingTimeInterval(3)
        while await harness.count()<2 && Date()<deadline{try await Task.sleep(nanoseconds:10_000_000)}
        XCTAssertEqual(model.probes["queued-public"]?.state,"queued")
        try AppFiles.write(records(String(repeating:"b",count:32),"New synthetic account"),name:"accounts.json",at:root)
        model.accountChanged("netease")
        XCTAssertEqual(model.accounts["netease"]?.nickname,"New synthetic account")
        XCTAssertFalse(model.isProbing)
        for id in model.tracks.map({$0.id}){XCTAssertNil(model.probes[id])}
        await harness.release();try await Task.sleep(nanoseconds:50_000_000)
        for id in model.tracks.map({$0.id}){XCTAssertNil(model.probes[id])}
        XCTAssertEqual(model.probes["cached-public"]?.state,"passed")
        let count=await harness.count();XCTAssertEqual(count,2)
        model.shutdown()
    }
}
