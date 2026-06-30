import SwiftUI
import AnkiKit

/// Settings screen, cloning a focused subset of AnkiDroid's Preferences as a
/// native grouped `Form`:
///
/// - **Account / Sync** — the synced account and a login/logout action, plus the
///   custom sync server when one is configured (AnkiDroid's Sync settings).
/// - **Appearance** — the app Theme picker (AnkiDroid's `app_theme`), persisted
///   with `@AppStorage` and applied app-wide via `preferredColorScheme`.
/// - **Reviewing** — engine-backed toggles read/written through the collection
///   `Preferences` message (AnkiDroid's Appearance/Study review settings).
/// - **About** — app version and the linked Anki engine build hash.
struct SettingsView: View {
    @ObservedObject var store: AnkiStore
    @AppStorage(AppTheme.storageKey) private var appThemeRaw = AppTheme.system.rawValue
    @State private var serverChoice: ServerChoice = .ankiweb
    @State private var customServerURL = ""
    @State private var serverLoaded = false

    var body: some View {
        Form {
            accountSection
            serverSection
            appearanceSection
            reviewingSection
            dataSection
            aboutSection
        }
        .scrollContentBackground(.hidden)
        .background(DS.background.ignoresSafeArea())
        .tint(DS.accent)
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            store.loadPreferences()
            loadServerState()
        }
    }

    // MARK: - Account / Sync

    private var accountSection: some View {
        Section {
            if store.isLoggedIn {
                DSStatRow("Account", value: store.syncUsername.isEmpty ? "AnkiWeb" : store.syncUsername)
                Button(role: .destructive) {
                    store.logout()
                } label: {
                    Label("Log out", systemImage: "rectangle.portrait.and.arrow.right")
                }
            } else {
                Text("Not logged in")
                    .font(DS.Typography.body)
                    .foregroundStyle(DS.textSecondary)
                Button {
                    store.showLogin = true
                } label: {
                    Label("Log in to sync", systemImage: "person.crop.circle.badge.plus")
                        .foregroundStyle(DS.accent)
                }
            }
        } header: {
            sectionHeader("Account & Sync")
        } footer: {
            sectionFooter(
                store.isLoggedIn
                    ? "Your collection syncs with this account."
                    : "Sign in to your AnkiWeb account (or a self-hosted server) to sync."
            )
        }
    }

    // MARK: - Sync server

    /// Editable sync-server picker. AnkiDroid keeps the custom sync server in
    /// Preferences (not on the login screen); we mirror that here. The choice is
    /// written to `store.preferredSyncServer`, which `login` uses as the endpoint.
    private var serverSection: some View {
        Section {
            Picker(selection: $serverChoice) {
                Text("MCAT Sync (our server)").tag(ServerChoice.mcat)
                Text("AnkiWeb (default)").tag(ServerChoice.ankiweb)
                Text("Other…").tag(ServerChoice.other)
            } label: {
                Text("Sync server")
                    .font(DS.Typography.body)
                    .foregroundStyle(DS.textPrimary)
            }
            .pickerStyle(.menu)
            .tint(DS.textSecondary)
            .onChange(of: serverChoice) { _ in applyServer() }

            if serverChoice == .other {
                TextField("https://my-sync-server.example.com/", text: $customServerURL)
                    .textContentType(.URL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(DS.Typography.body)
                    .foregroundStyle(DS.textPrimary)
                    .onChange(of: customServerURL) { _ in applyServer() }
            }
        } header: {
            sectionHeader("Sync server")
        } footer: {
            sectionFooter(
                "Used when you log in. To switch servers, log out and log in again."
            )
        }
    }

    // MARK: - Appearance

    private var appearanceSection: some View {
        Section {
            Picker(selection: themeBinding) {
                ForEach(AppTheme.allCases) { theme in
                    Text(theme.label).tag(theme)
                }
            } label: {
                Text("Theme")
                    .font(DS.Typography.body)
                    .foregroundStyle(DS.textPrimary)
            }
            .pickerStyle(.segmented)
        } header: {
            sectionHeader("Appearance")
        } footer: {
            sectionFooter("“System” follows your device's light/dark appearance.")
        }
    }

    // MARK: - Reviewing (engine-backed)

    private var reviewingSection: some View {
        Section {
            if store.preferencesAvailable {
                Toggle("Show next review time above answer buttons", isOn: boolBinding(
                    get: { store.reviewingPrefs.showIntervalsOnButtons },
                    set: store.setShowIntervalsOnButtons
                ))
                Toggle("Show remaining card count", isOn: boolBinding(
                    get: { store.reviewingPrefs.showRemainingDueCounts },
                    set: store.setShowRemainingDueCounts
                ))
                Toggle("Show play buttons on cards with audio", isOn: boolBinding(
                    get: { store.reviewingPrefs.showPlayButtonsOnAudio },
                    set: store.setShowPlayButtonsOnAudio
                ))
            } else {
                Text("Reviewing preferences are unavailable.")
                    .font(DS.Typography.body)
                    .foregroundStyle(DS.textSecondary)
            }
        } header: {
            sectionHeader("Reviewing")
        } footer: {
            sectionFooter("Stored in your collection and kept in sync across devices.")
        }
        .font(DS.Typography.body)
        .foregroundStyle(DS.textPrimary)
    }

    // MARK: - Data (import / export)

    private var dataSection: some View {
        Section {
            NavigationLink {
                ImportExportView(store: store)
            } label: {
                Label("Import & Export", systemImage: "tray.and.arrow.up.fill")
                    .font(DS.Typography.body)
                    .foregroundStyle(DS.textPrimary)
            }
            .accessibilityIdentifier("importExport")
        } header: {
            sectionHeader("Data")
        } footer: {
            sectionFooter("Import an .apkg/.colpkg, or export a deck or your whole collection to share or back up.")
        }
    }

    // MARK: - About

    private var aboutSection: some View {
        Section {
            DSStatRow("Version", value: appVersion)
            DSStatRow("Anki engine", value: engineBuildHash)
                .textSelection(.enabled)
        } header: {
            sectionHeader("About")
        }
    }

    // MARK: - Helpers

    private var themeBinding: Binding<AppTheme> {
        Binding(
            get: { AppTheme.from(rawValue: appThemeRaw) },
            set: { appThemeRaw = $0.rawValue }
        )
    }

    /// A `Bool` binding whose setter routes through the store (which persists the
    /// change in the engine and reloads the value), instead of mutating local
    /// state that the engine never sees.
    private func boolBinding(
        get: @escaping () -> Bool,
        set: @escaping (Bool) -> Void
    ) -> Binding<Bool> {
        Binding(get: get, set: set)
    }

    private var appVersion: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        if let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
           !build.isEmpty, build != short {
            return "\(short) (\(build))"
        }
        return short
    }

    private var engineBuildHash: String {
        store.buildHash.isEmpty ? Backend.buildHash() : store.buildHash
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(DS.Typography.caption.weight(.semibold))
            .foregroundStyle(DS.textSecondary)
    }

    private func sectionFooter(_ text: String) -> some View {
        Text(text)
            .font(DS.Typography.caption)
            .foregroundStyle(DS.textSecondary)
    }

    /// Seeds the picker from the persisted preference (once per appearance).
    private func loadServerState() {
        guard !serverLoaded else { return }
        serverLoaded = true
        let endpoint = store.preferredSyncServer
        if endpoint == nil || endpoint?.isEmpty == true {
            serverChoice = .ankiweb
        } else if endpoint!.normalizedURL == AnkiStore.mcatSyncServerURL.normalizedURL {
            serverChoice = .mcat
        } else {
            serverChoice = .other
            customServerURL = endpoint!
        }
    }

    /// Writes the current picker choice to the store's persisted preference.
    private func applyServer() {
        switch serverChoice {
        case .mcat:
            store.setPreferredSyncServer(AnkiStore.mcatSyncServerURL)
        case .ankiweb:
            store.setPreferredSyncServer(nil)
        case .other:
            let trimmed = customServerURL.trimmingCharacters(in: .whitespacesAndNewlines)
            store.setPreferredSyncServer(trimmed.isEmpty ? nil : trimmed)
        }
    }
}

/// Sync server presets offered in the Settings dropdown.
private enum ServerChoice: Hashable {
    case mcat
    case ankiweb
    case other
}

private extension String {
    /// Lowercased, trailing-slash-stripped form for comparing server URLs so
    /// that e.g. `https://host/` and `https://host` match the same preset.
    var normalizedURL: String {
        var s = trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }
}
