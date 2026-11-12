import Foundation
import XCTest
@testable import ChengWen

private actor VerificationReplyGate {
    private var waiting:CheckedContinuation<Void,Never>?
    func wait(_ started:XCTestExpectation)async {
        await withCheckedContinuation{waiting=$0;started.fulfill()}
    }
    func release(){let value=waiting;waiting=nil;value?.resume()}
}
private final class VerificationRequests:@unchecked Sendable {
    private let lock=NSLock()
    private var values:[[String:Any]]=[]
    func add(_ value:[String:Any]){lock.lock();values.append(value);lock.unlock()}
    var tracks:[[String:Any]]{lock.lock();defer{lock.unlock()};return values}
}

final class SourceVerificationModelTests:XCTestCase {
    private func root()->URL{FileManager.default.temporaryDirectory.appendingPathComponent("chengwen-full-proof-"+UUID().uuidString)}
    private func track(_ id:String,source:String="qq")->AudioTrack {AudioTrack(raw:["id":id,"title":"Synthetic "+id,"source":source,"url":"https://example.invalid/catalog-only","duration":"3:20","metadata":["duration_s":200]])}
    @MainActor private func eventually(_ condition:()->Bool)async throws {
        let deadline=Date().addingTimeInterval(3)
        while !condition() && Date()<deadline{try await Task.sleep(nanoseconds:10_000_000)}
        XCTAssertTrue(condition(),"Synthetic trusted-engine callback did not complete")
    }
    @MainActor func testProbeReplyNeverMeansAnonymousWholeTrackEvenIfItContainsFullFlag()async throws {
        let root=root();defer{try? FileManager.default.removeItem(at:root)}
        let model=AppModel(storeURL:root,engine:BackendClient{operation,_,_ in
            XCTAssertEqual(operation,"probe");return ["sample_bytes":131072,"full_verified":true,"anonymous":true]
        })
        defer{model.shutdown()}
        let song=track("preview");model.tracks=[song];model.probeTrack(song)
        try await eventually{!model.isProbing}
        XCTAssertEqual(model.probes[song.id]?.state,"passed");XCTAssertNil(model.probes[song.id]?.anonymous)
        XCTAssertEqual(model.sourceValidationSummary("qq"),"当前结果：匿名整首已验证 0 首 · 登录整首已验证 0 首 · 仅可试读 1 首")
    }
    @MainActor func testActualFullProofSeparatesAnonymousAndAuthenticatedAndLegacySuccessStaysReadable()async throws {
        let root=root();defer{try? FileManager.default.removeItem(at:root)}
        try AppFiles.write(["schema":2,"accounts":["netease":["revision":String(repeating:"a",count:32),"nickname":"Synthetic connected account"]]],name:"accounts.json",at:root)
        // Synthetic trusted-engine replies exercise propagation, not media
        // verification itself. Actual decoding is covered by pipeline tests.
        let model=AppModel(storeURL:root,engine:BackendClient{operation,payload,_ in
            XCTAssertEqual(operation,"download")
            let raw=payload["track"] as! [String:Any],id=raw["id"] as! String
            let ref=(raw["metadata"] as? [String:Any])?["account_ref"] as? [String:Any]
            if id=="account"{XCTAssertEqual(ref?["platform"] as? String,"netease")}else{XCTAssertNil(ref)}
            var result:[String:Any]=["path":"/tmp/synthetic-proof-only-\(id).mp3","anonymous":true]
            if id != "legacy"{result["full_verified"]=true;result["anonymous"]=id=="public"}
            return result
        })
        defer{model.shutdown()}
        model.refreshAccounts();model.settings.useConnectedAccounts=true
        model.tracks=[track("public"),track("account",source:"netease"),track("legacy")]
        model.probes["legacy"]=ProbeStatus(state:"passed",detail:"Only a previous small read")
        for song in model.tracks{model.downloadTrack(song)}
        try await eventually{model.completedJobCount==3}
        XCTAssertEqual(model.probes["public"]?.state,"verified");XCTAssertEqual(model.probes["public"]?.anonymous,true)
        XCTAssertEqual(model.probes["account"]?.state,"verified");XCTAssertEqual(model.probes["account"]?.anonymous,false)
        XCTAssertEqual(model.probes["legacy"]?.state,"passed");XCTAssertNil(model.probes["legacy"]?.anonymous)
        XCTAssertEqual(model.sourceValidationSummary("qq"),"当前结果：匿名整首已验证 1 首 · 登录整首已验证 0 首 · 仅可试读 1 首")
        XCTAssertEqual(model.sourceValidationSummary("netease"),"当前结果：匿名整首已验证 0 首 · 登录整首已验证 1 首 · 仅可试读 0 首")
    }
    @MainActor func testStoredSessionsStayUnusedByDefaultForProbeAndDownload()async throws {
        let root=root();defer{try? FileManager.default.removeItem(at:root)}
        try AppFiles.write(["schema":2,"accounts":["netease":["revision":String(repeating:"a",count:32)],"kuwo":["revision":String(repeating:"b",count:32)]]],name:"accounts.json",at:root)
        let requests=VerificationRequests()
        let model=AppModel(storeURL:root,engine:BackendClient{operation,payload,_ in
            requests.add(payload["track"] as! [String:Any])
            return operation=="probe" ? ["sample_bytes":4096] : ["path":"/tmp/synthetic-anonymous-default.mp3","full_verified":true,"anonymous":true]
        })
        defer{model.shutdown()}
        model.refreshAccounts();XCTAssertFalse(model.settings.useConnectedAccounts)
        XCTAssertEqual(model.accounts.count,2)
        model.tracks=[track("anonymous-netease",source:"netease"),track("anonymous-kuwo",source:"kuwo"),track("always-public",source:"qq")].map{song in
            var raw=song.raw,metadata=raw["metadata"] as! [String:Any]
            metadata["account_ref"]=["platform":"netease","revision":String(repeating:"c",count:32),"store":"/never-read"]
            raw["metadata"]=metadata;raw["cookies"]=["synthetic":"secret"]
            raw["headers"]=["Cookie":"secret","Authorization":"secret"]
            return AudioTrack(raw:raw)
        }
        model.selection=Set(model.tracks.map{$0.id});model.probeSelected();try await eventually{!model.isProbing}
        model.downloadTrack(model.tracks[0]);try await eventually{model.completedJobCount==1}
        XCTAssertEqual(requests.tracks.count,4)
        for raw in requests.tracks {
            XCTAssertNil((raw["metadata"] as? [String:Any])?["account_ref"])
            XCTAssertTrue((raw["cookies"] as? [String:String])?.isEmpty==true)
            XCTAssertNil((raw["headers"] as? [String:String])?["Cookie"])
            XCTAssertNil((raw["headers"] as? [String:String])?["Authorization"])
        }
        XCTAssertEqual(model.probes["anonymous-netease"]?.anonymous,true)
        XCTAssertTrue(model.sourceValidationSummary("netease").contains("匿名整首已验证 1 首"))
    }
    @MainActor func testMissingAnonymousClassificationCannotBeFalselyCalledLoginProof()async throws {
        let root=root();defer{try? FileManager.default.removeItem(at:root)}
        let model=AppModel(storeURL:root,engine:BackendClient{_,_,_ in ["path":"/tmp/synthetic-unclassified.mp3","full_verified":true]})
        defer{model.shutdown()}
        let song=track("unclassified");model.tracks=[song];model.downloadTrack(song)
        try await eventually{model.completedJobCount==1}
        XCTAssertNil(model.probes[song.id]?.anonymous)
        XCTAssertTrue(model.sourceValidationSummary("qq").contains("匿名整首已验证 0 首"))
        XCTAssertTrue(model.sourceValidationSummary("qq").contains("登录整首已验证 0 首"))
    }
    @MainActor func testLateFullResultCannotVerifySameIDAfterSearchGenerationChanges()async throws {
        let root=root();defer{try? FileManager.default.removeItem(at:root)}
        let gate=VerificationReplyGate(),started=expectation(description:"Download began")
        let song=track("same-id")
        let model=AppModel(storeURL:root,engine:BackendClient{operation,_,event in
            if operation=="search"{event("track",song.raw);return ["count":1]}
            await gate.wait(started)
            return ["path":"/tmp/synthetic-old-search.mp3","full_verified":true,"anonymous":true]
        })
        defer{model.shutdown()}
        model.settings.sources=["qq"];model.tracks=[song];model.downloadTrack(song)
        await fulfillment(of:[started],timeout:2)
        model.keyword="New search";model.search();try await eventually{!model.isSearching}
        XCTAssertEqual(model.tracks.first?.id,song.id)
        await gate.release();try await eventually{model.completedJobCount==1}
        XCTAssertNil(model.probes[song.id])
        XCTAssertEqual(model.sourceValidationSummary("qq"),"当前结果：匿名整首已验证 0 首 · 登录整首已验证 0 首 · 仅可试读 0 首")
    }
    @MainActor func testShutdownRejectsLateWholeTrackVerificationEvenWhenCommittedFileSucceeded()async throws {
        let root=root();defer{try? FileManager.default.removeItem(at:root)}
        let gate=VerificationReplyGate(),started=expectation(description:"Download began")
        let model=AppModel(storeURL:root,engine:BackendClient{_,_,_ in
            // Deliberately let an already committed success arrive after
            // cancellation; the model must still reject stale proof labels.
            await gate.wait(started)
            return ["path":"/tmp/synthetic-committed.mp3","full_verified":true,"anonymous":true]
        })
        let song=track("late");model.tracks=[song];model.downloadTrack(song)
        await fulfillment(of:[started],timeout:2)
        model.shutdown();await gate.release()
        try await eventually{model.completedJobCount==1}
        XCTAssertNil(model.probes[song.id])
    }
    @MainActor func testLateProbeCannotDowngradeNewerWholeTrackProof()async throws {
        let root=root();defer{try? FileManager.default.removeItem(at:root)}
        let downloadGate=VerificationReplyGate(),probeGate=VerificationReplyGate()
        let downloadStarted=expectation(description:"Download began"),probeStarted=expectation(description:"Probe began")
        let model=AppModel(storeURL:root,engine:BackendClient{operation,_,_ in
            if operation=="probe"{await probeGate.wait(probeStarted);return ["sample_bytes":4096]}
            await downloadGate.wait(downloadStarted)
            return ["path":"/tmp/synthetic-newer-full.mp3","full_verified":true,"anonymous":true]
        })
        defer{model.shutdown()}
        let song=track("overlap");model.tracks=[song];model.downloadTrack(song)
        await fulfillment(of:[downloadStarted],timeout:2)
        model.probeTrack(song);await fulfillment(of:[probeStarted],timeout:2)
        await downloadGate.release();try await eventually{model.completedJobCount==1}
        XCTAssertEqual(model.probes[song.id]?.state,"verified")
        await probeGate.release();try await eventually{!model.isProbing}
        XCTAssertEqual(model.probes[song.id]?.state,"verified");XCTAssertEqual(model.probes[song.id]?.anonymous,true)
        XCTAssertEqual(model.sourceValidationSummary("qq"),"当前结果：匿名整首已验证 1 首 · 登录整首已验证 0 首 · 仅可试读 0 首")
    }
    @MainActor func testAccountReplacementRevokesOnlyAffectedAuthenticatedProof()throws {
        let root=root();defer{try? FileManager.default.removeItem(at:root)}
        func accounts(_ revision:String)->[String:Any]{["schema":2,"accounts":["netease":["revision":revision,"nickname":"Synthetic account","verified":true]]]}
        try AppFiles.write(accounts(String(repeating:"a",count:32)),name:"accounts.json",at:root)
        let model=AppModel(storeURL:root,engine:BackendClient{_,_,_ in XCTFail("Metadata changes must not read a session");return [:]})
        defer{model.shutdown()}
        model.refreshAccounts();model.tracks=[track("member",source:"netease"),track("public")]
        model.probes["member"]=ProbeStatus(state:"verified",anonymous:false)
        model.probes["public"]=ProbeStatus(state:"verified",anonymous:true)
        try AppFiles.write(accounts(String(repeating:"b",count:32)),name:"accounts.json",at:root)
        model.accountChanged("netease")
        XCTAssertNil(model.probes["member"]);XCTAssertEqual(model.probes["public"]?.anonymous,true)
        XCTAssertTrue(model.sourceValidationSummary("netease").contains("登录整首已验证 0 首"))
        XCTAssertTrue(model.sourceValidationSummary("qq").contains("匿名整首已验证 1 首"))
    }
    @MainActor func testIncompleteDownloadFailureKeepsOnlyTheEarlierSmallReadProof()async throws {
        let root=root();defer{try? FileManager.default.removeItem(at:root)}
        let model=AppModel(storeURL:root,engine:BackendClient{_,_,_ in throw EngineFailure(reason:"Synthetic truncation",solution:"换其他版本。",code:"audio_incomplete")})
        defer{model.shutdown()}
        let song=track("truncated");model.tracks=[song];model.probes[song.id]=ProbeStatus(state:"passed")
        model.downloadTrack(song);try await eventually{model.jobs.first?.state=="failed"}
        XCTAssertEqual(model.probes[song.id]?.state,"passed")
        XCTAssertNil(model.probes[song.id]?.anonymous)
        XCTAssertEqual(model.sourceValidationSummary("qq"),"当前结果：匿名整首已验证 0 首 · 登录整首已验证 0 首 · 仅可试读 1 首")
    }
}
