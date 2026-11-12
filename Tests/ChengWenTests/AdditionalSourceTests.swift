import Foundation
import Network
import XCTest
@testable import ChengWen

private final class SourceRequestLog:@unchecked Sendable {
    private let lock=NSLock()
    private var values:[(URL,[String:String],String,Data?)]=[]
    func add(_ url:URL,_ headers:[String:String],_ method:String,_ body:Data?){lock.lock();values.append((url,headers,method,body));lock.unlock()}
    var calls:[(URL,[String:String],String,Data?)]{lock.lock();defer{lock.unlock()};return values}
}
private final class AnonymousHeaderServer:@unchecked Sendable {
    private let listener:NWListener
    private let queue=DispatchQueue(label:"ChengWen.AdditionalSourceHeaderTest")
    private let lock=NSLock()
    private var requests:[String]=[]
    private var connections:[NWConnection]=[]
    private var port:UInt16=0
    init()throws {
        let parameters=NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host:.ipv4(.loopback),port:.any)
        listener=try NWListener(using:parameters)
    }
    func start()async throws {
        try await withCheckedThrowingContinuation{(continuation:CheckedContinuation<Void,Error>) in
            listener.stateUpdateHandler={state in
                switch state {
                case .ready:self.lock.lock();self.port=self.listener.port!.rawValue;self.lock.unlock();continuation.resume()
                case .failed(let error):continuation.resume(throwing:error)
                default:break
                }
            }
            listener.newConnectionHandler={connection in
                self.lock.lock();self.connections.append(connection);self.lock.unlock()
                connection.start(queue:self.queue);self.read(connection,bytes:Data())
            }
            listener.start(queue:queue)
        }
    }
    private func read(_ connection:NWConnection,bytes:Data) {
        connection.receive(minimumIncompleteLength:1,maximumLength:8192){data,_,complete,error in
            var bytes=bytes;bytes.append(data ?? Data())
            if bytes.range(of:Data("\r\n\r\n".utf8))==nil && bytes.count<16384 && !complete && error==nil{self.read(connection,bytes:bytes);return}
            self.lock.lock();self.requests.append(String(data:bytes,encoding:.utf8) ?? "");self.lock.unlock()
            let body=Data("{\"status\":1}".utf8)
            let header="HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
            connection.send(content:Data(header.utf8)+body,completion:.contentProcessed{_ in connection.cancel()})
        }
    }
    var request:String{lock.lock();defer{lock.unlock()};return requests.joined(separator:"\n")}
    var url:URL{lock.lock();defer{lock.unlock()};return URL(string:"http://127.0.0.1:\(port)/anonymous")!}
    func stop(){listener.cancel();lock.lock();let values=connections;connections=[];lock.unlock();values.forEach{$0.cancel()}}
}

final class AdditionalSourceTests:XCTestCase {
    private let qqMID="000X8SPS2CNqAO",qqMedia="002dJn9N3wz9dh",kgHash=String(repeating:"a",count:32)
    private func searchBody(_ source:String)->[String:Any] {
        switch source {
        case "qq":return ["code":0,"req":["code":0,"data":["body":["song":["list":[["mid":qqMID,"title":"<em>Synthetic</em> &amp; song","interval":277,"singer":[["name":"Synthetic singer"]],"album":["name":"Album"],"file":["media_mid":qqMedia],"pay":["pay_down":0]]]]]]]]
        case "kugou":return ["status":1,"data":["lists":[["FileHash":kgHash,"SongName":"<em>Synthetic</em>","SingerName":"Synthetic singer","Duration":72,"AlbumID":"123","AlbumName":"Album","PayType":0,"Privilege":0]]]]
        case "migu":return ["items":[["copyrightId":"60000012345","contentId":"123456","songId":"98765","songName":"Synthetic","duration":"3:10","singerList":[["name":"Synthetic singer"]],"album":"Album"]]]
        default:return ["data":["typeTrack":[["id":"T_SYNTHETIC","title":"Synthetic","duration":190,"artist":[["name":"Synthetic singer"]],"albumTitle":"Album"]]]]
        }
    }
    private func track(_ source:String)throws->[String:Any]{try XCTUnwrap(NativeAdditionalSources.parseSearch(searchBody(source),source:source).first)}
    private func resolution(_ source:String)->[String:Any] {
        switch source {
        case "qq":return ["code":0,"req_1":["code":0,"data":["sip":["http://sjy6.stream.qqmusic.qq.com/"],"midurlinfo":[["songmid":qqMID,"result":0,"filename":"C400\(qqMedia).m4a","purl":"C400\(qqMedia).m4a?anonymous=1"]]]]]
        case "kugou":return ["status":1,"errcode":0,"hash":kgHash,"timeLength":72,"pay_type":0,"privilege":0,"url":"https://sharefs.kugou.com/synthetic.mp3"]
        case "migu":return ["data":["copyrightId":"60000012345","duration":"3:10","url":"//freetyst.nf.migu.cn/synthetic+file.mp3"]]
        default:return ["data":["id":"T_SYNTHETIC","duration":190,"path":"https://audio.dmhmusic.com/synthetic.mp3"]]
        }
    }
    private func failure(_ code:String?=nil,_ operation:()throws->Void,file:StaticString=#filePath,line:UInt=#line) {
        do{try operation();XCTFail("Invalid platform response was accepted",file:file,line:line)}
        catch let error as EngineFailure{if let code=code{XCTAssertEqual(error.code,code,file:file,line:line)}}
        catch{XCTFail("Unclassified error: \(type(of:error))",file:file,line:line)}
    }
    func testFourPublicCatalogueSchemasHaveStableIdentityDurationAndNoSessions()throws {
        var ids=Set<String>()
        for source in ["qq","kugou","migu","qianqian"] {
            let value=try track(source),metadata=try XCTUnwrap(value["metadata"] as? [String:Any])
            XCTAssertEqual(value["source"] as? String,source)
            XCTAssertTrue(ids.insert(value["id"] as! String).inserted)
            XCTAssertGreaterThan(metadata["duration_s"] as? Double ?? 0,60)
            XCTAssertNil(metadata["account_ref"]);XCTAssertNil(value["cookies"]);XCTAssertNil(value["headers"])
            XCTAssertEqual(try track(source)["id"] as? String,value["id"] as? String)
            XCTAssertFalse((value["title"] as? String ?? "").contains("<em>"))
        }
    }
    func testLegacyQQAndKugouSearchShapesAndInvalidIDs()throws {
        let legacyQQ:[String:Any]=["code":0,"data":["song":["list":[["songmid":qqMID,"songname":"Legacy","albumname":"Album","singer":[["name":"Synthetic"]],"interval":100],["songmid":"../../../escape","interval":100]]]]]
        XCTAssertEqual(try NativeAdditionalSources.parseSearch(legacyQQ,source:"qq").count,1)
        let legacyKG:[String:Any]=["status":1,"data":["info":[["hash":kgHash.uppercased(),"songname":"Legacy","duration":90,"album_id":123],["hash":"z"+kgHash.dropFirst(),"duration":90]]]]
        let parsed=try NativeAdditionalSources.parseSearch(legacyKG,source:"kugou")
        XCTAssertEqual(parsed.count,1);XCTAssertEqual((parsed.first?["metadata"] as? [String:Any])?["song_id"] as? String,kgHash)
        for source in ["qq","kugou","migu","qianqian"]{failure{_=try NativeAdditionalSources.parseSearch(["unexpected":["new":"schema"]],source:source)}}
    }
    func testEmptyCatalogueIsValidAndRepeatedIdentitiesAreDeduplicated()throws {
        let empty:[String:[String:Any]]=["qq":["code":0,"data":["song":["list":[]]]],"kugou":["status":1,"data":["lists":[]]],"migu":["items":[]],"qianqian":["data":["typeTrack":[]]]]
        for (source,body) in empty{XCTAssertTrue(try NativeAdditionalSources.parseSearch(body,source:source).isEmpty)}
        let song:[String:Any]=["FileHash":kgHash,"SongName":"Synthetic","Duration":72]
        let body:[String:Any]=["status":1,"data":["lists":Array(repeating:song,count:35)]]
        XCTAssertEqual(try NativeAdditionalSources.parseSearch(body,source:"kugou",limit:30).count,1)
    }
    func testSearchRequestShapesUsePublicAnonymousEndpointsAndClampLimit()async throws {
        for source in ["qq","kugou","migu","qianqian"] {
            let log=SourceRequestLog(),response=searchBody(source)
            _=try await NativeAdditionalSources.search(source:source,keyword:"  Synthetic & music  ",limit:999,request:{url,headers,method,body in log.add(url,headers,method,body);return response})
            let call=try XCTUnwrap(log.calls.first)
            XCTAssertEqual(log.calls.count,1);XCTAssertEqual(call.0.scheme,"https")
            XCTAssertFalse(call.1.keys.contains{$0.lowercased()=="cookie" || $0.lowercased().contains("authorization")})
            let query=URLComponents(url:call.0,resolvingAgainstBaseURL:false)?.queryItems ?? []
            let fields=Dictionary(uniqueKeysWithValues:query.map{($0.name,$0.value ?? "")})
            if source=="qq" {
                XCTAssertEqual(call.0.host,"u.y.qq.com");XCTAssertEqual(call.2,"POST")
                let envelope=try JSONSerialization.jsonObject(with:try XCTUnwrap(call.3)) as! [String:Any]
                let req=envelope["req"] as! [String:Any],param=req["param"] as! [String:Any]
                XCTAssertEqual(req["module"] as? String,"music.search.SearchCgiService")
                XCTAssertEqual(param["query"] as? String,"Synthetic & music");XCTAssertEqual(param["num_per_page"] as? Int,30)
                XCTAssertEqual((envelope["comm"] as? [String:Any])?["uin"] as? String,"0")
            } else {
                XCTAssertEqual(call.2,"GET");XCTAssertNil(call.3)
                let key=source=="kugou" ? "pagesize" : "pageSize"
                XCTAssertEqual(fields[key],"30")
                XCTAssertEqual(fields[source=="kugou" ? "keyword" : source=="migu" ? "text" : "word"],"Synthetic & music")
            }
        }
    }
    func testInvalidSearchAndResolutionIdentityNeverInitiatesNetwork()async throws {
        let request:NativeAdditionalSources.Request={_,_,_,_ in XCTFail("Invalid input reached network");return [:]}
        for source in ["qq","kugou","migu","qianqian"] {
            do{_=try await NativeAdditionalSources.search(source:source,keyword:"   ",limit:1,request:request);XCTFail()}catch let error as EngineFailure{XCTAssertEqual(error.code,"invalid_request")}
            do{_=try await NativeAdditionalSources.resolve(["source":source,"metadata":["song_id":"../../invalid"]],request:request);XCTFail()}catch let error as EngineFailure{XCTAssertEqual(error.code,"source_response")}
        }
    }
    func testResolversSendOnlyPublicTrackIDsAndNeverForwardInjectedCredentials()async throws {
        for source in ["qq","kugou","migu","qianqian"] {
            let log=SourceRequestLog();var value=try track(source),metadata=value["metadata"] as! [String:Any]
            metadata["account_ref"]=["store":"/never-read","platform":"netease","revision":String(repeating:"a",count:32)]
            value["metadata"]=metadata;value["cookies"]=["synthetic":"private-secret"]
            value["headers"]=["Cookie":"private-secret","Authorization":"private-secret","Proxy-Authorization":"private-secret"]
            let response=resolution(source)
            let result=try await NativeAdditionalSources.resolve(value,request:{url,headers,method,body in log.add(url,headers,method,body);return response})
            let call=try XCTUnwrap(log.calls.first)
            let sent=call.0.absoluteString+call.1.description+(call.3.flatMap{String(data:$0,encoding:.utf8)} ?? "")
            XCTAssertFalse(sent.contains("private-secret"));XCTAssertFalse(sent.contains("never-read"))
            XCTAssertFalse(result.headers.keys.contains{$0.lowercased()=="cookie" || $0.lowercased().contains("authorization")})
            XCTAssertEqual(result.url.scheme,"https");XCTAssertGreaterThan(result.expectedDuration ?? 0,60)
            if source=="qq" {
                let envelope=try JSONSerialization.jsonObject(with:try XCTUnwrap(call.3)) as! [String:Any]
                let req=envelope["req_1"] as! [String:Any],param=req["param"] as! [String:Any]
                XCTAssertEqual(param["uin"] as? String,"0");XCTAssertEqual(param["loginflag"] as? Int,0)
                XCTAssertEqual(param["songmid"] as? [String],[qqMID]);XCTAssertNil(param["filename"])
                XCTAssertEqual(result.container,"m4a")
            } else if source=="kugou" {
                XCTAssertEqual(call.0.host,"m.kugou.com");XCTAssertEqual(call.0.path,"/app/i/getSongInfo.php")
                let params=URLComponents(url:call.0,resolvingAgainstBaseURL:false)!.queryItems!
                XCTAssertEqual(params.first{$0.name=="hash"}?.value,kgHash);XCTAssertEqual(params.first{$0.name=="cmd"}?.value,"playInfo")
            } else if source=="migu" {
                XCTAssertEqual(call.0.host,"app.c.nf.migu.cn");XCTAssertEqual(call.1["channel"],"0146951")
                XCTAssertTrue(result.url.absoluteString.contains("%2B"))
            } else {XCTAssertEqual(call.0.host,"music.91q.com");XCTAssertTrue(call.0.path.hasSuffix("/song/tracklink"))}
        }
    }
    func testOfficialCDNsAreHTTPSAndUnsafeOrProtectedURLsAreRejected()throws {
        let hosts=["qq":"sjy6.stream.qqmusic.qq.com","kugou":"sharefs.kugou.com","migu":"freetyst.nf.migu.cn","qianqian":"audio.dmhmusic.com"]
        for (source,host) in hosts {
            XCTAssertEqual(try NativeAdditionalSources.mediaURL("http://\(host)/song.mp3",source:source).scheme,"https")
            for value in ["https://\(host).example.invalid/song.mp3","https://user:pass@\(host)/song.mp3","http://\(host):80/song.mp3","file://\(host)/song.mp3","https://127.0.0.1/song.mp3"]{failure{_=try NativeAdditionalSources.mediaURL(value,source:source)}}
            for ext in ["QMC","kgm","mflac","mgg","m3u8","mpd"]{failure("audio_protected"){_=try NativeAdditionalSources.mediaURL("https://\(host)/song.\(ext)",source:source)}}
        }
    }
    func testWrongReturnedIdentityAndTrialFlagsAreRejectedForEverySource()throws {
        for source in ["qq","kugou","migu","qianqian"] {
            let value=try track(source)
            var wrong=resolution(source),preview=resolution(source)
            switch source {
            case "qq":
                var req=wrong["req_1"] as! [String:Any],data=req["data"] as! [String:Any],item=(data["midurlinfo"] as! [[String:Any]])[0]
                item["songmid"]="000WrongMID1234";data["midurlinfo"]=[item];req["data"]=data;wrong["req_1"]=req
                item["songmid"]=qqMID;item["is_trial"]=1;data["midurlinfo"]=[item];req["data"]=data;preview["req_1"]=req
            case "kugou":wrong["hash"]=String(repeating:"b",count:32);preview["is_free_part"]=1
            case "migu":var data=wrong["data"] as! [String:Any];data["copyrightId"]="60000099999";wrong["data"]=data;data["copyrightId"]="60000012345";data["auditionsLength"]=30;preview["data"]=data
            default:var data=wrong["data"] as! [String:Any];data["id"]="T_OTHER";wrong["data"]=data;data["id"]="T_SYNTHETIC";data["freePart"]=1;preview["data"]=data
            }
            failure("source_response"){_=try NativeAdditionalSources.parseResolution(wrong,track:value)}
            failure("audio_preview"){_=try NativeAdditionalSources.parseResolution(preview,track:value)}
        }
    }
    func testEmptyLinksAndKnownPlatformFailuresNeverBecomePlayable()throws {
        let empty:[String:[String:Any]]=["qq":["code":0,"req_1":["code":0,"data":["midurlinfo":[["songmid":qqMID,"result":104003,"purl":""]]]]],"kugou":["status":0,"errcode":0,"error":"需要付费","hash":kgHash,"url":""],"migu":["data":["url":""]],"qianqian":["data":["path":""]]]
        for (source,body) in empty {
            let value=try track(source)
            failure("source_permission"){_=try NativeAdditionalSources.parseResolution(body,track:value)}
        }
        var qq=resolution("qq"),req=qq["req_1"] as! [String:Any],data=req["data"] as! [String:Any],item=(data["midurlinfo"] as! [[String:Any]])[0]
        item["result"]=104003;data["midurlinfo"]=[item];req["data"]=data;qq["req_1"]=req
        failure{_=try NativeAdditionalSources.parseResolution(qq,track:track("qq"))}
        var kg=resolution("kugou");kg["status"]=0;kg["error"]="需要付费"
        failure{_=try NativeAdditionalSources.parseResolution(kg,track:track("kugou"))}
        var migu=resolution("migu");migu["code"]="100001"
        failure("source_permission"){_=try NativeAdditionalSources.parseResolution(migu,track:track("migu"))}
        var qianqian=resolution("qianqian");qianqian["state"]=false
        failure("source_permission"){_=try NativeAdditionalSources.parseResolution(qianqian,track:track("qianqian"))}
    }
    func testAdvertisedPreviewDurationIsRejectedBeforeAnyAudioRequest()throws {
        for source in ["kugou","migu","qianqian"] {
            let value=try track(source);var body=resolution(source)
            if source=="kugou"{body["timeLength"]=15}
            else{var data=body["data"] as! [String:Any];data["duration"]=15;body["data"]=data}
            failure("audio_preview"){_=try NativeAdditionalSources.parseResolution(body,track:value)}
        }
    }
    func testQQSuccessCodesMustBeExplicitFiniteNumbersAndMalformedDiagnosticsNeverTrap()throws {
        let song=try track("qq")
        for invalid:Any in [NSNull(),false,Double.nan,Double.infinity,1e100,"not-a-code",-1] {
            var outer=resolution("qq");outer["code"]=invalid
            failure("source_permission"){_=try NativeAdditionalSources.parseResolution(outer,track:song)}
            var response=resolution("qq"),req=response["req_1"] as! [String:Any]
            req["code"]=invalid;response["req_1"]=req
            failure("source_permission"){_=try NativeAdditionalSources.parseResolution(response,track:song)}
            req=resolution("qq")["req_1"] as! [String:Any]
            var data=req["data"] as! [String:Any],item=(data["midurlinfo"] as! [[String:Any]])[0]
            item["result"]=invalid;item["purl"]="";data["midurlinfo"]=[item];req["data"]=data;response["req_1"]=req
            failure("source_permission"){_=try NativeAdditionalSources.parseResolution(response,track:song)}
        }
    }
    func testAnonymousTransportStripsAllCredentialHeadersOnActualLocalWire()async throws {
        let server=try AnonymousHeaderServer();try await server.start();defer{server.stop()}
        let result=try await NativeAdditionalSources.network(server.url,["cOoKiE":"synthetic-secret","AUTHORIZATION":"synthetic-secret","Proxy-Authorization":"synthetic-secret","X-Synthetic":"public"],"GET",nil)
        XCTAssertEqual(result["status"] as? Int,1)
        let request=server.request.lowercased()
        XCTAssertTrue(request.contains("x-synthetic: public"));XCTAssertFalse(request.contains("synthetic-secret"));XCTAssertFalse(request.contains("cookie:"));XCTAssertFalse(request.contains("authorization:"))
    }
}
