import AppKit
import SwiftUI
import XCTest
@testable import ChengWen

final class DownloadActionInteractionTests: XCTestCase {
    @MainActor private func mount(count: Int, width: CGFloat = 1100) async throws -> (AppModel, NSWindow, NativeDownloadsScrollView, NativeDownloadsTable.Coordinator) {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("chengwen-download-hit-" + UUID().uuidString)
        let model = AppModel(storeURL: root, engine: BackendClient { _, _, _ in
            try await Task.sleep(nanoseconds: 60_000_000_000); return [:]
        })
        model.jobs = (0..<count).map { index in
            var job = DownloadJob(track: AudioTrack(raw: ["id": "synthetic-\(index)", "title": "Synthetic \(index)", "source": "netease", "url": "https://music.163.com/song?id=123"]), format: "mp3", directory: root.path, lyrics: false)
            job.state = ["completed", "queued", "failed"][index % 3]
            job.detail = "Synthetic reason"; job.solution = "Synthetic solution"
            return job
        }
        let scroll = NativeDownloadsScrollView(), coordinator = NativeDownloadsTable(model: model, jobs: model.jobs, showAccounts: {}).makeCoordinator()
        scroll.table.delegate = coordinator; scroll.table.dataSource = coordinator; coordinator.scroll = scroll
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 320), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = scroll; window.orderBack(nil)
        coordinator.update(enabled: true); scroll.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 40_000_000); scroll.layoutSubtreeIfNeeded()
        return (model, window, scroll, coordinator)
    }
    @MainActor private func close(_ model: AppModel, _ window: NSWindow, _ coordinator: NativeDownloadsTable.Coordinator) {
        coordinator.popover?.animates = false; coordinator.popover?.close()
        window.makeFirstResponder(nil); window.contentView = nil; window.close()
        model.shutdown(); try? FileManager.default.removeItem(at: model.storeURL)
    }
    @MainActor private func hit(_ button: NSButton, x: CGFloat = 0.5, y: CGFloat = 0.5, window: NSWindow) throws -> NSView? {
        let point = button.convert(NSPoint(x: button.bounds.width * x, y: button.bounds.height * y), to: nil)
        let content = try XCTUnwrap(window.contentView)
        return content.hitTest(content.superview?.convert(point, from: nil) ?? point)
    }
    @MainActor func testVisibleDownloadActionsReceiveClicksAcrossRowsAndButtonFaces() async throws {
        for count in [1, 4, 20] {
            let (model, window, scroll, coordinator) = try await mount(count: count)
            defer { close(model, window, coordinator) }
            for row in 0..<min(count, 5) {
                let cell = try XCTUnwrap(scroll.table.view(atColumn: 5, row: row, makeIfNecessary: true) as? NativeDownloadActionsCell)
                cell.layoutSubtreeIfNeeded()
                for button in [cell.primary, cell.switchSource, cell.more] where !button.isHidden {
                    for (x, y): (CGFloat, CGFloat) in [(0.2, 0.25), (0.5, 0.5), (0.8, 0.75)] {
                        let target = try hit(button, x: x, y: y, window: window)
                        XCTAssertTrue(target === button || target?.isDescendant(of: button) == true,
                                      "Visible \(button.title) row \(row)/\(count) at y=\(y) must receive the click; got \(String(describing: target))")
                    }
                    let point = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
                    let event = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
                    XCTAssertTrue(scroll.table.validateProposedFirstResponder(button, for: event))
                    let cellHit = button.cell?.hitTest(for: event, in: button.bounds, of: button)
                    XCTAssertTrue(cellHit?.contains(.trackableArea) == true)
                }
            }
        }
    }
    @MainActor func testProgressRefreshKeepsThePressedActionAttachedAndUsesCurrentJob() async throws {
        let (model, window, scroll, coordinator) = try await mount(count: 4)
        defer { close(model, window, coordinator) }
        let original = try XCTUnwrap(scroll.table.view(atColumn: 5, row: 1, makeIfNecessary: true) as? NativeDownloadActionsCell)
        let id = model.jobs[1].id
        for percent in 1...20 {
            model.jobs[1].percent = percent
            coordinator.parent = NativeDownloadsTable(model: model, jobs: model.jobs, showAccounts: {})
            coordinator.update(enabled: true); scroll.layoutSubtreeIfNeeded()
            let current = try XCTUnwrap(scroll.table.view(atColumn: 5, row: 1, makeIfNecessary: true))
            XCTAssertTrue(current === original)
            XCTAssertTrue(original.primary.window === window)
        }
        original.primary.performClick(nil)
        XCTAssertEqual(model.jobs.first { $0.id == id }?.state, "cancelled")
    }
    @MainActor func testFirstFilteredFailureCanShowDetailsSwitchSourceRetryAndCancel() async throws {
        let (model, window, scroll, coordinator) = try await mount(count: 1)
        defer { close(model, window, coordinator) }
        model.jobs[0].state = "failed"
        func refresh() {
            coordinator.parent = NativeDownloadsTable(model: model, jobs: model.jobs, showAccounts: {})
            coordinator.update(enabled: true); scroll.layoutSubtreeIfNeeded()
        }
        refresh()
        let actions = try XCTUnwrap(scroll.table.view(atColumn: 5, row: 0, makeIfNecessary: true) as? NativeDownloadActionsCell)
        actions.layoutSubtreeIfNeeded()
        for button in [actions.primary, actions.switchSource, actions.more] {
            XCTAssertTrue(try hit(button, window: window) === button, "First filtered row must expose every action")
        }
        actions.more.performClick(nil)
        XCTAssertTrue(coordinator.popover?.isShown == true)
        coordinator.popover?.animates = false; coordinator.popover?.close()
        actions.switchSource.performClick(nil)
        XCTAssertEqual(model.page, .search)
        XCTAssertEqual(model.keyword, model.jobs[0].track.title + " " + model.jobs[0].track.artist)
        XCTAssertFalse(model.settings.sources.contains("netease"))
        model.stopSearch(); model.page = .downloads
        actions.primary.performClick(nil)
        XCTAssertEqual(model.jobs[0].retryCount, 1); XCTAssertEqual(model.jobs[0].state, "downloading")
        refresh(); XCTAssertEqual(actions.primary.title, "取消")
        XCTAssertTrue(try hit(actions.primary, window: window) === actions.primary)
        actions.primary.performClick(nil)
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while model.jobs[0].active && ProcessInfo.processInfo.systemUptime < deadline {try await Task.sleep(nanoseconds:5_000_000)}
        XCTAssertEqual(model.jobs[0].state, "cancelled")
    }
    @MainActor func testCompletedRecordWithMissingFileGivesFeedbackInsteadOfSilentClick() async throws {
        let (model, window, scroll, coordinator) = try await mount(count: 1)
        defer { close(model, window, coordinator) }
        let actions = try XCTUnwrap(scroll.table.view(atColumn: 5, row: 0, makeIfNecessary: true) as? NativeDownloadActionsCell)
        actions.primary.performClick(nil)
        XCTAssertTrue(model.notice.contains("没有保存位置"))
        model.notice = ""
        model.jobs[0].path = model.storeURL.appendingPathComponent("missing-synthetic.mp3").path
        // The existing button must resolve the latest job, even before redraw.
        actions.primary.performClick(nil)
        XCTAssertTrue(model.notice.contains("暂时找不到该文件"))
    }

    @MainActor func testScrollingThenFilteringOrResizingKeepsFirstVisibleActionReachable() async throws {
        let (model, window, scroll, coordinator) = try await mount(count: 20)
        defer { close(model, window, coordinator) }
        scroll.table.scrollRowToVisible(19); scroll.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(scroll.contentView.bounds.minY, 0)
        let filtered = model.jobs[19]
        coordinator.parent = NativeDownloadsTable(model: model, jobs: [filtered], showAccounts: {})
        coordinator.update(enabled: true); scroll.layoutSubtreeIfNeeded()
        window.setContentSize(NSSize(width: 836, height: 200)); scroll.layoutSubtreeIfNeeded()
        let actions = try XCTUnwrap(scroll.table.view(atColumn: 5, row: 0, makeIfNecessary: true) as? NativeDownloadActionsCell)
        actions.layoutSubtreeIfNeeded()
        XCTAssertTrue(try hit(actions.primary, window: window) === actions.primary)
        actions.primary.performClick(nil)
        XCTAssertEqual(model.jobs.first { $0.id == filtered.id }?.state, "cancelled")
        XCTAssertEqual(model.jobs.filter { $0.state == "cancelled" }.count, 1)
        coordinator.parent = NativeDownloadsTable(model: model, jobs: [], showAccounts: {})
        coordinator.update(enabled: true); scroll.layoutSubtreeIfNeeded()
        XCTAssertEqual(scroll.table.numberOfRows, 0)
        coordinator.parent = NativeDownloadsTable(model: model, jobs: [model.jobs[0]], showAccounts: {})
        coordinator.update(enabled: true); scroll.layoutSubtreeIfNeeded()
        let restored = try XCTUnwrap(scroll.table.view(atColumn: 5, row: 0, makeIfNecessary: true) as? NativeDownloadActionsCell)
        restored.layoutSubtreeIfNeeded()
        XCTAssertTrue(try hit(restored.primary, window: window) === restored.primary)
    }

}
