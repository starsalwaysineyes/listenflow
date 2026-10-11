import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct AudioApp: Identifiable, Hashable {
    let id: pid_t
    let name: String
    let bundleID: String
}

/// Where a session's audio comes from. In-person classes and meetings need the
/// microphone alone, with no app playing anything, so the two are exclusive
/// choices rather than a picker plus a bolted-on toggle.
enum AudioSource: String, Codable, CaseIterable, Identifiable {
    case microphone
    case app
    var id: String { rawValue }
    var label: String { self == .microphone ? "我的麦克风" : "指定 App" }
    var detail: String {
        self == .microphone ? "线下课堂、线下会议；只用本机麦克风" : "腾讯会议、网课、播放器；只接收所选 App 的声音"
    }
    var icon: String { self == .microphone ? "mic.fill" : "waveform.badge.macwindow" }
}

@MainActor
final class AudioLevels: ObservableObject {
    @Published var app: Float = 0
    @Published var mic: Float = 0
}

@MainActor
final class OrganizationPreview: ObservableObject {
    @Published var text = ""
}

/// Streaming answer text lives outside `AppModel` on purpose. Publishing it on the
/// session would invalidate every view that observes the model — the sidebar, the
/// whole transcript list and the footer — several times per second. Only the small
/// view that observes this object re-renders while an answer streams in.
@MainActor
final class AnswerStream: ObservableObject {
    struct State: Equatable {
        var messageID: UUID?
        var text = ""
    }
    @Published private(set) var state = State()
    func begin(_ id: UUID) { state = State(messageID: id, text: "") }
    func update(_ value: String) { state.text = value }
    func finish() { state = State() }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var preferences = Preferences.load()
    @Published var apps: [AudioApp] = []
    @Published var selectedPID: pid_t = 0
    @Published var session = MeetingSession()
    @Published var history: [MeetingSession] = []
    @Published var isRecording = false
    @Published var isBusy = false
    @Published var micEnabled = false
    @Published var micBusy = false
    @Published var modelReady = false
    @Published var modelLoading = false
    @Published var modelStatus = "模型尚未加载"
    @Published var error: String?
    @Published var pendingCount = 0
    let levels = AudioLevels()
    @Published var lastLatency: Double = 0
    @Published var oldestPending: Double = 0
    @Published var question = ""
    @Published var isAsking = false
    @Published var isOrganizing = false
    @Published var isImportingImages = false
    @Published var askImageIDs: Set<UUID> = []
    @Published var organizationImageIDs: Set<UUID> = []
    let organizationPreview = OrganizationPreview()
    let answerStream = AnswerStream()
    @Published var showOrganized = false
    @Published var autoOrganize = false
    @Published var showSettings = false
    @Published var showHistory = false
    @Published var source: AudioSource = .app
    /// Bumped to pull keyboard focus into the question field from the menu bar.
    /// A counter rather than a flag, so repeated ⌘K always re-focuses.
    @Published var questionFocusToken = 0
    /// What a running session is actually capturing, decided at start time so the
    /// user can change the picker freely while stopped.
    @Published var activeSource: AudioSource?
    private let capture = CaptureEngine()
    private let worker = ASRBridge()
    private var pending: [UUID: AudioChunk] = [:]
    private var askTask: Task<Void, Never>?
    private var organizeTask: Task<Void, Never>?
    private var lastOrganizationAttempt = Date.distantPast
    private var timer: Timer?
    private var loadingSince: Date?
    private var lastAppSignal = Date.distantPast
    private var lastMicSignal = Date.distantPast
    var canChangeSession: Bool { !isRecording && !isBusy && !isAsking && !isOrganizing && !isImportingImages && pendingCount == 0 }
    /// A microphone session can start with no app selected.
    var canStartRecording: Bool {
        guard modelReady, !isBusy, !isRecording else { return false }
        return source == .microphone || selectedPID != 0
    }
    var askImages: [ImageAttachment] { session.imageLibrary.filter { askImageIDs.contains($0.id) } }
    var organizationImages: [ImageAttachment] { session.imageLibrary.filter { organizationImageIDs.contains($0.id) } }
    var hasAskContext: Bool { !session.lines.isEmpty || !askImages.isEmpty || !session.chat.isEmpty }
    var hasOrganizationContext: Bool { !session.lines.isEmpty || !organizationImages.isEmpty }
    var organizationImagesChanged: Bool { Set(session.organized?.imageIDs ?? []) != organizationImageIDs }
    var selectedApp: AudioApp? { apps.first { $0.id == selectedPID } }
    var connectionLabel: String {
        guard !preferences.apiBase.isEmpty else { return "配置问答 API" }
        return URL(string: preferences.apiBase)?.host ?? "问答 API"
    }

    init() {
        capture.onChunk = { [weak self] chunk in Task { @MainActor in self?.submit(chunk) } }
        capture.onLevel = { [weak self] source, level in
            Task { @MainActor in
                guard let self else { return }
                if source == "麦克风" { self.levels.mic = level; self.lastMicSignal = Date() }
                else { self.levels.app = level; self.lastAppSignal = Date() }
            }
        }
        capture.onError = { [weak self] error in Task { @MainActor in
            guard let self else { return }
            self.error = error
            await self.stop()
        } }
        worker.onEvent = { [weak self] event in self?.receive(event) }
        refreshApps()
        history = SessionStore.all()
        // UI tests use a separate bundle identifier and a synthetic session, never a live recording.
        if Bundle.main.bundleIdentifier == "local.ListenFlow.preview",
           let path = ProcessInfo.processInfo.environment["LISTENFLOW_PREVIEW_SESSION"] ?? Bundle.main.path(forResource: "preview-session", ofType: "json"),
           let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
           let fixture = try? JSONDecoder().decode(MeetingSession.self, from: data) {
            session = fixture
            preferences.apiBase = ProcessInfo.processInfo.environment["LISTENFLOW_PREVIEW_API"] ?? "http://127.0.0.1:18764/v1"
            preferences.llmModel = "preview"
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    func refreshApps() {
        apps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
        }.map { AudioApp(id: $0.processIdentifier, name: $0.localizedName ?? "App", bundleID: $0.bundleIdentifier ?? "") }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        if !apps.contains(where: { $0.id == selectedPID }) { selectedPID = apps.first?.id ?? 0 }
    }

    func loadModel() {
        guard !isRecording, !isBusy, pending.isEmpty, !modelLoading else { return }
        error = nil
        modelLoading = true
        modelReady = false
        loadingSince = Date()
        modelStatus = "正在加载本地模型…"
        do { try worker.start(python: preferences.python, model: preferences.asrModel) }
        catch { modelLoading = false; modelStatus = "加载失败"; self.error = error.localizedDescription }
    }

    func toggleRecording() async {
        if isRecording { await stop() } else if canStartRecording { await start() }
    }

    /// Bring the main window forward, optionally focusing the question field, so a
    /// mid-session question never requires hunting for the window.
    func showMainWindow(focusQuestion: Bool = false) {
        NSApp.activate(ignoringOtherApps: true)
        for window in NSApp.windows where window.canBecomeMain {
            window.makeKeyAndOrderFront(nil)
            break
        }
        if focusQuestion { questionFocusToken += 1 }
    }

    func start() async {
        guard modelReady, !isBusy, !isRecording else { return }
        // A microphone-only session never needs a target app; an app session does.
        let app: AudioApp?
        switch source {
        case .microphone: app = nil
        case .app:
            guard let selected = selectedApp else { return }
            app = selected
        }
        isBusy = true
        error = nil
        let label = app?.name ?? AudioSource.microphone.label
        if session.lines.isEmpty && pending.isEmpty {
            session.created = Date()
            session.title = "\(label) · \(Date().formatted(date: .abbreviated, time: .shortened))"
        }
        do {
            if let app {
                try await capture.start(pid: app.id, name: app.name)
            } else {
                try await capture.startMicrophoneOnly()
            }
            activeSource = source
            isRecording = true
            micEnabled = source == .microphone
        } catch { self.error = error.localizedDescription }
        isBusy = false
    }

    func stop() async {
        guard !isBusy else { return }
        isBusy = true
        await capture.stop()
        isRecording = false
        micEnabled = false
        micBusy = false
        activeSource = nil
        levels.app = 0
        levels.mic = 0
        isBusy = false
        persist()
    }

    func toggleMic(_ value: Bool) async {
        guard isRecording, !isBusy, !micBusy else { return }
        micBusy = true
        do {
            try await capture.setMicrophone(value)
            micEnabled = value
        } catch { self.error = error.localizedDescription; micEnabled = false }
        micBusy = false
    }

    private func submit(_ chunk: AudioChunk) {
        guard modelReady else { return }
        pending[chunk.id] = chunk
        pendingCount = pending.count
        worker.submit(chunk, language: preferences.language, hotwords: preferences.hotwords)
        if pending.count >= 12 && isRecording && !isBusy {
            error = "识别暂时跟不上音频，已暂停采集以避免继续累积延迟。已采集的片段会继续处理。"
            Task { await stop() }
        }
    }

    private func receive(_ event: [String: Any]) {
        switch event["type"] as? String {
        case "status": modelStatus = event["message"] as? String ?? "正在加载…"
        case "ready":
            modelReady = true
            modelLoading = false
            loadingSince = nil
            modelStatus = "本地模型已就绪"
        case "result", "error":
            if let id = event["id"] as? String, let uuid = UUID(uuidString: id), let chunk = pending.removeValue(forKey: uuid) {
                if let text = event["text"] as? String, !text.isEmpty {
                    lastLatency = Date().timeIntervalSince(chunk.start)
                    session.lines.append(TranscriptLine(id: uuid, start: chunk.start, end: chunk.end,
                                                       source: chunk.source, text: text, latency: lastLatency))
                    session.lines.sort { $0.start < $1.start }
                    persist()
                }
                pendingCount = pending.count
            }
            if event["type"] as? String == "error" { error = "一个音频片段识别失败：\(event["message"] as? String ?? "未知错误")" }
        case "fatal": failWorker(event["message"] as? String ?? "本地识别进程异常。")
        default: break
        }
    }

    private func failWorker(_ message: String) {
        let unfinished = pending.count
        error = message + (unfinished > 0 ? " 尚有 \(unfinished) 段音频未完成识别。" : "")
        worker.shutdown()
        modelReady = false
        modelLoading = false
        modelStatus = "需要重新加载模型"
        pending.removeAll()
        pendingCount = 0
        if isRecording { Task { await stop() } }
    }

    private func tick() {
        let current = Date()
        // The elapsed-time readout is driven by a TimelineView, so this timer never
        // publishes a clock value — only real state changes reach the views.
        let age = pending.values.map { current.timeIntervalSince($0.start) }.max() ?? 0
        if age != oldestPending { oldestPending = age }
        if current.timeIntervalSince(lastAppSignal) > 1 && levels.app != 0 { levels.app = 0 }
        if current.timeIntervalSince(lastMicSignal) > 1 && levels.mic != 0 { levels.mic = 0 }
        if oldestPending > 40 { failWorker("识别等待超时，已停止采集。") }
        if modelLoading, let since = loadingSince, current.timeIntervalSince(since) > 120 { failWorker("本地模型加载超时，请检查 Python 环境与模型路径。") }
        if autoOrganize && !isOrganizing && !isImportingImages && hasOrganizationContext && (session.unorganizedCount > 0 || organizationImagesChanged) &&
            current.timeIntervalSince(lastOrganizationAttempt) >= 30 { organize() }
    }

    func applyPreferences(_ value: Preferences, key: String) throws {
        let changed = preferences.python != value.python || preferences.asrModel != value.asrModel
        if changed && (isRecording || isBusy || pendingCount > 0 || modelLoading) {
            throw CaptureFailure.message("请先暂停转写并等待识别完成，再切换本地模型。")
        }
        if !value.apiBase.isEmpty { _ = try LLMClient.endpoint(value.apiBase) }
        if !value.apiBase.isEmpty { try SecretStore.save(key, account: value.apiBase) }
        preferences = value
        value.save()
        if changed { loadModel() }
    }

    func ask(_ prompt: String? = nil) {
        var text = (prompt ?? question).trimmingCharacters(in: .whitespacesAndNewlines)
        let selectedImages = askImages
        guard !isAsking, !isImportingImages, hasAskContext, !text.isEmpty || !selectedImages.isEmpty else { return }
        if text.isEmpty { text = "请解释这些图片，结合已有转写（如有），区分图片和发言中的信息。" }
        guard !preferences.apiBase.isEmpty, !preferences.llmModel.isEmpty else { showSettings = true; return }
        error = nil
        question = ""
        let snapshot = session
        let settings = preferences
        let key = SecretStore.read(account: settings.apiBase)
        let contextEnd = snapshot.lines.last?.end
        session.chat.append(ChatMessage(role: "user", text: text, contextThrough: contextEnd, imageIDs: selectedImages.map(\.id)))
        let reply = ChatMessage(role: "assistant", text: "", contextThrough: contextEnd)
        session.chat.append(reply)
        isAsking = true
        // Stream into AnswerStream, not into `session`: publishing every delta on the
        // model would rebuild the sidebar, transcript and footer ~4x per second.
        answerStream.begin(reply.id)
        askTask = Task { [weak self] in
            guard let self else { return }
            do {
                let answer = try await LLMClient.ask(preferences: settings, key: key, session: snapshot, question: text, images: selectedImages) { [weak self] partial in
                    // Writes to the dedicated stream object, so only the answer view redraws.
                    self?.answerStream.update(partial)
                }
                if let index = self.session.chat.firstIndex(where: { $0.id == reply.id }) {
                    self.session.chat[index].text = answer
                }
            } catch {
                let cancelled = Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled
                // Keep whatever streamed in before the failure instead of dropping it.
                let partial = self.answerStream.state.text
                if let index = self.session.chat.firstIndex(where: { $0.id == reply.id }) {
                    if partial.isEmpty { self.session.chat.remove(at: index) }
                    else { self.session.chat[index].text = partial + "\n\n（\(cancelled ? "回答已停止" : "连接中断，回答未完成")）" }
                }
                if !cancelled {
                    self.error = error.localizedDescription
                    if self.question.isEmpty { self.question = text }
                }
            }
            self.answerStream.finish()
            self.isAsking = false
            self.persist()
        }
    }

    func cancelAsk() { askTask?.cancel() }

    func setAutoOrganize(_ enabled: Bool) {
        autoOrganize = enabled
        if enabled && (session.unorganizedCount > 0 || organizationImagesChanged) { organize() }
    }

    func organize() {
        guard hasOrganizationContext, !isOrganizing, !isImportingImages else { return }
        guard !preferences.apiBase.isEmpty, !preferences.llmModel.isEmpty else {
            autoOrganize = false; showSettings = true; return
        }
        let snapshot = session
        let selectedImages = organizationImages
        let settings = preferences
        let key = SecretStore.read(account: settings.apiBase)
        error = nil
        isOrganizing = true
        showOrganized = true
        organizationPreview.text = ""
        lastOrganizationAttempt = Date()

        // Incremental organizing: everything except the most recent batch is settled
        // and never re-sent, so earlier wording stays stable. The last batch is redone
        // together with the new lines, which gives the seam a natural overlap to
        // re-flow instead of cutting mid-paragraph.
        let existing = snapshot.organized?.segments ?? []
        let settled = existing.count > 1 ? Array(existing.dropLast()) : []
        let settledIDs = Set(settled.flatMap(\.sourceLineIDs))
        let settledText = settled.map(\.text).joined(separator: "\n\n")
        let pendingLines = snapshot.lines.filter { !settledIDs.contains($0.id) }
        let through = snapshot.lines.map(\.end).max() ?? snapshot.created

        organizeTask = Task { [weak self] in
            guard let self else { return }
            do {
                let parts = try await LLMClient.organize(preferences: settings, key: key,
                    session: snapshot, lines: pendingLines, images: selectedImages,
                    settledPrefix: settledText) { [weak self] text in
                        guard let self, self.session.id == snapshot.id else { return }
                        self.organizationPreview.text = text
                    }
                try Task.checkCancellation()
                guard self.session.id == snapshot.id else { return }
                let fresh = parts.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                    .map { OrganizedSegment(text: $0.text,
                                            sourceLineIDs: $0.lines.map(\.id),
                                            started: $0.lines.map(\.start).min() ?? through,
                                            through: $0.lines.map(\.end).max() ?? through) }
                let segments = settled + fresh
                guard !segments.isEmpty else { throw CaptureFailure.message("整理没有返回内容，已保留原文。") }
                self.session.organized = OrganizedTranscript(generatedAt: Date(), segments: segments,
                    imageIDs: selectedImages.map(\.id))
                self.persist()
            } catch {
                let cancelled = Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled
                self.autoOrganize = false // Avoid repeated billable retries after a failure.
                if !cancelled { self.error = "整理失败，原始转写和上一版整理稿已保留：\(error.localizedDescription)" }
            }
            self.isOrganizing = false
            self.organizationPreview.text = ""
            self.lastOrganizationAttempt = Date()
        }
    }

    func cancelOrganization() { autoOrganize = false; organizeTask?.cancel() }

    func selectImage(_ image: ImageAttachment, forOrganization: Bool, selected: Bool) {
        if forOrganization {
            guard !isOrganizing, !isImportingImages else { return }
            if selected && organizationImageIDs.count >= ImageAttachmentStore.maxSelected { error = "每次最多选择 6 张图片。"; return }
            if selected { organizationImageIDs.insert(image.id) } else { organizationImageIDs.remove(image.id) }
        } else {
            guard !isAsking, !isImportingImages else { return }
            if selected && askImageIDs.count >= ImageAttachmentStore.maxSelected { error = "每次最多选择 6 张图片。"; return }
            if selected { askImageIDs.insert(image.id) } else { askImageIDs.remove(image.id) }
        }
    }

    /// Mid-meeting grab of whatever is on screen: pick a region, and it lands in
    /// the session already selected for the pending question.
    func captureScreenshot(forOrganization: Bool = false) {
        guard !isImportingImages, !(forOrganization ? isOrganizing : isAsking) else { return }
        // Bring the window back afterwards, but get out of the way for the crosshair.
        NSApp.hide(nil)
        Task { @MainActor in
            let source = await ScreenshotCapture.captureInteractive()
            NSApp.unhide(nil)
            NSApp.activate(ignoringOtherApps: true)
            guard let source else { return }
            importImages([source], forOrganization: forOrganization)
        }
    }

    func importImages(forOrganization: Bool) {
        guard !isImportingImages, !(forOrganization ? isOrganizing : isAsking) else { return }
        let panel = NSOpenPanel()
        panel.title = forOrganization ? "添加整理参考图片" : "添加提问图片"
        panel.prompt = "添加图片"
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return }
        importImages(panel.urls.map(ImageImportSource.file), forOrganization: forOrganization)
    }

    /// Return false for ordinary text so the native editor can paste it at the cursor.
    func pasteAskImages(from pasteboard: NSPasteboard) -> Bool {
        do {
            let sources = try ClipboardImages.sources(from: pasteboard)
            guard !sources.isEmpty else { return false }
            guard !isAsking, !isImportingImages else { error = "请等待当前回答或图片添加完成，再粘贴图片。"; return true }
            importImages(sources, forOrganization: false)
            return true
        } catch {
            self.error = error.localizedDescription
            return true
        }
    }

    private func importImages(_ sources: [ImageImportSource], forOrganization: Bool) {
        guard !sources.isEmpty, !isImportingImages, !(forOrganization ? isOrganizing : isAsking) else { return }
        let selected = forOrganization ? organizationImageIDs : askImageIDs
        guard selected.count + sources.count <= ImageAttachmentStore.maxSelected else { error = "每次最多选择 6 张图片，请减少选择。"; return }
        let sessionID = session.id
        let firstNumber = (session.imageLibrary.map(\.number).max() ?? 0) + 1
        isImportingImages = true
        error = nil
        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> ([ImageAttachment], [String]) in
                var imported: [ImageAttachment] = [], failures: [String] = []
                for (index, source) in sources.enumerated() {
                    do { imported.append(try ImageAttachmentStore.importImage(source, sessionID: sessionID, number: firstNumber + index)) }
                    catch { failures.append(error.localizedDescription) }
                }
                return (imported, failures)
            }.value
            guard self.session.id == sessionID else { self.isImportingImages = false; return }
            self.session.images = self.session.imageLibrary + result.0
            if forOrganization { self.organizationImageIDs.formUnion(result.0.map(\.id)) }
            else { self.askImageIDs.formUnion(result.0.map(\.id)) }
            if self.session.title == "新的会话", !result.0.isEmpty { self.session.title = "图片资料 · \(Date().formatted(date: .abbreviated, time: .shortened))" }
            self.isImportingImages = false
            if !result.1.isEmpty { self.error = result.1.joined(separator: "\n") }
            self.persist()
        }
    }

    func newSession() {
        guard canChangeSession else { return }
        persist()
        session = MeetingSession()
        askImageIDs = []; organizationImageIDs = []
        showOrganized = false
        autoOrganize = false
        lastLatency = 0
    }
    func openSession(_ value: MeetingSession) {
        guard canChangeSession else { return }
        persist()
        session = value
        askImageIDs = Set((value.chat.last(where: { $0.role == "user" })?.imageIDs ?? []).prefix(ImageAttachmentStore.maxSelected))
        organizationImageIDs = Set((value.organized?.imageIDs ?? []).prefix(ImageAttachmentStore.maxSelected))
        showOrganized = value.organized != nil
        autoOrganize = false
        showHistory = false
    }
    func persist() {
        if Bundle.main.bundleIdentifier == "local.ListenFlow.preview" { return }
        guard !session.lines.isEmpty || !session.chat.isEmpty || !session.imageLibrary.isEmpty else { return }
        do { try SessionStore.save(session); history = SessionStore.all() }
        catch { self.error = "会话保存失败：\(error.localizedDescription)" }
    }
    func export() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(session.title.replacingOccurrences(of: "/", with: "-" )).md"
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try SessionStore.export(session, to: url) }
        catch { self.error = error.localizedDescription }
    }
    func shutdown() {
        askTask?.cancel()
        organizeTask?.cancel()
        persist()
        worker.shutdown()
    }
}
