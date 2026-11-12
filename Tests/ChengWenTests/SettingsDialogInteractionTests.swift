import AppKit
import SwiftUI
import XCTest
import Vision
@testable import ChengWen

private actor SettingsHealthGate {
    private var open = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        guard !open else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() {
        open = true
        let pending = waiters; waiters = []; pending.forEach { $0.resume() }
    }
    func reset() { open = false }
}

@MainActor private final class SettingsAuditChoice: ObservableObject {
    @Published var tab: NativePreferencesTab = .general
}
private struct SettingsAuditHarness: View {
    @ObservedObject var model: AppModel
    @ObservedObject var choice: SettingsAuditChoice
    var enabled = true
    var body: some View {
        NativePreferencesPage(tab: $choice.tab).environmentObject(model).disabled(!enabled)
    }
}

final class SettingsDialogInteractionTests: XCTestCase {
    @MainActor private func views<T: NSView>(_ root: NSView, _ type: T.Type) -> [T] {
        ((root as? T).map { [$0] } ?? []) + root.subviews.flatMap { views($0, type) }
    }
    @MainActor private func settle(_ view: NSView) async {
        view.layoutSubtreeIfNeeded(); try? await Task.sleep(nanoseconds: 50_000_000); view.layoutSubtreeIfNeeded()
    }
    @MainActor private func mount<V: View>(_ view: V, width: CGFloat = 860, height: CGFloat = 400) -> (NSWindow, NSHostingView<V>) {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: view); window.contentView = host; window.orderBack(nil)
        return (window, host)
    }
    @MainActor private func close(_ window: NSWindow) { window.makeFirstResponder(nil); window.contentView = nil; window.close() }
    @MainActor private func assertHit(_ view: NSView, in window: NSWindow, yFraction: CGFloat = 0.5, file: StaticString = #filePath, line: UInt = #line) throws {
        let content = try XCTUnwrap(window.contentView, file: file, line: line)
        let point = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.minY + view.bounds.height * yFraction), to: nil)
        let target = content.hitTest(content.superview?.convert(point, from: nil) ?? point)
        XCTAssertTrue(target === view || target?.isDescendant(of: view) == true,
                      "Visible control \(type(of: view)) frame \(view.frame), visible \(view.visibleRect) must own its window hit area at \(point); got \(String(describing: target))", file: file, line: line)
    }
    @MainActor func testGeneralFieldsRemainReachableAfterScrollingResizingTabAndEnabledChanges() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("chengwen-settings-interactions-" + UUID().uuidString)
        let model = AppModel(storeURL: root, engine: BackendClient { _, _, _ in XCTFail("Settings interactions must not request engine or account access"); return [:] })
        let choice = SettingsAuditChoice()
        let (window, host) = mount(SettingsAuditHarness(model: model, choice: choice))
        defer { close(window); model.shutdown(); try? FileManager.default.removeItem(at: root) }
        await settle(host)
        let controls = views(host, NativeIntegerControl.self)
        XCTAssertEqual(controls.count, 3)
        for (index, control) in controls.enumerated() {
            control.scrollToVisible(control.bounds); await settle(host)
            try assertHit(control.field, in: window)
            try assertHit(control.stepper, in: window, yFraction: 0.25)
            try assertHit(control.stepper, in: window, yFraction: 0.75)
            XCTAssertTrue(window.makeFirstResponder(control.field))
            let editor = try XCTUnwrap(control.field.currentEditor() as? NSTextView)
            editor.selectAll(nil); editor.insertText(["17", "120", "3"][index], replacementRange: editor.selectedRange())
            editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        }
        XCTAssertEqual(model.settings.limit, 17); XCTAssertEqual(model.settings.timeout, 120); XCTAssertEqual(model.settings.concurrency, 3)
        window.makeFirstResponder(nil)
        choice.tab = .accounts; await settle(host)
        XCTAssertTrue(views(host, NativeIntegerControl.self).isEmpty)
        choice.tab = .general; await settle(host)
        window.setContentSize(NSSize(width: 760, height: 350)); await settle(host)
        host.rootView = SettingsAuditHarness(model: model, choice: choice, enabled: false); await settle(host)
        XCTAssertTrue(views(host, NativeIntegerControl.self).allSatisfy { !$0.field.isEnabled && !$0.stepper.isEnabled })
        host.rootView = SettingsAuditHarness(model: model, choice: choice); await settle(host)
        for control in views(host, NativeIntegerControl.self) {
            XCTAssertTrue(control.field.isEnabled && control.stepper.isEnabled)
            control.scrollToVisible(control.bounds); await settle(host)
            try assertHit(control.field, in: window)
            try assertHit(control.stepper, in: window, yFraction: 0.25)
            try assertHit(control.stepper, in: window, yFraction: 0.75)
        }
        let popup = try XCTUnwrap(views(host, NSPopUpButton.self).first { $0.accessibilityLabel() == "默认音频格式" })
        popup.scrollToVisible(popup.bounds); await settle(host)
        try assertHit(popup, in: window)
        popup.selectItem(at: try XCTUnwrap(AudioFormat.all.firstIndex { $0.id == "flac" }))
        popup.sendAction(popup.action, to: popup.target)
        XCTAssertEqual(model.settings.format, "flac")
    }
    @MainActor func testInstallationMethodPopupRemainsReachableThroughScrollAndRepeatedChanges() async throws {
        let (window, host) = mount(ScrollView { NativeDependencyGuide().padding(16) }, width: 620, height: 280)
        defer { close(window) }
        await settle(host)
        let popup = try XCTUnwrap(views(host, NSPopUpButton.self).first { $0.accessibilityIdentifier() == "installation-method" })
        XCTAssertEqual(popup.itemTitles, ["Homebrew", "MacPorts / Monterey", "手动安装"])
        for index in [2, 0, 1, 2, 1, 0] {
            popup.scrollToVisible(popup.bounds); await settle(host)
            try assertHit(popup, in: window)
            popup.selectItem(at: index); popup.sendAction(popup.action, to: popup.target); await settle(host)
            XCTAssertEqual(popup.indexOfSelectedItem, index)
        }
        window.setContentSize(NSSize(width: 560, height: 240)); await settle(host)
        popup.scrollToVisible(popup.bounds); await settle(host)
        try assertHit(popup, in: window)
        XCTAssertTrue(popup.isEnabled)
    }
    @MainActor func testAccountPendingFailureReenablesReturnAndEscapeCancelsOwnedWindow() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("chengwen-account-interactions-" + UUID().uuidString)
        var completions: [(@MainActor (Result<NativeOwnedAccountSession, NativeAccountProblem>) -> Void)] = []
        let model = NativeAccountViewModel(platform: "netease", storeURL: root, request: { _, _, _, _ in XCTFail("Synthetic invalid login must not activate an account"); return {} }, vault: MemoryAccountVault(), autoLoadWeb: false, ownedSessionReader: { callback in completions.append(callback) }, onChange: {})
        let (window, host) = mount(NativeAccountConnectionView(model: model), width: 800, height: 660)
        var closes = 0
        model.requestClose = { closes += 1; model.close(); window.close() }
        defer { model.requestClose = nil; model.close(); close(window); try? FileManager.default.removeItem(at: root) }
        await settle(host)
        func key(_ characters: String, _ code: UInt16) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
        }
        XCTAssertTrue(window.performKeyEquivalent(with: try key("\r", 36))); await settle(host)
        XCTAssertTrue(model.isBusy); XCTAssertEqual(completions.count, 1)
        _ = window.performKeyEquivalent(with: try key("\r", 36)); await settle(host)
        XCTAssertEqual(completions.count, 1, "A pending connection must not duplicate requests")
        completions[0](.failure(NativeAccountProblem(reason: "Synthetic login required", solution: "Complete the local test login")))
        await settle(host); XCTAssertFalse(model.isBusy)
        XCTAssertTrue(window.performKeyEquivalent(with: try key("\r", 36))); await settle(host)
        XCTAssertTrue(model.isBusy); XCTAssertEqual(completions.count, 2)
        XCTAssertTrue(window.performKeyEquivalent(with: try key("\u{1b}", 53)))
        XCTAssertEqual(closes, 1); XCTAssertFalse(window.isVisible)
        completions[1](.failure(NativeAccountProblem(reason: "Late ignored failure", solution: "")))
        XCTAssertNotEqual(model.reason, "Late ignored failure")
    }
    @MainActor func testEnvironmentSheetCanCloseDuringHealthCheckAndReopenWithInteractiveInstallPicker() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("chengwen-health-interactions-" + UUID().uuidString)
        let gate = SettingsHealthGate()
        let model = AppModel(storeURL: root, engine: BackendClient { operation, _, _ in
            XCTAssertEqual(operation, "health")
            await gate.wait()
            return ["items": [
                ["key": "engine", "title": "Synthetic engine", "state": "ready", "required": true],
                ["key": "ffmpeg", "title": "FFmpeg", "state": "missing", "required": true],
                ["key": "ffprobe", "title": "FFprobe", "state": "missing", "required": true]
            ]]
        })
        let (window, host) = mount(NativeRootView().environmentObject(model), width: 1080, height: 740)
        defer { Task { await gate.release() }; model.showEnvironment = false; close(window); model.shutdown(); try? FileManager.default.removeItem(at: root) }
        await settle(host)
        func eventually(_ condition: () -> Bool) async throws {
            let deadline = ProcessInfo.processInfo.systemUptime + 3
            while !condition() && ProcessInfo.processInfo.systemUptime < deadline { try await Task.sleep(nanoseconds: 5_000_000) }
            XCTAssertTrue(condition())
        }
        func key(_ characters: String, _ code: UInt16, in sheet: NSWindow) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: sheet.windowNumber, context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
        }
        model.checkEnvironment()
        try await eventually { window.attachedSheet != nil }
        let initial = try XCTUnwrap(window.attachedSheet)
        XCTAssertTrue(model.isCheckingEnvironment)
        XCTAssertTrue(initial.performKeyEquivalent(with: try key("\u{1b}", 53, in: initial)))
        try await eventually { !model.showEnvironment && window.attachedSheet == nil }
        XCTAssertTrue(model.isCheckingEnvironment, "Closing the sheet must work while the health operation is pending")
        await gate.release()
        try await eventually { !model.isCheckingEnvironment }
        XCTAssertEqual(model.healthItems.count, 3)
        model.showEnvironment = true
        try await eventually { window.attachedSheet != nil }
        let reopened = try XCTUnwrap(window.attachedSheet), content = try XCTUnwrap(reopened.contentView)
        await settle(content)
        let popup = try XCTUnwrap(views(content, NSPopUpButton.self).first { $0.accessibilityIdentifier() == "installation-method" })
        popup.scrollToVisible(popup.bounds); await settle(content)
        try assertHit(popup, in: reopened)
        popup.selectItem(at: 2); popup.sendAction(popup.action, to: popup.target); await settle(content)
        XCTAssertEqual(popup.indexOfSelectedItem, 2)
        popup.selectItem(at: 0); popup.sendAction(popup.action, to: popup.target); await settle(content)
        XCTAssertEqual(popup.indexOfSelectedItem, 0)
        XCTAssertTrue(reopened.performKeyEquivalent(with: try key("\r", 36, in: reopened)))
        try await eventually { !model.showEnvironment && window.attachedSheet == nil }
        await gate.reset()
        model.checkEnvironment()
        try await eventually { window.attachedSheet != nil }
        let repeated = try XCTUnwrap(window.attachedSheet)
        XCTAssertTrue(model.isCheckingEnvironment)
        XCTAssertTrue(repeated.performKeyEquivalent(with: try key("\r", 36, in: repeated)))
        try await eventually { !model.showEnvironment && window.attachedSheet == nil }
        await gate.release()
        try await eventually { !model.isCheckingEnvironment }
    }

    @MainActor func testLongSavedPathCannotExpandRootWindowOrHideChangeButtonAfterNavigation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("chengwen-long-path-layout-" + UUID().uuidString)
        let model = AppModel(storeURL: root, engine: BackendClient { _, _, _ in XCTFail("Path layout must not access accounts or issue requests"); return [:] })
        model.settings.directory = root.appendingPathComponent(String(repeating: "AudioCollection-", count: 6) + "Output").path
        XCTAssertGreaterThan(model.settings.directory.count, 150)
        let (window, host) = mount(NativeRootView().environmentObject(model), width: 1080, height: 740)
        defer { close(window); model.shutdown(); try? FileManager.default.removeItem(at: root) }
        await settle(host)
        model.page = .preferences; await settle(host)
        let customerWidth = window.contentRect(forFrameRect: window.frame).width
        print("LONG_PATH_LAYOUT", model.settings.directory.count, "window", window.frame, "host", host.bounds)
        XCTAssertEqual(customerWidth, 1080, accuracy: 1, "A long read-only path must not expand the user's window")
        XCTAssertEqual(host.bounds.width, 1080, accuracy: 1, "The preferences content must remain in the requested client area")
        let pathField = try XCTUnwrap(views(host, NSTextField.self).first { $0.accessibilityLabel() == "音频保存位置" })
        let pathRect = pathField.convert(pathField.bounds, to: host)
        print("LONG_PATH_FIELD", pathRect, "intrinsic", pathField.intrinsicContentSize)
        XCTAssertLessThan(pathRect.maxX, 1080, "The read-only path must leave visible space for the change-folder action")
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let request = VNRecognizeTextRequest(); request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "en-US"]; request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: try XCTUnwrap(bitmap.cgImage), options: [:]).perform([request])
        let match = try XCTUnwrap(request.results?.first { item in
            item.topCandidates(3).contains { $0.string.contains("更改") }
        }, "The actual settings bitmap must contain the change-folder button. Recognized: \((request.results ?? []).compactMap { $0.topCandidates(1).first?.string })")
        let box = match.boundingBox
        let text = NSRect(x: box.minX * host.bounds.width,
                          y: (host.isFlipped ? 1 - box.maxY : box.minY) * host.bounds.height,
                          width: box.width * host.bounds.width, height: box.height * host.bounds.height)
        XCTAssertGreaterThanOrEqual(text.minX, 0)
        XCTAssertLessThanOrEqual(text.maxX, 1080, "The change-folder action must stay inside the user's original window")
        let location = host.convert(NSPoint(x: text.midX, y: text.midY), to: nil)
        let hit = host.hitTest(host.superview?.convert(location, from: nil) ?? location)
        XCTAssertNotNil(hit)
        XCTAssertFalse(hit is NSTextField, "The change-folder label must not be obscured by the read-only path")
        XCTAssertFalse(hit is NSClipView)
        XCTAssertTrue(hit?.window === window)
    }

}
