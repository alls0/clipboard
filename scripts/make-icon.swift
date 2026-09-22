import AppKit
import Foundation

// Draw at a shared logical size so every icon resolution remains crisp.
func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat) -> NSColor {
    NSColor(srgbRed: red / 255, green: green / 255, blue: blue / 255, alpha: 1)
}

func rounded(_ rect: NSRect, radius: CGFloat, fill: NSColor) {
    fill.setFill()
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
}

func drawIcon(size: Int) throws -> Data {
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: size,
        pixelsHigh: size,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
        throw NSError(domain: "PanoIcon", code: 1, userInfo: [NSLocalizedDescriptionKey: "Simge çizim alanı oluşturulamadı."])
    }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.cgContext.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    context.imageInterpolation = .high

    let background = NSBezierPath(roundedRect: NSRect(x: 80, y: 80, width: 864, height: 864), xRadius: 192, yRadius: 192)
    NSGradient(starting: color(31, 64, 51), ending: color(62, 105, 81))?.draw(in: background, angle: 55)

    rounded(NSRect(x: 239, y: 195, width: 478, height: 578), radius: 57, fill: color(22, 48, 38).withAlphaComponent(0.27))
    rounded(NSRect(x: 256, y: 225, width: 478, height: 578), radius: 57, fill: color(193, 206, 177))
    rounded(NSRect(x: 295, y: 265, width: 478, height: 578), radius: 57, fill: color(249, 243, 226))

    rounded(NSRect(x: 421, y: 763, width: 226, height: 103), radius: 31, fill: color(29, 62, 49).withAlphaComponent(0.16))
    rounded(NSRect(x: 411, y: 776, width: 226, height: 103), radius: 31, fill: color(217, 184, 117))
    rounded(NSRect(x: 470, y: 819, width: 108, height: 20), radius: 10, fill: color(105, 98, 66))

    let ink = color(57, 91, 72)
    rounded(NSRect(x: 374, y: 656, width: 314, height: 30), radius: 15, fill: ink)
    rounded(NSRect(x: 374, y: 571, width: 256, height: 30), radius: 15, fill: ink.withAlphaComponent(0.68))
    rounded(NSRect(x: 374, y: 486, width: 184, height: 30), radius: 15, fill: ink.withAlphaComponent(0.45))

    let badge = NSBezierPath(ovalIn: NSRect(x: 573, y: 213, width: 231, height: 231))
    color(217, 184, 117).setFill()
    badge.fill()
    let tick = NSBezierPath()
    tick.move(to: NSPoint(x: 632, y: 331))
    tick.line(to: NSPoint(x: 673, y: 290))
    tick.line(to: NSPoint(x: 748, y: 370))
    tick.lineWidth = 25
    tick.lineCapStyle = .round
    tick.lineJoinStyle = .round
    color(34, 67, 51).setStroke()
    tick.stroke()

    NSGraphicsContext.restoreGraphicsState()
    guard let data = bitmap.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "PanoIcon", code: 2, userInfo: [NSLocalizedDescriptionKey: "Simge PNG olarak kaydedilemedi."])
    }
    return data
}

guard CommandLine.arguments.count == 3 else {
    fputs("Kullanım: swift make-icon.swift <hedef.iconset> <hedef.icns>\n", stderr)
    exit(1)
}

func encodedLength(_ value: Int) -> Data {
    var bigEndian = UInt32(value).bigEndian
    return withUnsafeBytes(of: &bigEndian) { Data($0) }
}

let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
// Modern ICNS entries embed PNG data. Write the container directly so building
// the app does not need a separate icon conversion step.
let entries: [(points: Int, scale: Int, type: String)] = [
    (16, 1, "icp4"), (16, 2, "ic11"),
    (32, 1, "icp5"), (32, 2, "ic12"),
    (128, 1, "ic07"), (128, 2, "ic13"),
    (256, 1, "ic08"), (256, 2, "ic14"),
    (512, 1, "ic09"), (512, 2, "ic10")
]
var payload = Data()
for entry in entries {
    let suffix = entry.scale == 2 ? "@2x" : ""
    let path = output.appendingPathComponent("icon_\(entry.points)x\(entry.points)\(suffix).png")
    let png = try drawIcon(size: entry.points * entry.scale)
    try png.write(to: path)
    payload.append(Data(entry.type.utf8))
    payload.append(encodedLength(png.count + 8))
    payload.append(png)
}
var icns = Data("icns".utf8)
icns.append(encodedLength(payload.count + 8))
icns.append(payload)
try icns.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
