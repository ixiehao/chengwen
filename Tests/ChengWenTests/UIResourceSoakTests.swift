import AppKit
import SwiftUI
import XCTest
@testable import ChengWen

private final class UIWeakObject {
    weak var value: AnyObject?
    init(_ value: AnyObject) { self.value = value }
}

final class UIResourceSoakTests: XCTestCase {
    @MainActor private func views<T: NSView>(_ root: NSView, _ type: T.Type) -> [T] {
        ((root as? T).map { [$0] } ?? []) + root.subviews.flatMap { views($0, type) }
    }
    @MainActor private func mount<V: View>(_ view: V) -> (NSWindow, NSHostingView<V>) {
        _ = NSApplication.shared
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 130), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.orderBack(nil)
        host.layoutSubtreeIfNeeded()
        return (window, host)
    }
    @MainActor func testRepeatedIntegerEditsImmediatelySynchroniseStepperBeforeNextRender() async throws {
        var value = 10
        let (window, host) = mount(NativeIntegerField(value: Binding(get: { value }, set: { value = $0 }), range: 1...100, label: "Synthetic immediate numeric input"))
        defer { window.makeFirstResponder(nil); window.contentView = nil; window.close() }
        try await Task.sleep(nanoseconds: 30_000_000)
        let control = try XCTUnwrap(views(host, NativeIntegerControl.self).first)
        for number in 11...60 {
            control.field.stringValue = String(number)
            control.field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: control.field))
            XCTAssertEqual(value, number)
            XCTAssertEqual(control.stepper.integerValue, number, "Typing and stepping must not temporarily refer to different numbers")
            control.stepper.integerValue += 1
            control.stepper.sendAction(control.stepper.action, to: control.stepper.target)
            XCTAssertEqual(value, number + 1)
            XCTAssertEqual(control.field.stringValue, String(number + 1))
        }
    }
    @MainActor func testClampedIntegerCommitUpdatesStepperBeforeFollowingArrowAction() async throws {
        var value = 10
        let (window, host) = mount(NativeIntegerField(value: Binding(get: { value }, set: { value = $0 }), range: 1...30, label: "Synthetic clamped input"))
        defer { window.makeFirstResponder(nil); window.contentView = nil; window.close() }
        try await Task.sleep(nanoseconds: 30_000_000)
        let control = try XCTUnwrap(views(host, NativeIntegerControl.self).first)
        control.field.stringValue = "999"
        control.field.sendAction(control.field.action, to: control.field.target)
        XCTAssertEqual(value, 30)
        XCTAssertEqual(control.stepper.integerValue, 30)
        control.stepper.integerValue -= 1
        control.stepper.sendAction(control.stepper.action, to: control.stepper.target)
        XCTAssertEqual(value, 29)
    }
    @MainActor private func transientTables(model: AppModel) -> [UIWeakObject] {
        autoreleasepool {
            let result = NativeResultsTable(model: model, focusedTrackID: .constant(nil)).makeCoordinator()
            let search = NativeResultsScrollView()
            search.resultsTable.delegate = result; search.resultsTable.dataSource = result; result.scroll = search
            result.update(isEnabled: true)
            let searchCell = result.tableView(search.resultsTable, viewFor: search.resultsTable.tableColumns[7], row: 0)!
            let download = NativeDownloadsTable(model: model, jobs: model.jobs, showAccounts: {}).makeCoordinator()
            let jobs = NativeDownloadsScrollView()
            jobs.table.delegate = download; jobs.table.dataSource = download; download.scroll = jobs
            download.update(enabled: true)
            let jobCell = download.tableView(jobs.table, viewFor: jobs.table.tableColumns[5], row: 0)!
            return [result, search, searchCell, download, jobs, jobCell].map(UIWeakObject.init)
        }
    }
    @MainActor func testOneHundredSearchAndDownloadTableGraphsReleaseWithTheirActionCells() {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("chengwen-table-resource-soak-" + UUID().uuidString)
        let model = AppModel(storeURL: root, engine: BackendClient { _, _, _ in XCTFail("Resource-only tables cannot issue requests"); return [:] })
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        let song = AudioTrack(raw: ["id": "resource", "title": "Synthetic resource song", "source": "qq", "url": "https://example.invalid/synthetic"])
        model.tracks = [song]
        var job = DownloadJob(track: song, format: "mp3", directory: root.path, lyrics: false); job.state = "failed"; model.jobs = [job]
        for _ in 0..<100 {
            let objects = transientTables(model: model)
            XCTAssertTrue(objects.allSatisfy { $0.value == nil }, "Retired native views, coordinators and action closures must not form a retained graph")
        }
    }
    @MainActor private func retiredFailurePopover() async throws -> [UIWeakObject] {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("chengwen-popover-resource-soak-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(storeURL: root, engine: BackendClient { _, _, _ in XCTFail("Popover-only fixture cannot issue requests"); return [:] })
        let song = AudioTrack(raw: ["id": "resource", "title": "Synthetic failed resource song", "source": "qq"])
        var job = DownloadJob(track: song, format: "mp3", directory: root.path, lyrics: false); job.state = "failed"; model.jobs = [job]
        let coordinator = NativeDownloadsTable(model: model, jobs: [job], showAccounts: {}).makeCoordinator()
        let scroll = NativeDownloadsScrollView()
        scroll.table.delegate = coordinator; scroll.table.dataSource = coordinator; coordinator.scroll = scroll
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 240), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = scroll; window.orderBack(nil)
        coordinator.update(enabled: true); scroll.layoutSubtreeIfNeeded()
        let cell = try XCTUnwrap(scroll.table.view(atColumn: 5, row: 0, makeIfNecessary: true) as? NativeDownloadActionsCell)
        cell.more.performClick(nil)
        try await Task.sleep(nanoseconds: 15_000_000)
        let popover = try XCTUnwrap(coordinator.popover)
        XCTAssertTrue(popover.isShown)
        let weak = [model, coordinator, scroll, popover].map(UIWeakObject.init)
        NativeDownloadsTable.dismantleNSView(scroll, coordinator: coordinator)
        XCTAssertNil(coordinator.popover); XCTAssertFalse(popover.isShown)
        XCTAssertNil(scroll.table.delegate); XCTAssertNil(scroll.table.dataSource)
        window.contentView = nil; window.close(); model.shutdown()
        return weak
    }
    @MainActor func testThirtyPopoverPageTeardownsReleaseCoordinatorsModelsAndPopovers() async throws {
        for _ in 0..<30 {
            let weak = try await retiredFailurePopover()
            let deadline = Date().addingTimeInterval(1)
            while weak.contains(where: { $0.value != nil }) && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
            XCTAssertTrue(weak.allSatisfy { $0.value == nil }, "Page teardown must release failed-detail snapshots and their model")
        }
    }
}
