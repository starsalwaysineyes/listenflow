import AppKit
import AVFoundation
import ScreenCaptureKit
import CoreMedia

enum CaptureFailure: LocalizedError {
    case message(String)
    var errorDescription: String? { if case let .message(text) = self { return text }; return nil }
}

/// App audio and microphone have separate lifetimes and separate chunkers.
final class CaptureEngine: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    var onChunk: ((AudioChunk) -> Void)?
    var onLevel: ((String, Float) -> Void)?
    var onError: ((String) -> Void)?
    private let queue = DispatchQueue(label: "ListenFlow.capture", qos: .userInitiated)
    private var stream: SCStream?
    private var micEngine: AVAudioEngine?
    private var acceptingApp = false
    private var acceptingMic = false
    private var appChunker: AudioChunker?
    private var micChunker: AudioChunker?
    private var appConverter: AVAudioConverter?
    private var micConverter: AVAudioConverter?
    private var lastLevels: [String: Date] = [:]
    private var idleTimer: DispatchSourceTimer?
    private var lastAppBuffer = Date.distantPast
    private var lastMicBuffer = Date.distantPast
    private let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                             sampleRate: 16000, channels: 1, interleaved: false)!

    @MainActor
    func start(pid: pid_t, name: String) async throws {
        let content: SCShareableContent
        do { content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false) }
        catch { throw CaptureFailure.message("需要允许「屏幕与系统音频录制」。请在系统设置中授权听流，然后重新打开应用。\n\(error.localizedDescription)") }
        guard let display = content.displays.first,
              let app = content.applications.first(where: { $0.processID == pid }) else {
            throw CaptureFailure.message("所选 App 已退出或暂时不可采集。请刷新列表并重新选择。")
        }
        let filter = SCContentFilter(display: display, including: [app], exceptingWindows: [])
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.captureMicrophone = false  // Microphone is NEVER included in this stream.
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48000
        config.channelCount = 2
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.queueDepth = 3
        let newStream = SCStream(filter: filter, configuration: config, delegate: self)
        // No screen/video output is attached or persisted.
        try newStream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        queue.sync {
            appChunker = AudioChunker(source: name) { [weak self] in self?.onChunk?($0) }
            appConverter = nil
            acceptingApp = true
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + 0.3, repeating: 0.3)
            timer.setEventHandler { [weak self] in
                guard let self else { return }
                let now = Date()
                // Some apps stop delivering buffers entirely when playback pauses.
                if self.acceptingApp && now.timeIntervalSince(self.lastAppBuffer) > 0.6 { self.appChunker?.flush() }
                if self.acceptingMic && now.timeIntervalSince(self.lastMicBuffer) > 0.6 { self.micChunker?.flush() }
            }
            idleTimer = timer
            timer.resume()
        }
        stream = newStream
        do { try await newStream.startCapture() }
        catch {
            queue.sync { acceptingApp = false; appChunker?.discard(); idleTimer?.cancel(); idleTimer = nil }
            stream = nil
            throw error
        }
    }

    @MainActor
    func setMicrophone(_ enabled: Bool) async throws {
        if !enabled {
            // Close the hardware input first; queued buffers are rejected by the gate.
            queue.sync { acceptingMic = false }
            if let engine = micEngine {
                engine.inputNode.removeTap(onBus: 0)
                engine.stop()
            }
            micEngine = nil
            queue.sync {
                micChunker?.flush() // Only speech captured before the switch was turned off.
                micChunker = nil
                micConverter = nil
            }
            onLevel?("麦克风", 0)
            return
        }
        guard micEngine == nil else { return }
        guard await AVCaptureDevice.requestAccess(for: .audio) else {
            throw CaptureFailure.message("麦克风权限未获允许；App 音频仍可继续转写。")
        }
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw CaptureFailure.message("没有可用的麦克风输入设备。")
        }
        queue.sync {
            micChunker = AudioChunker(source: "麦克风") { [weak self] in self?.onChunk?($0) }
            micConverter = nil
            acceptingMic = true
        }
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            // AVAudioEngine owns its buffer; copy before leaving the tap callback.
            guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else { return }
            copy.frameLength = buffer.frameLength
            let src = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
            let dst = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
            for (s, d) in zip(src, dst) { if let sp = s.mData, let dp = d.mData { memcpy(dp, sp, Int(s.mDataByteSize)) } }
            let captured = Date()
            self.queue.async {
                guard self.acceptingMic else { return }
                self.consume(copy, microphone: true, at: captured)
            }
        }
        do { try engine.start(); micEngine = engine }
        catch {
            input.removeTap(onBus: 0)
            queue.sync { acceptingMic = false; micChunker?.discard() }
            throw error
        }
    }

    @MainActor
    func stop() async {
        try? await setMicrophone(false)
        if let stream { try? await stream.stopCapture() }
        stream = nil
        queue.sync {
            acceptingApp = false
            appChunker?.flush()
            appChunker = nil
            appConverter = nil
            idleTimer?.cancel()
            idleTimer = nil
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onError?("App 音频采集中断：\(error.localizedDescription)")
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, acceptingApp, sampleBuffer.isValid,
              let description = sampleBuffer.formatDescription else { return }
        let format = AVAudioFormat(cmAudioFormatDescription: description)
        guard let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(sampleBuffer.numSamples)) else { return }
        pcm.frameLength = AVAudioFrameCount(sampleBuffer.numSamples)
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(sampleBuffer, at: 0,
                      frameCount: Int32(sampleBuffer.numSamples), into: pcm.mutableAudioBufferList)
        guard status == noErr else { return }
        consume(pcm, microphone: false, at: Date())
    }

    private func consume(_ pcm: AVAudioPCMBuffer, microphone: Bool, at date: Date) {
        if microphone { lastMicBuffer = date } else { lastAppBuffer = date }
        var converter = microphone ? micConverter : appConverter
        if converter == nil || converter!.inputFormat != pcm.format {
            converter = AVAudioConverter(from: pcm.format, to: outputFormat)
            if microphone { micConverter = converter } else { appConverter = converter }
        }
        guard let converter,
              let converted = AVAudioPCMBuffer(pcmFormat: outputFormat,
                frameCapacity: AVAudioFrameCount(ceil(Double(pcm.frameLength) * 16000 / pcm.format.sampleRate)) + 64) else { return }
        var supplied = false
        var error: NSError?
        converter.convert(to: converted, error: &error) { _, status in
            if supplied { status.pointee = .noDataNow; return nil }
            supplied = true
            status.pointee = .haveData
            return pcm
        }
        guard error == nil, converted.frameLength > 0, let floats = converted.floatChannelData?[0] else { return }
        let samples = Array(UnsafeBufferPointer(start: floats, count: Int(converted.frameLength)))
        let source = microphone ? "麦克风" : "App"
        if date.timeIntervalSince(lastLevels[source] ?? .distantPast) > 0.2 {
            let rms = sqrt(samples.reduce(Float(0)) { $0 + $1 * $1 } / Float(samples.count))
            onLevel?(source, min(1, rms * 8))
            lastLevels[source] = date
        }
        (microphone ? micChunker : appChunker)?.append(samples, end: date)
    }
}
