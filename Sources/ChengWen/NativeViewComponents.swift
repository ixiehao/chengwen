import AppKit
import SwiftUI

struct NativeSidebarMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .withinWindow
        view.state = .followsWindowActiveState
        return view
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

/// Shared card chrome; controls inside remain system-native and accessible.
struct NativeSettingsGroup<Content: View>: View {
    let title: String
    let help: String
    let content: Content
    init(_ title: String, help: String = "", @ViewBuilder content: () -> Content) {
        self.title = title; self.help = help; self.content = content()
    }
    private var icon: String {
        switch title {
        case "下载与保存": return "download"
        case "搜索与任务": return "search"
        case "访问方式": return "download"
        case "音乐账号": return "user"
        case "工具状态": return "activity"
        case "安装音频工具": return "adjustments-horizontal"
        default: return "info-circle"
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    TablerIcon(name: icon, size: 22).foregroundColor(LibraryTheme.ink)
                    Text(title).font(.system(size: 20, weight: .semibold))
                }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 18).padding(.vertical, 9)
                    .background(LibraryTheme.accent.opacity(0.10))
                content.frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 18).padding(.vertical, 12)
            }
            .background(LibraryTheme.surface, in: RoundedRectangle(cornerRadius: 9))
            .clipShape(RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(LibraryTheme.border.opacity(0.55), lineWidth: 0.5))
            if !help.isEmpty {
                Text(help).font(.system(size: 13)).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 10)
            }
        }
    }
}

struct NativeSettingsRow<Content: View>: View {
    let title: String
    let content: Content
    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title; self.content = content()
    }
    var body: some View {
        HStack(spacing: 12) {
            Text(title).frame(width: 150, alignment: .leading)
            content
        }.font(.system(size: 15)).frame(minHeight: 36).padding(.vertical, 5)
    }
}
