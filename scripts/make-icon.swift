import AppKit

// Generates the Siaheh app icon master (1024x1024): a white paperclip on a full-bleed
// indigo gradient. Modern macOS applies the squircle rounding itself, so the corners
// stay filled. Run from scripts/make-icon.sh, which turns this into a .icns.

let size = 1024
let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon-1024.png"

guard let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
) else {
    fatalError("could not create bitmap")
}

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// Full-square vertical gradient. macOS rounds the corners of the finished icon.
let canvas = NSRect(x: 0, y: 0, width: CGFloat(size), height: CGFloat(size))
let gradient = NSGradient(colors: [
    NSColor(calibratedRed: 0.345, green: 0.404, blue: 0.910, alpha: 1.0),  // #5867E8
    NSColor(calibratedRed: 0.137, green: 0.180, blue: 0.561, alpha: 1.0),  // #232E8F
])
gradient?.draw(in: canvas, angle: -90)

// The paperclip, white with a soft drop shadow.
if let symbol = NSImage(systemSymbolName: "paperclip", accessibilityDescription: nil),
   let configured = symbol.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 560, weight: .regular)) {
    // Tint the symbol white with a source-atop fill — the reliable way to colour an
    // SF Symbol (raw draw() draws the glyph in its own colour and ignores the current one).
    let tinted = configured.copy() as! NSImage
    tinted.lockFocus()
    NSColor.white.set()
    NSRect(origin: .zero, size: tinted.size).fill(using: .sourceAtop)
    tinted.unlockFocus()

    let glyphRect = NSRect(
        x: (canvas.width - tinted.size.width) / 2,
        y: (canvas.height - tinted.size.height) / 2,
        width: tinted.size.width,
        height: tinted.size.height
    )

    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
    shadow.shadowOffset = NSSize(width: 0, height: -10)
    shadow.shadowBlurRadius = 22
    shadow.set()

    tinted.draw(in: glyphRect)
}

NSGraphicsContext.restoreGraphicsState()

guard let png = rep.representation(using: .png, properties: [:]) else {
    fatalError("could not encode png")
}
try! png.write(to: URL(fileURLWithPath: output))
print("wrote \(output)")
