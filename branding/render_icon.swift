import AppKit
import CoreText
import ImageIO

// Renders the Choritsu app icon (sumi background, cream mincho 律,
// vermilion seal) plus the separated layers for Icon Composer.
// Run: swift branding/render_icon.swift

let canvas: CGFloat = 1024

let sumi = CGColor(srgbRed: 33 / 255, green: 30 / 255, blue: 27 / 255, alpha: 1)
let cream = CGColor(srgbRed: 242 / 255, green: 235 / 255, blue: 221 / 255, alpha: 1)
let vermilion = CGColor(srgbRed: 217 / 255, green: 65 / 255, blue: 43 / 255, alpha: 1)
let white = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)

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

func drawGlyph(in ctx: CGContext) {
    let fontSize: CGFloat = 540
    let font = NSFont(name: "HiraMinProN-W6", size: fontSize)
        ?? NSFont(name: "HiraMinProN-W3", size: fontSize)
        ?? NSFont.systemFont(ofSize: fontSize, weight: .semibold)
    print("glyph font: \(font.fontName)")

    let attrs: [NSAttributedString.Key: Any] = [
        .font: font,
        NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
    ]
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: "律", attributes: attrs))
    let bounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)

    ctx.setFillColor(cream)
    // Optically a touch above geometric center, like a hanging scroll.
    let x = (canvas - bounds.width) / 2 - bounds.minX
    let y = (canvas - bounds.height) / 2 - bounds.minY + 14
    ctx.textPosition = CGPoint(x: x, y: y)
    CTLineDraw(line, ctx)
}

func drawSeal(in ctx: CGContext) {
    let sealSize: CGFloat = 172
    let margin: CGFloat = 118
    let rect = CGRect(x: canvas - margin - sealSize, y: margin, width: sealSize, height: sealSize)

    ctx.setFillColor(vermilion)
    ctx.addPath(CGPath(roundedRect: rect, cornerWidth: 43, cornerHeight: 43, transform: nil))
    ctx.fillPath()

    let waveWidth = sealSize * 0.58
    let amplitude: CGFloat = 40
    let startX = rect.midX - waveWidth / 2
    let midY = rect.midY

    let wave = CGMutablePath()
    wave.move(to: CGPoint(x: startX, y: midY))
    wave.addQuadCurve(to: CGPoint(x: startX + waveWidth / 2, y: midY),
                      control: CGPoint(x: startX + waveWidth / 4, y: midY + amplitude))
    wave.addQuadCurve(to: CGPoint(x: startX + waveWidth, y: midY),
                      control: CGPoint(x: startX + waveWidth * 3 / 4, y: midY - amplitude))

    ctx.setStrokeColor(white)
    ctx.setLineWidth(13)
    ctx.setLineCap(.round)
    ctx.addPath(wave)
    ctx.strokePath()
}

let dir = "branding"

let composite = makeContext()
composite.setFillColor(sumi)
composite.fill(CGRect(x: 0, y: 0, width: canvas, height: canvas))
drawGlyph(in: composite)
drawSeal(in: composite)
save(composite, to: "\(dir)/icon_1024.png")

let glyphLayer = makeContext()
drawGlyph(in: glyphLayer)
save(glyphLayer, to: "\(dir)/layer_glyph.png")

let sealLayer = makeContext()
drawSeal(in: sealLayer)
save(sealLayer, to: "\(dir)/layer_seal.png")
