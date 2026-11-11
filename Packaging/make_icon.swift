// Renders AppIcon.iconset (blue gradient squircle with the cloud-upload symbol) and
// PlaceholderIcon.iconset (white page with a folded corner and a blue cloud with a down arrow,
// the document icon of .mailcloud placeholders). Run via Packaging/make_icon.sh.
import AppKit
let out = CommandLine.arguments[1]
let iconset = out + "/AppIcon.iconset"
let placeholderSet = out + "/PlaceholderIcon.iconset"
for dir in [iconset, placeholderSet] {
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
}
func render(_ px: Int) -> Data {
    let img = NSImage(size: NSSize(width: px, height: px))
    img.lockFocus()
    let r = NSRect(x: 0, y: 0, width: px, height: px).insetBy(dx: CGFloat(px) * 0.05, dy: CGFloat(px) * 0.05)
    let path = NSBezierPath(roundedRect: r, xRadius: r.width * 0.22, yRadius: r.width * 0.22)
    NSGradient(starting: NSColor(calibratedRed: 0.20, green: 0.55, blue: 1.0, alpha: 1),
               ending: NSColor(calibratedRed: 0.05, green: 0.25, blue: 0.75, alpha: 1))!.draw(in: path, angle: -90)
    let cfg = NSImage.SymbolConfiguration(pointSize: CGFloat(px) * 0.5, weight: .medium)
    if let sym = NSImage(systemSymbolName: "icloud.and.arrow.up.fill", accessibilityDescription: nil)?.withSymbolConfiguration(cfg) {
        let tinted = NSImage(size: sym.size, flipped: false) { rect in
            sym.draw(in: rect); NSColor.white.set(); rect.fill(using: .sourceAtop); return true
        }
        let s = tinted.size
        tinted.draw(in: NSRect(x: (CGFloat(px) - s.width) / 2, y: (CGFloat(px) - s.height) / 2 + CGFloat(px) * 0.02, width: s.width, height: s.height))
    }
    img.unlockFocus()
    let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
    return rep.representation(using: .png, properties: [:])!
}
/// Document icon: a page with a folded top-right corner, a cloud with a down arrow on it.
func renderPlaceholder(_ px: Int) -> Data {
    let img = NSImage(size: NSSize(width: px, height: px))
    img.lockFocus()
    let s = CGFloat(px)
    let page = NSRect(x: s * 0.17, y: s * 0.06, width: s * 0.66, height: s * 0.88)
    let fold = page.width * 0.28
    let outline = NSBezierPath()
    outline.move(to: NSPoint(x: page.minX, y: page.minY))
    outline.line(to: NSPoint(x: page.maxX, y: page.minY))
    outline.line(to: NSPoint(x: page.maxX, y: page.maxY - fold))
    outline.line(to: NSPoint(x: page.maxX - fold, y: page.maxY))
    outline.line(to: NSPoint(x: page.minX, y: page.maxY))
    outline.close()
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
    shadow.shadowBlurRadius = max(1, s * 0.015)
    shadow.shadowOffset = NSSize(width: 0, height: -max(0.5, s * 0.006))
    shadow.set()
    NSColor.white.setFill()
    outline.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSColor(calibratedWhite: 0.78, alpha: 1).setStroke()
    outline.lineWidth = max(0.5, s * 0.006)
    outline.stroke()
    let corner = NSBezierPath()
    corner.move(to: NSPoint(x: page.maxX - fold, y: page.maxY))
    corner.line(to: NSPoint(x: page.maxX - fold, y: page.maxY - fold))
    corner.line(to: NSPoint(x: page.maxX, y: page.maxY - fold))
    corner.close()
    NSColor(calibratedWhite: 0.88, alpha: 1).setFill()
    corner.fill()
    corner.lineWidth = outline.lineWidth
    corner.stroke()
    let cfg = NSImage.SymbolConfiguration(pointSize: s * 0.34, weight: .medium)
    if let sym = NSImage(systemSymbolName: "icloud.and.arrow.down.fill", accessibilityDescription: nil)?.withSymbolConfiguration(cfg) {
        let blue = NSColor(calibratedRed: 0.10, green: 0.42, blue: 0.95, alpha: 1)
        let tinted = NSImage(size: sym.size, flipped: false) { rect in
            sym.draw(in: rect); blue.set(); rect.fill(using: .sourceAtop); return true
        }
        let t = tinted.size
        tinted.draw(in: NSRect(x: page.midX - t.width / 2, y: page.minY + page.height * 0.44 - t.height / 2,
                               width: t.width, height: t.height))
    }
    img.unlockFocus()
    let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
    return rep.representation(using: .png, properties: [:])!
}
for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128), ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    try! render(px).write(to: URL(fileURLWithPath: "\(iconset)/icon_\(name).png"))
    try! renderPlaceholder(px).write(to: URL(fileURLWithPath: "\(placeholderSet)/icon_\(name).png"))
}
