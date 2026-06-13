#!/usr/bin/env swift
// Generates AppIcon.iconset (and, via iconutil, AppIcon.icns) for PDC002 Flasher.
// Pure Core Graphics — no external assets. Artwork is vector, re-rendered crisp
// at every required pixel size. Run: swift Scripts/make_icon.swift [out.iconset]
import AppKit
import CoreGraphics

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset"
let fm = FileManager.default
try? fm.removeItem(atPath: outDir)
try! fm.createDirectory(atPath: outDir, withIntermediateDirectories: true)

let rgb = CGColorSpaceCreateDeviceRGB()
func c(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> CGColor {
    CGColor(colorSpace: rgb, components: [CGFloat(r), CGFloat(g), CGFloat(b), CGFloat(a)])!
}

/// Draw the whole icon in a fixed 1024-unit design space, scaled to the target.
func draw(into ctx: CGContext, pixel: Int) {
    let scale = CGFloat(pixel) / 1024.0
    ctx.scaleBy(x: scale, y: scale)   // design space is now 1024 × 1024

    // Rounded-rect "squircle" body, Apple grid: 824 box centered in 1024.
    let margin: CGFloat = 100
    let box = CGRect(x: margin, y: margin, width: 1024 - 2 * margin, height: 1024 - 2 * margin)
    let corner = box.width * 0.2237
    let body = CGPath(roundedRect: box, cornerWidth: corner, cornerHeight: corner, transform: nil)

    // Soft drop shadow so the tile floats (origin is bottom-left → -y is "down").
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -16), blur: 40, color: c(0, 0, 0, 0.35))
    ctx.addPath(body)
    ctx.setFillColor(c(0, 0, 0, 1))
    ctx.fillPath()
    ctx.restoreGState()

    // Background gradient: electric blue (top) → deep indigo (bottom).
    ctx.saveGState()
    ctx.addPath(body)
    ctx.clip()
    let bg = CGGradient(colorsSpace: rgb,
                        colors: [c(0.23, 0.49, 1.00), c(0.03, 0.13, 0.42)] as CFArray,
                        locations: [0, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])

    // Top sheen for depth.
    let sheen = CGGradient(colorsSpace: rgb,
                           colors: [c(1, 1, 1, 0.22), c(1, 1, 1, 0)] as CFArray,
                           locations: [0, 1])!
    ctx.drawRadialGradient(sheen, startCenter: CGPoint(x: 512, y: 820), startRadius: 0,
                           endCenter: CGPoint(x: 512, y: 820), endRadius: 560, options: [])
    ctx.restoreGState()

    // Lightning bolt (the hero glyph).
    let pts = [
        CGPoint(x: 575, y: 808), CGPoint(x: 330, y: 506), CGPoint(x: 476, y: 506),
        CGPoint(x: 452, y: 214), CGPoint(x: 700, y: 548), CGPoint(x: 548, y: 548),
    ]
    let bolt = CGMutablePath()
    bolt.move(to: pts[0])
    for p in pts.dropFirst() { bolt.addLine(to: p) }
    bolt.closeSubpath()

    // Charged glow underneath the bolt.
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 34, color: c(1.0, 0.78, 0.2, 0.85))
    ctx.addPath(bolt)
    ctx.setFillColor(c(1, 0.7, 0, 1))
    ctx.fillPath()
    ctx.restoreGState()

    // Amber gradient fill.
    ctx.saveGState()
    ctx.addPath(bolt)
    ctx.clip()
    let amber = CGGradient(colorsSpace: rgb,
                           colors: [c(1.0, 0.92, 0.42), c(1.0, 0.62, 0.05)] as CFArray,
                           locations: [0, 1])!
    ctx.drawLinearGradient(amber, start: CGPoint(x: 512, y: 808), end: CGPoint(x: 512, y: 214),
                           options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    ctx.restoreGState()

    // Crisp edge.
    ctx.addPath(bolt)
    ctx.setLineWidth(7)
    ctx.setLineJoin(.round)
    ctx.setStrokeColor(c(0.78, 0.45, 0.0, 0.55))
    ctx.strokePath()
}

let sizes = [16, 32, 64, 128, 256, 512, 1024]
for px in sizes {
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                     isPlanar: false, colorSpaceName: .deviceRGB,
                                     bytesPerRow: 0, bitsPerPixel: 0),
          let nsctx = NSGraphicsContext(bitmapImageRep: rep) else { fatalError("rep \(px)") }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = nsctx
    draw(into: nsctx.cgContext, pixel: px)
    NSGraphicsContext.restoreGraphicsState()
    let png = rep.representation(using: .png, properties: [:])!
    // Map pixel size → iconset filenames (1x and @2x variants share pixel sizes).
    let names: [String]
    switch px {
    case 16: names = ["icon_16x16.png"]
    case 32: names = ["icon_16x16@2x.png", "icon_32x32.png"]
    case 64: names = ["icon_32x32@2x.png"]
    case 128: names = ["icon_128x128.png"]
    case 256: names = ["icon_128x128@2x.png", "icon_256x256.png"]
    case 512: names = ["icon_256x256@2x.png", "icon_512x512.png"]
    case 1024: names = ["icon_512x512@2x.png"]
    default: names = []
    }
    for n in names { try! png.write(to: URL(fileURLWithPath: "\(outDir)/\(n)")) }
}
print("Wrote \(outDir)")
