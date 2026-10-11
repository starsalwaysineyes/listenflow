import CoreGraphics
import Foundation
let target = Int(CommandLine.arguments[1])!
let list = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
for w in list {
    guard (w[kCGWindowOwnerPID as String] as? Int) == target else { continue }
    let name = w[kCGWindowName as String] as? String ?? "(no name)"
    let num  = w[kCGWindowNumber as String] as? Int ?? 0
    let b    = w[kCGWindowBounds as String] as? [String: CGFloat] ?? [:]
    let layer = w[kCGWindowLayer as String] as? Int ?? -1
    let alpha = w[kCGWindowAlpha as String] as? Double ?? 0
    print("win#\(num) layer=\(layer) alpha=\(alpha) '\(name)'  \(Int(b["X"] ?? 0)),\(Int(b["Y"] ?? 0)) \(Int(b["Width"] ?? 0))x\(Int(b["Height"] ?? 0))")
}
