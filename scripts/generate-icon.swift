import AppKit
import Foundation

let destination = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .appendingPathComponent("Resources/Assets.xcassets/AppIcon.appiconset")
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
for size in [16, 32, 64, 128, 256, 512, 1024] {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                              bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                              isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let context = NSGraphicsContext.current!.cgContext
    context.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    let background = NSBezierPath(roundedRect: NSRect(x: 30, y: 30, width: 964, height: 964), xRadius: 215, yRadius: 215)
    NSGradient(starting: NSColor(calibratedRed: 0.17, green: 0.18, blue: 0.20, alpha: 1),
               ending: NSColor(calibratedRed: 0.055, green: 0.060, blue: 0.072, alpha: 1))!.draw(in: background, angle: -45)
    let disk = NSBezierPath(ovalIn: NSRect(x: 184, y: 184, width: 656, height: 656))
    NSColor(calibratedWhite: 0.04, alpha: 1).setFill(); disk.fill()
    for inset in stride(from: 210, through: 420, by: 26) {
        let groove = NSBezierPath(ovalIn: NSRect(x: inset, y: inset, width: 1024 - 2 * inset, height: 1024 - 2 * inset))
        NSColor(calibratedWhite: 0.65, alpha: 0.10).setStroke(); groove.lineWidth = 3; groove.stroke()
    }
    let center = NSBezierPath(ovalIn: NSRect(x: 405, y: 405, width: 214, height: 214))
    NSGradient(starting: NSColor(calibratedRed: 0.98, green: 0.77, blue: 0.45, alpha: 1),
               ending: NSColor(calibratedRed: 0.79, green: 0.46, blue: 0.20, alpha: 1))!.draw(in: center, angle: -90)
    let hole = NSBezierPath(ovalIn: NSRect(x: 493, y: 493, width: 38, height: 38))
    NSColor(calibratedWhite: 0.07, alpha: 1).setFill(); hole.fill()
    let needle = NSBezierPath()
    needle.move(to: NSPoint(x: 792, y: 790)); needle.line(to: NSPoint(x: 746, y: 418)); needle.line(to: NSPoint(x: 673, y: 346))
    NSColor(calibratedRed: 0.94, green: 0.76, blue: 0.49, alpha: 1).setStroke()
    needle.lineWidth = 26; needle.lineCapStyle = .round; needle.lineJoinStyle = .round; needle.stroke()
    let pivot = NSBezierPath(ovalIn: NSRect(x: 760, y: 758, width: 64, height: 64))
    NSColor(calibratedWhite: 0.8, alpha: 1).setFill(); pivot.fill()
    NSGraphicsContext.restoreGraphicsState()
    try rep.representation(using: .png, properties: [:])!.write(to: destination.appendingPathComponent("icon-\(size).png"))
}
var entries: [[String: String]] = []
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        entries.append(["idiom": "mac", "size": "\(points)x\(points)", "scale": "\(scale)x", "filename": "icon-\(points * scale).png"])
    }
}
let contents: [String: Any] = ["images": entries, "info": ["author": "xcode", "version": 1]]
try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
    .write(to: destination.appendingPathComponent("Contents.json"))
let assets: [String: Any] = ["info": ["author": "xcode", "version": 1]]
try JSONSerialization.data(withJSONObject: assets, options: [.prettyPrinted, .sortedKeys])
    .write(to: destination.deletingLastPathComponent().appendingPathComponent("Contents.json"))
print("Generated macOS app icons.")
