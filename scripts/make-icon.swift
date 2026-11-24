// Generates Resources/AppIcon.icns — the generator is kept so the icon can be re-rendered.
// Usage: swiftc -O scripts/make-icon.swift -o /private/tmp/make-icon && /private/tmp/make-icon <out-dir>
// (build in /private/tmp: see build.sh for the xattr/codesign reason.) Then:
//   iconutil -c icns <out-dir>/AppIcon.iconset -o Resources/AppIcon.icns
import AppKit

func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    // macOS icon grid: art occupies ~80% of the canvas, corner radius ~22.4% of that.
    let inset = s * 0.10, body = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let path = NSBezierPath(roundedRect: body, xRadius: body.width * 0.2237, yRadius: body.width * 0.2237)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
    shadow.shadowOffset = NSSize(width: 0, height: -s * 0.012); shadow.shadowBlurRadius = s * 0.025
    shadow.set()
    NSColor.black.setFill(); path.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(colors: [NSColor(red: 0.20, green: 0.24, blue: 0.34, alpha: 1),
                        NSColor(red: 0.07, green: 0.08, blue: 0.13, alpha: 1)])!.draw(in: path, angle: -90)
    // Glyph: the same SF Symbol the menu bar uses, so the icon and the menu bar item match.
    let cfg = NSImage.SymbolConfiguration(pointSize: body.width * 0.52, weight: .regular)
    if let sym = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: nil)?
        .withSymbolConfiguration(cfg) {
        let tinted = NSImage(size: sym.size, flipped: false) { r in
            sym.draw(in: r); NSColor.white.set(); r.fill(using: .sourceAtop); return true }
        let w = tinted.size.width, h = tinted.size.height
        tinted.draw(in: NSRect(x: s / 2 - w / 2, y: s / 2 - h / 2, width: w, height: h))
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
    .appendingPathComponent("AppIcon.iconset")
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128),
                   ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512),
                   ("512x512@2x", 1024)] {
    try! render(px).write(to: out.appendingPathComponent("icon_\(name).png"))
}
