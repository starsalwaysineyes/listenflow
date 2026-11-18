import Foundation

/// One audio source's link to Doubao streaming recognition. Audio goes up as it is
/// captured; text comes back while the speaker is still talking (a preview that
/// keeps changing) and again, settled, when the sentence ends.
///
/// A connection lasts for one stretch of speech (see `SpeechGate`). Until a
/// sentence is settled its audio is kept, so when a connection breaks a new one
/// is opened and that audio is sent again — faster than real time, which the
/// service accepts — instead of losing what was being said.
final class VolcStream: @unchecked Sendable {
    struct Settings {
        var key: String
        var resourceID: String
        var hotwords: [String]
        var tables = VolcTables()
        /// Quiet after which the service settles a sentence.
        var endWindowMS = 1000
    }
    enum Activity: Equatable { case waiting, connecting, live, reconnecting }
    enum Event {
        case line(text: String, start: Date, end: Date)
        /// Text still being revised; empty when there is none.
        case partial(String)
        case activity(Activity)
        /// Recognition cannot continue; capture should stop.
        case failed(String)
        /// After `finish()`: every result that will ever arrive has arrived.
        case drained
    }

    static let endpoint = URL(string: "wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_async")!
    /// Trailing quiet sent before a connection is closed. The service settles a
    /// sentence after 1 s; the rest avoids reconnecting on every breath.
    static let closeAfterQuiet: TimeInterval = 3
    static let prerollSeconds = 0.6
    /// How long reconnecting is kept up, and so how much unsent audio may pile
    /// up, before the link is declared dead. A Wi-Fi blip should not end a class.
    static let maxBacklog: TimeInterval = 120
    /// Sent audio kept for a resend; comfortably longer than the longest sentence.
    static let resendWindow: TimeInterval = 45

    let source: String
    private let settings: Settings
    private let emit: (Event) -> Void
    /// Receives exactly the audio that is streamed, once, as 16-bit PCM; the date
    /// is set on the first piece of each stretch of speech. Called on the
    /// stream's own queue.
    private let keep: ((Data, Date?) -> Void)?
    private let queue = DispatchQueue(label: "ListenFlow.volc", qos: .userInitiated)
    private let urlSession = URLSession(configuration: .ephemeral)

    private final class Segment {
        var backlog: VolcBacklog
        var tracker = VolcUtteranceTracker()
        var task: URLSessionWebSocketTask?
        var generation = 0          // bumped per connection; late callbacks are ignored
        var ended = false           // capture has moved on; only the last packet remains
        var lastSentAt: Date?
        var attempts = 0
        var failingSince: Date?
        var retrying = false
        var partial = ""
        init(start: Date) { backlog = VolcBacklog(start: start) }
    }

    private var gate = SpeechGate()
    private var preroll: [Float] = []
    private var live: Segment?
    private var closing: [Segment] = []
    private var lastSpeech = Date.distantPast
    private var lastAudio = Date.distantPast
    private var speechMarks: [Date] = []
    private var finishing = false
    private var dead = false
    private var drained = false
    private var activity = Activity.waiting
    private var timer: DispatchSourceTimer?
    private let lock = NSLock()
    private var openSince: Date?
    /// Sent with each new connection, so a word added mid-session is in use
    /// from the next stretch of speech.
    private var hotwords: [String]

    /// `emit` is called on the main queue.
    init(source: String, settings: Settings, keep: ((Data, Date?) -> Void)? = nil, emit: @escaping (Event) -> Void) {
        self.source = source
        self.settings = settings
        self.hotwords = settings.hotwords
        self.keep = keep
        self.emit = emit
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.5, repeating: 0.5)
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer
    }

    deinit {
        timer?.cancel()
        urlSession.invalidateAndCancel()
    }

    /// When speech that has not been settled into a line yet began, if any. The
    /// echo filter waits for this before judging a microphone line.
    var openSpeechSince: Date? { lock.withLock { openSince } }

    func append(_ samples: [Float], end: Date) {
        queue.async { self.consume(samples, end: end) }
    }

    /// The list changed while recording; connections opened from now on use it.
    func setHotwords(_ words: [String]) {
        queue.async { self.hotwords = words }
    }

    /// Capture stopped: send what is left, wait for the last results, then `.drained`.
    func finish() {
        queue.async {
            self.finishing = true
            if let segment = self.live { self.end(segment) }
            self.checkDrained()
        }
    }

    /// Drop everything without waiting; nothing further is emitted.
    func cancel() {
        queue.async {
            self.dead = true
            self.drained = true
            for segment in self.closing + [self.live].compactMap({ $0 }) { self.close(segment) }
            self.live = nil
            self.closing.removeAll()
        }
    }

    /// Test hook for the replay harness: break the connection the way a network
    /// failure would, mid-sentence.
    func simulateDrop() {
        queue.async {
            for segment in self.closing + [self.live].compactMap({ $0 }) {
                segment.task?.cancel(with: .abnormalClosure, reason: nil)
            }
        }
    }

    // MARK: Audio in

    private func consume(_ samples: [Float], end: Date) {
        guard !dead, !finishing, !samples.isEmpty else { return }
        lastAudio = Date()
        let heard = gate.process(samples)
        if heard.any {
            lastSpeech = end
            // One mark per 200 ms is plenty for "speech is open since".
            if end.timeIntervalSince(speechMarks.last ?? .distantPast) > 0.2 { speechMarks.append(end) }
            publishOpenSince()
        }
        if let segment = live {
            let pcm = VolcFrame.pcm(samples)
            segment.backlog.append(pcm)
            self.keep?(pcm, nil)
            if end.timeIntervalSince(lastSpeech) > Self.closeAfterQuiet { self.end(segment) }
            else if Double(segment.backlog.unsent) / 32000 > Self.maxBacklog {
                fail("豆包语音识别连接中断，重连未成功。已识别的内容已保留。")
            } else { pump(segment) }
            return
        }
        preroll += samples
        let keep = Int(Self.prerollSeconds * 16000)
        if preroll.count > keep { preroll.removeFirst(preroll.count - keep) }
        guard heard.onset else { return }
        // Speech began: open a connection and lead with the moments before it,
        // so the first syllable is not clipped.
        let segment = Segment(start: end.addingTimeInterval(-Double(preroll.count) / 16000))
        let lead = VolcFrame.pcm(preroll)
        segment.backlog.append(lead)
        self.keep?(lead, segment.backlog.start)
        preroll.removeAll(keepingCapacity: true)
        lastSpeech = end
        live = segment
        connect(segment)
    }

    private func tick() {
        guard !dead else { return }
        let now = Date()
        // Some apps simply stop delivering buffers when paused; the service would
        // time the connection out, so close it properly first.
        if let segment = live, now.timeIntervalSince(lastAudio) > 1.5 { end(segment) }
        for segment in closing {
            if let sent = segment.lastSentAt, now.timeIntervalSince(sent) > 10 {
                // The last result never came. Keep the preview text rather than nothing.
                settlePartial(segment)
                complete(segment)
            }
        }
    }

    private func end(_ segment: Segment) {
        guard !segment.ended else { return }
        segment.ended = true
        if live === segment { live = nil }
        closing.append(segment)
        pump(segment)
        setActivity()
    }

    // MARK: Connection

    private func connect(_ segment: Segment) {
        guard !dead else { return }
        segment.generation += 1
        let generation = segment.generation
        segment.backlog.restart()
        segment.tracker = VolcUtteranceTracker()
        segment.lastSentAt = nil
        segment.retrying = false
        let connectID = UUID().uuidString
        var request = URLRequest(url: Self.endpoint)
        request.timeoutInterval = 15
        request.setValue(settings.key, forHTTPHeaderField: "X-Api-Key")
        request.setValue(settings.resourceID, forHTTPHeaderField: "X-Api-Resource-Id")
        request.setValue(connectID, forHTTPHeaderField: "X-Api-Connect-Id")
        let task = urlSession.webSocketTask(with: request)
        segment.task = task
        task.resume()
        if let frame = VolcFrame.fullRequest(VolcFrame.configuration(uid: connectID, hotwords: hotwords, tables: settings.tables, endWindowMS: settings.endWindowMS)) {
            send(frame, on: segment, generation)
        }
        receive(segment, generation)
        pump(segment)
        setActivity()
    }

    private func send(_ frame: Data, on segment: Segment, _ generation: Int) {
        guard let task = segment.task else { return }
        task.send(.data(frame)) { [weak self] error in
            guard let self, let error else { return }
            self.queue.async { self.connectionLost(segment, generation, task: task, error: error) }
        }
    }

    /// Everything not yet sent, in 200 ms packets; the final one carries the
    /// "last" flag, which makes the service settle what is still open.
    private func pump(_ segment: Segment) {
        guard segment.task != nil, !segment.retrying, segment.lastSentAt == nil else { return }
        while let packet = segment.backlog.nextPacket(flush: false) {
            if let frame = VolcFrame.audio(packet, last: false) { send(frame, on: segment, segment.generation) }
        }
        segment.backlog.trimSent(keeping: Self.resendWindow)
        guard segment.ended else { return }
        let tail = segment.backlog.nextPacket(flush: true) ?? Data()
        if let frame = VolcFrame.audio(tail, last: true) { send(frame, on: segment, segment.generation) }
        segment.lastSentAt = Date()
    }

    private func receive(_ segment: Segment, _ generation: Int) {
        guard let task = segment.task else { return }
        task.receive { [weak self] result in
            guard let self else { return }
            self.queue.async {
                guard segment.generation == generation, segment.task === task, !self.dead else { return }
                switch result {
                case .failure(let error): self.connectionLost(segment, generation, task: task, error: error)
                case .success(.data(let data)): self.handle(data, segment, generation)
                case .success: self.receive(segment, generation)
                }
            }
        }
    }

    private func handle(_ data: Data, _ segment: Segment, _ generation: Int) {
        let response: VolcFrame.Response
        do { response = try VolcFrame.parse(data) }
        catch { retry(segment, reason: error.localizedDescription); return }
        if response.isError {
            let code = response.errorCode ?? 0
            let message = "豆包语音识别失败（\(code)）：\(VolcFrame.errorMessage(response.payload))"
            switch code {
            // Configuration and account problems: trying again cannot help.
            case 45000001, 45000151, 45000292: fail(message + Self.hint(code))
            case 45000002: complete(segment)             // nothing but silence was sent
            default: retry(segment, reason: message)     // timeouts, overload
            }
            return
        }
        if response.messageType == 0x09, let result = VolcFrame.utterances(in: response.payload) {
            let update = segment.tracker.update(result.utterances, final: response.isLast)
            segment.attempts = 0
            segment.failingSince = nil
            for sentence in update.finished {
                let end = segment.backlog.date(ms: sentence.endMS)
                let start = min(segment.backlog.date(ms: sentence.startMS), end)
                speechMarks.removeAll { $0 <= end.addingTimeInterval(0.3) }
                emitMain(.line(text: sentence.text, start: start, end: end))
            }
            if let last = update.finished.last { segment.backlog.settle(throughMS: last.endMS) }
            publishOpenSince()
            setPartial(update.partial, segment)
            setActivity()
        }
        guard response.isLast else { receive(segment, generation); return }
        if segment.ended { complete(segment) }
        else {
            // The service closed the connection on its own while speech goes on
            // (a length limit, perhaps). Carry on with a fresh one from the first
            // audio it had not settled.
            close(segment)
            connect(segment)
        }
    }

    private func connectionLost(_ segment: Segment, _ generation: Int, task: URLSessionWebSocketTask, error: Error) {
        guard segment.generation == generation, segment.task === task, !dead, !segment.retrying else { return }
        if let status = (task.response as? HTTPURLResponse)?.statusCode, status != 101 {
            // The handshake was refused. URLSession hides the body of a refused
            // upgrade, and the body is where the service says why.
            segment.retrying = true
            explainRefusal(status: status) { [weak self] reason in
                guard let self else { return }
                self.queue.async {
                    segment.retrying = false
                    let message = "豆包语音识别连接被拒绝（HTTP \(status)）：\(reason)"
                    if status == 401 || status == 403 { self.fail(message) } else { self.retry(segment, reason: message) }
                }
            }
            return
        }
        retry(segment, reason: "豆包语音识别连接中断：\(error.localizedDescription)")
    }

    private func explainRefusal(status: Int, completion: @escaping (String) -> Void) {
        var components = URLComponents(url: Self.endpoint, resolvingAgainstBaseURL: false)!
        components.scheme = "https"
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 8
        request.setValue(settings.key, forHTTPHeaderField: "X-Api-Key")
        request.setValue(settings.resourceID, forHTTPHeaderField: "X-Api-Resource-Id")
        urlSession.dataTask(with: request) { data, _, _ in
            let reason = data.map(VolcFrame.errorMessage) ?? ""
            completion(reason.isEmpty ? "服务端没有给出原因" : reason)
        }.resume()
    }

    /// Open a replacement connection and send the unsettled audio again.
    private func retry(_ segment: Segment, reason: String) {
        guard !dead, !segment.retrying else { return }
        close(segment)
        segment.attempts += 1
        let since = segment.failingSince ?? Date()
        segment.failingSince = since
        guard Date().timeIntervalSince(since) < Self.maxBacklog else {
            fail(reason + "（已重试 \(segment.attempts - 1) 次，持续约 \(Int(Self.maxBacklog / 60)) 分钟）")
            return
        }
        segment.retrying = true
        setPartial("", segment)
        setActivity()
        let generation = segment.generation
        queue.asyncAfter(deadline: .now() + min(0.4 * pow(2, Double(segment.attempts - 1)), 3)) { [weak self] in
            guard let self, !self.dead, segment.generation == generation, segment.retrying else { return }
            self.connect(segment)
        }
    }

    private func close(_ segment: Segment) {
        segment.task?.cancel(with: .normalClosure, reason: nil)
        segment.task = nil
    }

    private func complete(_ segment: Segment) {
        close(segment)
        segment.generation += 1
        setPartial("", segment)
        let through = segment.backlog.end
        speechMarks.removeAll { $0 <= through }
        if live === segment { live = nil }
        closing.removeAll { $0 === segment }
        publishOpenSince()
        setActivity()
        checkDrained()
    }

    private func fail(_ message: String) {
        guard !dead else { return }
        // Whatever preview text exists is better kept than lost.
        for segment in closing + [live].compactMap({ $0 }) { settlePartial(segment); close(segment) }
        dead = true
        live = nil
        closing.removeAll()
        speechMarks.removeAll()
        publishOpenSince()
        emitMain(.partial(""))
        emitMain(.failed(message))
        if !drained { drained = true; emitMain(.drained) }
    }

    private func settlePartial(_ segment: Segment) {
        let text = segment.partial.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        emitMain(.line(text: text, start: segment.backlog.start, end: segment.backlog.end))
        segment.partial = ""
    }

    private func checkDrained() {
        guard finishing, !drained, live == nil, closing.isEmpty else { return }
        drained = true
        emitMain(.drained)
    }

    // MARK: Out

    private func setPartial(_ text: String, _ segment: Segment) {
        guard segment.partial != text else { return }
        segment.partial = text
        // Normally one segment is speaking at a time; when one is finishing as
        // the next begins, show both in order.
        emitMain(.partial((closing + [live].compactMap { $0 }).map(\.partial).joined()))
    }

    private func setActivity() {
        let segments = closing + [live].compactMap { $0 }
        let value: Activity = segments.isEmpty ? .waiting
            : segments.contains { $0.retrying } ? .reconnecting
            : segments.contains { $0.attempts == 0 && $0.task != nil } ? .live : .connecting
        guard value != activity else { return }
        activity = value
        emitMain(.activity(value))
    }

    private func publishOpenSince() {
        let value = speechMarks.first
        lock.withLock { openSince = value }
    }

    private func emitMain(_ event: Event) {
        DispatchQueue.main.async { self.emit(event) }
    }

    private static func hint(_ code: UInt32) -> String {
        switch code {
        case 45000292: "。当前资源 ID 没有可用额度，请在设置里确认资源 ID（小时版为 volc.seedasr.sauc.duration）。"
        default: ""
        }
    }
}
