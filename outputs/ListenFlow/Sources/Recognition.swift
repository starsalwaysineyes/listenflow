import Foundation
import IOKit.ps

enum PowerSource {
    /// Desktop Macs report AC; an unreadable state counts as AC too, because the
    /// worst case is spending a little more compute, never losing accuracy.
    static var onAC: Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String? else { return true }
        return type != "Battery Power"
    }

    static func wantsQuality(_ mode: RecognitionMode) -> Bool {
        switch mode {
        case .quality: true
        case .economy: false
        case .auto: onAC && !ProcessInfo.processInfo.isLowPowerModeEnabled
        }
    }
}

/// The session's audio, one Int16 file per source, kept so the session can be
/// recognized again: by "refine" after the meeting, or one day by a better
/// model. It stays until the session is deleted — an hour of speech from one
/// source is about 115 MB. With the local engine it never leaves this Mac; with
/// the cloud engine it is what was streamed to Doubao, and refinement sends it again.
enum AudioStore {
    /// Tests point this at a temporary folder so they never touch real sessions.
    nonisolated(unsafe) static var rootOverride: URL?
    static var root: URL { rootOverride ?? ListenFlowHome.root.appendingPathComponent("audio", isDirectory: true) }
    /// Up to 0.8.0 kept audio sat beside the sessions in Application Support.
    /// Sessions still refer to it, so it moves rather than being left behind.
    static func adoptLegacy() {
        let fm = FileManager.default
        let old = SessionStore.folder.deletingLastPathComponent().appendingPathComponent("Audio", isDirectory: true)
        guard rootOverride == nil, let sessions = try? fm.contentsOfDirectory(at: old, includingPropertiesForKeys: nil) else { return }
        queue.sync {
            try? ListenFlowHome.ensure(root)
            for dir in sessions { try? fm.moveItem(at: dir, to: root.appendingPathComponent(dir.lastPathComponent)) }
            if (try? fm.contentsOfDirectory(atPath: old.path))?.isEmpty == true { try? fm.removeItem(at: old) }
        }
    }
    private static let queue = DispatchQueue(label: "ListenFlow.audio")
    nonisolated(unsafe) private static var lengths: [String: Int] = [:]   // guarded by queue

    static func folder(_ session: UUID) -> URL { root.appendingPathComponent(session.uuidString, isDirectory: true) }
    static func file(session: UUID, source: String) -> URL {
        let name = source.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "audio"
        return folder(session).appendingPathComponent(name + ".pcm")
    }

    /// Reserves the range synchronously, so refs follow submission order, and writes
    /// on a serial queue so capture never waits on the disk.
    static func append(_ samples: [Float], session: UUID, source: String) -> AudioRef {
        let url = file(session: session, source: source)
        return queue.sync {
            let offset = lengths[url.path] ?? currentLength(url)
            lengths[url.path] = offset + samples.count
            let data = samples.map { Int16(max(-1, min(1, $0)) * 32767) }.withUnsafeBytes { Data($0) }
            // A failed write only makes refinement unavailable for this stretch;
            // live transcription is unaffected.
            queue.async { try? write(data, to: url, at: UInt64(offset * 2)) }
            return AudioRef(offset: offset, count: samples.count)
        }
    }

    /// Files being appended to stay open. A recording hands over a piece of audio
    /// about 70 times a second; opening and closing the file for each one cost
    /// 112 µs a piece (measured), nearly all of it in the open and close.
    nonisolated(unsafe) private static var handles: [String: FileHandle] = [:]   // guarded by queue

    private static func handle(_ url: URL) throws -> FileHandle {
        if let open = handles[url.path] { return open }
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        let handle = try FileHandle(forWritingTo: url)
        handles[url.path] = handle
        return handle
    }

    private static func write(_ data: Data, to url: URL, at position: UInt64?) throws {
        let handle = try handle(url)
        do {
            if let position { try handle.seek(toOffset: position) } else { try handle.seekToEnd() }
            try handle.write(contentsOf: data)
        } catch {
            // Not to be trusted again; the next write opens the file afresh.
            try? handle.close()
            handles[url.path] = nil
            throw error
        }
    }

    /// Call on `queue`. Closes what is open under `prefix` (everything when nil);
    /// a file must be closed before it is deleted, or later writes would go to
    /// a file that no longer has a name.
    private static func closeHandles(under prefix: String? = nil) {
        for (path, handle) in handles where prefix.map(path.hasPrefix) ?? true {
            try? handle.close()
            handles[path] = nil
        }
    }

    /// Recording has stopped: nothing more is coming, so let the files go.
    static func release() { queue.sync { closeHandles() } }

    // MARK: Cloud engine
    //
    // The speech streamed to Doubao, kept so the whole session can be recognized
    // again from the recording afterwards. Its own files: there are no chunks to
    // point lines at, only stretches of speech and when each began.

    static func streamFile(session: UUID, source: String) -> URL {
        file(session: session, source: source).deletingPathExtension().appendingPathExtension("stream.pcm")
    }
    private static func streamIndex(_ file: URL) -> URL {
        file.deletingPathExtension().appendingPathExtension("idx")
    }

    /// 16-bit PCM as it goes to the service; `spanStart` is set on the first
    /// piece of a new stretch of speech.
    static func appendStream(_ pcm: Data, session: UUID, source: String, spanStart: Date?) {
        appendStream(pcm, to: streamFile(session: session, source: source), spanStart: spanStart)
    }

    /// For a caller that appends many times: `url` is `streamFile(session:source:)`,
    /// worked out once. Building that path was half the cost of an append.
    static func appendStream(_ pcm: Data, to url: URL, spanStart: Date?) {
        queue.sync {
            let offset = lengths[url.path] ?? currentLength(url)
            lengths[url.path] = offset + pcm.count / 2
            queue.async {
                if let spanStart {
                    try? write(Data("\(offset) \(spanStart.timeIntervalSince1970)\n".utf8), to: streamIndex(url), at: nil)
                }
                try? write(pcm, to: url, at: UInt64(offset * 2))
            }
        }
    }

    /// Every source of the session that has kept speech, with its stretches.
    static func streamSpans(_ session: UUID) -> [String: [AudioSpan]] {
        queue.sync {
            var result: [String: [AudioSpan]] = [:]
            for url in streamFiles(session) {
                let name = url.lastPathComponent.replacingOccurrences(of: ".stream.pcm", with: "")
                guard let source = name.removingPercentEncoding,
                      let index = try? String(contentsOf: streamIndex(url), encoding: .utf8) else { continue }
                let spans = VolcRecording.spans(index: index, totalSamples: currentLength(url))
                if !spans.isEmpty { result[source] = spans }
            }
            return result
        }
    }

    static func readStream(session: UUID, source: String, offset: Int, count: Int) -> Data? {
        let url = streamFile(session: session, source: source)
        return queue.sync {
            guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
            defer { try? handle.close() }
            guard (try? handle.seek(toOffset: UInt64(offset * 2))) != nil,
                  let data = try? handle.read(upToCount: count * 2), data.count == count * 2 else { return nil }
            return data
        }
    }

    /// Seconds of kept speech, all sources together; 0 when there is none.
    static func streamSeconds(_ session: UUID) -> TimeInterval {
        queue.sync { Double(streamFiles(session).reduce(0) { $0 + currentLength($1) }) / 16000 }
    }

    // The audio outlives refinement, so what has been refined is written down:
    // beside each source's file, how many samples a completed refinement covered.
    // Without it every later refinement would send, and pay for, the same speech.
    private static func streamMark(_ file: URL) -> URL {
        file.deletingPathExtension().appendingPathExtension("done")
    }
    private static func refinedLength(_ file: URL) -> Int {
        (try? String(contentsOf: streamMark(file), encoding: .utf8)).flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) } ?? 0
    }
    /// A refinement of the whole session has finished: everything kept so far is done.
    static func markStreamRefined(_ session: UUID) {
        queue.sync {
            for url in streamFiles(session) {
                try? Data("\(currentLength(url))\n".utf8).write(to: streamMark(url), options: .atomic)
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: streamMark(url).path)
            }
        }
    }
    /// Per source, the sample up to which the kept speech has been refined.
    static func refinedSamples(_ session: UUID) -> [String: Int] {
        queue.sync {
            var result: [String: Int] = [:]
            for url in streamFiles(session) {
                let name = url.lastPathComponent.replacingOccurrences(of: ".stream.pcm", with: "")
                if let source = name.removingPercentEncoding { result[source] = refinedLength(url) }
            }
            return result
        }
    }
    /// Seconds of kept speech that no completed refinement has covered.
    static func unrefinedStreamSeconds(_ session: UUID) -> TimeInterval {
        queue.sync { Double(streamFiles(session).reduce(0) { $0 + max(0, currentLength($1) - refinedLength($1)) }) / 16000 }
    }
    /// Everything kept, for every session, in bytes.
    static func totalBytes() -> Int {
        guard let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        return files.reduce(0) { $0 + (((try? ($1 as? URL)?.resourceValues(forKeys: [.fileSizeKey]))?.fileSize) ?? 0) }
    }

    static func deleteStream(_ session: UUID) {
        queue.sync {
            let fm = FileManager.default
            let dir = folder(session)
            closeHandles(under: dir.path)
            // By prefix, not by listed URL: a listing may spell the path differently.
            lengths = lengths.filter { !($0.key.hasPrefix(dir.path) && $0.key.hasSuffix(".stream.pcm")) }
            for url in streamFiles(session) {
                try? fm.removeItem(at: url)
                try? fm.removeItem(at: streamIndex(url))
                try? fm.removeItem(at: streamMark(url))
            }
            if (try? fm.contentsOfDirectory(atPath: dir.path))?.isEmpty == true { try? fm.removeItem(at: dir) }
        }
    }

    private static func streamFiles(_ session: UUID) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: folder(session), includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasSuffix(".stream.pcm") }
    }

    /// The local engine's files only; kept speech of the cloud engine stays.
    static func deleteChunks(_ session: UUID) {
        queue.sync {
            let fm = FileManager.default
            let dir = folder(session)
            closeHandles(under: dir.path)
            lengths = lengths.filter { !($0.key.hasPrefix(dir.path) && !$0.key.hasSuffix(".stream.pcm")) }
            for url in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            where url.pathExtension == "pcm" && !url.lastPathComponent.hasSuffix(".stream.pcm") {
                try? fm.removeItem(at: url)
            }
            if (try? fm.contentsOfDirectory(atPath: dir.path))?.isEmpty == true { try? fm.removeItem(at: dir) }
        }
    }

    private static func currentLength(_ url: URL) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0) / 2
    }

    static func read(session: UUID, source: String, offset: Int, count: Int) -> [Float]? {
        let url = file(session: session, source: source)
        return queue.sync {     // after any pending writes
            guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
            defer { try? handle.close() }
            guard (try? handle.seek(toOffset: UInt64(offset * 2))) != nil,
                  let data = try? handle.read(upToCount: count * 2), data.count == count * 2 else { return nil }
            return data.withUnsafeBytes { $0.bindMemory(to: Int16.self).map { Float($0) / 32767 } }
        }
    }

    static func hasAudio(_ session: UUID) -> Bool {
        FileManager.default.fileExists(atPath: folder(session).path)
    }

    static func delete(_ session: UUID) {
        queue.sync {
            let dir = folder(session)
            closeHandles(under: dir.path)
            lengths = lengths.filter { !$0.key.hasPrefix(dir.path) }
            try? FileManager.default.removeItem(at: dir)
        }
    }

}

/// Second-pass recognition: whole pause-cut lines are joined into one longer window
/// and re-decoded, and the result replaces them wholesale. Seams always fall in
/// pauses, so there is nothing to stitch and no text alignment to get wrong.
enum Refinement {
    static let liveWindow: TimeInterval = 20      // measured: gains flatten beyond ~20 s
    /// Every windowed re-decode beat single-pass in 36/36 runs (10–35% fewer errors),
    /// but where windows fall moves results more than their length does. 30 s had
    /// the best mean offline and in app replays (vs 20 s: 67 vs 74, 60 vs 71 errors);
    /// after the fact latency is free, so it takes the longer window and coarser rows.
    static let postWindow: TimeInterval = 30      // the worker accepts up to 32 s

    /// Consecutive lines of one source, joined while the window stays under `limit`
    /// and no long silence separates them. Single-line groups gain nothing and are dropped.
    static func windows(_ lines: [TranscriptLine], limit: TimeInterval, maxGap: TimeInterval = 3) -> [[TranscriptLine]] {
        var groups: [[TranscriptLine]] = []
        for source in Set(lines.map(\.source)) {
            var current: [TranscriptLine] = []
            for line in lines.filter({ $0.source == source && $0.audio != nil }).sorted(by: { $0.start < $1.start }) {
                // The window is read as one contiguous range of the audio file, so
                // it must never run backwards, nor skip audio whose line is gone —
                // a microphone echo dropped by `EchoFilter` would be read back in.
                if let first = current.first, let last = current.last,
                   line.end.timeIntervalSince(first.start) > limit
                    || line.start.timeIntervalSince(last.end) > maxGap
                    || line.audio!.offset != last.audio!.offset + last.audio!.count {
                    groups.append(current); current = []
                }
                current.append(line)
            }
            groups.append(current)
        }
        return groups.filter { $0.count >= 2 }.sorted { $0[0].start < $1[0].start }
    }

    /// Refuse a result that dropped or invented a large share of the text — a long
    /// window that collapsed or a hallucination should never overwrite real words.
    static func plausible(original: String, refined: String) -> Bool {
        let a = original.filter { !$0.isPunctuation && !$0.isWhitespace }.count
        let b = refined.filter { !$0.isPunctuation && !$0.isWhitespace }.count
        guard a > 0, b > 0 else { return false }
        let ratio = Double(b) / Double(a)
        return ratio >= 0.6 && ratio <= 1.6
    }

    /// The model ends every request with a full stop; a chunk cut on the ceiling
    /// usually stops mid-sentence, so that stop is misleading.
    static func dropTrailingStop(_ text: String) -> String {
        text.hasSuffix("。") ? String(text.dropLast()) : text
    }

    /// One line replacing `lines`. It keeps the first line's ID, so an organized draft
    /// that already covered that stretch still counts it as covered.
    static func merge(_ lines: [TranscriptLine], text: String) -> TranscriptLine {
        let audio: AudioRef? = {
            guard let first = lines.first?.audio, let last = lines.last?.audio else { return nil }
            return AudioRef(offset: first.offset, count: last.offset + last.count - first.offset)
        }()
        return TranscriptLine(id: lines[0].id, start: lines.map(\.start).min()!, end: lines.map(\.end).max()!,
                              source: lines[0].source, text: text, latency: lines[0].latency, audio: audio, refined: true)
    }

    /// Replace the lines in `ids` with `merged`, only if all are still present.
    static func apply(_ merged: TranscriptLine, replacing ids: [UUID], in lines: inout [TranscriptLine]) -> Bool {
        let targets = Set(ids)
        guard lines.filter({ targets.contains($0.id) }).count == ids.count else { return false }
        lines.removeAll { targets.contains($0.id) }
        lines.append(merged)
        lines.sort { $0.start < $1.start }
        return true
    }
}

/// With the microphone open next to speakers, the app's own sound is recorded a
/// second time. Apple's voice processing removes it completely, but while it runs
/// every other app's plain microphone input goes silent — measured with Tencent
/// Meeting, whose level meter stopped — so it is not usable here. A linear echo
/// canceller left ~15–24 dB of echo, which the model still transcribed (85–125 of
/// 193 characters). Echo is instead removed as text: a microphone line that
/// repeats what the app source said at the same time is dropped, keeping the
/// app's copy, which was recorded digitally and is the cleaner of the two.
enum EchoFilter {
    /// Share of the line's character pairs found in the app text. Measured: an
    /// echo scores 0.95–1.0 against the app's recognition of the same speech;
    /// unrelated lines of six characters or more never exceeded 0.25 (2,000 pairs).
    static let threshold = 0.6
    /// Search margin around the line: the two sources cut at slightly different points.
    static let margin: TimeInterval = 2
    static let micSource = "麦克风"

    static func characters(_ text: String) -> [Character] {
        text.filter { !$0.isPunctuation && !$0.isWhitespace && !$0.isSymbol }.map { $0 }
    }

    static func overlap(_ line: String, in reference: String) -> Double {
        let a = characters(line), b = characters(reference)
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        guard a.count >= 2 else { return b.contains(a[0]) ? 1 : 0 }
        var pairs = Set<String>()
        for i in 0..<(b.count - 1) { pairs.insert(String(b[i...i + 1])) }
        var hits = 0
        for i in 0..<(a.count - 1) where pairs.contains(String(a[i...i + 1])) { hits += 1 }
        return Double(hits) / Double(a.count - 1)
    }

    /// Whether `line` (from the microphone) repeats app lines spoken at the same time.
    /// Short replies such as「好的」match by chance far more easily, so they only
    /// count when an app line overlaps them closely in time.
    static func isEcho(_ line: TranscriptLine, among lines: [TranscriptLine]) -> Bool {
        guard line.source == micSource else { return false }
        let short = characters(line.text).count < 4
        let duration = line.end.timeIntervalSince(line.start)
        let near = lines.filter { other in
            guard other.source != micSource else { return false }
            if short {
                // Most of the reply must lie inside the app line, not merely near it.
                let shared = min(other.end, line.end).timeIntervalSince(max(other.start, line.start))
                return shared >= duration / 2
            }
            return other.end > line.start.addingTimeInterval(-margin) && other.start < line.end.addingTimeInterval(margin)
        }.sorted { $0.start < $1.start }
        guard !near.isEmpty else { return false }
        let score = overlap(line.text, in: near.map(\.text).joined())
        return short ? score >= 1 : score >= threshold
    }
}
