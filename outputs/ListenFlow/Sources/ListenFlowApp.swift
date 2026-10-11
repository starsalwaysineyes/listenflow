import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: AppModel?
    private var hotKey: GlobalHotKey?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        // ⌥⌘R works from any app, so a class or meeting can be captured without
        // switching back to the ListenFlow window first.
        hotKey = GlobalHotKey.toggleRecording { [weak self] in
            Task { @MainActor in await self?.model?.toggleRecording() }
        }
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
    @StateObject private var model = AppModel()
    init() {
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
                print("DeepSeek configured; API credential saved to Keychain.")
                exit(0)
            } catch { fputs("Configuration failed: \(error.localizedDescription)\n", stderr); exit(1) }
        }
    }
    var body: some Scene {
        WindowGroup("听流 · ListenFlow") {
            ContentView(model: model).onAppear { delegate.model = model }
        }
        .defaultSize(width: 1220, height: 800)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("新建会话") { model.newSession() }.keyboardShortcut("n").disabled(!model.canChangeSession)
            }
            CommandGroup(after: .newItem) {
                Button(model.isRecording ? "暂停转写" : "开始转写") {
                    Task { await model.toggleRecording() }
                }.keyboardShortcut("r").disabled(!model.canStartRecording && !model.isRecording)
                Divider()
                Button("随时提问…") { model.showMainWindow(focusQuestion: true) }
                    .keyboardShortcut("k")
                    .disabled(!model.hasAskContext)
            }
            CommandGroup(replacing: .appSettings) {
                Button("模型与 API 设置…") { model.showSettings = true }.keyboardShortcut(",")
            }
        }

        MenuBarExtra {
            menuContent
        } label: {
            // The glyph itself shows whether audio is being captured right now.
            Image(systemName: model.isRecording ? "waveform.circle.fill" : "waveform.circle")
        }
    }

    @ViewBuilder
    private var menuContent: some View {
        if model.isRecording {
            Text("正在转写 · \(model.session.lines.count) 段")
            if model.pendingCount > 0 { Text("识别中 \(model.pendingCount) 段") }
        } else {
            Text(model.modelReady ? "已就绪，未在转写" : model.modelStatus)
        }
        Divider()
        Button(model.isRecording ? "暂停转写（⌥⌘R）" : "开始转写（⌥⌘R）") {
            Task { await model.toggleRecording() }
        }.disabled(!model.canStartRecording && !model.isRecording)
        Button("随时提问…（⌘K）") { model.showMainWindow(focusQuestion: true) }
            .disabled(!model.hasAskContext)
        Button("打开听流窗口") { model.showMainWindow() }
        Divider()
        Button("模型与 API 设置…") { model.showSettings = true; model.showMainWindow() }
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
