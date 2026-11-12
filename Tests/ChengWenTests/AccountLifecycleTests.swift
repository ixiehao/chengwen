import Security
import XCTest
@testable import ChengWen

private final class BlockingCandidateVault:NativeAccountVault,@unchecked Sendable {
    let entered:XCTestExpectation
    let release=DispatchSemaphore(value:0)
    private let lock=NSLock()
    private var values=["old-active":Data("synthetic-old-session".utf8)]
    init(entered:XCTestExpectation){self.entered=entered}
    func stage(account:String,data:Data)->OSStatus {
        entered.fulfill();_ = release.wait(timeout:.now()+5)
        lock.lock();values[account]=data;lock.unlock();return errSecSuccess
    }
    func remove(account:String){lock.lock();values.removeValue(forKey:account);lock.unlock()}
    var accounts:Set<String>{lock.lock();defer{lock.unlock()};return Set(values.keys)}
}

final class AccountLifecycleTests:XCTestCase {
    @MainActor func testCloseDuringPendingCandidateWriteDeletesOnlyCandidateBeforeCleanupCompletes() async {
        let entered=expectation(description:"Synthetic candidate write started")
        let vault=BlockingCandidateVault(entered:entered)
        var activations=0
        let request:NativeAccountRequest={_,_,_,_ in activations += 1;return {}}
        let identity:[String:Any]=["code":200,"uid":"123","profile_uid":"123","origin":"https://music.163.com","nickname":"Synthetic","userAgent":"Synthetic UA"]
        let cookie=HTTPCookie(properties:[.name:"MUSIC_U",.value:"synthetic-only",.domain:".music.163.com",.path:"/"])!
        let model=NativeAccountViewModel(platform:"netease",storeURL:FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),request:request,vault:vault,autoLoadWeb:false,ownedSessionReader:{completion in completion(.success(NativeOwnedAccountSession(identityResponse:identity,cookies:[cookie])))},onChange:{})
        model.connectOwnedWebSession()
        await fulfillment(of:[entered],timeout:2)
        let cleanup=expectation(description:"Pending write and candidate deletion both finished")
        model.finishCandidateCleanup{cleanup.fulfill()}
        vault.release.signal()
        await fulfillment(of:[cleanup],timeout:3)
        // Give the deliberately late main-queue callback from stage() a turn.
        try? await Task.sleep(nanoseconds:30_000_000)
        XCTAssertEqual(activations,0)
        XCTAssertEqual(vault.accounts,["old-active"])
    }

    @MainActor func testLateOfficialWebReadAfterCloseDoesNotStageOrActivate() async {
        var readerCallback:((Result<NativeOwnedAccountSession,NativeAccountProblem>)->Void)?
        let vault=MemoryAccountVault()
        var activations=0
        let model=NativeAccountViewModel(platform:"netease",storeURL:FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),request:{_,_,_,_ in activations += 1;return {}},vault:vault,autoLoadWeb:false,ownedSessionReader:{readerCallback=$0},onChange:{})
        model.connectOwnedWebSession();model.close()
        let identity:[String:Any]=["code":200,"uid":"123","profile_uid":"123","origin":"https://music.163.com","userAgent":"Synthetic UA"]
        let cookie=HTTPCookie(properties:[.name:"MUSIC_U",.value:"synthetic-only",.domain:".music.163.com",.path:"/"])!
        readerCallback?(.success(NativeOwnedAccountSession(identityResponse:identity,cookies:[cookie])))
        let cleanup=expectation(description:"Closed account cleanup finished")
        model.finishCandidateCleanup{cleanup.fulfill()}
        await fulfillment(of:[cleanup],timeout:2)
        XCTAssertEqual(activations,0)
        XCTAssertEqual(Set(vault.saved.keys),["old-active"])
    }
}
