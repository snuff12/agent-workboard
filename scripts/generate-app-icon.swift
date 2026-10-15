import AppKit
import Foundation

guard CommandLine.arguments.count == 2 else { fatalError("Usage: generate-app-icon.swift iconset-folder") }
let folder = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

func drawIcon(size: Int) throws -> Data {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let scale = CGFloat(size) / 1024
    let transform = NSAffineTransform()
    transform.scale(by: scale)
    transform.concat()
    NSColor.clear.setFill()
    NSRect(x: 0, y: 0, width: 1024, height: 1024).fill()
    let base = NSBezierPath(roundedRect: NSRect(x: 72, y: 72, width: 880, height: 880),
        xRadius: 198, yRadius: 198)
    NSGradient(starting: NSColor(srgbRed: 0.18, green: 0.23, blue: 0.40, alpha: 1),
        ending: NSColor(srgbRed: 0.10, green: 0.13, blue: 0.24, alpha: 1))!.draw(in: base, angle: -60)
    let colors = [NSColor(srgbRed: 0.41, green: 0.58, blue: 1, alpha: 1),
        NSColor(srgbRed: 0.37, green: 0.77, blue: 0.68, alpha: 1),
        NSColor(srgbRed: 0.76, green: 0.64, blue: 1, alpha: 1)]
    for column in 0..<3 {
        let x = CGFloat(192 + column * 224)
        colors[column].setFill()
        NSBezierPath(roundedRect: NSRect(x: x, y: 676, width: 164, height: 32), xRadius: 16, yRadius: 16).fill()
        for row in 0..<(column == 1 ? 1 : 2) {
            NSColor.white.withAlphaComponent(row == 0 ? 0.93 : 0.50).setFill()
            NSBezierPath(roundedRect: NSRect(x: x, y: CGFloat(484 - row * 168), width: 164, height: 128),
                xRadius: 24, yRadius: 24).fill()
            colors[column].withAlphaComponent(0.7).setFill()
            NSBezierPath(roundedRect: NSRect(x: x + 24, y: CGFloat(560 - row * 168), width: 82, height: 10),
                xRadius: 5, yRadius: 5).fill()
        }
    }
    NSGraphicsContext.restoreGraphicsState()
    return bitmap.representation(using: .png, properties: [:])!
}

for points in [16, 32, 128, 256, 512] {
    try drawIcon(size: points).write(to: folder.appendingPathComponent("icon_\(points)x\(points).png"))
    try drawIcon(size: points * 2).write(to: folder.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}
