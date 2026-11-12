import Foundation
import XCTest
@testable import ChengWen

final class NativeMusicEngineTests:XCTestCase {
    func testAnonymousSearchRetriesOneTransientFailureButNeverPlatformDenial() async throws {
        var attempts=0
        let result=try await NativeMusicEngine.readSearch {
            attempts+=1
            if attempts==1 {throw URLError(.networkConnectionLost)}
            return ["count":1]
        }
        XCTAssertEqual(result["count"] as? Int,1);XCTAssertEqual(attempts,2)
        attempts=0
        do {_=try await NativeMusicEngine.readSearch {attempts+=1;throw NativeHTTP.status(429)};XCTFail("Denial accepted")}
        catch {XCTAssertEqual(attempts,1)}
        attempts=0
        do {_=try await NativeMusicEngine.readSearch {attempts+=1;throw URLError(.timedOut)};XCTFail("Unbounded retry succeeded")}
        catch {XCTAssertEqual(attempts,2)}
    }
    func testSearchParsesBothDomesticMetadataAndRejectsInvalidIDs() {
        let netease=NativeMusicEngine.searchTrack(["id":33190124,"name":"Carefree","artists":[["name":"Synthetic"]],"album":["name":"Album"],"duration":205000],source:"netease")
        XCTAssertEqual(netease["duration"] as? String,"3:25")
        XCTAssertEqual(try NativeMusicEngine.songID(netease),"33190124")
        let kuwo=NativeMusicEngine.searchTrack(["MUSICRID":"MUSIC_123","NAME":"A&nbsp;B","ARTIST":"A\\\\u0026B","DURATION":"18"],source:"kuwo")
        XCTAssertEqual(kuwo["title"] as? String,"A B")
        XCTAssertEqual(kuwo["artist"] as? String,"A&B")
        XCTAssertTrue(AudioTrack(raw:kuwo).fragment)
        XCTAssertTrue(NativeMusicEngine.searchTrack(["id":Double.infinity],source:"netease").isEmpty)
        XCTAssertFalse(NativeMusicEngine.validID("１２３"))
        XCTAssertEqual(NativeMusicEngine.duration(.infinity),"—")
    }
    func testLegacyObjectParserOnlyDecodesData() throws {
        let value=try NativeHTTP.decodeObject(Data("{'abslist':[{'NAME':'It\\'s \\\"fine\\\"','DURATION':'18','payInfo':None}], 'valid':True}".utf8))
        XCTAssertEqual((value["abslist"] as? [[String:Any]])?.first?["NAME"] as? String,"It's \"fine\"")
        XCTAssertEqual(value["valid"] as? Bool,true)
        XCTAssertThrowsError(try NativeHTTP.decodeObject(Data("{'x':__import__('os').system('echo unsafe')}".utf8)))
        XCTAssertThrowsError(try NativeHTTP.decodeObject(Data("{'x':function(){return 1}}".utf8)))
        let query=NativeHTTP.url("https://example.test/",query:["s":"A+B & C"])
        XCTAssertTrue(query.absoluteString.contains("%2B"))
    }
    func testTrustedLegacyCDNRedirectIsUpgradedAndNeverLeaksCredentials() {
        var request=URLRequest(url:URL(string:"http://m10.music.126.net/audio.mp3?public=1")!)
        request.setValue("synthetic",forHTTPHeaderField:"Cookie")
        let upgraded=NativeAudioTransfer.safeRedirect(request,loopbackOrigin:false)
        XCTAssertEqual(upgraded?.url?.scheme,"https")
        XCTAssertEqual(upgraded?.url?.host,"m10.music.126.net")
        XCTAssertNil(upgraded?.value(forHTTPHeaderField:"Cookie"))
        XCTAssertNil(NativeAudioTransfer.safeRedirect(URLRequest(url:URL(string:"http://unknown.example/audio")!),loopbackOrigin:false))
        XCTAssertNil(NativeAudioTransfer.safeRedirect(URLRequest(url:URL(string:"https://127.0.0.1/audio")!),loopbackOrigin:false))
        XCTAssertNil(NativeAudioTransfer.safeRedirect(URLRequest(url:URL(string:"https://user:pass@example.test/audio")!),loopbackOrigin:false))
    }
    func testNativeAudioPipelineAllFormatsAndBoundedPreview() async throws {
        let result=try await NativeEngineSmoke.run()
        XCTAssertEqual(result["passed"] as? Bool,true)
        XCTAssertEqual(result["no_python"] as? Bool,true)
        XCTAssertEqual((result["output_formats"] as? [String])?.count,5)
    }
    func testPublishDoesNotFollowOrReplaceAnExistingSymlink() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer{try? FileManager.default.removeItem(at:root)}
        let existing=root.appendingPathComponent("existing");try Data("old".utf8).write(to:existing)
        try FileManager.default.createSymbolicLink(at:root.appendingPathComponent("track.mp3"),withDestinationURL:existing)
        let staged=root.appendingPathComponent("staged");try Data("new".utf8).write(to:staged)
        let published=try NativeMusicEngine.publish(staged,in:root,name:"track",ext:"mp3")
        XCTAssertEqual(published.lastPathComponent,"track (2).mp3")
        XCTAssertEqual(try String(contentsOf:existing),"old")
        XCTAssertEqual(try String(contentsOf:published),"new")
        XCTAssertFalse(NativeMusicEngine.safeName("../bad/name\n").contains("/"))
        XCTAssertLessThanOrEqual(NativeMusicEngine.safeName(String(repeating:"音乐🎵",count:100)).utf8.count,180)
    }
    func testCancelledTransferNeverBeginsOrCreatesOutput() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let transfer=NativeAudioTransfer(destination:root)
        transfer.cancel()
        do {_=try await transfer.run(url:URL(string:"http://127.0.0.1:1/audio")!,headers:[:]);XCTFail("Canceled work succeeded")}
        catch {XCTAssertTrue(error is CancellationError)}
        XCTAssertFalse(FileManager.default.fileExists(atPath:root.path))
    }
    func testOriginalMP3WithLyingXingDurationIsRejectedAfterFullDecode() async throws {
        guard let ffmpeg=NativeTool.find("ffmpeg") else{throw XCTSkip("External audio tools not installed")}
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer{try? FileManager.default.removeItem(at:root)}
        let full=root.appendingPathComponent("full.mp3")
        _=try await NativeTool.run(ffmpeg,["-nostdin","-hide_banner","-loglevel","error","-f","lavfi","-i","sine=frequency=440:duration=120","-c:a","libmp3lame","-q:a","4",full.path])
        let data=try Data(contentsOf:full)
        let fixture=try NativeFixtureServer(audio:Data(data.prefix(data.count/2)))
        try await fixture.start();defer{fixture.stop()}
        let output=root.appendingPathComponent("result",isDirectory:true)
        do {
            _=try await NativeMusicEngine.download(["title":"Truncated","artist":"Synthetic"],resolved:NativeResolvedAudio(url:fixture.url(),expectedDuration:120,container:"mp3"),directory:output,format:"original",saveLyrics:false,event:{_,_ in})
            XCTFail("Incomplete audio published")
        } catch let failure as EngineFailure {
            // Strict FFmpeg decoding may reject a broken frame before the
            // independent header-versus-decoded-duration check can run.
            XCTAssertTrue(["audio_invalid","audio_incomplete"].contains(failure.code))
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath:output.path),[])
    }
}
