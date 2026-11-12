import Foundation
import Darwin
import XCTest
@testable import ChengWen

final class ToolSoakTests: XCTestCase {
    func testTimedOutParentCannotLeaveInheritedOutputPipeWaitingForDescendant() async throws {
        let started = Date()
        do {
            _ = try await NativeTool.run("/bin/sh", ["-c", "sleep 4 & exit 0"], timeout: 0.05)
            XCTFail("Expected tool timeout")
        } catch let error as EngineFailure { XCTAssertEqual(error.code, "tool_timeout") }
        XCTAssertLessThan(Date().timeIntervalSince(started), 3.0, "A descendant holding stdout must not extend the tool timeout")
    }
    func testExcessiveToolOutputIsNotMisreportedAsUserCancellation() async throws {
        do {
            _ = try await NativeTool.run("/usr/bin/head", ["-c", "2100001", "/dev/zero"], timeout: 5)
            XCTFail("Oversized output must be rejected")
        } catch let error as EngineFailure { XCTAssertEqual(error.code, "tool_output") }
        catch { XCTFail("Output-limit failure was misreported: \(error)") }
    }
    func testTwentyConcurrentToolsFinishWithDistinctOutputAndNoArgumentExpansion() async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<20 {
                group.addTask {
                    let text = "synthetic-\(index)-$(do-not-expand)"
                    let bytes = try await NativeTool.run("/usr/bin/printf", ["%s", text], timeout: 5)
                    XCTAssertEqual(String(data: bytes, encoding: .utf8), text)
                }
            }
            try await group.waitForAll()
        }
    }
    func testTenConcurrentTimeoutsAndTenCancellationsFinishWithoutStrandedChildren() async throws {
        let started = Date()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<20 {
                group.addTask {
                    if index.isMultiple(of: 2) {
                        do {
                            _ = try await NativeTool.run("/bin/sh", ["-c", "trap '' TERM; sleep 4 & wait"], timeout: 0.05)
                            XCTFail("Expected timeout")
                        } catch let error as EngineFailure { XCTAssertEqual(error.code, "tool_timeout") }
                    } else {
                        let work = Task { try await NativeTool.run("/bin/sleep", ["4"], timeout: 10) }
                        try await Task.sleep(nanoseconds: 50_000_000);work.cancel()
                        do { _ = try await work.value; XCTFail("Expected cancellation") }
                        catch is CancellationError {} catch { XCTFail("Unexpected cancel result: \(error)") }
                    }
                }
            }
            try await group.waitForAll()
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 3.5)
    }
    func testInvalidTimeoutsFailBeforeLaunchingTool() async {
        for timeout in [Double.nan, Double.infinity, -1, 0] {
            do { _ = try await NativeTool.run("/bin/sleep", ["5"], timeout: timeout); XCTFail("Invalid timeout accepted") }
            catch let error as EngineFailure { XCTAssertEqual(error.code, "invalid_request") }
            catch { XCTFail("Unexpected invalid timeout error: \(error)") }
        }
    }
    func testUnmappedOwnedPipeDescriptorIsNotInheritedByTool() async throws {
        var descriptors = [Int32](repeating: 0, count: 2)
        XCTAssertEqual(pipe(&descriptors), 0)
        defer { close(descriptors[0]); close(descriptors[1]) }
        let extra = fcntl(descriptors[1], F_DUPFD, 300)
        XCTAssertGreaterThanOrEqual(extra, 300); defer { close(extra) }
        XCTAssertEqual(fcntl(extra, F_SETFD, 0), 0)
        let script = "if [ -e /dev/fd/\(extra) ]; then printf inherited; else printf closed; fi"
        let result = try await NativeTool.run("/bin/sh", ["-c", script], timeout: 5)
        XCTAssertEqual(String(data: result, encoding: .utf8), "closed")
    }
    func testBackgroundDescendantCannotOutliveSuccessfulParentWithoutOutput() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("chengwen-tool-child-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let marker = root.appendingPathComponent("child-pid")
        var child: pid_t = 0
        defer { if child > 0 { kill(child, SIGKILL) } }
        do {
            _ = try await NativeTool.run("/bin/sh", ["-c", "sleep 4 >/dev/null 2>&1 & echo $! > \"$1\"", "fixture", marker.path], timeout: 5)
            XCTFail("Parent success cannot hide an unfinished child tool")
        } catch let error as EngineFailure { XCTAssertEqual(error.code, "audio_invalid") }
        child = try XCTUnwrap(pid_t(String(contentsOf: marker).trimmingCharacters(in: .whitespacesAndNewlines)))
        let deadline = Date().addingTimeInterval(2)
        while kill(child, 0) == 0, Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(kill(child, 0), -1)
        XCTAssertEqual(errno, ESRCH)
        if kill(child, 0) == -1, errno == ESRCH { child = 0 }
    }
}
