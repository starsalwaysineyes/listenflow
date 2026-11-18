import Foundation

// Storage.swift reports failures with this type; the app defines it next to capture.
enum CaptureFailure: LocalizedError {
    case message(String)
    var errorDescription: String? { if case let .message(text) = self { return text }; return nil }
}

/// Everything that touches files: where the sessions are, what the app says it
/// is doing, and the one request the tool can make of it.
enum Tool {
    static func fail(_ error: LstfError) -> Never {
        FileHandle.standardError.write(Data(("lstf: " + error.message + (error.usage ? "\n用法见 lstf --help\n" : "\n")).utf8))
        exit(error.usage ? 2 : 1)
    }

    static func emit(_ object: Any) {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data()
        print(String(decoding: data, as: UTF8.self))
    }

    static func info(_ session: MeetingSession, _ state: AgentBridge.State?) -> Lstf.Info {
        let kept = AudioStore.streamSeconds(session.id)
        let open = state?.sessionID == session.id
        return Lstf.Info(session: session, keptSeconds: kept, localAudio: kept == 0 && AudioStore.hasAudio(session.id),
                         open: open, recording: open && state?.recording == true, refining: state?.refining)
    }

    static func run(_ command: Lstf.Command) throws {
        let state = AgentBridge.state()
        switch command {
        case .help:
            print(Lstf.help)

        case let .status(json):
            let sessions = SessionStore.all()
            let open = state.flatMap { state in sessions.first { $0.id == state.sessionID } }
            if json {
                var object: [String: Any] = ["running": state != nil, "sessions": sessions.count]
                if let state {
                    object["recording"] = state.recording
                    object["engine"] = state.engine
                    object["pendingSentences"] = state.pending
                    if let source = state.source { object["source"] = source }
                    if let open { object["session"] = Lstf.json(info(open, state)) }
                    if let refining = state.refining {
                        object["refining"] = ["session": Lstf.shortID(refining.sessionID), "done": refining.done, "total": refining.total]
                    }
                    if let last = state.lastRefine {
                        object["lastRefine"] = ["session": Lstf.shortID(last.sessionID), "ok": last.ok, "message": last.message,
                                                "finished": Lstf.iso(last.finished)]
                    }
                }
                emit(object)
                return
            }
            guard let state else {
                print("听流没有在运行。历史会话仍然可以读：lstf list（共 \(sessions.count) 场）")
                return
            }
            print("听流正在运行，识别引擎：\(state.engine)")
            print(state.recording ? "正在录制：\(state.source ?? "")" : "没有在录制" + (state.pending > 0 ? "（还有 \(state.pending) 句在识别）" : ""))
            if let open { print("当前会话：" + Lstf.listRow(info(open, state))) }
            else { print("当前会话还没有内容。最近的会话用 lstf list 查看（共 \(sessions.count) 场）") }
            if let refining = state.refining, refining.sessionID != open?.id {
                print("正在精修：会话 \(Lstf.shortID(refining.sessionID))，\(refining.done)/\(refining.total) 段")
            }
            if let last = state.lastRefine {
                print("上次精修（会话 \(Lstf.shortID(last.sessionID))，\(Lstf.stamp(last.finished))）\(last.ok ? "" : "失败")：\(last.message)")
            }

        case let .list(limit, json):
            let sessions = SessionStore.all()
            let shown = sessions.prefix(limit).map { info($0, state) }
            if json { emit(["total": sessions.count, "sessions": shown.map(Lstf.json)]); return }
            if sessions.isEmpty { print("还没有任何会话。"); return }
            shown.forEach { print(Lstf.listRow($0)) }
            if sessions.count > shown.count { print("— 共 \(sessions.count) 场，只列出最近 \(shown.count) 场；加 --limit 看更多。") }

        case let .read(options):
            let picked = try Lstf.resolve(options.session, sessions: SessionStore.all(), open: state?.sessionID, running: state != nil)
            let item = info(picked.session, state)
            let session = picked.session
            if options.organized {
                guard let organized = session.organized else {
                    throw LstfError(message: "会话 \(Lstf.shortID(session.id)) 还没有整理稿（需要用户在听流里点「整理稿」生成）。原始转写用 lstf read \(Lstf.shortID(session.id))。")
                }
                let through = Lstf.clock(organized.through.timeIntervalSince(session.created))
                if options.json {
                    emit(["session": Lstf.json(item), "organized": organized.text, "through": through,
                          "linesNotIncluded": session.unorganizedCount])
                    return
                }
                print((picked.note.map { $0 + "\n" } ?? "") + Lstf.header(item))
                print("整理稿（AI 整理，覆盖到 \(through)" + (session.unorganizedCount > 0 ? "；之后还有 \(session.unorganizedCount) 行没有纳入" : "") + "）\n")
                print(organized.text)
                return
            }
            var offset = options.offset
            if let minutes = options.minutes {
                let reference = item.recording ? Date() : session.lines.last?.end ?? Date()
                offset = Lstf.firstLine(within: minutes, of: reference, in: session.lines)
            }
            let range = Lstf.window(total: session.lines.count, offset: offset, limit: options.limit, tail: options.tail)
            if options.json {
                var object: [String: Any] = [
                    "session": Lstf.json(item), "offset": range.lowerBound + 1, "count": range.count, "total": session.lines.count,
                    "lines": range.map { Lstf.json(session.lines[$0], number: $0 + 1, created: session.created) }]
                if range.upperBound < session.lines.count || item.recording { object["nextOffset"] = range.upperBound + 1 }
                if let note = picked.note { object["note"] = note }
                emit(object)
                return
            }
            print(Lstf.page(item, range: range, note: picked.note), terminator: "")

        case let .search(text, selector, limit, json):
            var sessions = SessionStore.all()
            if let selector {
                sessions = [try Lstf.resolve(selector, sessions: sessions, open: state?.sessionID, running: state != nil).session]
            }
            let found = Lstf.search(text, in: sessions, limit: limit)
            let byID = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })
            if json {
                emit(["query": text, "truncated": found.more, "hits": found.hits.compactMap { hit -> [String: Any]? in
                    guard let session = byID[hit.session] else { return nil }
                    var object = Lstf.json(session.lines[hit.number - 1], number: hit.number, created: session.created)
                    object["session"] = Lstf.shortID(session.id)
                    object["title"] = session.title
                    return object
                }])
                return
            }
            if found.hits.isEmpty { print("没有找到包含「\(text)」的句子（查了 \(sessions.count) 场会话）。"); return }
            var last: UUID?
            for hit in found.hits {
                guard let session = byID[hit.session] else { continue }
                if last != session.id {
                    print((last == nil ? "" : "\n") + "会话 \(Lstf.shortID(session.id))「\(session.title)」\(Lstf.stamp(session.lines.first?.start ?? session.created))")
                    last = session.id
                }
                print(Lstf.row(session.lines[hit.number - 1], number: hit.number, created: session.created, width: String(session.lines.count).count))
            }
            print("\n— \(found.hits.count) 处" + (found.more ? "，还有更多：加 --limit 或用 --session 缩小范围。" : "。")
                  + "看上下文：lstf read <会话ID> --offset <行号> --limit 20")

        case let .refine(selector, wait):
            let picked = try Lstf.resolve(selector, sessions: SessionStore.all(), open: state?.sessionID, running: state != nil)
            let id = picked.session.id, short = Lstf.shortID(picked.session.id)
            guard state != nil else {
                throw LstfError(message: "听流没有在运行。精修由听流 app 执行，需要用户先打开听流。")
            }
            let request = AgentBridge.Request(action: AgentBridge.refine, session: id)
            do { try AgentBridge.submit(request) }
            catch { throw LstfError(message: "无法向听流发出请求：\(error.localizedDescription)") }
            var answer: AgentBridge.Response?
            let asked = Date()
            while answer == nil && Date().timeIntervalSince(asked) < 8 {
                Thread.sleep(forTimeInterval: 0.2)
                answer = AgentBridge.response(to: request)
            }
            guard let answer else {
                AgentBridge.cancel(request)
                throw LstfError(message: "听流没有应答。它可能正忙，或者版本太旧不支持这个命令。")
            }
            guard answer.ok else { throw LstfError(message: "会话 \(short) 没有开始精修：\(answer.message)") }
            guard wait else {
                print("会话 \(short) 已开始精修。进度用 lstf status 查看；完成后重新读：lstf read \(short)（行号会变）。")
                return
            }
            var shown = ""
            while true {
                Thread.sleep(forTimeInterval: 1)
                guard let now = AgentBridge.state() else { throw LstfError(message: "听流在精修过程中退出了。已完成的部分保留，可以重新打开听流再试。") }
                if let refining = now.refining, refining.sessionID == id {
                    let progress = "\(refining.done)/\(refining.total)"
                    if progress != shown && refining.total > 0 {
                        shown = progress
                        FileHandle.standardError.write(Data("精修中 \(progress) 段\n".utf8))
                    }
                    continue
                }
                if let last = now.lastRefine, last.sessionID == id, last.finished >= request.created.addingTimeInterval(-1) {
                    guard last.ok else { throw LstfError(message: last.message) }
                    print(last.message)
                    print("重新读：lstf read \(short)")
                    return
                }
            }
        }
    }
}

// Tests point the tool at a folder of their own.
if let home = ProcessInfo.processInfo.environment["LSTF_HOME"], !home.isEmpty {
    let root = URL(fileURLWithPath: home, isDirectory: true)
    SessionStore.folderOverride = root.appendingPathComponent("Sessions", isDirectory: true)
    AudioStore.rootOverride = root.appendingPathComponent("audio", isDirectory: true)
}
do { try Tool.run(try Lstf.parse(Array(CommandLine.arguments.dropFirst()))) }
catch let error as LstfError { Tool.fail(error) }
catch { Tool.fail(LstfError(message: error.localizedDescription)) }
