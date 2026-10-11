import Foundation
import Security

struct Preferences: Codable {
    var python = "/Users/aurora/Desktop/workspace/asr-realtime-lab/.venv/bin/python"
    var asrModel = "mlx-community/Qwen3-ASR-1.7B-8bit"
    var language = ""
    var hotwords = ""
    var apiBase = "https://api.deepseek.com"
    var llmModel = "deepseek-flash"
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

struct TranscriptLine: Identifiable, Codable {
    var id = UUID()
    let start: Date
    let end: Date
    let source: String
    let text: String
    let latency: Double
}
struct ChatMessage: Identifiable, Codable {
    var id = UUID()
    let role: String
    var text: String
    var contextThrough: Date?
    var imageIDs: [UUID]?
}
struct OrganizedTranscript: Codable {
    let text: String
    let generatedAt: Date
    let sourceLineIDs: [UUID]
    let through: Date
    var imageIDs: [UUID]?
}
struct MeetingSession: Codable, Identifiable {
    var id = UUID()
    var title = "新的会话"
    var created = Date()
    var lines: [TranscriptLine] = []
    var chat: [ChatMessage] = []
    var organized: OrganizedTranscript?
    var images: [ImageAttachment]?
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
