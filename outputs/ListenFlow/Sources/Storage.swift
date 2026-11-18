import Foundation
import Security

/// How much compute live recognition may spend. Measured on a 2,224-character corpus:
/// economy (one pass, cut in pauses) halves errors versus the old fixed cut at ~7.5%
/// GPU time; quality adds a ~20 s re-decode for another ~20–30% fewer errors at ~13%.
enum RecognitionMode: String, Codable, CaseIterable, Identifiable {
    case auto, economy, quality
    var id: String { rawValue }
    var label: String {
        switch self {
        case .auto: "自动"
        case .economy: "省电"
        case .quality: "高精度"
        }
    }
    var detail: String {
        switch self {
        case .auto: "接电源时用高精度；用电池或开启低电量模式时省电"
        case .economy: "每段只识别一遍，在停顿处切分"
        case .quality: "先实时出字，再把约 20 秒合起来重新识别并替换"
        }
    }
}

/// Where speech is turned into text. Doubao streams audio to Volcengine and returns
/// text while the speaker is still talking; the local model keeps everything on
/// this Mac and works offline.
enum RecognitionEngine: String, Codable, CaseIterable, Identifiable {
    case volc, local
    var id: String { rawValue }
    var label: String { self == .volc ? "豆包（云端）" : "本地模型" }
}

struct Preferences: Codable {
    var engine = RecognitionEngine.volc
    /// The hour-based plan of Doubao streaming ASR 2.0. The concurrency plan
    /// (`volc.seedasr.sauc.concurrent`) needs its own quota; a handshake that
    /// succeeds does not mean the resource is usable.
    var volcResourceID = "volc.seedasr.sauc.duration"
    /// Doubao recording-file recognition, used to refine a finished session.
    var volcFileResourceID = "volc.seedasr.auc"
    /// A hot word table made in the Volcengine console, by ID; empty when not
    /// used. The console's replacement tables are deliberately not supported:
    /// rewriting one spelling as another after recognition changes words that
    /// were heard correctly too.
    var volcBoostingTableID = ""
    var python = "/Users/aurora/Desktop/workspace/asr-realtime-lab/.venv/bin/python"
    var asrModel = "mlx-community/Qwen3-ASR-1.7B-8bit"
    var language = ""
    /// Where hot words were kept up to 0.10.1; they now live in a file of their
    /// own (`HotwordStore`), and this is only read once to move them there.
    var hotwords = ""
    var apiBase = "https://api.deepseek.com"
    var llmModel = "deepseek-flash"
    var recognitionMode = RecognitionMode.auto
    /// Keep the session's 16 kHz audio on this Mac so it can be re-recognized later;
    /// deleted once refined, and after seven days regardless. With the cloud
    /// engine only the speech that was streamed is kept.
    var keepAudioForRefine = true
    /// Live transcript in the notch. The body height is set by dragging the
    /// island's bottom edge; 0.7.0's line-count presets are not carried over,
    /// since even its default was too tall.
    var islandEnabled = true
    var islandShowLatest = false
    var islandHeight: Double = 300
    /// 720 pt suits a 16-inch screen at its larger text sizes; a 14-inch screen
    /// (1512 pt wide by default) may want it narrower.
    var islandWidth: Double = 720

    init() {}

    // Field-by-field so settings saved by an older build keep their values when a
    // new field appears, instead of the whole decode failing back to defaults.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Preferences()
        engine = (try? c.decodeIfPresent(RecognitionEngine.self, forKey: .engine)) ?? d.engine
        volcResourceID = try c.decodeIfPresent(String.self, forKey: .volcResourceID) ?? d.volcResourceID
        volcFileResourceID = try c.decodeIfPresent(String.self, forKey: .volcFileResourceID) ?? d.volcFileResourceID
        volcBoostingTableID = try c.decodeIfPresent(String.self, forKey: .volcBoostingTableID) ?? d.volcBoostingTableID
        python = try c.decodeIfPresent(String.self, forKey: .python) ?? d.python
        asrModel = try c.decodeIfPresent(String.self, forKey: .asrModel) ?? d.asrModel
        language = try c.decodeIfPresent(String.self, forKey: .language) ?? d.language
        hotwords = try c.decodeIfPresent(String.self, forKey: .hotwords) ?? d.hotwords
        apiBase = try c.decodeIfPresent(String.self, forKey: .apiBase) ?? d.apiBase
        llmModel = try c.decodeIfPresent(String.self, forKey: .llmModel) ?? d.llmModel
        recognitionMode = (try? c.decodeIfPresent(RecognitionMode.self, forKey: .recognitionMode)) ?? d.recognitionMode
        keepAudioForRefine = try c.decodeIfPresent(Bool.self, forKey: .keepAudioForRefine) ?? d.keepAudioForRefine
        islandEnabled = try c.decodeIfPresent(Bool.self, forKey: .islandEnabled) ?? d.islandEnabled
        islandShowLatest = try c.decodeIfPresent(Bool.self, forKey: .islandShowLatest) ?? d.islandShowLatest
        islandHeight = try c.decodeIfPresent(Double.self, forKey: .islandHeight) ?? d.islandHeight
        islandWidth = try c.decodeIfPresent(Double.self, forKey: .islandWidth) ?? d.islandWidth
    }

    var hotwordList: [String] {
        hotwords.split(whereSeparator: { $0 == "," || $0 == "，" || $0 == "\n" }).map(String.init)
    }

    static func load() -> Preferences {
        guard let data = UserDefaults.standard.data(forKey: "preferences"),
              let value = try? JSONDecoder().decode(Preferences.self, from: data) else { return Preferences() }
        return value
    }
    func save() { if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: "preferences") } }
}

/// `~/.listenflow`: what the user should be able to find, back up or delete by
/// hand — API keys and kept recordings. Readable by the owner only.
enum ListenFlowHome {
    /// Tests point this at a temporary folder.
    nonisolated(unsafe) static var rootOverride: URL?
    static var isPreview: Bool { Bundle.main.bundleIdentifier == "local.ListenFlow.preview" }
    static var root: URL {
        if let rootOverride { return rootOverride }
        // Preview and test builds get a throwaway home: they never see real keys
        // or recordings, and nothing they write survives.
        if isPreview { return FileManager.default.temporaryDirectory.appendingPathComponent("listenflow-preview-home", isDirectory: true) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".listenflow", isDirectory: true)
    }
    static func ensure(_ directory: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }
}

/// API keys, in `~/.listenflow/keys.json` (mode 0600): one entry per account —
/// the API address of the model that writes the organized draft, `volcengine-asr` for Doubao speech.
/// Up to 0.8.0 they were in the Keychain. Nothing is stored there any more: a
/// key found there is moved to the file the first time it is asked for.
enum SecretStore {
    /// Account of the Doubao speech recognition key (streaming and recordings).
    static let volcAccount = "volcengine-asr"
    static var file: URL { ListenFlowHome.root.appendingPathComponent("keys.json") }
    private static let lock = NSLock()

    /// Nil when the file exists but cannot be read as a JSON object of strings:
    /// it is then left alone rather than overwritten.
    private static func load() -> [String: String]? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: file.path) else { return [:] }
        // Hand-made files tend to be world-readable; a key file must not be.
        if let mode = (try? fm.attributesOfItem(atPath: file.path))?[.posixPermissions] as? Int, mode & 0o077 != 0 {
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
        guard let data = try? Data(contentsOf: file) else { return nil }
        if data.allSatisfy({ $0 == 0x20 || $0 == 0x0a || $0 == 0x0d || $0 == 0x09 }) { return [:] }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: String]
    }

    private static func store(_ value: String, _ account: String) throws {
        guard var all = load() else {
            throw CaptureFailure.message("密钥文件 \(file.path) 不是有效的 JSON，没有改动它。请修正或删除这个文件后再保存。")
        }
        // An empty entry is kept on purpose: it says the key was cleared here,
        // so the Keychain is not consulted for it again.
        all[account] = value
        do {
            try ListenFlowHome.ensure(file.deletingLastPathComponent())
            let data = try JSONSerialization.data(withJSONObject: all, options: [.prettyPrinted, .sortedKeys])
            // Created private before it holds anything, then swapped in whole.
            let draft = file.appendingPathExtension("tmp")
            try? FileManager.default.removeItem(at: draft)
            guard FileManager.default.createFile(atPath: draft.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteUnknown)
            }
            _ = try FileManager.default.replaceItemAt(file, withItemAt: draft)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        } catch {
            throw CaptureFailure.message("无法把密钥保存到 \(file.path)：\(error.localizedDescription)")
        }
    }

    static func read(account: String) -> String {
        lock.withLock {
            guard let all = load() else { return "" }
            if let value = all[account] { return value }
            // Only the installed app looks in the Keychain, and once per account.
            guard ListenFlowHome.rootOverride == nil, !ListenFlowHome.isPreview, Bundle.main.bundleIdentifier != nil else { return "" }
            let old = keychain(account)
            try? store(old, account)
            // Moved, not copied — but only once the file is known to hold it.
            if !old.isEmpty, load()?[account] == old { SecItemDelete(keychainQuery(account) as CFDictionary) }
            return old
        }
    }

    static func save(_ value: String, account: String) throws {
        try lock.withLock { try store(value, account) }
    }

    private static func keychainQuery(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "local.ListenFlow.llm",
         kSecAttrAccount as String: account]
    }

    private static func keychain(_ account: String) -> String {
        var query = keychainQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }
}

/// Names and terms the recognizer should expect — people, products, jargon —
/// in `~/.listenflow/hotwords.txt`, one to a line. The app and the `lstf` tool
/// both read and change this file, so an agent that notices a name coming out
/// wrong can add it while the session is still running.
///
/// Order matters. Doubao's streaming interface takes about 100 tokens of hot
/// words and drops the rest from the end, so live recognition only ever sees
/// the top of the list; refining a session from its recording uses all of it.
enum HotwordStore {
    /// Tests, and `lstf` when pointed at a folder of its own.
    nonisolated(unsafe) static var fileOverride: URL?
    static var file: URL { fileOverride ?? ListenFlowHome.root.appendingPathComponent("hotwords.txt") }
    /// The recording interface takes 5,000; nobody keeps that many by hand.
    static let limit = 1000
    static let maxLength = 40
    private static let lock = NSLock()

    /// One term per entry out of whatever was typed: split on line breaks and
    /// commas, trimmed, with repeats dropped (ignoring case).
    static func terms(_ text: String) -> [String] { unique(text.split(whereSeparator: { $0 == "," || $0 == "，" || $0.isNewline }).map(String.init)) }

    private static func unique(_ words: [String]) -> [String] {
        var seen = Set<String>(), out: [String] = []
        for word in words {
            let clean = word.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            guard !clean.isEmpty, seen.insert(clean.lowercased()).inserted else { continue }
            out.append(clean)
        }
        return out
    }

    static func load() -> [String] {
        lock.withLock { ((try? String(contentsOf: file, encoding: .utf8)).map(terms) ?? []) }
    }

    /// When the file last changed; nil when there is none.
    static func modified() -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date
    }

    private static func write(_ words: [String]) throws {
        try ListenFlowHome.ensure(file.deletingLastPathComponent())
        try (words.joined(separator: "\n") + (words.isEmpty ? "" : "\n")).write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    static func save(_ words: [String]) throws { try lock.withLock { try write(unique(words)) } }

    struct Change: Equatable {
        /// Added, or removed.
        var changed: [String] = []
        /// Already there, or not there to remove.
        var unchanged: [String] = []
        /// Not usable as a hot word, with the reason.
        var refused: [String] = []
        var words: [String] = []
    }

    static func add(_ new: [String]) throws -> Change {
        try lock.withLock {
            var change = Change(words: (try? String(contentsOf: file, encoding: .utf8)).map(terms) ?? [])
            for word in unique(new) {
                if word.count > maxLength { change.refused.append("\(word)（超过 \(maxLength) 个字）") }
                else if change.words.contains(where: { $0.lowercased() == word.lowercased() }) { change.unchanged.append(word) }
                else if change.words.count >= limit { change.refused.append("\(word)（词表已满 \(limit) 个）") }
                else { change.words.append(word); change.changed.append(word) }
            }
            if !change.changed.isEmpty { try write(change.words) }
            return change
        }
    }

    static func remove(_ gone: [String]) throws -> Change {
        try lock.withLock {
            var change = Change(words: (try? String(contentsOf: file, encoding: .utf8)).map(terms) ?? [])
            for word in unique(gone) {
                if let index = change.words.firstIndex(where: { $0.lowercased() == word.lowercased() }) {
                    change.changed.append(change.words.remove(at: index))
                } else { change.unchanged.append(word) }
            }
            if !change.changed.isEmpty { try write(change.words) }
            return change
        }
    }

    /// The top of the list that fits the streaming interface. The service
    /// counts tokens, which cannot be counted here; 80 characters stays under
    /// its 100 for Chinese and Latin text alike.
    static let liveCharacters = 80
    static func live(_ words: [String]) -> [String] {
        var budget = liveCharacters
        return Array(words.prefix { word in
            budget -= word.count
            return budget >= 0
        })
    }
}

/// Where a line's audio sits in the session's per-source audio file, in samples.
struct AudioRef: Codable, Equatable {
    let offset: Int
    let count: Int
}

struct TranscriptLine: Identifiable, Codable {
    var id = UUID()
    let start: Date
    let end: Date
    let source: String
    let text: String
    let latency: Double
    var audio: AudioRef? = nil
    /// Produced by re-recognizing several live lines as one window; absent on
    /// live lines and on sessions saved before 0.6.2.
    var refined: Bool? = nil
}
struct ChatMessage: Identifiable, Codable {
    var id = UUID()
    let role: String
    var text: String
    var contextThrough: Date?
    var imageIDs: [UUID]?
}
/// One contiguous stretch of organized text, tied to the transcript lines it was
/// produced from. Keeping batches separate is what makes incremental organizing
/// possible: settled batches are never re-sent, so earlier wording stays put.
struct OrganizedSegment: Codable, Identifiable {
    var id = UUID()
    var text: String
    var sourceLineIDs: [UUID]
    var started: Date
    var through: Date
    /// Who wrote it, when it was not the app's own model: "agent" for a draft
    /// handed in through `lstf`. The app never re-sends such a stretch.
    var author: String? = nil
}

struct OrganizedTranscript: Codable {
    var generatedAt: Date
    var segments: [OrganizedSegment]
    var imageIDs: [UUID]?

    static let agent = "agent"
    /// Some or all of it was written by an agent through `lstf`.
    var fromAgent: Bool { segments.contains { $0.author != nil } }
    /// How many leading segments an update leaves alone. The app redoes its own
    /// last batch together with the new lines, so the seam re-flows; what an
    /// agent wrote is not the app's to redo, nor anything before it.
    static func settledCount(_ segments: [OrganizedSegment]) -> Int {
        max(segments.count - 1, (segments.lastIndex { $0.author != nil } ?? -1) + 1, 0)
    }

    var text: String { segments.map(\.text).joined(separator: "\n\n") }
    var sourceLineIDs: [UUID] { segments.flatMap(\.sourceLineIDs) }
    var through: Date { segments.map(\.through).max() ?? generatedAt }

    init(generatedAt: Date, segments: [OrganizedSegment], imageIDs: [UUID]?) {
        self.generatedAt = generatedAt
        self.segments = segments
        self.imageIDs = imageIDs
    }

    /// A single settled block. Used for image-only sessions and for tests that do not
    /// care about batch boundaries.
    init(text: String, generatedAt: Date, sourceLineIDs: [UUID], through: Date, imageIDs: [UUID]? = nil) {
        self.init(generatedAt: generatedAt,
                  segments: [OrganizedSegment(text: text, sourceLineIDs: sourceLineIDs,
                                              started: through, through: through)],
                  imageIDs: imageIDs)
    }

    enum CodingKeys: String, CodingKey {
        case generatedAt, segments, imageIDs
        case text, sourceLineIDs, through
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        generatedAt = try container.decode(Date.self, forKey: .generatedAt)
        imageIDs = try container.decodeIfPresent([UUID].self, forKey: .imageIDs)
        if let stored = try container.decodeIfPresent([OrganizedSegment].self, forKey: .segments) {
            segments = stored
        } else {
            // Pre-0.5 sessions stored a single flat block with no batch boundaries.
            segments = [OrganizedSegment(
                text: try container.decodeIfPresent(String.self, forKey: .text) ?? "",
                sourceLineIDs: try container.decodeIfPresent([UUID].self, forKey: .sourceLineIDs) ?? [],
                started: generatedAt,
                through: try container.decodeIfPresent(Date.self, forKey: .through) ?? generatedAt)]
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(generatedAt, forKey: .generatedAt)
        try container.encode(segments, forKey: .segments)
        try container.encodeIfPresent(imageIDs, forKey: .imageIDs)
        // Mirror the flat fields too, so a build from before this change can still
        // open a session this version wrote.
        try container.encode(text, forKey: .text)
        try container.encode(sourceLineIDs, forKey: .sourceLineIDs)
        try container.encode(through, forKey: .through)
    }
}
struct MeetingSession: Codable, Identifiable {
    var id = UUID()
    var title = "新的会话"
    var created = Date()
    var lines: [TranscriptLine] = []
    var chat: [ChatMessage] = []
    var organized: OrganizedTranscript?
    var images: [ImageAttachment]?
    /// Set when the whole transcript was re-recognized after the fact. An organized
    /// draft older than this was written from the earlier wording and is redone in full.
    var refinedAt: Date?
    /// The title was given by a person or an agent, not made up from what was
    /// recorded and when. Such a title is shown whole and never replaced.
    var renamed: Bool?
    /// The group the user filed it under, by name; nil when it is in none. A
    /// group is nothing more than the sessions that carry its name.
    var group: String?
    var imageLibrary: [ImageAttachment] { images ?? [] }
    /// Puts a draft written outside the app in place of whatever draft there
    /// was. It stands for the first `count` lines; later ones stay unorganized.
    mutating func setDraft(_ text: String, through count: Int, author: String, now: Date = Date()) {
        let covered = lines.prefix(max(0, count))
        organized = OrganizedTranscript(generatedAt: now, segments: [
            OrganizedSegment(text: text, sourceLineIDs: covered.map(\.id), started: covered.first?.start ?? created,
                             through: covered.map(\.end).max() ?? created, author: author)], imageIDs: nil)
    }
    /// What the session is called where its date is shown beside it anyway.
    var name: String { SessionStore.name(title: title, renamed: renamed == true) }
    var unorganizedCount: Int {
        let included = Set(organized?.sourceLineIDs ?? [])
        return lines.filter { !included.contains($0.id) }.count
    }
}
/// One row of the session list: enough to name a session and say how long it is.
struct SessionSummary: Identifiable, Equatable, Decodable {
    let id: UUID
    var title: String
    var created: Date
    var lineCount: Int
    /// From the session's start to the end of its last line; 0 without lines.
    var seconds: TimeInterval
    var hasDraft: Bool
    var imageCount: Int
    var renamed = false
    var group: String?
    var name: String { SessionStore.name(title: title, renamed: renamed) }

    init(_ session: MeetingSession) {
        id = session.id
        title = session.title
        renamed = session.renamed == true
        group = session.group
        created = session.created
        lineCount = session.lines.count
        seconds = max(0, (session.lines.map(\.end).max() ?? session.created).timeIntervalSince(session.created))
        hasDraft = session.organized != nil
        imageCount = session.imageLibrary.count
    }

    private enum CodingKeys: String, CodingKey { case id, title, created, lines, organized, images, renamed, group }
    private struct LineEnd: Decodable { let end: Date }
    private struct Present: Decodable { init(from decoder: Decoder) throws {} }

    /// Decodes a stored session, keeping only the counts.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        renamed = try c.decodeIfPresent(Bool.self, forKey: .renamed) ?? false
        group = try c.decodeIfPresent(String.self, forKey: .group)
        created = try c.decode(Date.self, forKey: .created)
        let ends = try c.decodeIfPresent([LineEnd].self, forKey: .lines) ?? []
        lineCount = ends.count
        seconds = max(0, (ends.map(\.end).max() ?? created).timeIntervalSince(created))
        hasDraft = (try c.decodeIfPresent(Present.self, forKey: .organized)) != nil
        imageCount = (try c.decodeIfPresent([Present].self, forKey: .images))?.count ?? 0
    }
}

/// How wide the list of sessions may be. It can be dragged, but never so far
/// that the transcript beside it has no room to be read.
enum RailWidth {
    static let standard: Double = 236
    static let narrowest: Double = 190
    static let widestEver: Double = 520
    /// The transcript column keeps at least this much.
    static let transcript: Double = 520
    static func widest(inWindow width: Double) -> Double { max(narrowest, min(widestEver, width - transcript)) }
    static func clamp(_ width: Double, widest: Double) -> Double { min(max(width, narrowest), max(narrowest, widest)) }
}

/// The groups down the side of the window: each one a name and the sessions
/// filed under it. Every session is also in the list of recent ones below,
/// so filing a session away never hides it.
struct SessionGroup: Identifiable, Equatable {
    let name: String
    var sessions: [SessionSummary]
    var id: String { name }
}
enum SessionGroups {
    /// A group shows this many sessions until it is asked to show them all.
    static let shown = 5
    /// `rows` newest first; so are the sessions inside each group. `names` are
    /// the groups that were made, which may hold nothing yet. The groups are in
    /// name order, so each stays where it was when a new session is recorded
    /// into another.
    static func groups(_ rows: [SessionSummary], names: [String] = []) -> [SessionGroup] {
        var byName: [String: [SessionSummary]] = [:]
        for name in names { byName[name] = [] }
        for row in rows { if let name = row.group { byName[name, default: []].append(row) } }
        return byName.map { SessionGroup(name: $0.key, sessions: $0.value) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

/// The groups that were made, by name, in `groups.json` beside the sessions.
/// A session says which group it is in; this file is what lets a group exist
/// before it has a session and after its last one has left.
enum GroupStore {
    static var file: URL { SessionStore.folder.deletingLastPathComponent().appendingPathComponent("groups.json") }
    static func clean(_ raw: String) -> String? { SessionStore.cleanName(raw, limit: SessionStore.groupLimit) }
    static func load() -> [String] {
        (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? []
    }
    static func save(_ names: [String]) throws {
        var seen = Set<String>()
        let unique = names.filter { seen.insert($0).inserted }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        try encoder.encode(unique).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
    /// Every group there is: the ones made, and any a session names that the
    /// file does not know of (groups from 0.12.0, or a session put back from the Trash).
    static func names(sessions: [String?]) -> [String] {
        var seen = Set<String>()
        return (load() + sessions.compactMap { $0 }).filter { seen.insert($0).inserted }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
    /// True when the group is new.
    @discardableResult
    static func add(_ name: String) throws -> Bool {
        var names = load()
        guard !names.contains(name) else { return false }
        names.append(name)
        try save(names)
        return true
    }
    static func remove(_ name: String) throws {
        let names = load()
        if names.contains(name) { try save(names.filter { $0 != name }) }
    }
}

/// Saves sessions off the main thread. A session is saved after every settled
/// sentence; encoding the whole of it there held up the interface for longer
/// the longer the session ran (measured: 15 ms at 4,000 lines). Saves that
/// pile up behind a slow disk collapse into the newest one.
final class SessionWriter: @unchecked Sendable {
    private let queue = DispatchQueue(label: "ListenFlow.sessions", qos: .utility)
    private let lock = NSLock()
    private var waiting: [UUID: MeetingSession] = [:]
    /// Called on the main queue when a save fails.
    var onError: ((String) -> Void)?

    func save(_ session: MeetingSession) {
        let schedule: Bool = lock.withLock {
            let queued = waiting[session.id] != nil
            waiting[session.id] = session
            return !queued
        }
        guard schedule else { return }
        let id = session.id
        queue.async { [self] in
            guard let latest = lock.withLock({ waiting.removeValue(forKey: id) }) else { return }
            do { try SessionStore.save(latest) }
            catch {
                let message = error.localizedDescription
                DispatchQueue.main.async { self.onError?(message) }
            }
        }
    }

    /// Returns once everything handed to `save` so far is on disk.
    func flush() { queue.sync {} }
}

/// A stretch of the transcript shown as one paragraph. Live recognition settles
/// a line per sentence, and a microphone running beside the Mac's sound is cut
/// every 0.2 s; read as separate rows that is choppy. Only the display joins
/// them: the stored lines, and what `lstf` reads, stay one per sentence.
struct TranscriptBlock: Identifiable, Equatable {
    /// The first line's id, so a block keeps its identity while it grows.
    let id: UUID
    let start: Date
    var end: Date
    let source: String
    var text: String
    let refined: Bool
    /// False when the block before it is from the same source.
    var showsSource: Bool
}

/// One thing on the transcript page: a paragraph of speech, or a picture kept
/// at that moment.
enum TranscriptEntry: Identifiable {
    case block(TranscriptBlock)
    case image(ImageAttachment)
    var id: UUID {
        switch self {
        case let .block(block): block.id
        case let .image(image): image.id
        }
    }
    var time: Date {
        switch self {
        case let .block(block): block.start
        case let .image(image): image.addedAt
        }
    }
}

enum TranscriptLayout {
    /// A longer pause than this starts a new paragraph.
    static let gap: TimeInterval = 2.5
    static let seconds: TimeInterval = 45

    /// Lines that were re-recognized are paragraphs already and are left as
    /// they are. `breakBefore` forces a new block at that line, and so does
    /// each of `cuts`: a paragraph does not run across a picture.
    static func blocks(_ lines: [TranscriptLine], breakBefore: UUID? = nil, cuts: [Date] = []) -> [TranscriptBlock] {
        var out: [TranscriptBlock] = []
        for line in lines {
            if var last = out.last, !last.refined, line.refined != true, line.id != breakBefore,
               last.source == line.source, line.start.timeIntervalSince(last.end) <= gap,
               line.end.timeIntervalSince(last.start) <= seconds,
               !cuts.contains(where: { $0 > last.start && $0 <= line.start }) {
                // Latin words need a space between them; Chinese does not.
                let latin = last.text.last.map { $0.isASCII && ($0.isLetter || $0.isNumber) } == true
                    && line.text.first.map { $0.isASCII && ($0.isLetter || $0.isNumber) } == true
                last.text += (latin ? " " : "") + line.text
                last.end = max(last.end, line.end)
                out[out.count - 1] = last
            } else {
                out.append(TranscriptBlock(id: line.id, start: line.start, end: line.end, source: line.source, text: line.text,
                                           refined: line.refined == true, showsSource: out.last?.source != line.source))
            }
        }
        return out
    }

    /// Paragraphs and pictures in the order they happened. A paragraph names
    /// its source again after a picture.
    static func timeline(_ session: MeetingSession, breakBefore: UUID? = nil) -> [TranscriptEntry] {
        let images = session.imageLibrary.sorted { $0.addedAt < $1.addedAt }
        var blocks = blocks(session.lines, breakBefore: breakBefore, cuts: images.map(\.addedAt))[...]
        var out: [TranscriptEntry] = []
        for image in images {
            while let block = blocks.first, block.start <= image.addedAt { out.append(.block(block)); blocks.removeFirst() }
            out.append(.image(image))
            if var next = blocks.first { next.showsSource = true; blocks[blocks.startIndex] = next }
        }
        out += blocks.map(TranscriptEntry.block)
        return out
    }
}

enum SessionStore {
    /// Tests, and preview builds that are told to, keep sessions somewhere else.
    nonisolated(unsafe) static var folderOverride: URL?
    static var folder: URL {
        folderOverride ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ListenFlow/Sessions", isDirectory: true)
    }
    /// Preview builds are driven by fixtures and never write, unless a test has
    /// pointed them at a folder of its own.
    static var writes: Bool { !ListenFlowHome.isPreview || folderOverride != nil }
    static func load(_ id: UUID) -> MeetingSession? {
        (try? Data(contentsOf: folder.appendingPathComponent(id.uuidString + ".json")))
            .flatMap { try? JSONDecoder().decode(MeetingSession.self, from: $0) }
    }
    static func save(_ session: MeetingSession) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let url = folder.appendingPathComponent(session.id.uuidString + ".json")
        try encoder.encode(session).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    static let nameLimit = 60
    static let groupLimit = 30
    /// A name as it will be stored: one line, no stray space, not endless.
    /// Nil when nothing is left of it.
    static func cleanName(_ raw: String, limit: Int = nameLimit) -> String? {
        let words = raw.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
        let name = String(words.joined(separator: " ").prefix(limit)).trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }
    /// Changes something about a session that is on disk and that nothing has
    /// open. The app changes the one it has open itself, or its next save
    /// would undo this.
    @discardableResult
    static func update(_ id: UUID, _ change: (inout MeetingSession) -> Void) throws -> MeetingSession {
        guard var session = load(id) else { throw CaptureFailure.message("找不到这场会话，或它的文件读不出来。") }
        change(&session)
        try save(session)
        return session
    }
    /// A title the app made up is "<what was recorded> · <date>", and the date
    /// is dropped wherever it is shown beside the name; a given name is kept whole.
    static func name(title: String, renamed: Bool) -> String {
        renamed ? title : title.components(separatedBy: " · ").first ?? title
    }
    /// Renames a session that is on disk and that nothing has open. The app
    /// renames the one it has open itself, or its next save would undo this.
    @discardableResult
    static func rename(_ id: UUID, to name: String) throws -> MeetingSession {
        guard let name = cleanName(name) else { throw CaptureFailure.message("名字不能是空的。") }
        guard var session = load(id) else { throw CaptureFailure.message("找不到这场会话，或它的文件读不出来。") }
        session.title = name
        session.renamed = true
        try save(session)
        return session
    }
    static let draftLimit = 300_000
    /// A draft as it will be stored; nil when nothing is left of it.
    static func cleanDraft(_ raw: String) -> String? {
        let text = raw.replacingOccurrences(of: "\r\n", with: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
    /// How many lines a draft handed in from outside stands for, or why it
    /// cannot be taken. A draft that exists is only replaced when asked to be;
    /// while lines are still arriving the writer has to say how far it read.
    static func draftCoverage(_ session: MeetingSession, through: Int?, replace: Bool, growing: Bool) throws -> Int {
        if session.organized != nil && !replace {
            throw CaptureFailure.message("这场会话已经有整理稿。先读它（lstf read \(session.id.uuidString.prefix(8)) --organized）；确实要换成新的一版，加 --replace。")
        }
        if let through {
            guard through >= 0, through <= session.lines.count, through > 0 || session.lines.isEmpty else {
                throw CaptureFailure.message("这场会话有 \(session.lines.count) 行，--through 不能是 \(through)。")
            }
            return through
        }
        if growing {
            throw CaptureFailure.message("这场会话还在录制，行数在增加：用 --through N 说明这份整理稿覆盖到第几行（你读到的最后一行）。")
        }
        return session.lines.count
    }
    /// Writes a draft into a session that is on disk and that nothing has open.
    @discardableResult
    static func writeDraft(_ id: UUID, text: String, through: Int?, replace: Bool) throws -> MeetingSession {
        guard let text = cleanDraft(text) else { throw CaptureFailure.message("整理稿是空的。") }
        guard text.count <= draftLimit else { throw CaptureFailure.message("整理稿太长（\(text.count) 字），上限是 \(draftLimit) 字。") }
        guard var session = load(id) else { throw CaptureFailure.message("找不到这场会话，或它的文件读不出来。") }
        let count = try draftCoverage(session, through: through, replace: replace, growing: false)
        session.setDraft(text, through: count, author: OrganizedTranscript.agent)
        try save(session)
        return session
    }
    /// Takes a session off the disk: its file, then its pictures. `remove` says
    /// how — the app moves them to the Trash. Kept audio is not touched here.
    /// A session that is not there is not an error.
    static func delete(_ id: UUID, remove: (URL) throws -> Void) throws {
        let fm = FileManager.default
        // The file first: once it is gone the session is gone, whatever becomes of the pictures.
        for url in [folder.appendingPathComponent(id.uuidString + ".json"), ImageAttachmentStore.folder(for: id)]
        where fm.fileExists(atPath: url.path) {
            try remove(url)
        }
    }
    static func trash(_ url: URL) throws { try FileManager.default.trashItem(at: url, resultingItemURL: nil) }
    static func all() -> [MeetingSession] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.compactMap {
            guard let data = try? Data(contentsOf: $0) else { return nil }
            return try? JSONDecoder().decode(MeetingSession.self, from: data)
        }.sorted { $0.created > $1.created }
    }
    /// What the session list shows, read without building every line of every
    /// session: the app keeps these in memory instead of whole sessions.
    static func summaries() -> [SessionSummary] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.compactMap {
            guard let data = try? Data(contentsOf: $0) else { return nil }
            return try? JSONDecoder().decode(SessionSummary.self, from: data)
        }.sorted { $0.created > $1.created }
    }
    static func timestamp(_ date: Date, relativeTo start: Date) -> String {
        let seconds = max(0, Int(date.timeIntervalSince(start)))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
    static func transcript(_ session: MeetingSession) -> String {
        session.lines.map {
            "[\(timestamp($0.start, relativeTo: session.created))] [\($0.source)] \($0.text)"
        }.joined(separator: "\n")
    }
    static func markdown(_ session: MeetingSession) -> String {
        var result = "# \(session.title)\n\n"
        if let organized = session.organized {
            let scope = organized.sourceLineIDs.isEmpty ? "图片资料" : "截至 \(timestamp(organized.through, relativeTo: session.created))"
            let labels = session.imageLibrary.filter { organized.imageIDs?.contains($0.id) == true }.map(\.label).joined(separator: "、")
            result += "## 整理稿\n\n整理范围：\(scope)\(labels.isEmpty ? "" : "；参考图片：" + labels)；\(organized.fromAgent ? "agent 通过 lstf 写入" : "AI 整理")，请对照原文核实。\n\n\(organized.text)\n\n"
            if session.unorganizedCount > 0 { result += "另有 \(session.unorganizedCount) 段原始转写尚未纳入整理稿。\n\n" }
        }
        result += "## 原始转写\n\n\(transcript(session))\n\n"
        // Sessions from before 0.11.0 may hold questions asked in the app.
        if !session.chat.isEmpty { result += "## 问答\n\n" }
        for message in session.chat {
            result += "### \(message.role == "user" ? "提问" : "回答")\n\n\(message.text)\n\n"
            let labels = session.imageLibrary.filter { message.imageIDs?.contains($0.id) == true }.map(\.label).joined(separator: "、")
            if !labels.isEmpty { result += "附图：\(labels)\n\n" }
        }
        return result
    }

    static func export(_ session: MeetingSession, to destination: URL) throws {
        var text = markdown(session)
        if !session.imageLibrary.isEmpty {
            let name = destination.deletingPathExtension().lastPathComponent + ".images"
            let directory = destination.deletingLastPathComponent().appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            text += "## 图片资料\n\n"
            for image in session.imageLibrary {
                let filename = image.id.uuidString + ".jpg"
                let data = try Data(contentsOf: ImageAttachmentStore.url(for: image, sessionID: session.id))
                try data.write(to: directory.appendingPathComponent(filename), options: .atomic)
                let relative = (name + "/" + filename).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? ""
                text += "\(image.label)：\(image.name)\n\n![\(image.label)](\(relative))\n\n"
            }
        }
        try text.write(to: destination, atomically: true, encoding: .utf8)
    }
}
