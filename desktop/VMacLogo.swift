// Renders VMac's mark and app icon from the otter master.
// Usage: render-logo <output directory> [master.png]
import Cocoa

let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let masterPath = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "assets/branding/vmac-otter.png"
let master: NSImage = {
    guard let image = NSImage(contentsOfFile: masterPath) else { fatalError("Cannot load the mark: \(masterPath)") }
    return image
}()
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

final class MarkView: NSView {
    override func draw(_ dirtyRect: NSRect) { master.draw(in: bounds) }
}
let view = MarkView(frame: NSRect(x: 0, y: 0, width: 1024, height: 1024))
try view.dataWithPDF(inside: view.bounds).write(to: output.appendingPathComponent("VMacMark.pdf"))

func png(_ size: Int, appIcon: Bool) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    let scale = NSAffineTransform(); scale.scale(by: CGFloat(size) / 1024); scale.concat()
    var mark = NSRect(x: 0, y: 0, width: 1024, height: 1024)
    if appIcon {
        // White tile with a hairline so it keeps its shape on white backgrounds.
        let tile = NSBezierPath(roundedRect: NSRect(x: 60, y: 60, width: 904, height: 904), xRadius: 210, yRadius: 210)
        NSColor.white.setFill(); tile.fill()
        NSColor(white: 0, alpha: 0.08).setStroke(); tile.lineWidth = 2; tile.stroke()
        mark = NSRect(x: 132, y: 132, width: 760, height: 760)
    }
    master.draw(in: mark)
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}
try png(1024, appIcon: false).write(to: output.appendingPathComponent("VMacMark.png"))
try png(1024, appIcon: true).write(to: output.appendingPathComponent("VMacAppIcon.png"))
let iconset = output.appendingPathComponent("VMac.iconset", isDirectory: true)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for (name, size) in [("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64), ("icon_128x128", 128),
                     ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512), ("icon_512x512", 512), ("icon_512x512@2x", 1024)] {
    try png(size, appIcon: true).write(to: iconset.appendingPathComponent(name + ".png"))
}

// ICNS is a container of native PNG representations; no raster processing here.
func length(_ value: Int) -> Data { var big = UInt32(value).bigEndian; return withUnsafeBytes(of: &big) { Data($0) } }
var chunks = Data()
for (kind, name) in [("icp4", "icon_16x16"), ("icp5", "icon_32x32"), ("icp6", "icon_32x32@2x"), ("ic07", "icon_128x128"),
                     ("ic08", "icon_256x256"), ("ic09", "icon_512x512"), ("ic10", "icon_512x512@2x"),
                     ("ic11", "icon_16x16@2x"), ("ic12", "icon_32x32@2x"), ("ic13", "icon_128x128@2x"), ("ic14", "icon_256x256@2x")] {
    let data = try Data(contentsOf: iconset.appendingPathComponent(name + ".png"))
    chunks.append(kind.data(using: .ascii)!); chunks.append(length(data.count + 8)); chunks.append(data)
}
var icon = Data("icns".utf8); icon.append(length(chunks.count + 8)); icon.append(chunks)
try icon.write(to: output.appendingPathComponent("VMac.icns"))
