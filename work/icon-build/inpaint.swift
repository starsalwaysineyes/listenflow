import AppKit
import Foundation

// The generator baked a large rounded corner into an opaque bitmap. Replace the
// corner region with a harmonic (Laplace) interpolation of the surrounding
// gradient: for a linear gradient this reproduces the exact extension, so the
// fill is seamless rather than a visible patch.
let W = 1024, H = 1024
let bpr = W * 4
guard let img = NSImage(contentsOfFile: CommandLine.arguments[1]) else { exit(1) }
var r = CGRect(x: 0, y: 0, width: W, height: H)
guard let cg = img.cgImage(forProposedRect: &r, context: nil, hints: nil) else { exit(1) }

var buf = [UInt8](repeating: 0, count: bpr * H)
buf.withUnsafeMutableBytes { raw in
    let ctx = CGContext(data: raw.baseAddress, width: W, height: H, bitsPerComponent: 8,
        bytesPerRow: bpr, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: W, height: H))
}

func isWhiteish(_ i: Int) -> Bool {
    let r = Int(buf[i]), g = Int(buf[i+1]), b = Int(buf[i+2])
    return min(r, g, b) > 230
}

// Flood fill the near-white region inward from the border so only the corner
// background is selected, never a light highlight inside the artwork.
var bg = [Bool](repeating: false, count: W * H)
var stack: [Int] = []
for x in 0..<W { stack.append(x); stack.append((H - 1) * W + x) }
for y in 0..<H { stack.append(y * W); stack.append(y * W + W - 1) }
while let p = stack.popLast() {
    if bg[p] { continue }
    if !isWhiteish(p * 4) { continue }
    bg[p] = true
    let x = p % W, y = p / W
    if x > 0 { stack.append(p - 1) }
    if x < W - 1 { stack.append(p + 1) }
    if y > 0 { stack.append(p - W) }
    if y < H - 1 { stack.append(p + W) }
}
// Grow the mask so the antialiased edge ring is replaced too, not left as a halo.
for _ in 0..<3 {
    var grown = bg
    for p in 0..<(W * H) where bg[p] {
        let x = p % W, y = p / W
        if x > 0 { grown[p - 1] = true }
        if x < W - 1 { grown[p + 1] = true }
        if y > 0 { grown[p - W] = true }
        if y < H - 1 { grown[p + W] = true }
    }
    bg = grown
}

var bgList: [Int32] = []
for p in 0..<(W * H) where bg[p] { bgList.append(Int32(p)) }
print("corner pixels to fill: \(bgList.count) (\(String(format: "%.1f", Double(bgList.count) * 100 / Double(W * H)))%)")

// Seed every masked pixel from its nearest known neighbour (BFS), then relax.
var queue = bgList
var head = 0
while head < queue.count {
    let p = Int(queue[head]); head += 1
    let x = p % W, y = p / W
    var sr = 0, sg = 0, sb = 0, n = 0
    func take(_ q: Int) { let i = q * 4; sr += Int(buf[i]); sg += Int(buf[i+1]); sb += Int(buf[i+2]); n += 1 }
    if x > 0 && !bg[p - 1] { take(p - 1) }
    if x < W - 1 && !bg[p + 1] { take(p + 1) }
    if y > 0 && !bg[p - W] { take(p - W) }
    if y < H - 1 && !bg[p + W] { take(p + W) }
    if n > 0 {
        let i = p * 4
        buf[i] = UInt8(sr / n); buf[i+1] = UInt8(sg / n); buf[i+2] = UInt8(sb / n)
        // Newly solved pixels act as sources for their still-unknown neighbours.
        if x > 0 && bg[p - 1] && buf[(p - 1) * 4] == 255 && buf[(p - 1) * 4 + 1] == 255 && buf[(p - 1) * 4 + 2] == 255 { queue.append(Int32(p - 1)) }
        if x < W - 1 && bg[p + 1] && buf[(p + 1) * 4] == 255 && buf[(p + 1) * 4 + 1] == 255 && buf[(p + 1) * 4 + 2] == 255 { queue.append(Int32(p + 1)) }
        if y > 0 && bg[p - W] && buf[(p - W) * 4] == 255 && buf[(p - W) * 4 + 1] == 255 && buf[(p - W) * 4 + 2] == 255 { queue.append(Int32(p - W)) }
        if y < H - 1 && bg[p + W] && buf[(p + W) * 4] == 255 && buf[(p + W) * 4 + 1] == 255 && buf[(p + W) * 4 + 2] == 255 { queue.append(Int32(p + W)) }
    }
}

// Gauss-Seidel relaxation toward the harmonic solution.
for _ in 0..<600 {
    for q in bgList {
        let p = Int(q), x = p % W, y = p / W
        var sr = 0, sg = 0, sb = 0, n = 0
        if x > 0 { let i = (p - 1) * 4; sr += Int(buf[i]); sg += Int(buf[i+1]); sb += Int(buf[i+2]); n += 1 }
        if x < W - 1 { let i = (p + 1) * 4; sr += Int(buf[i]); sg += Int(buf[i+1]); sb += Int(buf[i+2]); n += 1 }
        if y > 0 { let i = (p - W) * 4; sr += Int(buf[i]); sg += Int(buf[i+1]); sb += Int(buf[i+2]); n += 1 }
        if y < H - 1 { let i = (p + W) * 4; sr += Int(buf[i]); sg += Int(buf[i+1]); sb += Int(buf[i+2]); n += 1 }
        let i = p * 4
        buf[i] = UInt8(sr / n); buf[i+1] = UInt8(sg / n); buf[i+2] = UInt8(sb / n)
    }
}

let out = CGContext(data: &buf, width: W, height: H, bitsPerComponent: 8, bytesPerRow: bpr,
    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
let result = out.makeImage()!
let rep = NSBitmapImageRep(cgImage: result)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
print("wrote \(CommandLine.arguments[2])")
