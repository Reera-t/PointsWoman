// Original vector artwork rendered with AppKit: The Tactile PW Monogram (Midnight Obsidian & Cyber Cyan)
import AppKit

guard CommandLine.arguments.count == 3 else {
    fatalError("Usage: make-icon.swift iconset-directory preview.png")
}
let destination = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

func createAppleSquircle(rect: NSRect) -> NSBezierPath {
    return NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.225, yRadius: rect.height * 0.225)
}

func renderMasterIcon(side: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ctx
    let cg = ctx.cgContext
    cg.scaleBy(x: CGFloat(side) / 1024.0, y: CGFloat(side) / 1024.0)
    cg.setAllowsAntialiasing(true)
    cg.setShouldAntialias(true)

    let tileRect = NSRect(x: 92, y: 92, width: 840, height: 840)
    let squircle = createAppleSquircle(rect: tileRect)

    // --- 1. Ambient Occlusion + Contact Shadows ---
    NSGraphicsContext.saveGraphicsState()
    let deepShadow = NSShadow()
    deepShadow.shadowColor = NSColor.black.withAlphaComponent(0.45)
    deepShadow.shadowBlurRadius = 48
    deepShadow.shadowOffset = NSSize(width: 0, height: -26)
    deepShadow.set()
    NSColor(calibratedRed: 0.05, green: 0.06, blue: 0.08, alpha: 1.0).setFill()
    squircle.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.saveGraphicsState()
    let contactShadow = NSShadow()
    contactShadow.shadowColor = NSColor.black.withAlphaComponent(0.30)
    contactShadow.shadowBlurRadius = 14
    contactShadow.shadowOffset = NSSize(width: 0, height: -8)
    contactShadow.set()
    squircle.fill()
    NSGraphicsContext.restoreGraphicsState()

    // --- 2. Tile Base Material Fill (Midnight Obsidian Slate) ---
    NSGraphicsContext.saveGraphicsState()
    squircle.addClip()
    let bgGrad = NSGradient(colors: [
        NSColor(calibratedRed: 0.10, green: 0.12, blue: 0.16, alpha: 1.0),
        NSColor(calibratedRed: 0.05, green: 0.06, blue: 0.09, alpha: 1.0)
    ])!
    bgGrad.draw(in: tileRect, angle: 68)

    // Subtle radial cyan reflection on top-left of tile
    let lightRadial = NSGradient(colors: [
        NSColor(calibratedRed: 0.08, green: 0.78, blue: 0.92, alpha: 0.12),
        NSColor.clear
    ])!
    lightRadial.draw(fromCenter: NSPoint(x: 360, y: 720), radius: 20,
                     toCenter: NSPoint(x: 360, y: 720), radius: 460, options: [])

    // Subtle micro-dot routing grid
    let dotColor = NSColor(calibratedRed: 0.20, green: 0.78, blue: 0.92, alpha: 0.06)
    dotColor.setFill()
    for gx in stride(from: 220, through: 800, by: 60) {
        for gy in stride(from: 220, through: 800, by: 60) {
            let dot = NSBezierPath(ovalIn: NSRect(x: gx - 2, y: gy - 2, width: 4, height: 4))
            dot.fill()
        }
    }
    NSGraphicsContext.restoreGraphicsState()

    // --- 3. Outer Frame (Gunmetal Titanium) ---
    let frameColor = NSColor(calibratedRed: 0.18, green: 0.22, blue: 0.29, alpha: 1.0)
    frameColor.setStroke()
    squircle.lineWidth = 20
    squircle.stroke()

    // Inner Metallic Bevel Rim (Cyan Anodized Trim)
    let innerRimRect = NSRect(x: 104, y: 104, width: 816, height: 816)
    let innerRim = createAppleSquircle(rect: innerRimRect)
    let rimColor = NSColor(calibratedRed: 0.20, green: 0.78, blue: 0.92, alpha: 0.85)
    rimColor.setStroke()
    innerRim.lineWidth = 3.5
    innerRim.stroke()

    // Top Rim Specular Glint
    NSGraphicsContext.saveGraphicsState()
    squircle.addClip()
    let topGlint = NSBezierPath()
    topGlint.move(to: NSPoint(x: 200, y: 928))
    topGlint.line(to: NSPoint(x: 824, y: 928))
    NSColor.white.withAlphaComponent(0.35).setStroke()
    topGlint.lineWidth = 4
    topGlint.stroke()
    NSGraphicsContext.restoreGraphicsState()

    // --- 4. Monogram Path Geometry ---
    // P Path:
    let pPath = NSBezierPath()
    pPath.move(to: NSPoint(x: 260, y: 360))
    pPath.line(to: NSPoint(x: 260, y: 700))
    pPath.curve(to: NSPoint(x: 260, y: 500),
                controlPoint1: NSPoint(x: 550, y: 700),
                controlPoint2: NSPoint(x: 550, y: 500))
    pPath.line(to: NSPoint(x: 260, y: 500))
    pPath.lineCapStyle = .round
    pPath.lineJoinStyle = .round

    // W Path:
    let wPath = NSBezierPath()
    wPath.move(to: NSPoint(x: 260, y: 500))
    wPath.curve(to: NSPoint(x: 420, y: 300),
                controlPoint1: NSPoint(x: 320, y: 500),
                controlPoint2: NSPoint(x: 370, y: 300))
    wPath.curve(to: NSPoint(x: 540, y: 510),
                controlPoint1: NSPoint(x: 470, y: 300),
                controlPoint2: NSPoint(x: 500, y: 510))
    wPath.curve(to: NSPoint(x: 660, y: 300),
                controlPoint1: NSPoint(x: 580, y: 510),
                controlPoint2: NSPoint(x: 610, y: 300))
    wPath.curve(to: NSPoint(x: 795, y: 665),
                controlPoint1: NSPoint(x: 710, y: 300),
                controlPoint2: NSPoint(x: 750, y: 540))
    wPath.lineCapStyle = .round
    wPath.lineJoinStyle = .round

    // Split Route Bypass Underpass
    let bypassTrack = NSBezierPath()
    bypassTrack.move(to: NSPoint(x: 260, y: 360))
    bypassTrack.curve(to: NSPoint(x: 660, y: 230),
                      controlPoint1: NSPoint(x: 330, y: 230),
                      controlPoint2: NSPoint(x: 510, y: 230))
    bypassTrack.curve(to: NSPoint(x: 820, y: 370),
                      controlPoint1: NSPoint(x: 750, y: 230),
                      controlPoint2: NSPoint(x: 795, y: 280))
    bypassTrack.lineCapStyle = .round

    // --- 5. Draw Shadows under Channels ---
    let pCasing = NSColor(calibratedRed: 0.24, green: 0.30, blue: 0.40, alpha: 1.0)
    let wCasing = NSColor(calibratedRed: 0.34, green: 0.20, blue: 0.38, alpha: 1.0)
    let pCore1 = NSColor(calibratedRed: 0.08, green: 0.78, blue: 0.92, alpha: 1.0) // Cyan
    let pCore2 = NSColor(calibratedRed: 0.38, green: 0.92, blue: 0.98, alpha: 1.0)
    let wCore1 = NSColor(calibratedRed: 0.88, green: 0.18, blue: 0.60, alpha: 1.0) // Magenta
    let wCore2 = NSColor(calibratedRed: 0.98, green: 0.40, blue: 0.75, alpha: 1.0)

    NSGraphicsContext.saveGraphicsState()
    let trackShadow = NSShadow()
    trackShadow.shadowColor = NSColor.black.withAlphaComponent(0.40)
    trackShadow.shadowBlurRadius = 20
    trackShadow.shadowOffset = NSSize(width: 0, height: -10)
    trackShadow.set()

    pCasing.setStroke(); pPath.lineWidth = 58; pPath.stroke()
    wCasing.setStroke(); wPath.lineWidth = 54; wPath.stroke()
    pCasing.setStroke(); bypassTrack.lineWidth = 32; bypassTrack.stroke()
    NSGraphicsContext.restoreGraphicsState()

    // --- 6. Render Lower Bypass Track ---
    pCasing.setStroke(); bypassTrack.lineWidth = 30; bypassTrack.stroke()
    pCore1.setStroke(); bypassTrack.lineWidth = 16; bypassTrack.stroke()

    let bypassDotOuter = NSBezierPath(ovalIn: NSRect(x: 804, y: 354, width: 32, height: 32))
    pCasing.setFill(); bypassDotOuter.fill()
    let bypassDotInner = NSBezierPath(ovalIn: NSRect(x: 810, y: 360, width: 20, height: 20))
    pCore1.setFill(); bypassDotInner.fill()

    // --- 7. Render P Track (Titanium Casing + Electric Cyan Channel) ---
    pCasing.setStroke(); pPath.lineWidth = 58; pPath.stroke()
    pCore1.setStroke(); pPath.lineWidth = 36; pPath.stroke()
    pCore2.setStroke(); pPath.lineWidth = 26; pPath.stroke()

    // Specular Highlight line on P loop
    NSGraphicsContext.saveGraphicsState()
    let pGlint = NSBezierPath()
    pGlint.move(to: NSPoint(x: 275, y: 400))
    pGlint.line(to: NSPoint(x: 275, y: 690))
    pGlint.curve(to: NSPoint(x: 510, y: 620),
                 controlPoint1: NSPoint(x: 400, y: 690),
                 controlPoint2: NSPoint(x: 510, y: 660))
    NSColor.white.withAlphaComponent(0.45).setStroke()
    pGlint.lineWidth = 5
    pGlint.lineCapStyle = .round
    pGlint.stroke()
    NSGraphicsContext.restoreGraphicsState()

    // --- 8. Render W Track (Dark Casing + Neon Magenta Channel) ---
    wCasing.setStroke(); wPath.lineWidth = 54; wPath.stroke()
    wCore1.setStroke(); wPath.lineWidth = 34; wPath.stroke()
    wCore2.setStroke(); wPath.lineWidth = 24; wPath.stroke()

    // Specular Highlight line on W wave
    NSGraphicsContext.saveGraphicsState()
    let wGlint = NSBezierPath()
    wGlint.move(to: NSPoint(x: 300, y: 495))
    wGlint.curve(to: NSPoint(x: 420, y: 310),
                 controlPoint1: NSPoint(x: 340, y: 495),
                 controlPoint2: NSPoint(x: 375, y: 310))
    wGlint.curve(to: NSPoint(x: 540, y: 515),
                 controlPoint1: NSPoint(x: 465, y: 310),
                 controlPoint2: NSPoint(x: 495, y: 515))
    wGlint.curve(to: NSPoint(x: 660, y: 310),
                 controlPoint1: NSPoint(x: 585, y: 515),
                 controlPoint2: NSPoint(x: 615, y: 310))
    wGlint.curve(to: NSPoint(x: 780, y: 645),
                 controlPoint1: NSPoint(x: 705, y: 310),
                 controlPoint2: NSPoint(x: 745, y: 535))
    NSColor.white.withAlphaComponent(0.40).setStroke()
    wGlint.lineWidth = 5
    wGlint.lineCapStyle = .round
    wGlint.stroke()
    NSGraphicsContext.restoreGraphicsState()

    // --- 9. Directional Chiseled Arrowhead (Cyan / Magenta) ---
    let arrowTip = NSPoint(x: 830, y: 700)
    let arrowLeft = NSPoint(x: 735, y: 690)
    let arrowMid = NSPoint(x: 775, y: 635)
    let arrowRight = NSPoint(x: 730, y: 595)

    let leftFacet = NSBezierPath()
    leftFacet.move(to: arrowTip); leftFacet.line(to: arrowLeft); leftFacet.line(to: arrowMid); leftFacet.close()

    let rightFacet = NSBezierPath()
    rightFacet.move(to: arrowTip); rightFacet.line(to: arrowMid); rightFacet.line(to: arrowRight); rightFacet.close()

    NSGraphicsContext.saveGraphicsState()
    let arrowShadow = NSShadow()
    arrowShadow.shadowColor = NSColor.black.withAlphaComponent(0.38)
    arrowShadow.shadowBlurRadius = 14
    arrowShadow.shadowOffset = NSSize(width: 0, height: -6)
    arrowShadow.set()
    pCore2.setFill(); leftFacet.fill()
    NSColor(calibratedRed: 0.05, green: 0.60, blue: 0.75, alpha: 1.0).setFill(); rightFacet.fill()
    NSGraphicsContext.restoreGraphicsState()

    wCore1.setStroke()
    leftFacet.lineWidth = 4; leftFacet.stroke()
    rightFacet.lineWidth = 4; rightFacet.stroke()

    // --- 10. Origin Junction Pivot Node ---
    let nodeRect = NSRect(x: 205, y: 305, width: 110, height: 110)
    let nodeOuter = NSBezierPath(ovalIn: nodeRect)

    NSGraphicsContext.saveGraphicsState()
    let nodeShadow = NSShadow()
    nodeShadow.shadowColor = NSColor.black.withAlphaComponent(0.40)
    nodeShadow.shadowBlurRadius = 16
    nodeShadow.shadowOffset = NSSize(width: 0, height: -8)
    nodeShadow.set()
    NSColor(calibratedRed: 0.20, green: 0.25, blue: 0.34, alpha: 1.0).setFill()
    nodeOuter.fill()
    NSGraphicsContext.restoreGraphicsState()

    rimColor.setStroke()
    nodeOuter.lineWidth = 7
    nodeOuter.stroke()

    let nodeInner = NSBezierPath(ovalIn: NSRect(x: 235, y: 335, width: 50, height: 50))
    pCore1.setFill(); nodeInner.fill()
    NSColor.white.withAlphaComponent(0.7).setStroke()
    nodeInner.lineWidth = 3
    nodeInner.stroke()

    let nodeGlint = NSBezierPath(ovalIn: NSRect(x: 245, y: 358, width: 14, height: 10))
    NSColor.white.withAlphaComponent(0.6).setFill()
    nodeGlint.fill()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

// Generate the 1024x1024 master
let masterData = renderMasterIcon(side: 1024)
let masterPath = CommandLine.arguments[2]
try masterData.write(to: URL(fileURLWithPath: masterPath))

// Downsample into Apple iconset
let masterImg = NSImage(data: masterData)!
func downsample(_ pixelSize: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixelSize, pixelsHigh: pixelSize, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ctx
    ctx.imageInterpolation = .high
    masterImg.draw(in: NSRect(x: 0, y: 0, width: pixelSize, height: pixelSize),
                   from: NSRect(x: 0, y: 0, width: masterImg.size.width, height: masterImg.size.height),
                   operation: .copy, fraction: 1.0)
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try downsample(base).write(to: destination.appendingPathComponent("icon_\(base)x\(base).png"))
    try downsample(base * 2).write(to: destination.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
print("Generated master icon and complete iconset for Midnight Obsidian & Cyber Cyan.")
