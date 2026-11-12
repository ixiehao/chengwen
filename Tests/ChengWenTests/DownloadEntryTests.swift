import AppKit
import SwiftUI
import XCTest
@testable import ChengWen

final class DownloadEntryTests: XCTestCase {
    private func root() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("chengwen-download-entry-" + UUID().uuidString) }
    private func track(_ id: String) -> AudioTrack {
        AudioTrack(raw: ["id": id, "title": "Synthetic " + id, "artist": "Synthetic artist", "source": "netease", "duration": "3:20", "url": "https://music.163.com/song?id=123"])
    }
    @MainActor private func views<T: NSView>(_ root: NSView, _ type: T.Type) -> [T] {
        ((root as? T).map { [$0] } ?? []) + root.subviews.flatMap { views($0, type) }
    }
    @MainActor private func eventually(_ condition: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while !condition() && ProcessInfo.processInfo.systemUptime < deadline { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertTrue(condition())
    }
    @MainActor private func pending(_ root: URL) -> AppModel {
        AppModel(storeURL: root, engine: BackendClient { operation, _, _ in
            XCTAssertEqual(operation, "download", "Clicking download must not run an optional probe first")
            try await Task.sleep(nanoseconds: 60_000_000_000)
            return [:]
        })
    }
    @MainActor func testUntestedSingleTrackDownloadsWithoutAnyProbeRequest() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(storeURL: root, engine: BackendClient { operation, _, _ in
            XCTAssertEqual(operation, "download")
            return ["path": root.appendingPathComponent("synthetic.mp3").path, "full_verified": true, "anonymous": true]
        })
        defer { model.shutdown() }
        let song = track("untested"); model.tracks = [song]
        model.downloadTrack(song)
        XCTAssertEqual(model.jobs.count, 1)
        try await eventually { model.completedJobCount == 1 }
        XCTAssertEqual(model.probes[song.id]?.state, "verified")
    }
    @MainActor func testFreshFailedSampleDoesNotPreventARealDownloadAttempt() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(storeURL: root, engine: BackendClient { operation, _, _ in
            XCTAssertEqual(operation, "download")
            return ["path": root.appendingPathComponent("synthetic.mp3").path, "full_verified": true, "anonymous": true]
        })
        defer { model.shutdown() }
        let song = track("failed-sample"); model.tracks = [song]
        model.probes[song.id] = ProbeStatus(state: "failed", detail: "Synthetic sample timeout")
        model.downloadTrack(song)
        XCTAssertEqual(model.jobs.count, 1)
        guard !model.jobs.isEmpty else { return }
        try await eventually { model.completedJobCount == 1 }
        XCTAssertEqual(model.probes[song.id]?.state, "verified")
    }
    @MainActor func testDownloadCanStartWhileTheSameTracksOptionalProbeIsRunning() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let began = expectation(description: "Optional sample request began")
        let model = AppModel(storeURL: root, engine: BackendClient { operation, _, _ in
            if operation == "probe" { began.fulfill(); try await Task.sleep(nanoseconds: 60_000_000_000); return [:] }
            XCTAssertEqual(operation, "download")
            return ["path": root.appendingPathComponent("synthetic.mp3").path, "full_verified": true, "anonymous": true]
        })
        defer { model.shutdown() }
        let song = track("overlap"); model.tracks = [song]; model.probeTrack(song)
        await fulfillment(of: [began], timeout: 2)
        XCTAssertTrue(model.isProbing)
        model.downloadTrack(song)
        XCTAssertEqual(model.jobs.count, 1)
        guard !model.jobs.isEmpty else { return }
        try await eventually { model.completedJobCount == 1 }
        XCTAssertEqual(model.probes[song.id]?.state, "verified")
    }
    @MainActor func testBatchQueuesEverySelectedProbeStateAndRetainsActiveTaskDeduplication() {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let model = pending(root); defer { model.shutdown() }
        let states = ["untested", "queued", "checking", "testing", "running", "failed", "authentication", "unavailable", "blocked", "passed", "verified"]
        model.tracks = states.map(track); model.selection = Set(model.tracks.map(\.id)); model.isProbing = true
        for state in states where state != "untested" { model.probes[state] = ProbeStatus(state: state) }
        model.downloadSelected()
        XCTAssertEqual(Set(model.jobs.map { $0.track.id }), Set(states), "An advisory sample result must never silently filter selected songs")
        model.downloadSelected(); model.downloadTrack(model.tracks[0])
        XCTAssertEqual(model.jobs.count, states.count, "Repeated clicks must not duplicate active jobs")
    }
    @MainActor private func table(_ model: AppModel) async throws -> (NSWindow, NativeResultsScrollView, NativeResultsTable.Coordinator) {
        _ = NSApplication.shared
        let scroll = NativeResultsScrollView(), coordinator = NativeResultsTable(model: model, focusedTrackID: .constant(nil)).makeCoordinator()
        scroll.resultsTable.delegate = coordinator; scroll.resultsTable.dataSource = coordinator; coordinator.scroll = scroll
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 300), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = scroll; window.orderBack(nil)
        coordinator.update(isEnabled: true); scroll.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        try await Task.sleep(nanoseconds: 30_000_000); scroll.layoutSubtreeIfNeeded()
        return (window, scroll, coordinator)
    }
    @MainActor private func close(_ window: NSWindow) { window.makeFirstResponder(nil); window.contentView = nil; window.close() }
    @MainActor func testRowButtonsStayAttachedAcrossSelectionAndProbeChangesAndNeverRequireTesting() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let model = pending(root); defer { model.shutdown() }; model.tracks = [track("row")]
        let (window, scroll, coordinator) = try await table(model); defer { withExtendedLifetime(coordinator) {}; close(window) }
        let first = try XCTUnwrap(scroll.resultsTable.view(atColumn: 7, row: 0, makeIfNecessary: true))
        let download = try XCTUnwrap(views(first, NSButton.self).first { $0.title == "下载" })
        for state in ["untested", "checking", "failed", "authentication", "passed"] {
            model.selection = model.selection.isEmpty ? ["row"] : []
            model.isProbing = state == "checking"
            model.probes["row"] = state == "untested" ? nil : ProbeStatus(state: state)
            coordinator.update(isEnabled: true); scroll.layoutSubtreeIfNeeded()
            let current = try XCTUnwrap(scroll.resultsTable.view(atColumn: 7, row: 0, makeIfNecessary: true))
            XCTAssertTrue(current === first, "Refreshing a badge/selection must not remove a button during mouse tracking")
            XCTAssertTrue(download.window === window)
            XCTAssertTrue(download.isEnabled, "Download cannot depend on \(state)")
        }
        download.performClick(nil)
        XCTAssertEqual(model.jobs.count, 1)
    }
    @MainActor func testUntestedRowsHaveAnUnobstructedDownloadActionBeforeSelection() async throws {
        // Hit testing from the window, rather than invoking a located button
        // directly, catches floating headers covering a visible first row.
        for count in [1, 4, 20] {
            let root = root(); defer { try? FileManager.default.removeItem(at: root) }
            let model = pending(root); defer { model.shutdown() }
            model.tracks = (0..<count).map { track("row-\($0)") }
            let (window, scroll, coordinator) = try await table(model)
            defer { withExtendedLifetime(coordinator) {}; close(window) }
            XCTAssertTrue(model.selection.isEmpty); XCTAssertTrue(model.probes.isEmpty)
            for row in 0..<min(count, 4) {
                let cell = try XCTUnwrap(scroll.resultsTable.view(atColumn: 7, row: row, makeIfNecessary: true))
                cell.layoutSubtreeIfNeeded()
                let button = try XCTUnwrap(views(cell, NSButton.self).first { $0.title == "下载" })
                let content = try XCTUnwrap(window.contentView)
                let location = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
                let hit = content.hitTest(content.superview?.convert(location, from: nil) ?? location)
                let hitButton = try XCTUnwrap(hit as? NSButton, "Download must receive clicks in row \(row) of \(count)")
                XCTAssertTrue(hitButton === button); XCTAssertTrue(hitButton.isEnabled)
                hitButton.performClick(nil)
                XCTAssertEqual(model.jobs.count, row + 1, "The first action must queue the song without selecting or testing first")
            }
        }
    }
    @MainActor func testBatchButtonRemainsEnabledDuringOptionalTestingAndQueuesAllSelections() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let model = pending(root); defer { model.shutdown() }
        model.tracks = [track("new"), track("bad"), track("checking")]; model.selection = Set(model.tracks.map(\.id))
        model.probes["bad"] = ProbeStatus(state: "failed"); model.probes["checking"] = ProbeStatus(state: "checking"); model.isProbing = true
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1220, height: 820), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: NativeRootView().environmentObject(model)); window.contentView = host; window.orderBack(nil)
        defer { close(window) }
        host.layoutSubtreeIfNeeded(); try await Task.sleep(nanoseconds: 70_000_000); host.layoutSubtreeIfNeeded()
        let button = try XCTUnwrap(views(host, NSButton.self).first { $0.title.hasPrefix("下载所选") })
        XCTAssertTrue(button.isEnabled)
        XCTAssertEqual(button.title, "下载所选 (3)")
        button.performClick(nil)
        XCTAssertEqual(model.jobs.count, 3)
    }
}
