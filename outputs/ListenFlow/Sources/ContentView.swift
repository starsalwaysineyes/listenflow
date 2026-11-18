import SwiftUI
import AppKit

/// Colours that follow the system appearance. Two of them carry meaning: what
/// the Mac plays and what the microphone hears are told apart by colour
/// everywhere — the bar beside a paragraph, a level meter, a label.
enum Palette {
    private static func rgb(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
    private static func dynamic(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? rgb(dark) : rgb(light) })
    }
    static let page = dynamic(0xFFFFFF, 0x1E1F21)
    static let rail = dynamic(0xF1F2F0, 0x161718)
    static let ink = Color(nsColor: .labelColor)
    static let muted = Color(nsColor: .secondaryLabelColor)
    static let faint = Color(nsColor: .tertiaryLabelColor)
    static let hairline = Color(nsColor: .separatorColor)
    /// What the Mac plays.
    static let stream = dynamic(0x0B7468, 0x5FD0BF)
    /// What the microphone hears: the user's own side.
    static let voice = dynamic(0xAD5710, 0xF0A75E)
    static let live = dynamic(0xD2362F, 0xFF6B62)
    static let warning = dynamic(0xB36200, 0xF5B14C)
    static func source(_ name: String) -> Color { name == EchoFilter.micSource ? voice : stream }
}

private enum Format {
    static let zh = Locale(identifier: "zh_CN")
    private static func formatter(_ pattern: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = zh
        formatter.dateFormat = pattern
        return formatter
    }
    private static let dayFormat = formatter("M月d日 EEE")
    private static let timeFormat = formatter("HH:mm")

    static func day(_ date: Date, now: Date = Date()) -> String {
        let calendar = Calendar.current
        if calendar.isDate(date, inSameDayAs: now) { return "今天" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) { return "昨天" }
        return dayFormat.string(from: date)
    }
    static func time(_ date: Date) -> String { timeFormat.string(from: date) }
    static func length(_ seconds: TimeInterval) -> String {
        let minutes = Int((seconds / 60).rounded())
        if seconds < 45 { return "不到 1 分钟" }
        if minutes < 60 { return "\(max(minutes, 1)) 分钟" }
        return minutes % 60 == 0 ? "\(minutes / 60) 小时" : "\(minutes / 60) 小时 \(minutes % 60) 分钟"
    }
}

/// A session's name being typed over where it is shown, the way a file is
/// renamed in Finder: Return or clicking elsewhere keeps what was typed,
/// Escape leaves the old name. `done` gets nil when nothing should change.
private struct NameField: View {
    let initial: String
    let size: CGFloat
    let weight: Font.Weight
    let done: (String?) -> Void
    @State private var text = ""
    @State private var finished = false
    @FocusState private var focused: Bool

    var body: some View {
        TextField("给这场会话起个名字", text: $text)
            .textFieldStyle(.plain).font(.system(size: size, weight: weight))
            .focused($focused)
            .onSubmit { finish(text) }
            .onExitCommand { finish(nil) }
            .onChange(of: focused) { _, now in if !now { finish(text) } }
            .onAppear {
                text = initial
                DispatchQueue.main.async { focused = true }
            }
    }

    private func finish(_ value: String?) {
        guard !finished else { return }
        finished = true
        // Unchanged is not a rename: the session keeps the name the app gave it.
        let name = value.flatMap(SessionStore.cleanName)
        done(name == initial ? nil : name)
    }
}

/// A slow breathing pulse on the recording dot. Its own modifier, so it
/// animates without invalidating any sibling view.
private struct Pulse: ViewModifier {
    @State private var on = false
    func body(content: Content) -> some View {
        content
            .opacity(on ? 0.4 : 1)
            .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: on)
            .onAppear { on = true }
    }
}

struct ContentView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        HStack(spacing: 0) {
            SessionRail(model: model).frame(width: 236)
            Rectangle().fill(Palette.hairline).frame(width: 1)
            VStack(spacing: 0) {
                Transport(model: model)
                banners
                viewBar
                Rectangle().fill(Palette.hairline).frame(height: 1)
                if model.showOrganized { DraftPage(model: model) } else { TranscriptPage(model: model) }
                StatusBar(model: model)
            }.background(Palette.page)
        }
        .foregroundStyle(Palette.ink)
        .tint(Palette.stream)
        .frame(minWidth: 780, minHeight: 520)
        .sheet(isPresented: $model.showSettings) { SettingsView(model: model) }
        .alert("删除「\(model.deleteCandidate?.name ?? "")」？",
               isPresented: Binding(get: { model.deleteCandidate != nil }, set: { if !$0 { model.deleteCandidate = nil } }),
               presenting: model.deleteCandidate) { row in
            Button("删除", role: .destructive) {
                if let problem = model.deleteSession(row.id) { model.error = problem }
            }
            Button("取消", role: .cancel) {}
        } message: { row in
            Text(model.deleteDetail(row))
        }
        .task { if !ListenFlowHome.isPreview { model.prepareEngine() } }
        // The app list is only looked at before a session starts.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if !model.isRecording && !ListenFlowHome.isPreview { model.refreshApps() }
        }
    }

    @ViewBuilder private var banners: some View {
        if let error = model.error {
            banner(error, icon: "exclamationmark.triangle.fill", color: Palette.warning) { model.error = nil }
        }
        if let notice = model.notice {
            banner(notice, icon: "checkmark.circle.fill", color: Palette.stream) { model.notice = nil }
        }
    }

    private func banner(_ text: String, icon: String, color: Color, dismiss: @escaping () -> Void) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            Image(systemName: icon).foregroundStyle(color)
            Text(text).font(.system(size: 12)).lineSpacing(3).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            Button(action: dismiss) { Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)) }
                .buttonStyle(.plain).foregroundStyle(Palette.muted).help("关闭这条提示")
        }
        .padding(.horizontal, 28).padding(.vertical, 10)
        .background(color.opacity(0.1))
    }

    /// Which reading of the session is shown, and what can be done with it.
    private var viewBar: some View {
        HStack(spacing: 14) {
            Picker("记录视图", selection: $model.showOrganized) {
                Text("原始转写").tag(false)
                Text("整理稿").tag(true)
            }.labelsHidden().pickerStyle(.segmented).frame(width: 168)
            Spacer(minLength: 8)
            if !model.showOrganized { refineControl }
            Text(counts).font(.system(size: 11)).monospacedDigit().foregroundStyle(Palette.muted).lineLimit(1)
            Button { model.captureScreenshot() } label: { Image(systemName: "camera.viewfinder") }
                .buttonStyle(.plain).disabled(model.isCapturingShot)
                .help("截下整个屏幕，按时间存进这场会话（⇧⌘J）")
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(model.showOrganized ? model.session.organized?.text ?? "" : SessionStore.transcript(model.session), forType: .string)
            } label: { Image(systemName: "doc.on.doc") }
                .buttonStyle(.plain).help(model.showOrganized ? "复制整理稿" : "复制全部转写")
                .disabled(model.showOrganized ? model.session.organized == nil || model.isOrganizing : model.session.lines.isEmpty)
            Button { model.export() } label: { Image(systemName: "square.and.arrow.up") }
                .buttonStyle(.plain).help("导出为 Markdown 文件").disabled(model.sessionIsEmpty)
        }
        .font(.system(size: 13))
        .padding(.horizontal, 28).padding(.bottom, 12)
    }

    private var counts: String {
        let lines = model.session.lines.count, shots = model.session.imageLibrary.count
        if lines == 0 && shots == 0 { return "" }
        return shots > 0 ? "\(lines) 句，\(shots) 张图" : "\(lines) 句"
    }

    /// Whole-transcript re-recognition from kept audio. Hidden when there is nothing to redo.
    @ViewBuilder private var refineControl: some View {
        if model.isPostRefining {
            HStack(spacing: 7) {
                ProgressView(value: Double(model.postRefineDone), total: Double(max(model.postRefineTotal, 1)))
                    .frame(width: 70).controlSize(.small)
                Text("精修 \(model.postRefineDone)/\(model.postRefineTotal)").font(.system(size: 11)).foregroundStyle(Palette.stream)
                    .monospacedDigit()
                Button("停止") { model.cancelRefineSession() }.font(.system(size: 11))
            }
        } else if model.canRefineSession {
            Button { model.refineSession() } label: {
                Label("精修全文", systemImage: "wand.and.stars").font(.system(size: 12, weight: .medium))
            }.buttonStyle(.plain).foregroundStyle(Palette.stream)
                .help(model.usesCloud
                      ? "把本机暂存的约 \(Int((model.keptStreamSeconds / 60).rounded(.up))) 分钟录音上传到豆包录音文件识别，重新识别全文，更准确；按音频时长另外计费，完成后删除暂存录音"
                      : "用暂存的音频，以约 30 秒为一段重新识别全文，更准确；完成后删除暂存音频")
        }
    }
}

// MARK: - Session list

/// Every session, newest first. This is where the window starts: pick up an old
/// session with one click instead of opening a sheet to look for it.
private struct SessionRail: View {
    @ObservedObject var model: AppModel

    private struct Day: Identifiable {
        let id: String
        var sessions: [SessionSummary]
    }

    private var days: [Day] {
        var rows = model.history
        // A session with nothing in it yet has no file, but it is still the one open.
        if !rows.contains(where: { $0.id == model.session.id }) { rows.insert(SessionSummary(model.session), at: 0) }
        var out: [Day] = []
        for row in rows {
            let label = Format.day(row.created)
            if out.last?.id == label { out[out.count - 1].sessions.append(row) }
            else { out.append(Day(id: label, sessions: [row])) }
        }
        return out
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { model.newSession() } label: {
                HStack(spacing: 8) {
                    Image(systemName: "square.and.pencil").frame(width: 16)
                    Text("新建会话")
                    Spacer()
                    Text("⌘N").font(.system(size: 11)).foregroundStyle(Palette.faint)
                }
                .font(.system(size: 13, weight: .medium))
                .padding(.horizontal, 10).frame(height: 32)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).disabled(!model.canChangeSession)
            .padding(.horizontal, 10).padding(.top, 12).padding(.bottom, 6)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(days) { day in
                        Text(day.id).font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.muted)
                            .padding(.horizontal, 10).padding(.top, 14).padding(.bottom, 4)
                        ForEach(day.sessions) { row in SessionRow(model: model, row: row) }
                    }
                }.padding(.horizontal, 10).padding(.bottom, 12)
            }

            Rectangle().fill(Palette.hairline).frame(height: 1)
            EngineFooter(model: model)
        }
        .background(Palette.rail)
    }
}

private struct SessionRow: View {
    @ObservedObject var model: AppModel
    let row: SessionSummary

    private var detail: String {
        if row.lineCount == 0 { return row.imageCount > 0 ? "\(row.imageCount) 张图" : "还没有内容" }
        return Format.length(row.seconds) + "，\(row.lineCount) 句" + (row.hasDraft ? "，有整理稿" : "")
    }

    @State private var renaming = false

    private func content(current: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                if current && model.isRecording {
                    Circle().fill(Palette.live).frame(width: 6, height: 6).modifier(Pulse())
                }
                if renaming {
                    NameField(initial: row.name, size: 13, weight: current ? .semibold : .regular) { name in
                        renaming = false
                        if let name, let problem = model.renameSession(row.id, to: name) { model.error = problem }
                    }
                } else {
                    Text(row.name).font(.system(size: 13, weight: current ? .semibold : .regular)).lineLimit(1)
                    Spacer(minLength: 4)
                    Text(Format.time(row.created)).font(.system(size: 11)).monospacedDigit().foregroundStyle(Palette.muted)
                }
            }
            .frame(height: 16)
            Text(detail).font(.system(size: 11)).foregroundStyle(Palette.muted).lineLimit(1)
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(current || renaming ? Palette.ink.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .contentShape(Rectangle())
    }

    var body: some View {
        let current = row.id == model.session.id
        if renaming {
            // Not inside the button: a button would take the field's clicks and its space bar.
            content(current: current)
        } else {
            Button { model.openSession(row.id) } label: { content(current: current) }
                .buttonStyle(.plain)
                .disabled(!current && !model.canChangeSession)
                .opacity(current || model.canChangeSession ? 1 : 0.5)
                .help(current || model.canChangeSession ? row.title : "暂停转写并等识别完成后，才能换到别的会话")
                // Outside `disabled`: a session can be renamed while another one is recording.
                .contextMenu {
                    Button("改名…") { renaming = true }
                    Divider()
                    Button("删除…", role: .destructive) { model.askToDelete(row.id) }
                }
        }
    }
}

/// Which engine is listening, whether it is ready, and the way into settings.
private struct EngineFooter: View {
    @ObservedObject var model: AppModel

    private var recognitionStatus: String {
        let level = model.qualityActive ? "高精度" : "省电"
        guard model.preferences.recognitionMode == .auto else { return "识别档位：\(level)" }
        return "识别档位：\(level)（自动，\(model.onAC ? "接电源" : "电池")）"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Circle().fill(model.engineReady ? Palette.stream : Palette.warning).frame(width: 6, height: 6)
                Text(model.engineStatus).font(.system(size: 11, weight: .medium)).lineLimit(1)
            }
            if model.usesCloud {
                if !model.volcKeyPresent {
                    Button("填写 API Key") { model.showSettings = true }.font(.system(size: 11))
                }
            } else {
                Text(recognitionStatus).font(.system(size: 10)).foregroundStyle(Palette.muted).lineLimit(1)
                    .help(model.preferences.recognitionMode.detail)
                if !model.modelReady && !model.modelLoading {
                    Button("重新加载模型") { model.loadModel() }.font(.system(size: 11))
                }
            }
            Button { model.showSettings = true } label: {
                HStack(spacing: 8) {
                    Image(systemName: "gearshape").frame(width: 16)
                    Text("设置")
                    Spacer()
                    Text("⌘,").font(.system(size: 11)).foregroundStyle(Palette.faint)
                }.font(.system(size: 12)).frame(height: 24).contentShape(Rectangle())
            }.buttonStyle(.plain)
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
    }
}

// MARK: - Title and recording controls

/// The session's name and what it is doing on the left; on the right, what to
/// listen to and the one button that starts and pauses it.
private struct Transport: View {
    @ObservedObject var model: AppModel

    @State private var renaming = false
    @State private var overTitle = false

    /// Nil while the session has neither content nor a name of its own.
    private var name: String? {
        model.sessionIsEmpty && model.session.renamed != true ? nil : model.session.name
    }
    private var title: String { name ?? (model.isRecording ? "正在听" : "新的会话") }

    private var listening: String {
        let mic = model.micEnabled
        switch model.activeSource {
        case .microphone: return "在听麦克风"
        case .app: return "在听 \(model.selectedApp?.name ?? "所选 App")" + (mic ? "和麦克风" : "")
        default: return mic ? "在听电脑上的声音和麦克风" : "在听电脑上的声音，麦克风没有打开"
        }
    }

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                if renaming {
                    NameField(initial: name ?? "", size: 19, weight: .semibold) { name in
                        renaming = false
                        if let name, let problem = model.renameSession(model.session.id, to: name) { model.error = problem }
                    }
                    .frame(maxWidth: 460, alignment: .leading).frame(height: 24)
                } else {
                    HStack(spacing: 7) {
                        Text(title).font(.system(size: 19, weight: .semibold)).lineLimit(1)
                        Image(systemName: "pencil").font(.system(size: 12, weight: .medium)).foregroundStyle(Palette.muted)
                            .opacity(overTitle ? 1 : 0)
                    }
                    .contentShape(Rectangle())
                    .onHover { overTitle = $0 }
                    .onTapGesture { renaming = true }
                    .help("点一下改名")
                    .accessibilityAddTraits(.isButton)
                    .accessibilityLabel("会话名：\(title)，点一下改名")
                    .frame(height: 24)      // the same as the field, so nothing below moves
                }
                subtitle.font(.system(size: 12)).foregroundStyle(Palette.muted).lineLimit(1)
            }
            // A new session, or one opened from the list, is not the one being renamed.
            .onChange(of: model.session.id) { renaming = false }
            .onChange(of: model.renameToken) { renaming = true }
            Spacer(minLength: 10)
            if model.isRecording { liveControls } else { sourceMenu }
            recordButton
        }
        .padding(.horizontal, 28).padding(.top, 16).padding(.bottom, 14)
    }

    @ViewBuilder private var subtitle: some View {
        if model.isRecording {
            HStack(spacing: 7) {
                Circle().fill(Palette.live).frame(width: 7, height: 7).modifier(Pulse())
                // Its own timeline, so the ticking clock redraws one label
                // instead of publishing a value the whole window observes.
                TimelineView(.periodic(from: model.session.created, by: 1)) { context in
                    Text(SessionStore.timestamp(context.date, relativeTo: model.session.created))
                        .monospacedDigit().foregroundStyle(Palette.ink)
                }
                Text(listening)
            }
        } else if model.pendingCount > 0 {
            Text(model.usesCloud ? "正在等最后一句定稿" : "还有 \(model.pendingCount) 段音频在识别")
        } else if !model.session.lines.isEmpty {
            let last = model.session.lines.map(\.end).max() ?? model.session.created
            Text("\(Format.day(model.session.created)) \(Format.time(model.session.created)) 开始，\(Format.length(last.timeIntervalSince(model.session.created)))")
        } else {
            Text(model.source.detail)
        }
    }

    /// One menu instead of a picker plus a second list: the three kinds of
    /// source, and under the last the apps that are running.
    private var sourceMenu: some View {
        Menu {
            Toggle(isOn: Binding(get: { model.source == .all }, set: { _ in model.source = .all })) {
                Text("全局声音：电脑上所有声音，加上麦克风")
            }
            Toggle(isOn: Binding(get: { model.source == .microphone }, set: { _ in model.source = .microphone })) {
                Text("我的麦克风：线下课堂、线下会议")
            }
            Section("只录一个 App") {
                if model.apps.isEmpty { Text("没有正在运行的 App") }
                ForEach(model.apps) { app in
                    Toggle(isOn: Binding(get: { model.source == .app && model.selectedPID == app.id },
                                         set: { _ in model.source = .app; model.selectedPID = app.id })) { Text(app.name) }
                }
            }
            Divider()
            Button("刷新 App 列表") { model.refreshApps() }
        } label: {
            Label(sourceName, systemImage: model.source == .microphone ? "mic" : model.source == .app ? "macwindow" : "waveform")
        }
        .menuStyle(.button).buttonStyle(.bordered).controlSize(.large).fixedSize()
        .disabled(model.isBusy)
        .help(model.source.detail)
    }

    private var sourceName: String {
        switch model.source {
        case .all: "全局声音"
        case .microphone: "我的麦克风"
        case .app: model.selectedApp?.name ?? "选一个 App"
        }
    }

    /// While recording: how loud each side is, and the microphone switch.
    private var liveControls: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                if model.activeSource != .microphone { LevelBar(levels: model.levels, microphone: false) }
                if model.micEnabled { LevelBar(levels: model.levels, microphone: true) }
            }.frame(width: 64)
            if model.activeSource != .microphone {
                // With speakers the microphone re-records the Mac's own sound; those
                // repeated lines are dropped (EchoFilter), so the switch is safe to use.
                Button { Task { await model.toggleMic(!model.micEnabled) } } label: {
                    Image(systemName: model.micEnabled ? "mic.fill" : "mic.slash")
                        .font(.system(size: 13)).frame(width: 30, height: 30)
                        .foregroundStyle(model.micEnabled ? Palette.voice : Palette.muted)
                        .background(Palette.ink.opacity(0.06), in: Circle())
                }
                .buttonStyle(.plain).disabled(model.isBusy || model.micBusy)
                .help(model.micEnabled ? "麦克风在录。外放时录到的电脑声音会自动去掉，你自己的话照常保留。点一下关闭麦克风"
                                       : "麦克风没有在录。点一下打开")
            }
        }
    }

    private var recordButton: some View {
        let recording = model.isRecording
        return Button { Task { await model.toggleRecording() } } label: {
            HStack(spacing: 8) {
                if model.isBusy { ProgressView().controlSize(.small) }
                else if recording { Image(systemName: "pause.fill").font(.system(size: 11)) }
                else { Circle().fill(Palette.live).frame(width: 9, height: 9) }
                Text(model.isBusy ? "请稍候" : recording ? "暂停转写" : "开始转写").font(.system(size: 13, weight: .semibold))
            }
            .padding(.horizontal, 16).frame(height: 34)
            .foregroundStyle(recording ? Palette.live : Palette.page)
            .background(recording ? Palette.live.opacity(0.13) : Palette.ink, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .opacity(model.canToggleRecording ? 1 : 0.4)
        .disabled(!model.canToggleRecording)
        .help(recording ? "暂停转写（⌘R，在别的 App 里是 ⌥⌘R）" : "开始转写（⌘R，在别的 App 里是 ⌥⌘R）")
    }
}

private struct LevelBar: View {
    @ObservedObject var levels: AudioLevels
    let microphone: Bool
    var body: some View {
        let level = microphone ? levels.mic : levels.app
        let color = microphone ? Palette.voice : Palette.stream
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(color.opacity(0.16))
                Capsule().fill(color).frame(width: max(0, g.size.width * CGFloat(level)))
            }
        }
        .frame(height: 4).animation(.linear(duration: 0.1), value: level)
        .help(microphone ? "麦克风的音量" : "电脑声音的音量")
    }
}

// MARK: - Transcript

/// The session as a page: paragraphs of speech and the pictures taken along
/// the way, with the time in the margin and a coloured bar saying whose side
/// it was. New text is followed only while the reader is at the end; scroll
/// up to re-read something and it stays put.
private struct TranscriptPage: View {
    @ObservedObject var model: AppModel
    @State private var following = true
    /// There is more below the bottom edge. A session that fits on the page has no end to go to.
    @State private var below = false
    @State private var position = ScrollPosition(edge: .top)
    @State private var preview: ImageAttachment?

    /// Where the reader is: how far down, and how far from the end.
    private struct Reach: Equatable {
        var offset: CGFloat
        var fromEnd: CGFloat
    }

    var body: some View {
        if model.session.lines.isEmpty && model.session.imageLibrary.isEmpty && !model.hasLivePartial {
            EmptyTranscript(model: model)
        } else {
            page
        }
    }

    private var page: some View {
        let tail = model.liveTailStart
        let entries = TranscriptLayout.timeline(model.session, breakBefore: tail)
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                ForEach(entries) { entry in
                    switch entry {
                    case let .block(block):
                        if block.id == tail { LiveTailDivider() }
                        BlockRow(block: block, created: model.session.created).equatable()
                    case let .image(image):
                        ShotRow(image: image, sessionID: model.session.id, created: model.session.created) { preview = image }
                    }
                }
                LivePreviewRows(preview: model.livePreview)
                if model.pendingCount > 0 && !model.hasLivePartial {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.mini)
                        Text(model.usesCloud ? "正在等最后一句定稿" : "正在识别 \(model.pendingCount) 段音频")
                            .font(.system(size: 11)).foregroundStyle(Palette.muted)
                    }.padding(.leading, RowMetrics.textInset)
                }
            }
            .frame(maxWidth: RowMetrics.column, alignment: .leading)
            .padding(.horizontal, 28).padding(.top, 22).padding(.bottom, 30)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollPosition($position)
        .onScrollGeometryChange(for: Reach.self) { geometry in
            Reach(offset: geometry.contentOffset.y,
                  fromEnd: geometry.contentSize.height - geometry.contentOffset.y - geometry.containerSize.height)
        } action: { old, new in
            if below != (new.fromEnd >= 40) { below = new.fromEnd >= 40 }
            if new.fromEnd < 40 {
                if !following { following = true }
            } else if new.offset < old.offset - 2 {
                // The reader scrolled up: leave the page where they put it.
                if following { following = false }
            } else if following {
                // The page grew under a reader who is at the end: stay there.
                position.scrollTo(edge: .bottom)
            }
        }
        // A session being recorded opens at its newest line, a finished one at its start.
        .onChange(of: model.session.id, initial: true) { _, _ in
            following = model.isRecording
            position.scrollTo(edge: model.isRecording ? .bottom : .top)
        }
        .onChange(of: model.isRecording) { _, recording in
            if recording { following = true; position.scrollTo(edge: .bottom) }
        }
        .overlay(alignment: .bottom) {
            if !following && below {
                Button { following = true; position.scrollTo(edge: .bottom) } label: {
                    Label(model.isRecording ? "回到最新" : "到末尾", systemImage: "arrow.down")
                        .font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 13).frame(height: 30)
                        .foregroundStyle(Palette.page)
                        .background(Palette.ink.opacity(0.86), in: Capsule())
                }
                .buttonStyle(.plain).padding(.bottom, 14)
            }
        }
        .sheet(item: $preview) { image in
            AttachmentPreview(image: image, sessionID: model.session.id, created: model.session.created)
        }
    }
}

private enum RowMetrics {
    static let time: CGFloat = 44
    static let gutter: CGFloat = 14
    static let bar: CGFloat = 2.5
    /// Where text starts, measured from the row's leading edge.
    static var textInset: CGFloat { time + gutter + bar + gutter }
    /// About 42 Chinese characters a line at the body size.
    static let column: CGFloat = 760
}

/// A row of the page: the time in the margin, then a bar in the source's
/// colour that runs the height of whatever is beside it.
private struct MarginRow<Content: View>: View {
    let time: String
    let color: Color
    var dashed = false
    @ViewBuilder var content: Content
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: RowMetrics.gutter) {
            Text(time).font(.system(size: 11)).monospacedDigit().foregroundStyle(Palette.muted)
                .frame(width: RowMetrics.time, alignment: .trailing)
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, RowMetrics.bar + RowMetrics.gutter)
                .overlay(alignment: .leading) {
                    if dashed {
                        VerticalLine().stroke(color.opacity(0.7), style: StrokeStyle(lineWidth: RowMetrics.bar, dash: [3, 4]))
                            .frame(width: RowMetrics.bar)
                    } else {
                        RoundedRectangle(cornerRadius: RowMetrics.bar / 2).fill(color).frame(width: RowMetrics.bar)
                    }
                }
        }
    }
}

private struct VerticalLine: Shape {
    func path(in rect: CGRect) -> Path {
        Path { $0.move(to: CGPoint(x: rect.midX, y: 0)); $0.addLine(to: CGPoint(x: rect.midX, y: rect.maxY)) }
    }
}

private struct BlockRow: View, Equatable {
    let block: TranscriptBlock
    let created: Date
    var body: some View {
        MarginRow(time: SessionStore.timestamp(block.start, relativeTo: created), color: Palette.source(block.source)) {
            VStack(alignment: .leading, spacing: 5) {
                if block.showsSource {
                    Text(block.source).font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.source(block.source))
                }
                Text(block.text).font(.system(size: 15)).lineSpacing(7).textSelection(.enabled)
            }
        }
    }
}

/// A picture kept during the session, at the point where it was taken.
private struct ShotRow: View {
    let image: ImageAttachment
    let sessionID: UUID
    let created: Date
    var open: () -> Void
    var body: some View {
        MarginRow(time: SessionStore.timestamp(image.addedAt, relativeTo: created), color: Palette.faint) {
            VStack(alignment: .leading, spacing: 6) {
                Text(image.isShot ? "截屏" : image.name).font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.muted).lineLimit(1)
                Button(action: open) {
                    Group {
                        if let thumbnail = AttachmentThumbnails.image(image, sessionID: sessionID, edge: 720) {
                            Image(nsImage: thumbnail).resizable().scaledToFit()
                        } else {
                            Label("图片文件不在了", systemImage: "photo.badge.exclamationmark")
                                .font(.system(size: 12)).foregroundStyle(Palette.muted).frame(width: 240, height: 80)
                        }
                    }
                    .frame(maxWidth: 360, maxHeight: 230, alignment: .leading)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Palette.hairline))
                }
                .buttonStyle(.plain).help("点开看大图")
            }
        }
    }
}

/// Sentences the cloud engine is still revising, dimmed under the settled
/// text. Observes its own object, so the several updates a second redraw only
/// these rows.
private struct LivePreviewRows: View {
    @ObservedObject var preview: LivePreview
    var body: some View {
        ForEach(preview.items) { item in
            MarginRow(time: "", color: Palette.source(item.source), dashed: true) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("\(item.source)，正在说").font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.source(item.source))
                    Text(item.text).font(.system(size: 15)).lineSpacing(7).foregroundStyle(Palette.muted)
                }
            }
        }
    }
}

/// Faint seam between re-recognized text (above) and live chunks still waiting
/// to be merged (below), so it is clear which part may still change.
private struct LiveTailDivider: View {
    var body: some View {
        HStack(spacing: 8) {
            dash
            Text("以下为实时片段，稍后合并重识别").font(.system(size: 10)).foregroundStyle(Palette.muted).fixedSize()
            dash
        }.padding(.leading, RowMetrics.textInset)
    }
    private var dash: some View {
        Line().stroke(Palette.faint, style: StrokeStyle(lineWidth: 1, dash: [3, 4])).frame(height: 1)
    }
    private struct Line: Shape {
        func path(in rect: CGRect) -> Path {
            Path { $0.move(to: CGPoint(x: 0, y: rect.midY)); $0.addLine(to: CGPoint(x: rect.maxX, y: rect.midY)) }
        }
    }
}

/// Nothing said yet: say what will happen and how to begin.
private struct EmptyTranscript: View {
    @ObservedObject var model: AppModel

    private var headline: String {
        if !model.engineReady { return model.usesCloud ? "先填写豆包的 API Key" : model.modelLoading ? "正在准备本地模型" : "本地模型还没有加载" }
        guard model.isRecording else { return "从一段声音开始" }
        switch model.activeSource {
        case .microphone: return "正在听麦克风"
        case .app: return "正在等 App 里的声音"
        default: return "正在听电脑上的声音和麦克风"
        }
    }

    private var detail: String {
        let cloud = model.usesCloud
        if !model.engineReady {
            return cloud ? "豆包语音识别需要一个 API Key，保存在这台 Mac 的 ~/.listenflow/keys.json。\n没有网络时可以在设置里换成本地模型。"
                         : "本地模型加载好之后就可以开始；也可以在设置里换成豆包云端识别。"
        }
        if model.isRecording {
            let pace = cloud ? "边说边出字，一句说完后定稿。" : "停顿时更新，连续讲话约每 4 秒更新一次。"
            switch model.activeSource {
            case .microphone: return "说话即可，文字会出现在这里。\n" + pace
            case .app: return "让所选 App 播放声音，文字会出现在这里。\n" + pace
            default: return "电脑上播放的声音和你说的话都会写在这里。\n" + pace
            }
        }
        let place = cloud ? "音频发送到火山引擎豆包识别；可以在设置里换成本地模型。" : "音频在这台 Mac 上识别。"
        switch model.source {
        case .all: return "点「开始转写」，电脑上所有 App 的声音和麦克风一起转成文字。\n" + place
        case .microphone: return "点「开始转写」，只听这台 Mac 的麦克风，适合线下课堂和线下会议。\n" + place
        case .app: return "在右上角选好一个 App，再点「开始转写」，只听它的声音。\n" + place
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(systemName: model.isRecording ? "waveform" : "waveform.path")
                .font(.system(size: 30, weight: .light)).foregroundStyle(model.isRecording ? Palette.stream : Palette.faint)
                .symbolEffect(.variableColor.iterative, isActive: model.isRecording)
            Text(headline).font(.system(size: 22, weight: .semibold))
            Text(detail).font(.system(size: 13)).foregroundStyle(Palette.muted).lineSpacing(6)
                .fixedSize(horizontal: false, vertical: true)
            if !model.engineReady && model.usesCloud {
                Button("打开设置") { model.showSettings = true }.controlSize(.large)
            } else if model.modelLoading {
                ProgressView().controlSize(.small)
            } else {
                VStack(alignment: .leading, spacing: 7) {
                    shortcut("⌥⌘R", "在任何 App 里开始或暂停转写")
                    shortcut("⇧⌘J", "截下整个屏幕，按时间存进这场会话")
                }.padding(.top, 8)
            }
        }
        .frame(maxWidth: 470, alignment: .leading)
        .padding(.leading, 28 + RowMetrics.textInset).padding(.trailing, 28).padding(.top, 64)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func shortcut(_ keys: String, _ meaning: String) -> some View {
        HStack(spacing: 10) {
            Text(keys).font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.muted)
                .padding(.horizontal, 6).frame(height: 20)
                .background(Palette.ink.opacity(0.06), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                .frame(width: 50, alignment: .leading)
            Text(meaning).font(.system(size: 12)).foregroundStyle(Palette.muted)
        }
    }
}

// MARK: - Organized draft

/// The transcript rewritten as an article by the configured model. Speech is
/// set in the system sans; the written draft is set in Songti, so the two
/// readings of a session never look alike.
private struct DraftPage: View {
    @ObservedObject var model: AppModel

    private var status: String {
        guard let organized = model.session.organized else { return "用设置里的大模型把零碎的话连成文章；自动更新约每 30 秒一次" }
        var parts = [organized.sourceLineIDs.isEmpty ? "已整理图片资料"
                     : "已整理到 \(SessionStore.timestamp(organized.through, relativeTo: model.session.created))"]
        if model.session.unorganizedCount > 0 { parts.append("之后还有 \(model.session.unorganizedCount) 句") }
        if let count = organized.imageIDs?.count, count > 0 { parts.append("参考了 \(count) 张图") }
        if model.organizationImagesChanged { parts.append("图片选择变了") }
        if model.organizationStale { parts.append("原文已精修，更新时整篇重写") }
        return parts.joined(separator: "，")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    if model.isOrganizing {
                        ProgressView().controlSize(.small)
                        Text("正在整理").font(.system(size: 12)).foregroundStyle(Palette.stream)
                        Button("停止") { model.cancelOrganization() }.controlSize(.small)
                    } else {
                        Button(model.session.organized == nil ? "整理这场会话" : "更新整理稿") { model.organize() }
                            .buttonStyle(.borderedProminent).controlSize(.small)
                            .disabled(!model.hasOrganizationContext || model.isImportingImages)
                    }
                    Text(status).font(.system(size: 11)).foregroundStyle(Palette.muted).lineLimit(1)
                    Spacer(minLength: 4)
                    Toggle("自动更新", isOn: Binding(get: { model.autoOrganize }, set: { model.setAutoOrganize($0) }))
                        .font(.system(size: 11)).toggleStyle(.switch).controlSize(.mini)
                        .help("开启后，有新的转写时约每 30 秒更新一次整理稿")
                }
                ImageAttachmentPicker(model: model)
            }
            .padding(.horizontal, 28).padding(.vertical, 12)
            Rectangle().fill(Palette.hairline).frame(height: 1)
            DraftDocument(preview: model.organizationPreview, savedText: model.session.organized?.text ?? "",
                          isGenerating: model.isOrganizing)
        }
    }
}

private struct DraftDocument: View {
    @ObservedObject var preview: OrganizationPreview
    let savedText: String
    let isGenerating: Bool
    var body: some View {
        let text = isGenerating && !preview.text.isEmpty ? preview.text : savedText
        if text.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text(isGenerating ? "正在把碎片连成文章" : "把零碎的话，连起来读")
                    .font(.custom("Songti SC", size: 24).weight(.semibold))
                Text("合并断句、补全标点、分好段落，保留原意和时间。\n整理稿由 AI 生成，拿不准的地方请对照原始转写。")
                    .font(.system(size: 13)).foregroundStyle(Palette.muted).lineSpacing(6)
            }
            .padding(.leading, 28 + RowMetrics.textInset).padding(.trailing, 28).padding(.top, 64)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                DocumentTextView(text: text).frame(maxWidth: .infinity, maxHeight: .infinity)
                Text(isGenerating ? "生成中，完成后自动保存" : "AI 整理稿，拿不准的地方请对照原始转写")
                    .font(.system(size: 10)).foregroundStyle(Palette.muted)
                    .padding(.leading, 28 + RowMetrics.textInset).padding(.vertical, 9)
            }
        }
    }
}

/// Native text layout keeps a long streamed document inside the viewport
/// without rebuilding the window.
private struct DocumentTextView: NSViewRepresentable {
    let text: String

    /// The text column keeps a readable width however wide the window is.
    final class Column: NSTextView {
        static let inset = NSSize(width: 28 + 44 + 14, height: 22)
        static let width: CGFloat = 700
        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            textContainer?.containerSize = NSSize(width: max(200, min(newSize.width - Self.inset.width - 28, Self.width)),
                                                  height: .greatestFiniteMagnitude)
        }
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        let view = Column(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        view.isEditable = false
        view.isSelectable = true
        view.isRichText = false
        view.drawsBackground = false
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.textContainerInset = Column.inset
        view.textContainer?.widthTracksTextView = false
        view.textContainer?.lineFragmentPadding = 0
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        scroll.documentView = view
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView, view.string != text else { return }
        let origin = scroll.contentView.bounds.origin
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 9
        paragraph.paragraphSpacing = 3
        view.textStorage?.setAttributedString(NSAttributedString(string: text, attributes: [
            .font: NSFont(name: "Songti SC", size: 16) ?? NSFont.systemFont(ofSize: 15),
            .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph
        ]))
        scroll.contentView.scroll(to: origin)
        scroll.reflectScrolledClipView(scroll.contentView)
    }
}

// MARK: - Status line

private struct StatusBar: View {
    @ObservedObject var model: AppModel

    private var saved: String {
        if model.sessionIsEmpty { return "会话自动保存在这台 Mac" }
        if model.keepsAudio { return "已自动保存；录音暂存在本机，精修后删除" }
        return model.session.imageLibrary.isEmpty ? "已自动保存，不保留录音" : "文字和图片已自动保存，不保留录音"
    }

    var body: some View {
        HStack(spacing: 16) {
            Label(model.usesCloud ? "云端识别，音频发送到火山引擎" : "音频只在这台 Mac 上处理",
                  systemImage: model.usesCloud ? "cloud" : "lock.shield")
            if model.lastLatency > 0 {
                Text(String(format: model.usesCloud ? "最近一句 %.1f 秒后定稿" : "最近一段延迟 %.1f 秒", model.lastLatency)).monospacedDigit()
            }
            if model.echoDropped > 0 {
                Text("去掉了 \(model.echoDropped) 句外放回声").help("开着外放时，麦克风会把电脑的声音再录一遍；这些重复的句子不计入转写")
            }
            if model.oldestPending > 10 {
                Label("识别跟不上，正在处理积压", systemImage: "exclamationmark.triangle").foregroundStyle(Palette.warning)
            }
            Spacer(minLength: 8)
            Text(saved)
        }
        .font(.system(size: 11)).lineLimit(1)
        .foregroundStyle(Palette.muted)
        .padding(.horizontal, 28).frame(height: 30)
        .overlay(alignment: .top) { Rectangle().fill(Palette.hairline).frame(height: 1) }
    }
}
