// Draws the app icon and writes Resources/AppIcon.icns. Run: swift scripts/make-icon.swift
import AppKit

func draw(_ size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = size / 1024
    let tile = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    NSGradient(colors: [NSColor(calibratedRed: 0.13, green: 0.14, blue: 0.18, alpha: 1),
                        NSColor(calibratedRed: 0.05, green: 0.05, blue: 0.07, alpha: 1)])!
        .draw(in: NSBezierPath(roundedRect: tile, xRadius: 185 * s, yRadius: 185 * s), angle: -90)

    // Gold frame with a landscape inside.
    let frame = NSRect(x: 222 * s, y: 300 * s, width: 580 * s, height: 424 * s)
    NSColor(calibratedRed: 0.84, green: 0.64, blue: 0.36, alpha: 1).setFill()
    NSBezierPath(roundedRect: frame, xRadius: 10 * s, yRadius: 10 * s).fill()
    let art = frame.insetBy(dx: 30 * s, dy: 30 * s)
    NSGradient(colors: [NSColor(calibratedRed: 0.99, green: 0.62, blue: 0.40, alpha: 1),
                        NSColor(calibratedRed: 0.30, green: 0.36, blue: 0.80, alpha: 1)])!.draw(in: art, angle: 90)
    NSColor(calibratedRed: 1, green: 0.93, blue: 0.75, alpha: 1).setFill()
    NSBezierPath(ovalIn: NSRect(x: art.midX + 40 * s, y: art.minY + 170 * s, width: 90 * s, height: 90 * s)).fill()
    let hills = NSBezierPath()
    hills.move(to: NSPoint(x: art.minX, y: art.minY))
    hills.line(to: NSPoint(x: art.minX, y: art.minY + 110 * s))
    hills.curve(to: NSPoint(x: art.maxX, y: art.minY + 80 * s),
                controlPoint1: NSPoint(x: art.minX + 180 * s, y: art.minY + 230 * s),
                controlPoint2: NSPoint(x: art.minX + 330 * s, y: art.minY + 10 * s))
    hills.line(to: NSPoint(x: art.maxX, y: art.minY))
    hills.close()
    NSColor(calibratedRed: 0.10, green: 0.16, blue: 0.30, alpha: 1).setFill()
    hills.fill()

    // Thin stand line, like a TV on the wall.
    NSColor(white: 1, alpha: 0.25).setFill()
    NSBezierPath(roundedRect: NSRect(x: 412 * s, y: 236 * s, width: 200 * s, height: 14 * s), xRadius: 7 * s, yRadius: 7 * s).fill()
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try draw(CGFloat(base * scale)).representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent(name))
    }
}
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", root.appendingPathComponent("Resources/AppIcon.icns").path]
try task.run()
task.waitUntilExit()
print(task.terminationStatus == 0 ? "wrote Resources/AppIcon.icns" : "iconutil failed")
