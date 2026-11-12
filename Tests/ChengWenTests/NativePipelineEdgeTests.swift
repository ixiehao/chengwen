import Foundation
import XCTest
@testable import ChengWen

final class NativePipelineEdgeTests: XCTestCase {
    private func damagedMP3(in root: URL) async throws -> Data {
        guard let ffmpeg = NativeTool.find("ffmpeg") else {
            throw XCTSkip("External audio tools not installed")
        }
        let original = root.appendingPathComponent("synthetic.mp3")
        _ = try await NativeTool.run(ffmpeg, [
            "-nostdin", "-hide_banner", "-loglevel", "error", "-f", "lavfi",
            "-i", "sine=frequency=440:duration=8", "-c:a", "libmp3lame",
            "-b:a", "128k", original.path,
        ])
        var data = try Data(contentsOf: original)
        let offset = data.count / 2
        data.replaceSubrange(offset..<(offset + 1800), with: Data(repeating: 0, count: 1800))
        return data
    }

    private func assertDamagedInputRejected(format: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("chengwen-pipeline-edge-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try NativeFixtureServer(audio: await damagedMP3(in: root))
        try await fixture.start()
        defer { fixture.stop() }
        let output = root.appendingPathComponent("output", isDirectory: true)
        do {
            _ = try await NativeMusicEngine.download(
                ["title": "Damaged synthetic recording", "artist": "ChengWen local fixture"],
                resolved: NativeResolvedAudio(url: fixture.url(), expectedDuration: 8, container: "mp3"),
                directory: output, format: format, saveLyrics: false, event: { _, _ in }
            )
            XCTFail("Published a damaged bitstream as complete \(format) audio")
        } catch let failure as EngineFailure {
            XCTAssertEqual(failure.code, "audio_invalid")
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: output.path), [], "Failed validation must leave neither published audio nor a staging directory")
    }

    func testDamagedMP3OriginalIsRejectedBeforePublishing() async throws {
        try await assertDamagedInputRejected(format: "original")
    }

    func testDamagedMP3CannotBeHiddenByConversion() async throws {
        try await assertDamagedInputRejected(format: "mp3")
    }

    private func withLocalAudio(_ body: (NativeResolvedAudio, URL) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("chengwen-lyric-edge-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try NativeFixtureServer(audio: NativeFixtureServer.wave())
        try await fixture.start()
        defer { fixture.stop() }
        try await body(NativeResolvedAudio(url: fixture.url(), expectedDuration: 3, container: "wav"), root)
    }

    private var lyricTrack: [String: Any] {
        ["source": "netease", "title": "Local lyric fixture", "artist": "Synthetic", "metadata": ["song_id": "123"]]
    }

    func testLyricRequestFailureKeepsAudioAndReportsWarning() async throws {
        try await withLocalAudio { resolved, root in
            let result = try await NativeMusicEngine.download(lyricTrack, resolved: resolved, directory: root, format: "original", saveLyrics: true, event: { _, _ in }, lyricRequest: { id in
                XCTAssertEqual(id, "123")
                throw URLError(.cannotConnectToHost)
            })
            XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(result["path"] as? String)))
            XCTAssertEqual(result["full_verified"] as? Bool, true)
            XCTAssertTrue((result["warnings"] as? [String] ?? []).contains { $0.contains("歌词未能获取") })
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).count, 1)
        }
    }

    func testMissingAndEmptyLyricsAreNormalSuccessfulDownloads() async throws {
        for lyric in [nil, ""] as [String?] {
            try await withLocalAudio { resolved, root in
                let result = try await NativeMusicEngine.download(lyricTrack, resolved: resolved, directory: root, format: "original", saveLyrics: true, event: { _, _ in }, lyricRequest: { _ in lyric })
                XCTAssertEqual(result["warnings"] as? [String], [])
                XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).count, 1)
            }
        }
    }

    func testDisabledLyricsNeverInvokeTheRequester() async throws {
        try await withLocalAudio { resolved, root in
            var requested = false
            let result = try await NativeMusicEngine.download(lyricTrack, resolved: resolved, directory: root, format: "original", saveLyrics: false, event: { _, _ in }, lyricRequest: { _ in
                requested = true
                throw URLError(.cannotConnectToHost)
            })
            XCTAssertFalse(requested)
            XCTAssertEqual(result["warnings"] as? [String], [])
        }
    }

    func testCancellationAfterAudioCommitKeepsSuccessfulAudio() async throws {
        try await withLocalAudio { resolved, root in
            let track = lyricTrack
            let work = Task {
                try await NativeMusicEngine.download(track, resolved: resolved, directory: root, format: "original", saveLyrics: true, event: { _, _ in }, lyricRequest: { _ in
                    XCTAssertEqual(try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).filter { !$0.lastPathComponent.hasPrefix(".") }.count, 1)
                    withUnsafeCurrentTask { $0?.cancel() }
                    throw CancellationError()
                })
            }
            let result = try await work.value
            XCTAssertTrue(work.isCancelled)
            XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(result["path"] as? String)))
            XCTAssertEqual(result["full_verified"] as? Bool, true)
            XCTAssertTrue((result["warnings"] as? [String] ?? []).contains { $0.contains("歌词未能获取") })
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).count, 1)
        }
    }

    func testAudioToolTimeoutAndUserCancellationStayDistinct() async throws {
        let timeoutStarted = Date()
        do {
            _ = try await NativeTool.run("/bin/sleep", ["5"], timeout: 0.05)
            XCTFail("Tool deadline was ignored")
        } catch let failure as EngineFailure {
            XCTAssertEqual(failure.code, "tool_timeout")
        }
        XCTAssertLessThan(Date().timeIntervalSince(timeoutStarted), 3)

        let work = Task { try await NativeTool.run("/bin/sleep", ["5"], timeout: 10) }
        try await Task.sleep(nanoseconds: 50_000_000)
        work.cancel()
        do { _ = try await work.value; XCTFail("Cancelled tool succeeded") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    func testAudioToolFilesystemFailureKeepsItsActionableCategory() async throws {
        do {
            _ = try await NativeTool.run("/bin/sh", ["-c", "printf 'No space left on device' >&2; exit 1"])
            XCTFail("Failed tool succeeded")
        } catch let failure as EngineFailure {
            XCTAssertEqual(failure.code, "filesystem")
        }
    }
}
