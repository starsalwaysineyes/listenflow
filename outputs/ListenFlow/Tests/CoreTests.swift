import Foundation

enum CaptureFailure: LocalizedError {
    case message(String)
    var errorDescription: String? { if case let .message(value) = self { return value }; return nil }
}

@main struct CoreTests {
    static func main() async throws {
        var chunks: [AudioChunk] = []
        let start = Date(timeIntervalSince1970: 1000)
        // Stand-in for speech: a 400 Hz tone (exactly 8 cycles per 20 ms frame, so
        // every frame has the same energy). The chunker judges speech above 200 Hz,
        // so a DC level would rightly read as silence.
        func tone(_ count: Int, _ amplitude: Float = 0.14, phase: Int = 0) -> [Float] {
            (0..<count).map { amplitude * sin(2 * Float.pi * 400 * Float($0 + phase) / 16000) }
        }
        let chunker = AudioChunker(source: "App") { chunks.append($0) }
        chunker.append([Float](repeating: 0, count: 16000), end: start)
        chunker.flush()
        precondition(chunks.isEmpty, "Silence must not produce ASR requests")

        // Unbroken speech has no pause to cut in: bounded by the ceiling, cut late,
        // flagged as forced, and nothing lost or duplicated across the seams.
        let voice = tone(16000 * 20)
        chunker.append(voice, end: start.addingTimeInterval(20))
        chunker.flush()
        precondition(chunks.count == 3, "20 s of gapless speech should give two ceiling cuts, got \(chunks.count)")
        precondition(chunks.map { $0.samples.count }.reduce(0, +) == voice.count, "No samples lost at boundaries")
        precondition(chunks.allSatisfy { $0.samples.count <= 16000 * 8 }, "Ceiling must hold")
        precondition(chunks[0].samples.count >= 16000 * 7, "Uniform audio should be cut late, near the ceiling")
        precondition(chunks[0].forced && chunks[1].forced && !chunks[2].forced)
        precondition(abs(chunks[0].start.timeIntervalSince(start)) < 0.001)
        precondition(abs(chunks[1].start.timeIntervalSince(chunks[0].end)) < 0.001, "Seams must be contiguous")
        precondition(abs(chunks[2].end.timeIntervalSince(start) - 20) < 0.001)

        chunks.removeAll()
        let pause = AudioChunker(source: "App") { chunks.append($0) }
        pause.append(tone(16000), end: start.addingTimeInterval(1))
        pause.append([Float](repeating: 0, count: 8000), end: start.addingTimeInterval(1.5))
        precondition(chunks.isEmpty, "A short phrase waits through a brief pause for more context")
        pause.append([Float](repeating: 0, count: 16000), end: start.addingTimeInterval(2.5))
        precondition(chunks.count == 1, "A real pause should close a short chunk before the ceiling")
        precondition(chunks[0].samples.count == 40000 && !chunks[0].forced)

        // A lecturer: 1 s phrases separated by 1 s pauses join into one chunk
        // instead of being sent as fragments.
        chunks.removeAll()
        let lecturer = AudioChunker(source: "麦克风") { chunks.append($0) }
        for k in 0..<3 {
            lecturer.append(tone(16000, phase: k), end: start.addingTimeInterval(Double(k) * 2 + 1))
            lecturer.append([Float](repeating: 0, count: 16000), end: start.addingTimeInterval(Double(k) * 2 + 2))
        }
        lecturer.append([Float](repeating: 0, count: 32000), end: start.addingTimeInterval(8))
        // Old behaviour sent each phrase alone (3 chunks). Now the first two join until
        // the chunk reaches 3 s, and only the last phrase stands alone.
        precondition(chunks.count == 2, "Phrases with ~1 s pauses are joined, got \(chunks.count)")
        precondition(Double(chunks[0].samples.count) / 16000 >= 3, "The first chunk carries two phrases")

        // Words separated by short gaps over a steady noise floor that sits above the
        // old fixed 0.003 gate: the cut must still land in a gap, not on a clock.
        chunks.removeAll()
        let noisy = AudioChunker(source: "App") { chunks.append($0) }
        var meeting: [Float] = []
        for i in 0..<20 {   // 20 × (0.4 s word + 0.2 s gap) = 12 s
            meeting += tone(6400, phase: i * 7)
            meeting += (0..<3200).map { 0.006 * (($0 % 2 == 0) ? 1 : -1) }
        }
        noisy.append(meeting, end: start.addingTimeInterval(12))
        precondition(!chunks.isEmpty && chunks.allSatisfy { !$0.forced }, "Gaps in noise must be found")
        for chunk in chunks {
            let seconds = Double(chunk.samples.count) / 16000
            precondition(seconds >= 2.8 && seconds < 4, "Cut at the first gap once ~3 s long, got \(seconds)")
            let cutInGap = chunk.samples.suffix(320).allSatisfy { abs($0) < 0.01 }
            precondition(cutInGap, "Seam must fall inside a gap, never inside a word")
        }
        let emitted = chunks.count
        noisy.append([Float](repeating: 0.006, count: 16000 * 2), end: start.addingTimeInterval(14))
        noisy.flush()
        precondition(chunks.count == emitted, "Trailing noise alone must not produce a chunk")
        precondition(chunks.last!.end.timeIntervalSince(start) >= 11.6, "The last word is covered")
        precondition(chunks.allSatisfy { $0.samples.contains { $0 > 0.05 } }, "Silence-only chunks are never sent")

        // Far-field room: a 60 Hz rumble louder than the soft voice. Judged on raw
        // energy every frame reads as speech and no gap is ever found; judged above
        // 200 Hz the gaps between words reappear and the cut lands in one.
        chunks.removeAll()
        let room = AudioChunker(source: "麦克风") { chunks.append($0) }
        var lecture: [Float] = []
        for _ in 0..<20 {   // 20 × (0.4 s soft word + 0.2 s gap) = 12 s
            lecture += tone(6400, 0.012)
            lecture += [Float](repeating: 0, count: 3200)
        }
        lecture = lecture.enumerated().map { $1 + 0.03 * sin(2 * Float.pi * 60 * Float($0) / 16000) }
        room.append(lecture, end: start.addingTimeInterval(12))
        precondition(!chunks.isEmpty && chunks.allSatisfy { !$0.forced }, "Pauses under low-frequency rumble must be found")
        precondition(chunks.allSatisfy { Double($0.samples.count) / 16000 < 4 }, "Cut at the first pause, not the ceiling")

        chunks.removeAll()
        chunker.append(tone(8000), end: start)
        chunker.discard()
        chunker.flush()
        precondition(chunks.isEmpty, "Discard must clear in-flight audio")

        let app = AudioChunker(source: "Browser") { chunks.append($0) }
        let mic = AudioChunker(source: "麦克风") { chunks.append($0) }
        app.append(tone(32000, 0.28), end: start)
        mic.append(tone(16000), end: start)
        mic.flush()
        app.append(tone(32000, 0.28, phase: 32000), end: start.addingTimeInterval(2))
        app.flush()
        precondition(chunks.map(\.source) == ["麦克风", "Browser"], "Mic flush must not reset App audio")
        precondition(chunks[1].samples.count == 64000, "App audio continued across the mic flush")

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

        // Settings written by 0.5.0 (no recognition fields) keep every saved value.
        let oldPrefs = #"{"python":"/opt/py","asrModel":"m","language":"Chinese","hotwords":"小林","apiBase":"https://x.example","llmModel":"l"}"#
        let prefs = try JSONDecoder().decode(Preferences.self, from: Data(oldPrefs.utf8))
        precondition(prefs.python == "/opt/py" && prefs.hotwords == "小林" && prefs.apiBase == "https://x.example")
        precondition(prefs.recognitionMode == .auto && prefs.keepAudioForRefine)
        precondition(prefs.islandEnabled && !prefs.islandShowLatest && prefs.islandHeight == 300 && prefs.islandWidth == 720, "Island defaults for older settings")
        let roundPrefs = try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(prefs))
        precondition(roundPrefs.recognitionMode == .auto && roundPrefs.python == "/opt/py")
        precondition(PowerSource.wantsQuality(.quality) && !PowerSource.wantsQuality(.economy))

        // Refinement windows: same source, contiguous audio, capped length, no long silence.
        func line(_ t: Double, _ d: Double, _ src: String, _ off: Int, _ text: String = "字") -> TranscriptLine {
            TranscriptLine(start: start.addingTimeInterval(t), end: start.addingTimeInterval(t + d), source: src,
                           text: text, latency: 1, audio: AudioRef(offset: off, count: Int(d * 16000)))
        }
        let rl = [line(0, 5, "A", 0), line(5, 5, "A", 80000), line(10, 5, "A", 160000), line(15, 5, "A", 240000),
                  line(20, 5, "A", 320000), line(25, 5, "A", 400000), line(30, 5, "A", 480000),
                  line(45, 4, "A", 560000),                                   // after 10 s of silence
                  line(2, 3, "麦克风", 0), line(6, 3, "麦克风", 48000)]
        let groups = Refinement.windows(rl, limit: 30)
        precondition(groups.allSatisfy { Set($0.map(\.source)).count == 1 }, "Never mix sources")
        precondition(groups.allSatisfy { $0.last!.end.timeIntervalSince($0.first!.start) <= 30 }, "Cap holds")
        precondition(groups.allSatisfy { $0.count >= 2 }, "Single lines are not re-decoded")
        precondition(!groups.contains { g in g.contains { $0.start == start.addingTimeInterval(45) } }, "No joining across long silence")
        precondition(groups.map(\.count) == [6, 2], "Got \(groups.map(\.count))")
        let merged = Refinement.merge(Array(groups[0]), text: "精修后的文字")
        precondition(merged.id == groups[0][0].id && merged.audio == AudioRef(offset: 0, count: 480000))
        precondition(merged.refined == true && groups[0].allSatisfy { $0.refined == nil }, "Only merged lines are marked as re-recognized")
        let legacyLine = #"{"id":"6F9619FF-8B86-D011-B42D-00CF4FC964FF","start":0,"end":4,"source":"麦克风","text":"旧","latency":1}"#
        let legacy = try JSONDecoder().decode(TranscriptLine.self, from: Data(legacyLine.utf8))
        precondition(legacy.refined == nil, "Older lines still decode")
        var replaced = rl
        precondition(Refinement.apply(merged, replacing: groups[0].map(\.id), in: &replaced))
        precondition(replaced.count == rl.count - 5 && replaced.contains { $0.text == "精修后的文字" })
        precondition(!Refinement.apply(merged, replacing: groups[0].map(\.id), in: &replaced), "Stale jobs are refused")
        precondition(Refinement.plausible(original: "今天讨论发布安排。", refined: "今天讨论发布的安排"))
        precondition(!Refinement.plausible(original: "今天讨论发布安排，小林负责周五", refined: "嗯。"), "Collapsed output refused")
        precondition(!Refinement.plausible(original: "好的", refined: "好的好的好的好的好的好的"), "Hallucinated output refused")
        precondition(Refinement.dropTrailingStop("被推向远处。") == "被推向远处" && Refinement.dropTrailingStop("真的？") == "真的？")
        // A line whose audio is gone (a dropped echo) breaks the window: its audio must not be read back in.
        let gapped = [line(0, 3, "麦克风", 0), line(3, 3, "麦克风", 48000), line(9, 3, "麦克风", 144000), line(12, 3, "麦克风", 192000)]
        precondition(Refinement.windows(gapped, limit: 30).map(\.count) == [2, 2], "Never read across dropped audio")

        // Echo: a microphone line repeating the app at the same time is dropped.
        func spoken(_ t: Double, _ d: Double, _ src: String, _ text: String) -> TranscriptLine {
            TranscriptLine(start: start.addingTimeInterval(t), end: start.addingTimeInterval(t + d), source: src, text: text, latency: 1)
        }
        let appLines = [spoken(0, 6, "腾讯会议", "哎，你上次说的那家火锅店我去了，真的挺好吃的，"),
                   spoken(6, 5, "腾讯会议", "就是排队排得太久了。我们六点到的。"),
                   spoken(30, 2, "腾讯会议", "好的。")]
        // Measured: the microphone's copy of that speech, cut at different points, with recognition differences.
        let echo = spoken(0.2, 8, "麦克风", "你上次说的那家火锅店，我去了，真的挺好吃的，就是排队排得太久了")
        precondition(EchoFilter.isEcho(echo, among: appLines), "Echo dropped")
        precondition(!EchoFilter.isEcho(spoken(1, 5, "麦克风", "我们开始今天的周会，先同步一下进度。"), among: appLines), "Own speech kept")
        precondition(!EchoFilter.isEcho(spoken(40, 6, "麦克风", "你上次说的那家火锅店我去了"), among: appLines), "Only the same time counts")
        precondition(!EchoFilter.isEcho(appLines[0], among: appLines + [echo]), "App lines are never dropped")
        precondition(EchoFilter.isEcho(spoken(30.1, 1.5, "麦克风", "好的"), among: appLines), "Short echo aligned in time")
        precondition(!EchoFilter.isEcho(spoken(32.4, 1, "麦克风", "好的"), among: appLines), "A short reply after the app's is the user's own")
        precondition(!EchoFilter.isEcho(spoken(2, 4, "麦克风", "对"), among: appLines), "A one-word reply is not matched by chance")
        // Talking over the other side: the line is mostly the user's, so it stays.
        precondition(!EchoFilter.isEcho(spoken(6, 5, "麦克风", "我觉得周四之前修不完，排队的问题先放一放"), among: appLines), "Double talk kept")

        // Kept audio: ordered ranges, faithful round trip, removable.
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("lf-audio-\(UUID().uuidString)")
        AudioStore.rootOverride = tmp
        let sid = UUID()
        let r1 = AudioStore.append([Float](repeating: 0.25, count: 1000), session: sid, source: "腾讯会议")
        let r2 = AudioStore.append((0..<500).map { Float($0) / 1000 }, session: sid, source: "腾讯会议")
        precondition(r1 == AudioRef(offset: 0, count: 1000) && r2 == AudioRef(offset: 1000, count: 500))
        let back = AudioStore.read(session: sid, source: "腾讯会议", offset: 1000, count: 500)!
        precondition(zip(back, (0..<500).map { Float($0) / 1000 }).allSatisfy { abs($0 - $1) < 0.0002 })
        let perms = try FileManager.default.attributesOfItem(atPath: AudioStore.file(session: sid, source: "腾讯会议").path)[.posixPermissions] as! Int
        precondition(perms == 0o600, "Kept audio must be private")
        AudioStore.delete(sid)
        precondition(!AudioStore.hasAudio(sid) && AudioStore.read(session: sid, source: "腾讯会议", offset: 0, count: 1) == nil)
        try? FileManager.default.removeItem(at: tmp)

        // A post-hoc refinement makes an older draft stale; sessions without the field still decode.
        var refinedSession = MeetingSession(title: "R", created: start)
        precondition(refinedSession.refinedAt == nil)
        refinedSession.refinedAt = Date()
        let refinedRound = try JSONDecoder().decode(MeetingSession.self, from: JSONEncoder().encode(refinedSession))
        precondition(refinedRound.refinedAt != nil)

        print("PASS: silence, bounded chunks, lossless boundaries, endpointing, independent sources, discard, API URLs, context snapshots, session round-trip")
        print("PASS: old-session compatibility, organized draft persistence/export, late-arrival coverage, lossless cleanup batching, raw-only cleanup context")
        print("PASS: pause-aware chunking under noise, forced-cut flags, settings migration, refinement windows/guards/merge, echo filter, private audio store round trip")
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
