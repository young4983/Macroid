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
        guard serial.hasPrefix("emulator-") || args.contains("--allow-device") else { fputs("Integration test requires an emulator\n", stderr); NSApp.terminate(nil); return }
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
                if args.contains("--window-features") { try await verifyWindows(model, output: output, report: &report) }
                if args.contains("--display-features") { try await verifyDisplayFeatures(model, output: output, report: &report) }
                if args.contains("--screen-power-test") {
                    await model.setScreenOff(true)
                    guard model.screenOff else { throw WireError.remote(model.error ?? "Screen power toggle failed") }
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                    await model.setScreenOff(false)
                    guard !model.screenOff else { throw WireError.remote("Screen power restore failed") }
                    report["screenPowerUI"] = true
                }
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
    private static func verifyWindows(_ model: AppModel, output: URL, report: inout [String: Any]) async throws {
        guard let session = model.sessions.values.first(where: { $0.package == "io.macroid.fixture" }),
              let window = NSApp.windows.first(where: { $0.isVisible && $0.title == session.name + " · Macroid" }), session.dynamicResize else {
            throw WireError.remote("Missing native fusion window")
        }
        guard window.styleMask.contains(.titled), window.standardWindowButton(.closeButton) != nil else {
            throw WireError.remote("Fusion window does not use native chrome")
        }
        let originalSize = window.contentView!.bounds.size, originalPin = session.pinned
        let other = model.sessions.values.first(where: { $0.id != session.id })!
        let otherPin = other.pinned
        model.setPinned(session, true)
        guard window.level == .floating, other.pinned == otherPin else { throw WireError.remote("Independent pinning failed") }
        model.setPinned(session, false)
        guard window.level == .normal else { throw WireError.remote("Unpin failed") }
        model.setPinned(session, originalPin)
        report["nativeChrome"] = true; report["independentPinning"] = true
        var geometries: [[String: Any]] = []
        for (label, size) in [("narrow", NSSize(width: 420, height: 760)), ("wide", NSSize(width: 960, height: 680)), ("narrow-again", NSSize(width: 420, height: 760))] {
            window.setContentSize(size)
            try await waitForGeometry(session, width: size.width, height: size.height)
            geometries.append(["width": session.width, "height": session.height, "density": session.density, "display": session.displayID, "generation": session.generation])
            window.makeKeyAndOrderFront(nil)
            let observer = ADBClient()
            for _ in 0..<100 {
                let state = try await observer.run(["-s", model.selectedSerial, "shell", "content", "query", "--uri", "content://io.macroid.fixture/state"])
                let pattern = "widthDp=(\\d+)"
                let expression = try NSRegularExpression(pattern: pattern)
                if let match = expression.firstMatch(in: state, range: NSRange(state.startIndex..., in: state)),
                   let range = Range(match.range(at: 1), in: state), let dp = Double(state[range]), abs(dp-size.width) < 4 { break }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            // Configuration metadata can precede Activity recreation and its first actual layout.
            try await Task.sleep(nanoseconds: 2_000_000_000)
            let capture = Process(); capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            capture.arguments = ["-x", "-l", String(window.windowNumber), output.appendingPathComponent("fusion-" + label + ".png").path]
            try capture.run(); capture.waitUntilExit()
            report["windowCaptureAvailable"] = capture.terminationStatus == 0
        }
        report["resizeConfigurations"] = geometries
        for n in 0..<16 {
            window.setContentSize(NSSize(width: 460 + n * 20, height: 650))
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        try await waitForGeometry(session, width: 760, height: 650)
        report["rapidResize"] = true
        let package = session.package!, name = session.name
        let pinnedBefore = UserDefaults.standard.object(forKey: "windowPinned-" + package)
        model.setPinned(session, true)
        window.close()
        model.open(AndroidApp(package: package, name: name))
        guard let reopened = model.sessions.values.first(where: { $0.package == package }), reopened.pinned else { throw WireError.remote("Pin preference was not restored") }
        try await waitForGeometry(reopened, width: 760, height: 650)
        model.setPinned(reopened, originalPin)
        if let pinnedBefore { UserDefaults.standard.set(pinnedBefore, forKey: "windowPinned-" + package) }
        else { UserDefaults.standard.removeObject(forKey: "windowPinned-" + package) }
        report["windowPreferencesRestored"] = true
        if let restoredWindow = NSApp.windows.first(where: { $0.isVisible && $0.title == name + " · Macroid" }) { restoredWindow.setContentSize(originalSize) }
    }
    private static func waitForGeometry(_ session: MirrorSession, width: CGFloat, height: CGFloat) async throws {
        for _ in 0..<500 {
            if let error = session.error ?? session.renderer.error { throw WireError.remote(error) }
            if session.ready, session.resizeTask == nil, session.renderer.currentFrameReady,
               abs(CGFloat(session.width * 160) / CGFloat(session.density) - width) < 4,
               abs(CGFloat(session.height * 160) / CGFloat(session.density) - height) < 4 { return }
            try await Task.sleep(nanoseconds: 40_000_000)
        }
        throw WireError.remote("Resize did not settle: \(session.width)×\(session.height) @ \(session.density), expected \(width)×\(height) dp")
    }
    private static func capture(_ window: NSWindow, to url: URL) async throws {
        window.makeKeyAndOrderFront(nil)
        try await Task.sleep(nanoseconds: 600_000_000)
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-o", "-l", String(window.windowNumber), url.path]
        try process.run(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw WireError.remote("Window capture failed") }
    }
    private static func verifyDisplayFeatures(_ model: AppModel, output: URL, report: inout [String: Any]) async throws {
        guard let session = model.sessions.values.first(where: { $0.package == "io.macroid.fixture" }),
              let window = NSApp.windows.first(where: { $0.isVisible && $0.title == session.name + " · Macroid" }),
              let transport = model.transport, model.rotationSupported else { throw WireError.remote("Missing display feature capability") }
        let key = "fusionQuality-io.macroid.fixture", originalQuality = UserDefaults.standard.object(forKey: "fusionQuality-io.macroid.fixture")
        defer {
            if let originalQuality { UserDefaults.standard.set(originalQuality, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        window.setContentSize(NSSize(width: 420, height: 400))
        var configurations: [[String: Any]] = []
        for quality in [FusionQuality.automatic, .compatibility, .automatic] {
            model.setQuality(session, quality)
            try await waitForGeometry(session, width: 420, height: 400)
            let expected = StreamGeometry(contentWidth: 420, contentHeight: 400, pixelScale: quality.pixelScale(for: Double(window.backingScaleFactor)))
            guard session.width == expected.width, session.height == expected.height, session.density == expected.density else {
                throw WireError.remote("Pixel density did not match the selected quality")
            }
            let observer = ADBClient()
            for _ in 0..<100 {
                let state = try await observer.run(["-s", model.selectedSerial, "shell", "content", "query", "--uri", "content://io.macroid.fixture/state"])
                if state.range(of: "density=\(session.density)(?:,|$)", options: .regularExpression) != nil { break }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            // A valid new video frame may still contain the app's old buffer during Activity recreation.
            try await Task.sleep(nanoseconds: 2_000_000_000)
            configurations.append(["quality": quality.rawValue, "width": session.width, "height": session.height, "density": session.density])
            try await capture(window, to: output.appendingPathComponent("fusion-" + quality.rawValue + ".png"))
        }
        report["fusionQuality"] = configurations
        // Release the fusion encoders before exercising mirror configuration on low-capacity devices.
        for current in Array(model.sessions.values) {
            NSApp.windows.first(where: { $0.isVisible && $0.title == current.name + " · Macroid" })?.close()
        }
        _ = try await transport.request("apps.launch", ["package": "io.macroid.fixture"])
        let observer = ADBClient(), serial = model.selectedSerial
        let originalRotation = try await observer.run(["-s", serial, "shell", "wm", "user-rotation"])
        do {
            _ = try await observer.run(["-s", serial, "shell", "wm", "user-rotation", "lock", "0"])
            model.open()
            guard let mirror = model.sessions.values.first(where: { $0.mode == "mirror" }),
                  let device = NSApp.windows.first(where: { $0.isVisible && $0.title == mirror.name + " · Macroid" }) else { throw WireError.remote("Missing mirror window") }
            try await waitForRotation(mirror, window: device, rotation: 0)
            try await capture(device, to: output.appendingPathComponent("mirror-portrait.png"))
            await model.rotate(mirror)
            try await waitForRotation(mirror, window: device, rotation: 1)
            try await capture(device, to: output.appendingPathComponent("mirror-landscape.png"))
            await model.rotate(mirror)
            try await waitForRotation(mirror, window: device, rotation: 0)
            var rotations: [[String: Any]] = []
            for rotation in [2, 3, 0] {
                _ = try await observer.run(["-s", serial, "shell", "wm", "user-rotation", "lock", String(rotation)])
                try await waitForRotation(mirror, window: device, rotation: rotation)
                rotations.append(["rotation": rotation, "width": mirror.width, "height": mirror.height, "windowWidth": device.frame.width, "windowHeight": device.frame.height])
            }
            await model.rotate(mirror, automatic: true)
            let mode = try await observer.run(["-s", serial, "shell", "wm", "user-rotation"])
            guard mode.trimmingCharacters(in: .whitespacesAndNewlines) == "free" else { throw WireError.remote("Automatic rotation did not enable") }
            report["mirrorRotations"] = rotations; report["automaticRotation"] = true
        } catch {
            _ = try? await observer.run(["-s", serial, "shell", "wm", "user-rotation"] + originalRotation.split(whereSeparator: \.isWhitespace).map(String.init))
            throw error
        }
        _ = try await observer.run(["-s", serial, "shell", "wm", "user-rotation"] + originalRotation.split(whereSeparator: \.isWhitespace).map(String.init))
    }
    private static func waitForRotation(_ session: MirrorSession, window: NSWindow, rotation: Int) async throws {
        for _ in 0..<500 {
            if let error = session.error ?? session.renderer.error { throw WireError.remote(error) }
            if session.rotation == rotation, session.ready, session.renderer.currentFrameReady,
               (session.width > session.height) == (rotation % 2 == 1),
               (window.frame.width > window.frame.height) == (rotation % 2 == 1) { return }
            try await Task.sleep(nanoseconds: 40_000_000)
        }
        throw WireError.remote("Mirror video/window did not follow rotation \(rotation)")
    }
    // Explicit physical-device mirror check: no fixture installation, IME switch or file writes on the phone.
    private static func runMirrorTest(_ args: [String]) {
        guard let index = args.firstIndex(of: "--mirror-test"), args.indices.contains(index + 1),
              let outputIndex = args.firstIndex(of: "--integration-output"), args.indices.contains(outputIndex + 1) else { return }
        let serial = args[index + 1], output = URL(fileURLWithPath: args[outputIndex + 1], isDirectory: true)
        Task {
            var report: [String: Any] = ["serial": serial, "architecture": ProcessInfo.processInfo.machineArchitecture, "version": "0.3.0"]
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
