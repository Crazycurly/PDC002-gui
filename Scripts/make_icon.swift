#!/usr/bin/env swift
// Generates AppIcon.iconset (and, via iconutil, AppIcon.icns) for PDC002 Flasher.
// Source artwork is a single high-res PNG (AppIcon-source.png). This script
// center-crops it square, clips it into the macOS rounded-rect "squircle" with a
// soft drop shadow, and re-renders crisp at every required icon size.
// Run: swift Scripts/make_icon.swift [out.iconset] [source.png]
import AppKit
import CoreGraphics

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset"
let srcPath = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "AppIcon-source.png"
let fm = FileManager.default

// Load the source artwork.
guard let nsImage = NSImage(contentsOfFile: srcPath),
      let src = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    fatalError("cannot load source image: \(srcPath)")
}

// Content-aware square crop: the bright subject sits off-centre in a wide field
// of dark ground, so locate it by brightness and crop a padded square around it.
// This keeps the artwork centred and large regardless of the source framing.
let pad: CGFloat = 1.45   // crop side relative to the subject's longer dimension
let crop = subjectCrop(of: src, pad: pad)
guard let art = src.cropping(to: crop) else { fatalError("crop failed") }

/// Find a square crop centred on the artwork's bright subject.
func subjectCrop(of cg: CGImage, pad: CGFloat) -> CGRect {
    let w = cg.width, h = cg.height
    var px = [UInt8](repeating: 0, count: w * h * 4)
    let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
    func lum(_ x: Int, _ y: Int) -> Double {
        let i = (y * w + x) * 4
        return 0.2126 * Double(px[i]) + 0.7152 * Double(px[i + 1]) + 0.0722 * Double(px[i + 2])
    }
    // Background level from the four corners; subject is markedly brighter.
    var bg = 0.0
    for (cx, cy) in [(5, 5), (w - 6, 5), (5, h - 6), (w - 6, h - 6)] { bg += lum(cx, cy) }
    bg /= 4
    // Brightness "mass" projected onto each axis, then clip the sparse tails
    // (faint motion streaks, the corner sparkle) to isolate the real subject.
    var colM = [Double](repeating: 0, count: w), rowM = [Double](repeating: 0, count: h)
    for y in 0..<h { for x in 0..<w {
        let v = lum(x, y) - bg
        if v > 30 { colM[x] += v; rowM[y] += v }
    } }
    func span(_ m: [Double]) -> (Int, Int) {
        let total = m.reduce(0, +); var acc = 0.0; var lo = 0, hi = m.count - 1
        for i in m.indices { acc += m[i]; if acc >= 0.015 * total { lo = i; break } }
        acc = 0; for i in m.indices { acc += m[i]; if acc >= 0.985 * total { hi = i; break } }
        return (lo, hi)
    }
    let (x0, x1) = span(colM), (y0, y1) = span(rowM)
    let cx = CGFloat(x0 + x1) / 2, cy = CGFloat(y0 + y1) / 2
    var side = CGFloat(max(x1 - x0, y1 - y0)) * pad
    side = min(side, CGFloat(min(w, h)))                 // never larger than the image
    var ox = cx - side / 2, oy = cy - side / 2
    ox = min(max(ox, 0), CGFloat(w) - side)              // keep the crop inside the frame
    oy = min(max(oy, 0), CGFloat(h) - side)
    return CGRect(x: ox, y: oy, width: side, height: side)
}

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

    // Clip to the squircle and fill it with the cropped artwork.
    ctx.saveGState()
    ctx.addPath(body)
    ctx.clip()
    ctx.interpolationQuality = .high
    ctx.draw(art, in: box)
    ctx.restoreGState()
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
