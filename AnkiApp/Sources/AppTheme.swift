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

/// App-wide interface text size, cloning Anki's Preferences ▸ Appearance "User
/// interface size". A client-only control (it scales the SwiftUI chrome, not the
/// card content, which is rendered by the web view), so it's persisted with
/// `@AppStorage` and applied at the app root via `dynamicTypeSize`. `.system`
/// leaves the user's Dynamic Type setting untouched.
enum UISize: String, CaseIterable, Identifiable {
    case system
    case small
    case large
    case extraLarge

    /// `@AppStorage` key shared between the app root and the settings screen.
    static let storageKey = "uiSize"

    var id: String { rawValue }

    /// Short label for the picker.
    var label: String {
        switch self {
        case .system: return "System"
        case .small: return "Small"
        case .large: return "Large"
        case .extraLarge: return "Extra Large"
        }
    }

    /// The Dynamic Type size to force, or `nil` to follow the system setting.
    /// `.large` is SwiftUI's default size, so it's the baseline for "Small"
    /// (one step down) and the larger options (steps up).
    var dynamicTypeSize: DynamicTypeSize? {
        switch self {
        case .system: return nil
        case .small: return .small
        case .large: return .xLarge
        case .extraLarge: return .xxxLarge
        }
    }

    /// Decodes a stored raw value, falling back to `.system`.
    static func from(rawValue: String) -> UISize {
        UISize(rawValue: rawValue) ?? .system
    }
}

/// Namespacing for the client-only "Full-screen reviewer" toggle (Anki's
/// Appearance ▸ Distractions, "hide bars during review"). Stored with
/// `@AppStorage`; the Settings screen edits it and the reviewer reads it to hide
/// the status bar and home indicator for a distraction-free session.
enum FullScreenReviewer {
    static let storageKey = "fullScreenReviewer"
}

/// Namespacing for the first-launch onboarding gate, cloning AnkiDroid's
/// `IntroductionActivity.INTRODUCTION_SLIDES_SHOWN` preference. The intro flow is
/// shown once (when this `@AppStorage` flag is `false`) and sets it to `true` on
/// finish/skip so it never reappears — the exact key name AnkiDroid uses.
enum Onboarding {
    static let storageKey = "IntroductionSlidesShown"
}
