import SwiftUI
import AppKit

private let ink = Color(red: 0.12, green: 0.17, blue: 0.22)
private let teal = Color(red: 0.05, green: 0.48, blue: 0.43)
private let paper = Color(red: 0.965, green: 0.967, blue: 0.955)
private let muted = Color(red: 0.47, green: 0.51, blue: 0.53)

struct ContentView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 242)
            Divider()
            VStack(spacing: 0) {
                header
                if let error = model.error {
                    HStack(alignment: .top, spacing: 9) {
                        Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
                        Text(error).font(.system(size: 12)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        Button { model.error = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
                    }.padding(12).background(Color.orange.opacity(0.09))
                }
                HSplitView {
                    transcript.frame(minWidth: 310)
                    askPanel.frame(minWidth: 300, idealWidth: 380)
                }
                footer
            }.background(Color.white)
        }
        .foregroundStyle(ink)
        .tint(teal)
        .frame(minWidth: 1020, minHeight: 650)
        .preferredColorScheme(.light)
        .sheet(isPresented: $model.showSettings) { SettingsView(model: model) }
        .sheet(isPresented: $model.showHistory) { historySheet }
        .task { if Bundle.main.bundleIdentifier != "local.ListenFlow.preview" && !model.modelReady && !model.modelLoading { model.loadModel() } }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(spacing: 10) {
                Image(systemName: "waveform").font(.system(size: 22, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 40, height: 40).background(teal, in: RoundedRectangle(cornerRadius: 13))
                VStack(alignment: .leading, spacing: 3) {
                    Text("听流").font(.system(size: 23, weight: .semibold))
                    Text("LISTENFLOW").font(.system(size: 9, weight: .medium, design: .monospaced)).tracking(2).foregroundStyle(muted)
                }
            }.padding(.top, 12)
            VStack(alignment: .leading, spacing: 9) {
                sectionLabel("音频来源")
                Picker("音频来源", selection: $model.source) {
                    ForEach(AudioSource.allCases) { source in
                        Text(source.label).tag(source)
                    }
                }.labelsHidden().pickerStyle(.segmented).frame(maxWidth: .infinity)
                    .disabled(model.isRecording || model.isBusy)
                Text(model.source.detail).font(.system(size: 11)).foregroundStyle(muted)
                    .fixedSize(horizontal: false, vertical: true)

                if model.source == .app {
                    HStack {
                        Text("指定 App").font(.system(size: 13, weight: .medium))
                        Spacer()
                        Button { model.refreshApps() } label: { Image(systemName: "arrow.clockwise") }
                            .buttonStyle(.plain).foregroundStyle(muted).help("刷新正在运行的 App")
                            .disabled(model.isRecording || model.isBusy)
                    }.padding(.top, 2)
                    Picker("指定 App", selection: $model.selectedPID) {
                        if model.apps.isEmpty { Text("先打开一个 App").tag(pid_t(0)) }
                        ForEach(model.apps) { Text($0.name).tag($0.id) }
                    }.labelsHidden().pickerStyle(.menu).frame(maxWidth: .infinity)
                        .disabled(model.isRecording || model.isBusy)
                }

                AudioLevelMeter(levels: model.levels, microphone: model.source == .microphone)
            }
            if model.source == .app, model.isRecording {
                // Mixing an open microphone with speaker output re-records the app's
                // own sound; the option exists, but only as an explicit choice.
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Image(systemName: model.micEnabled ? "mic.fill" : "mic.slash.fill")
                            .foregroundStyle(model.micEnabled ? teal : muted)
                        Text("同时录麦克风").font(.system(size: 13, weight: .medium))
                        Spacer()
                        Toggle("同时录麦克风", isOn: Binding(get: { model.micEnabled }, set: { value in
                            Task { await model.toggleMic(value) }
                        })).labelsHidden().toggleStyle(.switch).controlSize(.small)
                            .disabled(model.isBusy || model.micBusy)
                    }
                    AudioLevelMeter(levels: model.levels, microphone: true)
                    if model.micEnabled {
                        Text("外放时会重复录入 App 的声音，建议戴耳机").font(.system(size: 10)).foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }.padding(14).background(Color.white.opacity(0.7), in: RoundedRectangle(cornerRadius: 12))
            }
            VStack(alignment: .leading, spacing: 10) {
                sectionLabel("会话")
                sideButton("新建会话", icon: "plus.square") { model.newSession() }.disabled(!model.canChangeSession)
                sideButton("历史记录", icon: "clock.arrow.circlepath") { model.showHistory = true }.disabled(!model.canChangeSession)
                sideButton("导出转写与问答", icon: "square.and.arrow.up") { model.export() }
                    .disabled(model.session.lines.isEmpty && model.session.chat.isEmpty && model.session.imageLibrary.isEmpty)
            }
            Spacer(minLength: 10)
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Circle().fill(model.modelReady ? teal : .orange).frame(width: 6, height: 6)
                    Text(model.modelStatus).font(.system(size: 11, weight: .medium))
                }
                Text(model.preferences.asrModel.components(separatedBy: "/").last ?? "本地 ASR")
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(muted).lineLimit(1)
                if !model.modelReady && !model.modelLoading {
                    Button("重新加载模型") { model.loadModel() }.font(.system(size: 11))
                }
                Divider()
                sideButton("模型与 API 设置", icon: "slider.horizontal.3") { model.showSettings = true }
            }
        }.padding(22).background(paper)
    }

    /// Spoken guidance depends on what the session is actually listening to.
    private var emptyStateDetail: String {
        if model.isRecording {
            return model.activeSource == .microphone
                ? "说话即可，转写会自动出现在这里。\n停顿时更新，连续讲话约每 4 秒更新一次。"
                : "让所选 App 播放音频，转写会自动出现在这里。\n停顿时更新，连续讲话约每 4 秒更新一次。"
        }
        return model.source == .microphone
            ? "选择左侧「我的麦克风」后点击「开始转写」。\n适合线下课堂与线下会议，音频在这台 Mac 上识别。"
            : "在左侧选择一个正在播放声音的 App，再点击「开始转写」。\n音频在这台 Mac 上识别。"
    }

    private var header: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(model.isRecording ? "正在聆听" : "实时转写").font(.system(size: 24, weight: .semibold))
                    if model.isRecording { Circle().fill(teal).frame(width: 7, height: 7) }
                }
                Text(model.session.lines.isEmpty && model.session.chat.isEmpty && model.session.imageLibrary.isEmpty ? "让声音留下，也让问题有据可循。" : model.session.title)
                    .font(.system(size: 12)).foregroundStyle(muted).lineLimit(1)
            }
            Spacer()
            if model.isRecording {
                Text(SessionStore.timestamp(model.now, relativeTo: model.session.created))
                    .font(.system(size: 14, weight: .medium, design: .monospaced)).foregroundStyle(muted)
            }
            Button { Task { if model.isRecording { await model.stop() } else { await model.start() } } } label: {
                HStack(spacing: 8) {
                    if model.isBusy { ProgressView().controlSize(.small) }
                    else { Image(systemName: model.isRecording ? "pause.fill" : "play.fill") }
                    Text(model.isBusy ? "请稍候" : model.isRecording ? "暂停转写" : "开始转写").fontWeight(.medium)
                }.padding(.horizontal, 14).padding(.vertical, 10)
            }.buttonStyle(.plain).foregroundStyle(.white).background(teal, in: Capsule())
                .opacity(model.modelReady && !model.isBusy ? 1 : 0.45)
                .disabled(!model.canStartRecording || model.isBusy || model.micBusy)
                .keyboardShortcut("r", modifiers: [.command])
        }.padding(.horizontal, 26).padding(.vertical, 23)
    }

    private var transcript: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Picker("记录视图", selection: $model.showOrganized) {
                    Text("原始转写").tag(false)
                    Text("整理稿").tag(true)
                }.labelsHidden().pickerStyle(.segmented).frame(width: 180)
                Spacer()
                Text("\(model.session.lines.count) 段").font(.system(size: 11)).foregroundStyle(muted)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(model.showOrganized ? model.session.organized?.text ?? "" : SessionStore.transcript(model.session), forType: .string)
                } label: { Image(systemName: "doc.on.doc") }.buttonStyle(.plain).help("复制当前视图的完整记录")
                    .disabled(model.showOrganized ? model.session.organized == nil || model.isOrganizing : model.session.lines.isEmpty)
            }.padding(.horizontal, 22).padding(.vertical, 16)
            if model.showOrganized { organizationControls }
            Divider().padding(.horizontal, 26)
            if model.showOrganized {
                organizedContent
            } else if model.session.lines.isEmpty {
                VStack(spacing: 16) {
                    Image(systemName: model.isRecording ? (model.activeSource == .microphone ? "mic.fill" : "waveform") : "waveform.path")
                        .font(.system(size: 42, weight: .ultraLight)).foregroundStyle(teal.opacity(0.7))
                    Text(model.isRecording
                         ? (model.activeSource == .microphone ? "正在聆听麦克风" : "正在等待 App 中的声音")
                         : "从一段声音开始").font(.system(size: 18, weight: .medium))
                    Text(emptyStateDetail)
                        .font(.system(size: 12)).foregroundStyle(muted).multilineTextAlignment(.center).lineSpacing(5)
                    if model.modelLoading { ProgressView("正在准备本地模型…").controlSize(.small).font(.system(size: 11)) }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 24) {
                            ForEach(model.session.lines) { line in
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack(spacing: 8) {
                                        Text(SessionStore.timestamp(line.start, relativeTo: model.session.created))
                                            .font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundStyle(muted)
                                        Text(line.source).font(.system(size: 10, weight: .medium))
                                            .foregroundStyle(line.source == "麦克风" ? .orange : teal)
                                        Spacer()
                                    }
                                    Text(line.text).font(.system(size: 15)).lineSpacing(6).textSelection(.enabled)
                                }.id(line.id)
                            }
                            if model.pendingCount > 0 {
                                HStack(spacing: 8) { ProgressView().controlSize(.mini); Text("正在识别 \(model.pendingCount) 段音频…").font(.system(size: 11)).foregroundStyle(muted) }
                            }
                            Color.clear.frame(height: 1).id("bottom")
                        }.padding(26)
                    }.onChange(of: model.session.lines.count) { _, _ in withAnimation { proxy.scrollTo("bottom", anchor: .bottom) } }
                }
            }
        }
    }

    private var organizationControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                if model.isOrganizing {
                    ProgressView().controlSize(.small)
                    Text("正在整理…").font(.system(size: 12)).foregroundStyle(teal)
                    Button("停止") { model.cancelOrganization() }.font(.system(size: 11))
                } else {
                    Button { model.organize() } label: {
                        Label(model.session.organized == nil ? "整理当前记录" : "更新整理稿", systemImage: "text.badge.checkmark")
                    }.buttonStyle(.borderedProminent).controlSize(.small).disabled(!model.hasOrganizationContext || model.isImportingImages)
                }
                Spacer(minLength: 4)
                Toggle("自动更新", isOn: Binding(get: { model.autoOrganize }, set: { model.setAutoOrganize($0) }))
                    .font(.system(size: 11)).toggleStyle(.switch).controlSize(.mini)
                    .help("开启后，有新增转写时约每 30 秒用问答 API 更新整理稿")
            }
            if let organized = model.session.organized {
                Text((organized.sourceLineIDs.isEmpty ? "已整理图片资料" : "已整理至 \(SessionStore.timestamp(organized.through, relativeTo: model.session.created))") +
                     (model.session.unorganizedCount > 0 ? " · 另有 \(model.session.unorganizedCount) 段新内容" : "") +
                     ((organized.imageIDs?.isEmpty == false) ? " · 参考 \(organized.imageIDs!.count) 张图" : "") +
                     (model.organizationImagesChanged ? " · 图片选择已变化" : ""))
                    .font(.system(size: 10)).foregroundStyle(muted)
            } else {
                Text("用已配置的 API 整理全文 · 自动更新间隔约 30 秒").font(.system(size: 10)).foregroundStyle(muted)
            }
            ImageAttachmentPicker(model: model, forOrganization: true)
        }.padding(.horizontal, 22).padding(.bottom, 14)
    }

    private var organizedContent: some View {
        OrganizationDocument(preview: model.organizationPreview, savedText: model.session.organized?.text ?? "",
                             isGenerating: model.isOrganizing)
    }

    private var askPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: "sparkle").foregroundStyle(teal)
                Text("问问这段内容").font(.system(size: 14, weight: .semibold))
                Spacer()
                Button { model.showSettings = true } label: { Image(systemName: "gearshape") }.buttonStyle(.plain).foregroundStyle(muted)
            }.padding(.horizontal, 22).padding(.top, 17).padding(.bottom, 8)
            Text(model.connectionLabel).font(.system(size: 10)).foregroundStyle(muted).padding(.horizontal, 22)
            if model.session.chat.isEmpty {
                VStack(alignment: .leading, spacing: 16) {
                    Text(model.askImages.isEmpty ? "边听，边理解。" : "看图，也结合上下文。").font(.system(size: 22, weight: .medium))
                    Text(model.askImages.isEmpty ? "基于当前会话已经转写的内容回答。\n提问期间，转写会继续。" : "结合选中的图片与已有转写回答。\n没有录音，也可以直接提问图片内容。")
                        .font(.system(size: 12)).foregroundStyle(muted).lineSpacing(5)
                    VStack(alignment: .leading, spacing: 8) {
                        suggestion("总结目前的讨论", icon: "text.alignleft")
                        suggestion("有哪些待办事项？", icon: "checklist")
                        suggestion("解释一下刚才的内容", icon: "lightbulb")
                    }.padding(.top, 8)
                }.padding(26).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 22) {
                            ForEach(model.session.chat) { message in
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack {
                                        Text(message.role == "user" ? "你" : "听流").font(.system(size: 11, weight: .semibold)).foregroundStyle(teal)
                                        if let through = message.contextThrough, message.role == "assistant" {
                                            Text("依据 \(SessionStore.timestamp(through, relativeTo: model.session.created)) 前的记录")
                                                .font(.system(size: 9)).foregroundStyle(muted)
                                        }
                                    }
                                    if message.text.isEmpty { ProgressView().controlSize(.small) }
                                    else if message.role == "assistant" {
                                        MarkdownAnswerView(text: message.text).equatable()
                                        Button {
                                            NSPasteboard.general.clearContents()
                                            NSPasteboard.general.setString(message.text, forType: .string)
                                        } label: { Label("复制回答", systemImage: "doc.on.doc").font(.system(size: 10)).foregroundStyle(muted) }
                                            .buttonStyle(.plain).help("复制原始 Markdown，保留格式")
                                    } else { Text(message.text).font(.system(size: 13)).lineSpacing(5).textSelection(.enabled) }
                                    if message.role == "user", let ids = message.imageIDs, !ids.isEmpty {
                                        ImageReferencesView(images: model.session.imageLibrary.filter { ids.contains($0.id) }, sessionID: model.session.id)
                                    }
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            }
                            Color.clear.frame(height: 1).id("chatBottom")
                        }.padding(22)
                    }.onChange(of: model.session.chat.last?.text) { _, _ in proxy.scrollTo("chatBottom", anchor: .bottom) }
                }
            }
            VStack(alignment: .leading, spacing: 10) {
                ImageAttachmentPicker(model: model, forOrganization: false)
                QuestionInput(text: $model.question, onPaste: { model.pasteAskImages(from: $0) }, onSubmit: { model.ask() }, focusToken: model.questionFocusToken)
                HStack {
                    Text(model.askImages.isEmpty ? (!model.hasAskContext ? "添加图片或转写内容后即可提问" : "发送当前会话文字给问答 API") : "发送会话文字及选中的 \(model.askImages.count) 张图片")
                        .font(.system(size: 9)).foregroundStyle(muted)
                    Spacer()
                    if model.isAsking {
                        Button { model.cancelAsk() } label: { Image(systemName: "stop.fill") }.buttonStyle(.bordered).help("停止回答")
                    } else {
                        Button { model.ask() } label: { Image(systemName: "arrow.up").fontWeight(.bold).frame(width: 22, height: 22) }
                            .buttonStyle(.borderedProminent).clipShape(Circle())
                            .disabled((model.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && model.askImages.isEmpty) || !model.hasAskContext || model.isImportingImages)
                            .keyboardShortcut(.return, modifiers: [.command])
                    }
                }
            }.padding(14).background(Color.white, in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(teal.opacity(0.15))).padding(18)
        }.background(paper.opacity(0.55))
    }

    private var footer: some View {
        HStack(spacing: 16) {
            Label("音频本地处理", systemImage: "lock.shield").font(.system(size: 10))
            if model.lastLatency > 0 {
                Text(String(format: "最近片段延迟 %.1f 秒", model.lastLatency)).font(.system(size: 10))
            }
            if model.oldestPending > 10 {
                Text("识别延迟较高，正在处理积压").font(.system(size: 10)).foregroundStyle(.orange)
            }
            Spacer()
            Text(!model.session.imageLibrary.isEmpty ? "会话与图片已保存在本机" : model.session.lines.isEmpty ? "会话文字自动保存在本机" : "已自动保存 · 不保存原始音频").font(.system(size: 10))
        }.foregroundStyle(muted).padding(.horizontal, 26).padding(.vertical, 11).background(paper.opacity(0.6))
    }

    private var historySheet: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack { Text("历史会话").font(.title2.bold()); Spacer(); Button("完成") { model.showHistory = false } }
            if model.history.isEmpty { Text("还没有保存的会话。转写后会自动保存在本机。").foregroundStyle(muted).padding(.vertical, 60) }
            else {
                List(model.history) { session in
                    Button { model.openSession(session) } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(session.title).font(.headline)
                            Text("\(session.lines.count) 段转写 · \(session.chat.count / 2) 次问答" + (session.imageLibrary.isEmpty ? "" : " · \(session.imageLibrary.count) 张图"))
                                .font(.caption).foregroundStyle(muted)
                        }.padding(.vertical, 5)
                    }.buttonStyle(.plain)
                }
            }
        }.padding(26).frame(width: 600, height: 420)
    }
    private func suggestion(_ text: String, icon: String) -> some View {
        Button { model.ask(text) } label: {
            HStack(spacing: 10) { Image(systemName: icon).foregroundStyle(teal).frame(width: 18); Text(text); Spacer(); Image(systemName: "arrow.up.left").foregroundStyle(muted) }
                .font(.system(size: 12)).padding(12).background(Color.white, in: RoundedRectangle(cornerRadius: 9))
        }.buttonStyle(.plain).disabled(!model.hasAskContext || model.isAsking || model.isImportingImages)
    }
    private func sectionLabel(_ text: String) -> some View { Text(text).font(.system(size: 10, weight: .medium)).tracking(1).foregroundStyle(muted) }
    private func sideButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { HStack(spacing: 10) { Image(systemName: icon).frame(width: 16); Text(title); Spacer() }.font(.system(size: 12)).padding(.vertical, 5) }.buttonStyle(.plain)
    }
}

private struct OrganizationDocument: View {
    @ObservedObject var preview: OrganizationPreview
    let savedText: String
    let isGenerating: Bool
    var body: some View {
        let text = isGenerating && !preview.text.isEmpty ? preview.text : savedText
        Group {
            if text.isEmpty {
                VStack(spacing: 15) {
                    Image(systemName: "text.alignleft").font(.system(size: 37, weight: .ultraLight)).foregroundStyle(teal.opacity(0.7))
                    Text(isGenerating ? "正在把碎片连成文章" : "把零碎的话，连起来读").font(.system(size: 17, weight: .medium))
                    Text("合并断句、补全标点、整理段落。\n保留原意与时间戳，随时可以对照原始转写。")
                        .font(.system(size: 12)).foregroundStyle(muted).multilineTextAlignment(.center).lineSpacing(5)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    DocumentTextView(text: text).frame(maxWidth: .infinity, maxHeight: .infinity)
                    Text(isGenerating ? "生成中，完成后自动保存" : "AI 整理稿 · 不确定之处请对照原始转写")
                        .font(.system(size: 10)).foregroundStyle(muted).padding(.horizontal, 26).padding(.vertical, 12)
                }
            }
        }
    }
}

/// Native text layout keeps long streamed documents inside the viewport without rebuilding the window.
private struct DocumentTextView: NSViewRepresentable {
    let text: String
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        view.isEditable = false
        view.isSelectable = true
        view.isRichText = false
        view.drawsBackground = false
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.textContainerInset = NSSize(width: 24, height: 22)
        view.textContainer?.widthTracksTextView = true
        view.textContainer?.containerSize = NSSize(width: 600, height: CGFloat.greatestFiniteMagnitude)
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        scroll.documentView = view
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView, view.string != text else { return }
        let origin = scroll.contentView.bounds.origin
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 7
        paragraph.paragraphSpacing = 10
        view.textStorage?.setAttributedString(NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 15), .foregroundColor: NSColor(ink), .paragraphStyle: paragraph
        ]))
        scroll.contentView.scroll(to: origin)
        scroll.reflectScrolledClipView(scroll.contentView)
    }
}

private struct AudioLevelMeter: View {
    @ObservedObject var levels: AudioLevels
    let microphone: Bool
    private var level: Float { microphone ? levels.mic : levels.app }
    private var color: Color { microphone ? .orange : teal }
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(color.opacity(0.08))
                Capsule().fill(color.opacity(0.8)).frame(width: max(0, g.size.width * CGFloat(level)))
            }
        }.frame(height: 4).animation(.linear(duration: 0.1), value: level)
    }
}

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var draft = Preferences()
    @State private var key = ""
    @State private var error: String?
    @State private var initialized = false
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack { Text("模型与 API 设置").font(.system(size: 23, weight: .semibold)); Spacer(); Button("取消") { dismiss() } }
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    GroupBox {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("本地语音识别").font(.headline)
                            Picker("模型", selection: $draft.asrModel) {
                                Text("Qwen3-ASR 1.7B · 默认").tag("mlx-community/Qwen3-ASR-1.7B-8bit")
                                Text("Qwen3-ASR 0.6B · 更轻量").tag("mlx-community/Qwen3-ASR-0.6B-8bit")
                            }.disabled(model.isRecording || model.pendingCount > 0 || model.modelLoading)
                            Picker("识别语言", selection: $draft.language) {
                                Text("自动识别").tag("")
                                Text("中文").tag("Chinese")
                                Text("English").tag("English")
                            }
                            field("Python 路径", text: $draft.python)
                                .disabled(model.isRecording || model.pendingCount > 0 || model.modelLoading)
                            field("人名、术语（逗号分隔，可选）", text: $draft.hotwords)
                            Text("复用本机模型缓存，模型加载和转写均为离线运行。").font(.caption).foregroundStyle(.secondary)
                        }.padding(12)
                    }
                    GroupBox {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("上下文问答").font(.headline)
                            field("API Base URL", text: $draft.apiBase, prompt: "https://api.deepseek.com/v1")
                                .onChange(of: draft.apiBase) { _, _ in if initialized { key = "" } }
                            field("模型名称", text: $draft.llmModel, prompt: "deepseek-flash")
                            VStack(alignment: .leading, spacing: 5) {
                                Text("API Key").font(.system(size: 11)).foregroundStyle(.secondary)
                                SecureField("密钥存入 macOS 钥匙串", text: $key).textFieldStyle(.roundedBorder)
                            }
                            Button("读取此地址已保存的密钥") { key = SecretStore.read(account: draft.apiBase) }.font(.caption)
                            Text("支持 chat/completions 兼容接口与流式回答。提问时发送当前会话的转写文字和最近问答，音频不会发送给问答服务。").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }.padding(12)
                    }
                    HStack {
                        Text("采集权限由 macOS 管理。麦克风仅在手动开启时请求权限。").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("打开录制权限设置") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                        }.font(.caption)
                    }
                }
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Text("密钥不会出现在项目源码或导出记录里。").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("保存设置") {
                    do { try model.applyPreferences(draft, key: key); dismiss() }
                    catch { self.error = error.localizedDescription }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }.padding(28).frame(width: 650, height: 690).tint(teal)
            .onAppear { draft = model.preferences; key = SecretStore.read(account: draft.apiBase)
                DispatchQueue.main.async { initialized = true }
            }
    }
    private func field(_ title: String, text: Binding<String>, prompt: String = "") -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 11)).foregroundStyle(.secondary)
            TextField(prompt, text: text).textFieldStyle(.roundedBorder)
        }
    }
}
