import SwiftUI

@main
struct AnkiSpeedrunApp: App {
    /// User's theme choice, applied app-wide. Shares its key with the settings
    /// screen so changes there re-render the whole app immediately.
    @AppStorage(AppTheme.storageKey) private var appThemeRaw = AppTheme.system.rawValue
    /// User's interface-size choice (Anki's "User interface size"), applied
    /// app-wide via `dynamicTypeSize`. Shares its key with the settings screen.
    @AppStorage(UISize.storageKey) private var uiSizeRaw = UISize.system.rawValue

    var body: some Scene {
        WindowGroup {
            HomeView()
                .preferredColorScheme(AppTheme.from(rawValue: appThemeRaw).colorScheme)
                .modifier(UISizeModifier(size: UISize.from(rawValue: uiSizeRaw).dynamicTypeSize))
        }
    }
}

/// Applies an absolute Dynamic Type size app-wide when one is chosen, or leaves
/// the system setting untouched for `.system` (nil). Kept as a modifier so the
/// `.system` case doesn't override the user's accessibility preference.
private struct UISizeModifier: ViewModifier {
    let size: DynamicTypeSize?
    func body(content: Content) -> some View {
        if let size {
            content.dynamicTypeSize(size)
        } else {
            content
        }
    }
}
