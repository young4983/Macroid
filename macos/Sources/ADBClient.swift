import Foundation

struct AndroidDevice: Identifiable, Hashable {
    let serial: String
    let state: String
    let model: String
    var id: String { serial }
    var available: Bool { state == "device" }
    var wireless: Bool { serial.contains(":") || serial.contains("_adb-tls-") }
    var connectionLabel: String { wireless ? "Wi-Fi" : "USB" }
    var stateLabel: String { state == "unauthorized" ? "请在手机上允许 USB 调试" : state == "offline" ? "设备离线" : "准备连接" }
}

final class ADBClient {
    private(set) var agent: Process?
    private var logPipe: Pipe?
    private(set) var port: String?
    private(set) var serial: String?
    let executable: URL

    init() {
        let override = UserDefaults.standard.string(forKey: "adbPath") ?? ""
        let bundled = Bundle.main.resourceURL?.appendingPathComponent("adb")
        let candidates = [override, bundled?.path ?? "", "/opt/homebrew/bin/adb", "/usr/local/bin/adb", NSHomeDirectory() + "/Library/Android/sdk/platform-tools/adb"]
        executable = URL(fileURLWithPath: candidates.first(where: { !$0.isEmpty && FileManager.default.isExecutableFile(atPath: $0) }) ?? "/usr/local/bin/adb")
    }
    func run(_ args: [String], timeout: TimeInterval = 30) async throws -> String {
        let executable = self.executable
        return try await Task.detached(priority: .userInitiated) {
            let process = Process(), pipe = Pipe()
            process.executableURL = executable; process.arguments = args; process.standardOutput = pipe; process.standardError = pipe
            do { try process.run() } catch { throw WireError.remote("找不到 ADB，请在设置中选择 platform-tools/adb。\n" + error.localizedDescription) }
            let work = DispatchWorkItem { if process.isRunning { process.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: work)
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit(); work.cancel()
            let output = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            guard process.terminationStatus == 0 else { throw WireError.remote(output.isEmpty ? "ADB 操作失败或超时" : output) }
            return output
        }.value
    }
    func devices() async throws -> [AndroidDevice] {
        let output = try await run(["devices", "-l"])
        return output.split(separator: "\n").compactMap { line in
            let parts = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard parts.count >= 2, !line.hasPrefix("List "), !line.hasPrefix("*") else { return nil }
            let model = parts.first(where: { $0.hasPrefix("model:") }).map { String($0.dropFirst(6)).replacingOccurrences(of: "_", with: " ") } ?? parts[0]
            return AndroidDevice(serial: parts[0], state: parts[1], model: model)
        }
    }
    static func validatedEndpoint(_ input: String) throws -> String {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let pattern = #"^(?:[A-Za-z0-9][A-Za-z0-9.\-]*|\[[0-9A-Fa-f:%.]+\]):([0-9]{1,5})$"#
        guard value.range(of: pattern, options: .regularExpression) != nil,
              let port = value.split(separator: ":").last.flatMap({ UInt16($0) }), port > 0 else {
            throw WireError.remote("请输入 IP 地址和端口，例如 192.168.1.10:37123")
        }
        return value
    }
    static var diagnosticsURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Macroid/Logs/agent.log")
    }
    func start(serial: String, status: @escaping @Sendable (String) -> Void) async throws -> (UInt16, String) {
        self.serial = serial
        let sdkText = try await run(["-s", serial, "shell", "getprop", "ro.build.version.sdk"])
        guard let sdk = Int(sdkText), sdk >= 31 else { throw WireError.remote("Macroid 需要 Android 12 或更新版本") }
        guard let apk = Bundle.main.resourceURL?.appendingPathComponent("Macroid.apk"), FileManager.default.fileExists(atPath: apk.path) else { throw WireError.remote("应用中缺少 Macroid.apk，请运行完整构建脚本") }
        status("正在安装 Macroid 助手…")
        _ = try await run(["-s", serial, "install", "-r", apk.path], timeout: 90)
        let packagePath = try await run(["-s", serial, "shell", "pm", "path", "io.macroid.bridge"])
        guard let line = packagePath.split(separator: "\n").first(where: { $0.hasPrefix("package:") }) else { throw WireError.remote("无法定位 Android 助手") }
        let path = String(line.dropFirst(8)).trimmingCharacters(in: .whitespacesAndNewlines)
        let socket = "macroid_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let token = UUID().uuidString.replacingOccurrences(of: "-", with: "") + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        status("正在启动安全连接…")
        let port = try await run(["-s", serial, "forward", "tcp:0", "localabstract:" + socket])
        self.port = port
        guard let value = UInt16(port) else { throw WireError.remote("无法分配 ADB 转发端口") }
        let process = Process(), pipe = Pipe()
        process.executableURL = executable
        process.arguments = ["-s", serial, "shell", "CLASSPATH=" + Self.quote(path) + " app_process / io.macroid.bridge.AgentMain " + Self.quote(socket) + " " + Self.quote(token)]
        process.standardOutput = pipe; process.standardError = pipe
        // Drain agent diagnostics continuously so the child can never fill its output pipe.
        try? FileManager.default.createDirectory(at: Self.diagnosticsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data().write(to: Self.diagnosticsURL)
        let diagnostics = AgentDiagnostics()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty { diagnostics.append(data) }
        }
        self.agent = process; self.logPipe = pipe
        try process.run()
        // Wait for an explicit ready marker rather than assuming a fixed device startup time.
        for _ in 0..<100 {
            if diagnostics.text.contains("MACROID_READY") { return (value, token) }
            if !process.isRunning { throw WireError.remote("手机端启动失败：\n" + diagnostics.text) }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw WireError.remote("手机端启动超时：\n" + diagnostics.text)
    }
    func stop() async {
        // Let EOF reach Android and let its finally block restore state and remove partial uploads.
        if let process = agent {
            for _ in 0..<50 {
                if !process.isRunning { break }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            if process.isRunning { process.terminate() }
        }
        agent = nil
        logPipe?.fileHandleForReading.readabilityHandler = nil; logPipe = nil
        if let serial, let port { _ = try? await run(["-s", serial, "forward", "--remove", "tcp:" + port]) }
        self.port = nil; self.serial = nil
    }
    static func quote(_ string: String) -> String { "'" + string.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}

private final class AgentDiagnostics: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    func append(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        buffer.append(data); if buffer.count > 32768 { buffer = Data(buffer.suffix(32768)) }
        // Bounded diagnostic log contains encoder choices and errors, never the authentication token.
        try? buffer.write(to: ADBClient.diagnosticsURL, options: .atomic)
    }
    var text: String { lock.lock(); defer { lock.unlock() }; return String(decoding: buffer, as: UTF8.self) }
}
