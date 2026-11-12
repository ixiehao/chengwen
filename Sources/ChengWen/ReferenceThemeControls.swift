import AppKit
import SwiftUI

/// Shared presentation; all actions, focus and accessibility still belong to
/// NSButton / SwiftUI Button rather than gesture-only decorations.
struct ReferenceButtonStyle: ButtonStyle {
    var primary = false
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 15, weight: .medium))
            .padding(.horizontal, 14).frame(minHeight: 32)
            .foregroundColor(primary && enabled ? .white : enabled ? LibraryTheme.accent : .secondary)
            .background {
                if primary && enabled { RoundedRectangle(cornerRadius: 7).fill(LibraryTheme.primaryFill) }
                else { RoundedRectangle(cornerRadius: 7).fill(LibraryTheme.surface) }
            }
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(LibraryTheme.accent.opacity(primary ? 0 : 0.25), lineWidth: 1))
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}

struct ReferenceCheckboxStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(spacing: 9) {
                NativeTriStateCheckbox(state: configuration.isOn ? .on : .off, label: "") {}
                    .frame(width: 20, height: 20).allowsHitTesting(false).accessibilityHidden(true)
                configuration.label
            }.contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityValue(configuration.isOn ? "已选" : "未选")
    }
}

final class ReferenceCheckboxButton: NSButton {
    // The custom drawing uses the whole bounds, including the leading pixel.
    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsetsZero }
    override var intrinsicContentSize: NSSize {
        let native = super.intrinsicContentSize
        guard !title.isEmpty else { return native }
        let box = min(18, max(0, native.height - 2))
        let label = (title as NSString).size(withAttributes: [.font: font ?? NSFont.systemFont(ofSize: 14)])
        // The custom checkbox has a wider label gap than NSButtonCell. Its
        // painted text and trailing pixel must remain inside the hit area.
        return NSSize(width: max(native.width, ceil(1 + box + 7 + label.width + 1)), height: native.height)
    }
    override func draw(_ dirtyRect: NSRect) {
        let size: CGFloat = min(18, bounds.height - 2)
        let box = NSRect(x: 1, y: (bounds.height-size)/2, width: size, height: size)
        let path = NSBezierPath(roundedRect: box, xRadius: 4, yRadius: 4)
        let active = state != .off
        let purple = NSColor(srgbRed: 0.35, green: 0.20, blue: 0.82, alpha: isEnabled ? 1 : 0.35)
        (active ? purple : NSColor.controlBackgroundColor).setFill(); path.fill()
        (active ? purple : NSColor.separatorColor).setStroke(); path.lineWidth = 1; path.stroke()
        if active {
            NSColor.white.setStroke()
            let mark = NSBezierPath(); mark.lineWidth = 1.8; mark.lineCapStyle = .round; mark.lineJoinStyle = .round
            if state == .mixed {
                mark.move(to: NSPoint(x: box.minX+4, y: box.midY)); mark.line(to: NSPoint(x: box.maxX-4, y: box.midY))
            } else {
                mark.move(to: NSPoint(x: box.minX+4, y: box.midY))
                mark.line(to: NSPoint(x: box.minX+7, y: isFlipped ? box.maxY-4 : box.minY+4))
                mark.line(to: NSPoint(x: box.maxX-3, y: isFlipped ? box.minY+4 : box.maxY-4))
            }
            mark.stroke()
        }
        if !title.isEmpty {
            let attributes: [NSAttributedString.Key: Any] = [.font: font ?? NSFont.systemFont(ofSize: 14), .foregroundColor: isEnabled ? NSColor.labelColor : NSColor.disabledControlTextColor]
            let text = NSAttributedString(string: title, attributes: attributes)
            text.draw(at: NSPoint(x: box.maxX+7, y: (bounds.height-text.size().height)/2))
        }
    }
}

final class ReferenceActionButton: NSButton {
    var primary = false
    var controlHeight: CGFloat = 28
    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsetsZero }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: controlHeight) }
    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.5, dy: 1)
        let path = NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7)
        let purple = NSColor(srgbRed: 0.35, green: 0.20, blue: 0.82, alpha: 1)
        let fill = primary ? purple.withAlphaComponent(isEnabled ? 1 : 0.08) : NSColor.controlBackgroundColor
        fill.setFill(); path.fill()
        (primary ? purple.withAlphaComponent(isEnabled ? 1 : 0.15) : NSColor.separatorColor).setStroke(); path.lineWidth = 1; path.stroke()
        let color = !isEnabled ? NSColor.secondaryLabelColor : primary ? .white : .labelColor
        let text = NSAttributedString(string: title, attributes: [.font: font ?? NSFont.systemFont(ofSize: 14), .foregroundColor: color])
        let imageWidth: CGFloat = image == nil ? 0 : 20
        let x = max(4, (bounds.width-text.size().width-imageWidth)/2)
        if let image = image {
            let copy = image.copy() as! NSImage
            copy.lockFocus()
            color.setFill()
            NSRect(origin: .zero, size: copy.size).fill(using: .sourceAtop)
            copy.unlockFocus()
            copy.isTemplate = false
            NSGraphicsContext.saveGraphicsState()
            copy.draw(in: NSRect(x:x, y:(bounds.height-14)/2, width:14, height:14), from:.zero, operation:.sourceOver, fraction:isEnabled ? 1:0.4, respectFlipped:true, hints:nil)
            NSGraphicsContext.restoreGraphicsState()
        }
        text.draw(at:NSPoint(x:x+imageWidth, y:(bounds.height-text.size().height)/2))
        if isHighlighted { NSColor.black.withAlphaComponent(0.06).setFill(); path.fill() }
    }
}

struct SidebarWaves: Shape {
    var secondary = false
    func path(in rect: CGRect) -> Path {
        Path { p in
            if secondary {
                p.move(to: CGPoint(x: 0, y: rect.height * 0.87))
                p.addCurve(to: CGPoint(x: rect.width, y: rect.height * 0.92), control1: CGPoint(x: rect.width * 0.48, y: rect.height * 0.82), control2: CGPoint(x: rect.width * 0.55, y: rect.height * 0.97))
            } else {
                p.move(to: CGPoint(x: 0, y: rect.height * 0.84))
                p.addCurve(to: CGPoint(x: rect.width, y: rect.height * 0.82), control1: CGPoint(x: rect.width * 0.45, y: rect.height * 0.9), control2: CGPoint(x: rect.width * 0.55, y: rect.height * 0.76))
            }
            p.addLine(to: CGPoint(x: rect.width, y: rect.height))
            p.addLine(to: CGPoint(x: 0, y: rect.height)); p.closeSubpath()
        }
    }
}
