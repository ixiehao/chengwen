import SwiftUI
import AppKit

struct TablerIcon: View {
    let name:String
    var size:CGFloat=18
    init(_ name:String,size:CGFloat=18){self.name=name;self.size=size}
    init(name:String,size:CGFloat=18){self.name=name;self.size=size}
    var body: some View {
        let aliases=["trash":"x","stop":"x","player-stop":"x","chevron-left":"chevron-right"]
        let asset=aliases[name] ?? name
        let url=Bundle.module.resourceURL?.appendingPathComponent("Resources/Tabler/\(asset).png")
        if let url=url,let image=NSImage(contentsOf:url) {
            Image(nsImage:image).resizable().renderingMode(.template).aspectRatio(contentMode:.fit).frame(width:size,height:size)
        } else {
            Rectangle().stroke(lineWidth:1.5).frame(width:size-4,height:size-4).frame(width:size,height:size).accessibilityLabel(name)
        }
    }
}
