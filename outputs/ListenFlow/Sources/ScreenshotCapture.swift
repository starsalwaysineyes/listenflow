import AppKit
import ScreenCaptureKit

/// One click during a meeting or a class keeps what is on screen — a slide, a
/// diagram, a shared document — with the session, at the moment it was shown.
/// Nothing is selected and nothing is hidden: the whole screen is taken as it
/// is, minus this app's own windows.
enum ScreenshotCapture {
    /// The screen the pointer is on: with several displays, that is the one
    /// being looked at.
    @MainActor static func displayUnderPointer() -> CGDirectDisplayID? {
        let point = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
        return screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }

    static func capture(display id: CGDirectDisplayID?) async throws -> CGImage {
        let content: SCShareableContent
        do { content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) }
        catch {
            throw CaptureFailure.message("截屏需要允许「屏幕与系统音频录制」。请在系统设置中授权听流，然后重新打开应用。")
        }
        guard let display = content.displays.first(where: { $0.displayID == id }) ?? content.displays.first else {
            throw CaptureFailure.message("没有可用的显示器，无法截屏。")
        }
        let own = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        let filter = SCContentFilter(display: display, excludingApplications: own, exceptingWindows: [])
        let pixels = CGSize(width: filter.contentRect.width * CGFloat(filter.pointPixelScale),
                            height: filter.contentRect.height * CGFloat(filter.pointPixelScale))
        let scale = min(1, CGFloat(ImageAttachmentStore.shotEdge) / max(pixels.width, pixels.height, 1))
        let config = SCStreamConfiguration()
        config.width = max(2, Int((pixels.width * scale).rounded()))
        config.height = max(2, Int((pixels.height * scale).rounded()))
        config.showsCursor = false
        do { return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) }
        catch { throw CaptureFailure.message("截屏失败：\(error.localizedDescription)") }
    }
}
