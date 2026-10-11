import Foundation

final class ASRBridge: @unchecked Sendable {
    var onEvent: (([String: Any]) -> Void)?
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var errors: FileHandle?
    private let writeQueue = DispatchQueue(label: "ListenFlow.worker.write")
    private let readQueue = DispatchQueue(label: "ListenFlow.worker.read")
    private var buffer = Data()
    private var generation = UUID()

    func start(python: String, model: String) throws {
        shutdown()
        guard FileManager.default.isExecutableFile(atPath: python) else {
            throw CaptureFailure.message("找不到 Python 环境，请在设置中选择已安装 mlx-audio 的 Python。")
        }
        guard let script = Bundle.main.url(forResource: "asr_worker", withExtension: "py") else {
            throw CaptureFailure.message("应用缺少 ASR 组件，请重新构建。")
        }
        let process = Process()
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        let token = UUID()
        generation = token
        process.executableURL = URL(fileURLWithPath: python)
        process.arguments = ["-u", script.path, "--model", model]
        var env = ProcessInfo.processInfo.environment
        env["HF_HUB_OFFLINE"] = "1"
        env["HF_HUB_DISABLE_TELEMETRY"] = "1"
        env["TOKENIZERS_PARALLELISM"] = "false"
        process.environment = env
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        input = stdin.fileHandleForWriting
        output = stdout.fileHandleForReading
        errors = stderr.fileHandleForReading
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let self else { return }
            self.readQueue.async {
                guard self.generation == token else { return }
                self.buffer.append(data)
                while let newline = self.buffer.firstIndex(of: 10) {
                    let line = self.buffer[..<newline]
                    self.buffer.removeSubrange(...newline)
                    if let event = try? JSONSerialization.jsonObject(with: line) as? [String: Any] {
                        DispatchQueue.main.async { [weak self] in
                            guard let self, self.generation == token else { return }
                            self.onEvent?(event)
                        }
                    }
                }
            }
        }
        // Drain library diagnostics so a full stderr pipe can never block recognition.
        stderr.fileHandleForReading.readabilityHandler = { handle in _ = handle.availableData }
        process.terminationHandler = { [weak self] process in
            DispatchQueue.main.async {
                guard let self, self.generation == token else { return }
                self.onEvent?(["type": "fatal", "message": "ASR 进程已退出（\(process.terminationStatus)）。请重新加载模型。"])
            }
        }
        self.process = process
        try process.run()
    }

    func submit(_ chunk: AudioChunk, language: String, hotwords: String) {
        let bytes = chunk.samples.withUnsafeBytes { Data($0) }
        let payload: [String: Any] = ["type": "transcribe", "id": chunk.id.uuidString,
            "audio": bytes.base64EncodedString(), "language": language,
            "hotwords": hotwords.split(whereSeparator: { $0 == "," || $0 == "，" || $0 == "\n" }).map(String.init)]
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        let handle = input
        let token = generation
        writeQueue.async { [weak self] in
            do { try handle?.write(contentsOf: data + Data([10])) }
            catch {
                DispatchQueue.main.async {
                    guard let self, self.generation == token else { return }
                    self.onEvent?(["type": "fatal", "message": "无法向 ASR 发送音频：\(error.localizedDescription)"])
                }
            }
        }
    }

    func shutdown() {
        generation = UUID()
        output?.readabilityHandler = nil
        errors?.readabilityHandler = nil
        try? input?.close()
        input = nil
        if let process, process.isRunning { process.terminate() }
        process = nil
        output = nil
        errors = nil
        readQueue.sync { buffer.removeAll() }
    }
    deinit { shutdown() }
}
