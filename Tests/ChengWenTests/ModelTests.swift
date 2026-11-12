import XCTest
@testable import ChengWen

final class ModelTests:XCTestCase {
    func testSettingsKeepKnownFormatsAndClampLimits() {
        let settings=AppSettings(["format":"invalid","limit":100,"timeout":1,"concurrency":7,"save_lyrics":false,"sources":["netease","obsolete"]])
        XCTAssertEqual(settings.format,"mp3");XCTAssertEqual(settings.limit,30);XCTAssertEqual(settings.timeout,15);XCTAssertEqual(settings.concurrency,4)
        XCTAssertFalse(settings.saveLyrics);XCTAssertEqual(settings.sources,["netease"])
    }
    func testFragmentHeuristicDoesNotMarkUnknownDuration() {
        XCTAssertTrue(AudioTrack(raw:["id":"1","duration":"0:18"]).fragment)
        XCTAssertFalse(AudioTrack(raw:["id":"2","duration":"3:12"]).fragment)
        XCTAssertFalse(AudioTrack(raw:["id":"3","duration":"—"]).fragment)
    }
    func testHistoryNeverContainsMediaURLsOrCredentials() {
        let track=AudioTrack(raw:["id":"1","title":"Test","url":"https://example.test/token/private","cookies":["secret":"value"],"headers":["Authorization":"private"],"metadata":["sid":"private"]])
        let job=DownloadJob(track:track,format:"mp3",directory:"/tmp",lyrics:true)
        let text=String(data:try! JSONSerialization.data(withJSONObject:job.history),encoding:.utf8)!
        XCTAssertFalse(text.contains("private"));XCTAssertFalse(text.contains("Authorization"));XCTAssertFalse(text.contains("cookies"))
    }
    func testActiveHistoryBecomesInterrupted() {
        let job=DownloadJob(history:["id":"old","track":["id":"song"],"state":"downloading","format":"mp3"])
        XCTAssertEqual(job?.state,"interrupted");XCTAssertFalse(job?.active ?? true)
    }
    func testSettingsAtomicRoundTrip() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:root)}
        let original=AppSettings(["recent":["new","old"],"sources":["kuwo"],"format":"flac"])
        try AppFiles.write(original.dictionary,name:"settings.json",at:root)
        let restored=AppSettings(AppFiles.read("settings.json",at:root) as! [String:Any])
        XCTAssertEqual(restored.recent,["new","old"]);XCTAssertEqual(restored.sources,["kuwo"]);XCTAssertEqual(restored.format,"flac")
    }
}
