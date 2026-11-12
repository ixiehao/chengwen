import AppKit
import Darwin
import XCTest
@testable import ChengWen

final class LifecycleTests:XCTestCase {
    @MainActor private func waitForExit(_ process:Process,timeout:TimeInterval=8) async throws {
        let end=Date().addingTimeInterval(timeout)
        while process.isRunning && Date()<end {try await Task.sleep(nanoseconds:20_000_000)}
        if process.isRunning {kill(process.processIdentifier,SIGKILL);process.waitUntilExit();XCTFail("Owned QA process did not exit within its lifecycle deadline")}
    }

    @MainActor private func preview(closeWindow:Bool=false) throws -> Process {
        let executable=Bundle(for:Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("ChengWen")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath:executable.path))
        let process=Process();process.executableURL=executable
        process.arguments=["--ui-preview","--hidden-preview","--exit-after-preview"]+(closeWindow ? ["--close-after-preview"] : [])
        process.standardOutput=FileHandle.nullDevice;process.standardError=FileHandle.nullDevice
        try process.run();return process
    }

    @MainActor func testQuitFromMainDispatchCompletesRealAppKitTerminationHandshake() async throws {
        let process=try preview()
        try await waitForExit(process)
        XCTAssertEqual(process.terminationStatus,0)
    }

    @MainActor func testClosingLastWindowCompletesRealAppKitTermination() async throws {
        let process=try preview(closeWindow:true)
        try await waitForExit(process)
        XCTAssertEqual(process.terminationStatus,0)
    }

    @MainActor func testBackendShutdownCancelsNativeTasksWaitsForCleanupAndRejectsNewRequests() async throws {
        let entered=expectation(description:"Native task started")
        let cleanup=expectation(description:"Canceled operation cleaned up")
        let backend=BackendClient{_,_,_ in
            entered.fulfill()
            defer{cleanup.fulfill()}
            try await Task.sleep(nanoseconds:20_000_000_000)
            return [:]
        }
        let cancelled=expectation(description:"Existing request is cancelled")
        backend.request("probe",payload:[:]){result in
            if case .failure(let error)=result{XCTAssertEqual(error.code,"cancelled")}else{XCTFail("Expected cancellation")}
            cancelled.fulfill()
        }
        await fulfillment(of:[entered],timeout:2)
        let stopped=expectation(description:"All native tasks exited")
        backend.shutdown{stopped.fulfill()}
        let rejected=expectation(description:"Request after shutdown is rejected")
        backend.request("health",payload:[:]){result in
            if case .failure(let error)=result{XCTAssertEqual(error.code,"cancelled")}else{XCTFail("Must not execute during shutdown")}
            rejected.fulfill()
        }
        await fulfillment(of:[cleanup,cancelled,stopped,rejected],timeout:3)
    }
}
