import SwiftUI
import AppKit

// Menu bar seal: filled rounded square with 律 knocked out, rendered as a
// template image so it adapts to menu bar appearance like the IME icon.
private enum MenuBarSeal {
    static let image: NSImage = {
        let side: CGFloat = 17
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            guard let cgContext = NSGraphicsContext.current?.cgContext else { return false }

            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5),
                         xRadius: 4.2,
                         yRadius: 4.2).fill()

            cgContext.setBlendMode(.destinationOut)
            let font = NSFont(name: "HiraginoSans-W6", size: 11) ?? NSFont.boldSystemFont(ofSize: 11)
            let glyph = NSAttributedString(string: "律", attributes: [
                .font: font,
                .foregroundColor: NSColor.white,
            ])
            let glyphSize = glyph.size()
            glyph.draw(at: NSPoint(x: (rect.width - glyphSize.width) / 2,
                                   y: (rect.height - glyphSize.height) / 2))
            return true
        }
        image.isTemplate = true
        return image
    }()
}

@main
struct SampleRateSwitcherApp: App {
    @StateObject private var model = SampleRateModel()

    var body: some Scene {
        MenuBarExtra {
            GlassPanelView(model: model)
        } label: {
            HStack(spacing: 4) {
                Image(nsImage: MenuBarSeal.image)
                Text(model.menuBarTitle)
            }
        }
        .menuBarExtraStyle(.window)
    }
}
