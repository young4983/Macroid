import AppKit
import AVFoundation

/// Explicit developer test entry point. Never auto-selects or tests a physical device.
@MainActor enum IntegrationHarness {
    static func runIfRequested() {
        let args = ProcessInfo.processInfo.arguments
        if args.contains("--mirror-test") { runMirrorTest(args); return }
        guard let index = args.firstIndex(of: "--integration-test"), args.indices.contains(index + 1),
              let outputIndex = args.firstIndex(of: "--integration-output"), args.indices.contains(outputIndex + 1) else { return }
        let serial = args[index + 1], output = URL(fileURLWithPath: args[outputIndex + 1], isDirectory: true)
        guard serial.hasPrefix("emulator-") else { fputs("Integration test requires an emulator\n", stderr); NSApp.terminate(nil); return }
        Task {
            var report: [String: Any] = ["serial": serial, "architecture": ProcessInfo.processInfo.machineArchitecture]
            do {
                try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                let model = AppModel.shared
                for _ in 0..<100 { if !model.refreshing { break }; try await Task.sleep(nanoseconds: 100_000_000) }
                await model.refresh(); model.selectedSerial = serial
                await model.connect()
                guard model.connected else { throw WireError.remote(model.error ?? "Connection failed") }
                guard let fixture = model.apps.first(where: { $0.package == "io.macroid.fixture" }),
                      let settings = model.apps.first(where: { $0.package == "com.android.settings" }) else { throw WireError.remote("Install the integration fixture first") }
                model.open(fixture); model.open(settings)
                var decoded = false
                for _ in 0..<200 {
                    if model.sessions.values.contains(where: { $0.error != nil }) { throw WireError.remote(model.sessions.values.compactMap(\.error).joined(separator: "\n")) }
                    if model.sessions.count == 2 && model.sessions.values.allSatisfy({ $0.renderer.hasFrame && $0.renderer.layer.status == .rendering }) { decoded = true; break }
                    try await Task.sleep(nanoseconds: 100_000_000)
                }
                guard decoded else { throw WireError.remote("Two Mac video display layers did not enter rendering state") }
                for _ in 0..<100 { if model.icons.count == model.apps.count { break }; try await Task.sleep(nanoseconds: 100_000_000) }
                report["sdk"] = model.sdk; report["apps"] = model.apps.count
                report["renderingStreams"] = model.sessions.count
                for window in NSApp.windows where window.title == "Macroid" {
                    window.makeKeyAndOrderFront(nil)
                    try await Task.sleep(nanoseconds: 500_000_000)
                    if let view = window.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                        view.cacheDisplay(in: view.bounds, to: bitmap)
                        try bitmap.representation(using: .png, properties: [:])?.write(to: output.appendingPathComponent("main-window.png"))
                    }
                }
                let observer = ADBClient()
                let originalIME = try await observer.run(["-s", serial, "shell", "settings", "get", "secure", "default_input_method"])
                await model.setIME(true)
                guard model.imeEnabled, let transport = model.transport else { throw WireError.remote("IME activation failed") }
                let remote = "/sdcard/Download/macroid-cleanup-" + UUID().uuidString + ".bin"
                let upload = try await transport.request("files.upload.begin", ["path": remote, "size": 1024])
                guard let transfer = upload["transfer"] as? String else { throw WireError.malformed }
                _ = try await transport.request("files.upload.chunk", ["transfer": transfer, "offset": 0, "data": Data("unfinished".utf8).base64EncodedString()])
                await model.disconnect()
                let restoredIME = try await observer.run(["-s", serial, "shell", "settings", "get", "secure", "default_input_method"])
                guard originalIME == restoredIME else { throw WireError.remote("IME was not restored") }
                _ = try await observer.run(["-s", serial, "shell", "test", "!", "-e", "/sdcard/Download/.macroid-upload-" + transfer])
                _ = try await observer.run(["-s", serial, "shell", "test", "!", "-e", remote])
                report["restoredIME"] = true; report["removedPartialUpload"] = true
                report["passed"] = true
            } catch { report["passed"] = false; report["error"] = error.localizedDescription; await AppModel.shared.disconnect() }
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: output.appendingPathComponent("mac-report.json")) }
            NSApp.terminate(nil)
        }
    }
    // Explicit physical-device mirror check: no fixture installation, IME switch or file writes on the phone.
    private static func runMirrorTest(_ args: [String]) {
        guard let index = args.firstIndex(of: "--mirror-test"), args.indices.contains(index + 1),
              let outputIndex = args.firstIndex(of: "--integration-output"), args.indices.contains(outputIndex + 1) else { return }
        let serial = args[index + 1], output = URL(fileURLWithPath: args[outputIndex + 1], isDirectory: true)
        Task {
            var report: [String: Any] = ["serial": serial, "architecture": ProcessInfo.processInfo.machineArchitecture, "version": "0.2.0"]
            let model = AppModel.shared
            do {
                try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                while model.refreshing { try await Task.sleep(nanoseconds: 100_000_000) }
                await model.refresh(); model.selectedSerial = serial; await model.connect()
                guard model.connected else { throw WireError.remote(model.error ?? "Connection failed") }
                model.open()
                for _ in 0..<250 {
                    if let error = model.sessions.values.first?.error { throw WireError.remote(error) }
                    if model.sessions.values.first?.renderer.layer.status == .rendering { break }
                    try await Task.sleep(nanoseconds: 100_000_000)
                }
                guard let session = model.sessions.values.first, session.renderer.layer.status == .rendering else {
                    throw WireError.remote(model.sessions.values.first?.renderer.error ?? "Mac display layer did not render")
                }
                let before = session.renderer.frameCount
                try await Task.sleep(nanoseconds: 3_000_000_000)
                guard session.renderer.frameCount > before else { throw WireError.remote("Stream stalled") }
                report["sdk"] = model.sdk; report["width"] = session.width; report["height"] = session.height
                report["encoding"] = session.encoding; report["renderedFrames"] = session.renderer.frameCount; report["passed"] = true
                report["layerStatus"] = "rendering"; report["transport"] = model.connectedDevice?.connectionLabel
                model.section = "apps"
            } catch { report["passed"] = false; report["error"] = error.localizedDescription }
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: output.appendingPathComponent("mirror-report.json"))
            }
            if !args.contains("--leave-open") { await model.disconnect(); NSApp.terminate(nil) }
        }
    }

}

private extension ProcessInfo {
    var machineArchitecture: String {
        #if arch(arm64)
        return "arm64"
        #else
        return "x86_64"
        #endif
    }
}
