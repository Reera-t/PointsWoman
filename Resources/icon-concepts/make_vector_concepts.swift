import AppKit

func createSquircle(side: CGFloat) -> NSBezierPath {
    let padding: CGFloat = side * (70.0 / 1024.0)
    let s = side - (padding * 2)
    let r: CGFloat = s * 0.225
    return NSBezierPath(roundedRect: NSRect(x: padding, y: padding, width: s, height: s), xRadius: r, yRadius: r)
}

func renderVectorConcept1(side: Int) -> Data {
    // Concept: "Neon Rail Switch" (Enhanced High-Definition Switch with Glass Depth and Neon Rail Tracks)
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
                                  samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                  bytesPerRow: 0, bitsPerPixel: 0)!
    let context = NSGraphicsContext(bitmapImageRep: bitmap)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.cgContext.scaleBy(x: CGFloat(side) / 1024, y: CGFloat(side) / 1024)
    context.cgContext.setAllowsAntialiasing(true)

    let tile = createSquircle(side: 1024)
    
    // Drop shadow
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.4)
    shadow.shadowBlurRadius = 36
    shadow.shadowOffset = NSSize(width: 0, height: -18)
    shadow.set()
    NSColor(calibratedRed: 0.08, green: 0.08, blue: 0.12, alpha: 1).setFill()
    tile.fill()
    NSGraphicsContext.restoreGraphicsState()

    // Base background gradient: Deep Midnight Obsidian to Charcoal
    let bgGradient = NSGradient(colors: [
        NSColor(calibratedRed: 0.07, green: 0.06, blue: 0.14, alpha: 1.0),
        NSColor(calibratedRed: 0.15, green: 0.12, blue: 0.25, alpha: 1.0)
    ])!
    bgGradient.draw(in: tile, angle: 75)

    // Inner subtle grid/track texture
    let gridPath = NSBezierPath()
    for y in stride(from: 150, to: 850, by: 70) {
        gridPath.move(to: NSPoint(x: 150, y: CGFloat(y)))
        gridPath.line(to: NSPoint(x: 874, y: CGFloat(y)))
    }
    NSColor(white: 1.0, alpha: 0.03).setStroke()
    gridPath.lineWidth = 1.5
    gridPath.stroke()

    // Outer frosted border
    NSColor(white: 1.0, alpha: 0.14).setStroke()
    tile.lineWidth = 3
    tile.stroke()

    // Glow effect behind the tracks
    func drawGlow(path: NSBezierPath, color: NSColor, width: CGFloat) {
        NSGraphicsContext.saveGraphicsState()
        color.withAlphaComponent(0.25).setStroke()
        path.lineWidth = width * 2.2
        path.stroke()
        color.withAlphaComponent(0.5).setStroke()
        path.lineWidth = width * 1.4
        path.stroke()
        NSGraphicsContext.restoreGraphicsState()
    }

    // Stem path
    let stem = NSBezierPath()
    stem.move(to: NSPoint(x: 512, y: 220))
    stem.line(to: NSPoint(x: 512, y: 440))
    stem.lineWidth = 52
    stem.lineCapStyle = .round

    // Left branch: Electric Cyan (Direct Physical Bypass)
    let leftBranch = NSBezierPath()
    leftBranch.move(to: NSPoint(x: 512, y: 420))
    leftBranch.curve(to: NSPoint(x: 310, y: 710), controlPoint1: NSPoint(x: 512, y: 560), controlPoint2: NSPoint(x: 310, y: 560))
    leftBranch.lineWidth = 52
    leftBranch.lineCapStyle = .round

    // Right branch: Violet/Indigo (VPN Tunnel)
    let rightBranch = NSBezierPath()
    rightBranch.move(to: NSPoint(x: 512, y: 420))
    rightBranch.curve(to: NSPoint(x: 714, y: 710), controlPoint1: NSPoint(x: 512, y: 560), controlPoint2: NSPoint(x: 714, y: 560))
    rightBranch.lineWidth = 52
    rightBranch.lineCapStyle = .round

    let cyan = NSColor(calibratedRed: 0.0, green: 0.94, blue: 0.86, alpha: 1.0)
    let purple = NSColor(calibratedRed: 0.72, green: 0.35, blue: 0.98, alpha: 1.0)

    drawGlow(path: leftBranch, color: cyan, width: 52)
    drawGlow(path: rightBranch, color: purple, width: 52)

    // Stem drawing
    NSColor(white: 0.95, alpha: 1.0).setStroke()
    stem.stroke()

    // Left track stroke
    cyan.setStroke()
    leftBranch.stroke()

    // Right track stroke
    purple.setStroke()
    rightBranch.stroke()

    // Arrow heads
    func drawArrow(at point: NSPoint, angle: CGFloat, color: NSColor) {
        NSGraphicsContext.saveGraphicsState()
        let t = NSAffineTransform()
        t.translateX(by: point.x, yBy: point.y)
        t.rotate(byDegrees: angle)
        t.concat()
        let arrow = NSBezierPath()
        arrow.move(to: NSPoint(x: 0, y: 70))
        arrow.line(to: NSPoint(x: -60, y: -20))
        arrow.line(to: NSPoint(x: 60, y: -20))
        arrow.close()
        color.setFill()
        arrow.fill()
        NSGraphicsContext.restoreGraphicsState()
    }
    drawArrow(at: NSPoint(x: 310, y: 710), angle: 0, color: cyan)
    drawArrow(at: NSPoint(x: 714, y: 710), angle: 0, color: purple)

    // Mechanical Switch Lever / Indicator Disc at Junction
    let switchRing = NSBezierPath(ovalIn: NSRect(x: 462, y: 395, width: 100, height: 100))
    NSColor(calibratedRed: 0.15, green: 0.15, blue: 0.22, alpha: 1.0).setFill()
    switchRing.fill()
    NSColor(white: 1.0, alpha: 0.3).setStroke()
    switchRing.lineWidth = 4
    switchRing.stroke()

    let switchCenter = NSBezierPath(ovalIn: NSRect(x: 487, y: 420, width: 50, height: 50))
    cyan.setFill()
    switchCenter.fill()

    // Origin Base Disc
    let originRing = NSBezierPath(ovalIn: NSRect(x: 472, y: 180, width: 80, height: 80))
    NSColor.white.setFill()
    originRing.fill()

    NSGraphicsContext.restoreGraphicsState()
    return bitmap.representation(using: .png, properties: [:])!
}

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
let data1 = renderVectorConcept1(side: 1024)
try data1.write(to: URL(fileURLWithPath: "\(outDir)/vector_concept1_neon_switch.png"))
print("Generated vector concept 1")
