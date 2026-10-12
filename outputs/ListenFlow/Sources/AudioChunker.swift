import Foundation

struct AudioChunk: Sendable {
    let id: UUID
    let samples: [Float]
    let source: String
    let start: Date
    let end: Date
    /// True when the chunk hit the length ceiling with no pause to cut in, so it
    /// may end mid-sentence. Such text gets no forced full stop, and a quality pass
    /// re-decodes it together with its neighbours.
    var forced = false
}

/// Called only on the capture queue. Cuts in pauses, never on a fixed clock.
///
/// A fixed four-second cut used to split words in half (measured: ~78% of real
/// chunks were hard cuts, and most recognition errors sat on those seams). Now:
/// - "quiet" is judged against a rolling noise floor, so a meeting's background
///   hiss no longer hides every pause behind a fixed RMS gate;
/// - once a chunk is long enough, any short gap (~160 ms) between words is a cut;
/// - only if speech runs to the ceiling with no gap at all is the chunk cut, at
///   the quietest moment of its last few seconds, and the rest carried forward.
final class AudioChunker {
    let source: String
    let emit: (AudioChunk) -> Void
    let rate = 16_000

    private let frame = 320                    // 20 ms
    private let minSeconds = 3.0               // below this, a short gap is not a cut
    private let maxSeconds = 8.0               // ceiling; the ASR worker accepts up to 32 s
    private let gapFrames = 8                  // 160 ms between words
    private let endpointFrames = 25            // 500 ms: the speaker stopped
    private let prerollFrames = 10             // 200 ms keeps leading consonants
    private let searchFrames = 125             // look for the quietest point in the last 2.5 s
    private let floorWindow = 150              // noise floor over the last 3 s

    private var floorHistory: [Float] = []
    private var preroll: [(samples: [Float], rms: Float)] = []
    private var frames: [(samples: [Float], rms: Float, speech: Bool)] = []
    private var active = false
    private var quietFrames = 0
    private var started = Date()

    init(source: String, emit: @escaping (AudioChunk) -> Void) {
        self.source = source
        self.emit = emit
    }

    func append(_ input: [Float], end: Date = Date()) {
        guard !input.isEmpty else { return }
        // Small frames make endpointing independent of the input device's buffer size.
        for offset in stride(from: 0, to: input.count, by: frame) {
            let part = Array(input[offset..<min(offset + frame, input.count)])
            let partEnd = end.addingTimeInterval(-Double(input.count - offset - part.count) / Double(rate))
            consume(part, end: partEnd)
        }
    }

    /// Relative to recent audio, capped so that minutes of unbroken speech cannot
    /// raise the floor until speech itself reads as silence.
    private func threshold() -> Float {
        let sorted = floorHistory.sorted()
        let floor = sorted.isEmpty ? 0 : sorted[sorted.count / 10]
        return min(max(0.003, floor * 2.5), 0.03)
    }

    private var sampleCount: Int { frames.reduce(0) { $0 + $1.samples.count } }
    private var hasSpeech: Bool { frames.contains { $0.speech } }

    private func consume(_ part: [Float], end: Date) {
        let rms = sqrt(part.reduce(Float(0)) { $0 + $1 * $1 } / Float(part.count))
        floorHistory.append(rms)
        if floorHistory.count > floorWindow { floorHistory.removeFirst(floorHistory.count - floorWindow) }
        let speech = rms > threshold()

        if !active {
            if !speech {
                preroll.append((part, rms))
                if preroll.count > prerollFrames { preroll.removeFirst(preroll.count - prerollFrames) }
                return
            }
            active = true
            let lead = preroll.reduce(0) { $0 + $1.samples.count }
            frames = preroll.map { ($0.samples, $0.rms, false) }
            preroll.removeAll(keepingCapacity: true)
            started = end.addingTimeInterval(-Double(lead + part.count) / Double(rate))
            quietFrames = 0
        }
        frames.append((part, rms, speech))
        quietFrames = speech ? 0 : quietFrames + 1
        let seconds = Double(sampleCount) / Double(rate)

        if quietFrames >= endpointFrames && seconds >= 0.8 {
            // The speaker stopped: close the chunk and go idle, keeping the
            // trailing silence as pre-roll for whatever comes next.
            let tail = Array(frames.suffix(prerollFrames)).map { ($0.samples, $0.rms) }
            close(upTo: frames.count, forced: false)
            active = false
            preroll = tail
            return
        }
        if seconds >= minSeconds && quietFrames >= gapFrames {
            close(upTo: frames.count - quietFrames / 2, forced: false)
            return
        }
        if seconds >= maxSeconds {
            close(upTo: quietestFrame(), forced: true)
        }
    }

    /// Start of the quietest 100 ms in the last 2.5 s. Ties go to the latest
    /// position so a uniformly loud stretch is cut as late as possible.
    private func quietestFrame() -> Int {
        let lo = max(0, frames.count - searchFrames)
        var best = frames.count - 3, bestEnergy = Float.greatestFiniteMagnitude
        guard frames.count - lo > 5 else { return frames.count }
        for k in (lo + 2)..<(frames.count - 2) {
            let energy = frames[(k - 2)...(k + 2)].reduce(Float(0)) { $0 + $1.rms }
            if energy <= bestEnergy { bestEnergy = energy; best = k }
        }
        return best
    }

    /// Emit frames[0..<index] and carry the rest into a new chunk that starts there.
    private func close(upTo index: Int, forced: Bool) {
        let head = Array(frames[..<index]), rest = Array(frames[index...])
        let samples = head.flatMap(\.samples)
        let duration = Double(samples.count) / Double(rate)
        if samples.count >= 1_600 && head.contains(where: \.speech) {
            emit(AudioChunk(id: UUID(), samples: samples, source: source, start: started,
                            end: started.addingTimeInterval(duration), forced: forced))
        }
        started = started.addingTimeInterval(duration)
        frames = rest
        quietFrames = rest.reversed().prefix { !$0.speech }.count
        // Nothing but silence carried over: wait for speech instead of growing a
        // chunk the model would only hallucinate on.
        if !rest.isEmpty && !hasSpeech && quietFrames >= endpointFrames {
            preroll = Array(rest.suffix(prerollFrames)).map { ($0.samples, $0.rms) }
            frames.removeAll(keepingCapacity: true)
            active = false
        }
    }

    func flush() {
        if active && sampleCount >= 1_600 && hasSpeech { close(upTo: frames.count, forced: false) }
        frames.removeAll(keepingCapacity: true)
        preroll.removeAll(keepingCapacity: true)
        active = false
        quietFrames = 0
    }

    func discard() {
        frames.removeAll(keepingCapacity: true)
        preroll.removeAll(keepingCapacity: true)
        active = false
        quietFrames = 0
    }
}
