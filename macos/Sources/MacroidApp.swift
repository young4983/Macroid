import AppKit
import SwiftUI

@main struct MacroidApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = AppModel.shared
    var body: some Scene {
        Window("Macroid", id: "main") { MainView(model: model) }.defaultSize(width: 392, height: 690)
            .windowStyle(.hiddenTitleBar).windowResizability(.contentSize)
            .commands {
                CommandGroup(replacing: .newItem) { }
                CommandMenu("设备") {
                    Button("刷新设备") { Task { await model.refresh() } }.keyboardShortcut("r", modifiers: .command)
                    Button("手机屏幕") { model.open() }.disabled(!model.connected)
                    Button("断开连接") { Task { await model.disconnect() } }.disabled(!model.connected)
                }
            }
        MenuBarExtra {
            StatusMenu(model: model)
        } label: {
            Image(nsImage: StatusMenu.icon).accessibilityLabel("Macroid")
        }.menuBarExtraStyle(.menu)
        Settings {
            VStack(alignment: .leading, spacing: 16) {
                Text("ADB 工具").font(.headline)
                Text("优先使用你选择的 adb，其次使用应用内置版本。重新连接后生效。").font(.callout).foregroundStyle(.secondary)
                HStack { Button("选择 adb…") { model.chooseADB() }; Button("恢复内置版本") { UserDefaults.standard.removeObject(forKey: "adbPath") } }
            }.padding(24).frame(width: 420)
        }
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    private var deviceRefreshTask: Task<Void, Never>?
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Device discovery must outlive the main panel so the menu remains useful after closing it.
        deviceRefreshTask = Task {
            await AppModel.shared.refresh()
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 3_000_000_000) } catch { break }
                await AppModel.shared.refresh(silent: true)
            }
        }
        IntegrationHarness.runIfRequested()
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) { deviceRefreshTask?.cancel() }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard AppModel.shared.connected || AppModel.shared.connecting else { return .terminateNow }
        Task { await AppModel.shared.disconnect(); sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
}
