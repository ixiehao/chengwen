import AppKit
import Foundation

let source = URL(fileURLWithPath: CommandLine.arguments[1])
let output = URL(fileURLWithPath: CommandLine.arguments[2])
try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
for url in try FileManager.default.contentsOfDirectory(at:source,includingPropertiesForKeys:nil) where url.pathExtension == "svg" {
    guard let image=NSImage(contentsOf:url),let bitmap=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:96,pixelsHigh:96,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0),let context=NSGraphicsContext(bitmapImageRep:bitmap) else{fatalError("Tabler asset could not be decoded")}
    NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current=context
    image.draw(in:NSRect(x:0,y:0,width:96,height:96))
    NSGraphicsContext.restoreGraphicsState()
    guard let data=bitmap.representation(using:.png,properties:[:]) else{fatalError("PNG export failed")}
    try data.write(to:output.appendingPathComponent(url.deletingPathExtension().lastPathComponent+".png"))
}
try Data(contentsOf:source.appendingPathComponent("LICENSE")).write(to:output.appendingPathComponent("LICENSE"),options:.atomic)
