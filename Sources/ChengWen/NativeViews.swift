import AppKit
import SwiftUI

// The views only consume AppModel; engine and account operations
// remain in the model so rendering never reads account files or starts work.
enum LibraryTheme {
    static let background = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor.windowBackgroundColor : NSColor(srgbRed: 0.988, green: 0.969, blue: 0.984, alpha: 1)
    })
    static let ink = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? .labelColor : NSColor(srgbRed: 0.055, green: 0.05, blue: 0.12, alpha: 1)
    })
    static let muted = Color(nsColor: .secondaryLabelColor)
    static let accent = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.72, green: 0.64, blue: 1, alpha: 1)
            : NSColor(srgbRed: 0.34, green: 0.15, blue: 0.88, alpha: 1)
    })
    static let border = Color(nsColor: .separatorColor)
    static let success = Color(nsColor: .systemGreen)
    static let warning = Color(nsColor: .systemOrange)
    static let failure = Color(nsColor: .systemRed)
    static let primaryFill = LinearGradient(colors: [Color(red: 0.32, green: 0.14, blue: 0.84), Color(red: 0.34, green: 0.09, blue: 0.98)], startPoint: .topLeading, endPoint: .bottomTrailing)
    static let surface = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? .controlBackgroundColor : NSColor(srgbRed: 0.990, green: 0.978, blue: 0.992, alpha: 1)
    })
    static let sidebar = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.16, green: 0.14, blue: 0.20, alpha: 1)
            : NSColor(srgbRed: 0.945, green: 0.918, blue: 0.979, alpha: 1)
    })
}

struct LibraryButtonLabel: View {
    let title: String
    let icon: String
    var body: some View {
        HStack(spacing: 6) {
            TablerIcon(name: icon, size: 16)
            Text(title).lineLimit(1)
        }
    }
}

@MainActor
struct NativeRootView: View {
    @EnvironmentObject private var model: AppModel
    @State private var preferencesTab = NativePreferencesTab.general

    init() {
        let arguments = CommandLine.arguments
        if arguments.contains("--ui-preview"), let index = arguments.firstIndex(of: "--preferences-tab"), arguments.count > index + 1 {
            switch arguments[index + 1] {
            case "accounts": _preferencesTab = State(initialValue: .accounts)
            case "environment": _preferencesTab = State(initialValue: .environment)
            default: break
            }
        }
    }
    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 195)
            Divider()
            VStack(alignment: .leading, spacing: 18) {
                pageHeader
                currentPage.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding(.horizontal, 24).padding(.top, 28).padding(.bottom, 20)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(LibraryTheme.background)
            .overlay(alignment: .topTrailing) {
                if !model.notice.isEmpty {
                    notice.padding(.top, 68).padding(.trailing, 22)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .animation(.easeInOut(duration: 0.18), value: model.notice.isEmpty)
        }
        .font(.system(size: 15)).foregroundColor(LibraryTheme.ink).accentColor(LibraryTheme.accent)
        .frame(minWidth: 1080, minHeight: 708).background(LibraryTheme.background)
        .ignoresSafeArea(.container, edges: .top)
        .sheet(isPresented: $model.showEnvironment) { NativeEnvironmentSheet().environmentObject(model) }
    }
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear.frame(height: 54)
            HStack(spacing: 10) {
                BrandLogoView().frame(width: 48, height: 48)
                VStack(alignment: .leading, spacing: 2) {
                    Text("澄闻").font(.system(size: 23, weight: .bold))
                    Text("音乐下载与收藏").font(.system(size: 13)).foregroundColor(.secondary)
                }
            }.help("把喜欢的声音，留给自己。").padding(.horizontal, 16).padding(.bottom, 32)
            VStack(spacing: 4) {
                navigation(.search, title: "搜索音乐", icon: "search")
                navigation(.downloads, title: "下载管理", icon: "download", count: model.activeJobCount)
                Button(action: model.openDirectory) {
                    Label { Text("下载文件夹") } icon: { TablerIcon(name: "folder-open", size: 18) }
                        .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading).padding(.horizontal, 14)
                        .contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityIdentifier("open-download-folder")
                navigation(.preferences, title: "偏好设置", icon: "settings")
            }.font(.system(size: 17)).padding(.horizontal, 11)
            Spacer(minLength: 0)
        }.background(LibraryTheme.sidebar
            .overlay(ZStack {
                SidebarWaves().fill(LibraryTheme.accent.opacity(0.055))
                SidebarWaves(secondary: true).fill(LibraryTheme.accent.opacity(0.045))
            }.allowsHitTesting(false)))
    }
    private func navigation(_ page: AppPage, title: String, icon: String, count: Int = 0) -> some View {
        Button { model.page = page } label: {
            HStack(spacing: 8) {
                Label { Text(title) } icon: { TablerIcon(name: icon, size: 18) }
                Spacer(minLength: 0)
                if count > 0 { Text(String(count)).font(.system(size: 11)).monospacedDigit() }
            }.foregroundColor(model.page == page ? LibraryTheme.accent : LibraryTheme.ink)
                .frame(maxWidth: .infinity, minHeight: 38, alignment: .leading).padding(.horizontal, 14)
                .background(model.page == page ? LibraryTheme.accent.opacity(0.13) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 8))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel(title)
            .accessibilityAddTraits(model.page == page ? .isSelected : [])
            .accessibilityIdentifier("navigation-\(page.rawValue)")
    }
    private var pageHeader: some View {
        HStack {
            TablerIcon(name: model.page == .search ? "search" : model.page == .downloads ? "download" : "settings", size: 27)
            Text(model.page == .search ? "搜索你想找的音乐" : model.page == .downloads ? "下载管理" : "偏好设置")
                .font(.system(size: 27, weight: .bold))
            Spacer()
            Button {
                model.showEnvironment = true
                if model.healthItems.isEmpty { model.checkEnvironment() }
            } label: {
                HStack(spacing: 6) {
                    if model.isCheckingEnvironment { ProgressView().controlSize(.small).frame(width: 14, height: 14) }
                    else { TablerIcon(name: "activity", size: 15) }
                    Text("运行环境测试")
                }
            }.buttonStyle(ReferenceButtonStyle()).help("检查下载与音频转换工具")
                .accessibilityIdentifier("environment-entry")
        }.frame(height: 32)
    }
    private var notice: some View {
        HStack(alignment: .top, spacing: 9) {
            TablerIcon(name: "info-circle", size: 16).foregroundColor(.accentColor).padding(.top, 1)
            Text(model.notice).font(.system(size: 12)).lineLimit(3)
                .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
                .help(model.notice).accessibilityLabel(model.notice)
            Button { model.notice = "" } label: { TablerIcon(name: "x", size: 13).frame(width: 20, height: 20) }
                .buttonStyle(.borderless).help("关闭提示").accessibilityLabel("关闭提示")
                .accessibilityIdentifier("notice-dismiss")
        }.padding(12).frame(width: 320)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(LibraryTheme.border, lineWidth: 0.5))
            .shadow(color: Color(nsColor: .shadowColor).opacity(0.18), radius: 10, x: 0, y: 4)
            .accessibilityElement(children: .contain).accessibilityIdentifier("transient-notice")
    }
    @ViewBuilder private var currentPage: some View {
        switch model.page {
        case .search: NativeSearchPage()
        case .downloads: NativeDownloadsPage { preferencesTab = .accounts; model.page = .preferences }
        case .preferences: NativePreferencesPage(tab: $preferencesTab)
        }
    }
}

@MainActor
private struct NativeSearchPage: View {
    @EnvironmentObject private var model: AppModel
    @State private var focusedTrackID: String?
    @State private var showSourceStatus = false
    @State private var showProbeDetails = false

    var body: some View {
        GeometryReader { geometry in
            VStack(alignment: .leading, spacing: 10) {
                searchControls(width: max(0, geometry.size.width - 32))
                    .padding(16)
                    .background(LibraryTheme.surface, in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(LibraryTheme.border.opacity(0.55), lineWidth: 0.5))
                downloadBar
                HStack(spacing: 9) {
                    Text("搜索结果").font(.system(size: 15, weight: .semibold))
                    if model.isSearching { ProgressView().controlSize(.small).frame(width: 14, height: 14) }
                    Text(model.searchStatus.isEmpty ? "\(model.tracks.count) 首" : model.searchStatus)
                        .font(.system(size: 12)).foregroundColor(.secondary).lineLimit(1)
                    Spacer(minLength: 4)
                    Button { showSourceStatus.toggle() } label: { LibraryButtonLabel(title: "来源状态", icon: "info-circle") }
                        .buttonStyle(.borderless).controlSize(.small)
                        .popover(isPresented: $showSourceStatus) { NativeSourceStatusList() }
                }.frame(height: 24)
                NativeAudioTable(focusedTrackID: $focusedTrackID)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if let probe = focusedProbe, let track = focusedTrack,
                   LibraryProbePresentation(probe).isProblem { probeExplanation(probe, track: track) }
            }
        }
    }

    private func searchControls(width: CGFloat) -> some View {
        let searchWidth = min(300, max(230, width * 0.28))
        let controlHeight = NativeSearchField.preferredHeight
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 18) {
                HStack(spacing: 8) {
                    NativeSearchField(text: $model.keyword, label: "歌曲、歌手或专辑", onSearch: model.search)
                        .frame(height: controlHeight).disabled(model.isSearching)
                    NativeFormButton(title: model.isSearching ? "停止" : "搜索", primary: !model.isSearching,
                                     identifier: "music-search-action",
                                     controlHeight: controlHeight,
                                     action: model.isSearching ? model.stopSearch : model.search)
                        .frame(width: 68, height: controlHeight)
                        .disabled(!model.isSearching && model.keyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }.frame(width: searchWidth)
                HStack(spacing: 6) {
                    Text("来源").font(.system(size: 12, weight: .medium)).fixedSize()
                    NativeSourcePicker(availableWidth: width - searchWidth - 18 - 30).disabled(model.isSearching)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 8) {
                Text("最近搜索").foregroundColor(.secondary).fixedSize()
                if model.settings.recent.isEmpty {
                    Text("暂无记录").foregroundColor(.secondary)
                } else {
                    Button("清空", action: model.clearRecent).buttonStyle(.borderless)
                        .help("清空最近搜索").fixedSize().accessibilityLabel("清空最近搜索")
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            ForEach(Array(model.settings.recent.prefix(8).enumerated()), id: \.offset) { entry in
                                Button(entry.element) { model.searchRecent(entry.element) }
                                    .buttonStyle(.borderless).lineLimit(1).help(entry.element)
                            }
                        }
                    }
                }
                Spacer(minLength: 8)
                Text("每源最多 \(model.settings.limit) 首 · 试读不等于整首验证")
                    .foregroundColor(.secondary).lineLimit(1).fixedSize()
            }.font(.system(size: 11)).frame(height: 20)
        }.padding(.vertical, 4)
    }
    private var focusedTrack: AudioTrack? {
        if let id = focusedTrackID, let track = model.tracks.first(where: { $0.id == id }) { return track }
        return model.tracks.first { model.selection.contains($0.id) && LibraryProbePresentation(model.probes[$0.id]).isProblem }
    }
    private var focusedProbe: ProbeStatus? { focusedTrack.flatMap { model.probes[$0.id] } }
    private func probeExplanation(_ probe: ProbeStatus, track: AudioTrack) -> some View {
        GroupBox {
            HStack(alignment: .top, spacing: 10) {
                TablerIcon(name: "alert-circle", size: 17).foregroundColor(LibraryTheme.warning).padding(.top, 2)
                VStack(alignment: .leading, spacing: 4) {
                    Text(track.title).fontWeight(.medium).lineLimit(1)
                    Text(probe.detail.isEmpty ? "当前版本尚未通过可用性测试。" : probe.detail)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    if !probe.solution.isEmpty { Text("下一步：\(probe.solution)").lineLimit(2).fixedSize(horizontal: false, vertical: true) }
                    Button("查看完整说明…") { showProbeDetails = true }.buttonStyle(.borderless)
                        .popover(isPresented: $showProbeDetails) {
                            VStack(alignment: .leading, spacing: 10) {
                                Text(track.title).font(.system(size: 14, weight: .semibold))
                                ScrollView {
                                    VStack(alignment: .leading, spacing: 10) {
                                        Text(probe.detail)
                                        if !probe.solution.isEmpty { Text("下一步：\(probe.solution)") }
                                        if !probe.technical.isEmpty { Text(probe.technical).font(.system(size: 11, design: .monospaced)) }
                                    }.frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                                }
                            }.font(.system(size: 12)).padding(18).frame(width: 420, height: 260)
                        }
                }.font(.system(size: 12)).foregroundColor(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .trailing, spacing: 7) {
                    if ["authentication", "verification", "needs_authentication", "auth"].contains(probe.state),
                       NativeSessionStore.platforms.contains(track.source) {
                        Button("登录并连接") { model.connectAccount(track.source) }.buttonStyle(.bordered)
                    }
                    Button { model.switchSource(track) } label: { LibraryButtonLabel(title: "换源搜索", icon: "search") }
                        .buttonStyle(.bordered)
                }.controlSize(.small)
            }.padding(4)
        }
    }
    private var downloadBar: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                TablerIcon(name: "folder", size: 17).foregroundColor(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text("保存到").foregroundColor(.secondary)
                        Button("更改…", action: model.chooseDirectory).buttonStyle(.borderless)
                            .accessibilityLabel("更改音频保存位置")
                    }
                    Text(model.settings.directory).foregroundColor(.secondary).lineLimit(1)
                        .truncationMode(.middle).help(model.settings.directory)
                }.font(.system(size: 11)).frame(maxWidth: .infinity, alignment: .leading)
                Text("格式").font(.system(size: 12)).foregroundColor(.secondary)
                NativeFormatPicker(selection: $model.settings.format, label: "下载音频格式", controlSize: .large)
                    .frame(width: 108, height: 34)
                NativeFormButton(title: model.isProbing ? "正在测试…" : "预下载测试", icon: "activity", controlHeight: 34, action: model.probeSelected)
                    .frame(width: 130, height: 34).disabled(model.selectedCount == 0 || model.isProbing)
                    .help("可选步骤：试读少量音频；无需先测试，可直接下载，完成后会校验整首。")
                NativeFormButton(title: downloadTitle, icon: "download", primary: true, identifier: "download-selected", controlHeight: 34, action: model.downloadSelected)
                    .frame(width: 140, height: 34).disabled(model.selectedCount == 0)
            }.frame(minHeight: 32)
        }
    }
    private var downloadTitle: String { model.selectedCount > 0 ? "下载所选 (\(model.selectedCount))" : "下载所选" }
}

@MainActor
struct NativeSourceStatusList: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("来源状态").font(.system(size: 15, weight: .semibold))
            Text("以下仅统计当前结果。搜索成功、可试读与整首验证分别显示。")
                .font(.system(size: 12)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            Text(model.settings.useConnectedAccounts ? "访问方式：网易云、酷我可使用已连接账号；其余免登录。" : "访问方式：全部音源免登录，不使用已连接账号。")
                .font(.system(size: 12)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            Divider()
            ForEach(MusicSource.available) { source in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(source.name).font(.system(size: 12, weight: .medium))
                        Spacer(minLength: 0)
                        Text("搜索：\(model.sourceStates[source.id] ?? "尚未搜索")")
                            .font(.system(size: 11)).foregroundColor(.secondary).multilineTextAlignment(.trailing)
                    }
                    Text(model.sourceValidationSummary(source.id)).font(.system(size: 11)).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if source.id != MusicSource.available.last?.id { Divider() }
            }
        }.padding(18).frame(width: 420)
    }
}

@MainActor
struct NativeSourcePicker: View {
    @EnvironmentObject private var model: AppModel
    var availableWidth: CGFloat = 660
    private var columns: [GridItem] {
        let count = availableWidth >= 510 ? 6 : 3
        let width = max(0, (availableWidth - CGFloat(count - 1) * 4) / CGFloat(count))
        return Array(repeating: GridItem(.fixed(width), spacing: 4, alignment: .leading), count: count)
    }
    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 4) {
            ForEach(MusicSource.available, id: \.id) { source in
                NativeSourceCheckbox(isOn: Binding(get: { model.settings.sources.contains(source.id) }, set: { value in
                    if value != model.settings.sources.contains(source.id) { model.toggleSource(source.id) }
                }), label: source.name).fixedSize().frame(height: 20)
                    .help("\(source.name)\n搜索：\(model.sourceStates[source.id] ?? "尚未搜索")\n\(model.sourceValidationSummary(source.id))")
            }
        }
    }
}

private enum NativeDownloadFilter: String, CaseIterable {
    case all = "全部任务", active = "进行中", completed = "已完成", failed = "失败"
    var identifier: String {
        switch self {
        case .all: return "all"
        case .active: return "active"
        case .completed: return "completed"
        case .failed: return "failed"
        }
    }
}

@MainActor
private struct NativeDownloadsPage: View {
    @EnvironmentObject private var model: AppModel
    let showAccounts: () -> Void
    @State private var filter = NativeDownloadFilter.all
    private var filtered: [DownloadJob] {
        model.jobsNewestFirst.filter { job in
            switch filter {
            case .all: return true
            case .active: return job.active
            case .completed: return job.state == "completed"
            case .failed: return job.state == "failed"
            }
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                HStack(spacing: 2) {
                    ForEach(NativeDownloadFilter.allCases, id: \.self) { option in
                        NativeFormButton(title: "\(option.rawValue) \(count(option))", primary: filter == option,
                                         identifier: "download-filter-\(option.identifier)") { filter = option }
                            .frame(width: 90, height: 34)
                    }
                }.padding(3).background(LibraryTheme.accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
                Spacer(minLength: 0)
                Button("清除已结束记录", action: model.clearFinishedJobs).buttonStyle(.borderless)
                    .help("只清除已结束记录，不会删除下载文件")
                Button(action: model.openDirectory) { LibraryButtonLabel(title: "打开文件夹", icon: "folder-open") }
                    .buttonStyle(ReferenceButtonStyle())
            }.frame(minHeight: 38)
            if filtered.isEmpty {
                NativeEmptyState(icon: "download", title: model.jobs.isEmpty ? "还没有下载任务" : "这个分类还没有任务",
                                 detail: "在搜索结果中选择音乐，再添加到下载队列。")
            } else {
                NativeDownloadsTable(model: model, jobs: filtered, scope: filter.rawValue, showAccounts: showAccounts)
                    .clipShape(RoundedRectangle(cornerRadius: 9))
                    .overlay(RoundedRectangle(cornerRadius: 9).stroke(LibraryTheme.border.opacity(0.5), lineWidth: 0.5))
            }
        }
    }
    private func count(_ filter: NativeDownloadFilter) -> Int {
        switch filter {
        case .all: return model.jobs.count
        case .active: return model.activeJobCount
        case .completed: return model.completedJobCount
        case .failed: return model.jobs.filter { $0.state == "failed" }.count
        }
    }
}

enum NativePreferencesTab: String, CaseIterable { case general = "通用", accounts = "账号与音源", environment = "运行环境" }

@MainActor
struct NativePreferencesPage: View {
    @EnvironmentObject private var model: AppModel
    @Binding var tab: NativePreferencesTab
    var body: some View {
        VStack(alignment: .leading, spacing: 34) {
            HStack(spacing: 2) {
                ForEach(NativePreferencesTab.allCases, id: \.self) { item in
                    Button { tab = item } label: {
                        Text(item.rawValue).font(.system(size: 17, weight: .medium))
                            .foregroundColor(tab == item ? .white : LibraryTheme.ink)
                            .frame(maxWidth: .infinity).frame(height: 36)
                            .background { if tab == item { RoundedRectangle(cornerRadius: 7).fill(LibraryTheme.primaryFill) } }
                            .contentShape(Rectangle())
                    }.buttonStyle(.plain)
                        .accessibilityLabel(item.rawValue)
                        .accessibilityValue(tab == item ? "已选择" : "未选择")
                        .accessibilityIdentifier("preferences-tab-\(item.rawValue)")
                }
            }.padding(3).frame(width: 560)
                .background(LibraryTheme.surface, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(LibraryTheme.border.opacity(0.5), lineWidth: 0.5))
                .accessibilityIdentifier("preferences-tabs")
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    switch tab {
                    case .general: generalSettings
                    case .accounts: accountSettings
                    case .environment: environmentSettings
                    }
                }.padding(.horizontal, 6).padding(.top, 1).padding(.bottom, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }.frame(minHeight: 0, maxHeight: .infinity).clipped()
        }.padding(.top, 34)
    }
    private var generalSettings: some View {
        VStack(alignment: .leading, spacing: 18) {
            NativeSettingsGroup("下载与保存", help: "MP3 320 kbps · M4A 256 kbps；转换为 FLAC 或 WAV 不会提升原始音质。") {
                VStack(spacing: 0) {
                    NativeSettingsRow("保存位置：") {
                        NativeReadOnlyField(text: model.settings.directory, label: "音频保存位置").frame(height: 34)
                        Button("更改…", action: model.chooseDirectory).buttonStyle(ReferenceButtonStyle())
                    }
                    NativeSettingsRow("默认格式：") {
                        NativeFormatPicker(selection: $model.settings.format, label: "默认音频格式", controlSize: .large).frame(width: 170, height: 34)
                        Spacer(minLength: 0)
                    }
                    NativeSettingsRow("歌词：") {
                        Toggle("同时保存可用歌词", isOn: $model.settings.saveLyrics).toggleStyle(ReferenceCheckboxStyle()).font(.system(size: 15))
                        Spacer(minLength: 0)
                    }
                }
            }
            NativeSettingsGroup("搜索与任务") {
                VStack(spacing: 0) {
                    NativeSettingsRow("每源搜索结果：") {
                        NativeIntegerField(value: $model.settings.limit, range: 1...30, label: "每个音源结果数").frame(width: 100, height: 34)
                        Text("首").frame(width: 48, alignment: .leading)
                        Text("1–30 首").font(.system(size: 12)).foregroundColor(.secondary)
                        Spacer(minLength: 0)
                    }
                    NativeSettingsRow("单来源超时：") {
                        NativeIntegerField(value: $model.settings.timeout, range: 15...180, step: 5, label: "单来源超时秒数").frame(width: 100, height: 34)
                        Text("秒").frame(width: 48, alignment: .leading)
                        Text("15–180 秒").font(.system(size: 12)).foregroundColor(.secondary)
                        Spacer(minLength: 0)
                    }
                    NativeSettingsRow("同时下载：") {
                        NativeIntegerField(value: $model.settings.concurrency, range: 1...4, label: "同时下载任务数").frame(width: 100, height: 34)
                        Text("个任务").frame(width: 48, alignment: .leading)
                        Text("1–4 个任务").font(.system(size: 12)).foregroundColor(.secondary)
                        Spacer(minLength: 0)
                    }
                }
            }
        }
    }
    private var accountSettings: some View {
        VStack(alignment: .leading, spacing: 24) {
            NativeSettingsGroup("访问方式") {
                VStack(alignment: .leading, spacing: 7) {
                    Toggle("下载时使用已连接账号", isOn: $model.settings.useConnectedAccounts)
                        .toggleStyle(ReferenceCheckboxStyle()).font(.system(size: 17, weight: .medium))
                    Text("仅网易云与酷我支持账号下载，默认为匿名下载。")
                        .font(.system(size: 15)).foregroundColor(.secondary).padding(.leading, 29)
                }.padding(.vertical, 12).padding(.horizontal, 15)
            }
            NativeSettingsGroup("音乐账号") {
                VStack(spacing: 0) {
                    accountRow(id: "netease", name: "网易云音乐", icon: "music")
                    Divider()
                    accountRow(id: "kuwo", name: "酷我音乐", icon: "headphones")
                }.padding(.horizontal, 15)
            }
            HStack(spacing: 9) {
                TablerIcon(name: "lock", size: 18)
                Text("用户在官方页面登录，会话保存在 macOS 钥匙串。")
                    .fixedSize(horizontal: false, vertical: true)
            }.font(.system(size: 14)).foregroundColor(.secondary)
                .padding(.top, -3).padding(.horizontal, 1)
        }
    }
    private func accountRow(id: String, name: String, icon: String) -> some View {
        let account = model.accounts[id]
        let connected = account?.connected == true
        let verified = account?.verified == true
        let blocked = account?.blocked == true
        let state = blocked ? "需重新连接" : verified ? "连接已验证" : connected ? "待检查" : "未连接"
        let stateColor = blocked ? LibraryTheme.warning : verified ? LibraryTheme.success : LibraryTheme.muted
        return HStack(alignment: .center, spacing: 16) {
            TablerIcon(name: icon, size: 27)
                .foregroundColor(id == "netease" ? .white : Color(red: 0.62, green: 0.27, blue: 0.02))
                .frame(width: 42, height: 42)
                .background(id == "netease" ? Color(red: 0.94, green: 0.12, blue: 0.18) : Color(red: 1, green: 0.83, blue: 0.22),
                            in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 3) {
                Text(name).font(.system(size: 18, weight: .semibold))
                if verified, let nickname = account?.nickname, !nickname.isEmpty {
                    Text(nickname).font(.system(size: 12)).foregroundColor(.secondary).lineLimit(1)
                }
            }.frame(width: 220, alignment: .leading)
            HStack(spacing: 7) {
                Circle().fill(stateColor).frame(width: 7, height: 7)
                Text(state)
            }.font(.system(size: 13, weight: .medium)).foregroundColor(stateColor)
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(stateColor.opacity(0.10), in: Capsule())
                .fixedSize().frame(width: 116, alignment: .leading)
            Spacer(minLength: 0)
            if connected {
                Menu("管理") {
                    Button("检查连接") { model.checkAccount(id) }
                    Button("断开连接") { model.disconnectAccount(id) }
                }.menuStyle(.borderlessButton).frame(width: 52)
                    .accessibilityLabel("管理\(name)账号")
            }
            Button { model.connectAccount(id) } label: {
                Text(connected ? "重新登录" : "登录并连接").frame(width: 110)
            }.buttonStyle(ReferenceButtonStyle())
                .accessibilityIdentifier("account-connect-\(id)")
        }.padding(.vertical, 14)
    }
    private var environmentSettings: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("音乐下载与音频转换工具").font(.system(size: 12)).foregroundColor(.secondary)
                Spacer()
                Button(action: model.checkEnvironment) { LibraryButtonLabel(title: model.isCheckingEnvironment ? "正在检查…" : "重新检查", icon: "refresh") }
                    .buttonStyle(.bordered).controlSize(.small).disabled(model.isCheckingEnvironment)
            }
            NativeEnvironmentContent()
        }
    }
}

@MainActor
struct NativeEnvironmentSheet: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 9) {
                TablerIcon(name: "activity", size: 19).foregroundColor(.accentColor)
                Text("运行环境测试").font(.system(size: 20, weight: .semibold))
                Spacer()
                Button { model.showEnvironment = false } label: { TablerIcon(name: "x", size: 14).frame(width: 22, height: 22) }
                    .buttonStyle(.borderless).keyboardShortcut(.cancelAction)
                    .help("关闭").accessibilityLabel("关闭运行环境测试").accessibilityIdentifier("environment-close")
            }
            Text("检查本机下载与音频转换工具，不会访问账号或下载音乐。")
                .font(.system(size: 13)).foregroundColor(.secondary)
            Divider()
            ScrollView { NativeEnvironmentContent().padding(1) }
                .frame(minHeight: 0, maxHeight: .infinity).clipped()
            Divider()
            HStack(spacing: 10) {
                if model.isCheckingEnvironment {
                    ProgressView().controlSize(.small)
                    Text("正在检查…").font(.system(size: 12)).foregroundColor(.secondary)
                }
                Spacer()
                Button(action: model.checkEnvironment) { LibraryButtonLabel(title: "重新检查", icon: "refresh") }
                    .buttonStyle(ReferenceButtonStyle()).disabled(model.isCheckingEnvironment).accessibilityIdentifier("environment-recheck")
                Button("完成") { model.showEnvironment = false }.buttonStyle(ReferenceButtonStyle(primary: true))
                    .keyboardShortcut(.defaultAction).accessibilityIdentifier("environment-done")
            }.controlSize(.regular)
        }.padding(22).frame(width: 620, height: 600).background(LibraryTheme.background)
            .foregroundColor(LibraryTheme.ink).font(.system(size: 13)).accentColor(LibraryTheme.accent)
    }
}

@MainActor
private struct NativeEnvironmentContent: View {
    @EnvironmentObject private var model: AppModel
    @State private var showInstallation = false
    private var toolsNeedRepair: Bool {
        model.healthItems.contains { ["ffmpeg", "ffprobe"].contains($0.id) && !["ready", "available", "passed", "ok"].contains($0.state) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            NativeEnvironmentList()
            if toolsNeedRepair {
                Label { Text("音频工具尚未就绪，请按以下步骤安装或修复。").font(.system(size: 12)) }
                    icon: { TablerIcon(name: "alert-circle", size: 16) }.foregroundColor(LibraryTheme.warning)
                NativeDependencyGuide()
            }
            if !toolsNeedRepair {
                DisclosureGroup("安装或更换音频工具", isExpanded: $showInstallation) { NativeDependencyGuide().padding(.top, 8) }
                    .font(.system(size: 12))
            }
        }
    }
}

@MainActor
private struct NativeEnvironmentList: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        NativeSettingsGroup("工具状态") {
            if model.healthItems.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text(model.isCheckingEnvironment ? "正在检查本机工具…" : "尚未检查运行环境")
                    Text("点击重新检查，读取工具版本与实际路径。").font(.system(size: 12)).foregroundColor(.secondary)
                }.padding(8)
            } else {
                VStack(spacing: 0) {
                    ForEach(model.healthItems, id: \.id) { item in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 7) {
                                TablerIcon(name: ready(item) ? "circle-check" : "alert-circle", size: 16).foregroundColor(stateColor(item))
                                Text(item.title).font(.system(size: 15, weight: .medium))
                                if !item.required { Text("可选").font(.system(size: 11)).foregroundColor(.secondary) }
                                Spacer(minLength: 0)
                                Text(item.version.isEmpty ? (ready(item) ? "已就绪" : (["ffmpeg", "ffprobe"].contains(item.id) ? "未找到" : "待处理")) : item.version)
                                    .font(.system(size: 12)).foregroundColor(stateColor(item)).lineLimit(1)
                            }
                            if !item.detail.isEmpty && !ready(item) && !["ffmpeg", "ffprobe"].contains(item.id) {
                                Text(item.detail).font(.system(size: 12)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                            }
                            if !ready(item), !["ffmpeg", "ffprobe"].contains(item.id) {
                                Text("请重新安装完整的澄闻应用。").font(.system(size: 12)).foregroundColor(.secondary)
                            }
                            if !item.path.isEmpty {
                                HStack(spacing: 8) {
                                    Text(item.path).font(.system(size: 11, design: .monospaced)).foregroundColor(.secondary)
                                        .lineLimit(1).truncationMode(.middle).textSelection(.enabled).help(item.path)
                                    Spacer(minLength: 0)
                                    Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(item.path, forType: .string) }
                                        label: { TablerIcon(name: "copy", size: 13) }.buttonStyle(.borderless)
                                        .help("复制路径").accessibilityLabel("复制 \(item.title) 路径")
                                }
                            }
                        }.padding(.horizontal, 8).padding(.vertical, 6)
                            .help(item.detail)
                        if item.id != model.healthItems.last?.id { Divider().padding(.horizontal, 8) }
                    }
                }
            }
        }
    }
    private func ready(_ item: EnvironmentItem) -> Bool { ["ready", "available", "passed", "ok"].contains(item.state) }
    private func stateColor(_ item: EnvironmentItem) -> Color { ready(item) ? LibraryTheme.success : item.required ? LibraryTheme.warning : .secondary }
}

struct NativeEmptyState: View {
    let icon: String
    let title: String
    let detail: String
    var body: some View {
        VStack(spacing: 10) {
            TablerIcon(name: icon, size: 28).foregroundColor(.secondary).padding(.bottom, 4)
            Text(title).font(.system(size: 14, weight: .medium))
            Text(detail).font(.system(size: 12)).foregroundColor(.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 360)
        }.padding(28).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
