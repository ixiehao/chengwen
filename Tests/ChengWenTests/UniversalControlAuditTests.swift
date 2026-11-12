import AppKit
import SwiftUI
import XCTest
@testable import ChengWen

final class UniversalControlAuditTests: XCTestCase {
    @MainActor func testCheckboxSizeContainsItsPaintedLabelAndBox() {
        for label in ["", "网易云音乐", "千千音乐", "较长的中文测试来源"] {
            let button = ReferenceCheckboxButton(checkboxWithTitle: label, target: nil, action: nil)
            button.controlSize = .small; button.font = .systemFont(ofSize: 12)
            let intrinsic = button.intrinsicContentSize
            button.frame = NSRect(origin: .zero, size: intrinsic)
            let boxWidth = min(18, intrinsic.height - 2)
            let textWidth = (label as NSString).size(withAttributes: [.font: button.font!]).width
            let paintedRight = label.isEmpty ? 1 + boxWidth : 1 + boxWidth + 7 + textWidth
            XCTAssertGreaterThanOrEqual(intrinsic.width + 0.5, paintedRight, "Visible checkbox content must fit its clickable bounds: \(label)")
        }
    }
    @MainActor func testFormActionKeepsItsHitAreaAndLatestClosureAfterRedrawAndDisable() async throws {
        _ = NSApplication.shared
        var actions: [Int] = []
        let window = NSWindow(contentRect: NSRect(x:0,y:0,width:240,height:120), styleMask:[.titled], backing:.buffered, defer:false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: AnyView(NativeFormButton(title:"开始", icon:"download", action:{actions.append(1)}).frame(width:160,height:34)))
        window.contentView = host
        defer {window.makeFirstResponder(nil);window.contentView=nil;window.close()}
        func buttons(_ v:NSView)->[NSButton] {((v as? NSButton).map{[$0]} ?? []) + v.subviews.flatMap(buttons)}
        for state in 0..<20 {
            let enabled = state % 3 != 0
            host.rootView = AnyView(NativeFormButton(title:state.isMultiple(of:2) ? "开始下载":"停止", icon:state.isMultiple(of:2) ? "download":"x", action:{actions.append(state)}).frame(width:160,height:34).disabled(!enabled))
            host.layoutSubtreeIfNeeded();try await Task.sleep(nanoseconds:5_000_000);host.layoutSubtreeIfNeeded()
            let button = try XCTUnwrap(buttons(host).first)
            XCTAssertEqual(button.isEnabled, enabled)
            let before = actions.count
            for fraction:CGFloat in [0.1,0.5,0.9] {
                let local = NSPoint(x:button.bounds.width*fraction,y:button.bounds.midY)
                let windowPoint = button.convert(local,to:nil)
                let hit = host.hitTest(host.superview?.convert(windowPoint,from:nil) ?? windowPoint)
                if enabled { XCTAssertTrue(hit === button || hit?.isDescendant(of:button) == true) }
            }
            button.performClick(nil)
            XCTAssertEqual(actions.count, before + (enabled ? 1:0))
            if enabled {XCTAssertEqual(actions.last,state)}
        }
    }
}
