import Foundation

struct AudioChunk: Sendable {
    let id: UUID
    let samples: [Float]
    let source: String
    let start: Date
    let end: Date
}

/// Called only on the capture queue. Split on silence, with a four-second ceiling.
/// A short pre-roll preserves consonants; bounded windows avoid latency drift.
final class AudioChunker {
    let source: String
    let emit: (AudioChunk) -> Void
    let rate = 16_000
    private var samples: [Float] = []
    private var preroll: [Float] = []
    private var active = false
    private var quietSamples = 0
    private var started = Date()
    private var lastEnd = Date()
    init(source: String, emit: @escaping (AudioChunk) -> Void) {
        self.source = source
        self.emit = emit
    }

    func append(_ input: [Float], end: Date = Date()) {
        guard !input.isEmpty else { return }
        // Small frames make endpointing independent of the input device's buffer size.
        let frame = 320
        for offset in stride(from: 0, to: input.count, by: frame) {
            let part = Array(input[offset..<min(offset + frame, input.count)])
            let partEnd = end.addingTimeInterval(-Double(input.count - offset - part.count) / Double(rate))
            consume(part, end: partEnd)
        }
    }

    private func consume(_ part: [Float], end: Date) {
        lastEnd = end
        let rms = sqrt(part.reduce(Float(0)) { $0 + $1 * $1 } / Float(part.count))
        let speech = rms > 0.003
        if !active {
            if !speech {
                preroll.append(contentsOf: part)
                if preroll.count > 3_200 { preroll.removeFirst(preroll.count - 3_200) }
                return
            }
            active = true
            samples = preroll
            preroll.removeAll(keepingCapacity: true)
            started = end.addingTimeInterval(-Double(samples.count + part.count) / Double(rate))
        }
        samples.append(contentsOf: part)
        quietSamples = speech ? 0 : quietSamples + part.count
        if samples.count >= rate * 4 || (quietSamples >= 8_000 && samples.count >= 12_800) {
            flush()
        }
    }

    func flush() {
        if active && samples.count >= 1_600 {
            emit(AudioChunk(id: UUID(), samples: samples, source: source, start: started, end: lastEnd))
        }
        samples.removeAll(keepingCapacity: true)
        preroll.removeAll(keepingCapacity: true)
        active = false
        quietSamples = 0
    }

    func discard() {
        samples.removeAll(keepingCapacity: true)
        preroll.removeAll(keepingCapacity: true)
        active = false
        quietSamples = 0
    }
}
