import AppKit
import SwiftUI

/// Approved proposal 09 “双韵”: two noteheads, two stems and one curved beam.
/// Coordinates and colors match Assets/Brand/ChengWen.svg exactly (1024 canvas).
/// The same drawing supplies the sidebar, Dock and installer icon.
enum BrandLogo {
    static func image(size: CGFloat) -> NSImage {
        let image=NSImage(size:NSSize(width:size,height:size))
        image.lockFocus()
        let context=NSGraphicsContext.current!.cgContext
        context.scaleBy(x:size/1024,y:size/1024)
        context.translateBy(x:0,y:1024)
        context.scaleBy(x:1,y:-1)
        context.saveGState()
        context.addPath(CGPath(roundedRect:CGRect(x:46,y:46,width:932,height:932),cornerWidth:210,cornerHeight:210,transform:nil))
        context.clip()
        let space=CGColorSpace(name:CGColorSpace.sRGB)!
        let colors=[CGColor(srgbRed:152.0/255,green:119.0/255,blue:1,alpha:1),CGColor(srgbRed:74.0/255,green:41.0/255,blue:194.0/255,alpha:1)]
        let gradient=CGGradient(colorsSpace:space,colors:colors as CFArray,locations:[0,1])!
        context.drawLinearGradient(gradient,start:CGPoint(x:0,y:46),end:CGPoint(x:0,y:978),options:[])
        context.restoreGState()
        context.setFillColor(CGColor(srgbRed:1,green:1,blue:1,alpha:1))
        let path0=CGMutablePath()
        path0.move(to:CGPoint(x:420,y:712))
        path0.addCurve(to:CGPoint(x:312,y:776),control1:CGPoint(x:405,y:749),control2:CGPoint(x:354,y:781))
        path0.addCurve(to:CGPoint(x:294,y:710),control1:CGPoint(x:270,y:771),control2:CGPoint(x:266,y:741))
        path0.addCurve(to:CGPoint(x:402,y:671),control1:CGPoint(x:322,y:678),control2:CGPoint(x:369,y:660))
        path0.addCurve(to:CGPoint(x:420,y:712),control1:CGPoint(x:421,y:678),control2:CGPoint(x:429,y:694))
        path0.closeSubpath()
        context.addPath(path0);context.fillPath()
        let path1=CGMutablePath()
        path1.move(to:CGPoint(x:686,y:655))
        path1.addCurve(to:CGPoint(x:578,y:719),control1:CGPoint(x:671,y:692),control2:CGPoint(x:620,y:724))
        path1.addCurve(to:CGPoint(x:560,y:653),control1:CGPoint(x:536,y:714),control2:CGPoint(x:532,y:684))
        path1.addCurve(to:CGPoint(x:668,y:614),control1:CGPoint(x:588,y:621),control2:CGPoint(x:635,y:603))
        path1.addCurve(to:CGPoint(x:686,y:655),control1:CGPoint(x:687,y:621),control2:CGPoint(x:695,y:637))
        path1.closeSubpath()
        context.addPath(path1);context.fillPath()
        let path2=CGMutablePath()
        path2.move(to:CGPoint(x:393,y:724))
        path2.addCurve(to:CGPoint(x:412,y:354),control1:CGPoint(x:402,y:605),control2:CGPoint(x:406,y:463))
        path2.addLine(to:CGPoint(x:417,y:331))
        path2.addCurve(to:CGPoint(x:443,y:329),control1:CGPoint(x:420,y:322),control2:CGPoint(x:437,y:320))
        path2.addCurve(to:CGPoint(x:446,y:362),control1:CGPoint(x:448,y:334),control2:CGPoint(x:448,y:347))
        path2.addCurve(to:CGPoint(x:427,y:705),control1:CGPoint(x:435,y:469),control2:CGPoint(x:440,y:593))
        path2.addCurve(to:CGPoint(x:396,y:738),control1:CGPoint(x:425,y:723),control2:CGPoint(x:410,y:736))
        path2.closeSubpath()
        context.addPath(path2);context.fillPath()
        let path3=CGMutablePath()
        path3.move(to:CGPoint(x:659,y:667))
        path3.addCurve(to:CGPoint(x:680,y:290),control1:CGPoint(x:667,y:550),control2:CGPoint(x:679,y:399))
        path3.addLine(to:CGPoint(x:686,y:260))
        path3.addCurve(to:CGPoint(x:717,y:262),control1:CGPoint(x:689,y:250),control2:CGPoint(x:708,y:251))
        path3.addCurve(to:CGPoint(x:719,y:295),control1:CGPoint(x:721,y:269),control2:CGPoint(x:721,y:281))
        path3.addCurve(to:CGPoint(x:693,y:648),control1:CGPoint(x:709,y:405),control2:CGPoint(x:705,y:535))
        path3.addCurve(to:CGPoint(x:664,y:681),control1:CGPoint(x:691,y:667),control2:CGPoint(x:678,y:679))
        path3.closeSubpath()
        context.addPath(path3);context.fillPath()
        let path4=CGMutablePath()
        path4.move(to:CGPoint(x:420,y:330))
        path4.addCurve(to:CGPoint(x:687,y:261),control1:CGPoint(x:509,y:314),control2:CGPoint(x:598,y:284))
        path4.addCurve(to:CGPoint(x:718,y:283),control1:CGPoint(x:705,y:256),control2:CGPoint(x:718,y:266))
        path4.addLine(to:CGPoint(x:715,y:315))
        path4.addCurve(to:CGPoint(x:424,y:386),control1:CGPoint(x:622,y:338),control2:CGPoint(x:532,y:366))
        path4.closeSubpath()
        context.addPath(path4);context.fillPath()
        image.unlockFocus()
        return image
    }
}

struct BrandLogoView: View {
    var body: some View {
        Image(nsImage:BrandLogo.image(size:128)).resizable().aspectRatio(contentMode:.fit)
            .accessibilityHidden(true)
    }
}
