import Foundation

enum FusionQuality: String, CaseIterable {
    case automatic, compatibility
    var title: String { self == .automatic ? L("清晰（匹配屏幕）") : L("兼容（较低分辨率）") }
    func pixelScale(for backingScale: Double) -> Double { self == .compatibility ? 1.5 : max(1.5, backingScale) }
}

/// Backing pixels and density scale together, so one window point remains one Android dp.
struct StreamGeometry: Equatable {
    let width: Int, height: Int, density: Int
    init(contentWidth: Double, contentHeight: Double, pixelScale: Double = 2) {
        let scale = min(4, max(1.5, pixelScale.isFinite ? pixelScale : 2))
        let w = min(8192 / scale, max(320, contentWidth.isFinite ? contentWidth : 420))
        let h = min(8192 / scale, max(240, contentHeight.isFinite ? contentHeight : 720))
        width = Int((w * scale).rounded()) & ~1
        height = Int((h * scale).rounded()) & ~1
        density = Int((160 * scale).rounded())
    }
    var values: [String: Any] { ["width": width, "height": height, "density": density] }
}
