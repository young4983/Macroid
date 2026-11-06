import AppKit
import SwiftUI

struct AndroidApp: Identifiable {
    let package: String, name: String
    var id: String { package }
}

@MainActor final class MirrorSession: ObservableObject, Identifiable {
    let id: UInt32, name: String, package: String?, mode: String
    let renderer = VideoRenderer()
    @Published var width = 720
    @Published var height = 1280
    @Published var ready = false
    @Published var encoding = ""
    @Published var error: String?
    init(id: UInt32, name: String, package: String?, mode: String) { self.id = id; self.name = name; self.package = package; self.mode = mode }
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
    private var disconnecting = false

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
        guard !connecting, !connected, let device = devices.first(where: { $0.serial == selectedSerial }), device.available else { return }
        connecting = true; error = nil; defer { connecting = false }
        do {
            let (port, token) = try await adb.start(serial: device.serial) { text in Task { @MainActor in self.status = text } }
            let transport = Transport(onVideo: { [weak self] packet in Task { @MainActor in self?.sessions[packet.stream]?.renderer.consume(packet) } }, onEvent: { [weak self] event in
                Task { @MainActor in
                    guard let self else { return }
                    if let id = event["stream"] as? UInt32, let text = event["message"] as? String { self.sessions[id]?.error = text }
                    else if let text = event["error"] as? String { self.error = text }
                }
            }, onDisconnect: { [weak self] error in Task { @MainActor in
                guard let self, !self.disconnecting else { return }
                self.error = error.localizedDescription; await self.disconnect()
            } })
            self.transport = transport
            try await transport.connect(port: port)
            let info = try await transport.request("hello", ["token": token])
            guard info["product"] as? String == "Macroid", info["protocol"] as? Int == 1 else { throw WireError.malformed }
            sdk = info["sdk"] as? Int ?? 0
            let ownFocus = (info["capabilities"] as? [String: Any])?["ownFocus"] as? Bool ?? false
            connectedDevice = device; status = ownFocus ? "已连接 · 独立焦点" : (sdk < 34 ? "已连接 · Android 12/13 兼容模式" : "已连接 · 兼容显示模式")
            try await loadApps()
        } catch { self.error = error.localizedDescription; await disconnect() }
    }
    func disconnect() async {
        guard !disconnecting else { return }; disconnecting = true
        iconTask?.cancel(); iconTask = nil
        if imeEnabled, let transport { _ = try? await transport.request("ime.disable", timeout: 20) }
        imeEnabled = false
        let controllers = Array(windows.values); windows.removeAll()
        for window in controllers { window.close() }
        for session in sessions.values { session.renderer.reset() }; sessions.removeAll()
        transport?.close(); transport = nil
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
        guard connected, let transport else { return }
        if let app, !fusionEnabled {
            Task {
                do { _ = try await transport.request("apps.launch", ["package": app.package]); self.open() }
                catch { self.error = error.localizedDescription }
            }
            return
        }
        // Reuse an existing window for a package; Android launch modes may only permit one task.
        if let existing = sessions.values.first(where: { $0.package == app?.package }) { windows[existing.id]?.showWindow(nil); windows[existing.id]?.window?.makeKeyAndOrderFront(nil); return }
        guard sessions.count < 4 else { error = "最多同时打开四个窗口，实际数量还取决于手机编码器能力。"; return }
        let id = nextStream; nextStream += 1
        let session = MirrorSession(id: id, name: app?.name ?? "手机屏幕", package: app?.package, mode: app == nil ? "mirror" : "fusion")
        sessions[id] = session
        let controller = MirrorWindowController(session: session, model: self)
        windows[id] = controller; controller.showWindow(nil); NSApp.activate(ignoringOtherApps: true)
        startStream(session, controller: controller)
    }
    private func startStream(_ session: MirrorSession, controller: MirrorWindowController) {
        guard let transport else { return }
        Task {
            do {
                var request: [String: Any] = ["stream": session.id, "mode": session.mode, "width": 720, "height": 1280, "density": 240, "fps": 60, "bitrate": 6_000_000]
                if let package = session.package { request["package"] = package }
                let info = try await transport.request("stream.open", request, timeout: 45)
                guard self.sessions[session.id] != nil else { transport.notify("stream.close", ["stream": session.id]); return }
                session.width = info["width"] as? Int ?? 720; session.height = info["height"] as? Int ?? 1280
                session.encoding = "\(session.width) × \(session.height) · \(info["fps"] as? Int ?? 30) fps · \(info["encoder"] as? String ?? "H.264")"
                session.ready = true; controller.updateAspect()
            } catch { session.error = error.localizedDescription }
        }
    }
    func retryStream(_ session: MirrorSession) {
        guard let transport, let controller = windows[session.id], sessions[session.id] != nil else { return }
        session.error = nil; session.ready = false; session.renderer.reset()
        Task {
            do {
                _ = try await transport.request("stream.close", ["stream": session.id])
                guard self.sessions[session.id] != nil else { return }
                self.startStream(session, controller: controller)
            } catch { session.error = error.localizedDescription }
        }
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
        if let session = sessions.removeValue(forKey: id) { session.renderer.reset(); transport?.notify("stream.close", ["stream": id]) }
    }
    func pointer(_ session: MirrorSession, action: Int, x: CGFloat, y: CGFloat, scrollX: CGFloat = 0, scrollY: CGFloat = 0) {
        guard session.ready else { return }
        transport?.notify("input.pointer", ["stream": session.id, "action": action, "x": Double(x), "y": Double(y), "scrollX": Double(scrollX), "scrollY": Double(scrollY)])
    }
    func key(_ session: MirrorSession, code: Int, meta: Int = 0) { guard session.ready else { return }; transport?.notify("input.key", ["stream": session.id, "code": code, "meta": meta]) }
    func text(_ session: MirrorSession, text: String) {
        guard session.ready, !text.isEmpty, let transport else { return }
        Task { do { _ = try await transport.request("input.text", ["stream": session.id, "text": text]) } catch { self.error = error.localizedDescription } }
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
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.message = "选择 Android platform-tools 中的 adb 可执行文件"
        if panel.runModal() == .OK, let url = panel.url { UserDefaults.standard.set(url.path, forKey: "adbPath"); if !connected { adb = ADBClient() } }
    }
}
