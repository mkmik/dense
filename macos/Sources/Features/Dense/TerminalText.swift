import AppKit
import GhosttyKit
import SwiftUI

/// How the terminals draw text, for text outside them that should look the same.
struct TerminalLook: Equatable {
    var font: NSFont
    /// The theme's foreground color.
    var ink: NSColor
    /// Ghostty's font-thicken. Off by default, so terminal text is drawn without macOS
    /// font smoothing, which makes glyphs a little bolder.
    var thicken: Bool

    /// The look from the config. Until a terminal has been shown, `font` is nil and the
    /// font is the system's monospaced one at the config's font-size.
    init(config: Ghostty.Config, font: NSFont?) {
        var size: Float = 13
        var thicken = false
        var ink = ghostty_config_color_s()
        if let config = config.config {
            func get<T>(_ key: String, _ value: inout T) -> Bool {
                ghostty_config_get(config, &value, key, UInt(key.lengthOfBytes(using: .utf8)))
            }
            _ = get("font-size", &size)
            _ = get("font-thicken", &thicken)
            if !get("foreground", &ink) { ink = .init(r: 0, g: 0, b: 0) }
        }
        self.font = font ?? .monospacedSystemFont(ofSize: CGFloat(size), weight: .regular)
        self.ink = NSColor(srgbRed: CGFloat(ink.r) / 255, green: CGFloat(ink.g) / 255, blue: CGFloat(ink.b) / 255, alpha: 1)
        self.thicken = thicken
    }

    /// The width of one character, and the height of one line, in the font.
    var cell: CGSize {
        CGSize(width: ("M" as NSString).size(withAttributes: [.font: font]).width,
               height: NSLayoutManager().defaultLineHeight(for: font))
    }
}

/// One line of text drawn as Ghostty draws terminal text: in the terminal's font and
/// color, with macOS font smoothing only if font-thicken is on. SwiftUI's Text always
/// smooths, which looks heavier than the terminal next to it. Truncated at the end.
struct TerminalText: NSViewRepresentable {
    let text: String
    let look: TerminalLook
    /// How much of the ink to use: 1 for text, less for secondary text.
    var opacity: CGFloat = 1

    func makeNSView(context: Context) -> Label {
        let label = Label(labelWithString: text)
        label.lineBreakMode = .byTruncatingTail
        label.cell?.truncatesLastVisibleLine = true
        // Let SwiftUI make it narrower than its text, which it then truncates.
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }

    func updateNSView(_ label: Label, context: Context) {
        label.stringValue = text
        label.font = look.font
        label.textColor = look.ink.withAlphaComponent(look.ink.alphaComponent * opacity)
        if label.thicken != look.thicken {
            label.thicken = look.thicken
            label.needsDisplay = true
        }
    }

    final class Label: NSTextField {
        var thicken = false

        override func draw(_ dirtyRect: NSRect) {
            if let context = NSGraphicsContext.current?.cgContext {
                context.setAllowsFontSmoothing(thicken)
                context.setShouldSmoothFonts(thicken)
            }
            super.draw(dirtyRect)
        }
    }
}
