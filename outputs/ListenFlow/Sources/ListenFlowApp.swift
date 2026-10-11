import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: AppModel?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
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
            CommandGroup(replacing: .appSettings) {
                Button("模型与 API 设置…") { model.showSettings = true }.keyboardShortcut(",")
            }
        }
    }
}
