import AppKit
import Combine
import SwiftUI

/// Native macOS menus share the same connection and window state as the main panel.
struct StatusMenu: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    // Session readiness is published by each session, not by the containing dictionary.
    @State private var sessionRevision = 0

    var body: some View {
        Group {
            if model.disconnecting {
                Text("正在断开连接…")
            } else if model.connecting {
                Text(model.status)
            } else if let device = model.connectedDevice {
                Menu {
                    Text("通过 \(device.connectionLabel) 连接")
                    Text(device.serial)
                    Divider()
                    Button("断开连接") { Task { await model.disconnect() } }
                } label: {
                    Label(device.model, systemImage: "checkmark.circle")
                }
            } else {
                Text("未连接设备")
                Menu("连接设备") {
                    if model.devices.isEmpty {
                        Text(model.refreshing ? "正在查找设备…" : "未发现设备")
                        Text("请连接 USB 并允许调试，或添加 Wi-Fi 设备")
                    }
                    ForEach(model.devices) { device in
                        Button {
                            Task {
                                guard !model.connecting, !model.disconnecting, !model.connected else { return }
                                model.selectedSerial = device.serial
                                model.section = "apps"
                                showMainPanel()
                                await model.connect()
                                if model.error != nil { showMainPanel() }
                            }
                        } label: {
                            Label(deviceTitle(device), systemImage: device.wireless ? "wifi" : "cable.connector")
                        }.disabled(!device.available)
                    }
                    Divider()
                    Button("管理 USB / Wi-Fi 设备…") { model.section = "devices"; showMainPanel() }
                }
            }

            Button {
                Task {
                    await model.refresh()
                    if model.error != nil { showMainPanel() }
                }
            } label: { Label("刷新设备", systemImage: "arrow.clockwise") }
                .disabled(model.refreshing || model.connecting || model.disconnecting)

            Divider()
            Button { showMainPanel() } label: { Label("显示主面板", systemImage: "macwindow") }

            if model.connected {
                Button { model.open() } label: { Label("手机屏幕", systemImage: "iphone") }
                    .disabled(model.disconnecting)
                if !model.sessions.isEmpty {
                    Menu("已打开的窗口") {
                        ForEach(model.sessions.values.sorted(by: { $0.id < $1.id })) { session in
                            Button(session.name) { model.showStream(session.id) }
                        }
                    }.disabled(model.disconnecting)
                }
                Toggle("关屏使用", isOn: Binding(get: { model.screenOff }, set: { value in
                    Task {
                        await model.setScreenOff(value)
                        if model.error != nil { showMainPanel() }
                    }
                }))
                .disabled(!model.screenPowerSupported || model.screenPowerBusy || model.disconnecting || !canControlScreen)
                if !model.screenPowerSupported { Text(model.screenPowerReason) }
            }

            Divider()
            Button { model.section = "settings"; showMainPanel() } label: { Label("设置与帮助…", systemImage: "gearshape") }
            Button("关于 Macroid") {
                NSApp.activate(ignoringOtherApps: true)
                NSApp.orderFrontStandardAboutPanel(nil)
            }
            Divider()
            Button("退出 Macroid") { NSApp.terminate(nil) }.keyboardShortcut("q")
        }
        .onReceive(Publishers.MergeMany(model.sessions.values.map { $0.objectWillChange })) { _ in sessionRevision &+= 1 }
    }

    private var canControlScreen: Bool {
        _ = sessionRevision
        // Always allow restoring the panel, including while the last stream is reconfiguring.
        return model.screenOff || model.sessions.values.contains { $0.ready && $0.error == nil }
    }
    private func deviceTitle(_ device: AndroidDevice) -> String {
        var title = "\(device.model) · \(device.connectionLabel)"
        if model.devices.filter({ $0.model == device.model && $0.connectionLabel == device.connectionLabel }).count > 1 {
            title += " · \(device.serial)"
        }
        if !device.available { title += "（\(device.stateLabel)）" }
        return title
    }
    private func showMainPanel() {
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }

    /// The overlapping windows from Macroid's app icon, redrawn for an 18pt monochrome template.
    static let icon: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.black.setStroke()
            let back = NSBezierPath()
            back.move(to: NSPoint(x: 3.5, y: 5.5))
            back.line(to: NSPoint(x: 2.75, y: 5.5))
            back.curve(to: NSPoint(x: 1.25, y: 7), controlPoint1: NSPoint(x: 1.9, y: 5.5), controlPoint2: NSPoint(x: 1.25, y: 6.15))
            back.line(to: NSPoint(x: 1.25, y: 13.75))
            back.curve(to: NSPoint(x: 2.75, y: 15.25), controlPoint1: NSPoint(x: 1.25, y: 14.6), controlPoint2: NSPoint(x: 1.9, y: 15.25))
            back.line(to: NSPoint(x: 11.5, y: 15.25))
            back.curve(to: NSPoint(x: 13, y: 13.75), controlPoint1: NSPoint(x: 12.35, y: 15.25), controlPoint2: NSPoint(x: 13, y: 14.6))
            back.lineWidth = 1.5; back.lineCapStyle = .round; back.stroke()
            let front = NSBezierPath(roundedRect: NSRect(x: 5, y: 2.75, width: 11.75, height: 9.5), xRadius: 1.5, yRadius: 1.5)
            front.lineWidth = 1.5; front.stroke()
            let title = NSBezierPath()
            title.move(to: NSPoint(x: 5.5, y: 9.25)); title.line(to: NSPoint(x: 16.25, y: 9.25))
            title.lineWidth = 1; title.stroke()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Macroid"
        return image
    }()
}
