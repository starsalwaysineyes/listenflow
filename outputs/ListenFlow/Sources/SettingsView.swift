import SwiftUI
import AppKit

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var draft = Preferences()
    @State private var key = ""
    @State private var volcKey = ""
    @State private var volcKeyLoaded = ""
    @State private var error: String?
    @State private var initialized = false
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack { Text("设置").font(.system(size: 23, weight: .semibold)); Spacer(); Button("取消") { dismiss() } }
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    // First: the one part of the settings that keeps changing.
                    GroupBox { HotwordEditor(model: model).padding(12).frame(maxWidth: .infinity, alignment: .leading) }
                    GroupBox {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("语音识别").font(.headline)
                            Picker("识别引擎", selection: $draft.engine) {
                                ForEach(RecognitionEngine.allCases) { Text($0.label).tag($0) }
                            }.pickerStyle(.segmented)
                                .disabled(model.isRecording || model.pendingCount > 0 || model.modelLoading)
                            if draft.engine == .volc {
                                Label("云端识别：转写时，音频会发送到火山引擎（豆包）。边说边出字，一句说完后由服务端再识别一遍定稿。",
                                      systemImage: "cloud")
                                    .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text("豆包语音 API Key").font(.system(size: 11)).foregroundStyle(.secondary)
                                    SecureField("保存在 ~/.listenflow/keys.json，仅本人可读", text: $volcKey).textFieldStyle(.roundedBorder)
                                }
                                field("资源 ID", text: $draft.volcResourceID, prompt: "volc.seedasr.sauc.duration")
                                Text("小时版填 volc.seedasr.sauc.duration，按送入的音频时长计费；并发版填 volc.seedasr.sauc.concurrent，需要单独开通。只在有人说话时连接和发送音频，静音不计费。")
                                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                                Toggle("暂存录音，用于会后「精修全文」", isOn: $draft.keepAudioForRefine)
                                Text("开启后，发给豆包的那部分音频（有人说话的片段）同时保存在这台 Mac 的 ~/.listenflow/audio。会后点「精修全文」，这些录音会上传到豆包录音文件识别，结合整段上下文重新识别，比实时结果更准；按音频时长另外计费。完成后删除，最长保留 7 天。")
                                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                                if draft.keepAudioForRefine {
                                    field("录音文件识别的资源 ID", text: $draft.volcFileResourceID, prompt: "volc.seedasr.auc")
                                }
                                field("火山引擎控制台的热词表 ID（可选）", text: $draft.volcBoostingTableID)
                                Text("已经在火山引擎控制台建过热词表的话，填它的 ID，和上面的热词一起生效。没建过不用填。")
                                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                                Text("识别档位和合并重识别只用于本地模型；豆包自带二遍识别。没有网络时可以切换到本地模型。")
                                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            } else {
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
                                Picker("识别档位", selection: $draft.recognitionMode) {
                                    ForEach(RecognitionMode.allCases) { Text($0.label).tag($0) }
                                }.pickerStyle(.segmented)
                                Text(draft.recognitionMode.detail + "。高精度约多用一半算力，错字约再少两到三成。")
                                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                                Toggle("暂存录音，用于事后「精修全文」", isOn: $draft.keepAudioForRefine)
                                Text("音频只保存在这台 Mac 的 ~/.listenflow/audio，精修完成后删除，最长保留 7 天。关闭后不保存任何原始音频。")
                                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                                Text("复用本机模型缓存，模型加载和转写均为离线运行，音频不离开这台 Mac。").font(.caption).foregroundStyle(.secondary)
                            }
                        }.padding(12)
                    }
                    GroupBox {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("刘海灵动岛").font(.headline)
                            Toggle("在刘海显示实时转写", isOn: $draft.islandEnabled)
                            Toggle("收起时常亮显示最新一句", isOn: $draft.islandShowLatest).disabled(!draft.islandEnabled)
                            HStack(spacing: 10) {
                                Text("宽度")
                                Slider(value: $draft.islandWidth, in: 480...1100, step: 20)
                                Text("\(Int(draft.islandWidth)) pt").font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(.secondary).frame(width: 52, alignment: .trailing)
                            }.disabled(!draft.islandEnabled)
                            HStack {
                                Button("恢复默认宽度") { draft.islandWidth = Preferences().islandWidth }
                                    .disabled(!draft.islandEnabled || draft.islandWidth == Preferences().islandWidth)
                                Button("恢复默认高度") { draft.islandHeight = Preferences().islandHeight }
                                    .disabled(!draft.islandEnabled || draft.islandHeight == Preferences().islandHeight)
                            }
                            Text("鼠标移到刘海处展开，移开后收起；点图钉可固定展开。拖动灵动岛底部的横条可以调整高度，会记住；14 寸屏幕可以把宽度调窄一些。灵动岛不会出现在屏幕共享和截图里。")
                                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }.padding(12)
                    }
                    GroupBox {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("整理稿用的大模型").font(.headline)
                            field("API Base URL", text: $draft.apiBase, prompt: "https://api.deepseek.com/v1")
                                .onChange(of: draft.apiBase) { _, _ in if initialized { key = "" } }
                            field("模型名称", text: $draft.llmModel, prompt: "deepseek-flash")
                            VStack(alignment: .leading, spacing: 5) {
                                Text("API Key").font(.system(size: 11)).foregroundStyle(.secondary)
                                SecureField("保存在 ~/.listenflow/keys.json，仅本人可读", text: $key).textFieldStyle(.roundedBorder)
                            }
                            Button("读取此地址已保存的密钥") { key = SecretStore.read(account: draft.apiBase) }.font(.caption)
                            Text("「整理稿」用这个模型把零碎的转写连成文章。支持 chat/completions 兼容接口；整理时发送当前会话的转写文字和选中的参考图片，音频不会发送。").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
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
                Text("密钥不会出现在导出的记录里。").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("保存设置") {
                    do { try model.applyPreferences(draft, key: key, volcKey: volcKey == volcKeyLoaded ? nil : volcKey); dismiss() }
                    catch { self.error = error.localizedDescription }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }.padding(28).frame(width: 650, height: 690).tint(Palette.stream)
            .onAppear { draft = model.preferences; key = SecretStore.read(account: draft.apiBase)
                // Preview builds take the Doubao key from the environment only.
                if Bundle.main.bundleIdentifier != "local.ListenFlow.preview" {
                    volcKeyLoaded = SecretStore.read(account: SecretStore.volcAccount)
                    volcKey = volcKeyLoaded
                }
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

/// The hot word list, as it is in `~/.listenflow/hotwords.txt`. Changes are
/// saved as they are made — the file is shared with `lstf`, so there is no
/// draft to keep apart from it.
private struct HotwordEditor: View {
    @ObservedObject var model: AppModel
    @State private var entry = ""

    var body: some View {
        let words = model.hotwords
        let live = HotwordStore.live(words).count
        VStack(alignment: .leading, spacing: 12) {
            Text("热词与术语").font(.headline)
            Text("人名、产品名、专业术语写在这里，识别时会优先往这些词上靠。增删立即保存，录制中从下一段讲话起生效。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                TextField("加一个词，回车确认；多个词用逗号隔开", text: $entry).textFieldStyle(.roundedBorder).onSubmit(add)
                Button("添加", action: add).disabled(entry.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if words.isEmpty {
                Text("还没有热词。").font(.caption).foregroundStyle(.secondary)
            } else {
                Flow(spacing: 6) {
                    ForEach(Array(words.enumerated()), id: \.element) { index, word in
                        HStack(spacing: 5) {
                            Text(word).font(.system(size: 12)).lineLimit(1)
                            Button { model.removeHotword(word) } label: {
                                Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                            }.buttonStyle(.plain).foregroundStyle(.secondary).help("删除「\(word)」")
                        }
                        .padding(.leading, 9).padding(.trailing, 7).frame(height: 24)
                        .background(Color.primary.opacity(index < live ? 0.08 : 0.03), in: Capsule())
                        .foregroundStyle(index < live ? Color.primary : Color.secondary)
                        .help(index < live ? "实时识别和精修都会用到" : "实时识别用不到（超出豆包流式接口约 100 tokens 的上限），精修全文时会用到")
                    }
                }
                Text(live < words.count
                     ? "共 \(words.count) 个。豆包实时识别只收得下前 \(live) 个，靠前的优先；会后「精修全文」时全部都用。"
                     : "共 \(words.count) 个，实时识别和精修都会用到。豆包实时识别大约收得下 \(HotwordStore.liveCharacters) 个字，超出的只在精修时用。")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Text("保存在 ~/.listenflow/hotwords.txt，一行一个。agent 可以用 lstf hotword add / delete 增删。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func add() {
        model.addHotwords(entry)
        entry = ""
    }
}

/// Lays its children out left to right, wrapping to a new row when one does not fit.
private struct Flow: Layout {
    var spacing: CGFloat = 6

    private func rows(_ subviews: Subviews, width: CGFloat) -> [(indices: [Int], height: CGFloat)] {
        var rows: [(indices: [Int], height: CGFloat)] = [], x: CGFloat = 0
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if rows.isEmpty || (x + size.width > width && !rows[rows.count - 1].indices.isEmpty) {
                rows.append(([], 0)); x = 0
            }
            rows[rows.count - 1].indices.append(index)
            rows[rows.count - 1].height = max(rows[rows.count - 1].height, size.height)
            x += size.width + spacing
        }
        return rows
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 400
        let rows = rows(subviews, width: width)
        return CGSize(width: width, height: rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(rows.count - 1, 0)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }
}
