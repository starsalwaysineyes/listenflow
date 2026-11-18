import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct AudioApp: Identifiable, Hashable {
    let id: pid_t
    let name: String
    let bundleID: String
}

/// Where a session's audio comes from. `all` is everything at once — whatever the
/// Mac is playing plus the microphone — and needs no choosing, so it is the
/// default. In-person classes need the microphone alone; picking one app keeps
/// notification sounds and other windows out.
enum AudioSource: String, Codable, CaseIterable, Identifiable {
    case all
    case microphone
    case app
    var id: String { rawValue }
    var label: String {
        switch self {
        case .all: "全局声音"
        case .microphone: "我的麦克风"
        case .app: "指定 App"
        }
    }
    /// For the three-way picker in the narrow sidebar.
    var shortLabel: String {
        switch self {
        case .all: "全局"
        case .microphone: "麦克风"
        case .app: "指定 App"
        }
    }
    var detail: String {
        switch self {
        case .all: "电脑上所有 App 的声音和麦克风一起录，不用选 App"
        case .microphone: "线下课堂、线下会议；只用本机麦克风"
        case .app: "腾讯会议、网课、播放器；只接收所选 App 的声音"
        }
    }
    /// Name on transcript lines that came from the Mac's own sound.
    static let systemName = "电脑声音"
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

@MainActor
final class AppModel: ObservableObject {
    @Published var preferences = Preferences.load()
    @Published var apps: [AudioApp] = []
    @Published var selectedPID: pid_t = 0
    @Published var session = MeetingSession()
    /// The session list. Summaries only: whole sessions stay on disk until opened.
    @Published var history: [SessionSummary] = []
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
    @Published var isOrganizing = false
    @Published var isImportingImages = false
    @Published var isCapturingShot = false
    /// Names and terms the recognizer is told to expect; see `HotwordStore`.
    @Published var hotwords: [String] = []
    private var hotwordsStamp: Date?
    /// Goes up with every screenshot kept, so views can confirm the click.
    @Published var shotsTaken = 0
    @Published var organizationImageIDs: Set<UUID> = []
    let organizationPreview = OrganizationPreview()
    @Published var showOrganized = false
    @Published var autoOrganize = false
    @Published var showSettings = false
    /// Bumped by the menu command; the title in the main window turns into a field.
    @Published var renameToken = 0
    /// The session the window is asking about deleting.
    @Published var deleteCandidate: SessionSummary?
    @Published var source: AudioSource = .all
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
    /// Seconds of streamed speech kept on disk for this session (cloud engine).
    /// Kept speech that no finished refinement has covered yet, and all of it.
    @Published var keptStreamSeconds: Double = 0
    @Published var savedStreamSeconds: Double = 0
    private var cloudRefineTask: Task<Void, Never>?
    /// Audio per upload; the replay harness shortens it to exercise the cutting.
    private var cloudChunkSeconds = VolcRecording.chunkSeconds
    private let writer = SessionWriter()
    /// Kept-audio files may be open; closed again once recording has wound down.
    private var audioOpen = false
    private var organizeTask: Task<Void, Never>?
    private var lastOrganizationAttempt = Date.distantPast
    private var timer: Timer?
    private var loadingSince: Date?
    private var lastAppSignal = Date.distantPast
    private var lastMicSignal = Date.distantPast
    var canChangeSession: Bool { !isRecording && !isBusy && !isOrganizing && !isImportingImages && !isCapturingShot && pendingCount == 0 && !isPostRefining }
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
        return source != .app || selectedPID != 0
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
    var organizationImages: [ImageAttachment] { session.imageLibrary.filter { organizationImageIDs.contains($0.id) } }
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
    /// Audio for this session is kept and there is something to redo: with the
    /// local engine at least one multi-line window, with the cloud any kept speech.
    var canRefineSession: Bool {
        guard !isRecording, !isBusy, !isPostRefining else { return false }
        if usesCloud { return pendingCount == 0 && volcKeyPresent && keptStreamSeconds > 0 }
        return pending.isEmpty && modelReady
            && session.lines.contains { $0.audio != nil }
            && !Refinement.windows(session.lines, limit: Refinement.postWindow).isEmpty
    }
    /// For the footer: this session has audio on disk, or is about to.
    var keepsAudio: Bool {
        session.lines.contains { $0.audio != nil } || savedStreamSeconds > 0
            || (isRecording && usesCloud && preferences.keepAudioForRefine)
    }
    var selectedApp: AudioApp? { apps.first { $0.id == selectedPID } }
    /// Whether a session holds anything worth keeping or showing.
    var sessionIsEmpty: Bool { session.lines.isEmpty && session.chat.isEmpty && session.imageLibrary.isEmpty }

    init() {
        // Tests of the command line tool: a preview build that keeps its sessions
        // and audio in a folder of the test's own, where the tool can read them.
        if ListenFlowHome.isPreview, let store = ProcessInfo.processInfo.environment["LISTENFLOW_PREVIEW_STORE"] {
            let root = URL(fileURLWithPath: store, isDirectory: true)
            SessionStore.folderOverride = root.appendingPathComponent("Sessions", isDirectory: true)
            AudioStore.rootOverride = root.appendingPathComponent("audio", isDirectory: true)
            HotwordStore.fileOverride = root.appendingPathComponent("hotwords.txt")
        }
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
        writer.onError = { [weak self] message in self?.error = "会话保存失败：\(message)" }
        // Up to 0.10.1 hot words were a line of text in the settings.
        if HotwordStore.modified() == nil, !preferences.hotwordList.isEmpty { try? HotwordStore.save(preferences.hotwordList) }
        reloadHotwords()
        loadHistory()
        // Kept audio is no longer cleared out after a week: it stays with its session.
        DispatchQueue.global(qos: .utility).async {
            if !ListenFlowHome.isPreview { AudioStore.adoptLegacy() }
        }
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
        timer?.tolerance = 0.2
        runReplayIfRequested()
        // Headless runs have no use for the island, and it would sit over the real one.
        if !AppDelegate.headless {
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
        // Checks of `lstf` against a running app: sit there without a window,
        // answer requests for this many seconds, then quit as a user would.
        if ListenFlowHome.isPreview, let seconds = ProcessInfo.processInfo.environment["LISTENFLOW_PREVIEW_SERVE"].flatMap(Double.init) {
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { NSApp.terminate(nil) }
        }
        if ListenFlowHome.isPreview, let path = ProcessInfo.processInfo.environment["LISTENFLOW_PREVIEW_DELETECHECK"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.deleteCheck(to: path) }
        }
        if ListenFlowHome.isPreview, let path = ProcessInfo.processInfo.environment["LISTENFLOW_PREVIEW_SCROLLCHECK"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.scrollCheck(to: path) }
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

    /// The key is read off the main thread: it is a file read, and the first
    /// time after an update the Keychain may put up a prompt.
    private func refreshVolcKey() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let present = !AppModel.volcKey().isEmpty
            DispatchQueue.main.async { if self?.volcKeyPresent != present { self?.volcKeyPresent = present } }
        }
    }

    /// Preview and test builds take the key from the environment only; the real
    /// app reads `~/.listenflow/keys.json`.
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

    func showMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        for window in NSApp.windows where window.canBecomeMain {
            window.makeKeyAndOrderFront(nil)
            break
        }
    }

    /// The list is a file that `lstf` may change at any time. Streams that are
    /// running pick the new list up with their next connection.
    private func reloadHotwords() {
        hotwordsStamp = HotwordStore.modified()
        let words = HotwordStore.load()
        guard words != hotwords else { return }
        hotwords = words
        streamsByID.values.forEach { $0.setHotwords(words) }
    }

    /// From the settings sheet: one or several terms, separated by commas.
    func addHotwords(_ text: String) {
        do {
            let change = try HotwordStore.add(HotwordStore.terms(text))
            if !change.refused.isEmpty { error = "没有加进热词：" + change.refused.joined(separator: "、") }
        } catch { self.error = "热词没有保存下来：\(error.localizedDescription)" }
        reloadHotwords()
    }

    func removeHotword(_ word: String) {
        do { _ = try HotwordStore.remove([word]) }
        catch { self.error = "热词没有保存下来：\(error.localizedDescription)" }
        reloadHotwords()
    }

    /// Read off the main thread: launch does not wait for it, however many
    /// sessions there are. Sessions saved in the meantime keep their newer row.
    private func loadHistory() {
        // A preview build with no store of its own must not list real sessions.
        guard SessionStore.writes else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let stored = SessionStore.summaries()
            DispatchQueue.main.async {
                guard let self else { return }
                let newer = self.history
                self.history = stored
                newer.forEach(self.remember)
            }
        }
    }

    /// Put a session's row in the list, or bring it up to date.
    private func remember(_ summary: SessionSummary) {
        if let index = history.firstIndex(where: { $0.id == summary.id }) {
            if history[index] != summary { history[index] = summary }
        } else {
            history.insert(summary, at: history.firstIndex { $0.created < summary.created } ?? history.count)
        }
    }

    func start() async {
        guard engineReady, !isBusy, !isRecording else { return }
        // Only an app session needs a target app.
        let app: AudioApp?
        switch source {
        case .all, .microphone: app = nil
        case .app:
            guard let selected = selectedApp else { return }
            app = selected
        }
        let source = source
        // What the non-microphone lines are called; nil when only the microphone runs.
        let playback = source == .all ? AudioSource.systemName : app?.name
        isBusy = true
        error = nil
        audioOpen = true
        let label = app?.name ?? source.label
        if session.lines.isEmpty && pending.isEmpty {
            session.created = Date()
            if session.renamed != true { session.title = "\(label) · \(Date().formatted(date: .abbreviated, time: .shortened))" }
        }
        do {
            if usesCloud {
                let key = await Task.detached { AppModel.volcKey() }.value
                guard !key.isEmpty else {
                    volcKeyPresent = false
                    throw CaptureFailure.message("还没有填写豆包语音识别的 API Key。请在「设置」里填写，或切换到本地模型。")
                }
                cloudKey = key
                capture.onAudio = { [router] source, samples, end in router.append(source, samples, end) }
                openStream(playback ?? EchoFilter.micSource)
            } else {
                capture.onAudio = nil
            }
            if let playback {
                try await capture.start(pid: app?.id, name: playback)
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
        // Everything at once: the microphone joins as soon as the Mac's sound is
        // running. Without it (no permission, no input device) the session
        // carries on with what the Mac plays, and says why. Still busy, so a
        // stop cannot slip in while the permission prompt is up.
        if isRecording && source == .all {
            await setMic(true)
            if !micEnabled, let reason = error { error = "麦克风没有打开，目前只在转写电脑上的声音。\(reason)" }
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
        await setMic(value)
    }

    private func setMic(_ value: Bool) async {
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
        var settings = VolcStream.Settings(key: cloudKey, resourceID: preferences.volcResourceID, hotwords: hotwords,
                                           tables: VolcTables(boosting: preferences.volcBoostingTableID))
        // A microphone running next to an app hears the app through the speakers.
        // Measured: with the usual 1 s window an echo ran straight into the user's
        // reply as one 20 s sentence, and the service's final text kept only the
        // echo — 7 s of speech gone. At 200 ms each phrase is its own line, so
        // echoes are judged, and dropped, one phrase at a time.
        if source == EchoFilter.micSource && activeStreams.keys.contains(where: { $0 != EchoFilter.micSource }) {
            settings.endWindowMS = 200
        }
        // Keep what is streamed, so the session can be refined from the recording.
        let keeping = preferences.keepAudioForRefine && (!ListenFlowHome.isPreview || AudioStore.rootOverride != nil)
        let kept = AudioStore.streamFile(session: session.id, source: source)
        let stream = VolcStream(source: source, settings: settings, keep: keeping ? { pcm, start in
            AudioStore.appendStream(pcm, to: kept, spanStart: start)
        } : nil) { [weak self] event in
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
            refreshKeptAudio()
            persist()
        }
    }

    private func refreshKeptAudio() {
        let id = session.id
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let seconds = AudioStore.unrefinedStreamSeconds(id), saved = AudioStore.streamSeconds(id)
            DispatchQueue.main.async {
                guard let self, self.session.id == id else { return }
                if self.keptStreamSeconds != seconds { self.keptStreamSeconds = seconds }
                if self.savedStreamSeconds != saved { self.savedStreamSeconds = saved }
            }
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
        worker.submit(chunk, language: preferences.language, hotwords: hotwords.joined(separator: ","))
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
        // The power source only matters to the local engine; with the cloud
        // engine it is not asked for at all, let alone once a second.
        if !usesCloud {
            let ac = PowerSource.onAC
            if ac != onAC { onAC = ac }
        }
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
        worker.submit(id: job.id, samples: job.samples, language: preferences.language, hotwords: hotwords.joined(separator: ","))
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
        if usesCloud { refineSessionCloud(); return }
        let groups = Refinement.windows(session.lines, limit: Refinement.postWindow)
        var jobs: [RefineJob] = []
        for group in groups {
            guard let first = group.first?.audio, let last = group.last?.audio,
                  let samples = AudioStore.read(session: session.id, source: group[0].source, offset: first.offset,
                                                count: last.offset + last.count - first.offset) else { continue }
            jobs.append(RefineJob(sessionID: session.id, lineIDs: group.map(\.id), samples: samples,
                                  original: group.map(\.text).joined(), dropStop: false, post: true))
        }
        guard !jobs.isEmpty else { notice = "这段会话的录音已不可用，无法精修。"; return }
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
        cloudRefineTask?.cancel()
        isPostRefining = false
        notice = "已停止精修，已完成的 \(postRefineDone) 处保留，可以稍后继续。"
    }

    private func finishPostRefine() {
        isPostRefining = false
        session.refinedAt = Date()
        // The audio stays, and the lines keep pointing into it: a better model may want it one day.
        persist()
        notice = "全文精修完成：重新识别 \(postRefineTotal) 段，其中 \(postRefineChanged) 段文字有改动。录音保留在本机。"
            + (session.organized != nil ? "整理稿下次更新时会按精修后的原文整篇重整。" : "")
    }

    // MARK: - Cloud refinement

    private struct CloudUpload: Sendable {
        let source: String
        let spans: [AudioSpan]
        /// A microphone recorded while the app was audible: sentences are cut on
        /// pauses, so the echo can be told from the reply one phrase at a time.
        var split = false
        var seconds: TimeInterval { Double(spans.reduce(0) { $0 + $1.count }) / 16000 }
    }

    /// The session's kept speech as uploads of a few minutes each. A stretch too
    /// long for one upload is cut at its quietest moment, which means reading
    /// the audio, so this runs off the main thread.
    nonisolated private static func cloudUploads(session: UUID, limit: TimeInterval) -> [CloudUpload] {
        let all = AudioStore.streamSpans(session)
        let done = AudioStore.refinedSamples(session)
        let spans = VolcRecording.remaining(all, after: done)
        // App sources first: the microphone's echo check reads their text.
        let sources = spans.keys.sorted { ($0 == EchoFilter.micSource ? 1 : 0, $0) < ($1 == EchoFilter.micSource ? 1 : 0, $1) }
        let played = all.filter { $0.key != EchoFilter.micSource }.flatMap(\.value)
        return sources.flatMap { source in
            VolcRecording.plan(spans[source] ?? [], limit: Int(limit * 16000),
                               search: Int(VolcRecording.cutSearchSeconds * 16000)) { range in
                guard let pcm = AudioStore.readStream(session: session, source: source, offset: range.lowerBound,
                                                      count: range.count) else { return range.upperBound }
                return range.lowerBound + VolcRecording.quietest(in: pcm)
            }.map { part in
                CloudUpload(source: source, spans: part, split: source == EchoFilter.micSource
                            && VolcRecording.overlap(part, with: played) >= VolcRecording.echoOverlap)
            }
        }
    }

    /// Two uploads at a time; each result is handed over as soon as it is in.
    nonisolated private static func recognize(_ uploads: [CloudUpload], session: UUID, client: VolcFileClient,
                                              hotwords: [String], tables: VolcTables,
                                              apply: @MainActor @Sendable (Int, [VolcUtterance]) -> Void) async throws {
        try await withThrowingTaskGroup(of: (Int, [VolcUtterance]).self) { group in
            var next = 0, running = 0
            while true {
                while next < uploads.count && running < 2 {
                    let index = next, upload = uploads[index]
                    group.addTask {
                        var parts: [Data] = []
                        for span in upload.spans {
                            guard let pcm = AudioStore.readStream(session: session, source: upload.source,
                                                                  offset: span.offset, count: span.count) else {
                                throw VolcFileError.failed("保存的录音读不出来了。")
                            }
                            parts.append(pcm)
                        }
                        let body = VolcRecording.submitBody(wav: VolcRecording.wav(parts, spans: upload.spans),
                                                            uid: UUID().uuidString, hotwords: hotwords, tables: tables, splitOnPauses: upload.split)
                        return (index, try await client.recognize(body: body, seconds: upload.seconds))
                    }
                    next += 1; running += 1
                }
                guard let (index, utterances) = try await group.next() else { return }
                running -= 1
                await apply(index, utterances)
            }
        }
    }

    /// Send the kept speech to Doubao's recording-file recognition and replace
    /// the live lines with what comes back.
    private func refineSessionCloud() {
        let sessionID = session.id
        let settings = preferences
        let limit = cloudChunkSeconds
        let words = hotwords
        let tables = VolcTables(boosting: preferences.volcBoostingTableID)
        error = nil
        notice = nil
        postRefineDone = 0
        postRefineTotal = 0
        postRefineChanged = 0
        isPostRefining = true
        cloudRefineTask = Task { [weak self] in
            let key = await Task.detached { AppModel.volcKey() }.value
            let planned = await Task.detached { AppModel.cloudUploads(session: sessionID, limit: limit) }.value
            guard let self, self.isPostRefining, self.session.id == sessionID else { return }
            guard !key.isEmpty else {
                self.isPostRefining = false
                self.volcKeyPresent = false
                self.error = "还没有填写豆包语音识别的 API Key，无法精修。"
                return
            }
            // A run that was interrupted has already replaced some stretches;
            // those are not sent, or paid for, twice.
            let uploads = planned.filter { VolcRecording.unfinished(self.session.lines, source: $0.source, spans: $0.spans) }
            self.postRefineTotal = uploads.count
            let seconds = uploads.reduce(0) { $0 + $1.seconds }
            var failure: String?
            do {
                try await AppModel.recognize(uploads, session: sessionID,
                                             client: VolcFileClient(key: key, resourceID: settings.volcFileResourceID),
                                             hotwords: words, tables: tables) { [weak self] index, utterances in
                    self?.applyCloud(uploads[index], utterances, session: sessionID)
                }
            } catch {
                failure = error.localizedDescription
            }
            // Stopped by the user: `cancelRefineSession` has said so already.
            guard self.isPostRefining, self.session.id == sessionID, !Task.isCancelled else { return }
            self.isPostRefining = false
            if let failure {
                self.error = "精修中断：\(failure) 已完成的 \(self.postRefineDone) 段保留，可以稍后再点「精修全文」继续。"
                return
            }
            AudioStore.markStreamRefined(sessionID)
            self.keptStreamSeconds = 0
            // The service answers sentence by sentence; show paragraphs.
            self.session.lines = VolcRecording.paragraphs(self.session.lines)
            if self.postRefineChanged > 0 { self.session.refinedAt = Date() }
            self.persist()
            self.notice = planned.isEmpty ? "这段会话没有还没精修的录音。"
                : uploads.isEmpty ? "这段会话已经精修过。"
                : "全文精修完成：\(uploads.count) 段、约 \(Self.minutes(seconds))的音频由豆包录音文件识别重新识别，其中 \(self.postRefineChanged) 段文字有改动。录音保留在本机。"
                    + (self.session.organized != nil && self.postRefineChanged > 0 ? "整理稿下次更新时会按精修后的原文整篇重整。" : "")
        }
    }

    private func applyCloud(_ upload: CloudUpload, _ utterances: [VolcUtterance], session id: UUID) {
        guard isPostRefining, session.id == id else { return }
        if VolcRecording.apply(utterances, spans: upload.spans, source: upload.source, split: upload.split, to: &session.lines) {
            postRefineChanged += 1
        }
        postRefineDone += 1
        persist()
    }

    // MARK: - Agent bridge (the `lstf` command line tool)

    /// A refinement of a session that is not the one open in the window,
    /// started from the command line. It works on its own copy and saves it.
    private struct StoredRefine {
        var session: MeetingSession
        var done = 0
        var total = 0
        var changed = 0
    }
    private var storedRefine: StoredRefine?
    private var publishedState: AgentBridge.State?
    private var lastRefine: AgentBridge.RefineResult?
    private var refiningOpenSession: UUID?

    /// Once a second: answer what the tool asked for, and say what the app is doing.
    private func serveAgents() {
        guard SessionStore.writes else { return }
        // A refinement of the open session that has just ended, however it ended.
        if isPostRefining { refiningOpenSession = session.id }
        else if let id = refiningOpenSession {
            refiningOpenSession = nil
            lastRefine = .init(sessionID: id, ok: error == nil, message: error ?? notice ?? "", finished: Date())
        }
        for request in AgentBridge.pending() { handle(request) }
        let refining = isPostRefining
            ? AgentBridge.Refining(sessionID: session.id, done: postRefineDone, total: postRefineTotal)
            : storedRefine.map { AgentBridge.Refining(sessionID: $0.session.id, done: $0.done, total: $0.total) }
        let state = AgentBridge.State(pid: getpid(), recording: isRecording, sessionID: session.id,
                                      source: activeSource?.label, engine: preferences.engine.label,
                                      pending: pendingCount, refining: refining, lastRefine: lastRefine)
        if state != publishedState {
            publishedState = state
            AgentBridge.publish(state)
        }
    }

    /// What an agent may ask of the app: start refining a session that has
    /// kept audio, and rename a session. Recording is never started or stopped
    /// from outside.
    private func handle(_ request: AgentBridge.Request) {
        func refuse(_ reason: String) { AgentBridge.respond(to: request, ok: false, reason) }
        if request.action == AgentBridge.draft {
            if let problem = writeDraft(request.session, text: request.text ?? "", through: request.through, replace: request.replace == true) { refuse(problem) }
            else { AgentBridge.respond(to: request, ok: true, "已写入。") }
            return
        }
        if request.action == AgentBridge.rename {
            if let problem = renameSession(request.session, to: request.name ?? "") { refuse(problem) }
            else { AgentBridge.respond(to: request, ok: true, "已改名。") }
            return
        }
        guard request.action == AgentBridge.refine else { refuse("这个版本的听流不认识这个请求。"); return }
        if isPostRefining || storedRefine != nil { refuse("已有一场会话在精修，等它完成后再试。"); return }
        if request.session == session.id {
            if isRecording { refuse("这场会话还在录制，暂停转写后才能精修。"); return }
            if isBusy || pendingCount > 0 { refuse("还有句子在识别，稍后再试。"); return }
            if usesCloud { keptStreamSeconds = AudioStore.unrefinedStreamSeconds(session.id) }
            guard canRefineSession else {
                refuse(usesCloud && !volcKeyPresent ? "还没有填写豆包语音识别的 API Key，无法精修。"
                       : !usesCloud && !modelReady ? "本地模型还没有就绪，无法精修。"
                       : "这场会话没有可以精修的内容：没有录音，或已经精修过。")
                return
            }
            refineSession()
            if isPostRefining { AgentBridge.respond(to: request, ok: true, "已开始精修。") }
            else { refuse(notice ?? "这场会话现在无法精修。") }
            return
        }
        writer.flush()
        guard let stored = SessionStore.load(request.session) else { refuse("找不到这场会话。"); return }
        guard AudioStore.unrefinedStreamSeconds(stored.id) > 0 else {
            refuse(AudioStore.streamSeconds(stored.id) > 0 ? "这场会话已经精修过（录音还保留着）。"
                   : AudioStore.hasAudio(stored.id)
                   ? "这场会话是用本地模型录的，需要先在听流的会话列表里打开它，再点「精修全文」。"
                   : "这场会话没有录音：录制时关闭了「保存录音」，或录音是旧版本精修后删掉的。")
            return
        }
        guard volcKeyPresent else { refuse("还没有填写豆包语音识别的 API Key，无法精修。"); return }
        refineStored(stored)
        AgentBridge.respond(to: request, ok: true, "已开始精修。")
    }

    private func refineStored(_ stored: MeetingSession) {
        let id = stored.id
        let settings = preferences
        let limit = cloudChunkSeconds
        let words = hotwords
        let tables = VolcTables(boosting: preferences.volcBoostingTableID)
        storedRefine = StoredRefine(session: stored)
        Task { [weak self] in
            let key = await Task.detached { AppModel.volcKey() }.value
            let planned = await Task.detached { AppModel.cloudUploads(session: id, limit: limit) }.value
            guard let self, let lines = self.storedRefine?.session.lines else { return }
            let uploads = planned.filter { VolcRecording.unfinished(lines, source: $0.source, spans: $0.spans) }
            self.storedRefine?.total = uploads.count
            var failure: String? = key.isEmpty ? "还没有填写豆包语音识别的 API Key。" : nil
            if failure == nil {
                do {
                    try await AppModel.recognize(uploads, session: id,
                                                 client: VolcFileClient(key: key, resourceID: settings.volcFileResourceID),
                                                 hotwords: words, tables: tables) { [weak self] index, utterances in
                        guard let self, var run = self.storedRefine else { return }
                        let upload = uploads[index]
                        if VolcRecording.apply(utterances, spans: upload.spans, source: upload.source,
                                               split: upload.split, to: &run.session.lines) {
                            run.changed += 1
                        }
                        run.done += 1
                        self.storedRefine = run
                        try? SessionStore.save(run.session)      // what is done survives a quit
                    }
                } catch {
                    failure = error.localizedDescription
                }
            }
            guard var run = self.storedRefine else { return }
            self.storedRefine = nil
            if let failure {
                self.lastRefine = .init(sessionID: id, ok: false, message: "精修中断：\(failure) 已完成的 \(run.done) 段保留，可以再试一次。", finished: Date())
            } else {
                AudioStore.markStreamRefined(id)
                run.session.lines = VolcRecording.paragraphs(run.session.lines)
                if run.changed > 0 { run.session.refinedAt = Date() }
                try? SessionStore.save(run.session)
                let seconds = uploads.reduce(0) { $0 + $1.seconds }
                self.lastRefine = .init(sessionID: id, ok: true, message: uploads.isEmpty ? "这场会话已经精修过。"
                    : "全文精修完成：\(uploads.count) 段、约 \(Self.minutes(seconds))的音频由豆包录音文件识别重新识别，其中 \(run.changed) 段文字有改动。录音保留在本机。", finished: Date())
            }
            self.remember(SessionSummary(run.session))
        }
    }

    nonisolated private static func minutes(_ seconds: TimeInterval) -> String {
        seconds < 90 ? "\(Int(seconds.rounded())) 秒" : "\(Int((seconds / 60).rounded())) 分钟"
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
        if HotwordStore.modified() != hotwordsStamp { reloadHotwords() }
        settleHeldMic()
        // A speaker who paused for a while has finished a thought: refine it now
        // rather than waiting for the next chunk to close the window.
        for (source, window) in openWindows where current.timeIntervalSince(window.touched) > 4 { closeWindow(source) }
        if !isRecording && pending.isEmpty && heldMic.isEmpty { closeAllWindows() }
        let age = pending.values.map { current.timeIntervalSince($0.start) }.max() ?? 0
        if age != oldestPending { oldestPending = age }
        if current.timeIntervalSince(lastAppSignal) > 1 && levels.app != 0 { levels.app = 0 }
        if current.timeIntervalSince(lastMicSignal) > 1 && levels.mic != 0 { levels.mic = 0 }
        if audioOpen && !isRecording && !isBusy && pendingCount == 0 { audioOpen = false; AudioStore.release() }
        if oldestPending > 40 { failWorker("识别等待超时，已停止采集。") }
        if modelLoading, let since = loadingSince, current.timeIntervalSince(since) > 120 { failWorker("本地模型加载超时，请检查 Python 环境与模型路径。") }
        if autoOrganize && !isOrganizing && !isImportingImages && hasOrganizationContext && (session.unorganizedCount > 0 || organizationImagesChanged || organizationStale) &&
            current.timeIntervalSince(lastOrganizationAttempt) >= 30 { organize() }
        serveAgents()
    }

    /// `volcKey` is nil when the field was left as loaded, so a key that could
    /// not be read is never overwritten with nothing.
    func applyPreferences(_ value: Preferences, key: String, volcKey: String? = nil) throws {
        let engineChanged = preferences.engine != value.engine
        let changed = preferences.python != value.python || preferences.asrModel != value.asrModel
        if (changed || engineChanged) && (isRecording || isBusy || pendingCount > 0 || modelLoading || isPostRefining) {
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
        preferences.volcBoostingTableID = value.volcBoostingTableID.trimmingCharacters(in: .whitespaces)
        let fileResource = value.volcFileResourceID.trimmingCharacters(in: .whitespaces)
        preferences.volcFileResourceID = fileResource.isEmpty ? Preferences().volcFileResourceID : fileResource
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
        let settled = Array(existing.prefix(OrganizedTranscript.settledCount(existing)))
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

    func selectImage(_ image: ImageAttachment, selected: Bool) {
        guard !isOrganizing, !isImportingImages else { return }
        if selected && organizationImageIDs.count >= ImageAttachmentStore.maxSelected { error = "每次最多选择 6 张图片。"; return }
        if selected { organizationImageIDs.insert(image.id) } else { organizationImageIDs.remove(image.id) }
    }

    /// One click keeps the whole screen with the session, at this moment: no
    /// region to drag, no window hidden. The transcript shows it where it
    /// happened, and `lstf` hands its path to an agent at the same place.
    func captureScreenshot() {
        guard SessionStore.writes, !isCapturingShot else { return }
        isCapturingShot = true
        let sessionID = session.id
        let number = (session.imageLibrary.map(\.number).max() ?? 0) + 1
        let display = ScreenshotCapture.displayUnderPointer()
        let taken = Date()
        Task {
            do {
                let image = try await ScreenshotCapture.capture(display: display)
                let shot = try await Task.detached(priority: .userInitiated) {
                    try ImageAttachmentStore.storeShot(image, at: taken, sessionID: sessionID, number: number)
                }.value
                if self.session.id == sessionID {
                    self.session.images = self.session.imageLibrary + [shot]
                    if self.session.title == "新的会话", self.session.renamed != true { self.session.title = "截屏 · \(taken.formatted(date: .abbreviated, time: .shortened))" }
                    self.persist()
                    self.shotsTaken += 1
                } else {
                    // The session was switched in the meantime; the picture has no home.
                    try? FileManager.default.removeItem(at: ImageAttachmentStore.url(for: shot, sessionID: sessionID))
                }
            } catch {
                self.error = error.localizedDescription
            }
            self.isCapturingShot = false
        }
    }

    func importImages() {
        guard !isImportingImages, !isOrganizing else { return }
        let panel = NSOpenPanel()
        panel.title = "添加整理参考图片"
        panel.prompt = "添加图片"
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return }
        importImages(panel.urls.map(ImageImportSource.file))
    }

    private func importImages(_ sources: [ImageImportSource]) {
        guard !sources.isEmpty, !isImportingImages, !isOrganizing else { return }
        guard organizationImageIDs.count + sources.count <= ImageAttachmentStore.maxSelected else { error = "每次最多选择 6 张图片，请减少选择。"; return }
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
            self.organizationImageIDs.formUnion(result.0.map(\.id))
            if self.session.title == "新的会话", self.session.renamed != true, !result.0.isEmpty { self.session.title = "图片资料 · \(Date().formatted(date: .abbreviated, time: .shortened))" }
            self.isImportingImages = false
            if !result.1.isEmpty { self.error = result.1.joined(separator: "\n") }
            self.persist()
        }
    }

    func newSession() {
        guard canChangeSession else { return }
        persist()
        startFresh()
    }
    private func startFresh() {
        session = MeetingSession()
        keptStreamSeconds = 0
        savedStreamSeconds = 0
        echoDropped = 0
        resetRefinement()
        organizationImageIDs = []
        showOrganized = false
        autoOrganize = false
        lastLatency = 0
    }
    func openSession(_ id: UUID) {
        guard canChangeSession, id != session.id else { return }
        // Its file is being rewritten; a copy opened now would overwrite that.
        if id == storedRefine?.session.id { notice = "这场会话正在后台精修，完成后再打开。"; return }
        persist()
        writer.flush()
        guard let value = SessionStore.load(id) else {
            error = "这场会话的文件读不出来了。"
            history.removeAll { $0.id == id }
            return
        }
        session = value
        keptStreamSeconds = 0
        refreshKeptAudio()
        echoDropped = 0
        resetRefinement()
        organizationImageIDs = Set((value.organized?.imageIDs ?? []).prefix(ImageAttachmentStore.maxSelected))
        showOrganized = false
        autoOrganize = false
        lastLatency = 0
        error = nil
        notice = nil
    }
    /// Takes an organized draft an agent wrote and handed in through `lstf`, in
    /// place of whatever draft the session had. Returns why it could not, or
    /// nil when it is done.
    @discardableResult
    func writeDraft(_ id: UUID, text raw: String, through: Int?, replace: Bool) -> String? {
        guard let text = SessionStore.cleanDraft(raw) else { return "整理稿是空的。" }
        guard text.count <= SessionStore.draftLimit else { return "整理稿太长（\(text.count) 字），上限是 \(SessionStore.draftLimit) 字。" }
        if id == session.id {
            if isOrganizing { return "听流正在整理这场会话，等它完成（或用户点「停止」）后再写。" }
            if isPostRefining { return "这场会话正在精修，行号会变；完成后重新读一遍再写。" }
            do {
                let count = try SessionStore.draftCoverage(session, through: through, replace: replace,
                                                           growing: isRecording || isBusy || pendingCount > 0)
                session.setDraft(text, through: count, author: OrganizedTranscript.agent)
            } catch { return error.localizedDescription }
            persist()
            notice = "agent 写入了这场会话的整理稿。"
            return nil
        }
        if id == storedRefine?.session.id { return "这场会话正在后台精修，行号会变；完成后重新读一遍再写。" }
        guard SessionStore.writes else { return "找不到这场会话。" }
        writer.flush()      // a session left a moment ago may still be on its way to disk
        do { remember(SessionSummary(try SessionStore.writeDraft(id, text: text, through: through, replace: replace))) }
        catch { return error.localizedDescription }
        return nil
    }
    /// Why a session cannot be deleted at the moment; nil when it can.
    func deleteBlocker(_ id: UUID) -> String? {
        if id == session.id {
            if isRecording { return "这场会话正在录制，暂停转写后才能删除。" }
            if !canChangeSession { return "这场会话还在识别、精修或整理，完成后才能删除。" }
        }
        if id == storedRefine?.session.id { return "这场会话正在后台精修，完成后才能删除。" }
        return nil
    }
    /// What deleting it takes away, for the question the window asks.
    func deleteDetail(_ row: SessionSummary) -> String {
        var parts = [row.lineCount > 0 ? "\(row.lineCount) 句转写" : "这场会话"]
        if row.hasDraft { parts.append("整理稿") }
        if row.imageCount > 0 { parts.append("\(row.imageCount) 张图片") }
        return parts.joined(separator: "、") + "会移到废纸篓。"
            + (AudioStore.hasAudio(row.id) ? "它的录音直接删除，找不回来。" : "")
    }
    /// The window asks first; this only raises the question.
    func askToDelete(_ id: UUID) {
        if let blocker = deleteBlocker(id) { error = blocker; return }
        deleteCandidate = id == session.id ? (sessionIsEmpty ? nil : SessionSummary(session)) : history.first { $0.id == id }
    }
    /// Deletes a session: its file and pictures go to the Trash, its kept audio
    /// is removed. Only a person does this, in the window; `lstf` cannot.
    /// Returns why it could not, or nil when it is done.
    @discardableResult
    func deleteSession(_ id: UUID) -> String? {
        if let blocker = deleteBlocker(id) { return blocker }
        let open = id == session.id
        let name = open ? session.name : history.first { $0.id == id }?.name
        writer.flush()      // a save still on its way would bring the file back
        if SessionStore.writes {
            // Preview builds are checks run from a terminal: they stay out of the user's Trash.
            do { try SessionStore.delete(id, remove: ListenFlowHome.isPreview ? { try FileManager.default.removeItem(at: $0) } : SessionStore.trash) }
            catch { return "没有删掉：\(error.localizedDescription)" }
            AudioStore.delete(id)
        }
        history.removeAll { $0.id == id }
        if lastRefine?.sessionID == id { lastRefine = nil }
        if open { startFresh() }
        error = nil
        notice = "已删除「\(name ?? "会话")」，文件在废纸篓里。"
        return nil
    }
    /// Gives a session a name of the user's (or their agent's) choosing: the
    /// one that is open, recording or not, or any other in the list. Returns
    /// why it could not, or nil when it is done.
    @discardableResult
    func renameSession(_ id: UUID, to raw: String) -> String? {
        guard let name = SessionStore.cleanName(raw) else { return "名字不能是空的。" }
        if id == session.id {
            guard session.title != name || session.renamed != true else { return nil }
            session.title = name
            session.renamed = true
            persist()       // an empty session has no file yet; it keeps the name until it has
            return nil
        }
        // Being refined in the background: that run owns the file until it ends.
        if var run = storedRefine, run.session.id == id {
            run.session.title = name
            run.session.renamed = true
            storedRefine = run
            do { try SessionStore.save(run.session) } catch { return "改名没有保存下来：\(error.localizedDescription)" }
            remember(SessionSummary(run.session))
            return nil
        }
        guard SessionStore.writes else {
            // A preview build showing made-up history: nothing on disk to change.
            guard let index = history.firstIndex(where: { $0.id == id }) else { return "找不到这场会话。" }
            history[index].title = name
            history[index].renamed = true
            return nil
        }
        writer.flush()      // a session left a moment ago may still be on its way to disk
        do { remember(SessionSummary(try SessionStore.rename(id, to: name))) }
        catch { return "改名没有保存下来：\(error.localizedDescription)" }
        return nil
    }
    /// Saved after every settled sentence, so `lstf` and a crash both find the
    /// text. The write itself happens off the main thread.
    func persist() {
        guard SessionStore.writes, !sessionIsEmpty else { return }
        writer.save(session)
        remember(SessionSummary(session))
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
        organizeTask?.cancel()
        cloudRefineTask?.cancel()
        persist()
        writer.flush()
        cancelStreams()
        worker.shutdown()
        if SessionStore.writes { AgentBridge.withdraw() }
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
        if AudioStore.rootOverride == nil {
            AudioStore.rootOverride = FileManager.default.temporaryDirectory.appendingPathComponent("listenflow-replay-audio")
        }
        Task { @MainActor in
            let wav = (try? Data(contentsOf: URL(fileURLWithPath: path))) ?? Data()
            // Raw 16 kHz mono Int16 LE, no header: WAV headers vary in length.
            let samples = wav.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }.map { Float($0) / 32768 }
            if env["LISTENFLOW_REPLAY_ENGINE"] == "volc" {
                let track = env["LISTENFLOW_REPLAY_MIC"].flatMap { try? Data(contentsOf: URL(fileURLWithPath: $0)) } ?? Data()
                preferences.engine = .volc
                await replayCloud(app: samples, mic: track.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }.map { Float($0) / 32768 },
                                  env: env, out: out)
                // Stay up for a while so the command line tool can be tried against
                // a session that has just ended.
                if let hold = env["LISTENFLOW_REPLAY_HOLD"].flatMap(Double.init) {
                    try? await Task.sleep(nanoseconds: UInt64(hold * 1_000_000_000))
                }
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
        let refine = env["LISTENFLOW_REPLAY_REFINE"] == "1"
        preferences.keepAudioForRefine = refine || env["LISTENFLOW_REPLAY_KEEP"] == "1"
        if let seconds = env["LISTENFLOW_REPLAY_CHUNK"].flatMap(Double.init) { cloudChunkSeconds = seconds }
        if let resource = env["LISTENFLOW_REPLAY_FILE_RESOURCE"] { preferences.volcFileResourceID = resource }
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
        guard refine else { return }
        keptStreamSeconds = AudioStore.unrefinedStreamSeconds(session.id)
        let kept = keptStreamSeconds
        let began = Date()
        refineSession()
        while isPostRefining { try? await Task.sleep(nanoseconds: 200_000_000) }
        write(out + "-post.json", extra: ["notice": notice ?? "", "error": error ?? "", "keptSeconds": kept,
                                          "uploads": postRefineTotal, "changed": postRefineChanged,
                                          "refineSeconds": Date().timeIntervalSince(began),
                                          "audioLeft": AudioStore.streamSeconds(session.id),
                                          // The audio stays; nothing of it is left to refine, so a second
                                          // refinement has nothing to send.
                                          "unrefinedLeft": AudioStore.unrefinedStreamSeconds(session.id),
                                          "canRefineAgain": canRefineSession,
                                          "uploadsIfAskedAgain": AppModel.cloudUploads(session: session.id, limit: cloudChunkSeconds).count])
        AudioStore.delete(session.id)
    }

    /// Renders the main window in its main states, light and dark, and the
    /// settings sheet for both engines, to PNG files without putting a window on
    /// screen — so layout can be checked on a locked or headless Mac. Preview
    /// builds only.
    func snapshotViews(to folder: String) {
        func shot<V: View>(_ view: V, _ size: NSSize, _ name: String, dark: Bool = false) {
            let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
            host.frame = NSRect(origin: .zero, size: size)
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.8))
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
            host.cacheDisplay(in: host.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: folder + "/" + name + (dark ? "-dark" : "") + ".png"))
        }
        func main(_ name: String, both: Bool = true) {
            let size = NSSize(width: 1080, height: 740)
            shot(ContentView(model: self), size, name)
            if both { shot(ContentView(model: self), size, name, dark: true) }
        }
        let fixture = session
        showSettings = false
        volcKeyPresent = true
        preferences.engine = .volc
        // A made-up list: a preview build never reads the real sessions.
        let now = Date()
        history = [SessionSummary(fixture)] + [(0.9, 52.0, 410, "腾讯会议"), (1.2, 95.0, 902, "全局声音"), (2.4, 7.0, 61, "我的麦克风"), (6.1, 48.0, 377, "Safari")]
            .map { days, minutes, lines, name in
                var past = MeetingSession(title: "\(name) · 合成", created: now.addingTimeInterval(-days * 86400))
                past.lines = (0..<lines).map { index in
                    TranscriptLine(start: past.created, end: past.created.addingTimeInterval(minutes * 60 * Double(index + 1) / Double(lines)),
                                   source: name, text: "", latency: 0)
                }
                return SessionSummary(past)
            }
        main("main-volc")

        // In the middle of a session: both sources live, a sentence still being heard.
        isRecording = true
        activeSource = .all
        micEnabled = true
        levels.app = 0.55
        levels.mic = 0.22
        cloudActivity = .live
        livePreview.set(AudioSource.systemName, "接下来说一下用户访谈的情况，这周一共约到了")
        hasLivePartial = true
        main("main-recording")
        isRecording = false
        activeSource = nil
        micEnabled = false
        levels.app = 0
        levels.mic = 0
        cloudActivity = .waiting
        livePreview.clear()
        hasLivePartial = false

        showOrganized = true
        main("main-draft")
        showOrganized = false

        session = MeetingSession()
        main("main-empty")
        session = fixture

        for engine in RecognitionEngine.allCases {
            preferences.engine = engine
            if engine == .local { main("main-local", both: false) }
            shot(SettingsView(model: self), NSSize(width: 650, height: 690), "settings-\(engine.rawValue)")
        }
        NSApp.terminate(nil)
    }

    /// Whether the transcript follows new text only while the reader is at the
    /// end. Driven in a window that is never shown: lines are added, the page
    /// is scrolled away and back, and where it ends up each time is written
    /// out. Preview builds only.
    func scrollCheck(to path: String) {
        let created = Date().addingTimeInterval(-3600)
        func line(_ index: Int) -> TranscriptLine {
            // Ten seconds apart, so every line is a paragraph of its own.
            let start = created.addingTimeInterval(Double(index) * 10)
            return TranscriptLine(start: start, end: start.addingTimeInterval(4), source: index % 3 == 0 ? EchoFilter.micSource : AudioSource.systemName,
                                  text: "合成的第 \(index + 1) 句，用来把页面撑到比窗口高。", latency: 0.8)
        }
        session = MeetingSession(title: "滚动检查", created: created)
        session.lines = (0..<60).map(line)
        volcKeyPresent = true
        isRecording = true
        activeSource = .all
        let size = NSSize(width: 1080, height: 740)
        let host = NSHostingView(rootView: ContentView(model: self).frame(width: size.width, height: size.height))
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        func settle(_ seconds: TimeInterval) {
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(seconds))
            host.layoutSubtreeIfNeeded()
        }
        func page() -> NSScrollView? {
            var found: [NSScrollView] = []
            func walk(_ view: NSView) {
                if let scroll = view as? NSScrollView { found.append(scroll) }
                view.subviews.forEach(walk)
            }
            walk(host)
            return found.filter { $0.frame.width > 500 }.max { ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0) }
        }
        var result: [String: Any] = [:]
        func record(_ name: String) {
            guard let scroll = page(), let document = scroll.documentView else { result[name] = "no scroll view"; return }
            let bounds = scroll.contentView.bounds
            result[name] = ["offset": Double(bounds.origin.y), "fromEnd": Double(document.frame.height - bounds.maxY),
                            "documentHeight": Double(document.frame.height), "lines": session.lines.count]
        }
        func scroll(toY y: CGFloat) {
            guard let scroll = page() else { return }
            scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        settle(1.2)
        record("1 opened while recording")
        session.lines.append(line(session.lines.count))
        settle(1.0)
        record("2 a line arrived while at the end")
        scroll(toY: 0)
        settle(0.6)
        record("3 scrolled to the top")
        for _ in 0..<3 { session.lines.append(line(session.lines.count)); settle(0.5) }
        livePreview.set(AudioSource.systemName, "正在说的半句")
        hasLivePartial = true
        settle(0.5)
        record("4 three lines and a preview arrived while at the top")
        if let scrollView = page(), let document = scrollView.documentView {
            scroll(toY: max(0, document.frame.height - scrollView.contentView.bounds.height))
        }
        settle(0.6)
        record("5 scrolled back to the end")
        session.lines.append(line(session.lines.count))
        settle(1.0)
        record("6 a line arrived while at the end again")
        if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: path))
        }
        isRecording = false
        NSApp.terminate(nil)
    }

    /// Deleting sessions, checked without a window in a store of the check's
    /// own that holds at least three sessions: one that is not open, the open
    /// one with a save still on its way, and one that is recording. What is
    /// left on disk and in the list each time is written out. Preview builds only.
    func deleteCheck(to path: String) {
        let fm = FileManager.default
        var result: [String: Any] = [:]
        func finish() {
            if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: URL(fileURLWithPath: path))
            }
            NSApp.terminate(nil)
        }
        func there(_ id: UUID) -> [String: Bool] {
            ["file": fm.fileExists(atPath: SessionStore.folder.appendingPathComponent(id.uuidString + ".json").path),
             "pictures": fm.fileExists(atPath: ImageAttachmentStore.folder(for: id).path),
             "audio": AudioStore.hasAudio(id), "listed": history.contains { $0.id == id }]
        }
        let stored = SessionStore.all()
        guard SessionStore.folderOverride != nil, stored.count >= 3 else { result["error"] = "needs LISTENFLOW_PREVIEW_STORE with three sessions"; finish(); return }
        history = SessionStore.summaries()
        let recording = stored[0], open = stored[1], other = stored[2]

        result["1 not open, before"] = there(other.id)
        result["1 asked"] = deleteDetail(SessionSummary(other))
        result["1 refused"] = deleteSession(other.id) ?? ""
        result["1 not open, after"] = there(other.id)

        openSession(open.id)
        session.lines.append(TranscriptLine(start: Date(), end: Date(), source: AudioSource.systemName, text: "删除前刚定稿的一句", latency: 0.5))
        persist()       // on its way to disk when the session is deleted
        result["2 open, before"] = there(open.id)
        result["2 refused"] = deleteSession(open.id) ?? ""
        writer.flush()
        result["2 open, after"] = there(open.id)
        result["2 window moved to a new empty session"] = session.id != open.id && sessionIsEmpty
        result["2 notice"] = notice ?? ""

        openSession(recording.id)
        isRecording = true
        result["3 refused"] = deleteSession(recording.id) ?? ""
        result["3 recording, after"] = there(recording.id)
        isRecording = false

        persist()
        writer.flush()
        result["4 sessions left on disk"] = SessionStore.all().map(\.id.uuidString)
        result["4 rows left in the list"] = history.map(\.id.uuidString)
        finish()
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
