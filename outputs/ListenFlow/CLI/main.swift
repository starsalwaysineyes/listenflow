import Foundation

// Storage.swift reports failures with this type; the app defines it next to capture.
enum CaptureFailure: LocalizedError {
    case message(String)
    var errorDescription: String? { if case let .message(text) = self { return text }; return nil }
}

/// Everything that touches files: where the sessions are, what the app says it
/// is doing, and the requests the tool can make of it.
enum Tool {
    /// Leaves a request for the running app and waits for its answer; the app
    /// looks once a second.
    static func ask(_ request: AgentBridge.Request) throws -> AgentBridge.Response {
        do { try AgentBridge.submit(request) }
        catch { throw LstfError(message: "无法向听流发出请求：\(error.localizedDescription)") }
        let asked = Date()
        while Date().timeIntervalSince(asked) < 8 {
            Thread.sleep(forTimeInterval: 0.2)
            if let answer = AgentBridge.response(to: request) { return answer }
        }
        AgentBridge.cancel(request)
        throw LstfError(message: "听流没有应答。它可能正忙，或者版本太旧不支持这个命令。")
    }

    static func fail(_ error: LstfError) -> Never {
        FileHandle.standardError.write(Data(("lstf: " + error.message + (error.usage ? "\n用法见 lstf --help\n" : "\n")).utf8))
        exit(error.usage ? 2 : 1)
    }

    static func emit(_ object: Any) {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data()
        print(String(decoding: data, as: UTF8.self))
    }

    static func info(_ session: MeetingSession, _ state: AgentBridge.State?) -> Lstf.Info {
        let kept = AudioStore.unrefinedStreamSeconds(session.id), saved = AudioStore.streamSeconds(session.id)
        let open = state?.sessionID == session.id
        return Lstf.Info(session: session, keptSeconds: kept, savedSeconds: saved, localAudio: saved == 0 && AudioStore.hasAudio(session.id),
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

        case let .list(limit, group, json):
            var sessions = SessionStore.all()
            if let group {
                let names = GroupStore.names(sessions: sessions.map(\.group))
                sessions = sessions.filter { $0.group == group }
                guard names.contains(group) else {
                    throw LstfError(message: names.isEmpty ? "还没有任何分组。新建：lstf group create 分组名"
                                    : "没有叫「\(group)」的分组。现有的分组：\(names.map { "「\($0)」" }.joined(separator: "、"))")
                }
                if sessions.isEmpty && !json { print("分组「\(group)」里还没有会话。"); return }
            }
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
                          "linesNotIncluded": session.unorganizedCount, "writtenBy": organized.fromAgent ? "agent" : "app"])
                    return
                }
                print((picked.note.map { $0 + "\n" } ?? "") + Lstf.header(item))
                print("整理稿（\(organized.fromAgent ? "agent 通过 lstf 写入" : "听流里的模型整理")，覆盖到 \(through)" + (session.unorganizedCount > 0 ? "；之后还有 \(session.unorganizedCount) 行没有纳入" : "") + "）\n")
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
                let pictures = Lstf.images(session, in: range)
                if !pictures.isEmpty {
                    object["images"] = pictures.keys.sorted().flatMap { slot in
                        pictures[slot]!.map { Lstf.json($0, session: session, beforeLine: slot + 1) }
                    }
                }
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

        case let .hotwords(json):
            let words = HotwordStore.load()
            if json {
                let live = HotwordStore.live(words).count
                emit(["file": HotwordStore.file.path, "count": words.count, "usedLive": live,
                      "hotwords": words.enumerated().map { ["word": $0.element, "live": $0.offset < live] as [String: Any] }])
                return
            }
            print(Lstf.hotwordList(words), terminator: "")

        case let .addHotwords(words):
            let change: HotwordStore.Change
            do { change = try HotwordStore.add(words) }
            catch { throw LstfError(message: "热词没有保存下来：\(error.localizedDescription)") }
            print(Lstf.hotwordResult(change, adding: true, recording: state?.recording == true))
            if change.changed.isEmpty && !change.refused.isEmpty { exit(1) }

        case let .deleteHotwords(words):
            let change: HotwordStore.Change
            do { change = try HotwordStore.remove(words) }
            catch { throw LstfError(message: "热词没有保存下来：\(error.localizedDescription)") }
            print(Lstf.hotwordResult(change, adding: false, recording: state?.recording == true))

        case let .writeDraft(selector, file, through, replace):
            // The text first: a missing file should not depend on what sessions there are.
            let raw: Data
            if let file, file != "-" {
                guard let data = FileManager.default.contents(atPath: (file as NSString).expandingTildeInPath) else {
                    throw LstfError(message: "读不到文件 \(file)。")
                }
                raw = data
            } else {
                guard isatty(0) == 0 else {
                    throw LstfError(message: "整理稿的正文从 --file 或标准输入读取，例如 lstf draft write --file 整理稿.txt。", usage: true)
                }
                raw = FileHandle.standardInput.readDataToEndOfFile()
            }
            guard let decoded = String(data: raw, encoding: .utf8) else { throw LstfError(message: "整理稿不是 UTF-8 文本。") }
            guard let text = SessionStore.cleanDraft(decoded) else { throw LstfError(message: "整理稿是空的。") }
            guard text.count <= SessionStore.draftLimit else {
                throw LstfError(message: "整理稿太长（\(text.count) 字），上限是 \(SessionStore.draftLimit) 字。")
            }
            let picked = try Lstf.resolve(selector, sessions: SessionStore.all(), open: state?.sessionID, running: state != nil)
            let session = picked.session, short = Lstf.shortID(picked.session.id)
            let item = info(session, state)
            if let refining = state?.refining, refining.sessionID == session.id {
                throw LstfError(message: "会话 \(short) 正在精修，行号会变；完成后重新读一遍再写。")
            }
            let count: Int
            do { count = try SessionStore.draftCoverage(session, through: through, replace: replace, growing: item.recording) }
            catch { throw LstfError(message: error.localizedDescription) }
            if state != nil {
                // The app may have this session open; it writes the draft into its own copy.
                let answer = try ask(AgentBridge.Request(action: AgentBridge.draft, session: session.id, text: text, through: count, replace: replace))
                guard answer.ok else { throw LstfError(message: "会话 \(short) 的整理稿没有写入：\(answer.message)") }
            } else {
                do { try SessionStore.writeDraft(session.id, text: text, through: count, replace: replace) }
                catch { throw LstfError(message: "会话 \(short) 的整理稿没有写入：\(error.localizedDescription)") }
            }
            print(Lstf.draftWritten(session, count: count, characters: text.count, replaced: session.organized != nil, note: picked.note), terminator: "")

        case let .groups(json):
            let sessions = SessionStore.all()
            let groups = SessionGroups.groups(sessions.map(SessionSummary.init), names: GroupStore.names(sessions: sessions.map(\.group)))
            if json { emit(["groups": groups.map(Lstf.json)]); return }
            print(Lstf.groupList(groups), terminator: "")

        case let .createGroup(name):
            let existed = GroupStore.names(sessions: SessionStore.all().map(\.group)).contains(name)
            if !existed {
                if state != nil {
                    // The app keeps the list of groups while it runs, and shows the new one at once.
                    let answer = try ask(AgentBridge.Request(action: AgentBridge.groupCreate, session: UUID(), name: name))
                    guard answer.ok else { throw LstfError(message: "分组「\(name)」没有建成：\(answer.message)") }
                } else {
                    do { try GroupStore.add(name) }
                    catch { throw LstfError(message: "分组「\(name)」没有建成：\(error.localizedDescription)") }
                }
            }
            print(Lstf.groupCreated(name, existed: existed), terminator: "")

        case let .moveToGroup(group, selector):
            let sessions = SessionStore.all()
            let picked = try Lstf.resolve(selector, sessions: sessions, open: state?.sessionID, running: state != nil)
            let session = picked.session, short = Lstf.shortID(picked.session.id)
            if let group {
                let names = GroupStore.names(sessions: sessions.map(\.group))
                guard names.contains(group) else {
                    throw LstfError(message: "没有叫「\(group)」的分组。" + (names.isEmpty ? "还没有任何分组；" : "现有的分组：\(names.map { "「\($0)」" }.joined(separator: "、"))。")
                                    + "要新建就先 lstf group create \(group)")
                }
            }
            if session.group != group {
                if state != nil {
                    let answer = try ask(AgentBridge.Request(action: AgentBridge.groupMove, session: session.id, name: group))
                    guard answer.ok else { throw LstfError(message: "会话 \(short) 没有移动：\(answer.message)") }
                } else {
                    do { try SessionStore.update(session.id) { $0.group = group } }
                    catch { throw LstfError(message: "会话 \(short) 没有移动：\(error.localizedDescription)") }
                }
            }
            print(Lstf.groupMoved(session, from: session.group, to: group, note: picked.note), terminator: "")

        case let .rename(name, selector):
            let picked = try Lstf.resolve(selector, sessions: SessionStore.all(), open: state?.sessionID, running: state != nil)
            let session = picked.session, short = Lstf.shortID(picked.session.id)
            if session.title != name || session.renamed != true {
                if state != nil {
                    // The app may have this session open; a file changed under it would be overwritten.
                    let answer = try ask(AgentBridge.Request(action: AgentBridge.rename, session: session.id, name: name))
                    guard answer.ok else { throw LstfError(message: "会话 \(short) 没有改名：\(answer.message)") }
                } else {
                    do { try SessionStore.rename(session.id, to: name) }
                    catch { throw LstfError(message: "会话 \(short) 没有改名：\(error.localizedDescription)") }
                }
            }
            print(Lstf.renamed(session.id, from: session.title, to: name, note: picked.note), terminator: "")

        case let .refine(selector, wait):
            let picked = try Lstf.resolve(selector, sessions: SessionStore.all(), open: state?.sessionID, running: state != nil)
            let id = picked.session.id, short = Lstf.shortID(picked.session.id)
            guard state != nil else {
                throw LstfError(message: "听流没有在运行。精修由听流 app 执行，需要用户先打开听流。")
            }
            let request = AgentBridge.Request(action: AgentBridge.refine, session: id)
            let answer = try ask(request)
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
    HotwordStore.fileOverride = root.appendingPathComponent("hotwords.txt")
}
do { try Tool.run(try Lstf.parse(Array(CommandLine.arguments.dropFirst()))) }
catch let error as LstfError { Tool.fail(error) }
catch { Tool.fail(LstfError(message: error.localizedDescription)) }
