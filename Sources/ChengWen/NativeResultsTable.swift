import AppKit
import SwiftUI

/// A view-based AppKit table gives columns, scrolling, focus and range selection
/// one owner. Checkbox selection and the native selected rows share stable IDs.
@MainActor
struct NativeResultsTable: NSViewRepresentable {
    @ObservedObject var model: AppModel
    @Binding var focusedTrackID: String?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NativeResultsScrollView {
        let scroll = NativeResultsScrollView()
        let table = scroll.resultsTable
        table.delegate = context.coordinator
        table.dataSource = context.coordinator
        table.onToggleFocused = { [weak coordinator = context.coordinator] in coordinator?.toggleFocused() }
        table.onSelectionCommand = { [weak coordinator = context.coordinator] all in
            coordinator?.setAllSelected(all)
        }
        scroll.resultsHeader.selectAllButton.target = context.coordinator
        scroll.resultsHeader.selectAllButton.action = #selector(Coordinator.toggleAll(_:))
        context.coordinator.scroll = scroll
        return scroll
    }

    func updateNSView(_ scroll: NativeResultsScrollView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.update(isEnabled: context.environment.isEnabled)
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var parent: NativeResultsTable
        weak var scroll: NativeResultsScrollView?
        private var ids: [String] = []
        private var rows: [AudioTrack] = []
        private var fingerprints: [String: String] = [:]
        private var synchronisingSelection = false
        private var controlsEnabled = true

        init(_ parent: NativeResultsTable) { self.parent = parent }

        func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

        func update(isEnabled: Bool) {
            guard let scroll = scroll else { return }
            let table = scroll.resultsTable
            let nextRows = parent.model.tracks
            let nextIDs = nextRows.map(\.id)
            let previousIDs = ids
            let previousOffset = scroll.contentView.bounds.origin
            let IDsChanged = previousIDs != nextIDs
            let appending = !previousIDs.isEmpty && nextIDs.starts(with: previousIDs)
            let enabledChanged = controlsEnabled != isEnabled
            controlsEnabled = isEnabled
            table.controlsEnabled = isEnabled
            ids = nextIDs
            rows = nextRows
            synchronisingSelection = true
            if IDsChanged {
                // Search results arrive in batches. Appending must not discard
                // the user's scroll position, focused row or existing choices.
                if appending {
                    table.insertRows(at: IndexSet(previousIDs.count..<nextIDs.count), withAnimation: [])
                } else {
                    table.reloadData()
                }
            }
            let changed = IndexSet(rows.indices.filter { index in
                let id = rows[index].id
                return enabledChanged || fingerprints[id] != fingerprint(rows[index])
            })
            if !changed.isEmpty {
                table.reloadData(forRowIndexes: changed, columnIndexes: IndexSet(integersIn: 0..<table.numberOfColumns))
            }
            fingerprints = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, fingerprint($0)) })
            let selected = IndexSet(rows.indices.filter { parent.model.selection.contains(rows[$0].id) })
            if table.selectedRowIndexes != selected { table.selectRowIndexes(selected, byExtendingSelection: false) }
            synchronisingSelection = false
            updateHeader()
            if IDsChanged {
                // NSClipView can retain its old bounds origin after reloadData
                // shrinks the document. Compute the real last-row boundary;
                // the table frame itself may still reflect its previous size.
                // New/replaced results start at the top, while streamed batches
                // retain the existing viewport within the new row bounds.
                table.layoutSubtreeIfNeeded()
                scroll.layoutSubtreeIfNeeded()
                let minimumY = -scroll.headerOverlap
                let proposed = appending ? previousOffset : NSPoint(x: 0, y: minimumY)
                let clip = scroll.contentView
                let bottom = rows.isEmpty ? 0 : table.rect(ofRow: rows.count - 1).maxY
                let maximumY = max(minimumY, bottom - clip.bounds.height)
                let maximumX = max(0, table.bounds.width - clip.bounds.width)
                let origin = NSPoint(x: min(max(0, proposed.x), maximumX), y: min(max(minimumY, proposed.y), maximumY))
                clip.scroll(to: origin)
                scroll.reflectScrolledClipView(clip)
            }
        }

        private func fingerprint(_ track: AudioTrack) -> String {
            let probe = parent.model.probes[track.id]
            return [track.title, track.artist, track.album, track.sourceName, track.ext, track.duration,
                    String(track.fragment), probe?.state ?? "", probe?.detail ?? "", probe?.solution ?? "",
                    String(describing: probe?.anonymous), String(parent.model.isProbing), String(parent.model.selection.contains(track.id))]
                .joined(separator: "\u{1F}")
        }

        private func updateHeader() {
            guard let button = scroll?.resultsHeader.selectAllButton else { return }
            let selectedCount = rows.reduce(0) { $0 + (parent.model.selection.contains($1.id) ? 1 : 0) }
            let allSelected = !rows.isEmpty && selectedCount == rows.count
            button.state = allSelected ? .on : selectedCount > 0 ? .mixed : .off
            button.isEnabled = controlsEnabled && !rows.isEmpty
            button.setAccessibilityLabel(allSelected ? "取消全选搜索结果" : "全选搜索结果")
        }

        @objc func toggleAll(_ sender: NSButton) {
            guard controlsEnabled, !rows.isEmpty else { return }
            setAllSelected(!parent.model.allSelected)
            scroll?.window?.makeFirstResponder(scroll?.resultsTable)
        }

        func setAllSelected(_ selected: Bool) {
            guard controlsEnabled, !synchronisingSelection else { return }
            parent.model.selection = selected ? Set(parent.model.tracks.map(\.id)) : []
            update(isEnabled: controlsEnabled)
        }

        func toggleFocused() {
            guard controlsEnabled, let table = scroll?.resultsTable else { return }
            let focused = parent.focusedTrackID.flatMap { ids.firstIndex(of: $0) }
            let indices = table.selectedRowIndexes.isEmpty ? focused.map { IndexSet(integer: $0) } ?? [] : table.selectedRowIndexes
            let selectedIDs = indices.compactMap { rows.indices.contains($0) ? rows[$0].id : nil }
            let clear = !selectedIDs.isEmpty && selectedIDs.allSatisfy { parent.model.selection.contains($0) }
            for id in selectedIDs {
                if clear { parent.model.selection.remove(id) } else { parent.model.selection.insert(id) }
            }
            update(isEnabled: controlsEnabled)
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !synchronisingSelection, controlsEnabled, let table = notification.object as? NSTableView else { return }
            parent.model.selection = Set(table.selectedRowIndexes.compactMap { rows.indices.contains($0) ? rows[$0].id : nil })
            if rows.indices.contains(table.selectedRow) { parent.focusedTrackID = rows[table.selectedRow].id }
            updateHeader()
        }

        func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { controlsEnabled }

        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            NativeResultRowView()
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard rows.indices.contains(row), let column = tableColumn else { return nil }
            let track = rows[row]
            let presentation = LibraryProbePresentation(parent.model.probes[track.id])
            let identifier = column.identifier
            switch identifier.rawValue {
            case "selection":
                let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? NativeResultCheckboxCell ?? NativeResultCheckboxCell()
                cell.identifier = identifier
                cell.button.state = parent.model.selection.contains(track.id) ? .on : .off
                cell.button.isEnabled = controlsEnabled
                cell.button.setAccessibilityLabel("选择 \(track.title)")
                cell.button.setAccessibilityIdentifier("result-select-\(track.id)")
                cell.onToggle = { [weak self] in
                    guard let self = self, self.controlsEnabled, let current = self.current(track.id) else { return }
                    self.parent.focusedTrackID = current.id
                    self.parent.model.toggleTrack(current.id)
                    self.update(isEnabled: self.controlsEnabled)
                }
                return cell
            case "title":
                let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? NativeResultTitleCell ?? NativeResultTitleCell()
                cell.identifier = identifier
                cell.configure(track)
                return cell
            case "availability":
                let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? NativeResultStatusCell ?? NativeResultStatusCell()
                cell.identifier = identifier
                cell.configure(presentation)
                return cell
            case "actions":
                let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? NativeResultActionsCell ?? NativeResultActionsCell()
                cell.identifier = identifier
                cell.probe.isEnabled = controlsEnabled && !parent.model.isProbing
                cell.download.isEnabled = controlsEnabled
                cell.probe.setAccessibilityLabel("试读 \(track.title) 的少量音频")
                cell.probe.setAccessibilityIdentifier("result-probe-\(track.id)")
                cell.probe.toolTip = "试读少量音频；整首验证以实际下载为准"
                cell.download.setAccessibilityLabel("下载 \(track.title)")
                cell.download.setAccessibilityIdentifier("result-download-\(track.id)")
                cell.download.toolTip = "直接下载这一首；预下载测试为可选步骤"
                cell.onProbe = { [weak self] in
                    guard let self = self, self.controlsEnabled, !self.parent.model.isProbing,
                          let current = self.current(track.id) else { return }
                    self.parent.focusedTrackID = current.id; self.parent.model.probeTrack(current)
                }
                cell.onDownload = { [weak self] in
                    guard let self = self, self.controlsEnabled, let current = self.current(track.id) else { return }
                    self.parent.focusedTrackID = current.id; self.parent.model.downloadTrack(current)
                }
                return cell
            default:
                let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? NativeResultTextCell ?? NativeResultTextCell()
                cell.identifier = identifier
                let value: String
                switch identifier.rawValue {
                case "album": value = track.album.isEmpty ? "—" : track.album
                case "source": value = track.sourceName
                case "format": value = track.ext.isEmpty ? "原始" : track.ext.uppercased()
                case "duration": value = track.duration.isEmpty ? "—" : track.duration
                default: value = ""
                }
                cell.label.stringValue = value
                cell.label.alignment = ["duration", "format"].contains(identifier.rawValue) ? .center : .left
                cell.label.font = identifier.rawValue == "duration" ? .monospacedDigitSystemFont(ofSize: 12, weight: .regular) : .systemFont(ofSize: 12)
                cell.toolTip = value
                return cell
            }
        }
        // Native buttons can outlive a reload, and a new search may reuse an
        // ID with a refreshed route. Never submit the cell's captured snapshot.
        private func current(_ id: String) -> AudioTrack? { parent.model.tracks.first { $0.id == id } }
    }
}

/// Retain NSTableView's native selection and focus behaviour while matching
/// the library's violet palette for the selected row background.
final class NativeResultRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let color = dark
            ? NSColor(srgbRed: 0.37, green: 0.30, blue: 0.52, alpha: 1)
            : NSColor(srgbRed: 0.91, green: 0.88, blue: 0.98, alpha: 1)
        color.setFill()
        bounds.fill()
    }
}

final class NativeResultsScrollView: NativeTableScrollView {
    let resultsTable = NativeResultsTableView()
    let resultsHeader = NativeResultsHeaderView()
    private var lastContentWidth: CGFloat = 0
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        borderType = .bezelBorder
        hasVerticalScroller = true
        // Columns fit at supported window widths. An explicitly widened column
        // remains reachable through the system's auto-hiding horizontal scroller.
        hasHorizontalScroller = true
        autohidesScrollers = true
        drawsBackground = true
        backgroundColor = .textBackgroundColor
        resultsTable.headerView = resultsHeader
        resultsHeader.frame.size.height = 28
        resultsTable.rowHeight = 44
        resultsTable.intercellSpacing = NSSize(width: 0, height: 1)
        resultsTable.style = .fullWidth
        resultsTable.usesAlternatingRowBackgroundColors = true
        resultsTable.gridStyleMask = []
        resultsTable.allowsMultipleSelection = true
        resultsTable.allowsEmptySelection = true
        resultsTable.allowsColumnReordering = false
        resultsTable.allowsColumnResizing = true
        resultsTable.columnAutoresizingStyle = .noColumnAutoresizing
        resultsTable.focusRingType = .default
        resultsTable.setAccessibilityLabel("音乐搜索结果")
        resultsTable.setAccessibilityIdentifier("music-results-table")
        resultsTable.setAccessibilityHelp("用方向键浏览，按住 Command 或 Shift 多选；Command+A 全选，Shift+Command+A 取消全选，空格切换选择。")
        for (id, title, width) in [("selection", "", 32.0), ("title", "歌曲 / 艺术家", 240), ("album", "专辑", 138),
                                   ("source", "来源", 96), ("format", "格式", 50), ("duration", "时长", 58),
                                   ("availability", "可用性", 112), ("actions", "操作", 122)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title
            column.width = width
            column.minWidth = id == "title" ? 150 : id == "album" ? 90 : width
            column.maxWidth = ["title", "album"].contains(id) ? 800 : width
            column.resizingMask = ["title", "album"].contains(id) ? .userResizingMask : []
            column.headerCell.font = .systemFont(ofSize: 11, weight: .medium)
            column.headerCell.alignment = ["format", "duration", "actions"].contains(id) ? .center : .left
            resultsTable.addTableColumn(column)
        }
        documentView = resultsTable
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        let available = max(0, contentSize.width - 16)
        guard available > 0, abs(available - lastContentWidth) > 0.5, resultsTable.tableColumns.count == 8 else { return }
        lastContentWidth = available
        let albumWidth: CGFloat = available < 880 ? 90 : 140
        let fixed: CGFloat = 32 + 96 + 50 + 58 + 112 + 122
        let titleWidth = max(150, available - fixed - albumWidth)
        if abs(resultsTable.tableColumns[1].width - titleWidth) > 0.5 { resultsTable.tableColumns[1].width = titleWidth }
        if abs(resultsTable.tableColumns[2].width - albumWidth) > 0.5 { resultsTable.tableColumns[2].width = albumWidth }
        resultsHeader.needsLayout = true
    }
}

final class NativeResultsHeaderView: NSTableHeaderView {
    let selectAllButton = NativeTriStateCheckbox.makeButton(target: nil, action: nil)
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        selectAllButton.setAccessibilityIdentifier("result-select-all")
        selectAllButton.setAccessibilityLabel("全选搜索结果")
        addSubview(selectAllButton)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layout() {
        super.layout()
        guard tableView?.numberOfColumns ?? 0 > 0 else { return }
        let rect = headerRect(ofColumn: 0)
        selectAllButton.frame = NSRect(x: rect.midX - 7, y: rect.midY - 8, width: 14, height: 16)
    }
}

final class NativeResultsTableView: NSTableView {
    var controlsEnabled = true
    var onToggleFocused: (() -> Void)?
    var onSelectionCommand: ((Bool) -> Void)?
    override func selectAll(_ sender: Any?) { if controlsEnabled { super.selectAll(sender) } }
    override func deselectAll(_ sender: Any?) { if controlsEnabled { super.deselectAll(sender) } }
    override func keyDown(with event: NSEvent) {
        guard controlsEnabled else { return }
        if event.keyCode == 49, event.modifierFlags.intersection([.command, .shift, .option, .control]).isEmpty {
            onToggleFocused?()
        } else { super.keyDown(with: event) }
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        if event.charactersIgnoringModifiers?.lowercased() == "a", modifiers == .command || modifiers == [.command, .shift] {
            guard controlsEnabled, window?.firstResponder === self else { return false }
            onSelectionCommand?(modifiers == .command)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

@MainActor
private func tableLabel(size: CGFloat = 12, weight: NSFont.Weight = .regular) -> NSTextField {
    let label = NSTextField(labelWithString: "")
    label.font = .systemFont(ofSize: size, weight: weight)
    label.lineBreakMode = .byTruncatingTail
    label.maximumNumberOfLines = 1
    label.cell?.usesSingleLineMode = true
    label.translatesAutoresizingMaskIntoConstraints = false
    label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    return label
}

private final class NativeResultCheckboxCell: NSTableCellView {
    let button = NativeTriStateCheckbox.makeButton(target: nil, action: nil)
    var onToggle: (() -> Void)?
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        button.controlSize = .small
        button.allowsMixedState = false
        button.target = self
        button.action = #selector(toggle)
        button.translatesAutoresizingMaskIntoConstraints = false
        addSubview(button)
        NSLayoutConstraint.activate([button.centerXAnchor.constraint(equalTo: centerXAnchor), button.centerYAnchor.constraint(equalTo: centerYAnchor)])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func toggle() { onToggle?() }
}

final class NativeResultTextCell: NSTableCellView {
    let label = tableLabel()
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        textField = label
        addSubview(label)
        NSLayoutConstraint.activate([label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
                                     label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8), label.centerYAnchor.constraint(equalTo: centerYAnchor)])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

final class NativeResultTitleCell: NSTableCellView {
    let titleLabel = tableLabel(size: 14, weight: .medium)
    let artistLabel = tableLabel(size: 12)
    let fragment = tableLabel(size: 9, weight: .medium)
    let musicIcon = NSImageView()
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        textField = titleLabel
        fragment.stringValue = "片段"
        fragment.textColor = .systemOrange
        fragment.toolTip = "时长短于 60 秒，请确认是否为你需要的完整版本。"
        fragment.setContentHuggingPriority(.required, for: .horizontal)
        fragment.setContentCompressionResistancePriority(.required, for: .horizontal)
        let titleLine = NSStackView(views: [titleLabel, fragment])
        titleLine.spacing = 6
        titleLine.alignment = .firstBaseline
        let stack = NSStackView(views: [titleLine, artistLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 1
        stack.translatesAutoresizingMaskIntoConstraints = false
        musicIcon.image = nativeControlImage("music", size: 15)
        musicIcon.contentTintColor = NSColor(srgbRed: 0.32, green: 0.20, blue: 0.77, alpha: 1)
        musicIcon.imageScaling = .scaleNone
        musicIcon.wantsLayer = true
        musicIcon.layer?.backgroundColor = NSColor(srgbRed: 0.91, green: 0.88, blue: 0.98, alpha: 1).cgColor
        musicIcon.layer?.cornerRadius = 6
        musicIcon.translatesAutoresizingMaskIntoConstraints = false
        addSubview(musicIcon)
        addSubview(stack)
        NSLayoutConstraint.activate([musicIcon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
                                     musicIcon.centerYAnchor.constraint(equalTo: centerYAnchor),
                                     musicIcon.widthAnchor.constraint(equalToConstant: 30), musicIcon.heightAnchor.constraint(equalToConstant: 30),
                                     stack.leadingAnchor.constraint(equalTo: musicIcon.trailingAnchor, constant: 8),
                                     stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8), stack.centerYAnchor.constraint(equalTo: centerYAnchor),
                                     titleLine.widthAnchor.constraint(equalTo: stack.widthAnchor), artistLabel.widthAnchor.constraint(equalTo: stack.widthAnchor)])
        refreshColors()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func configure(_ track: AudioTrack) {
        titleLabel.stringValue = track.title
        artistLabel.stringValue = track.artist
        fragment.isHidden = !track.fragment
        toolTip = "\(track.title)\n\(track.artist)"
        titleLabel.setAccessibilityLabel(track.title + (track.fragment ? "，片段" : ""))
    }
    override var backgroundStyle: NSView.BackgroundStyle { didSet { refreshColors() } }
    private func refreshColors() {
        artistLabel.textColor = backgroundStyle == .emphasized ? .alternateSelectedControlTextColor : .secondaryLabelColor
        fragment.textColor = backgroundStyle == .emphasized ? .alternateSelectedControlTextColor : .systemOrange
    }
}

private final class NativeResultStatusCell: NSTableCellView {
    let label = tableLabel(size: 11)
    let statusImage = NSImageView()
    private let badge = NSBox()
    private var statusColor = NSColor.secondaryLabelColor
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        statusImage.translatesAutoresizingMaskIntoConstraints = false
        let stack = NSStackView(views: [statusImage, label])
        stack.spacing = 4
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false
        badge.boxType = .custom
        badge.borderWidth = 0
        badge.cornerRadius = 7
        badge.fillColor = NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(srgbRed: 0.24, green: 0.20, blue: 0.32, alpha: 1)
                : NSColor(srgbRed: 0.94, green: 0.92, blue: 0.98, alpha: 1)
        }
        badge.translatesAutoresizingMaskIntoConstraints = false
        addSubview(badge)
        badge.addSubview(stack)
        NSLayoutConstraint.activate([badge.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 5),
                                     badge.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4), badge.centerYAnchor.constraint(equalTo: centerYAnchor),
                                     stack.leadingAnchor.constraint(equalTo: badge.leadingAnchor, constant: 6),
                                     stack.trailingAnchor.constraint(equalTo: badge.trailingAnchor, constant: -6),
                                     stack.topAnchor.constraint(equalTo: badge.topAnchor, constant: 3),
                                     stack.bottomAnchor.constraint(equalTo: badge.bottomAnchor, constant: -3),
                                     statusImage.widthAnchor.constraint(equalToConstant: 14), statusImage.heightAnchor.constraint(equalToConstant: 14)])
        setAccessibilityElement(true)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func configure(_ presentation: LibraryProbePresentation) {
        label.stringValue = presentation.title
        statusImage.image = nativeControlImage(presentation.icon, size: 14)
        statusColor = NSColor(presentation.color)
        toolTip = presentation.tooltip
        setAccessibilityLabel(presentation.title)
        setAccessibilityValue(presentation.tooltip)
        refreshColors()
    }
    override var backgroundStyle: NSView.BackgroundStyle { didSet { refreshColors() } }
    private func refreshColors() {
        let color = statusColor
        label.textColor = color
        statusImage.contentTintColor = color
    }
}

private final class NativeResultActionsCell: NSTableCellView {
    let probe = NSButton(title: "测试", target: nil, action: nil)
    let download = NSButton(title: "下载", target: nil, action: nil)
    var onProbe: (() -> Void)?
    var onDownload: (() -> Void)?
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        probe.image = nativeControlImage("activity", size: 12)
        download.image = nativeControlImage("download", size: 12)
        for button in [probe, download] {
            button.controlSize = .small
            button.bezelStyle = .rounded
            button.font = .systemFont(ofSize: 11)
            button.setButtonType(.momentaryPushIn)
            button.imagePosition = .imageLeading
            button.target = self
            button.translatesAutoresizingMaskIntoConstraints = false
            button.widthAnchor.constraint(equalToConstant: 58).isActive = true
            button.heightAnchor.constraint(equalToConstant: 26).isActive = true
        }
        probe.action = #selector(probeClicked)
        download.action = #selector(downloadClicked)
        let stack = NSStackView(views: [probe, download])
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([stack.centerXAnchor.constraint(equalTo: centerXAnchor), stack.centerYAnchor.constraint(equalTo: centerYAnchor)])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func probeClicked() { if probe.isEnabled { onProbe?() } }
    @objc private func downloadClicked() { if download.isEnabled { onDownload?() } }
}
