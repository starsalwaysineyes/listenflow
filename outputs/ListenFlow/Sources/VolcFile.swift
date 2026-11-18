import Foundation

/// A stretch of kept audio: where it sits in the source's file (in samples) and
/// when its first sample was captured.
struct AudioSpan: Equatable, Sendable {
    var offset: Int
    var count: Int
    var start: Date
    var end: Date { start.addingTimeInterval(Double(count) / 16000) }
}

/// Whole-transcript refinement for the cloud engine. While recording, the speech
/// that is streamed to Doubao is also kept on this Mac. Afterwards it is sent, a
/// few minutes at a time, to Doubao's recording-file recognition, which hears
/// each sentence with its full context and is not forced to cut a long one at
/// 20 s the way the streaming service is. Measured on 269 s of noisy speech:
/// 19 wrong characters against 27 for streaming (of 1,322).
///
/// Everything here is free of networking so it can be unit-tested.
enum VolcRecording {
    /// Audio per request. The interface took 269 s inline in testing; its
    /// documented limits (512 MB) concern uploads by URL.
    static let chunkSeconds: TimeInterval = 300
    /// Where a stretch longer than that is cut: the quietest moment in the last
    /// part of the chunk, so the cut falls between words.
    static let cutSearchSeconds: TimeInterval = 20
    /// Silence put between spans that were not adjacent when recorded, so the
    /// last word of one cannot run into the first of the next.
    static let seamMS = 500

    /// The index is one line per span, "offset start", written when the span
    /// begins; a span runs until the next one or the end of the file.
    static func spans(index: String, totalSamples: Int) -> [AudioSpan] {
        var marks: [(offset: Int, start: Date)] = []
        for line in index.split(separator: "\n") {
            let parts = line.split(separator: " ")
            guard parts.count == 2, let offset = Int(parts[0]), let time = Double(parts[1]),
                  offset >= (marks.last?.offset ?? 0), offset < totalSamples else { continue }
            marks.append((offset, Date(timeIntervalSince1970: time)))
        }
        return marks.enumerated().compactMap { i, mark in
            let end = i + 1 < marks.count ? marks[i + 1].offset : totalSamples
            return end > mark.offset ? AudioSpan(offset: mark.offset, count: end - mark.offset, start: mark.start) : nil
        }
    }

    /// Groups spans into uploads of at most `limit` samples. Spans are kept whole
    /// where possible — they end in pauses — and one that is longer than the
    /// limit is cut where `cut` says, given the range of samples to search.
    static func plan(_ spans: [AudioSpan], limit: Int, search: Int, cut: (Range<Int>) -> Int) -> [[AudioSpan]] {
        var chunks: [[AudioSpan]] = [], current: [AudioSpan] = [], size = 0
        func close() { if !current.isEmpty { chunks.append(current); current = []; size = 0 } }
        for span in spans.sorted(by: { $0.start < $1.start }) {
            var rest = span
            if size + rest.count > limit { close() }
            while rest.count > limit {
                let from = rest.offset + max(limit - search, limit / 2), to = rest.offset + limit
                let at = min(max(cut(from..<to), from), to)
                let head = AudioSpan(offset: rest.offset, count: at - rest.offset, start: rest.start)
                chunks.append([head])
                rest = AudioSpan(offset: at, count: rest.count - head.count, start: head.end)
            }
            current.append(rest)
            size += rest.count
        }
        close()
        return chunks
    }

    /// The middle of the quietest `window` in 16-bit PCM, as a sample index.
    static func quietest(in pcm: Data, window: TimeInterval = 0.3) -> Int {
        let frame = 320
        let energies: [Double] = pcm.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            return stride(from: 0, to: samples.count - frame + 1, by: frame).map { at in
                (at..<at + frame).reduce(0.0) { $0 + Double(samples[$1]) * Double(samples[$1]) }
            }
        }
        let width = max(1, Int(window * 16000) / frame)
        guard energies.count > width else { return pcm.count / 4 }
        var sum = energies[..<width].reduce(0, +), best = sum, bestAt = 0
        for i in width..<energies.count {
            sum += energies[i] - energies[i - width]
            if sum < best { best = sum; bestAt = i - width + 1 }
        }
        return (bestAt * frame) + width * frame / 2
    }

    /// Where each span starts in the uploaded audio, in milliseconds.
    static func starts(_ spans: [AudioSpan]) -> [Int] {
        var at = 0
        return spans.enumerated().map { i, span in
            if i > 0 && !adjacent(spans[i - 1], span) { at += seamMS }
            defer { at += span.count / 16 }
            return at
        }
    }

    /// Two halves of one stretch that was cut for length: nothing goes between
    /// them. Every stretch follows the last in the file, so it is the clock that
    /// tells a cut from a pause.
    static func adjacent(_ a: AudioSpan, _ b: AudioSpan) -> Bool {
        a.offset + a.count == b.offset && abs(b.start.timeIntervalSince(a.end)) < 0.02
    }

    /// When the audio at `ms` of the upload was captured. A time that falls in a
    /// seam belongs to the end of the span before it.
    static func date(ms: Int, in spans: [AudioSpan]) -> Date {
        let starts = starts(spans)
        guard let index = starts.lastIndex(where: { $0 <= ms }) else { return spans.first?.start ?? Date() }
        let span = spans[index]
        return span.start.addingTimeInterval(min(Double(ms - starts[index]) / 1000, Double(span.count) / 16000))
    }

    /// A 16 kHz mono 16-bit WAV of the spans' audio, with the seams in place.
    static func wav(_ parts: [Data], spans: [AudioSpan]) -> Data {
        var body = Data()
        for (i, part) in parts.enumerated() {
            if i > 0 && !adjacent(spans[i - 1], spans[i]) { body.append(Data(count: seamMS * 32)) }
            body.append(part)
        }
        var out = Data()
        func put32(_ value: Int) { withUnsafeBytes(of: UInt32(value).littleEndian) { out.append(contentsOf: $0) } }
        func put16(_ value: Int) { withUnsafeBytes(of: UInt16(value).littleEndian) { out.append(contentsOf: $0) } }
        out.append(contentsOf: Array("RIFF".utf8)); put32(36 + body.count)
        out.append(contentsOf: Array("WAVEfmt ".utf8)); put32(16); put16(1); put16(1)
        put32(16000); put32(32000); put16(2); put16(16)
        out.append(contentsOf: Array("data".utf8)); put32(body.count)
        out.append(body)
        return out
    }

    /// The submit request. `splitOnPauses` makes the service cut sentences at
    /// short silences instead of by meaning: a microphone next to speakers hears
    /// the app and then the user's reply, and those must not become one sentence,
    /// or the echo filter can only keep or drop both.
    static func submitBody(wav: Data, uid: String, hotwords: [String], splitOnPauses: Bool) -> Data {
        var request: [String: Any] = ["model_name": "bigmodel", "enable_itn": true, "enable_punc": true,
                                      "enable_ddc": true, "show_utterances": true]
        if splitOnPauses { request["vad_segment"] = true; request["end_window_size"] = 300 }
        // This interface takes up to 5,000 hot words, far more than anyone types.
        let words = hotwords.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.prefix(1000)
        if !words.isEmpty,
           let context = try? JSONSerialization.data(withJSONObject: ["hotwords": words.map { ["word": $0] }]) {
            request["corpus"] = ["context": String(decoding: context, as: UTF8.self)]
        }
        let object: [String: Any] = [
            "user": ["uid": uid],
            "audio": ["format": "wav", "codec": "raw", "rate": 16000, "bits": 16, "channel": 1,
                      "data": wav.base64EncodedString()],
            "request": request]
        return (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    }

    static func lines(_ utterances: [VolcUtterance], spans: [AudioSpan], source: String) -> [TranscriptLine] {
        utterances.compactMap { item in
            let text = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            let end = date(ms: item.endMS, in: spans)
            return TranscriptLine(start: min(date(ms: item.startMS, in: spans), end), end: end, source: source,
                                  text: text, latency: 0, refined: true)
        }
    }

    /// The lines these spans' audio produced while recording: same source, and
    /// centred inside the stretch of time the spans cover.
    static func covered(_ lines: [TranscriptLine], source: String, spans: [AudioSpan]) -> [TranscriptLine] {
        guard let from = spans.first?.start, let to = spans.last?.end else { return [] }
        return lines.filter {
            let middle = $0.start.addingTimeInterval($0.end.timeIntervalSince($0.start) / 2)
            return $0.source == source && middle >= from && middle <= to
        }
    }

    /// Never trade real words for a result that lost most of them. More text is
    /// fine: the live pass can miss speech (a reconnect that gave up), and the
    /// recording has it.
    static func acceptable(original: String, refined: String) -> Bool {
        let before = EchoFilter.characters(original).count, after = EchoFilter.characters(refined).count
        return before == 0 ? after > 0 : Double(after) >= Double(before) * 0.5
    }

    /// Live lines that nothing in the new result overlaps in time. Splitting on
    /// pauses makes the service discard very short stretches — measured: a lone
    /// 「第一，」 between two pauses came back with sentence splitting by meaning
    /// and not with splitting on pauses — so on that path a live line without a
    /// counterpart is kept rather than lost.
    static func uncovered(_ old: [TranscriptLine], by fresh: [TranscriptLine]) -> [TranscriptLine] {
        old.filter { line in
            !fresh.contains { min($0.end, line.end).timeIntervalSince(max($0.start, line.start)) > 0.2 }
        }
    }

    /// What one upload's result does to a transcript: the live lines its audio
    /// produced are replaced by the recognized sentences, unless the result
    /// lost most of the words. `split` says the upload was a microphone
    /// recorded next to an app, cut on pauses. Returns whether the text changed.
    static func apply(_ utterances: [VolcUtterance], spans: [AudioSpan], source: String, split: Bool,
                      to lines: inout [TranscriptLine]) -> Bool {
        var fresh = VolcRecording.lines(utterances, spans: spans, source: source)
        // The recording has the echo in it again; the live pass had dropped it.
        if source == EchoFilter.micSource { fresh.removeAll { EchoFilter.isEcho($0, among: lines) } }
        let old = covered(lines, source: source, spans: spans)
        if split { fresh = (fresh + uncovered(old, by: fresh)).sorted { $0.start < $1.start } }
        let before = old.map(\.text).joined(), after = fresh.map(\.text).joined()
        if before == after {
            // Nothing to improve; keep the lines (and their place in an organized
            // draft) and only note that this stretch is done.
            let ids = Set(old.map(\.id))
            for index in lines.indices where ids.contains(lines[index].id) { lines[index].refined = true }
            return false
        }
        guard acceptable(original: before, refined: after) else { return false }
        replace(old, with: fresh, in: &lines)
        return true
    }

    /// Uploads still to do: a run that was interrupted has already replaced
    /// some stretches, and those are not sent, or paid for, twice.
    static func unfinished(_ lines: [TranscriptLine], source: String, spans: [AudioSpan]) -> Bool {
        let old = covered(lines, source: source, spans: spans)
        return old.isEmpty || old.contains { $0.refined != true }
    }

    /// Swap the live lines of one upload for the recognized ones.
    static func replace(_ old: [TranscriptLine], with new: [TranscriptLine], in lines: inout [TranscriptLine]) {
        let gone = Set(old.map(\.id))
        lines.removeAll { gone.contains($0.id) }
        lines += new
        lines.sort { $0.start < $1.start }
    }
}

enum VolcFileError: LocalizedError {
    case failed(String)
    var errorDescription: String? { if case let .failed(text) = self { return text }; return nil }
}

/// Doubao's recording-file recognition: submit the audio, then ask for the result
/// until it is ready. Same account key as streaming, its own resource.
struct VolcFileClient: Sendable {
    static let submitURL = URL(string: "https://openspeech.bytedance.com/api/v3/auc/bigmodel/submit")!
    static let queryURL = URL(string: "https://openspeech.bytedance.com/api/v3/auc/bigmodel/query")!
    static let done = 20000000, processing = 20000001, queued = 20000002, silence = 20000003, empty = 45000002

    let key: String
    let resourceID: String

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 900
        return URLSession(configuration: configuration)
    }()

    private func request(_ url: URL, id: String, body: Data) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue(resourceID, forHTTPHeaderField: "X-Api-Resource-Id")
        request.setValue(id, forHTTPHeaderField: "X-Api-Request-Id")
        return request
    }

    private enum Outcome {
        case status(Int, Data)
        /// Network trouble or the service's own (55xxxxxx: busy, internal error).
        case retry(String)
    }

    /// The service reports through headers; the HTTP status alone says little.
    private func attempt(_ request: URLRequest, what: String) async throws -> Outcome {
        do {
            let (data, response) = try await Self.session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .retry("没有收到应答") }
            let message = [http.value(forHTTPHeaderField: "X-Api-Message") ?? "", VolcFrame.errorMessage(data)]
                .first { !$0.isEmpty } ?? "服务端没有给出原因"
            if let code = http.value(forHTTPHeaderField: "X-Api-Status-Code").flatMap(Int.init) {
                return code / 1_000_000 == 55 ? .retry("\(code)：\(message)") : .status(code, data)
            }
            if http.statusCode >= 500 { return .retry("HTTP \(http.statusCode)：\(message)") }
            throw VolcFileError.failed("豆包录音识别\(what)被拒绝（HTTP \(http.statusCode)）：\(message)")
        } catch let error as URLError where error.code != .cancelled {
            return .retry(error.localizedDescription)
        }
    }

    /// Sentences of the audio in `body` (see `VolcRecording.submitBody`), timed
    /// from its start. `seconds` is the length of the audio, to size the wait.
    func recognize(body: Data, seconds: TimeInterval) async throws -> [VolcUtterance] {
        var id = UUID().uuidString
        var failures = 0
        while true {
            var submit = request(Self.submitURL, id: id, body: body)
            submit.setValue("-1", forHTTPHeaderField: "X-Api-Sequence")
            switch try await attempt(submit, what: "提交") {
            case .status(Self.done, _): break
            case .status(Self.empty, _): return []
            case let .status(code, data):
                throw VolcFileError.failed("豆包录音识别提交失败（\(code)）：\(VolcFrame.errorMessage(data))" + Self.hint(code))
            case let .retry(reason):
                failures += 1
                guard failures < 4 else { throw VolcFileError.failed("豆包录音识别提交失败：\(reason)") }
                try await Task.sleep(nanoseconds: UInt64(failures) * 1_500_000_000)
                // A fresh ID: the service refuses one it has already seen.
                id = UUID().uuidString
                continue
            }
            break
        }
        // Measured: 75 s of audio took 17 s, 269 s took 32 s.
        let deadline = Date().addingTimeInterval(max(180, seconds * 2))
        let query = request(Self.queryURL, id: id, body: Data("{}".utf8))
        failures = 0
        while true {
            try await Task.sleep(nanoseconds: 1_500_000_000)
            switch try await attempt(query, what: "查询") {
            case let .status(Self.done, data): return VolcFrame.utterances(in: data)?.utterances ?? []
            case .status(Self.silence, _), .status(Self.empty, _): return []
            case .status(Self.processing, _), .status(Self.queued, _):
                failures = 0
                guard Date() < deadline else { throw VolcFileError.failed("豆包录音识别超时：提交后一直没有返回结果。") }
            case let .status(code, data):
                throw VolcFileError.failed("豆包录音识别失败（\(code)）：\(VolcFrame.errorMessage(data))" + Self.hint(code))
            case let .retry(reason):
                failures += 1
                guard failures < 6, Date() < deadline else { throw VolcFileError.failed("豆包录音识别查询失败：\(reason)") }
            }
        }
    }

    private static func hint(_ code: Int) -> String {
        switch code {
        case 45000131: "。提交得太快，请稍后再点「精修全文」。"
        case 45000132: "。单段音频超过了接口的大小限制。"
        default: ""
        }
    }
}
