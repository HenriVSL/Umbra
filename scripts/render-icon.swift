// Renders the Umbra app icon: a dark speech bubble (the umbra) eclipsing a light one, leaving a
// bright rim, inside a faint reticle.
//
//   swift scripts/render-icon.swift <out-dir>
//
// Writes icon-ios.png (opaque, full bleed), icon-mac.png (rounded tile with margin and shadow) and
// icon-vision-back/front.png (visionOS layers). Copy them into Umbra/Assets.xcassets; the macOS
// sizes are made with `sips -z <n> <n>`.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let side = 1024
let S = CGFloat(side)
let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func canvas() -> CGContext {
    CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
}

func save(_ ctx: CGContext, _ path: String) {
    let url = URL(fileURLWithPath: path) as CFURL
    let dest = CGImageDestinationCreateWithURL(url, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
    CGImageDestinationFinalize(dest)
}

func gradient(_ colors: [CGColor]) -> CGGradient {
    CGGradient(colorsSpace: sRGB, colors: colors as CFArray, locations: nil)!
}

/// Speech bubble: a circle whose outline flows into a pointed tail at the lower left, as one path.
func bubble(_ c: CGPoint, _ r: CGFloat) -> CGPath {
    func at(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: c.x + x * r, y: c.y + y * r) }
    let p = CGMutablePath()
    // Counterclockwise from just left of the bottom, all the way round to the lower left.
    p.addArc(center: c, radius: r, startAngle: 250 * .pi / 180, endAngle: 208 * .pi / 180, clockwise: false)
    p.addQuadCurve(to: at(-0.98, -1.04), control: at(-0.72, -0.78))  // continues the arc's tangent
    p.addQuadCurve(to: at(-0.342, -0.940), control: at(-0.62, -0.84))  // meets the arc tangentially
    p.closeSubpath()
    return p
}

func fill(_ ctx: CGContext, _ path: CGPath) {
    ctx.addPath(path)
    ctx.fillPath()
}

func clip(_ ctx: CGContext, _ path: CGPath) {
    ctx.addPath(path)
    ctx.clip()
}

let center = CGPoint(x: S * 0.5, y: S * 0.53)
let radius = S * 0.29
let shift = S * 0.022

func drawBackground(_ ctx: CGContext) {
    ctx.drawLinearGradient(gradient([rgb(0x1E2A25), rgb(0x0B110F)]),
                           start: CGPoint(x: 0, y: S), end: CGPoint(x: 0, y: 0), options: [])
    // Faint reticle: the "tactical" cue, quiet enough to vanish at small sizes.
    ctx.setStrokeColor(rgb(0x9FD9BE, 0.10))
    ctx.setLineWidth(S * 0.006)
    let rr = S * 0.40
    ctx.strokeEllipse(in: CGRect(x: S / 2 - rr, y: S / 2 - rr, width: 2 * rr, height: 2 * rr))
    for (dx, dy) in [(0.0, 1.0), (0.0, -1.0), (1.0, 0.0), (-1.0, 0.0)] {
        ctx.move(to: CGPoint(x: S / 2 + dx * rr * 0.9, y: S / 2 + dy * rr * 0.9))
        ctx.addLine(to: CGPoint(x: S / 2 + dx * rr * 1.08, y: S / 2 + dy * rr * 1.08))
    }
    ctx.strokePath()
}

func drawEclipse(_ ctx: CGContext) {
    let light = bubble(CGPoint(x: center.x + shift, y: center.y - shift), radius)
    let dark = bubble(CGPoint(x: center.x - shift, y: center.y + shift), radius)
    // Corona glow.
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: S * 0.07, color: rgb(0xFFA24A, 0.85))
    ctx.setFillColor(rgb(0xFFB45E))
    fill(ctx, light)
    ctx.restoreGState()
    // Crisp lit edge.
    ctx.saveGState()
    clip(ctx, light)
    ctx.drawLinearGradient(gradient([rgb(0xFFE7B0), rgb(0xFF8F3A)]),
                           start: CGPoint(x: center.x - radius, y: center.y + radius),
                           end: CGPoint(x: center.x + radius, y: center.y - radius), options: [])
    ctx.restoreGState()
    // The umbra.
    ctx.saveGState()
    clip(ctx, dark)
    ctx.drawLinearGradient(gradient([rgb(0x18221E), rgb(0x060908)]),
                           start: CGPoint(x: center.x - radius, y: center.y + radius),
                           end: CGPoint(x: center.x + radius, y: center.y - radius), options: [])
    ctx.restoreGState()
}

let out = CommandLine.arguments[1]

// iOS / master: full-bleed square, opaque (the system applies the mask).
let ios = canvas()
drawBackground(ios)
drawEclipse(ios)
save(ios, "\(out)/icon-ios.png")

// visionOS layers: opaque back, transparent front.
let back = canvas()
drawBackground(back)
save(back, "\(out)/icon-vision-back.png")
let front = canvas()
drawEclipse(front)
save(front, "\(out)/icon-vision-front.png")

// macOS: the artwork inside the standard rounded square with margin and drop shadow.
let mac = canvas()
let inset = S * 100 / 1024
let tile = CGRect(x: inset, y: inset, width: S - 2 * inset, height: S - 2 * inset)
let shape = CGPath(roundedRect: tile, cornerWidth: tile.width * 0.225, cornerHeight: tile.width * 0.225, transform: nil)
mac.saveGState()
mac.setShadow(offset: CGSize(width: 0, height: -S * 0.01), blur: S * 0.03, color: rgb(0x000000, 0.45))
mac.addPath(shape)
mac.setFillColor(rgb(0x0B110F))
mac.fillPath()
mac.restoreGState()
mac.addPath(shape)
mac.clip()
mac.draw(ios.makeImage()!, in: tile)
save(mac, "\(out)/icon-mac.png")
