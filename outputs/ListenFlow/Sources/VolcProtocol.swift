import Foundation
import zlib

/// Wire format of Volcengine's (Doubao) streaming speech recognition, kept free of
/// networking so it can be unit-tested. Every frame is a 4-byte header, a 4-byte
/// big-endian payload length, then the payload.
enum Gzip {
    /// Real gzip (header + trailer), which is what the service expects. Apple's
    /// Compression framework only produces raw deflate, hence zlib directly.
    static func compress(_ data: Data) -> Data? {
        var stream = z_stream()
        guard deflateInit2_(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, 15 + 16, 8, Z_DEFAULT_STRATEGY,
                            ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { return nil }
        defer { deflateEnd(&stream) }
        var out = Data(count: Int(deflateBound(&stream, uLong(data.count))) + 32)
        let status: Int32 = data.withUnsafeBytes { src in
            out.withUnsafeMutableBytes { dst in
                stream.next_in = UnsafeMutablePointer(mutating: src.bindMemory(to: Bytef.self).baseAddress)
                stream.avail_in = uInt(src.count)
                stream.next_out = dst.bindMemory(to: Bytef.self).baseAddress
                stream.avail_out = uInt(dst.count)
                return deflate(&stream, Z_FINISH)
            }
        }
        guard status == Z_STREAM_END else { return nil }
        out.count = Int(stream.total_out)
        return out
    }

    /// Bounded, so a corrupt or hostile frame cannot balloon in memory.
    static func decompress(_ data: Data, limit: Int = 32 << 20) -> Data? {
        guard !data.isEmpty else { return Data() }
        var stream = z_stream()
        guard inflateInit2_(&stream, 15 + 32, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { return nil }
        defer { inflateEnd(&stream) }
        var out = Data()
        var chunk = [UInt8](repeating: 0, count: 64 << 10)
        let ok: Bool = data.withUnsafeBytes { src in
            stream.next_in = UnsafeMutablePointer(mutating: src.bindMemory(to: Bytef.self).baseAddress)
            stream.avail_in = uInt(src.count)
            while true {
                let produced: Int = chunk.withUnsafeMutableBufferPointer { dst in
                    stream.next_out = dst.baseAddress
                    stream.avail_out = uInt(dst.count)
                    let status = inflate(&stream, Z_NO_FLUSH)
                    if status != Z_OK && status != Z_STREAM_END { return -1 }
                    let n = dst.count - Int(stream.avail_out)
                    return status == Z_STREAM_END ? -2 - n : n
                }
                if produced == -1 { return false }
                let done = produced <= -2
                let n = done ? -2 - produced : produced
                out.append(chunk, count: n)
                if out.count > limit { return false }
                if done { return true }
                if n == 0 && stream.avail_in == 0 { return false }   // truncated input
            }
        }
        return ok ? out : nil
    }
}

struct VolcUtterance: Equatable, Sendable {
    var text: String
    var definite: Bool
    /// Milliseconds from the start of the audio sent on this connection.
    var startMS: Int
    var endMS: Int
}

enum VolcProtocolError: LocalizedError {
    case malformed(String)
    var errorDescription: String? { if case let .malformed(text) = self { return "豆包返回的数据无法解析：\(text)" }; return nil }
}

enum VolcFrame {
    static let fullRequestHeader: [UInt8] = [0x11, 0x10, 0x11, 0x00]    // JSON, gzip
    static let audioHeader: [UInt8] = [0x11, 0x20, 0x01, 0x00]          // raw bytes, gzip
    static let lastAudioHeader: [UInt8] = [0x11, 0x22, 0x01, 0x00]

    struct Response {
        var messageType: UInt8
        var flags: UInt8
        var sequence: Int32?
        var errorCode: UInt32?
        var payload: Data
        var isError: Bool { messageType == 0x0f }
        /// Bit 1 marks the last response of the connection; a negative sequence says the same.
        var isLast: Bool { flags & 0x02 != 0 || (sequence ?? 0) < 0 }
    }

    private static func frame(_ header: [UInt8], _ payload: Data) -> Data? {
        guard let body = Gzip.compress(payload) else { return nil }
        var out = Data(header)
        withUnsafeBytes(of: UInt32(body.count).bigEndian) { out.append(contentsOf: $0) }
        out.append(body)
        return out
    }

    static func fullRequest(_ json: Data) -> Data? { frame(fullRequestHeader, json) }
    static func audio(_ pcm: Data, last: Bool) -> Data? { frame(last ? lastAudioHeader : audioHeader, pcm) }

    static func parse(_ data: Data) throws -> Response {
        let bytes = [UInt8](data)
        guard bytes.count >= 4 else { throw VolcProtocolError.malformed("帧太短") }
        let headerSize = Int(bytes[0] & 0x0f) * 4
        guard headerSize >= 4, bytes.count >= headerSize else { throw VolcProtocolError.malformed("帧头无效") }
        let type = bytes[1] >> 4, flags = bytes[1] & 0x0f, compression = bytes[2] & 0x0f
        var offset = headerSize
        func word() throws -> UInt32 {
            guard bytes.count >= offset + 4 else { throw VolcProtocolError.malformed("帧不完整") }
            defer { offset += 4 }
            return bytes[offset..<offset + 4].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        }
        var sequence: Int32?
        if flags & 0x01 != 0 { sequence = Int32(bitPattern: try word()) }
        var errorCode: UInt32?
        if type == 0x0f { errorCode = try word() }
        let size = Int(try word())
        guard bytes.count >= offset + size else { throw VolcProtocolError.malformed("负载不完整") }
        var payload = Data(bytes[offset..<offset + size])
        if compression == 0x01 {
            guard let plain = Gzip.decompress(payload) else { throw VolcProtocolError.malformed("解压失败") }
            payload = plain
        }
        return Response(messageType: type, flags: flags, sequence: sequence, errorCode: errorCode, payload: payload)
    }

    /// The first frame of a connection. `enable_nonstream` adds the service's own
    /// second, more accurate pass per sentence; only that pass marks a sentence
    /// `definite`. Hot words ride along as request context.
    static func configuration(uid: String, hotwords: [String], endWindowMS: Int = 1000) -> Data {
        var request: [String: Any] = [
            "model_name": "bigmodel", "enable_nonstream": true, "show_utterances": true, "enable_itn": true,
            "enable_punc": true, "enable_ddc": true, "end_window_size": endWindowMS, "result_type": "single"]
        // The streaming interface takes at most about 100 tokens of hot words.
        var budget = 80
        let words = hotwords.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.filter {
            budget -= $0.count
            return budget >= 0
        }
        if !words.isEmpty,
           let context = try? JSONSerialization.data(withJSONObject: ["hotwords": words.map { ["word": $0] }]) {
            request["corpus"] = ["context": String(decoding: context, as: UTF8.self)]
        }
        let object: [String: Any] = [
            "user": ["uid": uid],
            "audio": ["format": "pcm", "codec": "raw", "rate": 16000, "bits": 16, "channel": 1],
            "request": request]
        return (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    }

    /// 16-bit little-endian PCM from the app's float samples.
    static func pcm(_ samples: [Float]) -> Data {
        var out = Data(count: samples.count * 2)
        out.withUnsafeMutableBytes { raw in
            let dst = raw.bindMemory(to: Int16.self)
            for (i, v) in samples.enumerated() { dst[i] = Int16(max(-1, min(1, v)) * 32767).littleEndian }
        }
        return out
    }

    static func utterances(in payload: Data) -> (text: String, utterances: [VolcUtterance])? {
        guard let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let result = object["result"] as? [String: Any] else { return nil }
        let list = (result["utterances"] as? [[String: Any]] ?? []).compactMap { item -> VolcUtterance? in
            guard let text = item["text"] as? String else { return nil }
            return VolcUtterance(text: text, definite: item["definite"] as? Bool ?? false,
                                 startMS: (item["start_time"] as? NSNumber)?.intValue ?? 0,
                                 endMS: (item["end_time"] as? NSNumber)?.intValue ?? 0)
        }
        return (result["text"] as? String ?? "", list)
    }

    /// The reason carried by an error frame or a failed handshake body.
    static func errorMessage(_ payload: Data) -> String {
        if let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] {
            // Recording-file recognition wraps its reason in a "header" object.
            for source in [object, object["header"] as? [String: Any] ?? [:]] {
                for key in ["error", "message", "err_msg"] { if let text = source[key] as? String, !text.isEmpty { return text } }
            }
        }
        return String(decoding: payload.prefix(300), as: UTF8.self)
    }
}

/// The service repeats sentences across results (always in `full` mode, and a
/// settled sentence may ride along with the start of the next in `single` mode).
/// Each settled sentence must become exactly one transcript line.
struct VolcUtteranceTracker {
    private var settledMS = -1
    private var lastStartMS = -1
    private var lastText = ""

    /// `final` is the connection's last result: whatever is still open is as
    /// settled as it will ever be.
    mutating func update(_ list: [VolcUtterance], final: Bool) -> (finished: [VolcUtterance], partial: String, partialStartMS: Int?) {
        var finished: [VolcUtterance] = [], partial = "", partialStart: Int?
        for item in list {
            guard item.definite || final else {
                if partialStart == nil { partialStart = item.startMS }
                partial += item.text
                continue
            }
            // Timestamps identify a sentence — it ends after everything settled so
            // far, and a resend with a revised end still starts where it did.
            // Without timestamps fall back to its text.
            let isNew = item.endMS > 0 ? item.endMS > settledMS && item.startMS != lastStartMS : item.text != lastText
            guard isNew else { continue }
            settledMS = max(settledMS, item.endMS)
            lastStartMS = item.endMS > 0 ? item.startMS : lastStartMS
            lastText = item.text
            if !item.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { finished.append(item) }
        }
        return (finished, partial, partialStart)
    }
}

/// Audio of one stretch of speech that has not been settled into a sentence yet.
/// It is kept until then, so a dropped connection can be replaced and the audio
/// sent again without losing a word. Positions are bytes of 16 kHz 16-bit PCM.
struct VolcBacklog {
    static let bytesPerMS = 32
    static let packetBytes = 200 * bytesPerMS       // the service asks for 100–200 ms packets

    private(set) var pcm = Data()
    /// When the first retained sample was captured.
    private(set) var start: Date
    /// How much of `pcm` has gone out on the current connection.
    private(set) var sent = 0
    /// Bytes of the current connection's audio that came before `pcm`.
    private(set) var connectionOffset = 0

    init(start: Date) { self.start = start }

    var duration: TimeInterval { Double(pcm.count) / Double(Self.bytesPerMS * 1000) }
    var end: Date { start.addingTimeInterval(duration) }
    var unsent: Int { pcm.count - sent }

    /// Result timestamps count from the first audio of the connection.
    func date(ms: Int) -> Date {
        start.addingTimeInterval(Double(ms * Self.bytesPerMS - connectionOffset) / Double(Self.bytesPerMS * 1000))
    }

    mutating func append(_ data: Data) { pcm.append(data) }

    /// The next packet to send; `flush` also releases a final short one.
    mutating func nextPacket(flush: Bool) -> Data? {
        let available = unsent
        guard available >= Self.packetBytes || (flush && available > 0) else { return nil }
        let count = min(available, Self.packetBytes)
        let from = pcm.startIndex + sent
        sent += count
        return pcm.subdata(in: from..<from + count)
    }

    /// A sentence ending at `throughMS` is settled: its audio is no longer needed.
    mutating func settle(throughMS: Int) {
        var drop = min(max(0, throughMS * Self.bytesPerMS - connectionOffset), sent)
        drop -= drop % 2
        guard drop > 0 else { return }
        pcm.removeFirst(drop)
        start = start.addingTimeInterval(Double(drop) / Double(Self.bytesPerMS * 1000))
        sent -= drop
        connectionOffset += drop
    }

    /// No sentence stays open for long — the service cuts one off at about 20 s —
    /// so audio sent more than `seconds` ago cannot be needed again even if no
    /// sentence ever came back for it (music, noise).
    mutating func trimSent(keeping seconds: TimeInterval) {
        var drop = sent - Int(seconds * 1000) * Self.bytesPerMS
        drop -= drop % 2
        guard drop > 0 else { return }
        pcm.removeFirst(drop)
        start = start.addingTimeInterval(Double(drop) / Double(Self.bytesPerMS * 1000))
        sent -= drop
        connectionOffset += drop
    }

    /// A replacement connection starts from the first retained sample.
    mutating func restart() {
        sent = 0
        connectionOffset = 0
    }
}

/// Decides when there is speech worth sending. The hour-based plan bills every
/// second of audio sent, and the service drops a connection that receives nothing
/// for about 8 s, so silence is neither streamed nor waited through: a connection
/// lasts for one stretch of speech. Same test as `AudioChunker` — energy above
/// 200 Hz against a rolling noise floor — which was tuned on far-field speech.
struct SpeechGate {
    private var highPass = HighPass(cutoff: 200, rate: 16_000)
    private var floorHistory: [Float] = []
    private var carry: [Float] = []
    private var recent: [Bool] = []

    /// `any`: some 20 ms frame read as speech. `onset`: at least 60 ms of the last
    /// 200 ms did, so a single click does not open a connection.
    mutating func process(_ samples: [Float]) -> (any: Bool, onset: Bool) {
        carry += samples
        var any = false
        var offset = 0
        while carry.count - offset >= 320 {
            let rms = highPass.rms(Array(carry[offset..<offset + 320]))
            offset += 320
            floorHistory.append(rms)
            if floorHistory.count > 150 { floorHistory.removeFirst(floorHistory.count - 150) }
            let sorted = floorHistory.sorted()
            let speech = rms > min(max(0.0015, sorted[sorted.count / 10] * 2.0), 0.03)
            recent.append(speech)
            if recent.count > 10 { recent.removeFirst(recent.count - 10) }
            any = any || speech
        }
        carry.removeFirst(offset)
        return (any, recent.filter { $0 }.count >= 3)
    }
}
