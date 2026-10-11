import AppKit
import Foundation

/// Interactive screen capture for the "I'm in a meeting and want to grab what's
/// on screen" case. Apple's own capture tool is used so the familiar crosshair,
/// window and area selection affordances come for free; the app already holds
/// Screen Recording permission, which the child process inherits.
enum ScreenshotCapture {
    /// Returns nil when the user cancels the selection, which is not an error.
    static func captureInteractive() async -> ImageImportSource? {
        let path = NSTemporaryDirectory() + "listenflow-shot-\(UUID().uuidString).png"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        // -i interactive, -x silent. A cancelled selection simply writes no file.
        process.arguments = ["-i", "-x", path]
        do { try process.run() } catch { return nil }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            process.terminationHandler = { _ in continuation.resume() }
        }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)), !data.isEmpty else { return nil }
        return .data(data, name: "屏幕截图")
    }
}
