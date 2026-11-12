import AppKit
import SwiftUI
import XCTest
@testable import ChengWen

private struct DownloadTableHarness: View {
    @ObservedObject var model: AppModel
    var body: some View { NativeDownloadsTable(model: model, jobs: Array(model.jobsNewestFirst), showAccounts: {}) }
}

final class NativeDownloadsTableTests: XCTestCase {
    @MainActor private func views<T: NSView>(_ root: NSView, _ type: T.Type) -> [T] {
        ((root as? T).map { [$0] } ?? []) + root.subviews.flatMap { views($0, type) }
    }
    @MainActor private func settle(_ view: NSView) async {
        view.layoutSubtreeIfNeeded(); try? await Task.sleep(nanoseconds: 60_000_000); view.layoutSubtreeIfNeeded()
    }
    private func job(_ title: String, state: String, created: String) -> DownloadJob {
        var value = DownloadJob(track: AudioTrack(raw: ["id": title, "title": title, "artist": "Synthetic artist", "source": "netease", "url": "https://example.invalid/audio"]), format: "mp3", directory: "/tmp", lyrics: false)
        value.state = state; value.created = created
        return value
    }
    @MainActor func testFixedRowsKeepLongFailureReadableInDetailsAndProgressDoesNotMoveSelection() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("chengwen-download-table-" + UUID().uuidString)
        let model = AppModel(storeURL: root, engine: BackendClient { _, _, _ in XCTFail("Table rendering cannot issue requests"); return [:] })
        var failed = job("Long failure", state: "failed", created: "2026-11-06T08:00:00Z")
        failed.detail = String(repeating: "当前来源暂不可用。", count: 80)
        failed.solution = "请更换其他来源或完整版本。"; failed.retryCount = 2
        var active = job("Active download", state: "downloading", created: "2026-11-06T09:00:00Z")
        active.percent = 42
        model.jobs = [failed, active]
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 836, height: 300), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: DownloadTableHarness(model: model)); window.contentView = host
        defer { window.contentView = nil; window.close(); model.shutdown(); try? FileManager.default.removeItem(at: root) }
        await settle(host)
        let scroll = try XCTUnwrap(views(host, NativeDownloadsScrollView.self).first), table = scroll.table
        XCTAssertEqual(table.tableColumns.map(\.title), ["歌曲 / 艺术家", "来源", "格式", "状态 / 进度", "说明", "操作"])
        XCTAssertEqual(table.numberOfRows, 2)
        let header = try XCTUnwrap(table.headerView?.superview)
        let firstRow = table.convert(table.rect(ofRow: 0), to: scroll)
        XCTAssertGreaterThanOrEqual(firstRow.minY, header.frame.maxY - 0.5, "Header must not cover short task lists")
        XCTAssertEqual(table.rect(ofRow: 0).height, table.rect(ofRow: 1).height)
        XCTAssertLessThanOrEqual(table.rowHeight, 50)
        let detail = try XCTUnwrap(table.view(atColumn: 4, row: 1, makeIfNecessary: true) as? NativeResultTextCell)
        XCTAssertTrue(detail.toolTip?.contains(failed.solution) == true)
        XCTAssertTrue(detail.toolTip?.contains(failed.detail) == true)
        XCTAssertTrue(detail.label.stringValue.contains("建议换源"))
        table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        model.jobs[1].percent = 90; await settle(host)
        XCTAssertEqual(table.selectedRow, 1)
        let status = try XCTUnwrap(table.view(atColumn: 3, row: 0, makeIfNecessary: true) as? NativeDownloadStatusCell)
        XCTAssertEqual(status.label.stringValue, "下载中 90%")
        XCTAssertEqual(status.progress.doubleValue, 90)
        XCTAssertFalse(status.progress.isHidden)
        let actions = try XCTUnwrap(table.view(atColumn: 5, row: 0, makeIfNecessary: true) as? NativeDownloadActionsCell)
        actions.primary.performClick(nil); await settle(host)
        XCTAssertEqual(model.jobs.first { $0.id == active.id }?.state, "cancelled")
        XCTAssertEqual(model.jobs.first { $0.id == failed.id }?.state, "failed")
        let cancelled = try XCTUnwrap(table.view(atColumn: 3, row: 0, makeIfNecessary: true) as? NativeDownloadStatusCell)
        XCTAssertTrue(cancelled.progress.isHidden)
    }
    @MainActor func testReorderedAndDisabledRowsNeverCancelTheWrongJob() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("chengwen-download-actions-" + UUID().uuidString)
        let model = AppModel(storeURL: root, engine: BackendClient { _, _, _ in XCTFail("Table actions must remain local in this test"); return [:] })
        let old = job("Older task", state: "queued", created: "2026-11-06T08:00:00Z")
        let new = job("Newer task", state: "queued", created: "2026-11-06T09:00:00Z")
        model.jobs = [old]
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 836, height: 300), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: DownloadTableHarness(model: model).disabled(true)); window.contentView = host
        defer { window.contentView = nil; window.close(); model.shutdown(); try? FileManager.default.removeItem(at: root) }
        await settle(host)
        let table = try XCTUnwrap(views(host, NativeDownloadsScrollView.self).first?.table)
        let disabled = try XCTUnwrap(table.view(atColumn: 5, row: 0, makeIfNecessary: true) as? NativeDownloadActionsCell)
        XCTAssertFalse(disabled.primary.isEnabled)
        disabled.primary.performClick(nil)
        XCTAssertEqual(model.jobs[0].state, "queued")
        host.rootView = DownloadTableHarness(model: model).disabled(false)
        model.jobs.append(new); await settle(host)
        let newest = try XCTUnwrap(table.view(atColumn: 5, row: 0, makeIfNecessary: true) as? NativeDownloadActionsCell)
        XCTAssertEqual(newest.primary.accessibilityIdentifier(), "download-primary-\(new.id)")
        newest.primary.performClick(nil); await settle(host)
        XCTAssertEqual(model.jobs.first { $0.id == new.id }?.state, "cancelled")
        XCTAssertEqual(model.jobs.first { $0.id == old.id }?.state, "queued")
    }
    @MainActor func testFailureDetailsCloseWhenTheirJobDisappears() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("chengwen-download-detail-" + UUID().uuidString)
        let model = AppModel(storeURL: root, engine: BackendClient { _, _, _ in XCTFail("Failure details must not start work"); return [:] })
        var failed = job("Failure details", state: "failed", created: "2026-11-06T08:00:00Z")
        failed.detail = "Synthetic failure reason"; failed.solution = "Synthetic solution"
        model.jobs = [failed]
        let tableView = NativeDownloadsTable(model: model, jobs: [failed], showAccounts: {})
        let coordinator = tableView.makeCoordinator()
        let scroll = NativeDownloadsScrollView(frame: NSRect(x: 0, y: 0, width: 840, height: 300))
        scroll.table.dataSource = coordinator; scroll.table.delegate = coordinator; coordinator.scroll = scroll
        let window = NSWindow(contentRect: scroll.frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = scroll; window.orderBack(nil)
        defer { coordinator.popover?.close(); window.contentView = nil; window.close(); model.shutdown(); try? FileManager.default.removeItem(at: root) }
        coordinator.update(enabled: true); await settle(scroll)
        let cell = try XCTUnwrap(scroll.table.view(atColumn: 5, row: 0, makeIfNecessary: true) as? NativeDownloadActionsCell)
        cell.more.performClick(nil); await settle(scroll)
        let openedPopover = try XCTUnwrap(coordinator.popover)
        XCTAssertTrue(openedPopover.isShown)
        model.jobs = []
        coordinator.parent = NativeDownloadsTable(model: model, jobs: [], showAccounts: {})
        coordinator.update(enabled: true); await settle(scroll)
        XCTAssertFalse(openedPopover.isShown, "A removed job cannot leave stale details on screen")
    }
}
