import AppKit
import AVFoundation
import SwiftUI

@MainActor final class MirrorWindowController: NSWindowController, NSWindowDelegate {
    private let session: MirrorSession
    private weak var model: AppModel?
    private var layout: DeviceWindowLayout
    private var changingSize = false
    private var configured = false
    private var normalScale: CGFloat?
    static let fusionToolbarHeight: CGFloat = 40
    private var isFusion: Bool { session.mode == "fusion" }
    private var pinKey: String { "windowPinned-" + (session.package ?? "phone") }
    var requestedGeometry: StreamGeometry {
        let size = window?.contentView?.bounds.size ?? NSSize(width: 420, height: 760)
        return StreamGeometry(contentWidth: size.width, contentHeight: size.height - Self.fusionToolbarHeight)
    }
    private var scaleKey: String { "deviceScale-" + (session.package ?? "phone") }
    init(session: MirrorSession, model: AppModel) {
        self.session = session; self.model = model
        layout = DeviceWindowLayout(width: session.width, height: session.height)
        let fusion = session.mode == "fusion"
        let window: NSWindow
        if fusion {
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 760),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        } else {
            window = DeviceWindow(contentRect: NSRect(origin: .zero, size: layout.size(scale: 0.9)),
                                  styleMask: [.borderless, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        }
        window.title = session.name + " · Macroid"
        window.isOpaque = fusion; window.backgroundColor = fusion ? .windowBackgroundColor : .clear; window.hasShadow = fusion
        window.isReleasedWhenClosed = false; window.isMovableByWindowBackground = false
        window.animationBehavior = .documentWindow
        super.init(window: window)
        window.delegate = self
        (window as? DeviceWindow)?.fitDevice = { [weak self] in self?.toggleFit() }
        let hosted = NSHostingView(rootView: MirrorRootView(session: session, model: model,
            close: { [weak window] in window?.close() },
            minimize: { [weak window] in window?.miniaturize(nil) },
            fit: { [weak self] in self?.toggleFit() },
            layout: { [weak self] in self?.layout ?? DeviceWindowLayout(width: 720, height: 1280) }))
        if fusion { window.contentView = hosted }
        else {
            window.contentView = DeviceContentView(hosted: hosted, isMirror: true,
                layout: { [weak self] in self?.layout ?? DeviceWindowLayout(width: 720, height: 1280) },
                resize: { [weak self] size, anchor, edges in self?.resize(size, anchor: anchor, edges: edges) })
        }
        window.acceptsMouseMovedEvents = true
        updateLimits(); window.center()
        let frameName = (fusion ? "Macroid-fusion-" : "Macroid-device-") + (session.package ?? "phone")
        window.setFrameAutosaveName(frameName)
        if fusion { window.setFrameUsingName(frameName) }
        setPinned(UserDefaults.standard.bool(forKey: pinKey))
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func windowWillClose(_ notification: Notification) { model?.closeStream(session.id) }
    func setPinned(_ value: Bool) {
        session.pinned = value; window?.level = value ? .floating : .normal
        UserDefaults.standard.set(value, forKey: pinKey)
    }
    func updateAspect() {
        guard let window else { return }
        if isFusion {
            configured = true
            if session.dynamicResize { model?.resize(session, to: requestedGeometry) }
            return
        }
        layout = DeviceWindowLayout(width: session.width, height: session.height)
        updateLimits()
        let saved = CGFloat(UserDefaults.standard.double(forKey: scaleKey))
        let scale = limited(saved > 0 ? saved : min(1, maximumScale() * 0.94))
        setScale(scale, anchor: window.frame)
        configured = true
    }
    private func maximumScale() -> CGFloat {
        let area = (window?.screen ?? NSScreen.main)?.visibleFrame.size ?? NSSize(width: 1440, height: 900)
        return max(0.3, layout.scale(fitting: NSSize(width: area.width - 16, height: area.height - 16)))
    }
    private func limited(_ scale: CGFloat) -> CGFloat { min(maximumScale(), max(min(0.65, maximumScale()), scale)) }
    private func updateLimits() {
        guard let window else { return }
        if isFusion { window.contentMinSize = NSSize(width: 320, height: 240 + Self.fusionToolbarHeight); return }
        window.minSize = layout.size(scale: min(0.65, maximumScale()))
        window.maxSize = layout.size(scale: maximumScale())
    }
    private func setScale(_ scale: CGFloat, anchor: NSRect, edges: DeviceResizeEdges = []) {
        guard let window else { return }
        let size = layout.size(scale: limited(scale))
        var frame = NSRect(x: edges.contains(.left) ? anchor.maxX - size.width : anchor.minX,
                           y: edges.contains(.top) ? anchor.minY : anchor.maxY - size.height, width: size.width, height: size.height)
        if let area = (window.screen ?? NSScreen.main)?.visibleFrame {
            frame.origin.x = max(area.minX, min(frame.minX, area.maxX - frame.width))
            frame.origin.y = max(area.minY, min(frame.minY, area.maxY - frame.height))
        }
        changingSize = true; window.setFrame(frame, display: true); changingSize = false
    }
    private func resize(_ proposed: NSSize, anchor: NSRect, edges: DeviceResizeEdges) {
        let dx = (proposed.width - anchor.width) / layout.body.width
        let dy = (proposed.height - anchor.height) / layout.body.height
        let scale = layout.scale(fitting: anchor.size) + (abs(dx) > abs(dy) ? dx : dy)
        normalScale = nil; setScale(scale, anchor: anchor, edges: edges); saveScale()
    }
    private func toggleFit() {
        guard let window else { return }
        if isFusion { window.zoom(nil); return }
        if let previous = normalScale { normalScale = nil; setScale(previous, anchor: window.frame) }
        else { normalScale = layout.scale(fitting: window.frame.size); setScale(maximumScale(), anchor: window.frame) }
        saveScale()
    }
    private func saveScale() {
        guard configured, !changingSize, let window else { return }
        UserDefaults.standard.set(Double(layout.scale(fitting: window.frame.size)), forKey: scaleKey)
    }
    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        if isFusion {
            if session.dynamicResize { return frameSize }
            let title = sender.frame.height - (sender.contentView?.frame.height ?? 0)
            return NSSize(width: frameSize.width, height: frameSize.width * CGFloat(session.height) / CGFloat(session.width) + title + Self.fusionToolbarHeight)
        }
        let dx = (frameSize.width - sender.frame.width) / layout.body.width
        let dy = (frameSize.height - sender.frame.height) / layout.body.height
        let scale = layout.scale(fitting: sender.frame.size) + (abs(dx) > abs(dy) ? dx : dy)
        return layout.size(scale: limited(scale))
    }
    func windowDidResize(_ notification: Notification) {
        if isFusion {
            if configured, session.dynamicResize { model?.resize(session, to: requestedGeometry) }
        } else { saveScale() }
    }
    func windowDidEndLiveResize(_ notification: Notification) {
        if isFusion, configured, session.dynamicResize { model?.resize(session, to: requestedGeometry) }
    }
    func windowDidChangeScreen(_ notification: Notification) { updateLimits() }
}

struct MirrorRootView: View {
    @ObservedObject var session: MirrorSession
    @ObservedObject var model: AppModel
    let close: () -> Void, minimize: () -> Void, fit: () -> Void
    let layout: () -> DeviceWindowLayout
    @State private var showKeyboardHelp = false
    var body: some View {
        Group {
            if session.mode == "fusion" {
                VStack(spacing: 0) {
                    toolbar.frame(height: MirrorWindowController.fusionToolbarHeight).overlay(alignment: .bottom) { Divider() }
                    ZStack(alignment: .top) {
                        Color.black
                        VideoSurface(session: session, model: model, cornerRadius: 0)
                        MirrorLoadingView(session: session, renderer: session.renderer, model: model)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        if let notice = session.notice {
                            Text(notice).font(.caption).padding(8).background(.regularMaterial).padding(6)
                        }
                    }
                }
            } else {
                GeometryReader { proxy in
                    let deviceLayout = layout()
                    let scale = deviceLayout.scale(fitting: proxy.size)
                    VStack(spacing: DeviceWindowLayout.toolbarGap) {
                        toolbar.frame(height: DeviceWindowLayout.toolbarHeight)
                        device(deviceLayout, scale: scale)
                    }
                    .padding(DeviceWindowLayout.margin)
                    .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
                }
            }
        }
        .alert("启用 Macroid 键盘", isPresented: $showKeyboardHelp) {
            Button("启用") { Task { await model.setIME(true) } }
            Button("取消", role: .cancel) { }
        } message: {
            Text("连接期间将手机输入法切换为 Macroid，以接收 Mac 的中文和其他 Unicode 文字。断开连接时会恢复原输入法。Android 12/13 的输入焦点可能与手机共享。")
        }
    }
    private var toolbar: some View {
        HStack(spacing: 5) {
            if session.mode == "mirror" { DeviceTrafficLights(close: close, minimize: minimize, fit: fit).padding(.trailing, 5) }
            if session.mode == "mirror" { Text(session.name).font(.system(size: 11, weight: .medium)).lineLimit(1).truncationMode(.tail).help(session.name) }
            WindowDragRegion().frame(minWidth: 36, maxWidth: .infinity, minHeight: 30).accessibilityHidden(true)
            control("chevron.left", "返回 · Esc") { model.key(session, code: 4) }
            if session.mode == "mirror" {
                control("house", "主页") { model.key(session, code: 3) }
                control("square.stack", "最近任务") { model.key(session, code: 187) }
            }
            control(model.imeEnabled ? "keyboard.fill" : "keyboard", "Macroid 键盘") {
                if model.imeEnabled { Task { await model.setIME(false) } } else { showKeyboardHelp = true }
            }
            Menu {
                Toggle("窗口置顶", isOn: Binding(get: { session.pinned }, set: { model.setPinned(session, $0) }))
                Toggle("关屏使用", isOn: Binding(get: { model.screenOff }, set: { value in Task { await model.setScreenOff(value) } }))
                    .disabled(!model.screenPowerSupported || model.screenPowerBusy || !model.sessions.values.contains(where: { $0.ready }))
                if !model.screenPowerSupported { Text(model.screenPowerReason) }
                Divider()
                Button("适合屏幕", action: fit)
                Divider()
                Button("复制 Mac 剪贴板到 Android") { Task { await model.clipboard(toAndroid: true) } }
                Button("复制 Android 剪贴板到 Mac") { Task { await model.clipboard(toAndroid: false) } }
                Button("重新连接画面") { model.retryStream(session) }
                Divider()
                Text(session.encoding.isEmpty ? "正在连接…" : session.encoding)
                Divider()
                Button("关闭窗口", action: close)
            } label: { Image(systemName: "ellipsis").font(.system(size: 14, weight: .medium)).frame(width: 22, height: 26) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("更多操作").accessibilityLabel("更多操作")
        }.padding(.horizontal, 11)
            .background(Color(nsColor: .windowBackgroundColor).opacity(0.98), in: RoundedRectangle(cornerRadius: session.mode == "fusion" ? 0 : 9, style: .continuous))
            .overlay {
                if session.mode == "mirror" { RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(.primary.opacity(0.14), lineWidth: 0.6).allowsHitTesting(false) }
            }
    }
    private func control(_ symbol: String, _ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).font(.system(size: 12, weight: .medium)).frame(width: 22, height: 26).contentShape(Rectangle()) }
            .buttonStyle(.plain).help(title).accessibilityLabel(title).disabled(!session.acceptsInput)
    }
    private func device(_ layout: DeviceWindowLayout, scale: CGFloat) -> some View {
        let radius = (DeviceWindowLayout.screenRadius + DeviceWindowLayout.bezel) * scale
        let screenRadius = DeviceWindowLayout.screenRadius * scale
        return ZStack {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(LinearGradient(colors: [Color(white: 0.34), Color(white: 0.11), Color(white: 0.23)], startPoint: .topLeading, endPoint: .bottomTrailing))
            RoundedRectangle(cornerRadius: radius - 1.5 * scale, style: .continuous)
                .fill(Color(white: 0.035)).padding(2 * scale)
            ZStack {
                Color(white: 0.055)
                VideoSurface(session: session, model: model, cornerRadius: screenRadius)
                MirrorLoadingView(session: session, renderer: session.renderer, model: model)
            }
            .frame(width: layout.screen.width * scale, height: layout.screen.height * scale)
            .clipShape(RoundedRectangle(cornerRadius: screenRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: screenRadius, style: .continuous).strokeBorder(.white.opacity(0.07), lineWidth: 0.5).allowsHitTesting(false))
        }
        .frame(width: layout.body.width * scale, height: layout.body.height * scale)
        .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(.white.opacity(0.25), lineWidth: 0.6).allowsHitTesting(false))
        .overlay(alignment: .trailing) { Capsule().fill(Color(white: 0.27)).frame(width: 2 * scale, height: 48 * scale).offset(x: 1.5 * scale, y: -layout.body.height * scale * 0.21).allowsHitTesting(false) }
        .overlay(alignment: .leading) {
            VStack(spacing: 11 * scale) { Capsule().frame(height: 25 * scale); Capsule().frame(height: 42 * scale) }
                .foregroundStyle(Color(white: 0.27)).frame(width: 2 * scale).offset(x: -1.5 * scale, y: -layout.body.height * scale * 0.20).allowsHitTesting(false)
        }

    }
}

private struct MirrorLoadingView: View {
    @ObservedObject var session: MirrorSession
    @ObservedObject var renderer: VideoRenderer
    @ObservedObject var model: AppModel
    var body: some View {
        if let error = session.error ?? renderer.error {
            VStack(spacing: 16) {
                Image(systemName: "rectangle.slash").font(.system(size: 32, weight: .light))
                Text(session.mode == "mirror" ? "无法开始投屏" : "无法打开应用窗口").font(.headline)
                ScrollView { Text(error).font(.callout).textSelection(.enabled).frame(maxWidth: .infinity) }.frame(maxHeight: 160)
                Button("重新尝试") { model.retryStream(session) }.buttonStyle(.borderedProminent)
                if session.mode == "fusion" {
                    Button("投屏手机主屏幕") { model.open() }.buttonStyle(.borderless)
                    Text("部分应用或手机系统会限制独立窗口。").font(.caption).foregroundStyle(.secondary)
                }
            }.multilineTextAlignment(.center).padding(20).frame(maxWidth: 360).foregroundStyle(.white)
        } else if !renderer.hasFrame {
            VStack(spacing: 16) {
                ProgressView().controlSize(.small)
                Text(session.mode == "mirror" ? "正在连接手机屏幕…" : "正在打开应用窗口…").font(.callout)
            }.foregroundStyle(.white.opacity(0.85)).padding(20)
        }
    }
}

struct VideoSurface: NSViewRepresentable {
    let session: MirrorSession, model: AppModel
    let cornerRadius: CGFloat
    func makeNSView(context: Context) -> InputSurface { InputSurface(session: session, model: model) }
    func updateNSView(_ view: InputSurface, context: Context) {
        view.layer?.cornerRadius = cornerRadius; view.layer?.masksToBounds = true
        view.needsLayout = true
    }
}

@MainActor final class InputSurface: NSView, @preconcurrency NSTextInputClient {
    private let session: MirrorSession
    private weak var model: AppModel?
    private var marked = NSAttributedString(string: "")
    private var dragging = false
    private var lastMove: TimeInterval = 0
    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }
    init(session: MirrorSession, model: AppModel) {
        self.session = session; self.model = model
        super.init(frame: .zero); wantsLayer = true; layer?.backgroundColor = NSColor.clear.cgColor; layer?.masksToBounds = true
        layer?.addSublayer(session.renderer.container)
        session.cancelPointer = { [weak self] in
            guard let self, self.dragging else { return }
            self.model?.pointer(self.session, action: 3, x: 0, y: 0); self.dragging = false
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layout() {
        super.layout()
        session.renderer.layout(in: bounds)
    }
    private func coordinate(_ event: NSEvent, clamp: Bool = false) -> CGPoint? {
        let rect = AVMakeRect(aspectRatio: CGSize(width: session.width, height: session.height), insideRect: bounds)
        guard rect.width > 0, rect.height > 0 else { return nil }
        let point = convert(event.locationInWindow, from: nil)
        guard clamp || rect.contains(point) else { return nil }
        return CGPoint(x: max(0, min(CGFloat(session.width - 1), (point.x - rect.minX) / rect.width * CGFloat(session.width))),
                       y: max(0, min(CGFloat(session.height - 1), (point.y - rect.minY) / rect.height * CGFloat(session.height))))
    }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard session.acceptsInput, let p = coordinate(event) else { return }; dragging = true
        model?.pointer(session, action: 0, x: p.x, y: p.y)
    }
    override func mouseDragged(with event: NSEvent) {
        guard dragging, event.timestamp - lastMove > 1 / 90, let p = coordinate(event, clamp: true) else { return }
        lastMove = event.timestamp; model?.pointer(session, action: 2, x: p.x, y: p.y)
    }
    override func mouseUp(with event: NSEvent) {
        guard dragging, let p = coordinate(event, clamp: true) else { return }; dragging = false
        model?.pointer(session, action: 1, x: p.x, y: p.y)
    }
    override func rightMouseDown(with event: NSEvent) { model?.key(session, code: 4) }
    override func scrollWheel(with event: NSEvent) {
        guard let p = coordinate(event) else { return }
        model?.pointer(session, action: 8, x: p.x, y: p.y, scrollX: event.scrollingDeltaX / 12, scrollY: event.scrollingDeltaY / 12)
    }
    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "v": model?.text(session, text: NSPasteboard.general.string(forType: .string) ?? ""); return
            case "a": model?.key(session, code: 29, meta: 4096); return
            case "c": model?.key(session, code: 31, meta: 4096); return
            case "x": model?.key(session, code: 52, meta: 4096); return
            case "z": model?.key(session, code: 54, meta: 4096); return
            default: super.keyDown(with: event); return
            }
        }
        let codes: [UInt16: Int] = [51: 67, 117: 112, 36: 66, 76: 66, 48: 61, 123: 21, 124: 22, 125: 20, 126: 19, 53: 4, 115: 122, 119: 123, 116: 92, 121: 93]
        if !hasMarkedText(), let code = codes[event.keyCode] { model?.key(session, code: code); return }
        interpretKeyEvents([event])
    }
    func insertText(_ string: Any, replacementRange: NSRange) {
        let text = (string as? NSAttributedString)?.string ?? string as? String ?? ""
        marked = NSAttributedString(string: ""); model?.text(session, text: text)
    }
    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) { marked = (string as? NSAttributedString) ?? NSAttributedString(string: string as? String ?? "") }
    func unmarkText() { marked = NSAttributedString(string: "") }
    func selectedRange() -> NSRange { NSRange(location: 0, length: 0) }
    func markedRange() -> NSRange { marked.length > 0 ? NSRange(location: 0, length: marked.length) : NSRange(location: NSNotFound, length: 0) }
    func hasMarkedText() -> Bool { marked.length > 0 }
    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }
    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let window else { return .zero }
        return window.convertToScreen(convert(NSRect(x: bounds.midX, y: bounds.midY, width: 1, height: 20), to: nil))
    }
    func characterIndex(for point: NSPoint) -> Int { 0 }
    override func doCommand(by selector: Selector) {
        let codes = ["deleteBackward:": 67, "insertNewline:": 66, "insertTab:": 61, "cancelOperation:": 4]
        if let code = codes[NSStringFromSelector(selector)] { model?.key(session, code: code) }
    }
}
