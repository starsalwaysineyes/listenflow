import AppKit
let rep = NSBitmapImageRep(data: NSImage(contentsOfFile: "master.png")!.tiffRepresentation!)!
print("master \(rep.pixelsWide)x\(rep.pixelsHigh) alpha=\(rep.hasAlpha)")
func rgb(_ x: Int, _ y: Int) -> String {
    guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return "nil" }
    return String(format: "(%3d,%3d,%3d)", Int(c.redComponent*255), Int(c.greenComponent*255), Int(c.blueComponent*255))
}
print("-- corners (should be gradient, not white) --")
for p in [(1,1),(8,8),(20,20),(45,45),(90,90),(1022,1),(1,1022),(1022,1022)] { print("\(p) -> \(rgb(p.0,p.1))") }
print("-- tile center column, top edge --")
for x in [0,1,20,100,300,512] { print("(\(x),1) -> \(rgb(x,1))") }
