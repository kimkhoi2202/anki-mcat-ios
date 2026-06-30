import SwiftUI
import UIKit

/// Semantic design tokens for AnkiSpeedrun.
///
/// `DS` is a namespace (uninstantiable enum) exposing adaptive colors, a spacing
/// scale, corner radii, typography, and layout metrics. Every color adapts to
/// light/dark mode and every font is built on a Dynamic Type text style so the
/// UI respects the user's content-size preference.
enum DS {

    // MARK: - Colors

    /// App backdrop behind scrollable content.
    static var background: Color { adaptive(light: 0xF5F6F8, dark: 0x0E0F13) }
    /// Raised container surface (cards, sheets).
    static var surface: Color { adaptive(light: 0xFFFFFF, dark: 0x191B21) }
    /// Hairline dividers and card borders.
    static var separator: Color { adaptive(light: 0xDFE2E8, dark: 0x2B2E36) }

    /// Primary, high-emphasis text.
    static var textPrimary: Color { adaptive(light: 0x14161B, dark: 0xF3F4F6) }
    /// Secondary, lower-emphasis text.
    static var textSecondary: Color { adaptive(light: 0x5D636E, dark: 0x9BA1AD) }

    /// Brand accent for primary actions. Used as a fill behind white text, so it
    /// is kept dark enough to clear WCAG AA with white in both appearances
    /// (white contrast ~7.0:1 light / ~6.4:1 dark).
    static var accent: Color { adaptive(light: 0x4B45C9, dark: 0x5249D6) }

    // Review rating colors. Deep, saturated tones chosen so white label text
    // clears WCAG AA (>=4.5:1) against the fill in BOTH light and dark mode;
    // approximate white-on-fill contrast ratios are noted per color.
    /// "Again" rating (red). White contrast ~5.9:1 light / ~5.4:1 dark.
    static var again: Color { adaptive(light: 0xC0271F, dark: 0xCC2A22) }
    /// "Hard" rating (orange). White contrast ~6.0:1 light / ~5.1:1 dark.
    static var hard: Color { adaptive(light: 0xB23A0A, dark: 0xBB4A0A) }
    /// "Good" rating (blue). White contrast ~6.0:1 light / ~5.8:1 dark.
    static var good: Color { adaptive(light: 0x1C5BD6, dark: 0x2060D0) }
    /// "Easy" rating (green). White contrast ~5.9:1 light / ~5.4:1 dark.
    static var easy: Color { adaptive(light: 0x157347, dark: 0x18794A) }

    // MARK: - Spacing

    /// Spacing scale in points.
    enum Spacing {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
    }

    // MARK: - Corner radii

    /// Corner radii in points.
    enum Radius {
        static let small: CGFloat = 8
        static let medium: CGFloat = 12
        static let large: CGFloat = 16
    }

    // MARK: - Typography

    /// Dynamic Type-scaled fonts.
    enum Typography {
        static var title: Font { .system(.title2, design: .rounded).weight(.bold) }
        static var headline: Font { .system(.headline) }
        static var body: Font { .system(.body) }
        static var caption: Font { .system(.caption) }
    }

    // MARK: - Metrics

    /// Minimum touch-target edge length (Apple HIG / WCAG).
    static let minTapTarget: CGFloat = 44

    // MARK: - Helpers

    /// Builds a color that resolves differently for light and dark mode.
    private static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(uiColor: UIColor { trait in
            trait.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light)
        })
    }
}

private extension UIColor {
    /// Creates an opaque color from a `0xRRGGBB` integer.
    convenience init(hex: UInt32) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}
