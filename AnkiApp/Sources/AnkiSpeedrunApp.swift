import SwiftUI

@main
struct AnkiSpeedrunApp: App {
    /// User's theme choice, applied app-wide. Shares its key with the settings
    /// screen so changes there re-render the whole app immediately.
    @AppStorage(AppTheme.storageKey) private var appThemeRaw = AppTheme.system.rawValue

    var body: some Scene {
        WindowGroup {
            HomeView()
                .preferredColorScheme(AppTheme.from(rawValue: appThemeRaw).colorScheme)
        }
    }
}
