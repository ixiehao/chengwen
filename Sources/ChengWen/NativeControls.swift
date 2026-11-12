import AppKit
import SwiftUI

/// AppKit owns drawing, focus, keyboard navigation and disabled appearances.
/// These bridges only synchronise values with the existing model bindings.
struct NativeSearchField: NSViewRepresentable {
    @Binding var text: String
    let label: String
    let onSearch: () -> Void

    @MainActor private static func styledField() -> NSSearchField {
        let field = NSSearchField()
        field.controlSize = .large
        field.font = .systemFont(ofSize: 15)
        return field
    }

    // The large search field uses different bezel heights on different macOS versions.
    @MainActor static let preferredHeight = styledField().intrinsicContentSize.height

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSSearchField {
        let field = Self.styledField()
        field.placeholderString = label
        field.sendsWholeSearchString = true
        field.sendsSearchStringImmediately = false
        field.maximumRecents = 0 // Recent searches already have a visible home.
        field.delegate = context.coordinator
        field.target = context.coordinator
        field.action = #selector(Coordinator.search(_:))
        field.setAccessibilityLabel(label)
        field.setAccessibilityIdentifier("music-search-field")
        if let cell = field.cell as? NSSearchFieldCell {
            cell.searchButtonCell?.image = nativeControlImage("search", size: 14)
            cell.cancelButtonCell?.image = nativeControlImage("x", size: 12)
        }
        return field
    }
    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.parent = self
        field.controlSize = .large
        if field.stringValue != text { field.stringValue = text }
        field.isEnabled = context.environment.isEnabled
        field.setAccessibilityLabel(label)
    }
    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: NativeSearchField
        init(_ parent: NativeSearchField) { self.parent = parent }
        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            parent.text = field.stringValue
        }
        @objc func search(_ sender: NSSearchField) {
            parent.text = sender.stringValue
            // The native clear button also sends an action; clearing is not a search.
            if !sender.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { parent.onSearch() }
        }
    }
}

/// A native push button sized to the search field, rather than a SwiftUI
/// label whose bezel can be smaller than its proposed layout frame.
struct NativeFormButton: NSViewRepresentable {
    let title: String
    var icon: String? = nil
    var primary = false
    var identifier: String? = nil
    var controlHeight: CGFloat = 28
    let action: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(action) }
    func makeNSView(context: Context) -> NSButton {
        let button = ReferenceActionButton(title: title, target: context.coordinator, action: #selector(Coordinator.activate(_:)))
        button.controlSize = .large
        button.bezelStyle = .rounded
        button.font = .systemFont(ofSize: 14, weight: .medium)
        button.imagePosition = .imageLeading
        button.keyEquivalent = "" // Return belongs to the focused search/text field.
        return button
    }
    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.action = action
        button.controlSize = .large
        button.title = title
        button.image = icon.flatMap { nativeControlImage($0, size: 14) }
        button.isEnabled = context.environment.isEnabled
        (button as? ReferenceActionButton)?.primary = primary
        (button as? ReferenceActionButton)?.controlHeight = controlHeight
        button.invalidateIntrinsicContentSize()
        button.needsDisplay = true
        button.bezelColor = primary ? NSColor(srgbRed: 0.32, green: 0.20, blue: 0.77, alpha: 1) : nil
        button.contentTintColor = primary && button.isEnabled ? .selectedControlTextColor : nil
        button.setAccessibilityLabel(title)
        button.setAccessibilityIdentifier(identifier)
    }
    final class Coordinator: NSObject {
        var action: () -> Void
        init(_ action: @escaping () -> Void) { self.action = action }
        @objc func activate(_ sender: NSButton) { action() }
    }
}

final class NativePathField: NSTextField {
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: super.intrinsicContentSize.height)
    }
}

struct NativeReadOnlyField: NSViewRepresentable {
    let text: String
    let label: String

    func makeNSView(context: Context) -> NSTextField {
        let field = NativePathField()
        field.controlSize = .large
        field.font = .systemFont(ofSize: 15)
        field.bezelStyle = .roundedBezel
        field.isEditable = false
        field.isSelectable = true
        field.lineBreakMode = .byTruncatingMiddle
        field.maximumNumberOfLines = 1
        field.cell?.usesSingleLineMode = true
        field.focusRingType = .default
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return field
    }
    func updateNSView(_ field: NSTextField, context: Context) {
        field.controlSize = .large
        field.stringValue = text
        field.toolTip = text
        field.isEnabled = context.environment.isEnabled
        field.setAccessibilityLabel(label)
    }
}

struct NativeFormatPicker: NSViewRepresentable {
    @Binding var selection: String
    let label: String
    var controlSize: NSControl.ControlSize = .regular

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NativeFormatPopUpButton(frame: .zero, pullsDown: false)
        button.controlSize = controlSize
        button.font = .systemFont(ofSize: 15)
        button.bezelStyle = .rounded
        button.autoenablesItems = false
        // The system owns the indicator, menu spacing and focus ring. AppKit's
        // fixed control glyphs do not need a second, overlapping icon layer.
        for format in AudioFormat.all {
            button.addItem(withTitle: format.name)
            button.lastItem?.representedObject = format.id
        }
        button.target = context.coordinator
        button.action = #selector(Coordinator.select(_:))
        button.setAccessibilityLabel(label)
        button.setAccessibilityIdentifier("output-format")
        return button
    }
    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.parent = self
        button.controlSize = controlSize
        if let index = AudioFormat.all.firstIndex(where: { $0.id == selection }) { button.selectItem(at: index) }
        button.isEnabled = context.environment.isEnabled
        button.setAccessibilityLabel(label)
    }
    final class Coordinator: NSObject {
        var parent: NativeFormatPicker
        init(_ parent: NativeFormatPicker) { self.parent = parent }
        @objc func select(_ sender: NSPopUpButton) {
            if let id = sender.selectedItem?.representedObject as? String { parent.selection = id }
        }
    }
}

struct NativeSourceCheckbox: NSViewRepresentable {
    @Binding var isOn: Bool
    let label: String

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSButton {
        let button = ReferenceCheckboxButton(checkboxWithTitle: label, target: context.coordinator, action: #selector(Coordinator.toggle(_:)))
        button.controlSize = .small
        button.font = .systemFont(ofSize: 12)
        button.setAccessibilityLabel("搜索音源：\(label)")
        return button
    }
    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.parent = self
        button.state = isOn ? .on : .off
        button.isEnabled = context.environment.isEnabled
        button.title = label
        button.setAccessibilityLabel("搜索音源：\(label)")
    }
    final class Coordinator: NSObject {
        var parent: NativeSourceCheckbox
        init(_ parent: NativeSourceCheckbox) { self.parent = parent }
        @objc func toggle(_ sender: NSButton) { parent.isOn = sender.state == .on }
    }
}

final class NativeFormatPopUpButton: NSPopUpButton {
    override var intrinsicContentSize: NSSize { NSSize(width: super.intrinsicContentSize.width, height: 34) }
    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsetsZero }
    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.5, dy: 1)
        let bezel = NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7)
        NSColor.controlBackgroundColor.setFill(); bezel.fill()
        NSColor.separatorColor.setStroke(); bezel.lineWidth = 1; bezel.stroke()
        let color = isEnabled ? NSColor.labelColor : NSColor.secondaryLabelColor
        let value = NSAttributedString(string: titleOfSelectedItem ?? "", attributes: [.font: font ?? NSFont.systemFont(ofSize: 15), .foregroundColor: color])
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: NSRect(x: 10, y: 0, width: max(0, bounds.width-36), height: bounds.height)).addClip()
        value.draw(at: NSPoint(x: 10, y: (bounds.height-value.size().height)/2))
        NSGraphicsContext.restoreGraphicsState()
        color.withAlphaComponent(0.65).setStroke()
        let arrow = NSBezierPath(); arrow.lineWidth = 1.5; arrow.lineCapStyle = .round; arrow.lineJoinStyle = .round
        let x=bounds.maxX-16, y=bounds.midY
        arrow.move(to: NSPoint(x:x-4,y:isFlipped ? y-2:y+2)); arrow.line(to:NSPoint(x:x,y:isFlipped ? y+2:y-2));arrow.line(to:NSPoint(x:x+4,y:isFlipped ? y-2:y+2));arrow.stroke()
    }
    override init(frame buttonFrame: NSRect, pullsDown flag: Bool) {
        super.init(frame: buttonFrame, pullsDown: flag)
        focusRingType = .default
        setContentHuggingPriority(.defaultLow, for: .horizontal)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

struct NativeIntegerField: NSViewRepresentable {
    @Binding var value: Int
    let range: ClosedRange<Int>
    var step: Int = 1
    let label: String

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NativeIntegerControl {
        let view = NativeIntegerControl()
        view.field.delegate = context.coordinator
        view.field.target = context.coordinator
        view.field.action = #selector(Coordinator.commit(_:))
        view.stepper.target = context.coordinator
        view.stepper.action = #selector(Coordinator.step(_:))
        return view
    }
    func updateNSView(_ view: NativeIntegerControl, context: Context) {
        context.coordinator.parent = self
        view.stepper.minValue = Double(range.lowerBound)
        view.stepper.maxValue = Double(range.upperBound)
        view.stepper.increment = Double(step)
        view.stepper.integerValue = value
        if view.field.currentEditor() == nil { view.field.stringValue = String(value) }
        view.field.isEnabled = context.environment.isEnabled
        view.stepper.isEnabled = context.environment.isEnabled
        view.field.setAccessibilityLabel(label)
        view.field.setAccessibilityHelp("输入 \(range.lowerBound) 至 \(range.upperBound) 之间的整数。")
        view.stepper.setAccessibilityLabel("调整\(label)")
    }
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: NativeIntegerField
        init(_ parent: NativeIntegerField) { self.parent = parent }
        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField,
                  let number = Int(field.stringValue), parent.range.contains(number) else { return }
            parent.value = number
            synchroniseStepper(for: field, value: number)
        }
        func controlTextDidEndEditing(_ notification: Notification) {
            if let field = notification.object as? NSTextField { commit(field) }
        }
        @objc func commit(_ field: NSTextField) {
            let number = Int(field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)) ?? parent.value
            let clamped = min(parent.range.upperBound, max(parent.range.lowerBound, number))
            field.stringValue = String(clamped)
            parent.value = clamped
            synchroniseStepper(for: field, value: clamped)
        }
        private func synchroniseStepper(for field: NSTextField, value: Int) {
            // A text commit and a following arrow action can share an event
            // turn, before SwiftUI renders the changed binding. Keep AppKit's
            // companion control current immediately instead of stepping from
            // the previous rendered value.
            (field.superview as? NativeIntegerControl)?.stepper.integerValue = value
        }
        @objc func step(_ sender: NSStepper) {
            // Commit the stepper immediately, including when the text field is focused.
            parent.value = sender.integerValue
            if let view = sender.superview as? NativeIntegerControl {
                view.field.stringValue = String(parent.value)
            }
        }
    }
}

final class NativeIntegerControl: NSView {
    let field = NSTextField()
    let stepper = NSStepper()
    private var stepperWidth: CGFloat { max(18, stepper.intrinsicContentSize.width) }
    private var stepperHeight: CGFloat { max(24, stepper.intrinsicContentSize.height) }
    private var fieldHeight: CGFloat { max(28, field.intrinsicContentSize.height) }
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        field.controlSize = .large
        field.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        field.alignment = .right
        field.bezelStyle = .roundedBezel
        field.focusRingType = .default
        field.lineBreakMode = .byClipping
        field.maximumNumberOfLines = 1
        stepper.controlSize = .large
        stepper.valueWraps = false
        stepper.autorepeat = true
        // Keep both hit areas inside the bridge bounds, without stack-view
        // detachment or native alignment insets shrinking the stepper.
        field.translatesAutoresizingMaskIntoConstraints = false
        stepper.translatesAutoresizingMaskIntoConstraints = false
        addSubview(field)
        addSubview(stepper)
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: leadingAnchor),
            field.trailingAnchor.constraint(equalTo: stepper.leadingAnchor, constant: -6),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
            field.widthAnchor.constraint(greaterThanOrEqualToConstant: 62),
            field.heightAnchor.constraint(equalToConstant: fieldHeight),
            stepper.trailingAnchor.constraint(equalTo: trailingAnchor),
            stepper.centerYAnchor.constraint(equalTo: centerYAnchor),
            stepper.widthAnchor.constraint(equalToConstant: stepperWidth),
            stepper.heightAnchor.constraint(equalToConstant: stepperHeight),
        ])
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var intrinsicContentSize: NSSize { NSSize(width: max(94, 68 + stepperWidth), height: max(fieldHeight, stepperHeight)) }
}

@MainActor private enum NativeControlIconCache {
    static var images: [String: NSImage] = [:]
}

@MainActor func nativeControlImage(_ name: String, size: CGFloat) -> NSImage? {
    let key = "\(name):\(size)"
    if let image = NativeControlIconCache.images[key] { return image }
    guard let url = Bundle.module.resourceURL?.appendingPathComponent("Resources/Tabler/\(name).png"),
          let image = NSImage(contentsOf: url) else { return nil }
    image.size = NSSize(width: size, height: size)
    image.isTemplate = true
    NativeControlIconCache.images[key] = image
    return image
}
