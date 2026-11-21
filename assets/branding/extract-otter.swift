// Turns the supplied blue-on-white otter drawing into a square master with a
// transparent background, white kept inside the animal and the blue set to
// the brand color. Usage: extract <source.png> <master.png>
import Cocoa

let arguments = CommandLine.arguments
guard arguments.count == 3, let image = NSImage(contentsOfFile: arguments[1])?.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    fatalError("usage: extract <source.png> <master.png>")
}
let width = image.width, height = image.height
var pixels = [UInt8](repeating: 0, count: width * height * 4)
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let info = CGImageAlphaInfo.premultipliedLast.rawValue
pixels.withUnsafeMutableBytes { buffer in
    let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: space, bitmapInfo: info)!
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
}

// Red separates the two inks best: about 255 on white, low on the blue.
var histogram = [Int](repeating: 0, count: 256)
for index in 0..<(width * height) { histogram[Int(pixels[index * 4])] += 1 }
let inkRed = (0..<128).max { histogram[$0] < histogram[$1] }!
let paperRed = (128..<256).max { histogram[$0] < histogram[$1] }!
var coverage = [Double](repeating: 0, count: width * height)
for index in 0..<(width * height) {
    coverage[index] = min(1, max(0, Double(paperRed - Int(pixels[index * 4])) / Double(paperRed - inkRed)))
}

// Paper reachable from the border is background; paper inside the animal
// stays white. The drawing separates its parts with thin white lines that run
// out to the background, so the fill first treats ink as `reach` pixels wider
// to seal those lines, then grows back over plain paper by the same amount.
let reach = 9
var blocked = coverage.map { $0 >= 0.5 }
for _ in 0..<reach {
    var next = blocked
    for y in 1..<(height - 1) { for x in 1..<(width - 1) where !blocked[y * width + x] {
        let index = y * width + x
        if blocked[index - 1] || blocked[index + 1] || blocked[index - width] || blocked[index + width] ||
            blocked[index - width - 1] || blocked[index - width + 1] || blocked[index + width - 1] || blocked[index + width + 1] { next[index] = true }
    } }
    blocked = next
}
var outside = [Bool](repeating: false, count: width * height)
var stack: [Int] = []
func visit(_ x: Int, _ y: Int) {
    guard x >= 0, y >= 0, x < width, y < height else { return }
    let index = y * width + x
    if !outside[index] && !blocked[index] { outside[index] = true; stack.append(index) }
}
for x in 0..<width { visit(x, 0); visit(x, height - 1) }
for y in 0..<height { visit(0, y); visit(width - 1, y) }
while let index = stack.popLast() {
    let x = index % width, y = index / width
    visit(x + 1, y); visit(x - 1, y); visit(x, y + 1); visit(x, y - 1)
}
for _ in 0..<(reach + 2) {
    var next = outside
    for y in 1..<(height - 1) { for x in 1..<(width - 1) where !outside[y * width + x] && coverage[y * width + x] < 0.5 {
        let index = y * width + x
        if outside[index - 1] || outside[index + 1] || outside[index - width] || outside[index + width] ||
            outside[index - width - 1] || outside[index - width + 1] || outside[index + width - 1] || outside[index + width + 1] { next[index] = true }
    } }
    outside = next
}
// The antialiased rim next to the background fades out instead of turning white.
var rim = outside
for _ in 0..<2 {
    var next = rim
    for y in 1..<(height - 1) { for x in 1..<(width - 1) where !rim[y * width + x] {
        let index = y * width + x
        if rim[index - 1] || rim[index + 1] || rim[index - width] || rim[index + width] { next[index] = true }
    } }
    rim = next
}

let brand: (Double, Double, Double) = (57, 100, 254)
var output = [UInt8](repeating: 0, count: width * height * 4)
var minX = width, minY = height, maxX = 0, maxY = 0
for y in 0..<height { for x in 0..<width {
    let index = y * width + x, ink = coverage[index]
    let alpha = rim[index] ? ink : 1
    let red = rim[index] ? brand.0 : 255 + (brand.0 - 255) * ink
    let green = rim[index] ? brand.1 : 255 + (brand.1 - 255) * ink
    let blue = rim[index] ? brand.2 : 255 + (brand.2 - 255) * ink
    output[index * 4] = UInt8((red * alpha).rounded()); output[index * 4 + 1] = UInt8((green * alpha).rounded())
    output[index * 4 + 2] = UInt8((blue * alpha).rounded()); output[index * 4 + 3] = UInt8((alpha * 255).rounded())
    if alpha > 0.02 { minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y) }
} }
let cropped = output.withUnsafeMutableBytes { buffer -> CGImage in
    let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: space, bitmapInfo: info)!
    return context.makeImage()!.cropping(to: CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1))!
}

// Centered on a square canvas with a 6% margin on the longer side.
let side = 1200, content = Double(side) * 0.88
let scale = content / Double(max(cropped.width, cropped.height))
let drawn = CGSize(width: Double(cropped.width) * scale, height: Double(cropped.height) * scale)
let canvas = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4, space: space, bitmapInfo: info)!
canvas.interpolationQuality = .high
canvas.draw(cropped, in: CGRect(x: (Double(side) - drawn.width) / 2, y: (Double(side) - drawn.height) / 2, width: drawn.width, height: drawn.height))
let representation = NSBitmapImageRep(cgImage: canvas.makeImage()!)
try representation.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: arguments[2]))
let enclosed = (0..<(width * height)).filter { !outside[$0] && coverage[$0] < 0.5 }.count
print("ink red \(inkRed), paper red \(paperRed), bounds \(minX),\(minY)-\(maxX),\(maxY), white kept inside: \(enclosed) px, background: \(outside.filter { $0 }.count) px")
