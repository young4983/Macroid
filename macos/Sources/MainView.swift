import SwiftUI
import AppKit

private enum PanelStyle {
    static let blue = Color(red: 0.16, green: 0.35, blue: 0.85)
    static let cyan = Color(red: 0.30, green: 0.75, blue: 0.90)
    static let accent = Color(red: 0.18, green: 0.44, blue: 0.91)
    static let gradient = LinearGradient(colors: [blue, cyan], startPoint: .topLeading, endPoint: .bottomTrailing)
}

private let brand = PanelStyle.accent

private struct PanelSurface: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    var radius: CGFloat = 16

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .background(.regularMaterial, in: shape)
            .overlay {
                shape.strokeBorder(LinearGradient(
                    colors: [.white.opacity(colorScheme == .dark ? 0.14 : 0.85), brand.opacity(0.08)],
                    startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .shadow(color: .black.opacity(colorScheme == .dark ? 0.10 : 0.035), radius: 10, y: 3)
    }
}

struct BrandMark: View {
    var size: CGFloat = 42
    var body: some View {
        Image(nsImage: NSApplication.shared.applicationIconImage)
            .resizable().interpolation(.high).scaledToFit()
            .frame(width: size, height: size).accessibilityHidden(true)
    }
}

struct MainView: View {
    @ObservedObject var model: AppModel
    @State private var wireless = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                BrandMark(size: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Macroid").font(.system(size: 20, weight: .semibold, design: .rounded))
                    Text("让 Android 融入你的 Mac").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Button { Task { await model.refresh() } } label: {
                    ZStack {
                        if model.refreshing || model.connecting || model.disconnecting {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise").font(.system(size: 12, weight: .medium))
                        }
                    }.frame(width: 30, height: 30)
                        .background(.thinMaterial, in: Circle())
                }.buttonStyle(.plain).foregroundStyle(.secondary)
                    .help("刷新设备").accessibilityLabel("刷新设备")
                    .disabled(model.refreshing || model.connecting || model.disconnecting)
            }.padding(.horizontal, 20).padding(.vertical, 16)

            HStack(spacing: 3) {
                navigationItem("应用", icon: "square.grid.2x2", section: "apps")
                navigationItem("文件", icon: "folder", section: "files")
                navigationItem("设备", icon: "smartphone", section: "devices")
                navigationItem("设置", icon: "slider.horizontal.3", section: "settings")
            }.padding(4).modifier(PanelSurface(radius: 13))
                .padding(.horizontal, 20).padding(.bottom, 16)

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
            }.frame(maxWidth: .infinity, maxHeight: .infinity).transition(.opacity)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: model.connected)

            Rectangle().fill(Color.primary.opacity(0.06)).frame(height: 1)
            HStack(spacing: 7) {
                Circle().fill(model.connecting || model.disconnecting ? .orange : model.connected ? .green : Color.secondary.opacity(0.4))
                    .frame(width: 5, height: 5)
                Text(model.disconnecting ? "正在断开连接…" : model.connecting ? model.status : model.connected ? "\(model.connectedDevice?.connectionLabel ?? "") 已连接" : "等待连接设备")
                    .lineLimit(1)
                Spacer(minLength: 4)
                if model.connected {
                    Label("\(model.sessions.count) 个窗口", systemImage: "macwindow").monospacedDigit()
                } else {
                    Text("USB / Wi-Fi").foregroundStyle(.tertiary)
                }
            }.font(.system(size: 10)).foregroundStyle(.secondary)
                .padding(.horizontal, 20).frame(height: 34).help(model.status)
        }
        .background {
            ZStack {
                Color(nsColor: .windowBackgroundColor)
                LinearGradient(colors: [brand.opacity(0.07), PanelStyle.cyan.opacity(0.025), .clear], startPoint: .topLeading, endPoint: .bottomTrailing)
            }
        }
        .background(MainWindowChrome()).tint(brand)
        .frame(minWidth: 360, idealWidth: 392, maxWidth: 480, minHeight: 580, idealHeight: 690)
        .sheet(isPresented: $wireless) { WirelessConnectionView(model: model) }
        .alert("Macroid", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("好") { model.error = nil }
        } message: { Text(model.error ?? "") }
    }

    private func navigationItem(_ title: String, icon: String, section: String) -> some View {
        let selected = model.section == section
        return Button { model.section = section } label: {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 11, weight: selected ? .semibold : .regular))
                Text(title).font(.system(size: 12, weight: selected ? .semibold : .medium))
            }.foregroundStyle(selected ? brand : Color.secondary)
                .frame(maxWidth: .infinity).frame(height: 30)
                .background {
                    if selected {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(Color(nsColor: .controlBackgroundColor))
                            .shadow(color: .black.opacity(0.06), radius: 3, y: 1)
                    }
                }
                .contentShape(RoundedRectangle(cornerRadius: 9))
        }.buttonStyle(.plain).accessibilityLabel(title)
            .accessibilityAddTraits(selected ? .isSelected : [])
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: selected)
    }
}

struct WelcomeView: View {
    @ObservedObject var model: AppModel
    @Binding var wireless: Bool
    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                VStack(spacing: 10) {
                    Image(systemName: "macbook.and.iphone")
                        .font(.system(size: 38, weight: .light)).foregroundStyle(PanelStyle.gradient)
                        .frame(height: 48)
                    Text("手机应用，桌面随行").font(.system(size: 19, weight: .semibold))
                    Text("连接 Android，把熟悉的应用带到 Mac。")
                        .font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }.frame(maxWidth: .infinity).padding(.top, 8).padding(.bottom, 6)
                DeviceCard(model: model)
                WirelessCard(isPresented: $wireless, disabled: model.connecting || model.disconnecting)
                VStack(alignment: .leading, spacing: 13) {
                    Text("首次连接").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                    connectionStep("1", title: "用 USB 连接手机", detail: "在开发者选项中开启 USB 调试")
                    connectionStep("2", title: "允许这台 Mac", detail: "确认手机上的调试授权")
                    connectionStep("3", title: "点击连接，开始使用", detail: "自动安装助手，无桌面图标")
                }.padding(16).frame(maxWidth: .infinity, alignment: .leading).modifier(PanelSurface())
                Text("macOS 13+ · Android 12+").font(.caption2).foregroundStyle(.tertiary)
            }.padding(.horizontal, 20).padding(.bottom, 20)
        }
    }

    private func connectionStep(_ number: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(number).font(.system(size: 10, weight: .semibold)).foregroundStyle(brand)
                .frame(width: 20, height: 20).background(brand.opacity(0.08), in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 12, weight: .medium))
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }
}

struct DeviceCard: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "smartphone").font(.system(size: 23, weight: .light)).foregroundStyle(brand)
                    .frame(width: 38, height: 42).background(brand.opacity(0.08), in: RoundedRectangle(cornerRadius: 11))
                VStack(alignment: .leading, spacing: 4) {
                    if let device = model.connectedDevice {
                        Text(device.model).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                        HStack(spacing: 4) {
                            Circle().fill(.green).frame(width: 4, height: 4)
                            Text("已连接 · \(device.connectionLabel) · Android \(androidVersion)").lineLimit(1)
                        }.font(.system(size: 10)).foregroundStyle(.secondary)
                    } else if !model.devices.isEmpty {
                        Picker("设备", selection: $model.selectedSerial) {
                            ForEach(model.devices) { device in Text("\(device.model) · \(device.connectionLabel)").tag(device.serial) }
                        }.labelsHidden().disabled(model.connecting || model.disconnecting)
                        Text(model.connecting ? model.status : selectedDevice?.stateLabel ?? "选择设备")
                            .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text(model.refreshing ? "正在查找设备…" : "尚未发现设备").font(.system(size: 13, weight: .semibold))
                        Text("连接 USB，或通过 Wi-Fi 添加设备").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                if model.connected {
                    Button { model.open() } label: { Label("屏幕镜像", systemImage: "rectangle.on.rectangle").font(.system(size: 11, weight: .medium)) }
                        .buttonStyle(.borderedProminent).controlSize(.small)
                        .disabled(model.disconnecting).help("镜像手机当前屏幕").accessibilityLabel("屏幕镜像")
                }
            }
            if model.connected {
                Rectangle().fill(Color.primary.opacity(0.06)).frame(height: 1)
                HStack(spacing: 7) {
                    Image(systemName: "macwindow").font(.system(size: 12)).foregroundStyle(brand)
                    Text("融合模式").font(.system(size: 12, weight: .medium))
                    if model.sdk < 34 {
                        Text("兼容").font(.system(size: 9)).foregroundStyle(.secondary)
                            .padding(.horizontal, 5).padding(.vertical, 2).background(Color.primary.opacity(0.04), in: Capsule())
                    }
                    Spacer()
                    Toggle("融合模式", isOn: Binding(get: { model.fusionEnabled }, set: { model.fusionEnabled = $0 }))
                        .labelsHidden().toggleStyle(.switch).controlSize(.mini).disabled(model.disconnecting)
                }.help("开启后，应用在独立的 Mac 窗口中打开；关闭后，在手机主屏幕中打开并投屏。")
            } else {
                Button { Task { await model.connect() } } label: {
                    HStack { if model.connecting { ProgressView().controlSize(.small) }; Text(model.connecting ? "正在连接…" : "连接设备") }.frame(maxWidth: .infinity)
                }.buttonStyle(.borderedProminent).controlSize(.large)
                    .disabled(model.connecting || model.disconnecting || selectedDevice?.available != true)
            }
        }.padding(14).modifier(PanelSurface())
    }

    private var selectedDevice: AndroidDevice? { model.devices.first { $0.serial == model.selectedSerial } }
    private var androidVersion: String { model.sdk >= 33 ? String(model.sdk - 20) : "12" }
}

private struct WirelessCard: View {
    @Binding var isPresented: Bool
    var disabled = false

    var body: some View {
        Button { isPresented = true } label: {
            HStack(spacing: 10) {
                Image(systemName: "wifi").font(.system(size: 16)).foregroundStyle(brand)
                    .frame(width: 32, height: 32).background(brand.opacity(0.07), in: RoundedRectangle(cornerRadius: 9))
                VStack(alignment: .leading, spacing: 3) {
                    Text("通过 Wi-Fi 连接").font(.system(size: 12, weight: .medium)).foregroundStyle(.primary)
                    Text("同一网络，自由连接").font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
            }.padding(12).contentShape(RoundedRectangle(cornerRadius: 16))
        }.buttonStyle(.plain).modifier(PanelSurface()).disabled(disabled)
    }
}

struct DevicesView: View {
    @ObservedObject var model: AppModel
    @Binding var wireless: Bool
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(model.connected ? "当前设备" : "连接设备").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                DeviceCard(model: model)
                if model.connected {
                    HStack(alignment: .top, spacing: 12) {
                        Text(model.status).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        Button("断开连接", role: .destructive) { Task { await model.disconnect() } }
                            .controlSize(.small).disabled(model.disconnecting)
                    }
                    if let device = model.connectedDevice, !device.wireless {
                        Text("当前通过 USB 传输。拔线前请先在 Wi-Fi 中配对并选择无线设备重新连接。")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                WirelessCard(isPresented: $wireless, disabled: model.connecting || model.disconnecting)
                Text("手机与 Mac 需要在同一局域网。无线设备连接后，投屏不再依赖 USB 数据线。")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }.padding(.horizontal, 20).padding(.bottom, 20)
        }
    }
}

struct ApplicationsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 12) {
            DeviceCard(model: model)
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(.secondary)
                TextField("搜索应用或包名", text: $model.search).font(.system(size: 12)).textFieldStyle(.plain)
                    .accessibilityLabel("搜索应用或包名")
                if !model.search.isEmpty {
                    Button { model.search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                        .buttonStyle(.plain).help("清除搜索").accessibilityLabel("清除搜索")
                }
            }.padding(.horizontal, 12).frame(height: 36)
                .background(Color(nsColor: .textBackgroundColor).opacity(0.75), in: RoundedRectangle(cornerRadius: 11))
                .overlay { RoundedRectangle(cornerRadius: 11).strokeBorder(Color.primary.opacity(0.05)).allowsHitTesting(false) }
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if model.apps.isEmpty && model.connecting {
                        HStack(spacing: 8) { ProgressView().controlSize(.small); Text("正在读取应用…").font(.callout).foregroundStyle(.secondary) }
                            .frame(maxWidth: .infinity).padding(.top, 40)
                    } else if model.filteredApps.isEmpty {
                        emptyState
                    } else if !model.search.isEmpty {
                        appSection("搜索结果", apps: model.filteredApps)
                    } else {
                        let favorites = model.apps.filter { model.favorites.contains($0.package) }
                        let others = model.apps.filter { !model.favorites.contains($0.package) }
                        if !favorites.isEmpty { appSection("收藏应用", apps: favorites, icon: "star.fill") }
                        if !others.isEmpty { appSection(favorites.isEmpty ? "全部应用" : "其他应用", apps: others) }
                    }
                }.padding(.top, 4).padding(.bottom, 8)
            }
        }.padding(.horizontal, 20).padding(.bottom, 12)
    }

    private func appSection(_ title: String, apps: [AndroidApp], icon: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 5) {
                if let icon { Image(systemName: icon).font(.system(size: 9)).foregroundStyle(brand) }
                Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                Spacer()
                Text("\(apps.count)").font(.system(size: 10)).monospacedDigit().foregroundStyle(.tertiary)
            }.padding(.horizontal, 2)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                ForEach(apps) { app in AppCard(app: app, model: model) }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: model.search.isEmpty ? "square.grid.2x2" : "magnifyingglass")
                .font(.system(size: 28, weight: .light)).foregroundStyle(.tertiary)
            Text(model.search.isEmpty ? "暂无可打开的应用" : "没有找到应用").font(.system(size: 13, weight: .medium))
            Text(model.search.isEmpty ? "请检查设备连接后重试。" : "试试其他应用名称或包名。")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            if !model.search.isEmpty { Button("清除搜索") { model.search = "" }.buttonStyle(.link).font(.system(size: 12)) }
        }.frame(maxWidth: .infinity).padding(.top, 36)
    }
}

struct AppCard: View {
    let app: AndroidApp
    @ObservedObject var model: AppModel
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var isOpen: Bool { model.sessions.values.contains { $0.package == app.package } }

    var body: some View {
        Button { model.open(app) } label: {
            VStack(spacing: 7) {
                if let icon = model.icons[app.package] { Image(nsImage: icon).resizable().interpolation(.high).frame(width: 44, height: 44) }
                else { Image(systemName: "app.fill").font(.system(size: 40)).foregroundStyle(brand.opacity(0.6)).frame(width: 44, height: 44) }
                Text(app.name).font(.system(size: 11)).lineLimit(2).multilineTextAlignment(.center)
                    .frame(height: 28, alignment: .top).frame(maxWidth: .infinity)
            }.padding(.horizontal, 3).padding(.top, 10).padding(.bottom, 6).frame(maxWidth: .infinity)
                .background(hovering ? Color.primary.opacity(0.06) : isOpen ? brand.opacity(0.055) : Color(nsColor: .controlBackgroundColor).opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
                .overlay {
                    RoundedRectangle(cornerRadius: 12).strokeBorder(isOpen ? brand.opacity(0.18) : Color.primary.opacity(0.025))
                        .allowsHitTesting(false)
                }
                .overlay(alignment: .topTrailing) {
                    if isOpen { Circle().fill(.green).frame(width: 5, height: 5).padding(7).allowsHitTesting(false) }
                }
                .contentShape(RoundedRectangle(cornerRadius: 12))
        }.buttonStyle(.plain).onHover { hovering = $0 }.disabled(model.disconnecting)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: hovering)
            .help("\(app.name)\n\(app.package)\(isOpen ? "\n窗口已打开，点击返回窗口" : "")")
            .accessibilityLabel("\(app.name)\(isOpen ? "，窗口已打开" : "")")
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


/// Use native compact chrome so the panel and the device toolbar share the same button layout.
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
                let id = ObjectIdentifier(window)
                guard self.adjustedWindow != id else { return }
                WindowChrome.configure(window, showsTitle: false)
                self.adjustedWindow = id
            }
        }
    }
}
