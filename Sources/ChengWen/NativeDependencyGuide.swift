import AppKit
import SwiftUI

/// Installation is an explicit user action. These controls copy commands or
/// open documentation; the app never runs a package manager on the user's behalf.
@MainActor
struct NativeDependencyGuide: View {
    private enum Method: String, CaseIterable {
        case homebrew = "Homebrew", macports = "MacPorts / Monterey", manual = "手动安装"
    }
    @State private var method: Method = defaultMethod
    @State private var copied = false
    @State private var folderError = ""
    private let toolFolder = AppFiles.root().appendingPathComponent("bin", isDirectory: true)

    init() {
        let arguments = CommandLine.arguments
        if arguments.contains("--ui-preview"), let index = arguments.firstIndex(of: "--installation-method"), arguments.count > index + 1 {
            let method: Method
            switch arguments[index + 1] {
            case "macports": method = .macports
            case "manual": method = .manual
            default: method = .homebrew
            }
            _method = State(initialValue: method)
        }
    }

    private static var defaultMethod: Method {
        #if arch(x86_64)
        return .macports
        #else
        return ProcessInfo.processInfo.operatingSystemVersion.majorVersion <= 14 ? .macports : .homebrew
        #endif
    }

    var body: some View {
        NativeSettingsGroup("安装音频工具") {
            VStack(alignment: .leading, spacing: 12) {
                Text("需安装 FFmpeg（转换与完整解码）和 FFprobe（读取音频信息）。原始格式下载也需要两个工具；已就绪时无需重复安装。")
                    .font(.system(size: 12)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Text("安装方式：").font(.system(size: 13))
                    NativeInstallationMethodPicker(selection: Binding(get: {
                        Method.allCases.firstIndex(of: method) ?? 0
                    }, set: { index in
                        method = Method.allCases[min(max(0, index), Method.allCases.count - 1)]
                        copied = false; folderError = ""
                    }), titles: Method.allCases.map(\.rawValue))
                        .frame(width: 225, height: 28)
                    Spacer(minLength: 0)
                }
                instructions
                Text("安装后点击「重新检查」。两个工具应来自同一发行版，并放在同一文件夹。")
                    .font(.system(size: 12)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            }.padding(5)
        }
    }

    @ViewBuilder private var instructions: some View {
        switch method {
        case .homebrew:
            command("brew install ffmpeg")
            steps("1. 已安装 Homebrew：打开「终端」，粘贴并运行上面的命令。", "2. 此命令同时安装 FFmpeg 和 FFprobe。没有 Homebrew 时，可先查看官网安装步骤。")
            documentation("Homebrew 安装说明", "https://brew.sh/")
            Text("Monterey、较旧的 macOS 及 Intel Mac 不在 Homebrew 的完整支持范围内，建议改用 MacPorts 或兼容系统的手动安装包。")
                .font(.system(size: 12)).foregroundColor(LibraryTheme.muted).fixedSize(horizontal: false, vertical: true)
        case .macports:
            command("sudo port install ffmpeg")
            steps("1. 在 MacPorts 官网选择与你的 macOS 版本相符的安装器；Monterey 请选择 macOS 12。按官网要求准备开发工具。", "2. 安装 MacPorts 后，打开「终端」，运行上面的命令。终端可能要求输入本机管理员密码。")
            documentation("MacPorts 安装说明", "https://www.macports.org/install.php")
        case .manual:
            steps("1. 从 FFmpeg 官网的 macOS 下载入口选择构建，核对芯片（Apple 芯片 / Intel）及最低 macOS 版本；Monterey 需明确支持 macOS 12。", "2. 分别解压 ffmpeg 和 ffprobe，将两个可执行文件放入下方工具文件夹。请放入程序文件本身，不能只放压缩包或外层文件夹。")
            HStack(spacing: 10) {
                documentation("FFmpeg 下载入口", "https://ffmpeg.org/download.html")
                Button("打开工具文件夹…", action: openToolFolder)
                    .buttonStyle(.bordered).controlSize(.small)
            }
            Text(AppFiles.root().appendingPathComponent("bin", isDirectory: true).path)
                .font(.system(size: 12, design: .monospaced)).foregroundColor(LibraryTheme.muted)
                .textSelection(.enabled)
            Text("工具无法启动时，先按 macOS 的提示核实开发者与系统兼容性；也可改用上面的包管理器安装。")
                .font(.system(size: 12)).foregroundColor(LibraryTheme.muted).fixedSize(horizontal: false, vertical: true)
            if !folderError.isEmpty {
                Text(folderError).font(.system(size: 12)).foregroundColor(LibraryTheme.failure)
            }
        }
    }

    private func steps(_ first: String, _ second: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(first)
            Text(second)
        }.font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
    }

    private func command(_ value: String) -> some View {
        HStack(spacing: 8) {
            Text(value).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
            Spacer(minLength: 8)
            Button {
                NSPasteboard.general.clearContents()
                copied = NSPasteboard.general.setString(value, forType: .string)
            } label: { LibraryButtonLabel(title: copied ? "已复制" : "复制命令", icon: copied ? "check" : "copy") }
                .buttonStyle(.borderless).controlSize(.small)
        }.padding(.horizontal, 10).padding(.vertical, 6)
            .background(Color(nsColor: .textBackgroundColor)).cornerRadius(4)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(LibraryTheme.border, lineWidth: 0.5))
    }

    private func documentation(_ title: String, _ address: String) -> some View {
        Link(destination: URL(string: address)!) {
            LibraryButtonLabel(title: title, icon: "external-link").font(.system(size: 12))
        }
    }

    private func openToolFolder() {
        do {
            try FileManager.default.createDirectory(at: toolFolder, withIntermediateDirectories: true)
            folderError = NSWorkspace.shared.open(toolFolder) ? "" : "工具文件夹无法打开，请在 Finder 中按上面的路径访问。"
        } catch {
            folderError = "工具文件夹创建失败，请检查当前用户目录的写入权限。"
        }
    }
}

/// Use the same real popup-button interaction as the audio format field:
/// native menu, keyboard type selection, focus ring and system appearance.
private struct NativeInstallationMethodPicker: NSViewRepresentable {
    @Binding var selection: Int
    let titles: [String]
    @Environment(\.isEnabled) private var isEnabled
    func makeNSView(context: Context) -> NSPopUpButton {
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.controlSize = .large
        popup.font = .systemFont(ofSize: 13)
        popup.bezelStyle = .rounded
        popup.target = context.coordinator
        popup.action = #selector(Coordinator.selectMethod(_:))
        popup.setAccessibilityLabel("音频工具安装方式")
        popup.setAccessibilityIdentifier("installation-method")
        popup.setContentHuggingPriority(.defaultLow, for: .horizontal)
        popup.addItems(withTitles: titles)
        return popup
    }
    func updateNSView(_ popup: NSPopUpButton, context: Context) {
        context.coordinator.parent = self
        if popup.itemTitles != titles { popup.removeAllItems(); popup.addItems(withTitles: titles) }
        popup.selectItem(at: selection)
        popup.isEnabled = isEnabled
    }
    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }
    final class Coordinator: NSObject {
        var parent: NativeInstallationMethodPicker
        init(parent: NativeInstallationMethodPicker) { self.parent = parent }
        @objc func selectMethod(_ sender: NSPopUpButton) { parent.selection = sender.indexOfSelectedItem }
    }
}
