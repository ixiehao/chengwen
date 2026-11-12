import AppKit
import SwiftUI

/// Shared by search and downloads so floating-header layout and hit testing
/// retain the same document padding. Moving NSClipView's frame alone makes
/// AppKit reject otherwise visible controls in the first row.
class NativeTableScrollView: NSScrollView {
    var headerOverlap: CGFloat {
        guard let header = (documentView as? NSTableView)?.headerView?.superview,
              header.superview === self else { return 0 }
        let overlap = contentView.frame.intersection(header.frame)
        return overlap.isNull ? 0 : overlap.height
    }
    override func tile() {
        let atTop = abs(contentView.bounds.minY + headerOverlap) < 0.5
        super.tile()
        if atTop {
            contentView.scroll(to: NSPoint(x: contentView.bounds.minX, y: -headerOverlap))
        }
        synchroniseHeaderPosition()
    }

    override func reflectScrolledClipView(_ clipView: NSClipView) {
        super.reflectScrolledClipView(clipView)
        if clipView === contentView { synchroniseHeaderPosition() }
    }

    private func synchroniseHeaderPosition() {
        guard let header = (documentView as? NSTableView)?.headerView?.superview as? NSClipView,
              header.superview === self, abs(header.bounds.minX - contentView.bounds.minX) > 0.5 else { return }
        // AppKit can retain a stale header offset after horizontal scrolling
        // back or narrowing columns, leaving visible headers unclickable.
        header.scroll(to: NSPoint(x: contentView.bounds.minX, y: header.bounds.minY))
    }
}

struct NativeTriStateCheckbox: NSViewRepresentable {
    let state: NSControl.StateValue
    let label: String
    let action: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(action: action) }
    func makeNSView(context: Context) -> NSButton {
        let button = Self.makeButton(target: context.coordinator, action: #selector(Coordinator.toggle))
        button.setAccessibilityLabel(label)
        return button
    }
    @MainActor static func makeButton(target: AnyObject?, action: Selector?) -> NSButton {
        let button = ReferenceCheckboxButton(checkboxWithTitle: "", target: target, action: action)
        button.allowsMixedState = true
        button.controlSize = .small
        return button
    }
    func updateNSView(_ button: NSButton, context: Context) {
        button.state = state
        button.isEnabled = context.environment.isEnabled
        button.setAccessibilityLabel(label)
        context.coordinator.action = action
    }
    final class Coordinator: NSObject {
        var action: () -> Void
        init(action: @escaping () -> Void) { self.action = action }
        @objc func toggle() { action() }
    }
}

struct LibraryProbePresentation {
    let title: String
    let icon: String
    let color: Color
    let isProblem: Bool
    let tooltip: String
    init(_ probe: ProbeStatus?) {
        let state = probe?.state ?? "untested"
        switch state {
        case "verified":
            title = "整首已验证"; icon = "circle-check"; color = LibraryTheme.success; isProblem = false
        case "passed", "available", "ready":
            title = "可试读"; icon = "headphones"; color = Color(nsColor: .systemBlue); isProblem = false
        case "failed", "unavailable", "blocked":
            title = "试读失败"; icon = "alert-circle"; color = LibraryTheme.failure; isProblem = true
        case "authentication", "verification", "needs_authentication", "auth":
            title = "需验证"; icon = "info-circle"; color = LibraryTheme.warning; isProblem = true
        case "testing", "checking", "running":
            title = "测试中"; icon = "activity"; color = LibraryTheme.accent; isProblem = false
        case "queued":
            title = "等待测试"; icon = "clock"; color = LibraryTheme.accent; isProblem = false
        default:
            title = "未测试"; icon = "clock"; color = LibraryTheme.muted; isProblem = false
        }
        let explanation: String
        if state == "verified" {
            if probe?.anonymous == true {
                explanation = "此版本已在未登录状态下完成整首下载和完整性校验。"
            } else if probe?.anonymous == false {
                explanation = "此版本已使用已连接账号完成整首下载和完整性校验；不代表匿名可下载。"
            } else {
                explanation = "此版本已完成整首下载和完整性校验；登录状态未记录，不能据此判断匿名下载能力。"
            }
        } else if ["passed", "available", "ready"].contains(state) {
            explanation = "少量音频试读成功，不代表整首可下载或已通过完整性校验。"
        } else if state == "completed" {
            explanation = "尚未记录整首完整性验证；操作完成不等于整首校验完成。"
        } else if probe == nil {
            explanation = "可直接下载，预下载测试为可选步骤。测试只读取少量音频，整首验证以实际下载结果为准。"
        } else { explanation = "" }
        let solution = probe?.solution ?? ""
        tooltip = [explanation, probe?.detail ?? "", solution.isEmpty ? "" : "解决办法：\(solution)"]
            .filter { !$0.isEmpty }.joined(separator: "\n")
    }
}

/// Public SwiftUI boundary; AppKit owns the library's columns and selection.
@MainActor
struct NativeAudioTable: View {
    @EnvironmentObject private var model: AppModel
    @Binding var focusedTrackID: String?

    var body: some View {
        NativeResultsTable(model: model, focusedTrackID: $focusedTrackID)
            .overlay {
                if model.tracks.isEmpty {
                    NativeEmptyState(icon: "disc", title: model.isSearching ? "正在搜索音乐…" : "搜索喜欢的音乐",
                                     detail: "选择音源，输入歌曲、艺术家或专辑名称。")
                        .padding(.top, 28)
                        .allowsHitTesting(false)
                }
            }
    }
}
