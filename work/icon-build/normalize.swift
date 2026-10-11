import AppKit
import Foundation

// Model baked a rounded square into the bitmap; macOS requires full-bleed square
// art and applies its own mask. Crop just inside the baked corner, then rebuild
// the tile at the standard macOS proportion on a transparent canvas.
let src = CommandLine.arguments[1]
let outDir = CommandLine.arguments[2]
let canvas = 1024

guard let image = NSImage(contentsOfFile: src),
      let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff) else {
    FileHandle.standardError.write(Data("cannot load \(src)\n".utf8)); exit(1)
}
let w = rep.pixelsWide, h = rep.pixelsHigh
let side = min(w, h)

// Sample the four corners to find how far the baked rounded corner cuts in.
func isBackground(_ x: Int, _ y: Int) -> Bool {
    guard let c = rep.colorAt(x: x, y: y) else { return true }
    return c.alphaComponent < 0.5
}
func scanInset() -> Int {
    // Walk the diagonal from the corner until we hit opaque artwork.
    for step in 0..<(side / 2) {
        if !isBackground(step, step) { return step }
    }
    return 0
}
let inset = scanInset()
let cropRect = CGRect(x: inset, y: inset, width: side - inset * 2, height: side - inset * 2)

let tile = 0.92 * Double(canvas)          // standard macOS proportion for app tiles
let tileSize = Int(tile.rounded())
let radius = Double(tileSize) * 0.2237    // continuous-corner approximation

guard let ctx = CGContext(data: nil, width: canvas, height: canvas, bitsPerComponent: 8,
                          bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
    FileHandle.standardError.write(Data("no context\n".utf8)); exit(1)
}
var proposed = CGRect(x: 0, y: 0, width: side, height: side)
guard let cg = rep.cgImage ?? rep.cgImage(forProposedRect: &proposed, context: nil, hints: nil) else {
    FileHandle.standardError.write(Data("no cgImage\n".utf8)); exit(1)
}
let cropped = cg.cropping(to: cropRect) ?? cg

let origin = Double(canvas - tileSize) / 2
let tileRect = CGRect(x: origin, y: origin, width: Double(tileSize), height: Double(tileSize))
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
// Subtle drop shadow so the tile reads at large sizes, like Apple's own icons.
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
shadow.shadowBlurRadius = Double(canvas) * 0.018
shadow.shadowOffset = NSSize(width: 0, height: -Double(canvas) * 0.008)
shadow.set()
NSColor.black.withAlphaComponent(0.001).setFill()
NSBezierPath(roundedRect: tileRect, xRadius: radius, yRadius: radius).fill()
NSGraphicsContext.restoreGraphicsState()

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
NSBezierPath(roundedRect: tileRect, xRadius: radius, yRadius: radius).addClip()
let nsCtx = NSGraphicsContext(cgContext: ctx, flipped: false)
NSImage(cgImage: cropped, size: NSSize(width: tileSize, height: tileSize))
    .draw(in: tileRect, from: .zero, operation: .sourceOver, fraction: 1.0, respectFlipped: false, hints: nil)
_ = nsCtx
NSGraphicsContext.restoreGraphicsState()

guard let final = ctx.makeImage() else { exit(1) }
let outRep = NSBitmapImageRep(cgImage: final)
guard let png = outRep.representation(using: .png, properties: [:]) else { exit(1) }
try! FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
try! png.write(to: URL(fileURLWithPath: outDir + "/icon-1024.png"))
print("inset=\(inset) side=\(side) tile=\(tileSize) -> \(outDir)/icon-1024.png (\(png.count) bytes)")
