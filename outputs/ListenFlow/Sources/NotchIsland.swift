import SwiftUI
import AppKit
import Combine

/// Hover-driven state of the island. Kept out of `AppModel` so moving the mouse
/// over the notch never invalidates the main window.
@MainActor
final class IslandState: ObservableObject {
    enum Mode: Equatable { case hidden, compact, expanded }
    @Published var mode: Mode = .hidden
    @Published var notch = CGSize(width: 190, height: 32)
    @Published var hasNotch = true
    @Published var resizing = false
}

/// Live transcript in the MacBook notch. Collapsed it is invisible and lets every
/// click through; hovering the notch expands it, the pin keeps it open. It is
/// excluded from screen sharing and screenshots, so a shared screen never shows
/// what is being transcribed.
@MainActor
final class NotchIslandController {
    /// Body height bounds for dragging. For scale, measured on a real lecture in
    /// quality mode (merged lines of 63–113 characters): 300 pt shows about 4 of
    /// them, 520 pt about 8.
    static let minBody: CGFloat = 120
    static func maxBody(on screen: NSScreen) -> CGFloat { screen.visibleFrame.height * 0.75 }

    let state = IslandState()
    private weak var model: AppModel?
    private var panel: IslandPanel?
    private var poll: Timer?
    private var notchRect = NSRect.zero
    private var hoverExpanded = false
    private var hoverSince: Date?
    private var outsideSince: Date?
    private var laidOutHeight: Double = 0
    private var laidOutWidth: Double = 0
    private var liveBody: CGFloat = 0
    private var bag: Set<AnyCancellable> = []
    private let preview = ProcessInfo.processInfo.environment["LISTENFLOW_PREVIEW_ISLAND"]

    init(model: AppModel) {
        self.model = model
        model.objectWillChange
            .sink { [weak self] _ in DispatchQueue.main.async { self?.update() } }
            .store(in: &bag)
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in self?.layout() }
            .store(in: &bag)
        update()
    }

    private func makePanel(_ model: AppModel) -> IslandPanel {
        let panel = IslandPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        // Above the menu bar, which is what the notch sits in.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.becomesKeyOnlyIfNeeded = true
        // Preview builds stay capturable so the layout can be checked in screenshots.
        panel.sharingType = Bundle.main.bundleIdentifier == "local.ListenFlow.preview" ? .readOnly : .none
        panel.ignoresMouseEvents = true
        let view = NotchIslandView(model: model, levels: model.levels, state: state,
                                   onResize: { [weak self] in self?.resize(toScreenY: $0) },
                                   onResizeEnd: { [weak self] in self?.endResize() })
        let host = FirstMouseHostingView(rootView: view)
        host.sizingOptions = []
        panel.contentView = host
        return panel
    }

    private func targetScreen() -> NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main
    }

    private func layout() {
        guard let panel, let model, let screen = targetScreen() else { return }
        let frame = screen.frame
        var notch = CGSize(width: 190, height: max(24, frame.maxY - screen.visibleFrame.maxY))
        var hasNotch = false
        if screen.safeAreaInsets.top > 0, let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            notch = CGSize(width: frame.width - left.width - right.width, height: screen.safeAreaInsets.top)
            hasNotch = true
        }
        if state.notch != notch { state.notch = notch }
        if state.hasNotch != hasNotch { state.hasNotch = hasNotch }
        laidOutHeight = model.preferences.islandHeight
        laidOutWidth = model.preferences.islandWidth
        liveBody = min(max(CGFloat(laidOutHeight), Self.minBody), Self.maxBody(on: screen))
        place(panel, on: screen)
        notchRect = NSRect(x: frame.midX - notch.width / 2, y: frame.maxY - notch.height,
                           width: notch.width, height: notch.height + 2)
    }

    private func update() {
        guard let model else { return }
        guard model.preferences.islandEnabled else {
            poll?.invalidate(); poll = nil
            panel?.orderOut(nil)
            hoverExpanded = false
            if state.mode != .hidden { state.mode = .hidden }
            return
        }
        if panel == nil {
            panel = makePanel(model)
            layout()
        }
        if (laidOutHeight != model.preferences.islandHeight || laidOutWidth != model.preferences.islandWidth) && !state.resizing { layout() }
        if panel?.isVisible == false { panel?.orderFrontRegardless() }
        if poll == nil {
            poll = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.trackMouse() }
            }
        }

        let active = model.isRecording || model.pendingCount > 0
        let mode: IslandState.Mode
        if preview == "expanded" || model.islandPinned || hoverExpanded {
            mode = .expanded
        } else if preview == "compact" || (model.preferences.islandShowLatest && active && !model.session.lines.isEmpty) {
            mode = .compact
        } else {
            mode = .hidden
        }
        if state.mode != mode { state.mode = mode }
        // Only the expanded panel takes clicks; it fills the whole window then.
        // Compact and hidden let everything underneath stay usable.
        panel?.ignoresMouseEvents = mode != .expanded
    }

    private func place(_ panel: NSPanel, on screen: NSScreen) {
        let frame = screen.frame
        // Never narrower than the notch plus room for the controls beside it,
        // never wider than the screen.
        let width = min(max(CGFloat(laidOutWidth), state.notch.width + 300), frame.width - 40)
        let height = state.notch.height + liveBody
        panel.setFrame(NSRect(x: frame.midX - width / 2, y: frame.maxY - height, width: width, height: height), display: true)
    }

    /// Follows the pointer's screen position rather than the gesture's translation:
    /// the panel's top edge is fixed, so its bottom edge simply goes where the mouse is.
    private func resize(toScreenY y: CGFloat) {
        guard let panel, let screen = targetScreen() else { return }
        if !state.resizing { state.resizing = true }
        liveBody = min(max(screen.frame.maxY - y - state.notch.height, Self.minBody), Self.maxBody(on: screen))
        place(panel, on: screen)
    }

    /// Saved once on release, so dragging never republishes settings to the main window.
    private func endResize() {
        guard let model, state.resizing else { return }
        state.resizing = false
        let height = Double(liveBody.rounded())
        laidOutHeight = height
        model.preferences.islandHeight = height
        model.preferences.save()
    }

    /// Polled rather than tracked: the panel ignores the mouse while collapsed, and
    /// a global monitor would need more permissions than a 10 Hz position check.
    private func trackMouse() {
        guard let panel else { return }
        let point = NSEvent.mouseLocation
        let now = Date()
        if !hoverExpanded {
            outsideSince = nil
            if notchRect.insetBy(dx: -8, dy: -2).contains(point) {
                if let since = hoverSince {
                    if now.timeIntervalSince(since) > 0.12 { hoverExpanded = true; hoverSince = nil; update() }
                } else { hoverSince = now }
            } else { hoverSince = nil }
        } else {
            // Mid-drag the pointer can briefly run past the bottom edge.
            let inside = state.resizing || (state.mode == .expanded && panel.frame.contains(point)) || notchRect.contains(point)
            if inside { outsideSince = nil }
            else if let since = outsideSince {
                if now.timeIntervalSince(since) > 0.5 { hoverExpanded = false; outsideSince = nil; update() }
            } else { outsideSince = now }
        }
    }
}

final class IslandPanel: NSPanel {
    // Borderless panels may sit over the menu bar; never let AppKit push it down.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    override var canBecomeKey: Bool { true }
}

/// Buttons should respond to the first click even though the panel never activates the app.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

struct NotchIslandView: View {
    @ObservedObject var model: AppModel
    let levels: AudioLevels
    @ObservedObject var state: IslandState
    var onResize: (CGFloat) -> Void = { _ in }
    var onResizeEnd: () -> Void = {}

    var body: some View {
        GeometryReader { geo in
            let size = shapeSize(in: geo.size)
            let radius: CGFloat = state.mode == .expanded ? 24 : state.mode == .compact ? 16 : 10
            let shape = UnevenRoundedRectangle(cornerRadii: .init(topLeading: 0, bottomLeading: radius,
                                                                  bottomTrailing: radius, topTrailing: 0),
                                               style: .continuous)
            ZStack(alignment: .top) {
                shape.fill(Color.black)
                switch state.mode {
                case .expanded: expanded.transition(.opacity)
                case .compact: compact.transition(.opacity)
                case .hidden: EmptyView()
                }
            }
            .frame(width: size.width, height: size.height)
            .clipShape(shape)
            .opacity(state.mode == .hidden ? 0 : 1)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .animation(.spring(response: 0.36, dampingFraction: 0.86), value: state.mode)
        .environment(\.colorScheme, .dark)
    }

    private func shapeSize(in panel: CGSize) -> CGSize {
        switch state.mode {
        case .expanded: panel
        case .compact: CGSize(width: min(panel.width, max(state.notch.width + 220, 520)), height: state.notch.height + 30)
        case .hidden: state.notch
        }
    }

    // MARK: Expanded

    private var expanded: some View {
        VStack(spacing: 0) {
            header.frame(height: state.notch.height)
            transcript
            resizeHandle
        }
    }

    /// Drag the bottom edge to set the height; it is remembered.
    private var resizeHandle: some View {
        Capsule().fill(.white.opacity(state.resizing ? 0.55 : 0.25)).frame(width: 38, height: 4)
            .frame(maxWidth: .infinity).frame(height: 14)
            .contentShape(Rectangle())
            .onHover { inside in inside ? NSCursor.resizeUpDown.push() : NSCursor.pop() }
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { _ in onResize(NSEvent.mouseLocation.y) }
                .onEnded { _ in onResizeEnd() })
            .help("拖动调整高度")
    }

    /// Status on the left of the notch, controls on the right; nothing under the camera.
    private var header: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                if model.isRecording {
                    Circle().fill(Color.red).frame(width: 7, height: 7)
                    TimelineView(.periodic(from: model.session.created, by: 1)) { context in
                        Text(SessionStore.timestamp(context.date, relativeTo: model.session.created))
                            .font(.system(size: 11.5, weight: .medium, design: .monospaced)).monospacedDigit()
                    }
                } else {
                    Text(model.pendingCount > 0 ? "识别中" : "未在转写").font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.6))
                }
                iconButton(model.isRecording ? "pause.fill" : "record.circle", help: model.isRecording ? "暂停转写" : "开始转写") {
                    Task { await model.toggleRecording() }
                }.disabled(!model.canToggleRecording)
            }
            Spacer(minLength: state.notch.width + 20)
            HStack(spacing: 12) {
                if model.isRecording { IslandLevel(levels: levels) }
                iconButton(model.islandPinned ? "pin.fill" : "pin", help: model.islandPinned ? "取消固定，移开鼠标后收起" : "固定展开") {
                    model.islandPinned.toggle()
                }.foregroundStyle(model.islandPinned ? Color(red: 0.35, green: 0.85, blue: 0.75) : .white.opacity(0.8))
                iconButton("macwindow", help: "打开听流窗口") { model.showMainWindow() }
            }
        }
        .foregroundStyle(.white.opacity(0.9))
        .padding(.horizontal, 22)
    }

    private func iconButton(_ name: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: name).font(.system(size: 12, weight: .medium)).frame(width: 18, height: 18) }
            .buttonStyle(.plain).help(help)
    }

    private var shownLines: [TranscriptLine] {
        Array(model.session.lines.suffix(40))
    }

    /// Label sources once more than one is in play, so a meeting's other side and
    /// the room microphone can be told apart.
    private var showSources: Bool {
        Set(shownLines.map(\.source)).count > 1 || (model.micEnabled && model.activeSource == .app)
    }

    private var transcript: some View {
        let lines = shownLines
        let tail = model.liveTailStart
        let tags = showSources
        return ScrollViewReader { proxy in
            ScrollView {
                // Eager on purpose: 40 rows are cheap, and a lazy stack measured late
                // left the newest line below the fold when the island opened.
                VStack(alignment: .leading, spacing: 12) {
                    if lines.isEmpty {
                        Text(model.isRecording ? "正在听，第一句识别出来后会显示在这里。" : "开始转写后，最近的内容会显示在这里。")
                            .font(.system(size: 13)).foregroundStyle(.white.opacity(0.5))
                            .frame(maxWidth: .infinity).padding(.top, 40)
                    }
                    ForEach(Array(lines.enumerated()), id: \.element.id) { index, line in
                        if line.id == tail {
                            Line().stroke(.white.opacity(0.22), style: StrokeStyle(lineWidth: 1, dash: [3, 4])).frame(height: 1)
                        }
                        row(line, distance: lines.count - 1 - index, tags: tags)
                    }
                    if model.pendingCount > 0 {
                        HStack(spacing: 7) {
                            ProgressView().controlSize(.mini)
                            Text("正在识别…").font(.system(size: 11)).foregroundStyle(.white.opacity(0.45))
                        }.padding(.leading, 62)
                    }
                    Color.clear.frame(height: 1).id("end")
                }
                .padding(.horizontal, 22).padding(.top, 8).padding(.bottom, 6)
            }
            .scrollIndicators(.never)
            // Lazy rows are measured late; anchoring keeps the newest line in view
            // where a one-off scrollTo on appear could stop short.
            .defaultScrollAnchor(.bottom)
            // Older lines fade into the top edge, like scrolling lyrics.
            .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.08),
                                         .init(color: .black, location: 1)], startPoint: .top, endPoint: .bottom))
            .onAppear {
                proxy.scrollTo("end", anchor: .bottom)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { proxy.scrollTo("end", anchor: .bottom) }
            }
            .onChange(of: scrollKey(lines)) { _, _ in
                withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo("end", anchor: .bottom) }
            }
        }
    }

    private func scrollKey(_ lines: [TranscriptLine]) -> String {
        "\(lines.count)-\(lines.last?.id.uuidString ?? "")-\(lines.last?.text.count ?? 0)-\(model.pendingCount > 0)"
    }

    private func row(_ line: TranscriptLine, distance: Int, tags: Bool) -> some View {
        let opacity: Double = distance == 0 ? 1 : distance == 1 ? 0.82 : max(0.45, 0.7 - 0.06 * Double(distance - 2))
        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(SessionStore.timestamp(line.start, relativeTo: model.session.created))
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(.white.opacity(0.38))
                if tags { SourceTag(source: line.source) }
            }.frame(width: 52, alignment: .leading)
            Text(line.text)
                .font(.system(size: 14, weight: distance == 0 ? .medium : .regular))
                .foregroundStyle(.white.opacity(opacity))
                .lineSpacing(4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
    }

    // MARK: Compact

    /// Optional always-on strip: just the newest line, below the notch.
    private var compact: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: state.notch.height)
            if let line = model.session.lines.last {
                HStack(spacing: 8) {
                    if showSources { SourceTag(source: line.source) }
                    Text(line.text).font(.system(size: 12.5)).foregroundStyle(.white.opacity(0.92))
                        .lineLimit(1).truncationMode(.head)
                }
                .padding(.horizontal, 18).frame(height: 30)
            }
        }
    }
}

private struct SourceTag: View {
    let source: String
    var body: some View {
        let mic = source == "麦克风"
        Text(source).font(.system(size: 9.5, weight: .medium)).lineLimit(1)
            .foregroundStyle(mic ? Color(red: 0.55, green: 0.92, blue: 0.82) : Color(red: 0.62, green: 0.76, blue: 1))
            .padding(.horizontal, 5).padding(.vertical, 1.5)
            .background((mic ? Color(red: 0.2, green: 0.7, blue: 0.6) : Color(red: 0.3, green: 0.5, blue: 1)).opacity(0.22),
                        in: RoundedRectangle(cornerRadius: 4))
            .fixedSize()
    }
}

/// Five bars driven by the capture level, observed on its own so level updates
/// redraw only this view.
private struct IslandLevel: View {
    @ObservedObject var levels: AudioLevels
    private let shape: [CGFloat] = [0.55, 1, 0.75, 0.9, 0.6]
    var body: some View {
        let value = CGFloat(max(levels.app, levels.mic)).squareRoot()
        HStack(spacing: 2) {
            ForEach(0..<5, id: \.self) { i in
                Capsule().fill(.white.opacity(0.85)).frame(width: 2.5, height: 3 + 11 * min(1, value * shape[i] * 1.3))
            }
        }
        .frame(height: 14)
        .animation(.easeOut(duration: 0.15), value: value)
    }
}

private struct Line: Shape {
    func path(in rect: CGRect) -> Path {
        Path { $0.move(to: CGPoint(x: 0, y: rect.midY)); $0.addLine(to: CGPoint(x: rect.maxX, y: rect.midY)) }
    }
}
