import Cocoa

/// VMac's colors, in step with ui/src/vmac-tokens.mjs; the test in
/// ui/src/vmac-palette-sync.test.mjs fails when a hex value drifts. Every
/// color follows the light or dark appearance it is resolved under.
enum CagePalette {
    private static func isDark(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }
    private static func dynamic(_ light: Int, _ dark: Int) -> NSColor {
        NSColor(name: nil) { appearance in
            let hex = isDark(appearance) ? dark : light
            return NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255,
                           blue: CGFloat(hex & 255) / 255, alpha: 1)
        }
    }

    static let paper = dynamic(0xFFFFFF, 0x151517) // token: page
    static let card = dynamic(0xFFFFFF, 0x2C2C2E) // token: popover
    static let sidebar = dynamic(0xF9FAFB, 0x1B1B1C) // token: chrome
    static let group = dynamic(0xF1F3F5, 0x232324) // token: group
    static let ink = dynamic(0x0F1115, 0xF5F6F7) // token: ink
    static let muted = dynamic(0x61666B, 0xA8ADB4) // token: muted
    static let faint = dynamic(0x81858C, 0x7A8089) // token: faint
    static let accent = dynamic(0x3964FE, 0x5686FE) // token: accent
    static let accentText = dynamic(0x2648CC, 0x8FB0FF) // token: accentText
    static let accentSoft = dynamic(0xE4EDFD, 0x252E45) // token: accentSoft
    static let success = dynamic(0x22C55E, 0x22C55E) // token: okDot
    static let warn = dynamic(0xF59E0B, 0xF59E0B) // token: warnDot
    static let danger = dynamic(0xF25A5A, 0xF25A5A) // token: badDot
    /// Hairlines and hover washes are translucent so they sit on any surface.
    static let line = NSColor(name: nil) { isDark($0) ? NSColor(white: 1, alpha: 0.1) : NSColor(white: 0, alpha: 0.08) }
    static let hover = NSColor(name: nil) {
        isDark($0) ? NSColor(white: 1, alpha: 0.06) : NSColor(srgbRed: 38 / 255, green: 49 / 255, blue: 72 / 255, alpha: 0.06)
    }

    static func mono(_ size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        .monospacedDigitSystemFont(ofSize: size, weight: weight)
    }
}

extension NSColor {
    /// The color as a layer color under the view's own appearance. Layers do
    /// not follow appearance changes, so callers set it again from
    /// viewDidChangeEffectiveAppearance.
    func cgColor(in view: NSView) -> CGColor {
        var resolved = cgColor
        view.effectiveAppearance.performAsCurrentDrawingAppearance { resolved = cgColor }
        return resolved
    }
}
