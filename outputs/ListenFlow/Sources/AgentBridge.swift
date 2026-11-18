import Foundation

/// What the `lstf` command line tool and the app tell each other, through small
/// files beside the sessions. The tool reads sessions straight from disk — the
/// app saves after every settled sentence — so the only thing it ever asks the
/// app to do is start a refinement. The app stays the one writer of sessions.
enum AgentBridge {
    struct Refining: Codable, Equatable {
        var sessionID: UUID
        var done: Int
        var total: Int
    }
    struct RefineResult: Codable, Equatable {
        var sessionID: UUID
        var ok: Bool
        var message: String
        var finished: Date
    }
    /// Rewritten by the app whenever something in it changes.
    struct State: Codable, Equatable {
        var pid: Int32
        var recording: Bool
        /// The session open in the window; it has a file only once it has content.
        var sessionID: UUID
        var source: String?
        var engine: String
        /// Sentences still being recognized after a pause.
        var pending: Int
        var refining: Refining?
        var lastRefine: RefineResult?
    }
    struct Request: Codable {
        var id = UUID()
        var action: String
        var session: UUID
        var created = Date()
    }
    struct Response: Codable {
        var ok: Bool
        var message: String
    }

    static let refine = "refine"
    /// A request nobody picked up within this long was made while the app was away.
    static let requestLifetime: TimeInterval = 30

    static var root: URL { SessionStore.folder.deletingLastPathComponent() }
    static var stateURL: URL { root.appendingPathComponent("state.json") }
    static var requestsURL: URL { root.appendingPathComponent("requests", isDirectory: true) }
    private static func requestURL(_ id: UUID) -> URL { requestsURL.appendingPathComponent(id.uuidString + ".json") }
    private static func responseURL(_ id: UUID) -> URL { requestsURL.appendingPathComponent(id.uuidString + ".done") }

    private static func write<T: Encodable>(_ value: T, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(value).write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    private static func read<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(type, from: $0) }
    }

    // MARK: App side

    static func publish(_ state: State) { try? write(state, to: stateURL) }
    static func withdraw() { try? FileManager.default.removeItem(at: stateURL) }

    /// Requests waiting for an answer, oldest first; stale ones are cleared away.
    static func pending(now: Date = Date()) -> [Request] {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: requestsURL, includingPropertiesForKeys: nil)) ?? []
        var requests: [Request] = []
        for file in files {
            let modified = ((try? fm.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date) ?? now
            if now.timeIntervalSince(modified) > requestLifetime { try? fm.removeItem(at: file); continue }
            guard file.pathExtension == "json", let request = read(Request.self, from: file) else { continue }
            if fm.fileExists(atPath: responseURL(request.id).path) { continue }
            requests.append(request)
        }
        return requests.sorted { $0.created < $1.created }
    }

    static func respond(to request: Request, ok: Bool, _ message: String) {
        try? write(Response(ok: ok, message: message), to: responseURL(request.id))
        try? FileManager.default.removeItem(at: requestURL(request.id))
    }

    // MARK: Tool side

    /// Nil when the app is not running: no state, or one left by a process that is gone.
    static func state() -> State? {
        guard let state = read(State.self, from: stateURL) else { return nil }
        return kill(state.pid, 0) == 0 || errno == EPERM ? state : nil
    }

    static func submit(_ request: Request) throws { try write(request, to: requestURL(request.id)) }

    /// The app's answer, once it has given one. Reading it clears it.
    static func response(to request: Request) -> Response? {
        guard let response = read(Response.self, from: responseURL(request.id)) else { return nil }
        try? FileManager.default.removeItem(at: responseURL(request.id))
        return response
    }

    static func cancel(_ request: Request) {
        try? FileManager.default.removeItem(at: requestURL(request.id))
        try? FileManager.default.removeItem(at: responseURL(request.id))
    }
}
