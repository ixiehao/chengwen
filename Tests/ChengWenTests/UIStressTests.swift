import AppKit
import SwiftUI
import XCTest
@testable import ChengWen

final class UIStressTests: XCTestCase {
    @MainActor private func model(_ root: URL) -> AppModel {
        AppModel(storeURL: root, engine: BackendClient { _, _, _ in
            try await Task.sleep(nanoseconds: 60_000_000_000)
            return [:]
        })
    }
    private func track(_ index: Int, revision: Int = 0) -> AudioTrack {
        AudioTrack(raw: ["id": "stress-\(index)", "title": "Synthetic track \(index)", "artist": "Synthetic artist", "album": "Synthetic album", "source": "netease", "duration": "3:20", "url": "https://example.invalid/revision-\(revision)/\(index)"])
    }
    @MainActor private func views<T: NSView>(_ root: NSView, _ type: T.Type) -> [T] {
        ((root as? T).map { [$0] } ?? []) + root.subviews.flatMap { views($0, type) }
    }
    @MainActor private func settle(_ view: NSView) async {
        view.layoutSubtreeIfNeeded()
        try? await Task.sleep(nanoseconds: 25_000_000)
        view.layoutSubtreeIfNeeded()
    }
    @MainActor private func window(_ scroll: NSView) -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 300), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = scroll; window.orderBack(nil)
        return window
    }
    @MainActor func testResultActionUsesLatestRouteAfterOneHundredSameIDRefreshes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("chengwen-ui-route-stress-" + UUID().uuidString)
        let model = model(root); model.tracks = [track(0)]
        let view = NativeResultsTable(model: model, focusedTrackID: .constant(nil))
        let coordinator = view.makeCoordinator(), scroll = NativeResultsScrollView()
        scroll.resultsTable.delegate = coordinator; scroll.resultsTable.dataSource = coordinator; coordinator.scroll = scroll
        let window = window(scroll)
        defer { window.contentView = nil; window.close(); model.shutdown(); try? FileManager.default.removeItem(at: root) }
        coordinator.update(isEnabled: true); await settle(scroll)
        let cell = try XCTUnwrap(scroll.resultsTable.view(atColumn: 7, row: 0, makeIfNecessary: true))
        let button = try XCTUnwrap(views(cell, NSButton.self).first { $0.accessibilityIdentifier() == "result-download-stress-0" })
        for revision in 1...100 {
            model.tracks = [track(0, revision: revision)]
            coordinator.update(isEnabled: true)
        }
        button.performClick(nil)
        XCTAssertEqual(model.jobs.count, 1)
        XCTAssertEqual(model.jobs.first?.track.url, "https://example.invalid/revision-100/0", "A reused native cell cannot submit its original captured URL")
    }
    @MainActor func testRemovedResultCellsCannotSelectOrDownloadOldResults() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("chengwen-ui-removed-stress-" + UUID().uuidString)
        let model = model(root); model.tracks = (0..<200).map { track($0) }
        let coordinator = NativeResultsTable(model: model, focusedTrackID: .constant(nil)).makeCoordinator()
        let scroll = NativeResultsScrollView()
        scroll.resultsTable.delegate = coordinator; scroll.resultsTable.dataSource = coordinator; coordinator.scroll = scroll
        let window = window(scroll)
        defer { window.contentView = nil; window.close(); model.shutdown(); try? FileManager.default.removeItem(at: root) }
        coordinator.update(isEnabled: true); await settle(scroll)
        let selectionCell = try XCTUnwrap(scroll.resultsTable.view(atColumn: 0, row: 0, makeIfNecessary: true))
        let actionsCell = try XCTUnwrap(scroll.resultsTable.view(atColumn: 7, row: 0, makeIfNecessary: true))
        let checkbox = try XCTUnwrap(views(selectionCell, NSButton.self).first)
        let download = try XCTUnwrap(views(actionsCell, NSButton.self).first { $0.accessibilityIdentifier() == "result-download-stress-0" })
        model.tracks = []; coordinator.update(isEnabled: true); await settle(scroll)
        checkbox.performClick(nil); download.performClick(nil)
        XCTAssertTrue(model.selection.isEmpty, "A removed result must not leave an invisible selected ID")
        XCTAssertTrue(model.jobs.isEmpty, "A removed result must not enqueue an invisible old result")
    }
    @MainActor func testOpenFailureDetailsInvalidateWhenSameTaskFailsAgain() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("chengwen-ui-details-stress-" + UUID().uuidString)
        let model = model(root)
        var job = DownloadJob(track: track(0), format: "mp3", directory: root.path, lyrics: false)
        job.state = "failed"; job.detail = "First synthetic failure"; model.jobs = [job]
        let coordinator = NativeDownloadsTable(model: model, jobs: [job], showAccounts: {}).makeCoordinator()
        let scroll = NativeDownloadsScrollView()
        scroll.table.delegate = coordinator; scroll.table.dataSource = coordinator; coordinator.scroll = scroll
        let window = window(scroll)
        defer { coordinator.popover?.close(); window.contentView = nil; window.close(); model.shutdown(); try? FileManager.default.removeItem(at: root) }
        coordinator.update(enabled: true); await settle(scroll)
        let cell = try XCTUnwrap(scroll.table.view(atColumn: 5, row: 0, makeIfNecessary: true) as? NativeDownloadActionsCell)
        cell.more.performClick(nil); await settle(scroll)
        let original = try XCTUnwrap(coordinator.popover)
        XCTAssertTrue(original.isShown)
        // A fast retry can return to failed before SwiftUI delivers an update.
        job.retryCount = 1; job.detail = "Different synthetic failure after retry"
        model.jobs = [job]
        coordinator.parent = NativeDownloadsTable(model: model, jobs: [job], showAccounts: {})
        coordinator.update(enabled: true); await settle(scroll)
        XCTAssertFalse(original.isShown, "The old snapshot must not remain as the explanation of a new attempt")
    }
    @MainActor func testFiveThousandResultsSurviveFortySelectionAndReplacementCycles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("chengwen-ui-list-stress-" + UUID().uuidString)
        let model = model(root), original = (0..<5_000).map { track($0) }
        model.tracks = original
        let coordinator = NativeResultsTable(model: model, focusedTrackID: .constant(nil)).makeCoordinator()
        let scroll = NativeResultsScrollView(), table = scroll.resultsTable
        table.delegate = coordinator; table.dataSource = coordinator; coordinator.scroll = scroll
        let window = window(scroll)
        defer { window.contentView = nil; window.close(); model.shutdown(); try? FileManager.default.removeItem(at: root) }
        let started = Date()
        coordinator.update(isEnabled: true); await settle(scroll)
        for cycle in 0..<40 {
            coordinator.setAllSelected(cycle.isMultiple(of: 2))
            XCTAssertEqual(model.selection.count, cycle.isMultiple(of: 2) ? 5_000 : 0)
            table.scrollRowToVisible(4_999)
            scroll.layoutSubtreeIfNeeded()
            XCTAssertGreaterThan(scroll.contentView.bounds.minY, 0)
            let count = cycle % 4
            model.tracks = Array(original.suffix(count)); model.selection = []
            coordinator.update(isEnabled: true); await settle(scroll)
            XCTAssertEqual(table.numberOfRows, count)
            XCTAssertEqual(scroll.contentView.bounds.minY, -scroll.headerOverlap, accuracy: 1)
            if count > 0 {
                XCTAssertGreaterThan(table.rows(in: table.visibleRect).length, 0)
                let title = try XCTUnwrap(table.view(atColumn: 1, row: 0, makeIfNecessary: true) as? NativeResultTitleCell)
                XCTAssertEqual(title.titleLabel.stringValue, original[5_000-count].title)
            } else { XCTAssertFalse(scroll.resultsHeader.selectAllButton.isEnabled) }
            model.tracks = original; coordinator.update(isEnabled: true); await settle(scroll)
            XCTAssertLessThan(views(table, NSTableRowView.self).count, 200, "A long table must virtualize rows rather than materializing thousands of native views")
        }
        print("UI_STRESS results=5000 selection-and-shrink-cycles=40 elapsed-seconds=\(Date().timeIntervalSince(started))")
    }
    @MainActor func testThreeThousandDownloadRowsKeepSelectionAndViewportDuringOneHundredProgressUpdates() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("chengwen-ui-download-stress-" + UUID().uuidString)
        let model = model(root)
        model.jobs = (0..<3_000).map { index in
            var job = DownloadJob(track: track(index), format: "mp3", directory: root.path, lyrics: false)
            job.state = index == 0 ? "downloading" : "completed"
            return job
        }
        let coordinator = NativeDownloadsTable(model: model, jobs: model.jobs, showAccounts: {}).makeCoordinator()
        let scroll = NativeDownloadsScrollView(), table = scroll.table
        table.delegate = coordinator; table.dataSource = coordinator; coordinator.scroll = scroll
        let window = window(scroll)
        defer { window.contentView = nil; window.close(); model.shutdown(); try? FileManager.default.removeItem(at: root) }
        coordinator.update(enabled: true); await settle(scroll)
        table.selectRowIndexes(IndexSet(integer: 2_999), byExtendingSelection: false)
        table.scrollRowToVisible(2_999); await settle(scroll)
        let offset = scroll.contentView.bounds.minY, selected = model.jobs[2_999].id, started = Date()
        for percent in 1...100 {
            model.jobs[0].percent = percent
            coordinator.parent = NativeDownloadsTable(model: model, jobs: model.jobs, showAccounts: {})
            coordinator.update(enabled: true)
            XCTAssertEqual(table.selectedRow, 2_999)
            XCTAssertEqual(scroll.contentView.bounds.minY, offset, accuracy: 1)
            XCTAssertEqual(model.jobs[table.selectedRow].id, selected)
        }
        await settle(scroll)
        XCTAssertLessThan(views(table, NSTableRowView.self).count, 200)
        XCTAssertTrue(table.visibleRect.intersects(table.rect(ofRow: 2_999)))
        print("UI_STRESS downloads=3000 progress-updates=100 elapsed-seconds=\(Date().timeIntervalSince(started))")
    }
    @MainActor func testFailurePopoverSurvivesThirtyOpenInvalidateAndReopenCycles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("chengwen-ui-popover-stress-" + UUID().uuidString)
        let model = model(root)
        var job = DownloadJob(track: track(0), format: "mp3", directory: root.path, lyrics: false)
        job.state = "failed"; model.jobs = [job]
        let coordinator = NativeDownloadsTable(model: model, jobs: [job], showAccounts: {}).makeCoordinator()
        let scroll = NativeDownloadsScrollView()
        scroll.table.delegate = coordinator; scroll.table.dataSource = coordinator; coordinator.scroll = scroll
        let window = window(scroll)
        defer { coordinator.popover?.close(); window.contentView = nil; window.close(); model.shutdown(); try? FileManager.default.removeItem(at: root) }
        coordinator.update(enabled: true); await settle(scroll)
        for attempt in 1...30 {
            let cell = try XCTUnwrap(scroll.table.view(atColumn: 5, row: 0, makeIfNecessary: true) as? NativeDownloadActionsCell)
            cell.more.performClick(nil); await settle(scroll)
            let opened = try XCTUnwrap(coordinator.popover)
            XCTAssertTrue(opened.isShown)
            job.retryCount = attempt; job.detail = "Synthetic new failure \(attempt)"
            model.jobs = [job]; coordinator.parent = NativeDownloadsTable(model: model, jobs: [job], showAccounts: {})
            coordinator.update(enabled: true); await settle(scroll)
            XCTAssertFalse(opened.isShown)
            XCTAssertNil(coordinator.popover)
        }
        print("UI_STRESS failure-detail-open-invalidate-cycles=30")
    }
}
