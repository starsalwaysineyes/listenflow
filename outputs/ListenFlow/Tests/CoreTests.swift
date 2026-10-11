import Foundation

enum CaptureFailure: LocalizedError {
    case message(String)
    var errorDescription: String? { if case let .message(value) = self { return value }; return nil }
}

@main struct CoreTests {
    static func main() async throws {
        var chunks: [AudioChunk] = []
        let start = Date(timeIntervalSince1970: 1000)
        let chunker = AudioChunker(source: "App") { chunks.append($0) }
        chunker.append([Float](repeating: 0, count: 16000), end: start)
        chunker.flush()
        precondition(chunks.isEmpty, "Silence must not produce ASR requests")

        let voice = [Float](repeating: 0.1, count: 16000 * 10)
        chunker.append(voice, end: start.addingTimeInterval(10))
        chunker.flush()
        precondition(chunks.count == 3, "Continuous speech must be bounded to four seconds")
        precondition(chunks.map { $0.samples.count }.reduce(0, +) == voice.count, "No samples lost at boundaries")
        precondition(chunks.allSatisfy { $0.samples.count <= 64000 })
        precondition(abs(chunks[0].start.timeIntervalSince(start)) < 0.001)
        precondition(abs(chunks[2].end.timeIntervalSince(start) - 10) < 0.001)

        chunks.removeAll()
        chunker.append([Float](repeating: 0.1, count: 16000), end: start.addingTimeInterval(1))
        chunker.append([Float](repeating: 0, count: 8000), end: start.addingTimeInterval(1.5))
        precondition(chunks.count == 1, "Pause endpoint should flush before max chunk duration")
        precondition(chunks[0].samples.count == 24000)

        chunks.removeAll()
        chunker.append([Float](repeating: 0.1, count: 8000), end: start)
        chunker.discard()
        chunker.flush()
        precondition(chunks.isEmpty, "Discard must clear in-flight audio")

        let app = AudioChunker(source: "Browser") { chunks.append($0) }
        let mic = AudioChunker(source: "麦克风") { chunks.append($0) }
        app.append([Float](repeating: 0.2, count: 32000), end: start)
        mic.append([Float](repeating: 0.1, count: 16000), end: start)
        mic.flush()
        app.append([Float](repeating: 0.2, count: 32000), end: start.addingTimeInterval(2))
        precondition(chunks.map(\.source) == ["麦克风", "Browser"], "Mic flush must not reset App audio")

        let ep = try LLMClient.endpoint("https://api.deepseek.com")
        precondition(ep.absoluteString == "https://api.deepseek.com/chat/completions")
        let versioned = try LLMClient.endpoint("https://example.org/v1/")
        let local = try LLMClient.endpoint("http://127.0.0.1:8123/v1")
        precondition(versioned.absoluteString == "https://example.org/v1/chat/completions")
        precondition(local.scheme == "http")
        do { _ = try LLMClient.endpoint("http://untrusted.example/v1"); fatalError("Remote cleartext endpoint accepted") } catch {}

        var session = MeetingSession(title: "Test", created: start)
        session.lines = [TranscriptLine(start: start.addingTimeInterval(3), end: start.addingTimeInterval(7), source: "Browser", text: "Friday release", latency: 4.5)]
        session.chat = [ChatMessage(role: "user", text: "When?"), ChatMessage(role: "assistant", text: "Friday")]
        let messages = LLMClient.messages(session: session, question: "Owner?")
        precondition(messages[1]["content"]!.contains("[00:03] [Browser] Friday release"))
        precondition(messages.last?["content"] == "Owner?")
        precondition(messages.filter { $0["content"] == "Owner?" }.count == 1)
        let encoded = try JSONEncoder().encode(session)
        let decoded = try JSONDecoder().decode(MeetingSession.self, from: encoded)
        precondition(decoded.lines[0].text == "Friday release")
        precondition(SessionStore.markdown(decoded).contains("Friday"))
        precondition(decoded.organized == nil, "Old session JSON must remain readable")
        let oldIDs = session.lines.map(\.id)
        session.organized = OrganizedTranscript(text: "[00:03] Friday release.", generatedAt: Date(),
                                                sourceLineIDs: oldIDs, through: session.lines[0].end)
        precondition(session.unorganizedCount == 0)
        session.lines.insert(TranscriptLine(start: start, end: start, source: "麦克风", text: "New late-arriving audio", latency: 1), at: 0)
        precondition(session.unorganizedCount == 1, "Coverage must use IDs, not an assumed prefix or count")
        let roundTrip = try JSONDecoder().decode(MeetingSession.self, from: JSONEncoder().encode(session))
        precondition(roundTrip.organized?.sourceLineIDs == oldIDs)
        precondition(SessionStore.markdown(roundTrip).contains("整理稿") && SessionStore.markdown(roundTrip).contains("尚未纳入"))
        let batches = LLMClient.organizationBatches(session.lines, maxCharacters: 60)
        precondition(batches.count == 2)
        precondition(batches.flatMap { $0 }.map(\.id) == session.lines.map(\.id))
        let organizationMessages = LLMClient.organizationMessages(session: session, lines: batches[0])
        precondition(organizationMessages.count == 2 && !organizationMessages[1]["content"]!.contains("When?"), "Cleanup must use raw transcript, not prior answers")
        precondition(organizationMessages[1]["content"]!.contains("New late-arriving audio"))

        print("PASS: silence, bounded chunks, lossless boundaries, endpointing, independent sources, discard, API URLs, context snapshots, session round-trip")
        print("PASS: old-session compatibility, organized draft persistence/export, late-arrival coverage, lossless cleanup batching, raw-only cleanup context")
        if CommandLine.arguments.contains("--organize-live") {
            let key = String(data: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8)!.trimmingCharacters(in: .whitespacesAndNewlines)
            var fixture = MeetingSession(title: "整理功能测试（虚构记录）", created: start)
            let fragments = ["啊，我们今天讨论产品发布的。", "的安排。小林负责周五下午三点。", "发布雏形，预算上限是五千元。", "有人提议下周一再做用户验证，这个方案还没有决定。", "另外，麦克风默认关闭，不收集。", "不收集麦克风的声音，但继续转写 App 的音频。", "最后一个问题是……"]
            fixture.lines = fragments.enumerated().map { i, text in
                TranscriptLine(start: start.addingTimeInterval(Double(i * 4)), end: start.addingTimeInterval(Double(i * 4 + 4)),
                               source: "测试 App", text: text, latency: 4.3)
            }
            let parts = try await LLMClient.organize(preferences: Preferences(), key: key, session: fixture, lines: fixture.lines) { _ in }
            let text = parts.map(\.text).joined(separator: "\n\n")
            print("Live cleanup result:\n\(text)")
            precondition(text.contains("小林") && text.contains("麦克风") && text.contains("App"))
            precondition(text.contains("五千") || text.contains("5000") || text.contains("5,000"))
            precondition(parts.count == LLMClient.organizationBatches(fixture.lines).count, "One part per batch, so boundaries stay addressable")
            try JSONEncoder().encode(fixture).write(to: URL(fileURLWithPath: "work/organization-fixture.json"))
            try text.write(toFile: "work/organization-result.txt", atomically: true, encoding: .utf8)
            print("PASS: native live DeepSeek organization request; synthetic fixture saved for UI validation")
        }
        if let endpoint = ProcessInfo.processInfo.environment["TEST_LLM_BASE"] {
            var preferences = Preferences()
            preferences.apiBase = endpoint
            preferences.llmModel = "test"
            let answer = try await LLMClient.ask(preferences: preferences, key: "synthetic-test-token", session: session, question: "When?") { _ in }
            precondition(answer == "周五发布。[00:03]", "SSE parsing failed: \(answer)")
            print("PASS: native URLSession streaming API integration")
        }
    }
}
