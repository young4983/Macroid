// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "MacroidWire", platforms: [.macOS(.v13)], products: [.library(name: "MacroidWire", targets: ["MacroidWire"])], targets: [
    .target(name: "MacroidWire", path: "Sources", sources: ["Wire.swift", "NALUnit.swift"]),
    .testTarget(name: "MacroidWireTests", dependencies: ["MacroidWire"], path: "Tests")
])
