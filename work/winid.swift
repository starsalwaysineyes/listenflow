import CoreGraphics
import Foundation
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
for w in list {
    let owner = w[kCGWindowOwnerName as String] as? String ?? ""
    let name  = w[kCGWindowName as String] as? String ?? ""
    let num   = w[kCGWindowNumber as String] as? Int ?? 0
    let b     = w[kCGWindowBounds as String] as? [String: CGFloat] ?? [:]
    let layer = w[kCGWindowLayer as String] as? Int ?? -1
    if owner.contains("ListenFlow") || owner.contains("听流") || name.contains("听流") || name.contains("ListenFlow") {
        print("\(num)\t\(owner)\t\(name)\tlayer=\(layer)\t\(Int(b["X"] ?? 0)),\(Int(b["Y"] ?? 0)) \(Int(b["Width"] ?? 0))x\(Int(b["Height"] ?? 0))")
    }
}
