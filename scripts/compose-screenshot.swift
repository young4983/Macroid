import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

guard CommandLine.arguments.count == 3 else {
    fputs("usage: compose-screenshot.swift INPUT OUTPUT\n", stderr)
    exit(2)
}
let input = URL(fileURLWithPath: CommandLine.arguments[1])
guard let source = CGImageSourceCreateWithURL(input as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
    fatalError("Cannot read input screenshot")
}

let scale = min(1.0, 1500.0 / Double(image.height))
let padding = 68.0
let imageWidth = Double(image.width) * scale
let imageHeight = Double(image.height) * scale
let width = Int(imageWidth + padding * 2)
let height = Int(imageHeight + padding * 2)
guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                              bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
    fatalError("Cannot create output canvas")
}

context.setFillColor(NSColor(calibratedRed: 0.94, green: 0.96, blue: 0.98, alpha: 1).cgColor)
context.fill(CGRect(x: 0, y: 0, width: width, height: height))
context.saveGState()
context.translateBy(x: padding, y: padding)
context.scaleBy(x: scale, y: scale)
context.setShadow(offset: CGSize(width: 0, height: -8), blur: 24, color: NSColor.black.withAlphaComponent(0.16).cgColor)
let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
context.addPath(CGPath(roundedRect: rect, cornerWidth: 22 / scale, cornerHeight: 22 / scale, transform: nil))
context.clip()
context.draw(image, in: rect)
context.restoreGState()

let output = URL(fileURLWithPath: CommandLine.arguments[2]) as CFURL
guard let destination = CGImageDestinationCreateWithURL(output, UTType.png.identifier as CFString, 1, nil) else {
    fatalError("Cannot create PNG destination")
}
CGImageDestinationAddImage(destination, context.makeImage()!, nil)
guard CGImageDestinationFinalize(destination) else { fatalError("Cannot write PNG") }
