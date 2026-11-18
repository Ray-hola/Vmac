// Vector master export for VMac. Geometry mirrors assets/branding/vmac-mark.svg.
import Cocoa
let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
func mark() -> NSBezierPath {
    let p=NSBezierPath();p.windingRule = .evenOdd
    p.move(to:NSPoint(x:232,y:80));p.line(to:NSPoint(x:792,y:80))
    p.curve(to:NSPoint(x:944,y:232),controlPoint1:NSPoint(x:893.33,y:80),controlPoint2:NSPoint(x:944,y:130.67))
    p.line(to:NSPoint(x:944,y:792));p.curve(to:NSPoint(x:792,y:944),controlPoint1:NSPoint(x:944,y:893.33),controlPoint2:NSPoint(x:893.33,y:944))
    p.line(to:NSPoint(x:232,y:944));p.curve(to:NSPoint(x:80,y:792),controlPoint1:NSPoint(x:130.67,y:944),controlPoint2:NSPoint(x:80,y:893.33))
    p.line(to:NSPoint(x:80,y:232));p.curve(to:NSPoint(x:232,y:80),controlPoint1:NSPoint(x:80,y:130.67),controlPoint2:NSPoint(x:130.67,y:80));p.close()
    for x in [208,320,432] { p.appendOval(in:NSRect(x:x-32,y:192,width:64,height:64)) }
    p.move(to:NSPoint(x:168,y:332));p.line(to:NSPoint(x:320,y:332))
    p.curve(to:NSPoint(x:342,y:346),controlPoint1:NSPoint(x:329.33,y:332),controlPoint2:NSPoint(x:336.67,y:336.67))
    p.line(to:NSPoint(x:502,y:624));p.curve(to:NSPoint(x:522,y:624),controlPoint1:NSPoint(x:508.67,y:636),controlPoint2:NSPoint(x:515.33,y:636))
    p.line(to:NSPoint(x:682,y:346));p.curve(to:NSPoint(x:704,y:332),controlPoint1:NSPoint(x:687.33,y:336.67),controlPoint2:NSPoint(x:694.67,y:332))
    p.line(to:NSPoint(x:856,y:332));p.curve(to:NSPoint(x:866,y:350),controlPoint1:NSPoint(x:869.33,y:332),controlPoint2:NSPoint(x:872.67,y:338))
    p.line(to:NSPoint(x:598,y:834));p.curve(to:NSPoint(x:574,y:848),controlPoint1:NSPoint(x:592.67,y:843.33),controlPoint2:NSPoint(x:584.67,y:848))
    p.line(to:NSPoint(x:450,y:848));p.curve(to:NSPoint(x:426,y:834),controlPoint1:NSPoint(x:439.33,y:848),controlPoint2:NSPoint(x:431.33,y:843.33))
    p.line(to:NSPoint(x:158,y:350));p.curve(to:NSPoint(x:168,y:332),controlPoint1:NSPoint(x:151.33,y:338),controlPoint2:NSPoint(x:154.67,y:332));p.close()
    return p
}
let terracotta=NSColor(srgbRed:166/255,green:77/255,blue:47/255,alpha:1)
func drawMark() { terracotta.setFill();mark().fill() }
final class MarkView:NSView {
    override var isFlipped:Bool {true}
    override func draw(_ dirtyRect:NSRect) {drawMark()}
}
let view=MarkView(frame:NSRect(x:0,y:0,width:1024,height:1024))
try view.dataWithPDF(inside:view.bounds).write(to:output.appendingPathComponent("VMacMark.pdf"))
func png(_ size:Int,appIcon:Bool)->Data {
    let rep=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:size,pixelsHigh:size,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
    NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current=NSGraphicsContext(bitmapImageRep:rep)
    let t=NSAffineTransform();t.translateX(by:0,yBy:CGFloat(size));t.scaleX(by:CGFloat(size)/1024,yBy:-CGFloat(size)/1024);t.concat()
    if appIcon {
        NSColor(srgbRed:250/255,green:249/255,blue:245/255,alpha:1).setFill()
        NSBezierPath(roundedRect:NSRect(x:60,y:60,width:904,height:904),xRadius:210,yRadius:210).fill()
        let inset=NSAffineTransform();inset.translateX(by:144,yBy:144);inset.scale(by:736/1024);inset.concat()
    }
    drawMark();NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using:.png,properties:[:])!
}
try png(1024,appIcon:false).write(to:output.appendingPathComponent("VMacMark.png"))
try png(1024,appIcon:true).write(to:output.appendingPathComponent("VMacAppIcon.png"))
let iconset=output.appendingPathComponent("VMac.iconset",isDirectory:true)
try FileManager.default.createDirectory(at:iconset,withIntermediateDirectories:true)
for (name,size) in [("icon_16x16",16),("icon_16x16@2x",32),("icon_32x32",32),("icon_32x32@2x",64),("icon_128x128",128),("icon_128x128@2x",256),("icon_256x256",256),("icon_256x256@2x",512),("icon_512x512",512),("icon_512x512@2x",1024)] {
    try png(size,appIcon:true).write(to:iconset.appendingPathComponent(name+".png"))
}

// ICNS is a container of native PNG representations; no raster processing here.
func length(_ value:Int)->Data { var big=UInt32(value).bigEndian;return withUnsafeBytes(of:&big) { Data($0) } }
var chunks=Data()
for (kind,name) in [("icp4","icon_16x16"),("icp5","icon_32x32"),("icp6","icon_32x32@2x"),("ic07","icon_128x128"),("ic08","icon_256x256"),("ic09","icon_512x512"),("ic10","icon_512x512@2x"),("ic11","icon_16x16@2x"),("ic12","icon_32x32@2x"),("ic13","icon_128x128@2x"),("ic14","icon_256x256@2x")] {
    let data=try Data(contentsOf:iconset.appendingPathComponent(name+".png"))
    chunks.append(kind.data(using:.ascii)!);chunks.append(length(data.count+8));chunks.append(data)
}
var icon=Data("icns".utf8);icon.append(length(chunks.count+8));icon.append(chunks)
try icon.write(to:output.appendingPathComponent("VMac.icns"))
