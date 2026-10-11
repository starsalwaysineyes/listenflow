import AppKit
let image = NSImage(contentsOfFile: "icon-raw.png")!
let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
let side = min(rep.pixelsWide, rep.pixelsHigh)
print("pixels \(rep.pixelsWide)x\(rep.pixelsHigh) alpha=\(rep.hasAlpha)")
func rgb(_ x: Int, _ y: Int) -> (Int,Int,Int) {
    guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return (-1,-1,-1) }
    return (Int(c.redComponent*255), Int(c.greenComponent*255), Int(c.blueComponent*255))
}
for p in [(0,0),(1,1),(3,3),(6,6),(10,10),(15,15),(20,20),(30,30),(45,45),(60,60),(90,90),(120,120),(160,160),(200,200),(260,260)] {
    print("\(p) -> \(rgb(p.0,p.1))")
}
print("-- 沿顶边中心 --")
for x in [0,1,3,8,20,60,200,512] { print("(\(x),1) -> \(rgb(x,1))") }
