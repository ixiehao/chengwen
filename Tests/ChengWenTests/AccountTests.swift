import XCTest
import Security
@testable import ChengWen

final class MemoryAccountVault:NativeAccountVault,@unchecked Sendable {
    let lock=NSLock()
    var status:OSStatus=errSecSuccess
    var saved:[String:Data]=["old-active":Data("synthetic-old".utf8)]
    var removed:[String]=[]
    func stage(account:String,data:Data)->OSStatus {lock.lock();defer{lock.unlock()};if status == errSecSuccess{saved[account]=data};return status}
    func remove(account:String){lock.lock();defer{lock.unlock()};removed.append(account);saved.removeValue(forKey:account)}
}
final class AccountTests:XCTestCase {
    func testOfficialIdentityRequiresMatchingPositiveUID() throws {
        let valid:[String:Any]=["code":200,"uid":"123","profile_uid":"123","origin":"https://music.163.com","nickname":"Synthetic","userAgent":"Synthetic UA"]
        XCTAssertEqual(try NativeAccountValidation.neteaseIdentity(valid).uid,"123")
        for change:[String:Any] in [["code":200.5],["uid":"0","profile_uid":"0"],["profile_uid":"456"],["origin":"https://example.test"]] {
            var value=valid;value.merge(change){_,new in new}
            XCTAssertThrowsError(try NativeAccountValidation.neteaseIdentity(value))
        }
    }
    func testUserAgentRejectsCRLF() {
        for value in ["bad\rvalue","bad\nvalue","bad\r\nvalue",""] {XCTAssertThrowsError(try NativeAccountValidation.userAgent(value))}
    }
    func testCookiesAreScopedAndExpiredCookiesRejected() {
        func cookie(_ domain:String,_ name:String="MUSIC_U",expiry:Date?=nil)->HTTPCookie {
            var fields:[HTTPCookiePropertyKey:Any]=[.name:name,.value:"synthetic",.domain:domain,.path:"/"]
            if let expiry=expiry{fields[.expires]=expiry}
            return HTTPCookie(properties:fields)!
        }
        let records=NativeAccountValidation.cookieRecords([cookie(".music.163.com"),cookie(".example.test"),cookie(".163.com","other"),cookie(".music.163.com",expiry:Date(timeIntervalSinceNow:-60))],platform:"netease")
        XCTAssertEqual(records.count,1)
        XCTAssertTrue(NativeAccountValidation.cookieRecords([cookie(".music.163.com")],platform:"kuwo").isEmpty)
    }
    func testNavigationCannotLeaveOfficialHTTPSOrigins() {
        XCTAssertTrue(NativeAccountValidation.allowsMainURL(URL(string:"https://music.163.com/#/login")!,platform:"netease"))
        for value in ["http://music.163.com","https://163.com.example.test","https://user:secret@music.163.com","https://music.163.com:444"] {XCTAssertFalse(NativeAccountValidation.allowsMainURL(URL(string:value)!,platform:"netease"))}
    }
    @MainActor func testFailedCandidateSavePreservesOldAccount() async {
        let vault=MemoryAccountVault();vault.status=errSecAuthFailed
        var activations=0
        let request:NativeAccountRequest={_,_,_,_ in activations += 1;return {}}
        let identity:[String:Any]=["code":200,"uid":"123","profile_uid":"123","origin":"https://music.163.com","nickname":"Synthetic","userAgent":"Synthetic UA"]
        let cookie=HTTPCookie(properties:[.name:"MUSIC_U",.value:"synthetic",.domain:".music.163.com",.path:"/"])!
        let model=NativeAccountViewModel(platform:"netease",storeURL:URL(fileURLWithPath:"/tmp/chengwen-native-unit-test"),request:request,vault:vault,autoLoadWeb:false,ownedSessionReader:{completion in completion(.success(NativeOwnedAccountSession(identityResponse:identity,cookies:[cookie])))},onChange:{})
        model.connectOwnedWebSession()
        for _ in 0..<100 {if !model.isBusy{break};try? await Task.sleep(nanoseconds:10_000_000)}
        XCTAssertEqual(activations,0);XCTAssertNotNil(vault.saved["old-active"]);model.close()
    }
}
