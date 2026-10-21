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

struct Preferences: Codable {
    var python = "/Users/aurora/Desktop/workspace/asr-realtime-lab/.venv/bin/python"
    var asrModel = "mlx-community/Qwen3-ASR-1.7B-8bit"
    var language = ""
    var hotwords = ""
    var apiBase = "https://api.deepseek.com"
    var llmModel = "deepseek-flash"
    var recognitionMode = RecognitionMode.auto
    /// Keep the session's 16 kHz audio on this Mac so it can be re-recognized later;
    /// deleted once refined, and after seven days regardless.
    var keepAudioForRefine = true
    /// Live transcript in the notch. The body height is set by dragging the
    /// island's bottom edge; 0.7.0's line-count presets are not carried over,
    /// since even its default was too tall.
    var islandEnabled = true
    var islandShowLatest = false
    var islandHeight: Double = 300

    init() {}

    // Field-by-field so settings saved by an older build keep their values when a
    // new field appears, instead of the whole decode failing back to defaults.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Preferences()
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
    }

    static func load() -> Preferences {
        guard let data = UserDefaults.standard.data(forKey: "preferences"),
              let value = try? JSONDecoder().decode(Preferences.self, from: data) else { return Preferences() }
        return value
    }
    func save() { if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: "preferences") } }
}

enum SecretStore {
    private static let service = "local.ListenFlow.llm"
    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }
    static func read(account: String) -> String {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }
    static func save(_ value: String, account: String) throws {
        let q = query(account)
        if value.isEmpty {
            let status = SecItemDelete(q as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw CaptureFailure.message("无法删除钥匙串中的密钥（\(status)）。")
            }
            return
        }
        let data = Data(value.utf8)
        let status = SecItemUpdate(q as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = q
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let added = SecItemAdd(item as CFDictionary, nil)
            guard added == errSecSuccess else { throw CaptureFailure.message("无法保存 API 密钥到钥匙串（\(added)）。") }
        } else if status != errSecSuccess {
            throw CaptureFailure.message("无法更新 API 密钥（\(status)）。")
        }
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
}

struct OrganizedTranscript: Codable {
    var generatedAt: Date
    var segments: [OrganizedSegment]
    var imageIDs: [UUID]?

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
    var imageLibrary: [ImageAttachment] { images ?? [] }
    var unorganizedCount: Int {
        let included = Set(organized?.sourceLineIDs ?? [])
        return lines.filter { !included.contains($0.id) }.count
    }
}
enum SessionStore {
    static var folder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ListenFlow/Sessions", isDirectory: true)
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
    static func all() -> [MeetingSession] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.compactMap {
            guard let data = try? Data(contentsOf: $0) else { return nil }
            return try? JSONDecoder().decode(MeetingSession.self, from: data)
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
            result += "## 整理稿\n\n整理范围：\(scope)\(labels.isEmpty ? "" : "；参考图片：" + labels)；AI 整理，请对照原文核实。\n\n\(organized.text)\n\n"
            if session.unorganizedCount > 0 { result += "另有 \(session.unorganizedCount) 段原始转写尚未纳入整理稿。\n\n" }
        }
        result += "## 原始转写\n\n\(transcript(session))\n\n## 问答\n\n"
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
