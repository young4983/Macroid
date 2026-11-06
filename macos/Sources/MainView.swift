import SwiftUI
import AppKit

private let brand = Color.accentColor

struct BrandMark: View {
    var size: CGFloat = 42
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.25).fill(LinearGradient(colors: [Color(red: 0.18, green: 0.51, blue: 0.91), .teal], startPoint: .topLeading, endPoint: .bottomTrailing))
            Image(systemName: "rectangle.on.rectangle").font(.system(size: size * 0.48, weight: .semibold)).foregroundStyle(.white)
        }.frame(width: size, height: size)
    }
}

struct MainView: View {
    @ObservedObject var model: AppModel
    @State private var wireless = false
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 11) {
                BrandMark(size: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Macroid").font(.system(size: 22, weight: .bold, design: .rounded))
                    Text("让 Android 融入你的 Mac").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if model.connecting { ProgressView().controlSize(.small) }
                else { Button { Task { await model.refresh() } } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.borderless).help("刷新设备").disabled(model.refreshing) }
            }.padding(.horizontal, 22).padding(.top, 36).padding(.bottom, 18)
            Picker("页面", selection: $model.section) {
                Label("应用", systemImage: "square.grid.2x2").tag("apps")
                Label("文件", systemImage: "folder").tag("files")
                Label("设备", systemImage: "smartphone").tag("devices")
                Label("设置", systemImage: "slider.horizontal.3").tag("settings")
            }.pickerStyle(.segmented).labelsHidden().padding(.horizontal, 20).padding(.bottom, 16)
            Group {
                switch model.section {
                case "devices": DevicesView(model: model, wireless: $wireless)
                case "settings": GuideView(model: model)
                case "files":
                    if model.connected { FileBrowser(model: model) }
                    else { WelcomeView(model: model, wireless: $wireless) }
                default:
                    if model.connected { ApplicationsView(model: model) }
                    else { WelcomeView(model: model, wireless: $wireless) }
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            HStack(spacing: 6) {
                Circle().fill(model.connected ? Color.green : Color.secondary.opacity(0.4)).frame(width: 6, height: 6)
                Text(model.connecting ? model.status : model.connected ? "\(model.connectedDevice?.model ?? "Android") · \(model.connectedDevice?.connectionLabel ?? "")" : "等待连接设备")
                    .lineLimit(1).font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 4)
                if model.connected { Text("\(model.sessions.count) 个窗口").font(.caption).foregroundStyle(.tertiary) }
            }.padding(.horizontal, 20).frame(height: 34)
        }
        .background(.regularMaterial).background(MainWindowChrome()).frame(minWidth: 360, idealWidth: 392, maxWidth: 480, minHeight: 580, idealHeight: 690)
        .sheet(isPresented: $wireless) { WirelessConnectionView(model: model) }
        .alert("Macroid", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("好") { model.error = nil }
        } message: { Text(model.error ?? "") }
    }
}

struct WelcomeView: View {
    @ObservedObject var model: AppModel
    @Binding var wireless: Bool
    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                Image(systemName: "macbook.and.iphone").font(.system(size: 56, weight: .ultraLight)).foregroundStyle(brand).padding(.top, 22)
                VStack(spacing: 8) {
                    Text("手机应用，桌面随行").font(.title3.weight(.semibold))
                    Text("连接 Android，开始投屏或打开独立应用窗口。")
                        .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                DeviceCard(model: model)
                VStack(alignment: .leading, spacing: 12) {
                    Label("用 USB 连接手机，并开启 USB 调试", systemImage: "cable.connector")
                    Label("在手机上允许这台 Mac 的调试请求", systemImage: "checkmark.shield")
                    Label("点击连接，自动安装无桌面图标的助手", systemImage: "rectangle.on.rectangle")
                }.font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                Button { wireless = true } label: { Label("通过 Wi-Fi 连接", systemImage: "wifi") }.buttonStyle(.link)
                Text("macOS 13+ · Android 12+").font(.caption2).foregroundStyle(.tertiary)
            }.padding(20)
        }
    }
}

struct DeviceCard: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "smartphone").font(.system(size: 30, weight: .light)).foregroundStyle(brand).frame(width: 34)
                VStack(alignment: .leading, spacing: 4) {
                    if let device = model.connectedDevice {
                        Text(device.model).font(.headline)
                        Text("Android \(model.sdk >= 34 ? String(model.sdk - 20) : model.sdk == 31 || model.sdk == 32 ? "12" : "13") · \(device.connectionLabel)").font(.caption).foregroundStyle(.secondary)
                    } else if !model.devices.isEmpty {
                        Picker("设备", selection: $model.selectedSerial) {
                            ForEach(model.devices) { device in Text("\(device.model) · \(device.connectionLabel)").tag(device.serial) }
                        }.labelsHidden().disabled(model.connecting)
                        Text(model.devices.first(where: { $0.serial == model.selectedSerial })?.stateLabel ?? "选择设备").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("尚未发现设备").font(.headline)
                        Text("连接 USB 或添加无线设备").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                if model.connected { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
            }
            if model.connected {
                Button { model.open() } label: { Label("屏幕镜像", systemImage: "rectangle.on.rectangle").frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent).controlSize(.large)
            } else {
                Button { Task { await model.connect() } } label: {
                    HStack { if model.connecting { ProgressView().controlSize(.small) }; Text(model.connecting ? "正在连接…" : "连接设备") }.frame(maxWidth: .infinity)
                }.buttonStyle(.borderedProminent).controlSize(.large)
                    .disabled(model.connecting || !model.devices.contains(where: { $0.serial == model.selectedSerial && $0.available }))
            }
        }.padding(16).background(Color(nsColor: .controlBackgroundColor).opacity(0.8), in: RoundedRectangle(cornerRadius: 14))
    }
}

struct DevicesView: View {
    @ObservedObject var model: AppModel
    @Binding var wireless: Bool
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                DeviceCard(model: model)
                if model.connected {
                    HStack { Text(model.status).font(.caption).foregroundStyle(.secondary); Spacer(); Button("断开") { Task { await model.disconnect() } }.controlSize(.small) }
                    if let device = model.connectedDevice, !device.wireless {
                        Text("当前通过 USB 传输。拔线前请先在 Wi-Fi 中配对并选择无线设备重新连接。")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Button { wireless = true } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "wifi").font(.title3).foregroundStyle(brand)
                        VStack(alignment: .leading, spacing: 4) { Text("Wi-Fi 连接").font(.callout.weight(.medium)); Text("无线调试 · 配对码连接").font(.caption).foregroundStyle(.secondary) }
                        Spacer(); Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                    }.padding(16).background(Color(nsColor: .controlBackgroundColor).opacity(0.8), in: RoundedRectangle(cornerRadius: 14))
                }.buttonStyle(.plain)
                Text("手机与 Mac 需要在同一局域网。无线设备连接后，投屏不再依赖 USB 数据线。")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }.padding(20)
        }
    }
}

struct ApplicationsView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 7) {
                Image(systemName: model.connectedDevice?.wireless == true ? "wifi" : "cable.connector").foregroundStyle(.secondary)
                Text(model.connectedDevice?.model ?? "Android").font(.callout.weight(.medium)).lineLimit(1)
                Spacer()
                Button { model.open() } label: {
                    Label("屏幕镜像", systemImage: "rectangle.on.rectangle")
                }
                .buttonStyle(.borderedProminent).controlSize(.small)
                .help("镜像手机当前屏幕").accessibilityLabel("屏幕镜像")
            }
            HStack {
                Text("融合模式").font(.callout)
                if model.sdk < 34 { Text("兼容").font(.caption2).foregroundStyle(.secondary).padding(.horizontal, 6).padding(.vertical, 2).background(.quaternary, in: Capsule()) }
                Spacer()
                Toggle("融合模式", isOn: Binding(get: { model.fusionEnabled }, set: { model.fusionEnabled = $0 })).labelsHidden().toggleStyle(.switch).controlSize(.mini)
            }
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜索应用", text: $model.search).textFieldStyle(.plain)
                if !model.search.isEmpty { Button { model.search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }.buttonStyle(.plain) }
            }.padding(9).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
            ScrollView {
                let favorites = model.filteredApps.filter { model.favorites.contains($0.package) }
                if !favorites.isEmpty { grid(favorites); Divider().padding(.vertical, 12) }
                grid(model.filteredApps.filter { !model.favorites.contains($0.package) })
                if model.filteredApps.isEmpty { Text("没有找到应用").font(.callout).foregroundStyle(.secondary).padding(.top, 36) }
            }
        }.padding(.horizontal, 20).padding(.bottom, 12)
    }
    private func grid(_ apps: [AndroidApp]) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 16) {
            ForEach(apps) { app in AppCard(app: app, model: model) }
        }.padding(.top, 4)
    }
}

struct AppCard: View {
    let app: AndroidApp
    @ObservedObject var model: AppModel
    @State private var hovering = false
    var body: some View {
        Button { model.open(app) } label: {
            VStack(spacing: 7) {
                if let icon = model.icons[app.package] { Image(nsImage: icon).resizable().interpolation(.high).frame(width: 46, height: 46) }
                else { Image(systemName: "app.fill").font(.system(size: 42)).foregroundStyle(brand.opacity(0.6)).frame(width: 46, height: 46) }
                Text(app.name).font(.system(size: 11)).lineLimit(1).truncationMode(.tail).frame(maxWidth: 68)
            }.padding(.vertical, 7).frame(maxWidth: .infinity).background(hovering ? Color.primary.opacity(0.05) : .clear, in: RoundedRectangle(cornerRadius: 10))
        }.buttonStyle(.plain).onHover { hovering = $0 }.help("\(app.name)\n\(app.package)")
            .contextMenu { Button(model.favorites.contains(app.package) ? "取消收藏" : "收藏应用", systemImage: "star") { model.toggleFavorite(app) } }
    }
}

struct GuideView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        Form {
            Section("应用窗口") {
                Toggle("融合模式", isOn: Binding(get: { model.fusionEnabled }, set: { model.fusionEnabled = $0 }))
                Text("开启后，应用在原生窗口中运行。拖拽窗口会改变 Android 副屏尺寸，支持的应用会自行切换宽屏布局。Android 12/13 的焦点和输入法可能与手机共享。关闭后，应用在手机主屏幕打开并投屏。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("连接") {
                Button("选择 ADB 工具…") { model.chooseADB() }
                Button("恢复内置 ADB") { UserDefaults.standard.removeObject(forKey: "adbPath") }
                Button("查看连接诊断…") { NSWorkspace.shared.activateFileViewerSelecting([ADBClient.diagnosticsURL]) }
                Text("USB 和已配对的无线调试均可使用。连接方式显示在设备页；当前版本需要重新连接来切换传输方式。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("操作提示") {
                Text("右键或 Esc 返回；⌘V 输入剪贴板文字。中文输入请在投屏窗口启用 Macroid 键盘，断开时恢复原输入法。")
                Text("窗口的更多操作中可分别设置窗口置顶；关屏使用会关闭手机物理屏幕，影响当前设备的所有窗口，关闭最后一个窗口时恢复。请先在手机上解锁。")
                Text("音频、通知和摄像头映射尚未实现。手机旋转后请重新打开投屏窗口。")
            }.font(.caption).foregroundStyle(.secondary)
            Section {
                HStack { BrandMark(size: 28); VStack(alignment: .leading) { Text("Macroid").font(.headline); Text("0.3.0 · macOS 13+ · Android 12+").font(.caption).foregroundStyle(.secondary) } }
                Text("助手无桌面图标，可在 Android 应用设置中卸载。最多同时打开四个窗口，受手机能力与应用限制。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped)
    }
}

struct WirelessConnectionView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var needsPairing = true
    @State private var pairing = ""
    @State private var code = ""
    @State private var address = UserDefaults.standard.string(forKey: "wirelessAddress") ?? ""
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("Wi-Fi 连接", systemImage: "wifi").font(.title2.weight(.semibold))
            Text("在手机“开发者选项 → 无线调试”中开启无线调试，让手机与 Mac 连接同一 Wi-Fi。")
                .font(.callout).foregroundStyle(.secondary)
            Toggle("首次配对", isOn: $needsPairing).toggleStyle(.switch).controlSize(.small)
            if needsPairing {
                Text("打开“使用配对码配对设备”，填写该弹窗里的地址和配对码。").font(.caption).foregroundStyle(.secondary)
                TextField("配对地址，例如 192.168.1.10:37123", text: $pairing)
                SecureField("6 位配对码", text: $code)
            }
            TextField("连接地址，例如 192.168.1.10:40125", text: $address)
            Text("连接地址来自无线调试主页，端口通常与配对端口不同。").font(.caption).foregroundStyle(.secondary)
            if !model.wirelessStatus.isEmpty { Text(model.wirelessStatus).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
            HStack {
                if model.wirelessBusy { ProgressView().controlSize(.small) }
                Spacer()
                Button("取消") { code = ""; dismiss() }.keyboardShortcut(.cancelAction).disabled(model.wirelessBusy)
                Button(needsPairing ? "配对并连接" : "连接") {
                    Task {
                        let success = await model.connectWireless(pairing: needsPairing ? pairing : nil, code: code, address: address)
                        code = ""
                        if success { model.section = "devices"; dismiss() }
                    }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(model.wirelessBusy || address.isEmpty || (needsPairing && (pairing.isEmpty || code.count != 6)))
            }
        }.textFieldStyle(.roundedBorder).padding(24).frame(width: 390).onAppear { model.wirelessStatus = "" }
    }
}


/// Preserve the native hidden-titlebar controls and add a small left inset matching the device toolbar.
private struct MainWindowChrome: NSViewRepresentable {
    func makeNSView(context: Context) -> Marker { Marker() }
    func updateNSView(_ view: Marker, context: Context) { view.applyChrome() }
    final class Marker: NSView {
        private var adjustedWindow: ObjectIdentifier?
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); applyChrome() }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        func applyChrome() {
            guard let window else { return }
            DispatchQueue.main.async { [weak self, weak window] in
                guard let self, let window else { return }
                window.titleVisibility = .hidden
                window.titlebarAppearsTransparent = true
                window.toolbarStyle = .unifiedCompact
                let id = ObjectIdentifier(window)
                guard self.adjustedWindow != id else { return }
                for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                    guard let button = window.standardWindowButton(type) else { continue }
                    var frame = button.frame
                    frame.origin.x += 6
                    button.setFrameOrigin(frame.origin)
                }
                self.adjustedWindow = id
            }
        }
    }
}
