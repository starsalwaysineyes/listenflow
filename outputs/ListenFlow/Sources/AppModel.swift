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

/// Text the cloud engine is still revising, per source. Kept off `AppModel` for
/// the same reason as `AnswerStream`: it changes several times a second.
@MainActor
final class LivePreview: ObservableObject {
    struct Item: Identifiable, Equatable {
        let source: String
        var text: String
        var id: String { source }
    }
    @Published private(set) var items: [Item] = []
    func set(_ source: String, _ text: String) {
        var next = items.filter { $0.source != source }
        if !text.isEmpty { next.append(Item(source: source, text: text)) }
        if next != items { items = next }
    }
    func clear() { if !items.isEmpty { items = [] } }
}

/// Hands captured audio to the right stream straight from the capture queue,
/// without a hop through the main actor for every buffer.
final class StreamRouter: @unchecked Sendable {
    private let lock = NSLock()
    private var streams: [String: VolcStream] = [:]
    func set(_ source: String, _ stream: VolcStream?) { lock.withLock { streams[source] = stream } }
    func append(_ source: String, _ samples: [Float], _ end: Date) {
        lock.withLock { streams[source] }?.append(samples, end: end)
    }
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
    /// Microphone lines dropped this session because they repeated the app's sound.
    @Published var echoDropped = 0
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
    /// Whether the second recognition pass is running right now (the mode resolved
    /// against the power source), and whether the Mac is on AC — for the status line.
    @Published var qualityActive = false
    @Published var onAC = true
    @Published var isPostRefining = false
    @Published var postRefineDone = 0
    @Published var postRefineTotal = 0
    /// A non-error outcome worth telling the user about, such as a finished refinement.
    @Published var notice: String?
    /// The notch island stays open while pinned; otherwise it follows the mouse.
    @Published var islandPinned = ProcessInfo.processInfo.environment["LISTENFLOW_PREVIEW_ISLAND"] == "expanded"
    private var island: NotchIslandController?
    private let capture = CaptureEngine()
    private let worker = ASRBridge()
    private var pending: [UUID: AudioChunk] = [:]
    private var pendingAudio: [UUID: AudioRef] = [:]
    /// Microphone lines waiting for the app source to catch up, so they can be
    /// compared with what the app said at the same time (see `EchoFilter`).
    private struct HeldLine {
        let line: TranscriptLine
        let chunk: AudioChunk?
        let since: Date
    }
    private var heldMic: [HeldLine] = []
    // Cloud engine: one stream per audio source, kept until its last result is in.
    let livePreview = LivePreview()
    /// Whether a Doubao key is stored; read once, not on every view update.
    @Published var volcKeyPresent = false
    @Published var cloudActivity = VolcStream.Activity.waiting
    /// Preview text exists, so the transcript is no longer empty.
    @Published var hasLivePartial = false
    private let router = StreamRouter()
    private var streamsByID: [UUID: VolcStream] = [:]
    private var activeStreams: [String: UUID] = [:]
    private var drainingStreams: Set<UUID> = []
    private var streamActivity: [UUID: VolcStream.Activity] = [:]
    private var partials: [String: String] = [:]
    private var replayLog: [[String: Any]]?
    private var replayStarted = Date()
    /// The replay harness's app chunker, standing in for live capture.
    private var replayAppChunker: AudioChunker?
    /// A joined stretch of one source's lines waiting to be re-recognized as a whole.
    private struct OpenWindow {
        var lineIDs: [UUID]
        var samples: [Float]
        var start: Date
        var end: Date
        var text: String
        var lastForced: Bool
        var touched: Date
    }
    private struct RefineJob {
        let id = UUID()
        let sessionID: UUID
        let lineIDs: [UUID]
        let samples: [Float]
        let original: String
        let dropStop: Bool
        let post: Bool
    }
    private var openWindows: [String: OpenWindow] = [:]
    private var refineQueue: [RefineJob] = []
    private var refineInFlight: RefineJob?
    private var postRefineChanged = 0
    private var askTask: Task<Void, Never>?
    private var organizeTask: Task<Void, Never>?
    private var lastOrganizationAttempt = Date.distantPast
    private var timer: Timer?
    private var loadingSince: Date?
    private var lastAppSignal = Date.distantPast
    private var lastMicSignal = Date.distantPast
    var canChangeSession: Bool { !isRecording && !isBusy && !isAsking && !isOrganizing && !isImportingImages && pendingCount == 0 && !isPostRefining }
    /// A microphone session can start with no app selected.
    var usesCloud: Bool { preferences.engine == .volc }
    /// The engine in use can take audio: a loaded local model, or a stored cloud key.
    var engineReady: Bool { usesCloud ? volcKeyPresent : modelReady }
    var engineStatus: String {
        guard usesCloud else { return modelStatus }
        guard volcKeyPresent else { return "未填写豆包 API Key" }
        guard isRecording || pendingCount > 0 else { return "豆包云端识别已就绪" }
        switch cloudActivity {
        case .waiting: return "豆包 · 等待声音"
        case .connecting: return "豆包 · 正在连接"
        case .live: return "豆包 · 识别中"
        case .reconnecting: return "豆包 · 正在重连"
        }
    }
    var canStartRecording: Bool {
        guard engineReady, !isBusy, !isRecording, !isPostRefining else { return false }
        return source == .microphone || selectedPID != 0
    }
    /// Whether the start/pause control is actionable right now. Stopping must stay
    /// available while recording — `canStartRecording` is false then by definition,
    /// so gating the button on it alone left the control dead exactly when it was
    /// needed. `isBusy` and `micBusy` still block: both `stop()` and `toggleMic()`
    /// bail out early in those states, so offering the action would do nothing.
    var canToggleRecording: Bool {
        guard !isBusy, !micBusy else { return false }
        if isRecording { return true }
        return canStartRecording
    }
    var askImages: [ImageAttachment] { session.imageLibrary.filter { askImageIDs.contains($0.id) } }
    var organizationImages: [ImageAttachment] { session.imageLibrary.filter { organizationImageIDs.contains($0.id) } }
    var hasAskContext: Bool { !session.lines.isEmpty || !askImages.isEmpty || !session.chat.isEmpty }
    var hasOrganizationContext: Bool { !session.lines.isEmpty || !organizationImages.isEmpty }
    var organizationImagesChanged: Bool { Set(session.organized?.imageIDs ?? []) != organizationImageIDs }
    /// While live text is still arriving in quality mode, the first line after the
    /// last re-recognized one: everything above it is settled, everything from it
    /// down is short live chunks that may still be merged and replaced.
    var liveTailStart: UUID? {
        guard !usesCloud, isRecording || pendingCount > 0,
              let last = session.lines.lastIndex(where: { $0.refined == true }),
              last + 1 < session.lines.count else { return nil }
        return session.lines[last + 1].id
    }

    /// The transcript was re-recognized after this draft was written.
    var organizationStale: Bool {
        guard let organized = session.organized, let refined = session.refinedAt else { return false }
        return refined > organized.generatedAt
    }
    /// Audio for this session is kept and there is at least one multi-line window to redo.
    var canRefineSession: Bool {
        !usesCloud && !isRecording && !isBusy && pending.isEmpty && !isPostRefining && modelReady
            && session.lines.contains { $0.audio != nil }
            && !Refinement.windows(session.lines, limit: Refinement.postWindow).isEmpty
    }
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
        refreshVolcKey()
        refreshApps()
        history = SessionStore.all()
        DispatchQueue.global(qos: .utility).async { AudioStore.purgeExpired() }
        updateRecognitionMode()
        // UI tests use a separate bundle identifier and a synthetic session, never a live recording.
        if Bundle.main.bundleIdentifier == "local.ListenFlow.preview",
           let path = ProcessInfo.processInfo.environment["LISTENFLOW_PREVIEW_SESSION"] ?? Bundle.main.path(forResource: "preview-session", ofType: "json"),
           let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
           let fixture = try? JSONDecoder().decode(MeetingSession.self, from: data) {
            session = fixture
            preferences.apiBase = ProcessInfo.processInfo.environment["LISTENFLOW_PREVIEW_API"] ?? "http://127.0.0.1:18764/v1"
            preferences.llmModel = "preview"
            // Screenshot checks of recording-only UI; no capture is started.
            if ProcessInfo.processInfo.environment["LISTENFLOW_PREVIEW_RECORDING"] == "1" { isRecording = true }
            // README screenshots: a meeting app plus the microphone, model ready.
            // Uses a stand-in app entry so no real running app names are shown.
            if ProcessInfo.processInfo.environment["LISTENFLOW_PREVIEW_DEMO"] == "1" {
                apps = [AudioApp(id: 1, name: "腾讯会议", bundleID: "com.tencent.meeting")]
                selectedPID = 1
                source = .app
                activeSource = .app
                micEnabled = true
                modelReady = true
                modelStatus = "本地模型已就绪"
                preferences.llmModel = "deepseek-flash"
            }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        runReplayIfRequested()
        if ProcessInfo.processInfo.environment["LISTENFLOW_REPLAY"] == nil {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if let h = ProcessInfo.processInfo.environment["LISTENFLOW_PREVIEW_ISLAND_HEIGHT"].flatMap(Double.init) {
                    self.preferences.islandHeight = h
                }
                if let w = ProcessInfo.processInfo.environment["LISTENFLOW_PREVIEW_ISLAND_WIDTH"].flatMap(Double.init) {
                    self.preferences.islandWidth = w
                }
                self.island = NotchIslandController(model: self)
            }
        }
        if Bundle.main.bundleIdentifier == "local.ListenFlow.preview",
           let folder = ProcessInfo.processInfo.environment["LISTENFLOW_PREVIEW_SNAPSHOT"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.snapshotViews(to: folder) }
        }
        // Lets UI checks capture the settings sheet without synthesizing keystrokes.
        if Bundle.main.bundleIdentifier == "local.ListenFlow.preview",
           ProcessInfo.processInfo.environment["LISTENFLOW_PREVIEW_SETTINGS"] == "1" { showSettings = true }
    }

    func refreshApps() {
        apps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
        }.map { AudioApp(id: $0.processIdentifier, name: $0.localizedName ?? "App", bundleID: $0.bundleIdentifier ?? "") }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        if !apps.contains(where: { $0.id == selectedPID }) { selectedPID = apps.first?.id ?? 0 }
    }

    /// Called when the window appears: only the local engine has anything to load.
    func prepareEngine() {
        if usesCloud { refreshVolcKey() } else if !modelReady && !modelLoading { loadModel() }
    }

    /// The key is read off the main thread: the Keychain may put up a prompt.
    private func refreshVolcKey() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let present = !AppModel.volcKey().isEmpty
            DispatchQueue.main.async { if self?.volcKeyPresent != present { self?.volcKeyPresent = present } }
        }
    }

    /// Preview and test builds take the key from the environment and never touch
    /// the Keychain; the real app only ever reads the Keychain.
    nonisolated private static func volcKey() -> String {
        if Bundle.main.bundleIdentifier == "local.ListenFlow.preview" {
            return ProcessInfo.processInfo.environment["VOLC_ASR_API_KEY"] ?? ""
        }
        return SecretStore.read(account: SecretStore.volcAccount)
    }

    func loadModel() {
        guard !usesCloud, !isRecording, !isBusy, pending.isEmpty, !modelLoading else { return }
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
        guard engineReady, !isBusy, !isRecording else { return }
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
            if usesCloud {
                let key = await Task.detached { AppModel.volcKey() }.value
                guard !key.isEmpty else {
                    volcKeyPresent = false
                    throw CaptureFailure.message("还没有填写豆包语音识别的 API Key。请在「模型与 API 设置」里填写，或切换到本地模型。")
                }
                cloudKey = key
                capture.onAudio = { [router] source, samples, end in router.append(source, samples, end) }
                openStream(app?.name ?? EchoFilter.micSource)
            } else {
                capture.onAudio = nil
            }
            if let app {
                try await capture.start(pid: app.id, name: app.name)
            } else {
                try await capture.startMicrophoneOnly()
            }
            activeSource = source
            isRecording = true
            micEnabled = source == .microphone
        } catch {
            self.error = error.localizedDescription
            cancelStreams()
        }
        isBusy = false
    }

    func stop() async {
        guard !isBusy else { return }
        isBusy = true
        await capture.stop()
        // The cloud engine still owes the last sentence: ask for it and wait.
        for source in Array(activeStreams.keys) { finishStream(source) }
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
            if usesCloud && value { openStream(EchoFilter.micSource) }
            try await capture.setMicrophone(value)
            micEnabled = value
        } catch { self.error = error.localizedDescription; micEnabled = false }
        if usesCloud && !micEnabled { finishStream(EchoFilter.micSource) }
        micBusy = false
    }

    // MARK: - Cloud engine

    private var cloudKey = ""

    private func openStream(_ source: String) {
        guard activeStreams[source] == nil else { return }
        let id = UUID()
        var settings = VolcStream.Settings(key: cloudKey, resourceID: preferences.volcResourceID,
                                           hotwords: preferences.hotwordList)
        // A microphone running next to an app hears the app through the speakers.
        // Measured: with the usual 1 s window an echo ran straight into the user's
        // reply as one 20 s sentence, and the service's final text kept only the
        // echo — 7 s of speech gone. At 200 ms each phrase is its own line, so
        // echoes are judged, and dropped, one phrase at a time.
        if source == EchoFilter.micSource && activeStreams.keys.contains(where: { $0 != EchoFilter.micSource }) {
            settings.endWindowMS = 200
        }
        let stream = VolcStream(source: source, settings: settings) { [weak self] event in
            self?.receive(event, from: id, source: source)
        }
        streamsByID[id] = stream
        activeStreams[source] = id
        router.set(source, stream)
    }

    /// No more audio for this source; its stream stays until the last result is in.
    private func finishStream(_ source: String) {
        guard let id = activeStreams.removeValue(forKey: source), let stream = streamsByID[id] else { return }
        router.set(source, nil)
        drainingStreams.insert(id)
        stream.finish()
        refreshPending()
    }

    private func cancelStreams() {
        for (source, _) in activeStreams { router.set(source, nil) }
        streamsByID.values.forEach { $0.cancel() }
        streamsByID.removeAll(); activeStreams.removeAll(); drainingStreams.removeAll()
        streamActivity.removeAll(); partials.removeAll()
        livePreview.clear()
        if hasLivePartial { hasLivePartial = false }
        refreshPending()
    }

    private func receive(_ event: VolcStream.Event, from id: UUID, source: String) {
        guard streamsByID[id] != nil else { return }
        switch event {
        case let .line(text, start, end):
            let line = TranscriptLine(start: start, end: end, source: source, text: text,
                                      latency: max(0, Date().timeIntervalSince(end)))
            replayLog?.append(["event": "line", "source": source, "text": text, "at": Date().timeIntervalSince(replayStarted)])
            if source == EchoFilter.micSource {
                heldMic.append(HeldLine(line: line, chunk: nil, since: Date()))
            } else {
                accept(line, chunk: nil)
            }
            settleHeldMic()
        case let .partial(text):
            if partials[source] != text {
                partials[source] = text.isEmpty ? nil : text
                if !text.isEmpty { replayLog?.append(["event": "partial", "source": source, "chars": text.count, "at": Date().timeIntervalSince(replayStarted)]) }
                refreshPreview()
            }
        case let .activity(value):
            streamActivity[id] = value
            refreshCloudActivity()
        case let .failed(message):
            error = message
            if isRecording { Task { await stop() } }
        case .drained:
            streamsByID[id] = nil
            streamActivity[id] = nil
            drainingStreams.remove(id)
            if activeStreams[source] == id { activeStreams[source] = nil; router.set(source, nil) }
            if activeStreams[source] == nil { partials[source] = nil }
            refreshPreview()
            refreshCloudActivity()
            settleHeldMic()
            refreshPending()
            persist()
        }
    }

    /// The microphone's preview is hidden while it only repeats what the app is
    /// saying, so an echo does not flicker in before its line is dropped.
    private func refreshPreview() {
        let appText = partials.filter { $0.key != EchoFilter.micSource }.values.joined()
            + session.lines.suffix(3).filter { $0.source != EchoFilter.micSource }.map(\.text).joined()
        for source in Set(partials.keys).union(livePreview.items.map(\.source)) {
            var text = partials[source] ?? ""
            if source == EchoFilter.micSource, !appText.isEmpty,
               EchoFilter.overlap(text, in: appText) >= EchoFilter.threshold { text = "" }
            livePreview.set(source, text)
        }
        let has = !livePreview.items.isEmpty
        if hasLivePartial != has { hasLivePartial = has }
    }

    private func refreshCloudActivity() {
        let all = Set(streamActivity.values)
        let value: VolcStream.Activity = all.contains(.reconnecting) ? .reconnecting
            : all.contains(.live) ? .live : all.contains(.connecting) ? .connecting : .waiting
        if cloudActivity != value { cloudActivity = value }
    }

    private func submit(_ chunk: AudioChunk) {
        guard modelReady else { return }
        pending[chunk.id] = chunk
        refreshPending()
        if preferences.keepAudioForRefine && (Bundle.main.bundleIdentifier != "local.ListenFlow.preview" || AudioStore.rootOverride != nil) {
            pendingAudio[chunk.id] = AudioStore.append(chunk.samples, session: session.id, source: chunk.source)
        }
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
            let failed = event["type"] as? String == "error"
            if let id = event["id"] as? String, let uuid = UUID(uuidString: id), let job = refineInFlight, job.id == uuid {
                // A refinement failing is harmless: the first-pass text stays.
                finishRefine(job, text: failed ? "" : event["text"] as? String ?? "")
                return
            }
            if let id = event["id"] as? String, let uuid = UUID(uuidString: id), let chunk = pending.removeValue(forKey: uuid) {
                let audio = pendingAudio.removeValue(forKey: uuid)
                let raw = event["text"] as? String ?? ""
                let text = chunk.forced ? Refinement.dropTrailingStop(raw) : raw
                if !text.isEmpty {
                    let line = TranscriptLine(id: uuid, start: chunk.start, end: chunk.end, source: chunk.source,
                                              text: text, latency: Date().timeIntervalSince(chunk.start), audio: audio)
                    // Every microphone line goes through the echo check; with no app
                    // audio in play it is released straight away.
                    if chunk.source == EchoFilter.micSource {
                        heldMic.append(HeldLine(line: line, chunk: chunk, since: Date()))
                    } else {
                        accept(line, chunk: chunk)
                    }
                } else {
                    closeWindow(chunk.source)     // nothing recognized: don't join across it
                }
                settleHeldMic()
                if !isRecording && pending.isEmpty && heldMic.isEmpty { closeAllWindows() }
                pumpRefine()
            }
            if failed { error = "一个音频片段识别失败：\(event["message"] as? String ?? "未知错误")" }
        case "fatal": failWorker(event["message"] as? String ?? "本地识别进程异常。")
        default: break
        }
    }

    private func accept(_ line: TranscriptLine, chunk: AudioChunk?) {
        lastLatency = chunk.map { Date().timeIntervalSince($0.start) } ?? line.latency
        session.lines.append(line)
        session.lines.sort { $0.start < $1.start }
        persist()
        if qualityActive, let chunk { addToWindow(chunk, lineID: line.id, text: line.text) }
    }

    private func refreshPending() {
        let count = pending.count + heldMic.count + drainingStreams.count
        if pendingCount != count { pendingCount = count }
    }

    /// Drop held microphone lines that repeat the app, and release the rest once
    /// every piece of app audio that began before they ended has been recognized.
    /// Normally that is well under a second; 12 s is only a backstop.
    private func settleHeldMic(force: Bool = false) {
        guard !heldMic.isEmpty else { return }
        // Cloud engine: app speech that has not been settled into a line yet.
        let appStreams = streamsByID.values.filter { $0.source != EchoFilter.micSource }
        let cloudOpen = appStreams.compactMap(\.openSpeechSince).min()
        let buffered = cloudOpen ?? replayAppChunker?.bufferedSince ?? capture.appBufferedSince()
        let now = Date()
        // What the app is saying right now counts too, even before it settles:
        // a cloud sentence can stay open for 20 s.
        var reference = session.lines
        for (source, text) in partials where source != EchoFilter.micSource {
            reference.append(TranscriptLine(start: cloudOpen ?? now.addingTimeInterval(-20), end: now, source: source, text: text, latency: 0))
        }
        // The cloud engine's preview of the app arrives within about a second, so
        // an echo is recognizable long before the app's sentence settles.
        let backstop: TimeInterval = appStreams.isEmpty ? 12 : 4
        var waiting: [HeldLine] = []
        for held in heldMic {
            if EchoFilter.isEcho(held.line, among: reference) { echoDropped += 1; continue }
            let end = held.line.end
            let appPending = pending.values.contains { $0.source != EchoFilter.micSource && $0.start < end }
            let appBuffering = buffered.map { $0 < end } ?? false
            if force || (!appPending && !appBuffering) || now.timeIntervalSince(held.since) > backstop {
                accept(held.line, chunk: held.chunk)
            } else {
                waiting.append(held)
            }
        }
        heldMic = waiting
        refreshPending()
    }

    // MARK: - Replay hooks
    func submitForReplay(_ chunk: AudioChunk) { submit(chunk) }
    func updateRecognitionModeForReplay() { updateRecognitionMode() }
    var replayIdle: Bool { pending.isEmpty && heldMic.isEmpty && streamsByID.isEmpty && refineQueue.isEmpty && refineInFlight == nil && openWindows.isEmpty }

    // MARK: - Second-pass recognition

    private func updateRecognitionMode() {
        let ac = PowerSource.onAC
        if ac != onAC { onAC = ac }
        let quality = !usesCloud && PowerSource.wantsQuality(preferences.recognitionMode)
        if quality != qualityActive {
            qualityActive = quality
            // Switching to economy mid-session: stop joining, but let windows that
            // are already queued finish, since that work is cheap and nearly done.
            if !quality { openWindows.removeAll() }
        }
    }

    private func addToWindow(_ chunk: AudioChunk, lineID: UUID, text: String) {
        if var window = openWindows[chunk.source] {
            let gap = chunk.start.timeIntervalSince(window.end)
            if gap <= 3 && chunk.end.timeIntervalSince(window.start) <= Refinement.liveWindow {
                // Pauses longer than this were dropped by the chunker; a short bridge
                // of silence keeps the joined words from running together.
                if gap > 0.02 { window.samples += [Float](repeating: 0, count: Int(min(gap, 0.3) * 16000)) }
                window.samples += chunk.samples
                window.lineIDs.append(lineID)
                window.end = chunk.end
                window.text += text
                window.lastForced = chunk.forced
                window.touched = Date()
                openWindows[chunk.source] = window
                // Long enough to benefit fully (gains flatten past ~20 s): go now.
                if window.end.timeIntervalSince(window.start) >= 14 { closeWindow(chunk.source) }
                return
            }
            closeWindow(chunk.source)
        }
        openWindows[chunk.source] = OpenWindow(lineIDs: [lineID], samples: chunk.samples, start: chunk.start,
                                               end: chunk.end, text: text, lastForced: chunk.forced, touched: Date())
    }

    private func closeWindow(_ source: String) {
        guard let window = openWindows.removeValue(forKey: source), window.lineIDs.count >= 2 else { return }
        refineQueue.append(RefineJob(sessionID: session.id, lineIDs: window.lineIDs, samples: window.samples,
                                     original: window.text, dropStop: window.lastForced, post: false))
        pumpRefine()
    }

    private func closeAllWindows() {
        for source in Array(openWindows.keys) { closeWindow(source) }
    }

    /// One refinement at a time, and only while no live chunk is waiting: live text
    /// always comes first, refinement fills the idle gaps between chunks.
    private func pumpRefine() {
        guard modelReady, refineInFlight == nil, pending.isEmpty, !refineQueue.isEmpty else { return }
        let job = refineQueue.removeFirst()
        refineInFlight = job
        worker.submit(id: job.id, samples: job.samples, language: preferences.language, hotwords: preferences.hotwords)
    }

    private func finishRefine(_ job: RefineJob, text raw: String) {
        refineInFlight = nil
        let text = job.dropStop ? Refinement.dropTrailingStop(raw) : raw
        if job.sessionID == session.id, Refinement.plausible(original: job.original, refined: text) {
            let ids = Set(job.lineIDs)
            let lines = session.lines.filter { ids.contains($0.id) }.sorted { $0.start < $1.start }
            if lines.count == job.lineIDs.count {
                let merged = Refinement.merge(lines, text: text)
                if Refinement.apply(merged, replacing: job.lineIDs, in: &session.lines) {
                    if job.post && merged.text != job.original { postRefineChanged += 1 }
                    persist()
                }
            }
        }
        // A job returning after the user stopped refinement must not complete it:
        // that would delete audio the user was told is still there.
        if job.post && isPostRefining {
            postRefineDone += 1
            if !refineQueue.contains(where: \.post) { finishPostRefine() }
        }
        pumpRefine()
    }

    private func resetRefinement() {
        openWindows.removeAll()
        refineQueue.removeAll()
        // An in-flight job is left to return; its session check discards it.
    }

    /// Re-recognize the whole stored session in ~30 s windows — the most accurate
    /// pass, meant for after a meeting recorded on battery.
    func refineSession() {
        guard canRefineSession else { return }
        let groups = Refinement.windows(session.lines, limit: Refinement.postWindow)
        var jobs: [RefineJob] = []
        for group in groups {
            guard let first = group.first?.audio, let last = group.last?.audio,
                  let samples = AudioStore.read(session: session.id, source: group[0].source, offset: first.offset,
                                                count: last.offset + last.count - first.offset) else { continue }
            jobs.append(RefineJob(sessionID: session.id, lineIDs: group.map(\.id), samples: samples,
                                  original: group.map(\.text).joined(), dropStop: false, post: true))
        }
        guard !jobs.isEmpty else { notice = "这段会话的暂存音频已不可用，无法精修。"; return }
        error = nil
        notice = nil
        openWindows.removeAll()
        refineQueue.removeAll { !$0.post }
        refineQueue += jobs
        postRefineDone = 0
        postRefineTotal = jobs.count
        postRefineChanged = 0
        isPostRefining = true
        pumpRefine()
    }

    func cancelRefineSession() {
        guard isPostRefining else { return }
        refineQueue.removeAll { $0.post }
        isPostRefining = false
        notice = "已停止精修，已完成的 \(postRefineDone) 处保留；暂存音频仍在，可以稍后继续。"
    }

    private func finishPostRefine() {
        isPostRefining = false
        session.refinedAt = Date()
        // The audio served its purpose; keeping it longer than needed is not the deal.
        AudioStore.delete(session.id)
        for index in session.lines.indices { session.lines[index].audio = nil }
        persist()
        notice = "全文精修完成：重新识别 \(postRefineTotal) 段，其中 \(postRefineChanged) 段文字有改动。暂存音频已删除。"
            + (session.organized != nil ? "整理稿下次更新时会按精修后的原文整篇重整。" : "")
    }

    private func failWorker(_ message: String) {
        let unfinished = pending.count
        error = message + (unfinished > 0 ? " 尚有 \(unfinished) 段音频未完成识别。" : "")
        worker.shutdown()
        modelReady = false
        modelLoading = false
        modelStatus = "需要重新加载模型"
        pending.removeAll()
        pendingAudio.removeAll()
        settleHeldMic(force: true)     // already recognized: keep them
        refreshPending()
        resetRefinement()
        if isPostRefining { isPostRefining = false; error = (error ?? "") + " 全文精修已中止，已完成的部分保留。" }
        if isRecording { Task { await stop() } }
    }

    private func tick() {
        let current = Date()
        // The elapsed-time readout is driven by a TimelineView, so this timer never
        // publishes a clock value — only real state changes reach the views.
        updateRecognitionMode()
        settleHeldMic()
        // A speaker who paused for a while has finished a thought: refine it now
        // rather than waiting for the next chunk to close the window.
        for (source, window) in openWindows where current.timeIntervalSince(window.touched) > 4 { closeWindow(source) }
        if !isRecording && pending.isEmpty && heldMic.isEmpty { closeAllWindows() }
        let age = pending.values.map { current.timeIntervalSince($0.start) }.max() ?? 0
        if age != oldestPending { oldestPending = age }
        if current.timeIntervalSince(lastAppSignal) > 1 && levels.app != 0 { levels.app = 0 }
        if current.timeIntervalSince(lastMicSignal) > 1 && levels.mic != 0 { levels.mic = 0 }
        if oldestPending > 40 { failWorker("识别等待超时，已停止采集。") }
        if modelLoading, let since = loadingSince, current.timeIntervalSince(since) > 120 { failWorker("本地模型加载超时，请检查 Python 环境与模型路径。") }
        if autoOrganize && !isOrganizing && !isImportingImages && hasOrganizationContext && (session.unorganizedCount > 0 || organizationImagesChanged || organizationStale) &&
            current.timeIntervalSince(lastOrganizationAttempt) >= 30 { organize() }
    }

    /// `volcKey` is nil when the field was left as loaded, so a key that could
    /// not be read is never overwritten with nothing.
    func applyPreferences(_ value: Preferences, key: String, volcKey: String? = nil) throws {
        let engineChanged = preferences.engine != value.engine
        let changed = preferences.python != value.python || preferences.asrModel != value.asrModel
        if (changed || engineChanged) && (isRecording || isBusy || pendingCount > 0 || modelLoading) {
            throw CaptureFailure.message("请先暂停转写并等待识别完成，再切换识别引擎或本地模型。")
        }
        if value.engine == .volc && value.volcResourceID.trimmingCharacters(in: .whitespaces).isEmpty {
            throw CaptureFailure.message("请填写豆包的资源 ID，小时版为 volc.seedasr.sauc.duration。")
        }
        if !value.apiBase.isEmpty { _ = try LLMClient.endpoint(value.apiBase) }
        if !value.apiBase.isEmpty { try SecretStore.save(key, account: value.apiBase) }
        if let volcKey {
            let trimmed = volcKey.trimmingCharacters(in: .whitespacesAndNewlines)
            try SecretStore.save(trimmed, account: SecretStore.volcAccount)
            volcKeyPresent = !trimmed.isEmpty
        }
        preferences = value
        preferences.volcResourceID = value.volcResourceID.trimmingCharacters(in: .whitespaces)
        preferences.save()
        updateRecognitionMode()
        if value.engine == .local {
            if changed || engineChanged || (!modelReady && !modelLoading) { loadModel() }
        } else if engineChanged {
            // The local model holds about 2.7 GB; release it while the cloud is in use.
            worker.shutdown()
            modelReady = false
            modelLoading = false
            loadingSince = nil
            modelStatus = "模型尚未加载"
            resetRefinement()
        }
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
        // After a whole-transcript refinement the old wording is gone, so nothing
        // from the earlier draft can be treated as settled.
        let stale = organizationStale
        let existing = stale ? [] : snapshot.organized?.segments ?? []
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
        echoDropped = 0
        resetRefinement()
        askImageIDs = []; organizationImageIDs = []
        showOrganized = false
        autoOrganize = false
        lastLatency = 0
    }
    func openSession(_ value: MeetingSession) {
        guard canChangeSession else { return }
        persist()
        session = value
        echoDropped = 0
        resetRefinement()
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
        cancelStreams()
        worker.shutdown()
    }
}

// MARK: - Replay harness (preview builds only)

extension AppModel {
    /// Feeds raw 16 kHz mono PCM through the real chunker → worker → refinement path
    /// at a fixed speed-up, then writes the session to JSON. Only the preview
    /// bundle honours this, so a shipping build can never be driven by it.
    func runReplayIfRequested() {
        let env = ProcessInfo.processInfo.environment
        guard Bundle.main.bundleIdentifier == "local.ListenFlow.preview", let path = env["LISTENFLOW_REPLAY"],
              var out = env["LISTENFLOW_REPLAY_OUT"] else { return }
        AudioStore.rootOverride = FileManager.default.temporaryDirectory.appendingPathComponent("listenflow-replay-audio")
        Task { @MainActor in
            let wav = (try? Data(contentsOf: URL(fileURLWithPath: path))) ?? Data()
            // Raw 16 kHz mono Int16 LE, no header: WAV headers vary in length.
            let samples = wav.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }.map { Float($0) / 32768 }
            if env["LISTENFLOW_REPLAY_ENGINE"] == "volc" {
                let track = env["LISTENFLOW_REPLAY_MIC"].flatMap { try? Data(contentsOf: URL(fileURLWithPath: $0)) } ?? Data()
                preferences.engine = .volc
                await replayCloud(app: samples, mic: track.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }.map { Float($0) / 32768 },
                                  env: env, out: out)
                guard env["LISTENFLOW_REPLAY_THEN_LOCAL"] == "1" else { NSApp.terminate(nil); return }
                // Switch engines in the same process, the way the settings sheet
                // does. The question API is blanked so no key is written.
                var next = preferences
                next.engine = .local
                next.apiBase = ""
                do { try applyPreferences(next, key: "") }
                catch { write(out + "-local-live.json", extra: ["error": error.localizedDescription]); NSApp.terminate(nil); return }
                out += "-local"
            } else {
                preferences.engine = .local
                loadModel()
            }
            while !modelReady { try? await Task.sleep(nanoseconds: 200_000_000) }
            preferences.recognitionMode = RecognitionMode(rawValue: env["LISTENFLOW_REPLAY_MODE"] ?? "") ?? .economy
            preferences.keepAudioForRefine = true
            updateRecognitionModeForReplay()
            session = MeetingSession(title: "replay", created: Date())
            isRecording = true
            let started = Date()
            let speed = Double(env["LISTENFLOW_REPLAY_SPEED"] ?? "4") ?? 4
            let chunker = AudioChunker(source: "回放") { [weak self] chunk in
                MainActor.assumeIsolated { self?.submitForReplay(chunk) }
            }
            // Optional second track played as the microphone alongside the first
            // (the app), to exercise the echo filter end to end.
            let micData = env["LISTENFLOW_REPLAY_MIC"].flatMap { try? Data(contentsOf: URL(fileURLWithPath: $0)) } ?? Data()
            let mic = micData.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }.map { Float($0) / 32768 }
            let micChunker = AudioChunker(source: EchoFilter.micSource) { [weak self] chunk in
                MainActor.assumeIsolated { self?.submitForReplay(chunk) }
            }
            replayAppChunker = chunker
            var offset = 0
            let total = max(samples.count, mic.count)
            while offset < total {
                let n = min(1024, total - offset)
                let end = session.created.addingTimeInterval(Double(offset + n) / 16000)
                if offset < samples.count { chunker.append(Array(samples[offset..<min(offset + n, samples.count)]), end: end) }
                if offset < mic.count { micChunker.append(Array(mic[offset..<min(offset + n, mic.count)]), end: end) }
                offset += n
                try? await Task.sleep(nanoseconds: UInt64(Double(n) / 16000 / speed * 1_000_000_000))
            }
            chunker.flush()
            micChunker.flush()
            replayAppChunker = nil
            isRecording = false
            let wall = Date().timeIntervalSince(started)
            while !replayIdle { try? await Task.sleep(nanoseconds: 200_000_000) }
            write(out + "-live.json", extra: ["wallSeconds": wall, "echoDropped": echoDropped])
            if env["LISTENFLOW_REPLAY_REFINE"] == "1" {
                refineSession()
                while isPostRefining { try? await Task.sleep(nanoseconds: 200_000_000) }
                write(out + "-post.json", extra: ["notice": notice ?? ""])
            }
            AudioStore.delete(session.id)
            NSApp.terminate(nil)
        }
    }

    /// The cloud engine end to end: the same streams, events and stop path as a
    /// live session, fed from a file on the capture clock. Costs real audio time.
    private func replayCloud(app: [Float], mic: [Float], env: [String: String], out: String) async {
        cloudKey = AppModel.volcKey()
        guard !cloudKey.isEmpty else {
            write(out + "-live.json", extra: ["error": "VOLC_ASR_API_KEY is not set"])
            return
        }
        volcKeyPresent = true
        if let resource = env["LISTENFLOW_REPLAY_RESOURCE"] { preferences.volcResourceID = resource }
        updateRecognitionModeForReplay()
        session = MeetingSession(title: "replay", created: Date())
        replayStarted = session.created
        replayLog = []
        isRecording = true
        activeSource = .app
        openStream("回放")
        if !mic.isEmpty { openStream(EchoFilter.micSource); micEnabled = true }
        let speed = Double(env["LISTENFLOW_REPLAY_SPEED"] ?? "1") ?? 1
        let dropAt = env["LISTENFLOW_REPLAY_DROP_AT"].flatMap(Double.init)
        var dropped = false
        var offset = 0
        let total = max(app.count, mic.count)
        while offset < total && isRecording {
            let n = min(1024, total - offset)
            let end = session.created.addingTimeInterval(Double(offset + n) / 16000)
            if offset < app.count { router.append("回放", Array(app[offset..<min(offset + n, app.count)]), end) }
            if offset < mic.count { router.append(EchoFilter.micSource, Array(mic[offset..<min(offset + n, mic.count)]), end) }
            offset += n
            if let dropAt, !dropped, Double(offset) / 16000 >= dropAt {
                dropped = true
                streamsByID.values.forEach { $0.simulateDrop() }
                replayLog?.append(["event": "drop", "at": Date().timeIntervalSince(replayStarted)])
            }
            // Paced against the clock, not by summing sleeps, so it stays real time.
            let due = replayStarted.addingTimeInterval(Double(offset) / 16000 / speed).timeIntervalSinceNow
            if due > 0 { try? await Task.sleep(nanoseconds: UInt64(due * 1_000_000_000)) }
        }
        let fed = Date()
        replayLog?.append(["event": "pause", "at": fed.timeIntervalSince(replayStarted)])
        for source in Array(activeStreams.keys) { finishStream(source) }      // what stop() does
        isRecording = false
        micEnabled = false
        activeSource = nil
        while !replayIdle { try? await Task.sleep(nanoseconds: 100_000_000) }
        write(out + "-live.json", extra: ["fedSeconds": fed.timeIntervalSince(replayStarted),
                                          "drainSeconds": Date().timeIntervalSince(fed), "echoDropped": echoDropped,
                                          "events": replayLog ?? [], "error": error ?? ""])
        replayLog = nil
    }

    /// Renders the main window and the settings sheet for both engines to PNG files
    /// without putting a window on screen, so layout can be checked on a locked
    /// or headless Mac. Preview builds only.
    func snapshotViews(to folder: String) {
        func shot<V: View>(_ view: V, _ size: NSSize, _ name: String) {
            let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
            host.frame = NSRect(origin: .zero, size: size)
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.8))
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
            host.cacheDisplay(in: host.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: folder + "/" + name + ".png"))
        }
        showSettings = false
        for engine in RecognitionEngine.allCases {
            preferences.engine = engine
            volcKeyPresent = true
            if engine == .volc {
                livePreview.set(apps.first?.name ?? "App", "接下来说一下用户访谈的情况，这周一共约到了")
                hasLivePartial = true
                cloudActivity = .live
            } else {
                livePreview.clear()
                hasLivePartial = false
            }
            shot(ContentView(model: self), NSSize(width: 1220, height: 800), "main-\(engine.rawValue)")
            shot(SettingsView(model: self), NSSize(width: 650, height: 690), "settings-\(engine.rawValue)")
        }
        NSApp.terminate(nil)
    }

    private func write(_ path: String, extra: [String: Any]) {
        var object: [String: Any] = extra
        object["lines"] = session.lines.map { ["text": $0.text, "source": $0.source, "latency": $0.latency, "start": $0.start.timeIntervalSince(session.created),
                                                "end": $0.end.timeIntervalSince(session.created)] }
        if let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted]) {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }
}
