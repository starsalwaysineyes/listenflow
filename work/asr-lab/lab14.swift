import Foundation

// Storage.swift reports failures with this type; the app defines it next to capture.
enum CaptureFailure: LocalizedError {
    case message(String)
    var errorDescription: String? { if case let .message(text) = self { return text }; return nil }
}

/// Low-level speech and the cloud engine, without the app: nothing is captured,
/// played or written to the user's sessions.
///   lab14 gate <pcm>         which stretches the app would stream ("start end" in samples)
///   lab14 auc <pcm> <json>   Doubao recording-file recognition of the whole file, as refinement sends it
@main struct Lab14 {
    static func main() async {
        let args = CommandLine.arguments
        guard args.count >= 3, let data = FileManager.default.contents(atPath: args[2]) else {
            FileHandle.standardError.write(Data("usage: lab14 gate <pcm> | auc <pcm> <json>\n".utf8)); exit(2)
        }
        switch args[1] {
        case "gate":
            let samples = data.withUnsafeBytes { $0.bindMemory(to: Int16.self).map { Float($0) / 32768 } }
            // VolcStream.consume, without the network: a connection opens when speech
            // begins (led by the 0.6 s before it) and closes after 3 s without any.
            var gate = SpeechGate()
            let buffer = 640, preKeep = Int(VolcStream.prerollSeconds * 16000), quiet = Int(VolcStream.closeAfterQuiet * 16000)
            var live: Int?, lastSpeech = -quiet * 2, preroll = 0, offset = 0
            while offset < samples.count {
                let n = min(buffer, samples.count - offset), end = offset + n
                let heard = gate.process(Array(samples[offset..<end]))
                if heard.any { lastSpeech = end }
                if let start = live {
                    if end - lastSpeech > quiet { print(start, end); live = nil; preroll = 0 }
                } else {
                    preroll = min(preroll + n, preKeep)
                    if heard.onset { live = end - preroll; preroll = 0; lastSpeech = end }
                }
                offset = end
            }
            if let start = live { print(start, samples.count) }
        case "auc":
            guard args.count >= 4, let key = ProcessInfo.processInfo.environment["VOLC_ASR_API_KEY"], !key.isEmpty else {
                FileHandle.standardError.write(Data("auc needs VOLC_ASR_API_KEY and an output path\n".utf8)); exit(2)
            }
            let span = AudioSpan(offset: 0, count: data.count / 2, start: Date())
            let body = VolcRecording.submitBody(wav: VolcRecording.wav([data], spans: [span]), uid: UUID().uuidString,
                                                hotwords: [], splitOnPauses: false)
            do {
                let started = Date()
                let found = try await VolcFileClient(key: key, resourceID: "volc.seedasr.auc")
                    .recognize(body: body, seconds: Double(span.count) / 16000)
                let rows = found.map { ["text": $0.text, "start": $0.startMS, "end": $0.endMS] as [String: Any] }
                try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted]).write(to: URL(fileURLWithPath: args[3]))
                print("\(found.count) 句，\(String(format: "%.0f", Date().timeIntervalSince(started))) 秒返回")
            } catch { FileHandle.standardError.write(Data("失败：\(error.localizedDescription)\n".utf8)); exit(1) }
        default: exit(2)
        }
    }
}
