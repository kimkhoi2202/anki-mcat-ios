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
    /// Inline validation error for the custom ("Other") server URL, if any.
    @State private var serverError: String?

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
            reconcileServer()
        }
        // Re-seed the picker when the login state or the in-use server changes
        // (e.g. logging out while on this screen, or a shard reassignment), so it
        // never diverges from the server `sync()` actually uses.
        .onChange(of: store.isLoggedIn) { _ in reconcileServer() }
        .onChange(of: store.activeSyncServer) { _ in reconcileServer() }
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

    /// Sync-server picker. AnkiDroid keeps the custom sync server in Preferences
    /// (not on the login screen); we mirror that here. While logged out the
    /// choice is written to `store.preferredSyncServer` (used by `login` as the
    /// endpoint). While logged in the picker is read-only and mirrors the server
    /// actually in use (`store.activeSyncServer`), since AnkiDroid requires
    /// logging out to change the sync server.
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
            .disabled(store.isLoggedIn)
            .onChange(of: serverChoice) { _ in applyServer() }

            if serverChoice == .other {
                TextField("https://my-sync-server.example.com/", text: $customServerURL)
                    .textContentType(.URL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(DS.Typography.body)
                    .foregroundStyle(DS.textPrimary)
                    .disabled(store.isLoggedIn)
                    .onChange(of: customServerURL) { _ in applyServer() }

                if let serverError {
                    Text(serverError)
                        .font(DS.Typography.caption)
                        .foregroundStyle(DS.again)
                        .accessibilityLabel("Error: \(serverError)")
                }
            }
        } header: {
            sectionHeader("Sync server")
        } footer: {
            sectionFooter(
                store.isLoggedIn
                    ? "To switch servers, log out and log in again."
                    : "Used when you log in to sync."
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

    /// Reconciles the picker with the store. While logged in it mirrors the
    /// server actually in use (`activeSyncServer`, which AnkiWeb may set to an
    /// assigned shard) and is read-only; while logged out it shows the next-login
    /// choice (`preferredSyncServer`) and is editable. Any AnkiWeb host —
    /// including `*.ankiweb.net` shards — classifies as AnkiWeb, so a shard never
    /// masquerades as a custom ("Other") server.
    private func reconcileServer() {
        let endpoint = store.isLoggedIn ? store.activeSyncServer : store.preferredSyncServer
        let choice = ServerChoice.classify(endpoint)
        serverChoice = choice
        customServerURL = (choice == .other) ? (endpoint ?? "") : ""
        serverError = nil
    }

    /// Writes the current picker choice to the store's persisted next-login
    /// preference. No-op while logged in (the active server is fixed until
    /// logout). For "Other", validates the URL and refuses to apply — without
    /// silently falling back to AnkiWeb — when it is empty or malformed,
    /// surfacing an inline error instead.
    private func applyServer() {
        guard !store.isLoggedIn else { return }
        switch serverChoice {
        case .mcat:
            serverError = nil
            store.setPreferredSyncServer(AnkiStore.mcatSyncServerURL)
        case .ankiweb:
            serverError = nil
            store.setPreferredSyncServer(nil)
        case .other:
            let trimmed = customServerURL.trimmingCharacters(in: .whitespacesAndNewlines)
            if let error = Self.customServerError(trimmed) {
                serverError = error
            } else {
                serverError = nil
                store.setPreferredSyncServer(trimmed)
            }
        }
    }

    /// Validates a custom sync server URL, returning an inline error message or
    /// nil when acceptable (a non-empty `http`/`https` URL with a host). Keeps an
    /// invalid value from being stored unvalidated and only failing later in
    /// `syncLogin`.
    private static func customServerError(_ urlString: String) -> String? {
        if urlString.isEmpty { return "Enter a server URL." }
        guard let components = URLComponents(string: urlString),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host, !host.isEmpty
        else {
            return "Enter a valid http:// or https:// URL."
        }
        return nil
    }
}

/// Sync server presets offered in the Settings dropdown.
private enum ServerChoice: Hashable {
    case mcat
    case ankiweb
    case other

    /// Classifies a stored endpoint into a picker choice. A nil/empty endpoint or
    /// any AnkiWeb host — `ankiweb.net` or a `*.ankiweb.net` shard such as
    /// `sync.ankiweb.net` / `sync-xxx.ankiweb.net` — is AnkiWeb; the MCAT preset
    /// URL is MCAT; anything else is a custom ("Other") server.
    static func classify(_ endpoint: String?) -> ServerChoice {
        guard let endpoint,
              !endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return .ankiweb }
        if endpoint.normalizedURL == AnkiStore.mcatSyncServerURL.normalizedURL { return .mcat }
        if endpoint.isAnkiWebHost { return .ankiweb }
        return .other
    }
}

private extension String {
    /// Lowercased, trailing-slash-stripped form for comparing server URLs so
    /// that e.g. `https://host/` and `https://host` match the same preset.
    var normalizedURL: String {
        var s = trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }

    /// Whether this endpoint points at AnkiWeb — the apex `ankiweb.net` or any
    /// `*.ankiweb.net` shard (e.g. `sync.ankiweb.net`, `sync-xxx.ankiweb.net`) —
    /// so a server-assigned shard isn't misclassified as a custom server.
    var isAnkiWebHost: Bool {
        guard let host = URLComponents(
            string: trimmingCharacters(in: .whitespacesAndNewlines)
        )?.host?.lowercased() else { return false }
        return host == "ankiweb.net" || host.hasSuffix(".ankiweb.net")
    }
}
