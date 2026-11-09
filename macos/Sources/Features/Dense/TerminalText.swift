import AppKit
import SwiftUI

/// How the terminals draw text, for text outside them that should look the same.
struct TerminalLook: Equatable {
    var font: NSFont
    /// The theme's foreground color.
    var ink: NSColor
    /// Ghostty's font-thicken. Off by default, so terminal text is drawn without macOS
    /// font smoothing, which makes glyphs a little bolder.
    var thicken: Bool
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
