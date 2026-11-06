import AppKit
import SwiftUI

/// The screen and the surrounding device scale together; the Mac toolbar keeps its native size.
struct DeviceWindowLayout {
    static let margin: CGFloat = 12
    static let toolbarHeight: CGFloat = 36
    static let toolbarGap: CGFloat = 10
    static let bezel: CGFloat = 8
    static let screenRadius: CGFloat = 29
    let screen: NSSize
    var body: NSSize { NSSize(width: screen.width + 2 * Self.bezel, height: screen.height + 2 * Self.bezel) }
    var chromeHeight: CGFloat { 2 * Self.margin + Self.toolbarHeight + Self.toolbarGap }
    init(width: Int, height: Int) {
        let unit = 344 / CGFloat(max(1, min(width, height)))
        screen = NSSize(width: CGFloat(width) * unit, height: CGFloat(height) * unit)
    }
    func size(scale: CGFloat) -> NSSize {
        NSSize(width: body.width * scale + 2 * Self.margin, height: body.height * scale + chromeHeight)
    }
    func scale(fitting size: NSSize) -> CGFloat {
        max(0, min((size.width - 2 * Self.margin) / body.width, (size.height - chromeHeight) / body.height))
    }
}

@MainActor final class DeviceWindow: NSWindow {
    var fitDevice: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override func zoom(_ sender: Any?) { fitDevice?() }
}

struct DeviceResizeEdges: OptionSet {
    let rawValue: Int
    static let left = Self(rawValue: 1), right = Self(rawValue: 2), top = Self(rawValue: 4), bottom = Self(rawValue: 8)
}

/// Native hit testing keeps window gestures independent of SwiftUI and the embedded video view.
@MainActor final class DeviceContentView: NSView {
    let hosted: NSView
    let interaction: DeviceInteractionView
    override var isOpaque: Bool { false }
    init(hosted: NSView, isMirror: Bool, layout: @escaping () -> DeviceWindowLayout,
         resize: @escaping (NSSize, NSRect, DeviceResizeEdges) -> Void) {
        self.hosted = hosted
        interaction = DeviceInteractionView(isMirror: isMirror, layout: layout, resize: resize)
        super.init(frame: .zero)
        addSubview(hosted); addSubview(interaction)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layout() {
        super.layout(); hosted.frame = bounds; interaction.frame = bounds
        window?.invalidateCursorRects(for: interaction)
    }
}

@MainActor final class DeviceInteractionView: NSView {
    private let isMirror: Bool
    private let deviceLayout: () -> DeviceWindowLayout
    private let resize: (NSSize, NSRect, DeviceResizeEdges) -> Void
    private var tracking: NSTrackingArea?
    private var initialFrame = NSRect.zero
    private var initialMouse = NSPoint.zero
    private var resizing: DeviceResizeEdges = []
    private static let diagonalDown = diagonalCursor("arrow.up.left.and.arrow.down.right")
    private static let diagonalUp = diagonalCursor("arrow.up.right.and.arrow.down.left")
    override var isOpaque: Bool { false }
    init(isMirror: Bool, layout: @escaping () -> DeviceWindowLayout,
         resize: @escaping (NSSize, NSRect, DeviceResizeEdges) -> Void) {
        self.isMirror = isMirror; deviceLayout = layout; self.resize = resize
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    private static func diagonalCursor(_ symbol: String) -> NSCursor {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "调整大小")!
        image.size = NSSize(width: 18, height: 18)
        return NSCursor(image: image, hotSpot: NSPoint(x: 9, y: 9))
    }
    private var bodyRect: NSRect {
        let layout = deviceLayout(), scale = layout.scale(fitting: bounds.size)
        return NSRect(x: (bounds.width - layout.body.width * scale) / 2, y: DeviceWindowLayout.margin,
                      width: layout.body.width * scale, height: layout.body.height * scale)
    }
    private func dragRegionContains(_ point: NSPoint) -> Bool {
        let rightControls: CGFloat = isMirror ? 147 : 93
        let rect = NSRect(x: DeviceWindowLayout.margin + 70,
                          y: bounds.height - DeviceWindowLayout.margin - DeviceWindowLayout.toolbarHeight,
                          width: max(0, bounds.width - 2 * DeviceWindowLayout.margin - 70 - rightControls),
                          height: DeviceWindowLayout.toolbarHeight)
        return rect.contains(point)
    }
    private func edges(at point: NSPoint) -> DeviceResizeEdges {
        let layout = deviceLayout(), scale = layout.scale(fitting: bounds.size), body = bodyRect
        guard body.insetBy(dx: -4, dy: -4).contains(point) else { return [] }
        let screen = body.insetBy(dx: DeviceWindowLayout.bezel * scale, dy: DeviceWindowLayout.bezel * scale)
        let screenPath = NSBezierPath(roundedRect: screen, xRadius: DeviceWindowLayout.screenRadius * scale, yRadius: DeviceWindowLayout.screenRadius * scale)
        if screenPath.contains(point) { return [] }
        let corner = (DeviceWindowLayout.screenRadius + DeviceWindowLayout.bezel) * scale
        var edge: DeviceResizeEdges = []
        if point.x < body.minX + corner { edge.insert(.left) }
        else if point.x > body.maxX - corner { edge.insert(.right) }
        if point.y < body.minY + corner { edge.insert(.bottom) }
        else if point.y > body.maxY - corner { edge.insert(.top) }
        return edge
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        // hitTest receives coordinates in the superview, whose bounds match ours.
        guard !isHidden, bounds.contains(point) else { return nil }
        return !edges(at: point).isEmpty ? self : nil
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.activeAlways, .inVisibleRect, .mouseMoved, .cursorUpdate, .mouseEnteredAndExited], owner: self)
        addTrackingArea(area); tracking = area
    }
    private func updateCursor(_ event: NSEvent) {
        let edge = edges(at: convert(event.locationInWindow, from: nil))
        if edge.contains(.left) && edge.contains(.top) || edge.contains(.right) && edge.contains(.bottom) { Self.diagonalDown.set() }
        else if edge.contains(.right) && edge.contains(.top) || edge.contains(.left) && edge.contains(.bottom) { Self.diagonalUp.set() }
        else if !edge.intersection([.left, .right]).isEmpty { NSCursor.resizeLeftRight.set() }
        else if !edge.isEmpty { NSCursor.resizeUpDown.set() }
        else { NSCursor.arrow.set() }
    }
    override func cursorUpdate(with event: NSEvent) { updateCursor(event) }
    override func mouseMoved(with event: NSEvent) { updateCursor(event) }
    override func mouseExited(with event: NSEvent) { NSCursor.arrow.set() }
    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        let point = convert(event.locationInWindow, from: nil)
        resizing = edges(at: point)
        if resizing.isEmpty {
            if event.clickCount == 2 { window.zoom(nil) } else { window.performDrag(with: event) }
        } else {
            window.makeKeyAndOrderFront(nil)
            initialFrame = window.frame; initialMouse = NSEvent.mouseLocation
            updateCursor(event)
        }
    }
    override func mouseDragged(with event: NSEvent) {
        guard !resizing.isEmpty else { return }
        let point = NSEvent.mouseLocation
        let dx = point.x - initialMouse.x, dy = point.y - initialMouse.y
        let width = initialFrame.width + (resizing.contains(.left) ? -dx : resizing.contains(.right) ? dx : 0)
        let height = initialFrame.height + (resizing.contains(.bottom) ? -dy : resizing.contains(.top) ? dy : 0)
        resize(NSSize(width: width, height: height), initialFrame, resizing)
        updateCursor(event)
    }
    override func mouseUp(with event: NSEvent) { resizing = []; updateCursor(event) }
}

/// A small, explicit drag surface in the toolbar; it never sits on top of its buttons.
struct WindowDragRegion: NSViewRepresentable {
    func makeNSView(context: Context) -> DragSurface { DragSurface() }
    func updateNSView(_ view: DragSurface, context: Context) {}
    final class DragSurface: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { bounds.contains(point) ? self : nil }
        override func mouseDown(with event: NSEvent) {
            guard let window else { return }
            if event.clickCount == 2 { window.zoom(nil) } else { window.performDrag(with: event) }
        }
        override func resetCursorRects() { addCursorRect(bounds, cursor: .arrow) }
    }
}

struct DeviceTrafficLights: View {
    let close: () -> Void, minimize: () -> Void, fit: () -> Void
    @State private var hovering = false
    var body: some View {
        HStack(spacing: 4) {
            light(Color(red: 1, green: 0.37, blue: 0.34), "xmark", "关闭窗口", close)
            light(Color(red: 1, green: 0.75, blue: 0.19), "minus", "最小化窗口", minimize)
            light(Color(red: 0.16, green: 0.79, blue: 0.26), "arrow.up.left.and.arrow.down.right", "适合屏幕", fit)
        }.onHover { hovering = $0 }
    }
    private func light(_ color: Color, _ symbol: String, _ title: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ZStack {
                Circle().fill(color).overlay(Circle().strokeBorder(.black.opacity(0.12), lineWidth: 0.5))
                if hovering { Image(systemName: symbol).font(.system(size: 7, weight: .bold)).foregroundStyle(.black.opacity(0.6)) }
            }.frame(width: 12, height: 12)
                .frame(width: 16, height: 18).contentShape(Rectangle())
        }.buttonStyle(.plain).help(title).accessibilityLabel(title)
    }
}
