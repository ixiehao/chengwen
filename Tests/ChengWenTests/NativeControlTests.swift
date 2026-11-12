import AppKit
import SwiftUI
import XCTest
@testable import ChengWen

final class NativeControlTests: XCTestCase {
    @MainActor func testSearchFieldCommitsReturnAndDoesNotSearchWhenCleared() async throws {
        var text = ""
        var submissions = 0
        let fixture = mount(NativeSearchField(text: Binding(get: { text }, set: { text = $0 }),
                                              label: "搜索合成音乐", onSearch: { submissions += 1 }))
        defer { fixture.window.makeFirstResponder(nil); fixture.window.contentView = nil }
        await settle(fixture.host)
        let field = try XCTUnwrap(descendants(fixture.host, of: NSSearchField.self).first)
        XCTAssertEqual(field.accessibilityLabel(), "搜索合成音乐")
        XCTAssertTrue(field.sendsWholeSearchString)
        XCTAssertEqual(field.maximumRecents, 0)
        XCTAssertTrue(field.acceptsFirstResponder)
        field.stringValue = "Synthetic piano"
        field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
        XCTAssertEqual(text, "Synthetic piano")
        XCTAssertEqual(submissions, 0, "Typing must not start network searches")
        field.sendAction(field.action, to: field.target)
        XCTAssertEqual(submissions, 1)
        field.stringValue = ""
        field.sendAction(field.action, to: field.target)
        XCTAssertEqual(text, "")
        XCTAssertEqual(submissions, 1, "The clear action must only clear the binding")
    }

    @MainActor func testFormatPickerIsNativePopupWithStableValuesAndSystemIndicator() async throws {
        var selection = "mp3"
        let fixture = mount(NativeFormatPicker(selection: Binding(get: { selection }, set: { selection = $0 }),
                                               label: "合成格式"))
        defer { fixture.window.makeFirstResponder(nil); fixture.window.contentView = nil }
        await settle(fixture.host)
        let popup = try XCTUnwrap(descendants(fixture.host, of: NSPopUpButton.self).first)
        XCTAssertTrue(popup is NativeFormatPopUpButton)
        XCTAssertFalse(popup.pullsDown)
        XCTAssertEqual(popup.accessibilityLabel(), "合成格式")
        XCTAssertEqual(popup.itemTitles, AudioFormat.all.map(\.name))
        XCTAssertNotEqual((popup.cell as? NSPopUpButtonCell)?.arrowPosition, .noArrow)
        XCTAssertNotNil(popup.menu)
        XCTAssertEqual(popup.selectedItem?.representedObject as? String, "mp3")
        let flacIndex = try XCTUnwrap(AudioFormat.all.firstIndex { $0.id == "flac" })
        popup.selectItem(at: flacIndex)
        popup.sendAction(popup.action, to: popup.target)
        XCTAssertEqual(selection, "flac")
        let indicatorPoint=popup.convert(NSPoint(x:popup.bounds.maxX-8,y:popup.bounds.midY),to:fixture.host)
        let hit=try XCTUnwrap(fixture.host.hitTest(indicatorPoint))
        XCTAssertTrue(hit===popup || hit.isDescendant(of:popup),"The system indicator's click area must belong to the native pop-up")
    }

    @MainActor func testIntegerFieldEditsClampsAndSharesValueWithStepper() async throws {
        var value = 10
        let fixture = mount(NativeIntegerField(value: Binding(get: { value }, set: { value = $0 }),
                                               range: 1...30, label: "合成结果数"))
        defer { fixture.window.makeFirstResponder(nil); fixture.window.contentView = nil }
        await settle(fixture.host)
        let control = try XCTUnwrap(descendants(fixture.host, of: NativeIntegerControl.self).first)
        let field = control.field
        XCTAssertEqual(field.accessibilityLabel(), "合成结果数")
        XCTAssertEqual(control.stepper.accessibilityLabel(), "调整合成结果数")
        XCTAssertTrue(field.acceptsFirstResponder)
        XCTAssertEqual(control.stepper.minValue, 1)
        XCTAssertEqual(control.stepper.maxValue, 30)
        field.stringValue = "25"
        field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
        XCTAssertEqual(value, 25)
        field.stringValue = "999"
        field.sendAction(field.action, to: field.target)
        XCTAssertEqual(value, 30)
        XCTAssertEqual(field.stringValue, "30")
        field.stringValue = "invalid"
        field.sendAction(field.action, to: field.target)
        XCTAssertEqual(value, 30)
        XCTAssertEqual(field.stringValue, "30")
        control.stepper.integerValue = 12
        control.stepper.sendAction(control.stepper.action, to: control.stepper.target)
        XCTAssertEqual(value, 12)
        XCTAssertEqual(field.stringValue, "12")
        let fieldRect = control.convert(field.bounds, from: field)
        let stepperRect = control.convert(control.stepper.bounds, from: control.stepper)
        XCTAssertLessThanOrEqual(fieldRect.maxX + 3, stepperRect.minX)
        XCTAssertLessThanOrEqual(stepperRect.maxX, control.bounds.maxX + 1)
    }

    @MainActor func testNativeControlsRespectDisabledEnvironment() async throws {
        let content = VStack {
            NativeSearchField(text: .constant("Synthetic"), label: "禁用搜索", onSearch: {})
            NativeFormatPicker(selection: .constant("mp3"), label: "禁用格式")
            NativeIntegerField(value: .constant(90), range: 15...180, step: 5, label: "禁用超时")
            NativeSourceCheckbox(isOn: .constant(true), label: "禁用音源")
            NativeFormButton(title: "禁用操作", action: {})
            NativeReadOnlyField(text: "/tmp/Synthetic music", label: "禁用位置")
        }.disabled(true)
        let fixture = mount(content)
        defer { fixture.window.makeFirstResponder(nil); fixture.window.contentView = nil }
        await settle(fixture.host)
        let controls = descendants(fixture.host, of: NSControl.self)
        XCTAssertTrue(controls.contains { $0 is NSSearchField })
        XCTAssertTrue(controls.contains { $0 is NSPopUpButton })
        XCTAssertTrue(controls.contains { $0 is NSStepper })
        let interactive = controls.filter { $0 is NSButton || $0 is NSTextField || $0 is NSStepper }
        XCTAssertTrue(interactive.allSatisfy { !$0.isEnabled })
    }

    @MainActor func testTableHeaderUsesNativeMixedStateCheckbox() async throws {
        var toggles = 0
        let fixture = mount(NativeTriStateCheckbox(state: .mixed, label: "全选合成结果", action: { toggles += 1 }))
        defer { fixture.window.makeFirstResponder(nil); fixture.window.contentView = nil }
        await settle(fixture.host)
        let checkbox = try XCTUnwrap(descendants(fixture.host, of: NSButton.self).first)
        XCTAssertTrue(checkbox.allowsMixedState)
        XCTAssertEqual(checkbox.state, .mixed)
        XCTAssertEqual(checkbox.accessibilityLabel(), "全选合成结果")
        checkbox.performClick(nil)
        XCTAssertEqual(toggles, 1)
    }

    @MainActor func testSearchFieldAcceptsKeyboardFocusAndReturnCommitsOnce() async throws {
        var text = ""
        var submissions = 0
        let fixture = mount(NativeSearchField(text: Binding(get: { text }, set: { text = $0 }),
                                              label: "键盘合成搜索", onSearch: { submissions += 1 }))
        defer { fixture.window.makeFirstResponder(nil); fixture.window.contentView = nil }
        await settle(fixture.host)
        let field = try XCTUnwrap(descendants(fixture.host, of: NSSearchField.self).first)
        XCTAssertTrue(fixture.window.makeFirstResponder(field))
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        editor.insertText("Keyboard piano", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(text, "Keyboard piano")
        XCTAssertEqual(submissions, 0)
        editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        XCTAssertEqual(submissions, 1)
        XCTAssertEqual(text, "Keyboard piano")
    }

    @MainActor func testSourceCheckboxesShowOnlySupportedSourcesAndUpdateSelection() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("chengwen-native-control-" + UUID().uuidString)
        let model = AppModel(storeURL: root)
        let fixture = mount(NativeSourcePicker(availableWidth: 460).environmentObject(model))
        defer {
            fixture.window.makeFirstResponder(nil)
            fixture.window.contentView = nil
            model.shutdown()
            try? FileManager.default.removeItem(at: root)
        }
        await settle(fixture.host)
        let checkboxes = descendants(fixture.host, of: NSButton.self)
        XCTAssertEqual(checkboxes.count, MusicSource.available.count)
        XCTAssertEqual(checkboxes.count, 6, "All six supported sources must be visible without a menu")
        let first = try XCTUnwrap(checkboxes.first)
        XCTAssertTrue(model.settings.sources.contains("netease"))
        first.performClick(nil)
        await settle(fixture.host)
        XCTAssertFalse(model.settings.sources.contains("netease"))
        XCTAssertTrue(model.settings.sources.contains("kuwo"))
    }

    @MainActor func testSixSourcesUseTwoAlignedRowsAtBothWindowWidths() async throws {
        for width:CGFloat in [376,462] {
            let root=FileManager.default.temporaryDirectory.appendingPathComponent("chengwen-source-grid-"+UUID().uuidString)
            let model=AppModel(storeURL:root)
            let fixture=mount(NativeSourcePicker(availableWidth:width).environmentObject(model).frame(width:width))
            defer {
                fixture.window.contentView=nil
                model.shutdown();try? FileManager.default.removeItem(at:root)
            }
            fixture.window.setContentSize(NSSize(width:width,height:80))
            await settle(fixture.host)
            let buttons=descendants(fixture.host,of:NSButton.self)
            XCTAssertEqual(buttons.count,6)
            XCTAssertEqual(Set(buttons.map(\.title)),Set(MusicSource.available.map(\.name)))
            let frames=buttons.map{$0.convert($0.bounds,to:fixture.host)}
            let rows=Dictionary(grouping:frames,by:{Int(($0.midY*2).rounded())})
            XCTAssertEqual(rows.count,2)
            XCTAssertTrue(rows.values.allSatisfy{$0.count==3})
            let columnStarts=Set(frames.map{Int(($0.minX*2).rounded())})
            XCTAssertEqual(columnStarts.count,3)
            for (button,frame) in zip(buttons,frames) {
                XCTAssertGreaterThanOrEqual(frame.minX,-0.5)
                XCTAssertLessThanOrEqual(frame.maxX,width+0.5)
                XCTAssertGreaterThanOrEqual(button.bounds.width,button.intrinsicContentSize.width-0.5,"Source labels must not truncate")
            }
            let extra=try XCTUnwrap(MusicSource.available.first{!["netease","kuwo"].contains($0.id)})
            let checkbox=try XCTUnwrap(buttons.first{$0.title==extra.name})
            let initial=model.settings.sources.contains(extra.id)
            checkbox.performClick(nil);await settle(fixture.host)
            XCTAssertEqual(model.settings.sources.contains(extra.id),!initial)
            checkbox.performClick(nil);await settle(fixture.host)
            XCTAssertEqual(model.settings.sources.contains(extra.id),initial)
        }
    }

    func testSampleReadPresentationNeverClaimsWholeTrackVerification() {
        for state in ["passed","available","ready"] {
            let presentation=LibraryProbePresentation(ProbeStatus(state:state))
            XCTAssertEqual(presentation.title,"可试读")
            XCTAssertEqual(presentation.color,Color(nsColor:.systemBlue))
            XCTAssertFalse(presentation.isProblem)
            XCTAssertTrue(presentation.tooltip.contains("不代表整首"))
        }
        XCTAssertEqual(LibraryProbePresentation(nil).title,"未测试")
        let anonymous=LibraryProbePresentation(ProbeStatus(state:"verified",anonymous:true))
        XCTAssertEqual(anonymous.title,"整首已验证")
        XCTAssertEqual(anonymous.color,LibraryTheme.success)
        XCTAssertTrue(anonymous.tooltip.contains("未登录状态"))
        let loggedIn=LibraryProbePresentation(ProbeStatus(state:"verified",anonymous:false))
        XCTAssertEqual(loggedIn.title,"整首已验证")
        XCTAssertTrue(loggedIn.tooltip.contains("不代表匿名可下载"))
        let completed=LibraryProbePresentation(ProbeStatus(state:"completed",anonymous:true))
        XCTAssertNotEqual(completed.title,"整首已验证")
        XCTAssertNotEqual(completed.color,LibraryTheme.success)
        XCTAssertTrue(completed.tooltip.contains("操作完成不等于"))
        XCTAssertTrue(LibraryProbePresentation(ProbeStatus(state:"verified")).tooltip.contains("登录状态未记录"))
    }

    @MainActor func testSearchFieldAndButtonShareNativeMetricsAndClickAction() async throws {
        let search = expectation(description: "Search button starts exactly one synthetic search")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("chengwen-search-metrics-" + UUID().uuidString)
        let model = AppModel(storeURL: root, engine: BackendClient { operation, _, _ in
            XCTAssertEqual(operation, "search")
            search.fulfill()
            return [:]
        })
        model.keyword = "Synthetic"
        model.settings.sources = ["netease"]
        let fixture = mount(NativeRootView().environmentObject(model))
        fixture.window.setContentSize(NSSize(width: 1080, height: 700))
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        defer { fixture.window.makeFirstResponder(nil); fixture.window.contentView = nil }
        await settle(fixture.host)
        let field = try XCTUnwrap(descendants(fixture.host, of: NSSearchField.self).first)
        let button = try XCTUnwrap(descendants(fixture.host, of: ReferenceActionButton.self).first { $0.accessibilityIdentifier() == "music-search-action" })
        XCTAssertEqual(field.controlSize, .large)
        let fieldBounds = field.convert(field.bounds, to: fixture.host)
        let buttonBounds = button.convert(button.bounds, to: fixture.host)
        XCTAssertEqual(fieldBounds.height, buttonBounds.height, accuracy: 0.5)
        XCTAssertEqual(fieldBounds.midY, buttonBounds.midY, accuracy: 0.5)
        XCTAssertEqual(field.intrinsicContentSize.height, button.intrinsicContentSize.height, accuracy: 0.5)
        button.performClick(nil)
        await fulfillment(of: [search], timeout: 3)
    }

    @MainActor func testSavedPathIsSelectableReadOnlyAndAccessible() async throws {
        let path = "/tmp/Synthetic Music/专辑/Downloads"
        let fixture = mount(NativeReadOnlyField(text: path, label: "合成保存位置").frame(width: 220, height: 28))
        defer { fixture.window.makeFirstResponder(nil); fixture.window.contentView = nil }
        await settle(fixture.host)
        let field = try XCTUnwrap(descendants(fixture.host, of: NSTextField.self).first)
        XCTAssertFalse(field.isEditable)
        XCTAssertTrue(field.isSelectable)
        XCTAssertEqual(field.stringValue, path)
        XCTAssertEqual(field.toolTip, path)
        XCTAssertEqual(field.accessibilityLabel(), "合成保存位置")
    }

    @MainActor func testToastDoesNotMoveSearchOrFormatControls() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("chengwen-toast-layout-" + UUID().uuidString)
        let model = AppModel(storeURL: root)
        let fixture = mount(NativeRootView().environmentObject(model))
        fixture.window.setContentSize(NSSize(width: 1080, height: 740))
        defer {
            fixture.window.makeFirstResponder(nil); fixture.window.contentView = nil
            model.shutdown(); try? FileManager.default.removeItem(at: root)
        }
        await settle(fixture.host)
        let search = try XCTUnwrap(descendants(fixture.host, of: NSSearchField.self).first)
        let format = try XCTUnwrap(descendants(fixture.host, of: NSPopUpButton.self).first)
        let searchFrame = search.convert(search.bounds, to: nil)
        let formatFrame = format.convert(format.bounds, to: nil)
        for notice in ["已保存。", String(repeating: "这是较长的合成下载提示，用来检查浮层不会推动搜索和表格布局。", count: 4), ""] {
            model.notice = notice
            await settle(fixture.host)
            try? await Task.sleep(nanoseconds: 250_000_000)
            fixture.host.layoutSubtreeIfNeeded()
            XCTAssertEqual(search.convert(search.bounds, to: nil), searchFrame)
            XCTAssertEqual(format.convert(format.bounds, to: nil), formatFrame)
        }
    }

    @MainActor func testEnvironmentSheetKeepsHeaderAndFooterVisibleWhileScrolling() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("chengwen-environment-layout-" + UUID().uuidString)
        let model = AppModel(storeURL: root)
        model.healthItems = [
            EnvironmentItem(["key":"engine", "title":"合成音乐引擎", "state":"ready", "required":true]),
            EnvironmentItem(["key":"ffmpeg", "title":"FFmpeg", "state":"missing", "detail":String(repeating:"合成工具缺失说明。", count:20), "required":true]),
            EnvironmentItem(["key":"ffprobe", "title":"FFprobe", "state":"missing", "detail":String(repeating:"合成工具缺失说明。", count:20), "required":true]),
        ]
        let fixture = mount(NativeEnvironmentSheet().environmentObject(model))
        fixture.window.setContentSize(NSSize(width:650,height:610))
        fixture.window.appearance = NSAppearance(named:.aqua)
        defer {
            fixture.window.makeFirstResponder(nil); fixture.window.contentView=nil
            model.shutdown(); try? FileManager.default.removeItem(at:root)
        }
        await settle(fixture.host)
        let scroll = try XCTUnwrap(descendants(fixture.host, of:NSScrollView.self).first)
        let viewportFrame = scroll.convert(scroll.bounds,to:nil)
        let actualViewport=scroll.convert(scroll.bounds,to:fixture.host)
        let before=NSRect(x:0,y:0,width:fixture.host.bounds.width,height:actualViewport.minY)
        let after=NSRect(x:0,y:actualViewport.maxY,width:fixture.host.bounds.width,height:fixture.host.bounds.maxY-actualViewport.maxY)
        let headerRect=fixture.host.isFlipped ? before:after
        let footerRect=fixture.host.isFlipped ? after:before
        XCTAssertGreaterThan(headerRect.height,20)
        XCTAssertGreaterThan(footerRect.height,20)
        let headerPixels = try snapshot(fixture.host, in:headerRect)
        let footerPixels = try snapshot(fixture.host, in:footerRect)
        let document = try XCTUnwrap(scroll.documentView)
        XCTAssertGreaterThan(document.bounds.height, scroll.contentView.bounds.height)
        for y in [max(0,document.bounds.height-scroll.contentView.bounds.height),0] {
            scroll.contentView.scroll(to:NSPoint(x:0,y:y));scroll.reflectScrolledClipView(scroll.contentView)
            await settle(fixture.host)
            XCTAssertEqual(scroll.convert(scroll.bounds,to:nil),viewportFrame)
            XCTAssertEqual(try snapshot(fixture.host,in:headerRect),headerPixels,"Scrolling must not paint over the fixed title and introduction")
            XCTAssertEqual(try snapshot(fixture.host,in:footerRect),footerPixels,"Scrolling must not paint over the fixed footer buttons")
        }
    }

    @MainActor private func snapshot(_ view:NSView,in rect:NSRect)throws->Data {
        let bitmap=try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in:rect))
        view.cacheDisplay(in:rect,to:bitmap)
        return try XCTUnwrap(bitmap.representation(using:.png,properties:[:]))
    }

    @MainActor private func mount<V: View>(_ view: V) -> (window: NSWindow, host: NSHostingView<V>) {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 250, height: 110),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: view)
        window.contentView = host
        return (window, host)
    }
    @MainActor private func settle(_ view: NSView) async {
        view.layoutSubtreeIfNeeded()
        try? await Task.sleep(nanoseconds: 30_000_000)
        view.layoutSubtreeIfNeeded()
    }
    @MainActor private func descendants<T: NSView>(_ view: NSView, of type: T.Type) -> [T] {
        ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { descendants($0, of: type) }
    }
}
