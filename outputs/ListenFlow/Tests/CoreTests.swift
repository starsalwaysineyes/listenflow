import Foundation
import CoreGraphics

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
        precondition(SessionStore.transcript(session).contains("[00:03] [Browser] Friday release"))
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

        // --- Doubao streaming protocol ---
        // Real gzip, not raw deflate: magic bytes, and a round trip through the bounded inflater.
        let sample = Data((0..<5000).map { UInt8(truncatingIfNeeded: $0 &* 7) })
        let zipped = Gzip.compress(sample)!
        precondition(zipped.prefix(2) == Data([0x1f, 0x8b]), "gzip header")
        precondition(Gzip.decompress(zipped) == sample && Gzip.decompress(Data()) == Data())
        precondition(Gzip.decompress(zipped.prefix(zipped.count / 2)) == nil, "Truncated input is refused")
        precondition(Gzip.decompress(Gzip.compress(Data(count: 4096))!, limit: 1024) == nil, "Output is bounded")

        // Requests: 4-byte header, big-endian length, gzip payload.
        let audioFrame = VolcFrame.audio(sample, last: false)!, lastFrame = VolcFrame.audio(Data(), last: true)!
        precondition([UInt8](audioFrame.prefix(4)) == [0x11, 0x20, 0x01, 0x00] && [UInt8](lastFrame.prefix(4)) == [0x11, 0x22, 0x01, 0x00])
        let declared = audioFrame[4..<8].reduce(0) { $0 << 8 | Int($1) }
        precondition(declared == audioFrame.count - 8 && Gzip.decompress(audioFrame.dropFirst(8)) == sample)
        let config = VolcFrame.configuration(uid: "u", hotwords: ["梯度下降", " ", "损失函数"])
        precondition([UInt8](VolcFrame.fullRequest(config)!.prefix(4)) == [0x11, 0x10, 0x11, 0x00])
        let configObject = try JSONSerialization.jsonObject(with: config) as! [String: Any]
        let configRequest = configObject["request"] as! [String: Any]
        precondition(configRequest["enable_nonstream"] as? Bool == true && configRequest["show_utterances"] as? Bool == true
                     && configRequest["end_window_size"] as? Int == 1000 && configRequest["result_type"] as? String == "single")
        let corpus = (configRequest["corpus"] as! [String: Any])["context"] as! String
        precondition(corpus.contains("梯度下降") && corpus.contains("损失函数") && !corpus.contains("\" \""), "Hot words, blanks dropped")
        precondition((VolcFrame.configuration(uid: "u", hotwords: []).count) > 0
                     && !String(decoding: VolcFrame.configuration(uid: "u", hotwords: []), as: UTF8.self).contains("corpus"))
        let longWords = (0..<60).map { "术语编号\($0)" }
        let capped = String(decoding: VolcFrame.configuration(uid: "u", hotwords: longWords), as: UTF8.self)
        precondition(capped.contains("术语编号0") && !capped.contains("术语编号59"), "Hot words stay within the service's budget")
        precondition(VolcFrame.pcm([0, 1, -1, 2, 0.5]) == Data([0, 0, 0xff, 0x7f, 0x01, 0x80, 0xff, 0x7f, 0xff, 0x3f]), "Float to 16-bit LE, clamped")

        // Responses, as the service sends them.
        func response(_ header: [UInt8], sequence: Int32? = nil, code: UInt32? = nil, _ json: String, gzip: Bool = true) -> Data {
            var out = Data(header)
            if let sequence { withUnsafeBytes(of: sequence.bigEndian) { out.append(contentsOf: $0) } }
            if let code { withUnsafeBytes(of: code.bigEndian) { out.append(contentsOf: $0) } }
            let body = gzip ? Gzip.compress(Data(json.utf8))! : Data(json.utf8)
            withUnsafeBytes(of: UInt32(body.count).bigEndian) { out.append(contentsOf: $0) }
            return out + body
        }
        let resultJSON = #"{"audio_info":{"duration":8002},"result":{"text":"上一节","utterances":[{"definite":true,"start_time":0,"end_time":6892,"text":"今天继续讨论梯度下降方法。"},{"definite":false,"start_time":7312,"end_time":8002,"text":"上一节","words":[{"text":"上"}]}]}}"#
        let middle = try VolcFrame.parse(response([0x11, 0x91, 0x11, 0x00], sequence: 14, resultJSON))
        precondition(middle.messageType == 9 && middle.sequence == 14 && !middle.isLast && !middle.isError)
        let parsed = VolcFrame.utterances(in: middle.payload)!
        precondition(parsed.text == "上一节" && parsed.utterances == [
            VolcUtterance(text: "今天继续讨论梯度下降方法。", definite: true, startMS: 0, endMS: 6892),
            VolcUtterance(text: "上一节", definite: false, startMS: 7312, endMS: 8002)])
        let lastSequenced = try VolcFrame.parse(response([0x11, 0x93, 0x11, 0x00], sequence: -15, resultJSON))
        let lastPlain = try VolcFrame.parse(response([0x11, 0x92, 0x11, 0x00], resultJSON))
        precondition(lastSequenced.isLast && lastSequenced.sequence == -15, "Flag bit 1 and negative sequence")
        precondition(lastPlain.isLast && lastPlain.sequence == nil, "Last without a sequence")
        let first = try VolcFrame.parse(response([0x11, 0x90, 0x10, 0x00], #"{"result":{"text":""}}"#, gzip: false))
        precondition(first.sequence == nil && VolcFrame.utterances(in: first.payload)?.utterances.isEmpty == true, "Uncompressed, no sequence")
        let failure = try VolcFrame.parse(response([0x11, 0xf0, 0x10, 0x00], code: 45000292, #"{"error":"quota exceeded for types: concurrency"}"#, gzip: false))
        precondition(failure.isError && failure.errorCode == 45000292 && VolcFrame.errorMessage(failure.payload) == "quota exceeded for types: concurrency")
        precondition(VolcFrame.errorMessage(Data("plain text reason".utf8)) == "plain text reason")
        precondition(VolcFrame.errorMessage(Data(#"{"error":"[resource_id=x] requested resource not granted"}"#.utf8)).contains("not granted"), "Handshake refusal body")
        for bad in [Data([0x11, 0x90]), Data([0x11, 0x91, 0x11, 0x00, 0, 0]), Data([0x11, 0x90, 0x11, 0x00, 0, 0, 0, 9, 1, 2])] {
            precondition((try? VolcFrame.parse(bad)) == nil, "Malformed frames throw instead of crashing")
        }

        // A settled sentence becomes one line exactly once, however often it is resent.
        func u(_ text: String, _ definite: Bool, _ start: Int, _ end: Int) -> VolcUtterance {
            VolcUtterance(text: text, definite: definite, startMS: start, endMS: end)
        }
        var tracker = VolcUtteranceTracker()
        var step = tracker.update([u("各位同学", false, 0, 2600)], final: false)
        precondition(step.finished.isEmpty && step.partial == "各位同学" && step.partialStartMS == 0)
        step = tracker.update([u("各位同学，今天继续。", true, 0, 6892)], final: false)
        precondition(step.finished.map(\.text) == ["各位同学，今天继续。"] && step.partial.isEmpty)
        step = tracker.update([u("各位同学，今天继续。", true, 0, 6892), u("上一节", false, 7312, 8800)], final: false)
        precondition(step.finished.isEmpty && step.partial == "上一节" && step.partialStartMS == 7312, "Resent sentence is not repeated")
        step = tracker.update([u("各位同学，今天继续。", true, 0, 6892), u("上一节课讲到损失函数。", true, 7312, 22011), u("很多", false, 22011, 22602)], final: false)
        precondition(step.finished.map(\.text) == ["上一节课讲到损失函数。"] && step.partial == "很多")
        step = tracker.update([u("很多同学课后问我", false, 22011, 24000)], final: true)
        precondition(step.finished.map(\.text) == ["很多同学课后问我"] && step.partial.isEmpty, "The last result settles what is open")
        precondition(tracker.update([u("很多同学课后问我", true, 22011, 24922)], final: true).finished.isEmpty, "…and only once")
        var blank = VolcUtteranceTracker()
        precondition(blank.update([u("  ", true, 0, 500)], final: false).finished.isEmpty, "Blank sentences make no line")
        var untimed = VolcUtteranceTracker()
        precondition(untimed.update([u("好的。", true, 0, 0)], final: false).finished.count == 1
                     && untimed.update([u("好的。", true, 0, 0)], final: false).finished.isEmpty, "Without timestamps, text identifies the sentence")

        // Unsettled audio is kept for a resend, in the service's packet size, on the capture clock.
        var backlog = VolcBacklog(start: start)
        backlog.append(Data(count: 32000 * 3 + 100))                    // 3 s and a bit
        var packets = 0
        while backlog.nextPacket(flush: false) != nil { packets += 1 }
        precondition(packets == 15 && backlog.unsent == 100, "200 ms packets; a short tail waits")
        precondition(backlog.date(ms: 1500) == start.addingTimeInterval(1.5))
        backlog.settle(throughMS: 2000)
        precondition(backlog.start == start.addingTimeInterval(2) && backlog.pcm.count == 32100 && backlog.unsent == 100)
        precondition(backlog.date(ms: 2500) == start.addingTimeInterval(2.5), "Timestamps still count from the connection's first audio")
        backlog.settle(throughMS: 60_000)
        precondition(backlog.pcm.count == 100 && backlog.unsent == 100, "Never drops audio that was not sent")
        backlog.append(Data(count: 6400))
        backlog.restart()                                                // connection replaced
        precondition(backlog.unsent == 6500 && backlog.date(ms: 100) == start.addingTimeInterval(3.1), "Resend starts at the first retained sample")
        precondition(backlog.nextPacket(flush: true)?.count == 6400 && backlog.nextPacket(flush: true)?.count == 100 && backlog.nextPacket(flush: true) == nil)
        var music = VolcBacklog(start: start)
        music.append(Data(count: 32000 * 100))
        while music.nextPacket(flush: false) != nil {}
        music.trimSent(keeping: 45)
        precondition(music.pcm.count == 32000 * 45 && music.start == start.addingTimeInterval(55) && music.date(ms: 60_000) == start.addingTimeInterval(60),
                     "Audio with no sentence coming back does not pile up")

        // Silence is not streamed: a connection opens on speech, not on a click or a hum.
        var gate = SpeechGate()
        precondition(gate.process([Float](repeating: 0, count: 16000)) == (false, false))
        precondition(gate.process(tone(160, 0.3)).onset == false, "10 ms is not speech")
        var hum = SpeechGate()
        let rumble = (0..<16000).map { 0.2 * sin(2 * Float.pi * 60 * Float($0) / 16000) }
        _ = hum.process(rumble)
        precondition(hum.process(rumble).onset == false, "Low-frequency room noise does not open a connection")
        var speaking = SpeechGate()
        _ = speaking.process([Float](repeating: 0.0005, count: 16000))
        let heard = speaking.process(tone(3200))
        precondition(heard.any && heard.onset, "200 ms of voice does")
        _ = speaking.process([Float](repeating: 0.0005, count: 1600))        // the filter rings briefly after speech
        precondition(speaking.process([Float](repeating: 0.0005, count: 8000)) == (false, false), "Quiet again once speech stops")

        // Settings saved before the engine existed take the new default; a saved choice survives.
        precondition(prefs.engine == .volc && prefs.volcResourceID == "volc.seedasr.sauc.duration")
        var localPrefs = Preferences(); localPrefs.engine = .local; localPrefs.volcResourceID = "volc.seedasr.sauc.concurrent"
        let localRound = try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(localPrefs))
        precondition(localRound.engine == .local && localRound.volcResourceID == "volc.seedasr.sauc.concurrent")
        var listed = Preferences(); listed.hotwords = "小林，梯度下降,损失函数\n听流"
        precondition(listed.hotwordList == ["小林", "梯度下降", "损失函数", "听流"])

        // --- Refinement from the recording (cloud engine) ---
        let recT0 = Date(timeIntervalSince1970: 1_800_000_000)
        // The index: one line per stretch of speech; garbage and backwards offsets are skipped.
        let recIndex = "0 \(recT0.timeIntervalSince1970)\n16000 \(recT0.timeIntervalSince1970 + 10)\nnonsense\n8000 5\n48000 \(recT0.timeIntervalSince1970 + 30)\n"
        let recSpans = VolcRecording.spans(index: recIndex, totalSamples: 80000)
        precondition(recSpans == [AudioSpan(offset: 0, count: 16000, start: recT0),
                                  AudioSpan(offset: 16000, count: 32000, start: recT0.addingTimeInterval(10)),
                                  AudioSpan(offset: 48000, count: 32000, start: recT0.addingTimeInterval(30))], "Spans run to the next mark or the end")
        precondition(VolcRecording.spans(index: "", totalSamples: 100).isEmpty && VolcRecording.spans(index: "0 1\n", totalSamples: 0).isEmpty)

        // Uploads: whole stretches while they fit, nothing lost, nothing sent twice.
        let recPlan = VolcRecording.plan(recSpans, limit: 50000, search: 8000) { _ in preconditionFailure("No stretch needs cutting") }
        precondition(recPlan.map { $0.map(\.offset) } == [[0, 16000], [48000]], "A stretch that does not fit starts the next upload")
        // One long lecture without a pause: cut where the callback says, inside the search range.
        var recAsked: [Range<Int>] = []
        let recLong = [AudioSpan(offset: 1000, count: 250_000, start: recT0)]
        let recCut = VolcRecording.plan(recLong, limit: 100_000, search: 20_000) { range in recAsked.append(range); return range.lowerBound + 5000 }
        precondition(recAsked == [81_000..<101_000, 166_000..<186_000], "Search the end of each upload")
        precondition(recCut.count == 3 && recCut.allSatisfy { $0.count == 1 && $0[0].count <= 100_000 })
        precondition(recCut.map { $0[0].offset } == [1000, 86_000, 171_000] && recCut.map { $0[0].count }.reduce(0, +) == 250_000, "Contiguous and complete")
        precondition(abs(recCut[1][0].start.timeIntervalSince(recT0) - 85000.0 / 16000) < 0.001, "A cut stretch keeps its clock")
        let recWild = VolcRecording.plan(recLong, limit: 100_000, search: 20_000) { _ in 0 }
        precondition(recWild.allSatisfy { $0[0].count > 0 && $0[0].count <= 100_000 } && recWild.map { $0[0].count }.reduce(0, +) == 250_000, "A bad cut point is clamped")

        // The quietest moment: noise, 0.4 s of near silence, noise.
        var recNoise = (0..<48000).map { i in Int16(((i * 7919) % 2000) - 1000) }
        for i in 30000..<36400 { recNoise[i] = Int16(i % 3) }
        let recQuiet = VolcRecording.quietest(in: recNoise.withUnsafeBytes { Data($0) })
        precondition((30000..<36400).contains(recQuiet), "Cut in the pause, got \(recQuiet)")
        precondition(VolcRecording.quietest(in: Data(count: 100)) == 25, "Too short to search: the middle")

        // Time in the upload → capture clock, with 0.5 s put between separate stretches only.
        let recPair = [recSpans[0], recSpans[1]]                     // 1 s at T0, then 2 s at T0+10
        precondition(VolcRecording.starts(recPair) == [0, 1500])
        precondition(VolcRecording.date(ms: 400, in: recPair) == recT0.addingTimeInterval(0.4))
        precondition(VolcRecording.date(ms: 1200, in: recPair) == recT0.addingTimeInterval(1), "Inside the seam: end of the stretch before")
        precondition(VolcRecording.date(ms: 2500, in: recPair) == recT0.addingTimeInterval(11))
        precondition(VolcRecording.date(ms: 99_000, in: recPair) == recT0.addingTimeInterval(12), "Never past the audio")
        precondition(VolcRecording.starts([recCut[0][0], recCut[1][0]]) == [0, 85000 / 16], "Halves of one stretch join without a gap")

        let recWav = VolcRecording.wav([Data(repeating: 1, count: 32000), Data(repeating: 2, count: 64000)], spans: recPair)
        precondition(recWav.count == 44 + 32000 + 16000 + 64000 && String(decoding: recWav[0..<4], as: UTF8.self) == "RIFF"
                     && String(decoding: recWav[8..<16], as: UTF8.self) == "WAVEfmt ")
        precondition(recWav[24..<28].elementsEqual([0x80, 0x3e, 0, 0]) && recWav[22] == 1 && recWav[34] == 16, "16 kHz mono 16-bit")
        precondition(recWav[40..<44].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) } == 112000 && recWav[44] == 1
                     && recWav[44 + 32000] == 0 && recWav[44 + 48000] == 2, "Data length, and silence in the seam")

        let recBody = try JSONSerialization.jsonObject(with: VolcRecording.submitBody(wav: recWav, uid: "u", hotwords: ["听流", " "], splitOnPauses: false)) as! [String: Any]
        let recAudio = recBody["audio"] as! [String: Any], recRequest = recBody["request"] as! [String: Any]
        precondition(recAudio["format"] as? String == "wav" && Data(base64Encoded: recAudio["data"] as! String) == recWav)
        precondition(recRequest["model_name"] as? String == "bigmodel" && recRequest["show_utterances"] as? Bool == true
                     && recRequest["enable_punc"] as? Bool == true && recRequest["vad_segment"] == nil)
        precondition(((recRequest["corpus"] as? [String: Any])?["context"] as? String)?.contains("听流") == true)
        let recSplit = (try JSONSerialization.jsonObject(with: VolcRecording.submitBody(wav: Data(), uid: "u", hotwords: [], splitOnPauses: true)) as! [String: Any])["request"] as! [String: Any]
        precondition(recSplit["vad_segment"] as? Bool == true && recSplit["end_window_size"] as? Int == 300 && recSplit["corpus"] == nil)

        // The answer: same shape as a streaming result, without `definite`.
        let recAnswer = Data(#"{"audio_info":{"duration":3000},"result":{"text":"第一句。第二句。","utterances":[{"start_time":100,"end_time":900,"text":"第一句。"},{"start_time":1600,"end_time":3400,"text":"第二句。"},{"start_time":3400,"end_time":3450,"text":"  "}]}}"#.utf8)
        let recLines = VolcRecording.lines(VolcFrame.utterances(in: recAnswer)!.utterances, spans: recPair, source: "腾讯会议")
        precondition(recLines.map(\.text) == ["第一句。", "第二句。"] && recLines.allSatisfy { $0.refined == true && $0.source == "腾讯会议" })
        precondition(recLines[0].start == recT0.addingTimeInterval(0.1) && recLines[1].start == recT0.addingTimeInterval(10.1)
                     && recLines[1].end == recT0.addingTimeInterval(11.9))

        // Replacing: only this source's lines inside the stretch of time the upload covers.
        func recLine(_ at: Double, _ source: String, _ text: String) -> TranscriptLine {
            TranscriptLine(start: recT0.addingTimeInterval(at), end: recT0.addingTimeInterval(at + 1), source: source, text: text, latency: 0)
        }
        var recSession = [recLine(0, "腾讯会议", "第一局"), recLine(10.5, "腾讯会议", "第二句"), recLine(10.6, "麦克风", "我说的"), recLine(31, "腾讯会议", "后面的")]
        let recOld = VolcRecording.covered(recSession, source: "腾讯会议", spans: recPair)
        precondition(recOld.map(\.text) == ["第一局", "第二句"])
        VolcRecording.replace(recOld, with: recLines, in: &recSession)
        precondition(recSession.map(\.text) == ["第一句。", "第二句。", "我说的", "后面的"], "Other sources and other times untouched")
        precondition(VolcRecording.acceptable(original: "今天讲梯度下降", refined: "今天讲，梯度下降。") && VolcRecording.acceptable(original: "嗯", refined: "嗯，我们开始上课")
                     && VolcRecording.acceptable(original: "", refined: "漏掉的一句"))
        precondition(!VolcRecording.acceptable(original: "今天讲梯度下降和损失函数", refined: "今天") && !VolcRecording.acceptable(original: "今天讲", refined: "")
                     && !VolcRecording.acceptable(original: "", refined: "。"), "Never trade words for nothing")

        precondition(VolcFrame.errorMessage(Data(#"{"header":{"reqid":"x","code":45000030,"message":"requested resource not granted"}}"#.utf8)) == "requested resource not granted",
                     "The reason, not the envelope")

        // Splitting on pauses can lose a very short line; one the new result does not cover stays.
        let recLive = [recLine(0, "麦克风", "关于新版本的设计"), recLine(5.2, "麦克风", "第一"), recLine(6.3, "麦克风", "很多人没有注意到")]
        let recFresh = [recLine(0.1, "麦克风", "关于新版本的设计。"), recLine(6.4, "麦克风", "很多人没有注意到。")]
        precondition(VolcRecording.uncovered(recLive, by: recFresh).map(\.text) == ["第一"])
        precondition(VolcRecording.uncovered(recLive, by: []).count == 3 && VolcRecording.uncovered([], by: recFresh).isEmpty)

        // Kept speech on disk: stretches with their clocks, private, and removable on its own.
        let recTmp = FileManager.default.temporaryDirectory.appendingPathComponent("lf-stream-\(UUID().uuidString)")
        AudioStore.rootOverride = recTmp
        let recSID = UUID()
        _ = AudioStore.append([Float](repeating: 0.1, count: 400), session: recSID, source: "腾讯会议")     // a local-engine chunk
        AudioStore.appendStream(Data(repeating: 3, count: 2000), session: recSID, source: "腾讯会议", spanStart: recT0)
        AudioStore.appendStream(Data(repeating: 4, count: 1000), session: recSID, source: "腾讯会议", spanStart: nil)
        AudioStore.appendStream(Data(repeating: 5, count: 600), session: recSID, source: "腾讯会议", spanStart: recT0.addingTimeInterval(60))
        AudioStore.appendStream(Data(repeating: 6, count: 800), session: recSID, source: "麦克风", spanStart: recT0.addingTimeInterval(5))
        let recKept = AudioStore.streamSpans(recSID)
        precondition(Set(recKept.keys) == ["腾讯会议", "麦克风"], "Source names survive the file name")
        precondition(recKept["腾讯会议"]!.map(\.offset) == [0, 1500] && recKept["腾讯会议"]!.map(\.count) == [1500, 300]
                     && abs(recKept["腾讯会议"]![1].start.timeIntervalSince(recT0) - 60) < 0.001)
        precondition(AudioStore.readStream(session: recSID, source: "腾讯会议", offset: 1000, count: 800) == Data(repeating: 4, count: 1000) + Data(repeating: 5, count: 600))
        precondition(AudioStore.readStream(session: recSID, source: "腾讯会议", offset: 1700, count: 200) == nil, "Never a short read")
        precondition(abs(AudioStore.streamSeconds(recSID) - 2200.0 / 16000) < 1e-9)
        let recPerms = try FileManager.default.attributesOfItem(atPath: AudioStore.streamFile(session: recSID, source: "麦克风").path)[.posixPermissions] as! Int
        precondition(recPerms == 0o600, "Kept speech must be private")
        AudioStore.deleteStream(recSID)
        precondition(AudioStore.streamSpans(recSID).isEmpty && AudioStore.streamSeconds(recSID) == 0)
        precondition(AudioStore.read(session: recSID, source: "腾讯会议", offset: 0, count: 400) != nil, "The local engine's audio is not this refinement's to delete")
        AudioStore.appendStream(Data(repeating: 7, count: 200), session: recSID, source: "麦克风", spanStart: recT0)
        precondition(AudioStore.streamSpans(recSID)["麦克风"]!.map(\.offset) == [0], "A new recording starts a new file")
        AudioStore.deleteChunks(recSID)
        precondition(AudioStore.read(session: recSID, source: "腾讯会议", offset: 0, count: 1) == nil && AudioStore.streamSeconds(recSID) > 0)
        AudioStore.deleteStream(recSID)
        precondition(!AudioStore.hasAudio(recSID), "An empty folder is removed")
        try? FileManager.default.removeItem(at: recTmp)
        AudioStore.rootOverride = nil

        // --- Keys in ~/.listenflow/keys.json ---
        let keyHome = FileManager.default.temporaryDirectory.appendingPathComponent("lf-home-\(UUID().uuidString)")
        ListenFlowHome.rootOverride = keyHome
        precondition(SecretStore.read(account: "https://api.example.com") == "" && !FileManager.default.fileExists(atPath: keyHome.path), "Reading creates nothing")
        try SecretStore.save("first-key", account: "https://api.example.com")
        try SecretStore.save("second-key", account: SecretStore.volcAccount)
        precondition(SecretStore.read(account: "https://api.example.com") == "first-key" && SecretStore.read(account: SecretStore.volcAccount) == "second-key")
        let keyMode = try FileManager.default.attributesOfItem(atPath: SecretStore.file.path)[.posixPermissions] as! Int
        let homeMode = try FileManager.default.attributesOfItem(atPath: keyHome.path)[.posixPermissions] as! Int
        precondition(keyMode == 0o600 && homeMode == 0o700, "Only the owner may read keys")
        let keyFiles = try FileManager.default.contentsOfDirectory(atPath: keyHome.path)
        precondition(keyFiles == ["keys.json"], "No draft left behind")
        try SecretStore.save("", account: "https://api.example.com")
        precondition(SecretStore.read(account: "https://api.example.com") == "" && SecretStore.read(account: SecretStore.volcAccount) == "second-key", "Clearing one key leaves the others")
        // A file made by hand: readable by others, then not; broken, then left alone.
        try Data(#"{"volcengine-asr": "typed-by-hand"}"#.utf8).write(to: SecretStore.file)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: SecretStore.file.path)
        precondition(SecretStore.read(account: SecretStore.volcAccount) == "typed-by-hand")
        let keyTightened = try FileManager.default.attributesOfItem(atPath: SecretStore.file.path)[.posixPermissions] as! Int
        precondition(keyTightened == 0o600, "Tightened on first read")
        try Data("{ not json".utf8).write(to: SecretStore.file)
        precondition(SecretStore.read(account: SecretStore.volcAccount) == "")
        var keyRefused = false
        do { try SecretStore.save("x", account: "a") } catch { keyRefused = true }
        let keyBroken = try Data(contentsOf: SecretStore.file)
        precondition(keyRefused && keyBroken == Data("{ not json".utf8), "A file that cannot be read is never overwritten")
        try? FileManager.default.removeItem(at: keyHome)
        ListenFlowHome.rootOverride = nil
        precondition(Preferences().volcFileResourceID == "volc.seedasr.auc")

        // --- One upload's result applied to a transcript (shared by the window and background refinement) ---
        var applyLines = [recLine(0, "腾讯会议", "第一局"), recLine(10.5, "腾讯会议", "第二句"), recLine(10.6, "麦克风", "我说的"), recLine(31, "腾讯会议", "后面的")]
        precondition(VolcRecording.unfinished(applyLines, source: "腾讯会议", spans: recPair))
        let applyUtterances = VolcFrame.utterances(in: recAnswer)!.utterances
        precondition(VolcRecording.apply(applyUtterances, spans: recPair, source: "腾讯会议", split: false, to: &applyLines), "Changed text is reported")
        precondition(applyLines.map(\.text) == ["第一句。", "第二句。", "我说的", "后面的"])
        precondition(!VolcRecording.unfinished(applyLines, source: "腾讯会议", spans: recPair), "A finished upload is not sent twice")
        precondition(!VolcRecording.apply(applyUtterances, spans: recPair, source: "腾讯会议", split: false, to: &applyLines) && applyLines.count == 4, "Same text again changes nothing")
        var applyKept = [recLine(0, "腾讯会议", "今天讲梯度下降和损失函数的关系"), recLine(10.5, "腾讯会议", "学习率怎么选")]
        precondition(!VolcRecording.apply([VolcUtterance(text: "今天", definite: false, startMS: 0, endMS: 500)], spans: recPair, source: "腾讯会议", split: false, to: &applyKept)
                     && applyKept.count == 2 && applyKept[0].refined == nil, "A result that lost the words is refused")
        precondition(VolcRecording.unfinished([], source: "腾讯会议", spans: recPair), "Audio without lines is still worth sending")

        // --- Refined sentences shown as paragraphs ---
        func sentence(_ at: Double, _ length: Double, _ source: String, _ text: String, refined: Bool? = true, audio: AudioRef? = nil) -> TranscriptLine {
            TranscriptLine(start: recT0.addingTimeInterval(at), end: recT0.addingTimeInterval(at + length), source: source, text: text, latency: 0, audio: audio, refined: refined)
        }
        let paraIn = [sentence(0, 5, "电脑声音", "今天讲梯度下降。"), sentence(5.3, 11, "电脑声音", "上一节课讲到损失函数。"), sentence(16.6, 4, "电脑声音", "学习率怎么选？"),
                      sentence(21, 2, "麦克风", "老师，"), sentence(23.2, 3, "麦克风", "这个会考吗？"),             // a reply from another source breaks the paragraph
                      sentence(27, 6, "电脑声音", "会考。"), sentence(36, 4, "电脑声音", "下面看动量法。"),            // 3 s pause: a new paragraph
                      sentence(40.2, 12, "电脑声音", "它把之前几步的方向累积起来，"), sentence(52.4, 10, "电脑声音", "像滚下山坡的小球。"),
                      sentence(62.6, 9, "电脑声音", "遇到平地也能继续向前。")]                                          // would pass 30 s: starts the next
        let paraOut = VolcRecording.paragraphs(paraIn.shuffled())
        precondition(paraOut.map(\.text) == ["今天讲梯度下降。上一节课讲到损失函数。学习率怎么选？", "老师，这个会考吗？", "会考。",
                                             "下面看动量法。它把之前几步的方向累积起来，像滚下山坡的小球。", "遇到平地也能继续向前。"], "\(paraOut.map(\.text))")
        precondition(paraOut[0].id == paraIn[0].id && paraOut[0].start == paraIn[0].start && paraOut[0].end == paraIn[2].end && paraOut.allSatisfy { $0.refined == true })
        precondition(paraOut[3].end.timeIntervalSince(paraOut[3].start) <= VolcRecording.paragraphSeconds)
        precondition(VolcRecording.paragraphs(paraOut).map(\.text) == paraOut.map(\.text), "Doing it twice changes nothing")
        // Live lines, and the local engine's lines (which point into its audio file), are left alone.
        let paraMixed = [sentence(0, 4, "麦克风", "第一句", refined: nil), sentence(4.2, 4, "麦克风", "第二句"), sentence(8.4, 4, "麦克风", "第三句", audio: AudioRef(offset: 0, count: 9)),
                         sentence(12.6, 3, "麦克风", "open the"), sentence(15.8, 2, "麦克风", "settings 页面"), sentence(18, 2, "麦克风", "3 次")]
        precondition(VolcRecording.paragraphs(paraMixed).map(\.text) == ["第一句", "第二句", "第三句", "open the settings 页面3 次"], "A space between Latin words only")
        precondition(VolcRecording.paragraphs([]).isEmpty)

        // The microphone is cut on pauses only where the app was audible at the same time.
        let micSpans = [AudioSpan(offset: 0, count: 160_000, start: recT0), AudioSpan(offset: 160_000, count: 320_000, start: recT0.addingTimeInterval(60))]   // 0–10 s, 60–80 s
        precondition(VolcRecording.overlap(micSpans, with: []) == 0)
        precondition(VolcRecording.overlap(micSpans, with: [AudioSpan(offset: 0, count: 64_000, start: recT0.addingTimeInterval(20))]) == 0, "A sound while the microphone was quiet")
        precondition(abs(VolcRecording.overlap(micSpans, with: [AudioSpan(offset: 0, count: 64_000, start: recT0.addingTimeInterval(8))]) - 2) < 0.001
                     && VolcRecording.overlap(micSpans, with: [AudioSpan(offset: 0, count: 64_000, start: recT0.addingTimeInterval(8))]) < VolcRecording.echoOverlap, "A notification is not a conversation")
        precondition(abs(VolcRecording.overlap(micSpans, with: [AudioSpan(offset: 0, count: 1_600_000, start: recT0.addingTimeInterval(5))]) - 25) < 0.001)

        // Live lines that splitting on pauses lost are kept, and count as done.
        var keptLines = [recLine(0, "麦克风", "关于新版本的设计"), recLine(5.2, "麦克风", "第一"), recLine(6.3, "麦克风", "很多人没有注意到")]
        let keptSpans = [AudioSpan(offset: 0, count: 160_000, start: recT0)]
        precondition(VolcRecording.apply([VolcUtterance(text: "关于新版本的设计。", definite: false, startMS: 100, endMS: 1000),
                                          VolcUtterance(text: "很多人没有注意到。", definite: false, startMS: 6400, endMS: 7300)],
                                         spans: keptSpans, source: "麦克风", split: true, to: &keptLines))
        precondition(keptLines.map(\.text) == ["关于新版本的设计。", "第一", "很多人没有注意到。"] && keptLines.allSatisfy { $0.refined == true }
                     && !VolcRecording.unfinished(keptLines, source: "麦克风", spans: keptSpans))

        // --- lstf: arguments ---
        func cliFails(_ arguments: [String], usage: Bool = true) -> Bool {
            do { _ = try Lstf.parse(arguments); return false } catch let error as LstfError { return error.usage == usage } catch { return false }
        }
        func cli(_ arguments: [String]) -> Lstf.Command? { try? Lstf.parse(arguments) }
        precondition(cli([]) == .help && cli(["--help"]) == .help && cli(["read", "-h"]) == .help && cli(["help"]) == .help)
        precondition(cli(["status"]) == .status(json: false) && cli(["status", "--json"]) == .status(json: true))
        precondition(cli(["list"]) == .list(limit: 20, json: false) && cli(["list", "--limit", "5", "--json"]) == .list(limit: 5, json: true))
        precondition(cli(["read"]) == .read(Lstf.Read()))
        precondition(cli(["read", "3F2A", "--offset", "41", "--limit", "20"]) == .read(Lstf.Read(session: "3F2A", offset: 41, limit: 20)))
        precondition(cli(["read", "--tail", "30", "latest", "--json"]) == .read(Lstf.Read(session: "latest", tail: 30, json: true)), "Options before the session")
        precondition(cli(["read", "--minutes", "2.5"]) == .read(Lstf.Read(minutes: 2.5)) && cli(["read", "--organized"]) == .read(Lstf.Read(organized: true)))
        precondition(cli(["search", "预算", "--session", "latest"]) == .search(text: "预算", session: "latest", limit: 50, json: false))
        precondition(cli(["refine"]) == .refine(session: nil, wait: false) && cli(["refine", "3F2A91BC", "--wait"]) == .refine(session: "3F2A91BC", wait: true))
        for bad in [["read", "--offset", "3", "--tail", "5"], ["read", "--offset", "0"], ["read", "--limit", "many"], ["read", "--limit"], ["read", "a1b2", "extra"],
                    ["read", "--organized", "--limit", "5"], ["read", "--minutes", "0"], ["read", "--wait"], ["refine", "--json"], ["search"],
                    ["list", "--tail", "3"], ["record"], ["stop"], ["read", "--force"]] {
            precondition(cliFails(bad), "Should be refused as a usage error: \(bad)")
        }

        // --- lstf: which session ---
        func cliSession(_ id: String, _ title: String, lines: Int, at offset: Double = 0) -> MeetingSession {
            var session = MeetingSession(id: UUID(uuidString: id)!, title: title, created: recT0.addingTimeInterval(offset))
            session.lines = (0..<lines).map { i in
                TranscriptLine(start: session.created.addingTimeInterval(Double(i) * 10), end: session.created.addingTimeInterval(Double(i) * 10 + 8),
                               source: i % 3 == 2 ? "麦克风" : "电脑声音", text: "第\(i + 1)句话", latency: 0)
            }
            return session
        }
        let cliNew = cliSession("3F2A91BC-0000-4000-8000-000000000001", "周会", lines: 5, at: 3600)
        let cliOld = cliSession("3F2A77AA-0000-4000-8000-000000000002", "网课", lines: 450)
        let cliOther = cliSession("B0C1D2E3-0000-4000-8000-000000000003", "访谈", lines: 0, at: -3600)
        let cliAll = [cliNew, cliOld, cliOther]
        func cliPick(_ selector: String?, open: UUID? = nil, running: Bool = true) -> (id: UUID, note: Bool)? {
            (try? Lstf.resolve(selector, sessions: cliAll, open: open, running: running)).map { ($0.session.id, $0.note != nil) }
        }
        precondition(cliPick(nil, open: cliOld.id)! == (cliOld.id, false), "The open session, not the newest")
        precondition(cliPick("current", open: UUID())! == (cliNew.id, true) && cliPick(nil, running: false)! == (cliNew.id, true), "A fallback says it is one")
        precondition(cliPick("latest", open: cliOld.id)! == (cliNew.id, false))
        precondition(cliPick("3f2a9")! == (cliNew.id, false) && cliPick("3F2A77AA-0000")! == (cliOld.id, false) && cliPick("b0c1")! == (cliOther.id, false))
        precondition(cliPick("3F2A") == nil && cliPick("ffff") == nil && cliPick("b0c") == nil, "Ambiguous, unknown and too short are errors")
        precondition((try? Lstf.resolve(nil, sessions: [], open: nil, running: true)) == nil)

        // --- lstf: paging like a file ---
        precondition(Lstf.window(total: 450, offset: nil, limit: nil, tail: nil) == 0..<200 && Lstf.window(total: 450, offset: 201, limit: nil, tail: nil) == 200..<400)
        precondition(Lstf.window(total: 450, offset: 401, limit: 100, tail: nil) == 400..<450 && Lstf.window(total: 450, offset: 41, limit: 20, tail: nil) == 40..<60)
        precondition(Lstf.window(total: 450, offset: 451, limit: nil, tail: nil) == 450..<450 && Lstf.window(total: 450, offset: 9000, limit: 5, tail: nil).isEmpty, "Past the end is empty, not an error")
        precondition(Lstf.window(total: 450, offset: nil, limit: nil, tail: 30) == 420..<450 && Lstf.window(total: 5, offset: nil, limit: nil, tail: 30) == 0..<5
                     && Lstf.window(total: 0, offset: nil, limit: nil, tail: 3).isEmpty && Lstf.window(total: 0, offset: nil, limit: nil, tail: nil).isEmpty)
        // Lines end at 8, 18, 28, 38, 48 s; the last two ended within 25 s of second 60.
        precondition(Lstf.firstLine(within: 25.0 / 60, of: cliNew.created.addingTimeInterval(60), in: cliNew.lines) == 4)
        precondition(Lstf.firstLine(within: 60, of: cliNew.created.addingTimeInterval(60), in: cliNew.lines) == 1
                     && Lstf.firstLine(within: 1, of: cliNew.created.addingTimeInterval(3600), in: cliNew.lines) == 6, "Nothing recent: one past the end")

        // --- lstf: what is printed ---
        precondition(Lstf.clock(0) == "00:00" && Lstf.clock(195.9) == "03:15" && Lstf.clock(3725) == "1:02:05" && Lstf.clock(-4) == "00:00")
        precondition(Lstf.shortID(cliNew.id) == "3F2A91BC")
        var cliMultiline = cliNew.lines[2]
        cliMultiline = TranscriptLine(start: cliMultiline.start, end: cliMultiline.end, source: "麦克风", text: "一行\n两行", latency: 0)
        precondition(Lstf.row(cliMultiline, number: 7, created: cliNew.created, width: 3) == "  7  [00:20] [麦克风] 一行 两行", "One sentence, one line")
        let cliRecording = Lstf.Info(session: cliNew, keptSeconds: 40, open: true, recording: true)
        let cliPage = Lstf.page(cliRecording, range: 0..<5, note: nil)
        precondition(cliPage.contains("会话 3F2A91BC「周会」") && cliPage.contains("共 5 行") && cliPage.contains("正在录制") && cliPage.contains("暂停后可精修"))
        precondition(cliPage.contains("1  [00:00] [电脑声音] 第1句话\n") && cliPage.contains("3  [00:20] [麦克风] 第3句话\n"))
        precondition(cliPage.hasSuffix("— 第 1–5 行，共 5 行。\n— 仍在录制，之后的新内容：lstf read 3F2A91BC --offset 6\n"), "Says where to carry on")
        let cliLong = Lstf.page(Lstf.Info(session: cliOld), range: 200..<400, note: "听流没有在运行，这里是最近的一场。")
        precondition(cliLong.hasPrefix("听流没有在运行，这里是最近的一场。\n会话 3F2A77AA") && cliLong.contains("201  [33:20]") && !cliLong.contains("\n200  ")
                     && cliLong.hasSuffix("— 第 201–400 行，共 450 行。\n— 还有 50 行：lstf read 3F2A77AA --offset 401\n"))
        precondition(Lstf.page(Lstf.Info(session: cliOld), range: 450..<450, note: nil).contains("第 451 行起没有内容；目前共 450 行")
                     && Lstf.page(Lstf.Info(session: cliOther), range: 0..<0, note: nil).contains("还没有转写内容"))
        precondition(Lstf.refinement(Lstf.Info(session: cliOld)) == .none && Lstf.refinement(Lstf.Info(session: cliOld, keptSeconds: 700)) == .possible
                     && Lstf.refinement(Lstf.Info(session: cliOld, localAudio: true)) == .windowOnly)
        precondition(Lstf.describe(Lstf.Info(session: cliOld, keptSeconds: 700)) == "可精修（暂存录音约 12 分钟）")
        var cliDone = cliNew
        cliDone.refinedAt = recT0
        precondition(Lstf.refinement(Lstf.Info(session: cliDone)) == .done
                     && Lstf.refinement(Lstf.Info(session: cliDone, keptSeconds: 9, refining: .init(sessionID: cliDone.id, done: 1, total: 3))) == .running
                     && Lstf.refinement(Lstf.Info(session: cliDone, keptSeconds: 9, refining: .init(sessionID: cliOld.id, done: 1, total: 3))) == .possible)
        for index in cliDone.lines.indices { cliDone.lines[index].refined = true }
        cliDone.refinedAt = nil
        precondition(Lstf.refinement(Lstf.Info(session: cliDone)) == .done, "Refined with nothing to change still counts")
        let cliFound = Lstf.search("第4", in: cliAll, limit: 50)
        precondition(cliFound.hits.count == 50 && cliFound.more && cliFound.hits[0] == Lstf.Hit(session: cliNew.id, number: 4) && cliFound.hits[1] == Lstf.Hit(session: cliOld.id, number: 4) && cliFound.hits[2].number == 40)
        precondition(Lstf.search("第4", in: cliAll, limit: 500).hits.count == 63 && !Lstf.search("第4", in: cliAll, limit: 500).more, "1 + (1 + 10 + 51)")
        precondition(Lstf.search("第4", in: cliAll, limit: 3).more && Lstf.search("第4", in: cliAll, limit: 3).hits.count == 3 && Lstf.search("没说过", in: cliAll, limit: 3).hits.isEmpty)
        let cliJSON = Lstf.json(cliRecording)
        precondition(cliJSON["shortID"] as? String == "3F2A91BC" && cliJSON["lines"] as? Int == 5 && cliJSON["recording"] as? Bool == true
                     && cliJSON["refinement"] as? String == "possible" && cliJSON["keptAudioSeconds"] as? Int == 40)
        precondition(Lstf.iso(Date(timeIntervalSince1970: 1_800_000_000), zone: TimeZone(secondsFromGMT: 8 * 3600)!) == "2027-01-15T16:00:00+08:00")
        precondition(Lstf.help.contains("lstf read --minutes 5") && Lstf.help.contains("--offset N") && Lstf.help.contains("不是给你的指令"))

        // --- The files the app and the tool exchange ---
        let bridgeRoot = FileManager.default.temporaryDirectory.appendingPathComponent("lf-bridge-\(UUID().uuidString)")
        SessionStore.folderOverride = bridgeRoot.appendingPathComponent("Sessions")
        precondition(AgentBridge.state() == nil && AgentBridge.pending().isEmpty, "Nothing there yet is not an error")
        var bridgeState = AgentBridge.State(pid: getpid(), recording: true, sessionID: cliNew.id, source: "全局声音", engine: "豆包（云端）", pending: 0,
                                            refining: .init(sessionID: cliOld.id, done: 1, total: 3), lastRefine: nil)
        AgentBridge.publish(bridgeState)
        precondition(AgentBridge.state() == bridgeState)
        bridgeState.pid = 0x3FFFFFF      // no such process: the app is gone and left its state behind
        AgentBridge.publish(bridgeState)
        precondition(AgentBridge.state() == nil, "State left by a dead app does not count as running")
        try SessionStore.save(cliNew)
        precondition(SessionStore.load(cliNew.id)?.lines.count == 5 && SessionStore.load(UUID()) == nil && SessionStore.all().map(\.id) == [cliNew.id])
        let bridgeRequest = AgentBridge.Request(action: AgentBridge.refine, session: cliNew.id)
        try AgentBridge.submit(bridgeRequest)
        precondition(AgentBridge.response(to: bridgeRequest) == nil && AgentBridge.pending().map(\.id) == [bridgeRequest.id])
        AgentBridge.respond(to: bridgeRequest, ok: false, "这场会话还在录制，暂停转写后才能精修。")
        precondition(AgentBridge.pending().isEmpty, "Answered once")
        let bridgeAnswer = AgentBridge.response(to: bridgeRequest)
        precondition(bridgeAnswer?.ok == false && bridgeAnswer?.message.contains("还在录制") == true && AgentBridge.response(to: bridgeRequest) == nil)
        let bridgeStale = AgentBridge.Request(action: AgentBridge.refine, session: cliOld.id)
        try AgentBridge.submit(bridgeStale)
        precondition(AgentBridge.pending(now: Date().addingTimeInterval(AgentBridge.requestLifetime + 5)).isEmpty && AgentBridge.pending().isEmpty,
                     "A request made while the app was away is not acted on later")
        AgentBridge.withdraw()
        precondition(!FileManager.default.fileExists(atPath: AgentBridge.stateURL.path))
        try? FileManager.default.removeItem(at: bridgeRoot)
        SessionStore.folderOverride = nil


        // --- 0.11.0: the session list, saving off the main thread, the page layout, screenshots ---
        do {
            let listRoot = FileManager.default.temporaryDirectory.appendingPathComponent("lf-list-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: listRoot) }
            SessionStore.folderOverride = listRoot.appendingPathComponent("Sessions")
            AudioStore.rootOverride = listRoot.appendingPathComponent("audio")
            let listStart = Date(timeIntervalSince1970: 1_790_000_000)
            func said(_ at: Double, _ length: Double, _ source: String, _ text: String, refined: Bool? = nil) -> TranscriptLine {
                TranscriptLine(start: listStart.addingTimeInterval(at), end: listStart.addingTimeInterval(at + length), source: source,
                               text: text, latency: 0.5, refined: refined)
            }
            var listedSession = MeetingSession(title: "全局声音 · 测试", created: listStart)
            listedSession.lines = [said(2, 3, "电脑声音", "第一句。"), said(5.5, 2, "电脑声音", "第二句。"), said(600, 4, "麦克风", "十分钟后的一句。")]
            listedSession.organized = OrganizedTranscript(text: "整理稿", generatedAt: listStart, sourceLineIDs: [listedSession.lines[0].id], through: listStart)
            try SessionStore.save(listedSession)
            var bare = MeetingSession(title: "空的", created: listStart.addingTimeInterval(3600))
            bare.chat = [ChatMessage(role: "user", text: "只有旧问答")]
            try SessionStore.save(bare)
            let summaries = SessionStore.summaries()
            precondition(summaries.map(\.id) == [bare.id, listedSession.id], "Newest first")
            precondition(summaries[1] == SessionSummary(listedSession) && summaries[1].lineCount == 3 && summaries[1].seconds == 604 && summaries[1].hasDraft
                         && summaries[1].imageCount == 0, "Read from disk, a summary says what one made from the session says")
            precondition(summaries[0].lineCount == 0 && summaries[0].seconds == 0 && !summaries[0].hasDraft)
            precondition(SessionStore.markdown(bare).contains("## 问答") && !SessionStore.markdown(listedSession).contains("## 问答"),
                         "Questions asked before 0.11.0 still export; a session without any has no empty section")

            // Saves pile up while the disk is busy; only the newest of each session is written.
            let writer = SessionWriter()
            var growing = MeetingSession(title: "写入", created: listStart)
            for index in 0..<200 {
                growing.lines.append(said(Double(index), 0.5, "电脑声音", "第 \(index) 句"))
                writer.save(growing)
            }
            writer.flush()
            precondition(SessionStore.load(growing.id)?.lines.count == 200, "After flush the newest state is on disk")
            writer.flush()

            // The page: sentences that follow one another read as one paragraph.
            let choppy = [said(0, 2, "电脑声音", "先说结论，"), said(2.3, 2, "电脑声音", "这个方案可行。"), said(4.6, 1, "麦克风", "OK"),
                          said(5.8, 1, "麦克风", "fine,"), said(7, 1, "麦克风", "那就这么定。"), said(20, 2, "麦克风", "另外一件事。"),
                          said(22.2, 3, "麦克风", "精修过的一段。", refined: true), said(25.4, 2, "麦克风", "精修过的另一段。", refined: true)]
            let blocks = TranscriptLayout.blocks(choppy)
            precondition(blocks.map(\.text) == ["先说结论，这个方案可行。", "OK fine,那就这么定。", "另外一件事。", "精修过的一段。", "精修过的另一段。"],
                         "Joined within a source across short pauses; a space only between Latin words; refined lines left alone")
            precondition(blocks.map(\.showsSource) == [true, true, false, false, false] && blocks.map(\.id) == [choppy[0].id, choppy[2].id, choppy[5].id, choppy[6].id, choppy[7].id])
            precondition(blocks[1].start == choppy[2].start && blocks[1].end == choppy[4].end)
            precondition(TranscriptLayout.blocks(choppy, breakBefore: choppy[1].id).count == 6, "A forced break starts a new paragraph")
            let longTalk = (0..<40).map { said(Double($0) * 2, 1.9, "电脑声音", "句\($0)。") }
            precondition(TranscriptLayout.blocks(longTalk).allSatisfy { $0.end.timeIntervalSince($0.start) <= TranscriptLayout.seconds }
                         && TranscriptLayout.blocks(longTalk).count == 2, "Unbroken talk still gets paragraphs")
            precondition(TranscriptLayout.blocks([]).isEmpty)

            // A screenshot is kept under the session, named after when it was taken.
            let shotZone = TimeZone(secondsFromGMT: 8 * 3600)!
            precondition(ImageAttachmentStore.shotFileName(Date(timeIntervalSince1970: 1_800_000_000), zone: shotZone) == "shot-20270115-160000.jpg")
            precondition(ImageAttachmentStore.root.path == listRoot.appendingPathComponent("Images").path, "Pictures live beside the sessions, wherever those are")
            let canvas = CGContext(data: nil, width: 640, height: 400, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                   bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
            canvas.setFillColor(CGColor(red: 0.1, green: 0.5, blue: 0.4, alpha: 1))
            canvas.fill(CGRect(x: 0, y: 0, width: 640, height: 400))
            let screen = canvas.makeImage()!
            var pictured = MeetingSession(title: "带截屏", created: listStart)
            pictured.lines = [said(10, 3, "电脑声音", "看这一页。"), said(13.2, 2, "电脑声音", "左边是问题。"), said(40, 3, "电脑声音", "下一页。"), said(60, 2, "麦克风", "好的。")]
            let early = try ImageAttachmentStore.storeShot(screen, at: listStart.addingTimeInterval(4), sessionID: pictured.id, number: 1)
            let middle = try ImageAttachmentStore.storeShot(screen, at: listStart.addingTimeInterval(12), sessionID: pictured.id, number: 2)
            let twin = try ImageAttachmentStore.storeShot(screen, at: listStart.addingTimeInterval(12), sessionID: pictured.id, number: 3)
            let late = try ImageAttachmentStore.storeShot(screen, at: listStart.addingTimeInterval(90), sessionID: pictured.id, number: 4)
            pictured.images = [late, middle, early, twin]
            let middleURL = ImageAttachmentStore.url(for: middle, sessionID: pictured.id)
            precondition(middle.isShot && middle.width == 640 && middle.file == ImageAttachmentStore.shotFileName(listStart.addingTimeInterval(12))
                         && middleURL.lastPathComponent == middle.file && FileManager.default.fileExists(atPath: middleURL.path))
            precondition(twin.file != middle.file && twin.file?.hasSuffix("-2.jpg") == true, "Two in the same second are both kept")
            let shotMode = try FileManager.default.attributesOfItem(atPath: middleURL.path)[.posixPermissions] as? Int
            precondition(shotMode == 0o600)
            let reread = try JSONDecoder().decode(MeetingSession.self, from: JSONEncoder().encode(pictured))
            precondition(reread.imageLibrary.first { $0.id == middle.id }?.file == middle.file && reread.imageLibrary.allSatisfy(\.isShot))
            let legacyImage = try JSONDecoder().decode(ImageAttachment.self, from: Data("""
            {"id":"3F2A91BC-0000-4000-8000-000000000009","number":1,"name":"a.png","width":10,"height":10,"byteCount":5,"addedAt":0}
            """.utf8))
            precondition(!legacyImage.isShot && ImageAttachmentStore.url(for: legacyImage, sessionID: pictured.id).lastPathComponent == "3F2A91BC-0000-4000-8000-000000000009.jpg",
                         "Pictures stored before 0.11.0 keep their file names")

            // On the page: pictures in time order, and no paragraph runs across one.
            let timeline = TranscriptLayout.timeline(pictured)
            let shape: [String] = timeline.map { entry in
                switch entry {
                case let .block(block): return "说:" + block.text
                case let .image(image): return "图:\(image.number)"
                }
            }
            precondition(shape == ["图:1", "说:看这一页。", "图:2", "图:3", "说:左边是问题。", "说:下一页。", "说:好的。", "图:4"], "\(shape)")
            if case let .block(afterPicture) = timeline[4] { precondition(afterPicture.showsSource, "The source is named again after a picture") }
            precondition(SessionSummary(pictured).imageCount == 4)

            // For an agent: each picture's path, where it happened, without taking a line number.
            let picturedInfo = Lstf.Info(session: pictured)
            let whole = Lstf.page(picturedInfo, range: 0..<4, note: nil).split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            let bodyRows = Array(whole.drop { !$0.contains("[截屏]") && !$0.contains("[电脑声音]") }.prefix(8))
            precondition(bodyRows.map { $0.contains("[截屏]") } == [true, false, true, true, false, false, false, true], "\(bodyRows)")
            precondition(bodyRows[0].hasSuffix(ImageAttachmentStore.url(for: early, sessionID: pictured.id).path) && bodyRows[0].contains("[00:04] [截屏] /")
                         && bodyRows[1].hasPrefix("1  [00:10]") && bodyRows[4].hasPrefix("2  [00:13]"), "Line numbers are the transcript's own")
            precondition(whole[1].contains("截屏 4 张") && Lstf.json(picturedInfo)["images"] as? Int == 4)
            // Paged: each picture turns up once, on the page of the line it comes before.
            let firstPage = Lstf.images(pictured, in: 0..<2), secondPage = Lstf.images(pictured, in: 2..<4)
            precondition(firstPage[0]?.map(\.number) == [1] && firstPage[1]?.map(\.number) == [2, 3] && firstPage[2] == nil)
            precondition(secondPage.keys.sorted() == [4] && secondPage[4]?.map(\.number) == [4])
            precondition(Lstf.images(pictured, in: 4..<4)[4]?.map(\.number) == [4], "Reading on from the end still shows a picture taken since")
            let pictureJSON = Lstf.json(middle, session: pictured, beforeLine: 2)
            precondition(pictureJSON["kind"] as? String == "screenshot" && pictureJSON["at"] as? String == "00:12" && pictureJSON["path"] as? String == middleURL.path
                         && pictureJSON["beforeLine"] as? Int == 2)
            var onlyPictures = MeetingSession(title: "只有图", created: listStart)
            onlyPictures.images = [early]
            precondition(Lstf.page(Lstf.Info(session: onlyPictures), range: 0..<0, note: nil).contains("只有上面的图片"))
            precondition(Lstf.help.contains("[截屏]"))

            // Hot words: one file, shared by the app and the tool; order is priority.
            HotwordStore.fileOverride = listRoot.appendingPathComponent("home/hotwords.txt")
            precondition(HotwordStore.load().isEmpty && HotwordStore.modified() == nil, "No file yet is an empty list")
            precondition(HotwordStore.terms("小林，梯度下降,损失函数\n听流\n\n  梯度下降  ,Adam   优化器") == ["小林", "梯度下降", "损失函数", "听流", "Adam 优化器"])
            let firstAdd = try HotwordStore.add(["梯度下降", "Transformer", "梯度下降"])
            precondition(firstAdd.changed == ["梯度下降", "Transformer"] && firstAdd.unchanged.isEmpty && firstAdd.words == ["梯度下降", "Transformer"])
            let secondAdd = try HotwordStore.add(["transformer", "注意力机制", String(repeating: "长", count: 41)])
            precondition(secondAdd.changed == ["注意力机制"] && secondAdd.unchanged == ["transformer"] && secondAdd.refused.count == 1
                         && secondAdd.words == ["梯度下降", "Transformer", "注意力机制"], "Same word in another case is the same word; over-long is refused")
            precondition(HotwordStore.load() == secondAdd.words && HotwordStore.modified() != nil)
            let hotMode = try FileManager.default.attributesOfItem(atPath: HotwordStore.file.path)[.posixPermissions] as? Int
            let hotText = try String(contentsOf: HotwordStore.file, encoding: .utf8)
            precondition(hotMode == 0o600 && hotText == "梯度下降\nTransformer\n注意力机制\n",
                         "Plain text, a word a line: readable and editable by hand")
            let removal = try HotwordStore.remove(["TRANSFORMER", "没有这个词"])
            precondition(removal.changed == ["Transformer"] && removal.unchanged == ["没有这个词"] && removal.words == ["梯度下降", "注意力机制"])
            try HotwordStore.save([])
            precondition(HotwordStore.load().isEmpty && HotwordStore.modified() != nil, "An emptied list is still a file, so old settings are not moved in again")
            let manyWords = (0..<30).map { "术语\($0)号词条" }
            let liveWords = HotwordStore.live(manyWords)
            precondition(liveWords == Array(manyWords.prefix(liveWords.count)) && liveWords.joined().count <= HotwordStore.liveCharacters
                         && (liveWords + [manyWords[liveWords.count]]).joined().count > HotwordStore.liveCharacters, "The top of the list, as much as fits")
            let liveConfig = try JSONSerialization.jsonObject(with: VolcFrame.configuration(uid: "u", hotwords: manyWords,
                                tables: VolcTables(boosting: " tb-1 "))) as! [String: Any]
            let liveCorpus = (liveConfig["request"] as! [String: Any])["corpus"] as! [String: Any]
            let liveContext = try JSONSerialization.jsonObject(with: Data((liveCorpus["context"] as! String).utf8)) as! [String: [[String: String]]]
            precondition(liveContext["hotwords"]?.compactMap { $0["word"] } == liveWords && liveCorpus["boosting_table_id"] as? String == "tb-1"
                         && liveCorpus["correct_table_id"] == nil, "Streaming sends what fits, and names the console's hot word table; never a replacement table")
            let fileBody = try JSONSerialization.jsonObject(with: VolcRecording.submitBody(wav: Data(), uid: "u", hotwords: manyWords,
                                tables: VolcTables(), splitOnPauses: false)) as! [String: Any]
            let fileCorpus = (fileBody["request"] as! [String: Any])["corpus"] as! [String: Any]
            let fileContext = try JSONSerialization.jsonObject(with: Data((fileCorpus["context"] as! String).utf8)) as! [String: [[String: String]]]
            precondition(fileContext["hotwords"]?.count == 30 && fileCorpus["correct_table_id"] == nil && fileCorpus["boosting_table_id"] == nil,
                         "Refining from the recording uses the whole list")
            precondition(VolcTables().corpus(hotwords: []) == nil && VolcTables(boosting: "tb").corpus(hotwords: [])?.count == 1)
            let hotCommands = try [["hotword"], ["hotwords", "list", "--json"], ["hotword", "add", "小林", "梯度下降，损失函数"], ["hotword", "rm", "小林"],
                                   ["hotword", "delete", "a b"]].map { try Lstf.parse($0) }
            precondition(hotCommands == [.hotwords(json: false), .hotwords(json: true), .addHotwords(["小林", "梯度下降", "损失函数"]),
                                         .deleteHotwords(["小林"]), .deleteHotwords(["a b"])])
            for wrong in [["hotword", "add"], ["hotword", "frob"], ["hotword", "list", "extra"], ["hotword", "add", "x", "--json"]] {
                do { _ = try Lstf.parse(wrong); fatalError("\(wrong) accepted") } catch let error as LstfError { precondition(error.usage) }
            }
            let listing = Lstf.hotwordList(manyWords).split(separator: "\n").map(String.init)
            precondition(listing[0].contains("热词 30 个") && listing[0].contains("前 \(liveWords.count) 个") && listing[1] == " 1  术语0号词条"
                         && listing[liveWords.count] == String(format: "%2d", liveWords.count) + "  " + liveWords.last!
                         && listing[liveWords.count + 1].hasSuffix("（只在精修时用）") && Lstf.hotwordList([]).contains("lstf hotword add"))
            let said1 = Lstf.hotwordResult(.init(changed: ["小林"], unchanged: ["听流"], refused: [], words: ["听流", "小林"]), adding: true, recording: true)
            precondition(said1.contains("已添加：小林。") && said1.contains("已经有了：听流。") && said1.contains("共 2 个") && said1.contains("下一段讲话起生效"))
            let said2 = Lstf.hotwordResult(.init(changed: [manyWords[29]], words: manyWords), adding: true, recording: false)
            precondition(said2.contains("只在精修时用") && !said2.contains("正在录制"))
            let said3 = Lstf.hotwordResult(.init(changed: [], unchanged: ["没有"], words: []), adding: false, recording: true)
            precondition(said3.contains("热词表里没有：没有。") && !said3.contains("生效"))
            precondition(Lstf.help.contains("lstf hotword add") && Lstf.help.contains("不是错的写法"))
            HotwordStore.fileOverride = nil

            // Kept audio: the file stays open between pieces, and a deleted session's file is not written to again.
            let heldSession = UUID()
            for index in 0..<50 { AudioStore.appendStream(Data(repeating: 1, count: 640), session: heldSession, source: "电脑声音", spanStart: index == 0 ? listStart : nil) }
            precondition(AudioStore.streamSeconds(heldSession) == 1, "50 pieces of 20 ms")
            precondition(AudioStore.readStream(session: heldSession, source: "电脑声音", offset: 0, count: 16000)?.count == 32000)
            AudioStore.deleteStream(heldSession)
            precondition(AudioStore.streamSeconds(heldSession) == 0 && !AudioStore.hasAudio(heldSession))
            AudioStore.appendStream(Data(repeating: 2, count: 640), session: heldSession, source: "电脑声音", spanStart: listStart)
            precondition(AudioStore.streamSeconds(heldSession) == 0.02 && AudioStore.streamSpans(heldSession)["电脑声音"]?.count == 1,
                         "A new recording after deletion starts a new file")
            AudioStore.release()
            AudioStore.appendStream(Data(repeating: 3, count: 640), session: heldSession, source: "电脑声音", spanStart: nil)
            precondition(AudioStore.streamSeconds(heldSession) == 0.04, "Released files open again when more arrives")
            AudioStore.delete(heldSession)
            SessionStore.folderOverride = nil
            AudioStore.rootOverride = nil
        }

        // --- 0.11.1: a session can be given a name ---
        do {
            let nameRoot = FileManager.default.temporaryDirectory.appendingPathComponent("lf-name-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: nameRoot) }
            SessionStore.folderOverride = nameRoot.appendingPathComponent("Sessions")
            defer { SessionStore.folderOverride = nil }

            precondition(SessionStore.cleanName("  产品周会\n导出排期  ") == "产品周会 导出排期" && SessionStore.cleanName(" \n\t ") == nil
                         && SessionStore.cleanName(String(repeating: "长", count: 200))?.count == SessionStore.nameLimit,
                         "One line, trimmed, not endless; nothing left is no name")
            precondition(SessionStore.name(title: "全局声音 · Nov 18, 2026 at 22:52", renamed: false) == "全局声音"
                         && SessionStore.name(title: "需求评审 · 第二场", renamed: true) == "需求评审 · 第二场",
                         "The app's own titles lose their date where one is shown anyway; a given name is kept whole")

            let began = Date(timeIntervalSince1970: 1_800_000_000)
            var named = MeetingSession(title: "全局声音 · Nov 18, 2026 at 22:52", created: began)
            named.lines = [TranscriptLine(start: began.addingTimeInterval(2), end: began.addingTimeInterval(6), source: "电脑声音", text: "第一句", latency: 1),
                           TranscriptLine(start: began.addingTimeInterval(8), end: began.addingTimeInterval(12), source: "麦克风", text: "第二句", latency: 1)]
            named.organized = OrganizedTranscript(text: "稿", generatedAt: began, sourceLineIDs: [named.lines[0].id], through: began.addingTimeInterval(6))
            named.refinedAt = began.addingTimeInterval(60)
            precondition(named.name == "全局声音" && SessionSummary(named).renamed == false && SessionSummary(named).name == "全局声音")
            try SessionStore.save(named)
            let before = try Data(contentsOf: SessionStore.folder.appendingPathComponent(named.id.uuidString + ".json"))
            precondition(!String(decoding: before, as: UTF8.self).contains("renamed"), "Sessions nobody renamed are stored as before")

            let after = try SessionStore.rename(named.id, to: "  需求评审 · 第二场\n")
            let stored = SessionStore.load(named.id)
            precondition(after.title == "需求评审 · 第二场" && stored?.title == "需求评审 · 第二场" && stored?.renamed == true && stored?.name == "需求评审 · 第二场")
            precondition(stored?.lines.map(\.id) == named.lines.map(\.id) && stored?.lines.map(\.text) == ["第一句", "第二句"]
                         && stored?.organized?.text == "稿" && stored?.refinedAt == named.refinedAt && stored?.created == named.created,
                         "Only the name changes")
            let namedFile = SessionStore.folder.appendingPathComponent(named.id.uuidString + ".json")
            let namedMode = try FileManager.default.attributesOfItem(atPath: namedFile.path)[.posixPermissions] as? Int
            precondition(namedMode == 0o600)
            let namedRows = SessionStore.summaries()
            precondition(namedRows.count == 1 && namedRows[0].renamed && namedRows[0].name == "需求评审 · 第二场" && namedRows[0] == SessionSummary(stored!),
                         "The list reads the name without reading the lines")
            var refusedEmpty = false, refusedMissing = false
            do { try SessionStore.rename(named.id, to: "  ") } catch { refusedEmpty = true }
            do { try SessionStore.rename(UUID(), to: "别的") } catch { refusedMissing = true }
            precondition(refusedEmpty && refusedMissing && SessionStore.load(named.id)?.title == "需求评审 · 第二场")
            precondition(SessionStore.markdown(stored!).hasPrefix("# 需求评审 · 第二场\n"), "The export carries the name")

            // What the tool asks of the app.
            let ask = AgentBridge.Request(action: AgentBridge.rename, session: named.id, name: "周会")
            try AgentBridge.submit(ask)
            let waiting = AgentBridge.pending()
            precondition(waiting.count == 1 && waiting[0].action == "rename" && waiting[0].name == "周会" && waiting[0].session == named.id)
            AgentBridge.cancel(ask)
            let older = try JSONDecoder().decode(AgentBridge.Request.self, from: Data(#"{"id":"\#(UUID().uuidString)","action":"refine","session":"\#(named.id.uuidString)","created":0}"#.utf8))
            precondition(older.name == nil && older.action == AgentBridge.refine, "A request written by 0.11.0 still reads")

            // The command.
            let parsedNames = try [["rename", "产品周会", "导出排期"], ["rename", "--session", "3F2A91BC", "  周会 "], ["rename", "周会", "--session", "latest"]].map(Lstf.parse)
            precondition(parsedNames == [.rename(name: "产品周会 导出排期", session: nil), .rename(name: "周会", session: "3F2A91BC"),
                                         .rename(name: "周会", session: "latest")], "Words after rename are the name, joined by spaces")
            for wrong in [["rename"], ["rename", "  "], ["rename", "周会", "--json"], ["rename", "周会", "--session"]] {
                var usage = false
                do { _ = try Lstf.parse(wrong) } catch let error as LstfError { usage = error.usage }
                precondition(usage, "\(wrong) is a mistake in the command")
            }
            let short = Lstf.shortID(named.id)
            precondition(Lstf.renamed(named.id, from: "全局声音 · Nov 18", to: "周会", note: nil) == "会话 \(short) 已改名：「全局声音 · Nov 18」→「周会」\n"
                         && Lstf.renamed(named.id, from: "周会", to: "周会", note: "听流没有在运行，这里是最近的一场。")
                            == "听流没有在运行，这里是最近的一场。\n会话 \(short) 本来就叫「周会」。\n")
            precondition(Lstf.help.contains("lstf rename 新名字 [--session 会话]") && Lstf.help.contains("能改动的只有三件事"))
            precondition(Lstf.listRow(Lstf.Info(session: stored!, keptSeconds: 0, localAudio: false, open: false, recording: false, refining: nil)).contains("「需求评审 · 第二场」"))
        }

        // --- 0.11.2: a session can be deleted ---
        do {
            let goneRoot = FileManager.default.temporaryDirectory.appendingPathComponent("lf-gone-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: goneRoot) }
            SessionStore.folderOverride = goneRoot.appendingPathComponent("Sessions")
            defer { SessionStore.folderOverride = nil }
            let fm = FileManager.default
            let forever: (URL) throws -> Void = { try fm.removeItem(at: $0) }

            var doomed = MeetingSession(title: "要删的", created: Date(timeIntervalSince1970: 1_800_000_000))
            doomed.lines = [TranscriptLine(start: doomed.created, end: doomed.created.addingTimeInterval(4), source: "电脑声音", text: "一句", latency: 1)]
            var kept = MeetingSession(title: "留下的", created: Date(timeIntervalSince1970: 1_800_000_500))
            kept.lines = doomed.lines
            try SessionStore.save(doomed)
            try SessionStore.save(kept)
            for id in [doomed.id, kept.id] {
                try fm.createDirectory(at: ImageAttachmentStore.folder(for: id), withIntermediateDirectories: true)
                try Data([1, 2, 3]).write(to: ImageAttachmentStore.folder(for: id).appendingPathComponent("shot-20270115-160000.jpg"))
            }
            var removed: [String] = []
            try SessionStore.delete(doomed.id) { removed.append($0.lastPathComponent); try forever($0) }
            precondition(removed == [doomed.id.uuidString + ".json", doomed.id.uuidString], "The file first, then the pictures; nothing else")
            precondition(SessionStore.load(doomed.id) == nil && !fm.fileExists(atPath: ImageAttachmentStore.folder(for: doomed.id).path))
            precondition(SessionStore.all().map(\.id) == [kept.id] && SessionStore.summaries().map(\.id) == [kept.id]
                         && fm.fileExists(atPath: ImageAttachmentStore.folder(for: kept.id).appendingPathComponent("shot-20270115-160000.jpg").path),
                         "The other session and its pictures are untouched")
            var calls = 0
            try SessionStore.delete(doomed.id) { _ in calls += 1 }
            try SessionStore.delete(UUID()) { _ in calls += 1 }
            precondition(calls == 0, "Nothing there is nothing to do, not an error")
            // No pictures: only the file goes.
            try fm.removeItem(at: ImageAttachmentStore.folder(for: kept.id))
            var stopped = false
            do { try SessionStore.delete(kept.id) { _ in throw CaptureFailure.message("废纸篓不可用") } } catch { stopped = true }
            precondition(stopped && SessionStore.load(kept.id) != nil, "When it cannot be moved away it stays, and the caller hears why")
            removed = []
            try SessionStore.delete(kept.id) { removed.append($0.lastPathComponent); try forever($0) }
            precondition(removed == [kept.id.uuidString + ".json"] && SessionStore.all().isEmpty)
            for command in [["delete"], ["delete", "latest"], ["rm", "3F2A91BC"], ["remove"]] {
                var usage = false
                do { _ = try Lstf.parse(command) } catch let error as LstfError { usage = error.usage }
                precondition(usage, "lstf has no way to delete a session")
            }
        }

        print("PASS: silence, bounded chunks, lossless boundaries, endpointing, independent sources, discard, API URLs, context snapshots, session round-trip")
        print("PASS: old-session compatibility, organized draft persistence/export, late-arrival coverage, lossless cleanup batching, raw-only cleanup context")
        print("PASS: Doubao frames (gzip, headers, errors, malformed input), sentence de-duplication, resend backlog, speech gate, engine settings")
        print("PASS: recording refinement (span index, upload planning and cutting, clock mapping, WAV, request, replacement guards, paragraphs, when to cut on pauses), kept speech store, key file")
        print("PASS: lstf (arguments, choosing a session, paging, output, search), app/tool request files, refinement applied to a stored session")
        print("PASS: session list summaries, saving off the main thread, paragraphs on the page, screenshots kept by time and shown to lstf, hot word file and lstf hotword, console tables, kept-audio files held open")
        print("PASS: deleting a session (its file and pictures, nothing else; refused when it cannot be moved away; not from lstf)")
        print("PASS: naming a session (clean names, the stored file, the list, the export), lstf rename (arguments, the request, output)")
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
    }
}
