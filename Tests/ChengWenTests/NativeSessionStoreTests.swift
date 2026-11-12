import Foundation
import XCTest
@testable import ChengWen

private final class SessionMemoryVault:NativeSessionVault,@unchecked Sendable {
    private let lock=NSLock()
    private var values:[String:Data]=[:]
    var afterSave:(()->Void)?
    var afterDelete:(()->Void)?
    var failSave=false
    var failDelete=false
    func load(account:String)throws->Data?{lock.lock();defer{lock.unlock()};return values[account]}
    func save(account:String,data:Data)throws {
        if failSave{throw NativeSessionStore.keychainFailure()}
        lock.lock();values[account]=data;lock.unlock();afterSave?()
    }
    func delete(account:String)throws{if failDelete{throw NativeSessionStore.keychainFailure()};lock.lock();values.removeValue(forKey:account);lock.unlock();afterDelete?()}
    var keys:Set<String>{lock.lock();defer{lock.unlock()};return Set(values.keys)}
}
private final class Requests:@unchecked Sendable {
    private let lock=NSLock()
    private var values:[(URL,[String:String],String,Data?)]=[]
    func append(_ url:URL,_ headers:[String:String],_ method:String,_ body:Data?){lock.lock();values.append((url,headers,method,body));lock.unlock()}
    var all:[(URL,[String:String],String,Data?)]{lock.lock();defer{lock.unlock()};return values}
}
final class NativeSessionStoreTests:XCTestCase {
    private func root()->URL{FileManager.default.temporaryDirectory.appendingPathComponent("chengwen-session-native-"+UUID().uuidString)}
    private let profile:[String:Any]=["code":200,"account":["id":123],"profile":["userId":123,"nickname":"Synthetic member"]]
    private func secret(_ platform:String="netease",revision:String)->[String:Any] {
        let cookies:[[String:Any]]=platform=="netease" ? [["name":"MUSIC_U","value":"synthetic-session-secret","domain":".music.163.com","path":"/"]] : [["name":"userid","value":"123","domain":".kuwo.cn","path":"/"],["name":"sid","value":"synthetic-sid_suffix","domain":".kuwo.cn","path":"/"]]
        return ["cookies":cookies,"user_agent":"Synthetic UA","revision":revision,"staged_at":Date().timeIntervalSince1970,"native_identity":["code":200,"origin":"https://music.163.com","uid":"123","profile_uid":"123","nickname":"Synthetic","verified":true],"device":["id":String(repeating:"b",count:32),"user":"1234567890"]]
    }
    private func old(_ store:NativeSessionStore,_ platform:String="netease")throws->[String:Any] {
        let revision=String(repeating:"a",count:32)
        try AppFiles.write(["schema":2,"accounts":[platform:["revision":revision,"storage":"revision","nickname":"Old synthetic"]]],name:"accounts.json",at:store.root)
        try store.vault.save(account:store.key(platform,revision),data:JSONSerialization.data(withJSONObject:secret(platform,revision:revision)))
        return store.references()[platform]!
    }
    private func candidate(_ store:NativeSessionStore,_ platform:String="netease",change:([String:Any])->[String:Any]={$0})throws->[String:Any] {
        let revision=String(repeating:"c",count:32)
        try store.vault.save(account:store.key(platform,revision),data:JSONSerialization.data(withJSONObject:change(secret(platform,revision:revision))))
        return ["store":store.root.path,"platform":platform,"revision":revision]
    }
    func testAccountsReadsOnlySafeMetadataAndNeverKeychain() async throws {
        struct Forbidden:NativeSessionVault {func load(account:String)throws->Data?{XCTFail("Must not read Keychain");return nil};func save(account:String,data:Data)throws{XCTFail()};func delete(account:String)throws{XCTFail()}}
        let root=root();defer{try? FileManager.default.removeItem(at:root)}
        let store=NativeSessionStore(root:root,vault:Forbidden(),api:{_,_,_,_ in XCTFail("Must not access network");return [:]})
        let result=try await store.perform("accounts",payload:[:]);XCTAssertTrue((result["records"] as? [String:Any])?.isEmpty==true)
    }
    func testOfficialNetEaseCandidateValidatesAndCommitsNewVersionWithoutPublicSecrets() async throws {
        let root=root(),vault=SessionMemoryVault(),requests=Requests();defer{try? FileManager.default.removeItem(at:root)}
        let profile=self.profile
        let store=NativeSessionStore(root:root,vault:vault,api:{url,headers,method,body in requests.append(url,headers,method,body);return profile})
        let previous=try old(store),payload=try candidate(store)
        let result=try await store.perform("activate_account",payload:payload)
        let ref=try XCTUnwrap((result["refs"] as? [String:[String:Any]])?["netease"])
        XCTAssertNotEqual(ref["revision"] as? String,previous["revision"] as? String)
        XCTAssertThrowsError(try store.assertCurrent(previous));XCTAssertNoThrow(try store.assertCurrent(ref))
        let loaded=try store.load(ref);XCTAssertEqual(loaded["user_agent"] as? String,"Synthetic UA")
        XCTAssertEqual(vault.keys,[store.key("netease",ref["revision"] as? String)])
        let publicData=String(data:try JSONSerialization.data(withJSONObject:result),encoding:.utf8)!
        for value in ["synthetic-session-secret","MUSIC_U","cookies","user_agent","profile_uid"]{XCTAssertFalse(publicData.contains(value))}
        XCTAssertEqual(requests.all.count,1);XCTAssertEqual(requests.all.first?.1["Cookie"],"MUSIC_U=synthetic-session-secret")
    }
    func testInvalidCandidatesNeverReplaceOldSession() async throws {
        for field in ["staged_at","origin","uid","cookie","user_agent"] {
            let root=root(),vault=SessionMemoryVault();defer{try? FileManager.default.removeItem(at:root)}
            let store=NativeSessionStore(root:root,vault:vault,api:{_,_,_,_ in XCTFail("Invalid candidate must not make a request");return [:]})
            let previous=try old(store)
            let payload=try candidate(store){raw in
                var value=raw
                switch field {
                case "staged_at":value[field]=Date().timeIntervalSince1970-301
                case "origin":var identity=value["native_identity"] as! [String:Any];identity["origin"]="https://example.invalid";value["native_identity"]=identity
                case "uid":var identity=value["native_identity"] as! [String:Any];identity["profile_uid"]="456";value["native_identity"]=identity
                case "cookie":value["cookies"]=[["name":"MUSIC_U","value":"synthetic","domain":".example.invalid","path":"/"]]
                default:value[field]="invalid\r\nHeader"
                };return value
            }
            do{_=try await store.perform("activate_account",payload:payload);XCTFail("Must reject \(field)")}catch{}
            XCTAssertNoThrow(try store.load(previous));XCTAssertEqual(vault.keys.count,1)
        }
    }
    func testSaveFailureAndCancellationAfterStagingPreserveOldAccount() async throws {
        for cancel in [false,true] {
            let root=root(),vault=SessionMemoryVault();defer{try? FileManager.default.removeItem(at:root)}
            let profile=self.profile
            let store=NativeSessionStore(root:root,vault:vault,api:{_,_,_,_ in profile})
            let previous=try old(store),payload=try candidate(store)
            if cancel{vault.afterSave={withUnsafeCurrentTask{$0?.cancel()}}}else{vault.failSave=true}
            let task=Task{try await store.perform("activate_account",payload:payload)}
            do{_=try await task.value;XCTFail("Must fail before commit")}catch{}
            vault.afterSave=nil;vault.failSave=false
            XCTAssertNoThrow(try store.load(previous));XCTAssertEqual(vault.keys,[store.key("netease",previous["revision"] as? String)])
        }
    }
    func testCancellationAfterCommitKeepsSuccessfulNewReference() async throws {
        let root=root(),vault=SessionMemoryVault();defer{try? FileManager.default.removeItem(at:root)}
        let profile=self.profile
        let store=NativeSessionStore(root:root,vault:vault,api:{_,_,_,_ in profile})
        _=try old(store);let payload=try candidate(store)
        vault.afterDelete={withUnsafeCurrentTask{$0?.cancel()}}
        let result=try await Task{try await store.perform("activate_account",payload:payload)}.value
        vault.afterDelete=nil
        let ref=try XCTUnwrap((result["refs"] as? [String:[String:Any]])?["netease"])
        XCTAssertNoThrow(try store.load(ref));XCTAssertEqual(vault.keys.count,1)
    }
    func testLogoutRevokesReferenceEvenWhenKeychainCleanupFails() async throws {
        let root=root(),vault=SessionMemoryVault();defer{try? FileManager.default.removeItem(at:root)}
        let store=NativeSessionStore(root:root,vault:vault,api:{_,_,_,_ in [:]})
        let ref=try old(store)
        vault.failDelete=true
        do{_=try await store.perform("account",payload:["platform":"netease","action":"logout"]);XCTFail("Must report Keychain cleanup failure")}catch let error as EngineFailure{XCTAssertEqual(error.code,"keychain")}
        XCTAssertThrowsError(try store.assertCurrent(ref));XCTAssertEqual(vault.keys.count,1)
    }
    func testLogoutDuringFirstConnectionPreventsLateActivation() async throws {
        let root=root(),vault=SessionMemoryVault();defer{try? FileManager.default.removeItem(at:root)}
        let profile=self.profile
        let store=NativeSessionStore(root:root,vault:vault,api:{_,_,_,_ in
            // A second window revokes the account during the first request.
            try NativeSessionStore(root:root,vault:vault).logout("netease")
            return profile
        })
        let payload=try candidate(store)
        do{_=try await store.perform("activate_account",payload:payload);XCTFail("Explicit logout must win")}
        catch let error as EngineFailure{XCTAssertEqual(error.code,"account_changed")}
        XCTAssertTrue(store.references().isEmpty);XCTAssertTrue(vault.keys.isEmpty)
    }
    func testHTTPAuthFailuresBlockCurrentRevisionWithoutLeakingSignedURL() async throws {
        for status in [401,403,429] {
            let root=root(),vault=SessionMemoryVault();defer{try? FileManager.default.removeItem(at:root)}
            let store=NativeSessionStore(root:root,vault:vault,api:{_,_,_,_ in throw NativeHTTP.status(status)})
            let ref=try old(store)
            do{_=try await NativeAccountAdapters.resolve(track:["source":"netease","url":"https://music.163.com/song?id=456"],reference:ref,store:store);XCTFail("Must stop on HTTP auth failure")}
            catch let error as EngineFailure{XCTAssertEqual(error.code,status==401 ? "account_expired" : "account_risk");XCTAssertTrue(error.technical.isEmpty)}
            XCTAssertThrowsError(try store.assertCurrent(ref))
        }
    }
    func testClaimedWebIdentityCannotActivateDifferentCookieAccount() async throws {
        let root=root(),vault=SessionMemoryVault();defer{try? FileManager.default.removeItem(at:root)}
        let store=NativeSessionStore(root:root,vault:vault,api:{_,_,_,_ in ["code":200,"account":["id":456],"profile":["userId":456,"nickname":"Different synthetic account"]]})
        let ref=try old(store),payload=try candidate(store)
        do{_=try await store.perform("activate_account",payload:payload);XCTFail("Mismatched identity must not activate")}
        catch let failure as EngineFailure{XCTAssertEqual(failure.code,"account_changed")}
        XCTAssertNoThrow(try store.load(ref));XCTAssertEqual(vault.keys.count,1)
    }
    func testSessionCookiesCannotBeAttachedToCDNURLsOrInjectedHeaders() async throws {
        XCTAssertThrowsError(try NativeAccountAdapters.filteredCookies([["name":"MUSIC_U","value":"bad\r\nInjected: true","domain":".music.163.com","path":"/"]],platform:"netease"))
        let root=root(),vault=SessionMemoryVault();defer{try? FileManager.default.removeItem(at:root)}
        let profile=self.profile
        let store=NativeSessionStore(root:root,vault:vault,api:{url,_,_,_ in url.path.contains("account/get") ? profile : ["code":200,"data":["code":200,"id":456,"type":"mp3","url":"https://m2.music.126.net/full.mp3?secret=synthetic-session-secret"]]})
        let ref=try old(store)
        do{_=try await NativeAccountAdapters.resolve(track:["source":"netease","url":"https://music.163.com/song?id=456"],reference:ref,store:store);XCTFail("Never publish credential-bearing media")}
        catch let failure as EngineFailure{XCTAssertEqual(failure.code,"account_response");XCTAssertFalse(failure.reason.contains("synthetic-session-secret"))}
    }
    func testRiskStopsFurtherRequestsAndDoesNotLeakResponseDetails() async throws {
        let root=root(),vault=SessionMemoryVault(),requests=Requests();defer{try? FileManager.default.removeItem(at:root)}
        let store=NativeSessionStore(root:root,vault:vault,api:{url,headers,method,body in requests.append(url,headers,method,body);return ["code":200,"data":["code":-462],"userinfo":"private-server-content"]})
        let ref=try old(store),track:[String:Any]=["source":"netease","url":"https://music.163.com/song?id=456"]
        for _ in 0..<2 {
            do{_=try await NativeAccountAdapters.resolve(track:track,reference:ref,store:store);XCTFail("Risk must stop")}
            catch let error as EngineFailure{XCTAssertEqual(error.code,"account_risk");XCTAssertFalse(error.reason.contains("private"));XCTAssertTrue(error.technical.isEmpty)}
        }
        XCTAssertEqual(requests.all.count,1)
    }
    func testNetEaseSongGrantRejectsTrialsMismatchAndEncryptedFormats() async throws {
        for mutation in ["trial","id","type"] {
            let root=root(),vault=SessionMemoryVault();defer{try? FileManager.default.removeItem(at:root)}
            let profile=self.profile
            let store=NativeSessionStore(root:root,vault:vault,api:{url,_,_,_ in
                if url.path.contains("account/get"){return profile}
                var media:[String:Any]=["code":200,"id":456,"url":"https://m2.music.126.net/full.mp3","type":"mp3"]
                if mutation=="trial"{media["freeTrialInfo"]=["start":0,"end":30]}else if mutation=="id"{media["id"]=999}else{media["type"]="ncm"}
                return ["code":200,"data":media]
            })
            let ref=try old(store)
            do{_=try await NativeAccountAdapters.resolve(track:["source":"netease","url":"https://music.163.com/song?id=456"],reference:ref,store:store);XCTFail("Must reject \(mutation)")}
            catch let error as EngineFailure{XCTAssertEqual(error.code,"account_permission")}
        }
    }
    func testNetEaseGrantedMediaUsesOnlyCleanCDNHeaders() async throws {
        let root=root(),vault=SessionMemoryVault();defer{try? FileManager.default.removeItem(at:root)}
        let profile=self.profile
        let store=NativeSessionStore(root:root,vault:vault,api:{url,_,_,_ in url.path.contains("account/get") ? profile : ["code":200,"data":["code":200,"id":456,"url":"http://m2.music.126.net/full.mp3","type":"mp3"]]})
        let ref=try old(store)
        let result=try await NativeAccountAdapters.resolve(track:["source":"netease","url":"https://music.163.com/song?id=456","metadata":["duration_s":220]],reference:ref,store:store)
        XCTAssertEqual(result.url.scheme,"https");XCTAssertEqual(result.expectedDuration,220)
        XCTAssertEqual(Set(result.headers.keys),["User-Agent"])
        XCTAssertFalse(result.url.absoluteString.contains("synthetic"))
    }
    func testKuwoRequiresWebNativeAndSongRightsThenSignsOnlyAuthorizedMedia() async throws {
        let root=root(),vault=SessionMemoryVault(),requests=Requests();defer{try? FileManager.default.removeItem(at:root)}
        let store=NativeSessionStore(root:root,vault:vault,api:{url,headers,method,body in
            requests.append(url,headers,method,body)
            if url.path.contains("checkLogin"){return ["status":200]}
            if url.host=="loginserver.kuwo.cn"{return ["result":"ok"]}
            if url.host=="musicpay.kuwo.cn" {return ["result":"ok","errorcode":"0","uid":"123","timestamp":"1234567890","songs":[["id":"456","payInfo":["nplay":"01","ndown":"01"],"token":["S":"synthetic-grant"],"audio":[["quality":"S","br":320,"fmt":"MP3H","policy":"vip","cost":0,"st":"0","avaliable":1]]]]]}
            return ["code":200,"loginSid":"synthetic-sid","duration":220,"data":["rid":"456","type":0,"startPos":0,"endPos":0,"format":"mp3","bitrate":320,"surl":"https://music.kuwo.cn/full.mp3"]]
        })
        let ref=try old(store,"kuwo")
        let resolved=try await NativeAccountAdapters.resolve(track:["source":"kuwo","url":"https://www.kuwo.cn/yinyue/456"],reference:ref,store:store)
        XCTAssertEqual(resolved.expectedDuration,220);XCTAssertNil(resolved.headers["Cookie"])
        XCTAssertEqual(requests.all.count,4)
        for request in requests.all where request.0.host != "www.kuwo.cn"{XCTAssertNil(request.1["Cookie"])}
        let mediaRequest=requests.all.last!.0.absoluteString
        XCTAssertFalse(mediaRequest.contains("synthetic-sid"));XCTAssertTrue(mediaRequest.contains("f=kwxs"))
    }
    func testKuwoRejectsTrialEncryptedWrongSongOrSessionInMediaURL() throws {
        let base:[String:Any]=["rid":"456","type":0,"startPos":0,"endPos":0,"format":"mp3","bitrate":320,"surl":"https://music.kuwo.cn/full.mp3"]
        for mutation:[String:Any] in [["endPos":30],["ekey":"encrypted"],["rid":"999"],["surl":"https://music.kuwo.cn/full.mp3?sid=synthetic-sid"]] {
            var data=base;data.merge(mutation){_,new in new}
            XCTAssertThrowsError(try NativeAccountAdapters.kuwoMedia(["code":200,"duration":220,"data":data],rid:"456",bitrate:320,sid:"synthetic-sid",expectedDuration:nil))
        }
    }
    func testNativeKuwoSigningMatchesIndependentMITVectors() throws {
        let source=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("fixtures/kuwo-codec-vectors.json")
        let vectors=try JSONSerialization.jsonObject(with:Data(contentsOf:source)) as! [String:Any]
        func hex(_ value:String)->Data{Data(stride(from:0,to:value.count,by:2).map{offset in let start=value.index(value.startIndex,offsetBy:offset);return UInt8(value[start..<value.index(start,offsetBy:2)],radix:16)!})}
        for row in vectors["digest"] as! [[String:String]]{XCTAssertEqual(NativeKuwoCrypto.digest(hex(row["data_hex"]!)),row["digest"])}
        for row in vectors["cipher"] as! [[String:String]]{XCTAssertEqual(try NativeKuwoCrypto.encrypt(hex(row["input_hex"]!),material:hex(row["key_material_hex"]!)),row["actual"])}
        for row in vectors["queries"] as! [[String:Any]]{XCTAssertEqual(try NativeKuwoCrypto.seal(row["values"] as! [String:String]),row["q"] as? String)}
    }
}
