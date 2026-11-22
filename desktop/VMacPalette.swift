import Cocoa

/// VMac's colors, in step with ui/src/vmac-tokens.mjs; the test in
/// ui/src/vmac-palette-sync.test.mjs fails when a hex value drifts. They are
/// DeepSeek's: a white page, a faintly blue-grey sidebar, near-black text, one
/// blue, and a green for a good state. VMac is always light.
enum CagePalette {
    private static func solid(_ hex: Int) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255,
                blue: CGFloat(hex & 255) / 255, alpha: 1)
    }

    static let paper = solid(0xFFFFFF) // token: page
    static let card = solid(0xFFFFFF) // token: popover
    static let sidebar = solid(0xF9FAFB) // token: chrome
    static let track = solid(0xEBEEF2) // token: navActive
    static let ink = solid(0x0F1115) // token: ink
    static let secondary = solid(0x61666B) // token: secondary
    static let tertiary = solid(0x81858C) // token: tertiary
    static let caption = solid(0xADB2B8) // token: caption
    static let accent = solid(0x3964FE) // token: accent
    static let accentText = solid(0x3964FE) // token: accentText
    static let accentSoft = solid(0xE4EDFD) // token: accentSoft
    static let ok = solid(0x22C55E) // token: ok
    static let warn = solid(0xF59E0B) // token: warn
    /// The middle light of red, yellow and green: something on its way.
    static let starting = solid(0xEAB308) // token: starting
    static let danger = solid(0xEC1313) // token: bad
    static let dangerOnDark = solid(0xF25A5A) // token: badOnDark
    static let toast = solid(0x353638) // token: toast
    /// An edge is black at a tenth; the fill under the pointer is DeepSeek's
    /// hover tint.
    static let line = NSColor(white: 0, alpha: 0.1)
    static let hover = NSColor(srgbRed: 38 / 255, green: 49 / 255, blue: 72 / 255, alpha: 0.06)

    static func mono(_ size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        .monospacedDigitSystemFont(ofSize: size, weight: weight)
    }
}
