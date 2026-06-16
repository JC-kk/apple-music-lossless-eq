import AppKit
import CoreText
import ImageIO

// Renders the Choritsu app icon (sumi background, cream tuning fork — 音叉,
// the universal mark of tuning — with a vermilion 律 seal) plus the
// separated layers for Icon Composer.
// Run: swift branding/render_icon.swift

let canvas: CGFloat = 1024

let sumi = CGColor(srgbRed: 33 / 255, green: 30 / 255, blue: 27 / 255, alpha: 1)
let cream = CGColor(srgbRed: 242 / 255, green: 235 / 255, blue: 221 / 255, alpha: 1)
let vermilion = CGColor(srgbRed: 217 / 255, green: 65 / 255, blue: 43 / 255, alpha: 1)
let rikyu = CGColor(srgbRed: 115 / 255, green: 120 / 255, blue: 66 / 255, alpha: 1)

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

// The hero: a tuning fork (音叉). CoreGraphics origin is bottom-left, so
// higher y is nearer the top — the prong tips sit high, the handle hangs low.
func drawFork(in ctx: CGContext) {
    let centerX: CGFloat = 512
    let halfGap: CGFloat = 96       // prong centres at centerX ± halfGap
    let strokeW: CGFloat = 54

    let tipY: CGFloat = 838         // top of the prongs
    let bendStartY: CGFloat = 452   // where the straight prongs meet the U
    let bendBottomY: CGFloat = 392  // lowest point of the U / top of the stem
    let stemBottomY: CGFloat = 232  // bottom of the handle

    let leftX = centerX - halfGap
    let rightX = centerX + halfGap

    // Two subtle 利休-green resonance arcs, just outside the prong tips.
    let arcs = CGMutablePath()
    arcs.move(to: CGPoint(x: leftX - 36, y: tipY + 30))
    arcs.addQuadCurve(to: CGPoint(x: leftX - 36, y: tipY - 70),
                      control: CGPoint(x: leftX - 86, y: tipY - 20))
    arcs.move(to: CGPoint(x: rightX + 36, y: tipY + 30))
    arcs.addQuadCurve(to: CGPoint(x: rightX + 36, y: tipY - 70),
                      control: CGPoint(x: rightX + 86, y: tipY - 20))
    ctx.setStrokeColor(rikyu)
    ctx.setLineWidth(18)
    ctx.setLineCap(.round)
    ctx.addPath(arcs)
    ctx.strokePath()

    // The fork itself: U-joined prongs plus a hanging stem.
    let fork = CGMutablePath()
    fork.move(to: CGPoint(x: leftX, y: tipY))
    fork.addLine(to: CGPoint(x: leftX, y: bendStartY))
    fork.addQuadCurve(to: CGPoint(x: centerX, y: bendBottomY),
                      control: CGPoint(x: leftX, y: bendBottomY))
    fork.addQuadCurve(to: CGPoint(x: rightX, y: bendStartY),
                      control: CGPoint(x: rightX, y: bendBottomY))
    fork.addLine(to: CGPoint(x: rightX, y: tipY))

    fork.move(to: CGPoint(x: centerX, y: bendBottomY))
    fork.addLine(to: CGPoint(x: centerX, y: stemBottomY))

    ctx.setStrokeColor(cream)
    ctx.setLineWidth(strokeW)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.addPath(fork)
    ctx.strokePath()
}

// Centre the kanji 律 inside an arbitrary rect, in mincho type.
func drawKanji(_ string: String, in ctx: CGContext, rect: CGRect, fontSize: CGFloat, color: CGColor) {
    let font = NSFont(name: "HiraMinProN-W6", size: fontSize)
        ?? NSFont(name: "HiraMinProN-W3", size: fontSize)
        ?? NSFont.systemFont(ofSize: fontSize, weight: .semibold)

    let attrs: [NSAttributedString.Key: Any] = [
        .font: font,
        NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
    ]
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: attrs))
    let bounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)

    ctx.setFillColor(color)
    let x = rect.midX - bounds.width / 2 - bounds.minX
    let y = rect.midY - bounds.height / 2 - bounds.minY
    ctx.textPosition = CGPoint(x: x, y: y)
    CTLineDraw(line, ctx)
}

// The vermilion seal, bottom-right, now stamped with 律 — the brand's signature.
func drawSeal(in ctx: CGContext) {
    let sealSize: CGFloat = 196
    let margin: CGFloat = 104
    let rect = CGRect(x: canvas - margin - sealSize, y: margin, width: sealSize, height: sealSize)

    ctx.setFillColor(vermilion)
    ctx.addPath(CGPath(roundedRect: rect, cornerWidth: 48, cornerHeight: 48, transform: nil))
    ctx.fillPath()

    // Optically a touch above centre, the way a seal is cut.
    let glyphRect = rect.offsetBy(dx: 0, dy: 8)
    drawKanji("律", in: ctx, rect: glyphRect, fontSize: 132, color: cream)
}

let dir = "branding"

let composite = makeContext()
composite.setFillColor(sumi)
composite.fill(CGRect(x: 0, y: 0, width: canvas, height: canvas))
drawFork(in: composite)
drawSeal(in: composite)
save(composite, to: "\(dir)/icon_1024.png")

let glyphLayer = makeContext()
drawFork(in: glyphLayer)
save(glyphLayer, to: "\(dir)/layer_glyph.png")

let sealLayer = makeContext()
drawSeal(in: sealLayer)
save(sealLayer, to: "\(dir)/layer_seal.png")
