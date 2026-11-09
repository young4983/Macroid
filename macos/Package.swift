// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "MacroidWire", defaultLocalization: "en", platforms: [.macOS(.v13)], products: [.library(name: "MacroidWire", targets: ["MacroidWire"])], targets: [
    .target(name: "MacroidWire", path: ".", exclude: ["Tests", "build", "Macroid.xcodeproj", "Info.plist",
        "Sources/ADBClient.swift", "Sources/AppModel.swift", "Sources/DeviceWindow.swift", "Sources/FileBrowser.swift",
        "Sources/IntegrationHarness.swift", "Sources/LanguageSettings.swift", "Sources/MacroidApp.swift", "Sources/MainView.swift",
        "Sources/MirrorWindow.swift", "Sources/StatusMenu.swift", "Sources/Transport.swift", "Sources/VideoRenderer.swift",
        "Resources/Macroid.apk", "Resources/adb", "Resources/adb-NOTICE.txt", "Resources/Macroid.icns",
        "Resources/THIRD_PARTY_NOTICES.md", "Resources/scrcpy-Apache-2.0.txt"],
        sources: ["Sources/Wire.swift", "Sources/NALUnit.swift", "Sources/StreamGeometry.swift", "Sources/Localization.swift"],
        resources: [.process("Resources/en.lproj"), .process("Resources/zh-Hans.lproj")]),
    .testTarget(name: "MacroidWireTests", dependencies: ["MacroidWire"], path: "Tests")
])
