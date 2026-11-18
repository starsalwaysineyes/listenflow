import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: AppModel?
    private var hotKeys: [GlobalHotKey] = []

    /// Replays and offscreen snapshots are logic checks driven from a terminal:
    /// they must not put a window on screen or take focus from whoever is
    /// using the Mac. Preview builds only.
    static let headless: Bool = {
        let env = ProcessInfo.processInfo.environment
        return Bundle.main.bundleIdentifier == "local.ListenFlow.preview"
            && (env["LISTENFLOW_REPLAY"] != nil || env["LISTENFLOW_PREVIEW_SNAPSHOT"] != nil
                || env["LISTENFLOW_PREVIEW_SCROLLCHECK"] != nil || env["LISTENFLOW_PREVIEW_SERVE"] != nil)
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        if Self.headless {
            NSApp.setActivationPolicy(.accessory)
            // Belt and braces: the scene is told not to open a window, and any
            // that appears anyway (state restoration) is taken off screen.
            for delay in [0.0, 0.2, 1.0] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    NSApp.windows.filter { $0.canBecomeMain }.forEach { $0.orderOut(nil) }
                }
            }
            return
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        // Both shortcuts work from any app, so a class or meeting can be captured
        // without switching back to the ListenFlow window first.
        var keys: [GlobalHotKey] = []
        if let key = GlobalHotKey.toggleRecording(action: { [weak self] in
            Task { @MainActor in await self?.model?.toggleRecording() }
        }) { keys.append(key) }
        if let key = GlobalHotKey.screenshot(action: { [weak self] in
            Task { @MainActor in self?.model?.captureScreenshot() }
        }) { keys.append(key) }
        hotKeys = keys
    }

    /// The window closes to the menu bar rather than quitting, so an in-progress
    /// recording is never cut off by tidying a window away.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { model?.shutdown() }
    }
}

@main
struct ListenFlowApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    /// One instance, whoever asks first: the views, or a headless run that has no
    /// window to create it.
    private static let sharedModel = AppModel()
    @StateObject private var model = ListenFlowApp.sharedModel
    init() {
        if AppDelegate.headless { DispatchQueue.main.async { _ = Self.sharedModel } }
        if CommandLine.arguments.contains("--configure-deepseek") {
            let data = FileHandle.standardInput.readDataToEndOfFile()
            let key = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            do {
                guard !key.isEmpty else { throw CaptureFailure.message("No API credential supplied") }
                try SecretStore.save(key, account: "https://api.deepseek.com")
                var settings = Preferences.load()
                settings.apiBase = "https://api.deepseek.com"
                settings.llmModel = "deepseek-flash"
                settings.save()
                print("DeepSeek configured; API credential saved to \(SecretStore.file.path).")
                exit(0)
            } catch { fputs("Configuration failed: \(error.localizedDescription)\n", stderr); exit(1) }
        }
    }
    var body: some Scene {
        WindowGroup("听流 · ListenFlow") {
            ContentView(model: model).onAppear { delegate.model = model }
        }
        .defaultSize(width: 1080, height: 740)
        .defaultLaunchBehavior(AppDelegate.headless ? .suppressed : .automatic)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("新建会话") { model.newSession() }.keyboardShortcut("n").disabled(!model.canChangeSession)
            }
            CommandGroup(after: .newItem) {
                Button(model.isRecording ? "暂停转写" : "开始转写") {
                    Task { await model.toggleRecording() }
                }.keyboardShortcut("r").disabled(!model.canToggleRecording)
                Button("给这场会话改名…") {
                    model.showMainWindow()
                    model.renameToken += 1
                }
            }
            CommandGroup(replacing: .appSettings) {
                Button("设置…") { model.showSettings = true }.keyboardShortcut(",")
            }
        }

        MenuBarExtra(isInserted: .constant(!AppDelegate.headless)) {
            menuContent
        } label: {
            // The glyph itself shows whether audio is being captured right now.
            Image(systemName: model.isRecording ? "waveform.circle.fill" : "waveform.circle")
        }
    }

    @ViewBuilder
    private var menuContent: some View {
        if model.isRecording {
            Text("正在转写，已有 \(model.session.lines.count) 句")
            if model.pendingCount > 0 && !model.usesCloud { Text("识别中 \(model.pendingCount) 段") }
        } else {
            Text(model.engineReady ? "已就绪，未在转写" : model.engineStatus)
        }
        Divider()
        Button(model.isRecording ? "暂停转写（⌥⌘R）" : "开始转写（⌥⌘R）") {
            Task { await model.toggleRecording() }
        }.disabled(!model.canToggleRecording)
        Button("截屏，存进这场会话（⇧⌘J）") { model.captureScreenshot() }
            .disabled(model.isCapturingShot)
        Button("打开听流窗口") { model.showMainWindow() }
        if model.preferences.islandEnabled {
            Button(model.islandPinned ? "取消固定灵动岛" : "固定展开灵动岛") { model.islandPinned.toggle() }
        }
        Divider()
        Button("设置…") { model.showSettings = true; model.showMainWindow() }
        Button("退出听流") {
            // Stop capture and persist before terminating, so no session is lost.
            Task { @MainActor in
                await model.stop()
                model.shutdown()
                NSApp.terminate(nil)
            }
        }
    }
}
