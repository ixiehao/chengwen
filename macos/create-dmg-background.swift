import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "dmg-background.png")
let canvasSize = NSSize(width: 960, height: 600)
guard let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: Int(canvasSize.width),
    pixelsHigh: Int(canvasSize.height),
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
), let graphics = NSGraphicsContext(bitmapImageRep: bitmap) else {
    fatalError("Could not create DMG background context.")
}

bitmap.size = canvasSize
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = graphics
graphics.imageInterpolation = .high

func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(calibratedRed: red, green: green, blue: blue, alpha: alpha)
}

func drawCentered(_ value: String, y: CGFloat, font: NSFont, textColor: NSColor) {
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    paragraph.lineBreakMode = .byTruncatingTail
    NSAttributedString(string: value, attributes: [
        .font: font,
        .foregroundColor: textColor,
        .paragraphStyle: paragraph
    ]).draw(in: NSRect(x: 56, y: y, width: 848, height: font.pointSize * 1.5))
}

let canvas = NSRect(origin: .zero, size: canvasSize)
color(0.91, 0.95, 1.0).setFill()
NSBezierPath(rect: canvas).fill()

// The complete canvas is deliberately tinted. This makes the installation
// surface read as one composed background instead of a white Finder window
// with a small, detached blue panel in the middle.
let fullSurface = NSGradient(colors: [
    color(0.94, 0.975, 1.0),
    color(0.87, 0.93, 1.0)
])!
fullSurface.draw(in: canvas, angle: 270)

let centerGlow = NSGradient(colors: [
    color(0.72, 0.84, 1.0, 0.48),
    color(0.72, 0.84, 1.0, 0)
])!
centerGlow.draw(
    fromCenter: NSPoint(x: 480, y: 304),
    radius: 0,
    toCenter: NSPoint(x: 480, y: 304),
    radius: 430,
    options: [.drawsAfterEndingLocation]
)

let titleStyle: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 34, weight: .bold),
    .foregroundColor: color(0.12, 0.15, 0.21)
]
let subtitleStyle: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 15, weight: .medium),
    .foregroundColor: color(0.26, 0.37, 0.57)
]
let instructionColor = color(0.27, 0.39, 0.60)

drawCentered("澄闻", y: 500, font: titleStyle[.font] as! NSFont, textColor: titleStyle[.foregroundColor] as! NSColor)
drawCentered("音乐下载与收藏  ·  把喜欢的声音，留给自己。", y: 472, font: subtitleStyle[.font] as! NSFont, textColor: subtitleStyle[.foregroundColor] as! NSColor)

let arrow = NSBezierPath()
arrow.move(to: NSPoint(x: 394, y: 305))
arrow.line(to: NSPoint(x: 565, y: 305))
arrow.lineWidth = 5
arrow.lineCapStyle = .round
color(0.12, 0.40, 0.91, 0.86).setStroke()
arrow.stroke()
let arrowHead = NSBezierPath()
arrowHead.move(to: NSPoint(x: 565, y: 305))
arrowHead.line(to: NSPoint(x: 546, y: 317))
arrowHead.move(to: NSPoint(x: 565, y: 305))
arrowHead.line(to: NSPoint(x: 546, y: 293))
arrowHead.lineWidth = 5
arrowHead.lineCapStyle = .round
arrowHead.stroke()

drawCentered("Drag 澄闻 to Applications to install", y: 82, font: .systemFont(ofSize: 14, weight: .semibold), textColor: instructionColor)
drawCentered("将 澄闻 拖到 Applications 文件夹完成安装", y: 56, font: .systemFont(ofSize: 14, weight: .medium), textColor: instructionColor)

NSGraphicsContext.restoreGraphicsState()
guard let png = bitmap.representation(using: .png, properties: [:]) else {
    fatalError("Could not encode DMG background.")
}
try png.write(to: output)
