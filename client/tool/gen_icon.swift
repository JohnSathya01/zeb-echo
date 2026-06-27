// Generates the Echo app icon (1024×1024 PNG) using CoreGraphics — the
// echo-ripple mark on the zeb dark green-charcoal canvas, matching the in-app
// logo + theme tokens. Run: swiftc -O -o gen_icon gen_icon.swift && ./gen_icon out.png
import AppKit
import CoreGraphics
import Foundation

let size = 1024
let args = CommandLine.arguments
let outPath = args.count > 1 ? args[1] : "app_icon_1024.png"

let cs = CGColorSpaceCreateDeviceRGB()
guard
    let ctx = CGContext(
        data: nil, width: size, height: size, bitsPerComponent: 8,
        bytesPerRow: 0, space: cs,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
else { fatalError("ctx") }

let s = CGFloat(size)

// Brand tokens (match app_colors.dart).
func rgb(_ r: Int, _ g: Int, _ b: Int, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: a)
}
let bgTop = rgb(0x22, 0x2B, 0x26)     // surface
let bgBottom = rgb(0x11, 0x16, 0x0F)  // deepest
let accent = rgb(0xB6, 0xE0, 0x8A)    // lime

// Rounded-rect background with a subtle vertical gradient.
let inset: CGFloat = s * 0.06
let rect = CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
let radius = s * 0.22
let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
ctx.saveGState()
ctx.addPath(path)
ctx.clip()
let grad = CGGradient(
    colorsSpace: cs, colors: [bgTop, bgBottom] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(
    grad, start: CGPoint(x: 0, y: s), end: CGPoint(x: 0, y: 0), options: [])
ctx.restoreGState()

// Echo ripples — refined: evenly-spaced concentric arcs opening right with a
// gentle outward taper in weight + opacity, plus an origin dot. Matches the
// in-app EchoLogo geometry.
let origin = CGPoint(x: s * 0.38, y: s * 0.5)
ctx.setLineCap(.round)
let arcCount = 3
let baseR = s * 0.13
let ringGap = s * 0.105
let sweep: CGFloat = 2.5
for i in 0..<arcCount {
    let r = baseR + ringGap * CGFloat(i)
    let strokeW = s * (0.072 - CGFloat(i) * 0.009)
    let opacity = 1.0 - CGFloat(i) * 0.26
    ctx.setStrokeColor(accent.copy(alpha: opacity)!)
    ctx.setLineWidth(strokeW)
    ctx.addArc(
        center: origin, radius: r, startAngle: -sweep / 2, endAngle: sweep / 2,
        clockwise: false)
    ctx.strokePath()
}
ctx.setFillColor(accent)
ctx.fillEllipse(
    in: CGRect(
        x: origin.x - s * 0.05, y: origin.y - s * 0.05, width: s * 0.10,
        height: s * 0.10))

guard let img = ctx.makeImage() else { fatalError("img") }
let rep = NSBitmapImageRep(cgImage: img)
guard let data = rep.representation(using: .png, properties: [:]) else {
    fatalError("png")
}
try! data.write(to: URL(fileURLWithPath: outPath))
print("wrote \(outPath)")
