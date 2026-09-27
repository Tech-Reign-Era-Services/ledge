import AppKit

// Draws the app icon (1024 × 1024 PNG): the island coming out of the top of a dark screen, holding three items.
// Usage: swift scripts/make-icon.swift out.png

let size: CGFloat = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8, samplesPerPixel: 4,
                           hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext
ctx.translateBy(x: 0, y: size)
ctx.scaleBy(x: 1, y: -1) // draw top-down

// The squircle-ish tile, inset as macOS icons are.
let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)
NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
shadow.shadowBlurRadius = 24
shadow.shadowOffset = NSSize(width: 0, height: -10)
shadow.set()
NSColor(calibratedRed: 0.10, green: 0.11, blue: 0.16, alpha: 1).setFill()
tilePath.fill()
NSGraphicsContext.restoreGraphicsState()
NSGraphicsContext.saveGraphicsState()
tilePath.addClip()
NSGradient(colors: [NSColor(calibratedRed: 0.29, green: 0.36, blue: 0.78, alpha: 1), NSColor(calibratedRed: 0.09, green: 0.10, blue: 0.18, alpha: 1)])!
    .draw(in: tile, angle: 90)

// The island: black, hanging from the top edge, with the notch's inward shoulders.
let island = NSRect(x: 212, y: 100, width: 600, height: 330)
NSColor.black.setFill()
NSBezierPath(roundedRect: island, xRadius: 96, yRadius: 96).fill()
NSRect(x: island.minX, y: island.minY, width: island.width, height: 120).fill()
for (edge, out) in [(island.minX, island.minX - 44), (island.maxX, island.maxX + 44)] {
    let p = NSBezierPath()
    p.move(to: NSPoint(x: out, y: 100))
    p.curve(to: NSPoint(x: edge, y: 144), controlPoint1: NSPoint(x: edge, y: 100), controlPoint2: NSPoint(x: edge, y: 100))
    p.line(to: NSPoint(x: edge, y: 100))
    p.close()
    p.fill()
}

// Three items on the shelf: a document, a picture, a link.
let tiles: [(NSColor, NSColor)] = [
    (NSColor(white: 0.97, alpha: 1), NSColor(white: 0.80, alpha: 1)),
    (NSColor(calibratedRed: 0.99, green: 0.72, blue: 0.36, alpha: 1), NSColor(calibratedRed: 0.93, green: 0.40, blue: 0.40, alpha: 1)),
    (NSColor(calibratedRed: 0.58, green: 0.66, blue: 1.0, alpha: 1), NSColor(calibratedRed: 0.36, green: 0.46, blue: 0.95, alpha: 1)),
]
for (i, (a, b)) in tiles.enumerated() {
    let r = NSRect(x: 282 + CGFloat(i) * 170, y: 250, width: 120, height: 120)
    NSGradient(colors: [a, b])!.draw(in: NSBezierPath(roundedRect: r, xRadius: 28, yRadius: 28), angle: -90)
}
NSGraphicsContext.restoreGraphicsState()
NSGraphicsContext.restoreGraphicsState()

try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
