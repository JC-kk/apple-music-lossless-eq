import AppKit
import Foundation
import ImageIO

// Renders the Choritsu app icon: two offset sine waves on sumi ink that read
// as both a parametric-EQ response curve (boost bell + soft cut) and a
// front-back afterimage — the cream wave is the audio/EQ, the 利休-green ghost
// trailing behind is the output following the source sample rate.
// The two waves are kept as separate Icon Composer layers so Liquid Glass
// parallaxes them into real depth. Run: swift branding/render_icon.swift

let canvas: CGFloat = 1024

let sumi = CGColor(srgbRed: 33 / 255, green: 30 / 255, blue: 27 / 255, alpha: 1)
let cream = CGColor(srgbRed: 242 / 255, green: 235 / 255, blue: 221 / 255, alpha: 1)
let rikyu = CGColor(srgbRed: 115 / 255, green: 120 / 255, blue: 66 / 255, alpha: 1)

// Curve geometry. CoreGraphics origin is bottom-left, so a positive response
// (a boost) lifts the point toward the top of the canvas.
let x0: CGFloat = 150
let x1: CGFloat = 874
let midY: CGFloat = 470
let amp: CGFloat = 156
let strokeW: CGFloat = 52
let samples = 220

// A classic PEQ response: one boost bell, one gentle cut, flat at the edges.
func waveResponse(_ t: Double) -> Double {
    let boost = exp(-pow((t - 0.28) / 0.14, 2))
    let cut = 0.30 * exp(-pow((t - 0.72) / 0.17, 2))
    return boost - cut
}

func wavePath(dx: CGFloat, dy: CGFloat) -> CGPath {
    let path = CGMutablePath()
    for i in 0...samples {
        let t = Double(i) / Double(samples)
        let x = x0 + (x1 - x0) * CGFloat(t) + dx
        let y = midY + amp * CGFloat(waveResponse(t)) + dy
        if i == 0 {
            path.move(to: CGPoint(x: x, y: y))
        } else {
            path.addLine(to: CGPoint(x: x, y: y))
        }
    }
    return path
}

func makeContext() -> CGContext {
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    return CGContext(data: nil,
                     width: Int(canvas),
                     height: Int(canvas),
                     bitsPerComponent: 8,
                     bytesPerRow: 0,
                     space: colorSpace,
                     bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
}

func save(_ ctx: CGContext, to path: String) {
    let image = ctx.makeImage()!
    let url = URL(fileURLWithPath: path) as CFURL
    let dest = CGImageDestinationCreateWithURL(url, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
    print("wrote \(path)")
}

func drawWave(in ctx: CGContext, color: CGColor, dx: CGFloat, dy: CGFloat) {
    ctx.setStrokeColor(color)
    ctx.setLineWidth(strokeW)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.addPath(wavePath(dx: dx, dy: dy))
    ctx.strokePath()
}

// EQ band handles: hollow circles sitting on the front wave at the two band
// centres (the boost peak and the soft cut), drawn as a cream ring around a
// sumi core so they read as draggable nodes punched onto the curve.
let nodeT: [Double] = [0.28, 0.72]
let nodeRadius: CGFloat = 34
let nodeRing: CGFloat = 14

func drawNodes(in ctx: CGContext) {
    for t in nodeT {
        let x = x0 + (x1 - x0) * CGFloat(t)
        let y = midY + amp * CGFloat(waveResponse(t))
        let rect = CGRect(x: x - nodeRadius, y: y - nodeRadius,
                          width: nodeRadius * 2, height: nodeRadius * 2)
        ctx.setFillColor(sumi)
        ctx.fillEllipse(in: rect)
        ctx.setStrokeColor(cream)
        ctx.setLineWidth(nodeRing)
        ctx.strokeEllipse(in: rect)
    }
}

// The ghost trails to the lower-right of the front wave.
let ghostDX: CGFloat = 46
let ghostDY: CGFloat = -30

let dir = "branding"

let composite = makeContext()
composite.setFillColor(sumi)
composite.fill(CGRect(x: 0, y: 0, width: canvas, height: canvas))
drawWave(in: composite, color: rikyu, dx: ghostDX, dy: ghostDY)
drawWave(in: composite, color: cream, dx: 0, dy: 0)
drawNodes(in: composite)
save(composite, to: "\(dir)/icon_1024.png")

let frontLayer = makeContext()
drawWave(in: frontLayer, color: cream, dx: 0, dy: 0)
drawNodes(in: frontLayer)
save(frontLayer, to: "\(dir)/layer_front.png")

let backLayer = makeContext()
drawWave(in: backLayer, color: rikyu, dx: ghostDX, dy: ghostDY)
save(backLayer, to: "\(dir)/layer_back.png")
