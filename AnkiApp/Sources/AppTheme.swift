import SwiftUI

/// App-wide theme choice, cloning AnkiDroid's "Theme" appearance setting
/// (`app_theme`: Follow system / Light / Dark).
///
/// Persisted as its `rawValue` via `@AppStorage(AppTheme.storageKey)` and applied
/// at the app root through `preferredColorScheme`. `System` resolves to `nil`,
/// which hands control back to the OS appearance.
enum AppTheme: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    /// `@AppStorage` key shared between the app root and the settings screen.
    static let storageKey = "appTheme"

    var id: String { rawValue }

    /// Short label for the theme picker (mirrors AnkiDroid's app theme labels).
    var label: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    /// The SwiftUI color scheme to force, or `nil` to follow the system.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    /// Decodes a stored raw value, falling back to `.system` for anything
    /// unrecognized.
    static func from(rawValue: String) -> AppTheme {
        AppTheme(rawValue: rawValue) ?? .system
    }
}
