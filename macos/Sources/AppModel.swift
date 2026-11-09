import AppKit
import SwiftUI

struct AndroidApp: Identifiable {
    let package: String, name: String
    var id: String { package }
}

@MainActor final class MirrorSession: ObservableObject, Identifiable {
    let id: UInt32, package: String?, mode: String
    private let appName: String
    var name: String { package == nil ? L("手机屏幕") : appName }
    let renderer = VideoRenderer()
    @Published var width = 720
    @Published var height = 1280
    let dynamicResize: Bool
    @Published var ready = false
    @Published var resizing = false
    @Published var pinned = false
    @Published var quality: FusionQuality = .automatic
    @Published var rotating = false
    @Published var rotationLocked = false
    @Published var notice: String?
    var generation = 0
    var rotation = 0
    var displayID = 0
    var density = 240
    var pendingGeometry: StreamGeometry?
    var requestedGeometry: StreamGeometry?
    var resizeTask: Task<Void, Never>?
    var resizeTaskID = UUID()
    var lastResizeTime: TimeInterval = 0
    var cancelPointer: (() -> Void)?
    var acceptsInput: Bool { ready && !resizing && !rotating && error == nil && renderer.error == nil }
    @Published var encoding = ""
    @Published var error: String?
    init(id: UInt32, name: String, package: String?, mode: String, dynamicResize: Bool = false) {
        self.id = id; self.appName = name; self.package = package; self.mode = mode; self.dynamicResize = dynamicResize
        if let package, let stored = UserDefaults.standard.string(forKey: "fusionQuality-" + package), let value = FusionQuality(rawValue: stored) { quality = value }
    }
    func apply(_ info: [String: Any]) {
        width = info["width"] as? Int ?? width; height = info["height"] as? Int ?? height
        density = info["density"] as? Int ?? density; displayID = info["display"] as? Int ?? displayID
        generation = info["generation"] as? Int ?? generation
        applyRotation(info)
        encoding = "\(width) × \(height) · \(info["fps"] as? Int ?? 30) fps · \(info["encoder"] as? String ?? "H.264")"
    }
    func applyRotation(_ info: [String: Any]) {
        rotation = info["rotation"] as? Int ?? rotation
        rotationLocked = info["rotationLocked"] as? Bool ?? rotationLocked
    }
}

@MainActor final class AppModel: ObservableObject {
    static let shared = AppModel()
    @Published var devices: [AndroidDevice] = []
    @Published var selectedSerial: String = ""
    @Published var connectedDevice: AndroidDevice?
    @Published var connecting = false
    @Published var refreshing = false
    @Published var status = "等待连接"
    @Published var sdk = 0
    @Published var apps: [AndroidApp] = []
    @Published var icons: [String: NSImage] = [:]
    @Published var sessions: [UInt32: MirrorSession] = [:]
    @Published var error: String?
    @Published var imeEnabled = false
    @Published var screenOff = false
    @Published var screenPowerBusy = false
    @Published var screenPowerSupported = false
    @Published var screenPowerReason = "设备未连接"
    private(set) var resizeSupported = false
    private(set) var configSupported = false
    private(set) var rotationSupported = false
    private var connectionID = UUID()
    @Published var search = ""
    @Published var section = "apps"
    @Published var transferProgress: Double?
    @Published var transferLabel = ""
    @Published var wirelessBusy = false
    @Published var wirelessStatus = ""
    @Published var favorites = Set(UserDefaults.standard.stringArray(forKey: "favoriteApps") ?? [])
    var fusionEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "fusionEnabled") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "fusionEnabled"); objectWillChange.send() }
    }
    private var adb = ADBClient()
    private(set) var transport: Transport?
    private var nextStream: UInt32 = 1
    private var windows: [UInt32: MirrorWindowController] = [:]
    private var iconTask: Task<Void, Never>?
    @Published private(set) var disconnecting = false

    var connected: Bool { connectedDevice != nil }
    var filteredApps: [AndroidApp] {
        guard !search.isEmpty else { return apps }
        return apps.filter { $0.name.localizedCaseInsensitiveContains(search) || $0.package.localizedCaseInsensitiveContains(search) }
    }
    func refresh(silent: Bool = false) async {
        guard !refreshing else { return }; refreshing = true; defer { refreshing = false }
        do {
            if !connected && !connecting { adb = ADBClient() }
            devices = try await adb.devices()
            if !devices.contains(where: { $0.serial == selectedSerial }) { selectedSerial = devices.first(where: \.available)?.serial ?? devices.first?.serial ?? "" }
        } catch { if !silent { self.error = error.localizedDescription } }
    }
    func connect() async {
        guard !connecting, !disconnecting, !connected, let device = devices.first(where: { $0.serial == selectedSerial }), device.available else { return }
        connecting = true; error = nil; defer { connecting = false }
        do {
            let (port, token) = try await adb.start(serial: device.serial) { text in Task { @MainActor in self.status = text } }
            let connectionID = UUID(); self.connectionID = connectionID
            let transport = Transport(onVideo: { [weak self] packet in
                guard let self, self.connectionID == connectionID else { return }
                self.sessions[packet.stream]?.renderer.consume(packet)
            }, onEvent: { [weak self] event in
                guard let self, self.connectionID == connectionID else { return }
                self.handle(event)
            }, onDisconnect: { [weak self] error in
                guard let self, self.connectionID == connectionID, !self.disconnecting else { return }
                self.error = error.localizedDescription
                Task { await self.disconnect() }
            })
            self.transport = transport
            try await transport.connect(port: port)
            let info = try await transport.request("hello", ["token": token])
            guard info["product"] as? String == "Macroid", info["protocol"] as? Int == 1 else { throw WireError.malformed }
            sdk = info["sdk"] as? Int ?? 0
            let capabilities = info["capabilities"] as? [String: Any] ?? [:]
            let ownFocus = capabilities["ownFocus"] as? Bool ?? false
            configSupported = capabilities["streamConfig"] as? Bool ?? false
            resizeSupported = configSupported && capabilities["resize"] as? Bool == true
            rotationSupported = configSupported && capabilities["rotation"] as? Bool == true
            screenPowerSupported = capabilities["screenPower"] as? Bool ?? false
            screenPowerReason = capabilities["screenPowerReason"] as? String ?? "手机助手不支持关屏使用"
            connectedDevice = device; status = ownFocus ? "已连接 · 独立焦点" : (sdk < 34 ? "已连接 · Android 12/13 兼容模式" : "已连接 · 兼容显示模式")
            try await loadApps()
        } catch { self.error = error.localizedDescription; await disconnect() }
    }
    func disconnect() async {
        guard !disconnecting else { return }; disconnecting = true
        iconTask?.cancel(); iconTask = nil
        for session in sessions.values { session.resizeTask?.cancel(); session.pendingGeometry = nil }
        if screenOff, let transport { _ = try? await transport.request("device.screenPower", ["screenOff": false]) }
        if imeEnabled, let transport { _ = try? await transport.request("ime.disable", timeout: 20) }
        imeEnabled = false
        let controllers = Array(windows.values); windows.removeAll()
        for window in controllers { window.close() }
        for session in sessions.values { session.renderer.reset() }; sessions.removeAll()
        connectionID = UUID(); transport?.close(); transport = nil
        screenOff = false; screenPowerBusy = false; screenPowerSupported = false
        resizeSupported = false; configSupported = false; rotationSupported = false; screenPowerReason = "设备未连接"
        await adb.stop()
        connectedDevice = nil; apps = []; icons = [:]; status = "等待连接"; sdk = 0; transferProgress = nil
        disconnecting = false
    }
    func loadApps() async throws {
        guard let transport else { throw WireError.disconnected }
        let result = try await transport.request("apps.list")
        apps = (result["apps"] as? [[String: Any]] ?? []).compactMap {
            guard let name = $0["name"] as? String, let package = $0["package"] as? String else { return nil }
            return AndroidApp(package: package, name: name)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        iconTask?.cancel()
        iconTask = Task { [weak self] in
            guard let self else { return }
            for app in self.apps {
                if Task.isCancelled || !self.connected { return }
                guard self.icons[app.package] == nil else { continue }
                if let result = try? await transport.request("apps.icon", ["package": app.package]),
                   let encoded = result["png"] as? String, let data = Data(base64Encoded: encoded), let icon = NSImage(data: data) { self.icons[app.package] = icon }
            }
        }
    }
    func open(_ app: AndroidApp? = nil) {
        guard connected, !disconnecting, let transport else { return }
        if let app, !fusionEnabled {
            Task {
                do { _ = try await transport.request("apps.launch", ["package": app.package]); self.open() }
                catch { self.error = error.localizedDescription }
            }
            return
        }
        // Reuse an existing window for a package; Android launch modes may only permit one task.
        if let existing = sessions.values.first(where: { $0.package == app?.package }) { showStream(existing.id); return }
        guard sessions.count < 4 else { error = "最多同时打开四个窗口，实际数量还取决于手机编码器能力。"; return }
        let id = nextStream; nextStream += 1
        let session = MirrorSession(id: id, name: app?.name ?? "手机屏幕", package: app?.package, mode: app == nil ? "mirror" : "fusion", dynamicResize: app != nil && resizeSupported)
        session.renderer.onFirstFrame = { [weak self, weak session] in
            guard let self, let session, self.sessions[id] === session else { return }
            session.ready = true
        }
        sessions[id] = session
        let controller = MirrorWindowController(session: session, model: self)
        windows[id] = controller; controller.showWindow(nil); NSApp.activate(ignoringOtherApps: true)
        startStream(session, controller: controller)
    }
    func showStream(_ id: UInt32) {
        guard !disconnecting, let controller = windows[id], let window = controller.window else { return }
        controller.showWindow(nil)
        if window.isMiniaturized { window.deminiaturize(nil) }
        NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
    }
    private func startStream(_ session: MirrorSession, controller: MirrorWindowController) {
        guard let transport else { return }
        Task {
            do {
                var request: [String: Any] = ["stream": session.id, "mode": session.mode, "width": 720, "height": 1280, "density": 240, "fps": 60, "bitrate": 6_000_000]
                if session.mode == "fusion" { request["bitrate"] = 12_000_000; request["maxSize"] = 4096 }
                if let package = session.package { request["package"] = package }
                if self.configSupported { request["configEvents"] = true }
                if session.dynamicResize {
                    let geometry = controller.requestedGeometry
                    request.merge(geometry.values) { _, new in new }; session.requestedGeometry = geometry
                }
                let info = try await transport.request("stream.open", request, timeout: 45)
                guard self.sessions[session.id] != nil else { transport.notify("stream.close", ["stream": session.id]); return }
                if session.generation == 0 { session.apply(info) }
                if !self.configSupported { session.ready = true }
                controller.updateAspect()
            } catch { session.error = error.localizedDescription }
        }
    }
    func retryStream(_ session: MirrorSession) {
        guard let transport, let controller = windows[session.id], sessions[session.id] != nil else { return }
        session.resizeTaskID = UUID(); session.resizeTask?.cancel(); session.resizeTask = nil; session.pendingGeometry = nil
        session.cancelPointer?(); session.error = nil; session.notice = nil; session.ready = false; session.resizing = false
        session.generation = 0; session.renderer.reset()
        Task {
            do {
                _ = try await transport.request("stream.close", ["stream": session.id])
                guard self.sessions[session.id] != nil else { return }
                self.startStream(session, controller: controller)
            } catch { session.error = error.localizedDescription }
        }
    }
    private func handle(_ event: [String: Any]) {
        switch event["event"] as? String {
        case "stream.config":
            guard let number = event["stream"] as? NSNumber, let session = sessions[number.uint32Value] else { return }
            session.cancelPointer?(); session.ready = false; session.apply(event); session.renderer.beginConfiguration()
            if session.mode == "mirror" { windows[session.id]?.updateAspect() }
        case "device.rotation":
            for session in sessions.values where session.mode == "mirror" { session.applyRotation(event) }
        case "device.screenPower":
            screenOff = event["screenOff"] as? Bool ?? false
        case "stream.error":
            guard let number = event["stream"] as? NSNumber, let session = sessions[number.uint32Value] else { return }
            session.error = event["message"] as? String ?? "视频会话失败"; session.ready = false
            session.resizeTaskID = UUID(); session.resizeTask?.cancel(); session.resizeTask = nil; session.pendingGeometry = nil; session.resizing = false
        default:
            if let text = event["error"] as? String { error = text }
        }
    }
    func resize(_ session: MirrorSession, to geometry: StreamGeometry) {
        guard session.dynamicResize, sessions[session.id] === session, session.error == nil else { return }
        session.pendingGeometry = geometry
        guard session.resizeTask == nil else { return }
        let taskID = UUID(); session.resizeTaskID = taskID
        session.resizeTask = Task { [weak self, weak session] in
            guard let self, let session else { return }
            defer { if session.resizeTaskID == taskID { session.resizeTask = nil; session.resizing = false } }
            do {
                while let target = session.pendingGeometry, !Task.isCancelled {
                    if target == session.requestedGeometry { session.pendingGeometry = nil; continue }
                    // Allow stream.open's first frame to establish the initial configuration.
                    while !session.ready {
                        try Task.checkCancellation()
                        if let error = session.error ?? session.renderer.error { throw WireError.remote(error) }
                        try await Task.sleep(nanoseconds: 20_000_000)
                    }
                    let delay = max(0, 0.2 - (ProcessInfo.processInfo.systemUptime - session.lastResizeTime))
                    if delay > 0 { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
                    guard let latest = session.pendingGeometry, let transport = self.transport else { break }
                    session.pendingGeometry = nil
                    session.cancelPointer?(); session.resizing = true; session.notice = nil
                    session.lastResizeTime = ProcessInfo.processInfo.systemUptime
                    var values = latest.values; values["stream"] = session.id
                    let oldGeneration = session.generation
                    let result = try await transport.request("stream.resize", values, timeout: 45)
                    try Task.checkCancellation()
                    guard self.sessions[session.id] === session else { return }
                    session.requestedGeometry = latest
                    session.notice = result["warning"] as? String
                    let deadline = ProcessInfo.processInfo.systemUptime + 15
                    while session.generation <= oldGeneration || !session.renderer.currentFrameReady {
                        try Task.checkCancellation()
                        if let error = session.error ?? session.renderer.error { throw WireError.remote(error) }
                        if ProcessInfo.processInfo.systemUptime > deadline { throw WireError.timeout }
                        try await Task.sleep(nanoseconds: 20_000_000)
                    }
                    session.resizing = false
                }
            } catch is CancellationError { }
            catch {
                guard !Task.isCancelled, self.sessions[session.id] === session else { return }
                session.error = error.localizedDescription; session.pendingGeometry = nil
            }
        }
    }
    func setPinned(_ session: MirrorSession, _ value: Bool) { windows[session.id]?.setPinned(value) }
    func setQuality(_ session: MirrorSession, _ quality: FusionQuality) {
        guard session.dynamicResize, let controller = windows[session.id] else { return }
        session.quality = quality
        if let package = session.package { UserDefaults.standard.set(quality.rawValue, forKey: "fusionQuality-" + package) }
        resize(session, to: controller.requestedGeometry)
    }
    func rotate(_ session: MirrorSession, automatic: Bool = false) async {
        guard session.mode == "mirror", rotationSupported, session.acceptsInput, let transport else { return }
        session.cancelPointer?(); session.rotating = true
        defer { session.rotating = false }
        do {
            let generation = session.generation
            let result = try await transport.request("stream.rotate", ["stream": session.id, "automatic": automatic])
            guard sessions[session.id] === session else { return }
            session.applyRotation(result)
            session.notice = nil
            if !automatic, let target = result["requestedRotation"] as? Int {
                let deadline = ProcessInfo.processInfo.systemUptime + 6
                while session.rotation != target || session.generation <= generation || !session.ready {
                    guard sessions[session.id] === session else { return }
                    if let error = session.error ?? session.renderer.error { throw WireError.remote(error) }
                    if ProcessInfo.processInfo.systemUptime >= deadline {
                        session.notice = "当前应用或手机系统未允许切换方向，可尝试开启手机自动旋转。"
                        break
                    }
                    try await Task.sleep(nanoseconds: 40_000_000)
                }
            }
        } catch { session.notice = error.localizedDescription }
    }
    func setScreenOff(_ value: Bool) async {
        guard !screenPowerBusy, let transport, screenPowerSupported else { return }
        screenPowerBusy = true
        let connection = connectionID
        defer { if connectionID == connection { screenPowerBusy = false } }
        do {
            let result = try await transport.request("device.screenPower", ["screenOff": value])
            guard connectionID == connection else { return }
            screenOff = result["screenOff"] as? Bool ?? false
        } catch { if connectionID == connection { self.error = error.localizedDescription } }
    }
    func toggleFavorite(_ app: AndroidApp) {
        if favorites.contains(app.package) { favorites.remove(app.package) } else { favorites.insert(app.package) }
        UserDefaults.standard.set(Array(favorites), forKey: "favoriteApps")
    }
    func connectWireless(pairing: String?, code: String, address: String) async -> Bool {
        guard !wirelessBusy else { return false }
        wirelessBusy = true; wirelessStatus = "正在连接…"
        defer { wirelessBusy = false }
        do {
            let client = ADBClient()
            let endpoint = try ADBClient.validatedEndpoint(address)
            if let pairing {
                let pairingEndpoint = try ADBClient.validatedEndpoint(pairing)
                guard code.count == 6, code.allSatisfy({ $0.isASCII && $0.isNumber }) else { throw WireError.remote("请输入手机显示的 6 位配对码") }
                wirelessStatus = "正在配对…"
                let result = try await client.run(["pair", pairingEndpoint, code], timeout: 25)
                guard result.localizedCaseInsensitiveContains("successfully paired") else { throw WireError.remote("无线配对失败，请检查配对地址和配对码。") }
            }
            wirelessStatus = "正在建立无线连接…"
            let result = try await client.run(["connect", endpoint], timeout: 20)
            guard result.contains("connected to") else { throw WireError.remote("无线连接失败，请检查无线调试页面的 IP 地址和连接端口。") }
            await refresh(); selectedSerial = devices.first(where: { $0.serial == endpoint && $0.available })?.serial ?? selectedSerial
            UserDefaults.standard.set(endpoint, forKey: "wirelessAddress")
            wirelessStatus = "无线设备已连接，可在设备页选择并启动。"
            return true
        } catch { wirelessStatus = error.localizedDescription; return false }
    }
    func closeStream(_ id: UInt32) {
        windows.removeValue(forKey: id)
        if let session = sessions.removeValue(forKey: id) {
            session.resizeTask?.cancel(); session.pendingGeometry = nil; session.cancelPointer?()
            session.ready = false; session.renderer.reset(); transport?.notify("stream.close", ["stream": id])
        }
    }
    func pointer(_ session: MirrorSession, action: Int, x: CGFloat, y: CGFloat, scrollX: CGFloat = 0, scrollY: CGFloat = 0) {
        guard session.acceptsInput else { return }
        transport?.notify("input.pointer", ["stream": session.id, "generation": session.generation, "action": action, "x": Double(x), "y": Double(y), "scrollX": Double(scrollX), "scrollY": Double(scrollY)])
    }
    func key(_ session: MirrorSession, code: Int, meta: Int = 0) { guard session.acceptsInput else { return }; transport?.notify("input.key", ["stream": session.id, "generation": session.generation, "code": code, "meta": meta]) }
    func text(_ session: MirrorSession, text: String) {
        guard session.acceptsInput, !text.isEmpty, let transport else { return }
        Task { do { _ = try await transport.request("input.text", ["stream": session.id, "generation": session.generation, "text": text]) } catch { self.error = error.localizedDescription } }
    }
    func setIME(_ enabled: Bool) async {
        guard let transport else { return }
        do { _ = try await transport.request(enabled ? "ime.enable" : "ime.disable"); imeEnabled = enabled }
        catch { self.error = error.localizedDescription }
    }
    func clipboard(toAndroid: Bool) async {
        guard let transport else { return }
        do {
            if toAndroid { _ = try await transport.request("clipboard.set", ["text": NSPasteboard.general.string(forType: .string) ?? ""]) }
            else {
                let result = try await transport.request("clipboard.get")
                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(result["text"] as? String ?? "", forType: .string)
            }
        } catch { self.error = error.localizedDescription }
    }
    func chooseADB() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.message = L("选择 Android platform-tools 中的 adb 可执行文件")
        if panel.runModal() == .OK, let url = panel.url { UserDefaults.standard.set(url.path, forKey: "adbPath"); if !connected { adb = ADBClient() } }
    }
}
