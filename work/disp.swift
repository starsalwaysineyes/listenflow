import AppKit
for (i, s) in NSScreen.screens.enumerated() {
    print("屏幕\(i): frame=\(s.frame) visible=\(s.visibleFrame) scale=\(s.backingScaleFactor)")
}
