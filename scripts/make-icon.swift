import AppKit
let target = CommandLine.arguments[1]
// Use a fixed pixel canvas; NSImage.lockFocus() follows the current display's Retina scale.
let bitmap = CGContext(data: nil, width: 1024, height: 1024, bitsPerComponent: 8, bytesPerRow: 0,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(cgContext: bitmap, flipped: false)
// Give the icon tile the usual macOS outer padding: 824 px in a 1024 px canvas.
// Scale all artwork together to preserve the mark's proportions within the tile.
let artworkTransform = NSAffineTransform()
artworkTransform.translateX(by: 512, yBy: 512)
artworkTransform.scale(by: 824.0 / 928.0)
artworkTransform.translateX(by: -512, yBy: -512)
artworkTransform.concat()
let rect = NSRect(x: 48, y: 48, width: 928, height: 928)
let background = NSBezierPath(roundedRect: rect, xRadius: 214, yRadius: 214)
background.addClip()
NSGradient(starting: NSColor(srgbRed: 0.16, green: 0.35, blue: 0.85, alpha: 1), ending: NSColor(srgbRed: 0.30, green: 0.75, blue: 0.90, alpha: 1))!.draw(in: rect, angle: -45)
NSColor.white.withAlphaComponent(0.45).setStroke()
let back = NSBezierPath(roundedRect: NSRect(x: 226, y: 408, width: 456, height: 326), xRadius: 44, yRadius: 44)
back.lineWidth = 28; back.stroke()
let frontRect = NSRect(x: 344, y: 284, width: 456, height: 326)
NSColor.white.withAlphaComponent(0.17).setFill(); NSBezierPath(roundedRect: frontRect, xRadius: 44, yRadius: 44).fill()
NSColor.white.setStroke()
let front = NSBezierPath(roundedRect: frontRect, xRadius: 44, yRadius: 44); front.lineWidth = 28; front.stroke()
let title = NSBezierPath(); title.move(to: NSPoint(x: 362, y: 532)); title.line(to: NSPoint(x: 782, y: 532)); title.lineWidth = 15; title.stroke()
NSGraphicsContext.restoreGraphicsState()
let rep = NSBitmapImageRep(cgImage: bitmap.makeImage()!)
try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: target))
