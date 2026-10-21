// Renders Daeva's 1024px app icon: an aether halo around a gold spire on a night squircle.
// usage: swift scripts/make-icon.swift out.png
import AppKit

let size: CGFloat = 1024
let out = CommandLine.arguments.dropFirst().first ?? "icon.png"
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let cg = NSGraphicsContext.current!.cgContext

let inset: CGFloat = 100, r: CGFloat = 185
let tile = CGRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
let squircle = CGPath(roundedRect: tile, cornerWidth: r, cornerHeight: r, transform: nil)
let space = CGColorSpaceCreateDeviceRGB()
func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor { CGColor(red: r, green: g, blue: b, alpha: a) }

// drop shadow + night gradient
cg.saveGState()
cg.setShadow(offset: CGSize(width: 0, height: -14), blur: 40, color: rgb(0, 0, 0, 0.45))
cg.addPath(squircle); cg.setFillColor(rgb(0.05, 0.05, 0.1)); cg.fillPath()
cg.restoreGState()
cg.saveGState()
cg.addPath(squircle); cg.clip()
cg.drawLinearGradient(CGGradient(colorsSpace: space, colors: [rgb(0.10, 0.11, 0.24), rgb(0.02, 0.02, 0.06)] as CFArray, locations: [0, 1])!,
                      start: CGPoint(x: 0, y: size), end: CGPoint(x: 0, y: 0), options: [])
let c = CGPoint(x: size / 2, y: size / 2 - 10)
cg.drawRadialGradient(CGGradient(colorsSpace: space, colors: [rgb(0.45, 0.74, 1, 0.55), rgb(0.45, 0.74, 1, 0)] as CFArray, locations: [0, 1])!,
                      startCenter: c, startRadius: 0, endCenter: c, endRadius: 330, options: [])

// halo
cg.setLineWidth(18)
cg.setStrokeColor(rgb(0.93, 0.80, 0.52, 0.95))
cg.setShadow(offset: .zero, blur: 30, color: rgb(0.45, 0.74, 1, 0.9))
cg.strokeEllipse(in: CGRect(x: c.x - 215, y: c.y - 215, width: 430, height: 430))

// spire: a tapering blade crossing the halo
let spire = CGMutablePath()
spire.move(to: CGPoint(x: c.x, y: c.y + 330))
spire.addCurve(to: CGPoint(x: c.x + 46, y: c.y - 120), control1: CGPoint(x: c.x + 18, y: c.y + 120), control2: CGPoint(x: c.x + 46, y: c.y))
spire.addLine(to: CGPoint(x: c.x, y: c.y - 300))
spire.addLine(to: CGPoint(x: c.x - 46, y: c.y - 120))
spire.addCurve(to: CGPoint(x: c.x, y: c.y + 330), control1: CGPoint(x: c.x - 46, y: c.y), control2: CGPoint(x: c.x - 18, y: c.y + 120))
cg.addPath(spire); cg.clip()
cg.setShadow(offset: .zero, blur: 0, color: nil)
cg.drawLinearGradient(CGGradient(colorsSpace: space, colors: [rgb(1, 0.96, 0.86), rgb(0.93, 0.78, 0.48), rgb(0.70, 0.52, 0.28)] as CFArray, locations: [0, 0.5, 1])!,
                      start: CGPoint(x: c.x, y: c.y + 330), end: CGPoint(x: c.x, y: c.y - 300), options: [])
cg.restoreGState()

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
