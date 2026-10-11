import AppKit
let rep = NSBitmapImageRep(data: NSImage(contentsOfFile: "icon-raw.png")!.tiffRepresentation!)!
let w = rep.pixelsWide, h = rep.pixelsHigh
func isWhite(_ x: Int, _ y: Int) -> Bool {
    guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return true }
    return c.redComponent > 0.94 && c.greenComponent > 0.94 && c.blueComponent > 0.94
}
// Scan the middle row/column to find where the opaque tile actually begins/ends.
var left = 0, right = w - 1, top = 0, bottom = h - 1
let midY = h / 2, midX = w / 2
while left < w && isWhite(left, midY) { left += 1 }
while right > 0 && isWhite(right, midY) { right -= 1 }
while top < h && isWhite(midX, top) { top += 1 }
while bottom > 0 && isWhite(midX, bottom) { bottom -= 1 }
print("tile bounds: x=\(left)..\(right) (w=\(right-left+1))  y=\(top)..\(bottom) (h=\(bottom-top+1))")
// Corner radius: on the top row of the tile, find where fill starts from the left.
var r = 0
while r < w && isWhite(left + r, top + 1) { r += 1 }
print("horizontal run of white at top+1 from tile left: \(r)")
// Compare: how far in from the tile's left edge is the tile at the top row
print("midY=\(midY) midX=\(midX) left=\(left) top=\(top)")
