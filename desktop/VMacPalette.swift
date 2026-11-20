import Cocoa

/// VMac's colors, in step with ui/src/vmac-tokens.mjs; the test in
/// ui/src/vmac-palette-sync.test.mjs fails when a hex value drifts. VMac is
/// always light, so each color is a single value.
enum CagePalette {
    private static func solid(_ hex: Int) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255,
                blue: CGFloat(hex & 255) / 255, alpha: 1)
    }

    static let paper = solid(0xFFFFFF) // token: page
    static let card = solid(0xFFFFFF) // token: popover
    static let sidebar = solid(0xF9FAFB) // token: chrome
    static let group = solid(0xF1F3F5) // token: group
    static let ink = solid(0x0F1115) // token: ink
    static let muted = solid(0x61666B) // token: muted
    static let faint = solid(0x81858C) // token: faint
    static let accent = solid(0x3964FE) // token: accent
    static let accentText = solid(0x2648CC) // token: accentText
    static let accentSoft = solid(0xE4EDFD) // token: accentSoft
    static let success = solid(0x22C55E) // token: okDot
    static let warn = solid(0xF59E0B) // token: warnDot
    static let danger = solid(0xF25A5A) // token: badDot
    /// Hairlines and hover washes are translucent so they sit on any surface.
    static let line = NSColor(white: 0, alpha: 0.08)
    static let hover = NSColor(srgbRed: 38 / 255, green: 49 / 255, blue: 72 / 255, alpha: 0.06)

    static func mono(_ size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        .monospacedDigitSystemFont(ofSize: size, weight: weight)
    }
}
