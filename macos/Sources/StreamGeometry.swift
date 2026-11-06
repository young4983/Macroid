import Foundation

/// Window content points correspond to Android dp, independently of Retina backing scale.
struct StreamGeometry: Equatable {
    let width: Int, height: Int, density: Int
    init(contentWidth: Double, contentHeight: Double) {
        let w = min(5460, max(320, contentWidth.isFinite ? contentWidth : 420))
        let h = min(5460, max(240, contentHeight.isFinite ? contentHeight : 720))
        width = Int((w * 1.5).rounded()) & ~1
        height = Int((h * 1.5).rounded()) & ~1
        density = 240
    }
    var values: [String: Any] { ["width": width, "height": height, "density": density] }
}
