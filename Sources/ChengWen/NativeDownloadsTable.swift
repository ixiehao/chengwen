import AppKit
import SwiftUI

/// Downloads use the same native columns, row density and selection as search.
/// Actions resolve a stable job ID at click time, even after filtering/reuse.
@MainActor
struct NativeDownloadsTable: NSViewRepresentable {
    @ObservedObject var model: AppModel
    let jobs: [DownloadJob]
    var scope: String = "all"
    let showAccounts: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NativeDownloadsScrollView {
        let scroll = NativeDownloadsScrollView()
        scroll.table.delegate = context.coordinator
        scroll.table.dataSource = context.coordinator
        context.coordinator.scroll = scroll
        return scroll
    }
    func updateNSView(_ scroll: NativeDownloadsScrollView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.update(enabled: context.environment.isEnabled)
    }
    static func dismantleNSView(_ view: NativeDownloadsScrollView, coordinator: Coordinator) {
        coordinator.popover?.animates = false
        coordinator.popover?.close(); coordinator.popover = nil
        view.table.delegate = nil; view.table.dataSource = nil
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var parent: NativeDownloadsTable
        weak var scroll: NativeDownloadsScrollView?
        var popover: NSPopover?
        private var detailJobID: String?
        private var detailFingerprint: String?
        private var rows: [DownloadJob] = []
        private var fingerprints: [String: String] = [:]
        private var enabled = true
        private var previousScope: String?
        init(_ parent: NativeDownloadsTable) { self.parent = parent }
        func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
        func update(enabled: Bool) {
            guard let scroll = scroll else { return }
            let table = scroll.table
            let oldIDs = rows.map(\.id), next = parent.jobs, nextIDs = next.map(\.id)
            let previousOffset = scroll.contentView.bounds.origin
            let selectedID = rows.indices.contains(table.selectedRow) ? rows[table.selectedRow].id : nil
            let scopeChanged = previousScope != parent.scope
            let changedIDs = oldIDs != nextIDs
            // Keep the first visible task in the same place while new tasks
            // arrive or an active filter loses a completed task. A deliberate
            // filter change starts from the top instead.
            let visibleY = previousOffset.y + scroll.headerOverlap + 0.5
            let anchorIndex = table.row(at: NSPoint(x: 10, y: visibleY))
            let anchorInset = rows.indices.contains(anchorIndex) ? table.rect(ofRow: anchorIndex).minY - previousOffset.y : 0
            let retainedIDs = Set(nextIDs)
            let anchorID: String?
            if !scopeChanged, oldIDs.indices.contains(anchorIndex) {
                anchorID = oldIDs[anchorIndex...].first(where: retainedIDs.contains)
                    ?? oldIDs[..<anchorIndex].reversed().first(where: retainedIDs.contains)
            } else { anchorID = nil }
            let enabledChanged = self.enabled != enabled
            self.enabled = enabled; rows = next; previousScope = parent.scope
            if let id = detailJobID, scopeChanged || !enabled ||
                !rows.contains(where: { $0.id == id && $0.state == "failed" && fingerprint($0) == detailFingerprint }) {
                popover?.animates = false
                popover?.close(); popover = nil; detailJobID = nil; detailFingerprint = nil
            }
            if scopeChanged {
                table.reloadData()
            } else if changedIDs {
                // Incremental changes preserve the native button that may be
                // tracking a press; reloadData would recycle every visible row.
                let changes = nextIDs.difference(from: oldIDs)
                var removed = IndexSet(), inserted = IndexSet()
                for change in changes {
                    switch change {
                    case .remove(let offset, _, _): removed.insert(offset)
                    case .insert(let offset, _, _): inserted.insert(offset)
                    }
                }
                table.beginUpdates()
                table.removeRows(at: removed, withAnimation: [])
                table.insertRows(at: inserted, withAnimation: [])
                table.endUpdates()
            }
            let changed = IndexSet(rows.indices.filter {
                fingerprints[rows[$0].id] != nil &&
                    (enabledChanged || fingerprints[rows[$0].id] != fingerprint(rows[$0]))
            })
            if !changed.isEmpty {
                table.reloadData(forRowIndexes: changed, columnIndexes: IndexSet(integersIn: 0..<table.numberOfColumns))
            }
            fingerprints = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, fingerprint($0)) })
            if changedIDs || scopeChanged {
                if let id = selectedID, let row = rows.firstIndex(where: { $0.id == id }) {
                    table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                } else { table.deselectAll(nil) }
                table.layoutSubtreeIfNeeded(); scroll.layoutSubtreeIfNeeded()
                let clip = scroll.contentView, minimumY = -scroll.headerOverlap
                let bottom = rows.isEmpty ? 0 : table.rect(ofRow: rows.count - 1).maxY
                let maximumY = max(minimumY, bottom - clip.bounds.height)
                let proposedY = anchorID.flatMap { id in rows.firstIndex(where: { $0.id == id }) }
                    .map { table.rect(ofRow: $0).minY - anchorInset } ?? minimumY
                let maximumX = max(0, table.bounds.width - clip.bounds.width)
                clip.scroll(to: NSPoint(x: scopeChanged ? 0 : min(max(0, previousOffset.x), maximumX),
                                       y: min(max(minimumY, proposedY), maximumY)))
                scroll.reflectScrolledClipView(clip)
            }
        }
        private func fingerprint(_ job: DownloadJob) -> String {
            [job.track.title, job.track.artist, job.track.sourceName, job.format, job.state,
             String(job.percent), job.detail, job.solution, job.technical, job.errorCode,
             String(job.retryCount), job.path, job.track.url].joined(separator: "\u{1F}")
        }
        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { NativeResultRowView() }
        func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
            guard rows.indices.contains(row), let column = column else { return nil }
            let job = rows[row], identifier = column.identifier
            switch identifier.rawValue {
            case "title":
                let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? NativeResultTitleCell ?? NativeResultTitleCell()
                cell.identifier = identifier; cell.configure(job.track)
                return cell
            case "status":
                let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? NativeDownloadStatusCell ?? NativeDownloadStatusCell()
                cell.identifier = identifier; cell.configure(job)
                return cell
            case "actions":
                let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? NativeDownloadActionsCell ?? NativeDownloadActionsCell()
                cell.identifier = identifier; cell.configure(job, enabled: enabled)
                cell.onPrimary = { [weak self] in
                    guard let self = self, self.enabled, let current = self.current(job.id) else { return }
                    if current.state == "cancelling" { return }
                    if current.active { self.parent.model.cancelJob(current.id) }
                    else if current.state == "completed" { self.parent.model.revealFile(current.path) }
                    else { self.parent.model.retryJob(current.id) }
                }
                cell.onSwitch = { [weak self] in
                    guard let self = self, self.enabled, let current = self.current(job.id), current.state == "failed" else { return }
                    self.parent.model.switchSource(current.track)
                }
                cell.onDetails = { [weak self, weak cell] in
                    guard let self = self, self.enabled, let cell = cell, let current = self.current(job.id), current.state == "failed" else { return }
                    self.popover?.animates = false
                    self.popover?.close()
                    let popover = NSPopover(); popover.behavior = .transient
                    popover.contentViewController = NSHostingController(rootView: NativeDownloadDetails(job: current, showAccounts: { [weak self] in
                        self?.popover?.close(); self?.parent.showAccounts()
                    }, showEnvironment: { [weak self] in
                        self?.popover?.close(); self?.parent.model.checkEnvironment()
                    }))
                    self.popover = popover; self.detailJobID = current.id; self.detailFingerprint = self.fingerprint(current)
                    popover.show(relativeTo: cell.more.bounds, of: cell.more, preferredEdge: .minY)
                }
                return cell
            default:
                let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? NativeResultTextCell ?? NativeResultTextCell()
                cell.identifier = identifier
                let value = identifier.rawValue == "source" ? job.track.sourceName : identifier.rawValue == "format" ? (AudioFormat.all.first { $0.id == job.format }?.name ?? job.format.uppercased()) : NativeDownloadPresentation.summary(job)
                cell.label.stringValue = value
                cell.label.alignment = identifier.rawValue == "format" ? .center : .left
                cell.label.textColor = identifier.rawValue == "detail" ? (job.state == "failed" ? .systemRed : .secondaryLabelColor) : .labelColor
                cell.toolTip = identifier.rawValue == "detail" ? NativeDownloadPresentation.explanation(job) : value
                return cell
            }
        }
        private func current(_ id: String) -> DownloadJob? {
            guard rows.contains(where: { $0.id == id }) else { return nil }
            return parent.model.jobs.first { $0.id == id }
        }
    }
}

enum NativeDownloadPresentation {
    enum RecoveryAction { case accounts, environment }
    static func recoveryAction(_ job: DownloadJob) -> RecoveryAction? {
        if ["authentication", "authentication_file", "authentication_netease", "authentication_kuwo",
            "account_expired", "account_risk", "account_permission", "account_changed"].contains(job.errorCode),
           NativeSessionStore.platforms.contains(job.track.source) { return .accounts }
        if ["dependency", "conversion", "tool_launch", "tool_timeout", "tool_output"].contains(job.errorCode) { return .environment }
        return nil
    }
    static func title(_ job: DownloadJob) -> String {
        ["queued": "等待中", "pending": "等待中", "downloading": "下载中", "converting": "转换中", "completed": "已完成", "failed": "下载失败", "cancelled": "已取消", "cancelling": "正在取消", "interrupted": "已中断"][job.state] ?? "等待处理"
    }
    static func summary(_ job: DownloadJob) -> String {
        if job.state == "completed" { return "已保存到本地" }
        if job.state == "failed", job.retryCount > 0 { return "\(job.detail.isEmpty ? "下载未完成" : job.detail) · 已重试 \(job.retryCount) 次，建议换源" }
        return job.detail.isEmpty ? (job.state == "failed" ? "下载未完成，点击详情查看" : title(job)) : job.detail
    }
    static func explanation(_ job: DownloadJob) -> String {
        let reason = job.detail.isEmpty && job.state == "failed" ? "下载未完成，当前来源没有提供可保存的完整音频。" : job.detail
        let solution = job.solution.isEmpty && job.state == "failed" ? "请重试重新解析链接；仍失败时，请更换其他音源或完整版本。" : job.solution
        return [reason, solution.isEmpty ? "" : "解决办法：\(solution)",
         job.retryCount > 0 ? "已重试 \(job.retryCount) 次；仍失败时，请更换其他音源或版本。" : "", job.technical].filter { !$0.isEmpty }.joined(separator: "\n\n")
    }
}

final class NativeDownloadsScrollView: NativeTableScrollView {
    let table = NSTableView()
    private var lastWidth: CGFloat = 0
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        borderType = .bezelBorder; hasVerticalScroller = true; hasHorizontalScroller = true; autohidesScrollers = true
        drawsBackground = true; backgroundColor = .textBackgroundColor
        table.rowHeight = 48; table.intercellSpacing = NSSize(width: 0, height: 1)
        table.style = .fullWidth; table.usesAlternatingRowBackgroundColors = true
        table.gridStyleMask = []; table.allowsMultipleSelection = false; table.allowsEmptySelection = true
        table.allowsColumnReordering = false; table.allowsColumnResizing = true; table.columnAutoresizingStyle = .noColumnAutoresizing
        table.headerView = NSTableHeaderView(frame: NSRect(x: 0, y: 0, width: 0, height: 28))
        table.setAccessibilityLabel("下载任务，最新添加的任务在前")
        table.setAccessibilityIdentifier("download-jobs-table")
        for (id, title, width) in [("title", "歌曲 / 艺术家", 240.0), ("source", "来源", 98), ("format", "格式", 54),
                                   ("status", "状态 / 进度", 110), ("detail", "说明", 180), ("actions", "操作", 176)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title; column.width = width
            column.minWidth = id == "title" ? 190 : id == "detail" ? 150 : width
            column.maxWidth = ["title", "detail"].contains(id) ? 1200 : width
            column.resizingMask = ["title", "detail"].contains(id) ? .userResizingMask : []
            column.headerCell.font = .systemFont(ofSize: 11, weight: .medium)
            column.headerCell.alignment = id == "format" ? .center : .left
            table.addTableColumn(column)
        }
        documentView = table
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layout() {
        super.layout()
        let available = max(0, contentSize.width - 16)
        guard available > 0, abs(available - lastWidth) > 0.5 else { return }
        lastWidth = available
        let flexible = max(340, available - 438)
        table.tableColumns[0].width = max(190, flexible * 0.56)
        table.tableColumns[4].width = max(150, flexible * 0.44)
    }

}

final class NativeDownloadStatusCell: NSTableCellView {
    let label = NSTextField(labelWithString: "")
    let progress = NSProgressIndicator()
    private let badge = NSBox()
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        badge.boxType = .custom; badge.borderWidth = 0; badge.cornerRadius = 7
        label.font = .systemFont(ofSize: 11, weight: .medium)
        for view in [badge, label, progress] { view.translatesAutoresizingMaskIntoConstraints = false }
        addSubview(badge); badge.addSubview(label); addSubview(progress)
        progress.style = .bar; progress.controlSize = .small; progress.maxValue = 100
        NSLayoutConstraint.activate([
            badge.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6), badge.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -3),
            label.leadingAnchor.constraint(equalTo: badge.leadingAnchor, constant: 7), label.trailingAnchor.constraint(equalTo: badge.trailingAnchor, constant: -7),
            label.topAnchor.constraint(equalTo: badge.topAnchor, constant: 3), label.bottomAnchor.constraint(equalTo: badge.bottomAnchor, constant: -3),
            progress.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 7), progress.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            progress.topAnchor.constraint(equalTo: badge.bottomAnchor, constant: 4), progress.heightAnchor.constraint(equalToConstant: 3)
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func configure(_ job: DownloadJob) {
        let color: NSColor = job.state == "completed" ? .systemGreen : job.state == "failed" ? .systemRed : job.active ? NSColor(LibraryTheme.accent) : .secondaryLabelColor
        let percent = max(0, min(100, job.percent))
        label.stringValue = NativeDownloadPresentation.title(job) + (job.active && job.percent >= 0 ? " \(percent)%" : "")
        label.textColor = color; badge.fillColor = color.withAlphaComponent(0.10)
        progress.isHidden = !job.active; progress.isIndeterminate = job.percent < 0
        progress.doubleValue = Double(percent)
        if job.active && job.percent < 0 { progress.startAnimation(nil) } else { progress.stopAnimation(nil) }
        setAccessibilityLabel(label.stringValue); toolTip = label.stringValue
    }
}

final class NativeDownloadActionsCell: NSTableCellView {
    let primary = ReferenceActionButton(title: "", target: nil, action: nil)
    let switchSource = ReferenceActionButton(title: "换源", target: nil, action: nil)
    let more = ReferenceActionButton(title: "", target: nil, action: nil)
    var onPrimary: (() -> Void)?, onSwitch: (() -> Void)?, onDetails: (() -> Void)?
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        for button in [primary, switchSource, more] {
            button.setButtonType(.momentaryPushIn); button.bezelStyle = .rounded
            button.font = .systemFont(ofSize: 11); button.target = self
            button.translatesAutoresizingMaskIntoConstraints = false
            button.heightAnchor.constraint(equalToConstant: 28).isActive = true
        }
        primary.widthAnchor.constraint(equalToConstant: 82).isActive = true
        switchSource.widthAnchor.constraint(equalToConstant: 48).isActive = true
        more.widthAnchor.constraint(equalToConstant: 26).isActive = true
        primary.action = #selector(primaryClicked); switchSource.action = #selector(switchClicked); more.action = #selector(detailsClicked)
        more.image = nativeControlImage("info-circle", size: 14)
        let stack = NSStackView(views: [primary, switchSource, more]); stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false; addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6), stack.centerYAnchor.constraint(equalTo: centerYAnchor)])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func configure(_ job: DownloadJob, enabled: Bool) {
        let needsSearch = !job.active && job.state != "completed" && job.track.url.isEmpty
        primary.title = job.active ? "取消" : job.state == "completed" ? "显示文件" : needsSearch ? "重新搜索" : "重试"
        primary.image = nativeControlImage(job.active ? "x" : job.state == "completed" ? "folder" : needsSearch ? "search" : "refresh", size: 12)
        primary.isEnabled = enabled && job.state != "cancelling"
        switchSource.isHidden = job.state != "failed"; more.isHidden = job.state != "failed"
        switchSource.isEnabled = enabled; more.isEnabled = enabled
        primary.setAccessibilityLabel("\(primary.title) · \(job.track.title)")
        primary.setAccessibilityIdentifier("download-primary-\(job.id)")
        switchSource.setAccessibilityLabel("换源搜索 · \(job.track.title)")
        more.setAccessibilityLabel("下载失败详情 · \(job.track.title)")
        more.toolTip = "查看完整原因与解决办法"; switchSource.toolTip = "使用其他音源搜索这首歌"
        for button in [primary, switchSource, more] { button.needsDisplay = true }
    }
    @objc private func primaryClicked() { if primary.isEnabled { onPrimary?() } }
    @objc private func switchClicked() { if switchSource.isEnabled { onSwitch?() } }
    @objc private func detailsClicked() { if more.isEnabled { onDetails?() } }
}

@MainActor
private struct NativeDownloadDetails: View {
    let job: DownloadJob
    let showAccounts: () -> Void
    let showEnvironment: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("下载失败说明").font(.system(size: 16, weight: .semibold))
                Spacer()
                Button("复制") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(NativeDownloadPresentation.explanation(job), forType: .string)
                }.buttonStyle(.borderless)
            }
            Text(job.track.title).font(.system(size: 13, weight: .medium))
            Divider()
            ScrollView {
                Text(NativeDownloadPresentation.explanation(job)).font(.system(size: 13))
                    .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
            }
            HStack {
                if NativeDownloadPresentation.recoveryAction(job) == .accounts {
                    Button("账号设置", action: showAccounts).buttonStyle(ReferenceButtonStyle())
                }
                if NativeDownloadPresentation.recoveryAction(job) == .environment {
                    Button("环境测试", action: showEnvironment).buttonStyle(ReferenceButtonStyle())
                }
            }
        }.padding(18).frame(width: 420, height: 270).foregroundColor(LibraryTheme.ink).background(LibraryTheme.background)
    }
}
