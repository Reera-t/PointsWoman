// Original vector artwork rendered with AppKit, not a stock symbol or downloaded asset.
import AppKit

guard CommandLine.arguments.count == 3 else { fatalError("Usage: make-icon.swift iconset-directory preview.png") }
let destination = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

func render(_ side: Int) -> Data {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
                                 samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                 bytesPerRow: 0, bitsPerPixel: 0)!
    let context = NSGraphicsContext(bitmapImageRep: bitmap)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.cgContext.scaleBy(x: CGFloat(side) / 1024, y: CGFloat(side) / 1024)
    context.cgContext.setAllowsAntialiasing(true)
    let tile = NSBezierPath(roundedRect: NSRect(x: 70, y: 70, width: 884, height: 884), xRadius: 200, yRadius: 200)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow(); shadow.shadowColor = NSColor.black.withAlphaComponent(0.30)
    shadow.shadowBlurRadius = 30; shadow.shadowOffset = NSSize(width: 0, height: -12); shadow.set()
    NSColor(calibratedRed: 0.16, green: 0.08, blue: 0.26, alpha: 1).setFill(); tile.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(colors: [NSColor(calibratedRed: 0.10, green: 0.07, blue: 0.20, alpha: 1),
                        NSColor(calibratedRed: 0.31, green: 0.14, blue: 0.54, alpha: 1)])!.draw(in: tile, angle: 75)
    NSColor.white.withAlphaComponent(0.10).setStroke(); tile.lineWidth = 3; tile.stroke()

    // One origin, two deliberate routes. Bright branches stay legible at Dock/menu sizes.
    let stem = NSBezierPath()
    stem.move(to: NSPoint(x: 512, y: 275)); stem.line(to: NSPoint(x: 512, y: 425))
    stem.lineWidth = 64; stem.lineCapStyle = .round
    NSColor(calibratedWhite: 0.96, alpha: 1).setStroke(); stem.stroke()
    func route(_ x: CGFloat, color: NSColor) {
        let route = NSBezierPath()
        route.move(to: NSPoint(x: 512, y: 406))
        route.curve(to: NSPoint(x: x, y: 650), controlPoint1: NSPoint(x: 512, y: 534), controlPoint2: NSPoint(x: x, y: 510))
        route.lineWidth = 64; route.lineCapStyle = .round; color.setStroke(); route.stroke()
        let arrow = NSBezierPath()
        arrow.move(to: NSPoint(x: x, y: 752))
        arrow.line(to: NSPoint(x: x - 88, y: 645)); arrow.line(to: NSPoint(x: x + 88, y: 645)); arrow.close()
        color.setFill(); arrow.fill()
    }
    route(302, color: NSColor(calibratedRed: 0.28, green: 0.91, blue: 0.82, alpha: 1))
    route(722, color: NSColor(calibratedRed: 0.91, green: 0.45, blue: 0.96, alpha: 1))
    let origin = NSBezierPath(ovalIn: NSRect(x: 466, y: 230, width: 92, height: 92))
    NSColor.white.setFill(); origin.fill()
    NSGraphicsContext.restoreGraphicsState()
    return bitmap.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try render(base).write(to: destination.appendingPathComponent("icon_\(base)x\(base).png"))
    try render(base * 2).write(to: destination.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
try render(1024).write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
