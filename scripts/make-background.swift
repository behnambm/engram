import AppKit

let W = 660, H = 400
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp/background.png"

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: W, pixelsHigh: H,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

let rect = NSRect(x: 0, y: 0, width: W, height: H)

// Indigo gradient matching the app icon
NSGradient(colors: [
    NSColor(calibratedRed: 0.345, green: 0.404, blue: 0.910, alpha: 1),  // #5867E8
    NSColor(calibratedRed: 0.137, green: 0.180, blue: 0.561, alpha: 1),  // #232E8F
])?.draw(in: rect, angle: -90)

func centerText(_ s: String, font: NSFont, color: NSColor, y: CGFloat) {
    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
    let size = (s as NSString).size(withAttributes: attrs)
    (s as NSString).draw(at: NSPoint(x: (CGFloat(W) - size.width)/2, y: y), withAttributes: attrs)
}

// small paperclip glyph
if let sym = NSImage(systemSymbolName: "paperclip", accessibilityDescription: nil) {
    let cfg = sym.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 44, weight: .regular))!
    let tinted = cfg.copy() as! NSImage
    tinted.lockFocus(); NSColor.white.set()
    NSRect(origin: .zero, size: tinted.size).fill(using: .sourceAtop); tinted.unlockFocus()
    let gr = NSRect(x: (CGFloat(W) - tinted.size.width)/2, y: 60, width: tinted.size.width, height: tinted.size.height)
    tinted.draw(in: gr)
}

centerText("Engram", font: .systemFont(ofSize: 52, weight: .bold), color: .white, y: 116)
centerText("Drag into your Applications folder",
           font: .systemFont(ofSize: 16, weight: .regular),
           color: NSColor.white.withAlphaComponent(0.85), y: 176)

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
