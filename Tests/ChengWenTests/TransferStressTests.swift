import Foundation
import XCTest
@testable import ChengWen

final class TransferStressTests: XCTestCase {
    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("chengwen-transfer-stress-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    func testCompletedStreamCannotBeReusedWithStaleByteCounts() async throws {
        let body = Data(repeating: 7, count: 4096), server = try NativeFixtureServer(audio: body)
        try await server.start(); defer { server.stop() }
        let transfer = NativeAudioTransfer()
        let first = try await transfer.run(url: server.url(), headers: [:])
        XCTAssertEqual(first.bytes, Int64(body.count))
        do {
            _ = try await transfer.run(url: server.url(), headers: [:])
            XCTFail("A single-use stream must reject reuse instead of returning stale bytes")
        } catch let error as EngineFailure { XCTAssertEqual(error.code, "invalid_request") }
    }
    func testExistingFileAndSymlinkTargetAreNeverTruncatedByTransfer() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let original = Data("preserve synthetic preexisting audio".utf8)
        let target = root.appendingPathComponent("target.wav")
        try original.write(to: target)
        let link = root.appendingPathComponent("link.wav")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let server = try NativeFixtureServer(audio: Data(repeating: 7, count: 4096))
        try await server.start(); defer { server.stop() }
        for destination in [target, link] {
            do {
                _ = try await NativeAudioTransfer(destination: destination).run(url: server.url(), headers: [:])
                XCTFail("Existing transfer destinations must be rejected")
            } catch let error as EngineFailure { XCTAssertEqual(error.code, "filesystem") }
            XCTAssertEqual(try Data(contentsOf: target), original)
        }
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), target.path)
    }
    func test128ConcurrentRunCallsHaveExactlyOneOwnerAndAllFinish() async throws {
        let body = Data(repeating: 9, count: 8192), server = try NativeFixtureServer(audio: body)
        try await server.start(); defer { server.stop() }
        let transfer = NativeAudioTransfer()
        let winners = try await withThrowingTaskGroup(of: Int.self) { group in
            for _ in 0..<128 {
                group.addTask {
                    do {
                        let result = try await transfer.run(url: server.url(), headers: [:])
                        XCTAssertEqual(result.bytes, Int64(body.count)); XCTAssertEqual(result.sample, body)
                        return 1
                    } catch let error as EngineFailure {
                        XCTAssertEqual(error.code, "invalid_request"); return 0
                    }
                }
            }
            var successes = 0
            for try await count in group { successes += count }
            return successes
        }
        XCTAssertEqual(winners, 1)
    }
    func test32ConcurrentDestinationClaimsKeepExactlyOneCompleteFile() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("shared.wav")
        let body = Data(repeating: 11, count: 32768), server = try NativeFixtureServer(audio: body)
        try await server.start(); defer { server.stop() }
        let winners = try await withThrowingTaskGroup(of: Int.self) { group in
            for _ in 0..<32 {
                group.addTask {
                    do {
                        let result = try await NativeAudioTransfer(destination: destination).run(url: server.url(), headers: [:])
                        XCTAssertEqual(result.bytes, Int64(body.count)); return 1
                    } catch let error as EngineFailure {
                        XCTAssertEqual(error.code, "filesystem"); return 0
                    }
                }
            }
            var successes = 0
            for try await count in group { successes += count }
            return successes
        }
        XCTAssertEqual(winners, 1)
        XCTAssertEqual(try Data(contentsOf: destination), body)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["shared.wav"])
    }
    func testInvalidReadBudgetsFailWithoutCreatingDestinations() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        for cap in [Int64.min, -1, 0, 4097] {
            let transfer = NativeAudioTransfer(cap: cap, destination: root.appendingPathComponent("invalid.wav"), maximumBytes: 4096)
            do {
                _ = try await transfer.run(url: URL(string: "http://127.0.0.1:1/audio")!, headers: [:])
                XCTFail("Invalid byte budgets must fail before network or file creation")
            } catch let error as EngineFailure { XCTAssertEqual(error.code, "invalid_request") }
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
    }
    func testRepeatedPreStartCancellationSettlesWithoutCreatingFiles() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        for index in 0..<64 {
            let transfer = NativeAudioTransfer(destination: root.appendingPathComponent("cancel-\(index).wav"))
            for _ in 0..<8 { transfer.cancel() }
            do {
                _ = try await transfer.run(url: URL(string: "http://127.0.0.1:1/audio")!, headers: [:])
                XCTFail("Pre-cancelled transfers cannot start")
            } catch is CancellationError {} catch { XCTFail("Unexpected cancellation error: \(error)") }
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
    }
}
