import AppKit
import SwiftUI
import XCTest
@testable import ChengWen

private actor SearchAuditRequests {
    var operations: [String] = []
    func append(_ value: String) { operations.append(value) }
    func count(_ value: String) -> Int { operations.filter { $0 == value }.count }
}

final class SearchInteractionAuditTests: XCTestCase {
    private func track(_ id: Int) -> AudioTrack {
        AudioTrack(raw: ["id": "audit-\(id)", "title": "Synthetic song \(id)", "artist": "Synthetic artist", "album": "Synthetic album", "source": "netease", "duration": "3:24", "url": "https://music.163.com/song?id=\(id + 1)"])
    }
    @MainActor private func model() -> (AppModel, SearchAuditRequests) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("chengwen-search-interaction-" + UUID().uuidString)
        let journal = SearchAuditRequests()
        let model = AppModel(storeURL: root, engine: BackendClient { operation, payload, event in
            await journal.append(operation)
            if operation == "search" {
                event("track", ["id": "streamed", "title": "Synthetic streamed song", "source": "netease", "url": "https://music.163.com/song?id=123"])
            }
            try await Task.sleep(nanoseconds: 60_000_000_000)
            return [:]
        })
        model.settings.sources = ["netease"]
        return (model, journal)
    }
    @MainActor private func views<T: NSView>(_ view: NSView, _ type: T.Type) -> [T] {
        ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { views($0, type) }
    }
    @MainActor private func mount<V: View>(_ view: V, width: CGFloat = 1080, height: CGFloat = 740) async -> (NSWindow, NSHostingView<V>) {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: view); window.contentView = host; window.orderBack(nil)
        await settle(host)
        return (window, host)
    }
    @MainActor private func settle(_ view: NSView) async {
        view.layoutSubtreeIfNeeded(); try? await Task.sleep(nanoseconds: 50_000_000); view.layoutSubtreeIfNeeded()
    }
    @MainActor private func close(_ window: NSWindow, _ model: AppModel) {
        window.makeFirstResponder(nil); window.contentView = nil; window.close(); model.shutdown()
        try? FileManager.default.removeItem(at: model.storeURL)
    }
    @MainActor private func hit(_ control: NSView, window: NSWindow, x: CGFloat = 0.5, y: CGFloat = 0.5) throws -> NSView? {
        let point = control.convert(NSPoint(x: control.bounds.width * x, y: control.bounds.height * y), to: nil)
        let content = try XCTUnwrap(window.contentView)
        return content.hitTest(content.superview?.convert(point, from: nil) ?? point)
    }
    @MainActor private func reachable(_ control: NSView, window: NSWindow, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) throws {
        let target = try hit(control, window: window)
        XCTAssertTrue(target === control || target?.isDescendant(of: control) == true,
                      "\(message) must receive the visible click; got \(String(describing: target))", file: file, line: line)
    }
    @MainActor private func button(_ title: String, host: NSView) throws -> NSButton {
        try XCTUnwrap(views(host, NSButton.self).first { $0.title == title }, "Missing \(title)")
    }
    @MainActor func testRootSearchStopAndSourceControlsRemainReachableAfterStreamingAndRestore() async throws {
        let (model, journal) = model(); model.keyword = "Synthetic keyboard search"
        let (window, host) = await mount(NativeRootView().environmentObject(model))
        defer { close(window, model) }
        let field = try XCTUnwrap(views(host, NSSearchField.self).first)
        let search = try button("搜索", host: host)
        try reachable(field, window: window, "Search field"); try reachable(search, window: window, "Search button")
        let checkboxes = views(host, NSButton.self).filter { $0.accessibilityLabel()?.hasPrefix("搜索音源：") == true }
        XCTAssertEqual(checkboxes.count, MusicSource.available.count)
        for source in checkboxes { try reachable(source, window: window, source.title) }
        search.performClick(nil); await settle(host)
        XCTAssertTrue(model.isSearching); XCTAssertFalse(field.isEnabled)
        XCTAssertTrue(checkboxes.allSatisfy { !$0.isEnabled })
        XCTAssertTrue(model.tracks.contains { $0.id == "streamed" })
        let stop = try button("停止", host: host)
        try reachable(stop, window: window, "Stop after streamed results")
        stop.performClick(nil); await settle(host)
        XCTAssertFalse(model.isSearching); XCTAssertTrue(field.isEnabled)
        XCTAssertTrue(checkboxes.allSatisfy(\.isEnabled))
        let calls = await journal.count("search"); XCTAssertEqual(calls, 1, "A reused search/stop button must call its latest action")
        let restored = try button("搜索", host: host); try reachable(restored, window: window, "Restored search")
        let old = model.settings.sources
        let extra = try XCTUnwrap(checkboxes.first { $0.title == "酷我音乐" })
        extra.performClick(nil); await settle(host)
        XCTAssertNotEqual(model.settings.sources, old); XCTAssertTrue(model.settings.sources.contains("kuwo"))
    }
    @MainActor func testResultCheckboxAndActionsStayReachableAfterVerticalScrollAppendAndReplacement() async throws {
        let (model, _) = model(); model.tracks = (0..<80).map(track)
        let (window, host) = await mount(NativeResultsTable(model: model, focusedTrackID: .constant(nil)), width: 940, height: 300)
        defer { close(window, model) }
        let scroll = try XCTUnwrap(views(host, NativeResultsScrollView.self).first), table = scroll.resultsTable
        table.scrollRowToVisible(70); await settle(host)
        let before = scroll.contentView.bounds.origin
        model.probes[model.tracks[70].id] = ProbeStatus(state: "failed", detail: "Synthetic sample failure")
        model.tracks.append(track(80)); await settle(host)
        XCTAssertEqual(scroll.contentView.bounds.minY, before.y, accuracy: 1)
        let index = 70
        let selectorCell = try XCTUnwrap(table.view(atColumn: 0, row: index, makeIfNecessary: true))
        selectorCell.layoutSubtreeIfNeeded()
        let selector = try XCTUnwrap(views(selectorCell, NSButton.self).first)
        try reachable(selector, window: window, "Scrolled row selection")
        selector.performClick(nil); await settle(host)
        XCTAssertTrue(model.selection.contains("audit-70"))
        let actionCell = try XCTUnwrap(table.view(atColumn: 7, row: index, makeIfNecessary: true))
        actionCell.layoutSubtreeIfNeeded()
        let download = try XCTUnwrap(views(actionCell, NSButton.self).first { $0.title == "下载" })
        try reachable(download, window: window, "Scrolled failed-probe row download")
        download.performClick(nil); XCTAssertEqual(model.jobs.first?.track.id, "audit-70")
        model.tracks = [track(900)]; model.selection = []; await settle(host)
        let header = scroll.resultsHeader.selectAllButton
        try reachable(header, window: window, "Header select all after shrink")
        header.performClick(nil); await settle(host)
        XCTAssertEqual(model.selection, ["audit-900"])
        let first = try XCTUnwrap(table.view(atColumn: 7, row: 0, makeIfNecessary: true)); first.layoutSubtreeIfNeeded()
        for action in views(first, NSButton.self) { try reachable(action, window: window, "Replaced first row \(action.title)") }
        window.setContentSize(NSSize(width: 800, height: 200)); await settle(host)
        try reachable(header, window: window, "Header after resize")
    }
    @MainActor func testHorizontalScrollStillReachesActionsAndHeaderSelectionAfterReturningLeft() async throws {
        let (model, _) = model(); model.tracks = [track(1)]
        let (window, host) = await mount(NativeResultsTable(model: model, focusedTrackID: .constant(nil)), width: 840, height: 220)
        defer { close(window, model) }
        let scroll = try XCTUnwrap(views(host, NativeResultsScrollView.self).first), table = scroll.resultsTable
        table.tableColumns[1].width = 800; table.tableColumns[2].width = 500
        await settle(host)
        let last = table.rect(ofColumn: 7)
        table.scrollToVisible(NSRect(x: last.maxX - 100, y: 0, width: 100, height: 44)); await settle(host)
        XCTAssertGreaterThan(scroll.contentView.bounds.minX, 0)
        let actions = try XCTUnwrap(table.view(atColumn: 7, row: 0, makeIfNecessary: true)); actions.layoutSubtreeIfNeeded()
        let download = try XCTUnwrap(views(actions, NSButton.self).first { $0.title == "下载" })
        try reachable(download, window: window, "Horizontally scrolled download")
        download.performClick(nil); XCTAssertEqual(model.jobs.first?.track.id, "audit-1")
        scroll.contentView.scroll(to: NSPoint(x: 0, y: -scroll.headerOverlap)); scroll.reflectScrolledClipView(scroll.contentView); await settle(host)
        try reachable(scroll.resultsHeader.selectAllButton, window: window, "Header after horizontal return")
        scroll.resultsHeader.selectAllButton.performClick(nil); await settle(host)
        XCTAssertEqual(model.selection, ["audit-1"])
    }
    @MainActor func testSelectedHeaderAndBatchControlsRemainReachableDuringProbeStateChanges() async throws {
        let (model, _) = model(); model.tracks = (0..<4).map(track)
        let (window, host) = await mount(NativeRootView().environmentObject(model))
        defer { close(window, model) }
        let scroll = try XCTUnwrap(views(host, NativeResultsScrollView.self).first)
        let header = scroll.resultsHeader.selectAllButton
        try reachable(header, window: window, "Header checkbox")
        header.performClick(nil); await settle(host)
        XCTAssertTrue(model.allSelected)
        model.isProbing = true
        model.probes[model.tracks[0].id] = ProbeStatus(state: "checking")
        model.probes[model.tracks[1].id] = ProbeStatus(state: "failed")
        await settle(host)
        let download = try XCTUnwrap(views(host, NSButton.self).first { $0.accessibilityIdentifier() == "download-selected" })
        XCTAssertTrue(download.isEnabled); try reachable(download, window: window, "Batch download during probe")
        let popup = try XCTUnwrap(views(host, NSPopUpButton.self).first)
        try reachable(popup, window: window, "Format during probe")
        let index = try XCTUnwrap(AudioFormat.all.firstIndex { $0.id == "flac" })
        popup.selectItem(at: index); popup.sendAction(popup.action, to: popup.target)
        download.performClick(nil)
        XCTAssertEqual(model.jobs.count, 4); XCTAssertTrue(model.jobs.allSatisfy { $0.format == "flac" })
        header.performClick(nil); await settle(host)
        XCTAssertTrue(model.selection.isEmpty); XCTAssertFalse(download.isEnabled)
        try reachable(header, window: window, "Deselect all after state refresh")
    }
    @MainActor func testTransientNoticeDoesNotInterceptSourceCheckboxes() async throws {
        let (model, _) = model(); model.keyword = "Synthetic notice click test"
        let (window, host) = await mount(NativeRootView().environmentObject(model))
        defer { close(window, model) }
        let checkboxes = views(host, NSButton.self).filter { $0.accessibilityLabel()?.hasPrefix("搜索音源：") == true }
        for source in checkboxes { try reachable(source, window: window, "Before toast \(source.title)") }
        model.notice = "已加入下载队列"
        try await Task.sleep(nanoseconds: 300_000_000)
        await settle(host)
        for source in checkboxes {
            let target = try hit(source, window: window)
            if target !== source && target?.isDescendant(of: source) != true {
                print("TOAST_INTERCEPT", source.title, source.convert(source.bounds, to:nil), String(describing:target))
            }
            try reachable(source, window: window, "With toast \(source.title)")
        }
    }

    @MainActor func testRecentSearchReorderAndClearHistoryRetainCurrentSearch() async throws {
        // Recent-search controls are SwiftUI virtual buttons, not NSButtons in
        // standalone XCTest. Their actual horizontal-scroll clicks are covered
        // by the separate owned-app mouse audit; verify the action semantics here.
        let (model, journal) = model()
        defer { model.shutdown(); try? FileManager.default.removeItem(at:model.storeURL) }
        model.settings.recent = (1...8).map { "Recent \($0) · Synthetic music keyword" }
        let expected = try XCTUnwrap(model.settings.recent.last)
        model.searchRecent(expected)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(model.keyword, expected); XCTAssertTrue(model.isSearching)
        XCTAssertEqual(model.settings.recent.first, expected)
        XCTAssertEqual(Set(model.settings.recent).count, 8)
        let next = try XCTUnwrap(model.settings.recent.dropFirst().first)
        model.searchRecent(next)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(model.keyword, next); XCTAssertEqual(model.settings.recent.first, next)
        model.clearRecent()
        XCTAssertTrue(model.settings.recent.isEmpty); XCTAssertTrue(model.isSearching)
        let count = await journal.count("search"); XCTAssertEqual(count, 2, "Clearing history must not start or cancel search")
        model.stopSearch(); XCTAssertFalse(model.isSearching)
    }

}
