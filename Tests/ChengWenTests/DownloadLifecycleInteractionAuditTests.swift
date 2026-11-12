import AppKit
import SwiftUI
import XCTest
@testable import ChengWen

final class DownloadLifecycleInteractionAuditTests: XCTestCase {
    private func job(_ index: Int, state: String = "queued") -> DownloadJob {
        var value = DownloadJob(track: AudioTrack(raw: ["id": "audit-\(index)", "title": "Audit \(index)", "source": "netease", "url": "https://music.163.com/song?id=123"]), format: "mp3", directory: "/tmp", lyrics: false)
        value.state = state; value.detail = "Synthetic reason"; value.solution = "Synthetic solution"
        return value
    }
    @MainActor private func mount(_ jobs: [DownloadJob]) async throws -> (AppModel, NSWindow, NativeDownloadsScrollView, NativeDownloadsTable.Coordinator) {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("chengwen-download-lifecycle-audit-" + UUID().uuidString)
        let model = AppModel(storeURL: root, engine: BackendClient { _, _, _ in
            try await Task.sleep(nanoseconds: 60_000_000_000); return [:]
        }); model.jobs = jobs
        let scroll = NativeDownloadsScrollView()
        let coordinator = NativeDownloadsTable(model: model, jobs: jobs, showAccounts: {}).makeCoordinator()
        scroll.table.delegate = coordinator; scroll.table.dataSource = coordinator; coordinator.scroll = scroll
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 320), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = scroll; window.orderBack(nil)
        coordinator.update(enabled: true); await settle(scroll)
        return (model, window, scroll, coordinator)
    }
    @MainActor private func settle(_ view: NSView) async {
        view.layoutSubtreeIfNeeded(); try? await Task.sleep(nanoseconds: 25_000_000); view.layoutSubtreeIfNeeded()
    }
    @MainActor private func close(_ model: AppModel, _ window: NSWindow, _ coordinator: NativeDownloadsTable.Coordinator) {
        coordinator.popover?.animates = false; coordinator.popover?.close()
        window.makeFirstResponder(nil); window.contentView = nil; window.close()
        model.shutdown(); try? FileManager.default.removeItem(at: model.storeURL)
    }
    @MainActor private func update(_ coordinator: NativeDownloadsTable.Coordinator, model: AppModel, jobs: [DownloadJob]) {
        coordinator.parent = NativeDownloadsTable(model: model, jobs: jobs, showAccounts: {})
        coordinator.update(enabled: true)
    }
    @MainActor private func firstVisible(_ scroll: NativeDownloadsScrollView) -> Int {
        scroll.table.row(at: NSPoint(x: 10, y: scroll.contentView.bounds.minY + scroll.headerOverlap + 0.5))
    }
    @MainActor func testIncomingTasksKeepVisibleButtonAtTheSameWindowPositionAndTarget() async throws {
        let originals = (0..<60).map { job($0) }
        let (model, window, scroll, coordinator) = try await mount(originals)
        defer { close(model, window, coordinator) }
        scroll.table.scrollRowToVisible(35); await settle(scroll)
        let oldRow = firstVisible(scroll); XCTAssertGreaterThan(oldRow, 0)
        let id = originals[oldRow].id
        let oldCell = try XCTUnwrap(scroll.table.view(atColumn: 5, row: oldRow, makeIfNecessary: true) as? NativeDownloadActionsCell)
        oldCell.layoutSubtreeIfNeeded()
        let before = oldCell.primary.convert(NSPoint(x: oldCell.primary.bounds.midX, y: oldCell.primary.bounds.midY), to: nil)
        model.jobs = [job(100), job(101)] + originals
        update(coordinator, model: model, jobs: model.jobs); await settle(scroll)
        let row = try XCTUnwrap(model.jobs.firstIndex { $0.id == id })
        let current = try XCTUnwrap(scroll.table.view(atColumn: 5, row: row, makeIfNecessary: true) as? NativeDownloadActionsCell)
        current.layoutSubtreeIfNeeded()
        let after = current.primary.convert(NSPoint(x: current.primary.bounds.midX, y: current.primary.bounds.midY), to: nil)
        XCTAssertEqual(before.y, after.y, accuracy: 1, "A newly added task must not move the button under the pointer")
        XCTAssertTrue(current === oldCell, "Appending new tasks must keep the existing native action cell")
        current.primary.performClick(nil)
        XCTAssertEqual(model.jobs.first { $0.id == id }?.state, "cancelled")
        XCTAssertEqual(model.jobs[0].state, "queued"); XCTAssertEqual(model.jobs[1].state, "queued")
    }
    @MainActor func testCompletionRemovingTheVisibleAnchorKeepsItsNextNeighbourReachable() async throws {
        let originals = (0..<60).map { job($0) }
        let (model, window, scroll, coordinator) = try await mount(originals)
        defer { close(model, window, coordinator) }
        scroll.table.scrollRowToVisible(35); await settle(scroll)
        let row = firstVisible(scroll), removed = originals[row].id, nextID = originals[row + 1].id
        let before = scroll.table.convert(scroll.table.rect(ofRow: row), to: nil).minY
        model.jobs[row].state = "completed"
        let active = model.jobs.filter(\.active)
        update(coordinator, model: model, jobs: active); await settle(scroll)
        let nextRow = try XCTUnwrap(active.firstIndex { $0.id == nextID })
        XCTAssertEqual(scroll.table.convert(scroll.table.rect(ofRow: nextRow), to: nil).minY, before, accuracy: 1)
        let actions = try XCTUnwrap(scroll.table.view(atColumn: 5, row: nextRow, makeIfNecessary: true) as? NativeDownloadActionsCell)
        actions.primary.performClick(nil)
        XCTAssertEqual(model.jobs.first { $0.id == nextID }?.state, "cancelled")
        XCTAssertEqual(model.jobs.first { $0.id == removed }?.state, "completed")
    }
    @MainActor func testFilteredOutOldActionsCannotAffectInvisibleTasks() async throws {
        let (model, window, scroll, coordinator) = try await mount([job(0), job(1, state: "failed")])
        defer { close(model, window, coordinator) }
        let actions = try XCTUnwrap(scroll.table.view(atColumn: 5, row: 0, makeIfNecessary: true) as? NativeDownloadActionsCell)
        let pendingPress = try XCTUnwrap(actions.onPrimary)
        update(coordinator, model: model, jobs: [model.jobs[1]]); await settle(scroll)
        pendingPress()
        XCTAssertEqual(model.jobs[0].state, "queued", "A pending action from a row removed by filtering must expire")
    }
    @MainActor func testUnchangedFailureDetailsSurviveInsertionAndCloseWhenFilteredAway() async throws {
        let failed = job(0, state: "failed")
        let (model, window, scroll, coordinator) = try await mount([failed, job(1)])
        defer { close(model, window, coordinator) }
        let actions = try XCTUnwrap(scroll.table.view(atColumn: 5, row: 0, makeIfNecessary: true) as? NativeDownloadActionsCell)
        actions.more.performClick(nil); await settle(scroll)
        let popover = try XCTUnwrap(coordinator.popover); XCTAssertTrue(popover.isShown)
        model.jobs.insert(job(2), at: 0); update(coordinator, model: model, jobs: model.jobs); await settle(scroll)
        XCTAssertTrue(popover.isShown, "Incoming unrelated tasks cannot dismiss the explanation being read")
        update(coordinator, model: model, jobs: [model.jobs[0]]); await settle(scroll)
        XCTAssertFalse(popover.isShown); XCTAssertNil(coordinator.popover)
    }
    @MainActor func testTaskStateChangesKeepActionLabelsVisibilityAndEnabledStateCorrect() async throws {
        let (model, window, scroll, coordinator) = try await mount([job(0)])
        defer { close(model, window, coordinator) }
        for (state, title, enabled, showExtras) in [("queued", "取消", true, false), ("downloading", "取消", true, false), ("converting", "取消", true, false), ("cancelling", "取消", false, false), ("cancelled", "重试", true, false), ("interrupted", "重试", true, false), ("failed", "重试", true, true), ("completed", "显示文件", true, false)] {
            model.jobs[0].state = state
            update(coordinator, model: model, jobs: model.jobs); await settle(scroll)
            let cell = try XCTUnwrap(scroll.table.view(atColumn: 5, row: 0, makeIfNecessary: true) as? NativeDownloadActionsCell)
            XCTAssertEqual(cell.primary.title, title, state); XCTAssertEqual(cell.primary.isEnabled, enabled, state)
            XCTAssertEqual(cell.switchSource.isHidden, !showExtras, state); XCTAssertEqual(cell.more.isHidden, !showExtras, state)
        }
    }
    @MainActor func testDeliberateScopeChangeResetsEvenWhenTheFilteredIDsAreIdentical() async throws {
        let jobs = (0..<60).map { job($0, state: "failed") }
        let (model, window, scroll, coordinator) = try await mount(jobs)
        defer { close(model, window, coordinator) }
        scroll.table.scrollRowToVisible(40); await settle(scroll)
        XCTAssertGreaterThan(scroll.contentView.bounds.minY, 0)
        coordinator.parent = NativeDownloadsTable(model: model, jobs: jobs, scope: "failed", showAccounts: {})
        coordinator.update(enabled: true); await settle(scroll)
        XCTAssertEqual(scroll.contentView.bounds.minY, -scroll.headerOverlap, accuracy: 0.5)
        let first = try XCTUnwrap(scroll.table.view(atColumn: 5, row: 0, makeIfNecessary: true) as? NativeDownloadActionsCell)
        first.layoutSubtreeIfNeeded()
        let point = first.more.convert(NSPoint(x: first.more.bounds.midX, y: first.more.bounds.midY), to: nil)
        let root = try XCTUnwrap(window.contentView)
        XCTAssertTrue(root.hitTest(root.superview?.convert(point, from: nil) ?? point) === first.more)
    }
    @MainActor func testClearAndRestoreAfterScrollingClampsTheViewportAndAllowsOnlyCurrentActions() async throws {
        let jobs = (0..<60).map { job($0) }
        let (model, window, scroll, coordinator) = try await mount(jobs)
        defer { close(model, window, coordinator) }
        scroll.table.scrollRowToVisible(59); await settle(scroll)
        let retained = try XCTUnwrap(scroll.table.view(atColumn: 5, row: 59, makeIfNecessary: true) as? NativeDownloadActionsCell)
        let oldPress = try XCTUnwrap(retained.onPrimary)
        update(coordinator, model: model, jobs: []); await settle(scroll)
        XCTAssertEqual(scroll.table.numberOfRows, 0)
        XCTAssertEqual(scroll.contentView.bounds.minY, -scroll.headerOverlap, accuracy: 0.5)
        oldPress(); XCTAssertEqual(model.jobs.last?.state, "queued")
        update(coordinator, model: model, jobs: [jobs[0]]); await settle(scroll)
        XCTAssertEqual(scroll.table.numberOfRows, 1)
        XCTAssertEqual(scroll.contentView.bounds.minY, -scroll.headerOverlap, accuracy: 0.5)
        let first = try XCTUnwrap(scroll.table.view(atColumn: 5, row: 0, makeIfNecessary: true) as? NativeDownloadActionsCell)
        first.primary.performClick(nil)
        XCTAssertEqual(model.jobs[0].state, "cancelled"); XCTAssertEqual(model.jobs.last?.state, "queued")
    }
    func testActualAccountAndToolErrorsExposeTheirRecoveryDestinations() {
        var value = job(0, state: "failed")
        for code in ["account_expired", "account_risk", "account_permission", "account_changed", "authentication"] {
            value.errorCode = code
            XCTAssertEqual(NativeDownloadPresentation.recoveryAction(value), .accounts, code)
        }
        for code in ["dependency", "conversion", "tool_launch", "tool_timeout", "tool_output"] {
            value.errorCode = code
            XCTAssertEqual(NativeDownloadPresentation.recoveryAction(value), .environment, code)
        }
        value.errorCode = "network"
        XCTAssertNil(NativeDownloadPresentation.recoveryAction(value))
        value.track = AudioTrack(raw: ["source": "qq"]); value.errorCode = "account_expired"
        XCTAssertNil(NativeDownloadPresentation.recoveryAction(value), "Unsupported account sources must not expose a dead login route")
    }

}
