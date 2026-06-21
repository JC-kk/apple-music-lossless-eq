import AppKit
import Foundation
import ImageIO

// Renders the Choritsu app icon: two offset sine waves on sumi ink. The cream
// wave is the audio signal; the 利休-green wave staggered behind it is the
// afterimage — the output trailing the source sample rate. A phase + position
// offset weaves the two waves over each other (正弦波・前後の交叠). They stay
// separate Icon Composer layers so Liquid Glass parallaxes them into depth.
// Run: swift branding/render_icon.swift

let canvas: CGFloat = 1024

let sumi = CGColor(srgbRed: 33 / 255, green: 30 / 255, blue: 27 / 255, alpha: 1)
let cream = CGColor(srgbRed: 242 / 255, green: 235 / 255, blue: 221 / 255, alpha: 1)
let rikyu = CGColor(srgbRed: 115 / 255, green: 120 / 255, blue: 66 / 255, alpha: 1)

// Wave geometry. CoreGraphics origin is bottom-left.
let x0: CGFloat = 138
let x1: CGFloat = 886
let midY: CGFloat = 512
let amp: CGFloat = 196
let strokeW: CGFloat = 48
let samples = 360
let cycles: Double = 1.0

// A clean sine wave — reads as an audio waveform / 正弦波.
func waveSine(_ t: Double, phase: Double) -> Double {
    sin(t * 2 * .pi * cycles + phase)
}

func wavePath(dx: CGFloat, dy: CGFloat, phase: Double) -> CGPath {
    let path = CGMutablePath()
    for i in 0...samples {
        let t = Double(i) / Double(samples)
        let x = x0 + (x1 - x0) * CGFloat(t) + dx
        let y = midY + amp * CGFloat(waveSine(t, phase: phase)) + dy
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

func drawWave(in ctx: CGContext, color: CGColor, dx: CGFloat, dy: CGFloat, phase: Double) {
    ctx.setStrokeColor(color)
    ctx.setLineWidth(strokeW)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.addPath(wavePath(dx: dx, dy: dy, phase: phase))
    ctx.strokePath()
}

// EQ band handles on the front wave: a cream ring around a sumi core, sitting
// on the crest and the trough so they read as draggable PEQ nodes.
let nodeT: [Double] = [0.25, 0.75]
let nodeRadius: CGFloat = 34
let nodeRing: CGFloat = 14

func drawNodes(in ctx: CGContext) {
    for t in nodeT {
        let x = x0 + (x1 - x0) * CGFloat(t)
        let y = midY + amp * CGFloat(waveSine(t, phase: 0))
        let rect = CGRect(x: x - nodeRadius, y: y - nodeRadius,
                          width: nodeRadius * 2, height: nodeRadius * 2)
        ctx.setFillColor(sumi)
        ctx.fillEllipse(in: rect)
        ctx.setStrokeColor(cream)
        ctx.setLineWidth(nodeRing)
        ctx.strokeEllipse(in: rect)
    }
}

// The green wave is staggered behind the cream one: a phase shift weaves it
// across the front wave, a small offset lifts it into its own parallax layer.
let ghostDX: CGFloat = 18
let ghostDY: CGFloat = -26
let ghostPhase: Double = 0.62

let dir = "branding"

let composite = makeContext()
composite.setFillColor(sumi)
composite.fill(CGRect(x: 0, y: 0, width: canvas, height: canvas))
drawWave(in: composite, color: rikyu, dx: ghostDX, dy: ghostDY, phase: ghostPhase)
drawWave(in: composite, color: cream, dx: 0, dy: 0, phase: 0)
drawNodes(in: composite)
save(composite, to: "\(dir)/icon_1024.png")

let frontLayer = makeContext()
drawWave(in: frontLayer, color: cream, dx: 0, dy: 0, phase: 0)
drawNodes(in: frontLayer)
save(frontLayer, to: "\(dir)/layer_front.png")

let backLayer = makeContext()
drawWave(in: backLayer, color: rikyu, dx: ghostDX, dy: ghostDY, phase: ghostPhase)
save(backLayer, to: "\(dir)/layer_back.png")
