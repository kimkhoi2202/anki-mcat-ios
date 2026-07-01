import SwiftUI
import AnkiKit

/// Settings screen, cloning Anki's Preferences dialog (and AnkiDroid's settings)
/// as a native grouped `Form`. Engine-backed sections read/write the collection
/// `Preferences` message so they sync across devices; client-only sections use
/// `@AppStorage`/`UserDefaults`:
///
/// - **Account & Sync / Sync server / Syncing** — the synced account and
///   login/logout, the custom sync server, and the app-local auto-sync and
///   sync-media toggles (Anki's Preferences ▸ Syncing).
/// - **Appearance** — Theme + UI size (app-wide) and a full-screen reviewer
///   toggle (Anki's Appearance ▸ Distractions).
/// - **Reviewing** — engine-backed toggles from `Preferences.reviewing`.
/// - **Editing** — engine-backed paste/search prefs from `Preferences.editing`.
/// - **Backups** — engine-backed `Preferences.backups` limits + "Create backup
///   now".
/// - **About** — app version and the linked Anki engine build hash.
struct SettingsView: View {
    @ObservedObject var store: AnkiStore
    @AppStorage(AppTheme.storageKey) private var appThemeRaw = AppTheme.system.rawValue
    @AppStorage(UISize.storageKey) private var uiSizeRaw = UISize.system.rawValue
    @AppStorage(FullScreenReviewer.storageKey) private var fullScreenReviewer = false
    @State private var serverChoice: ServerChoice = .ankiweb
    @State private var customServerURL = ""
    /// Inline validation error for the custom ("Other") server URL, if any.
    @State private var serverError: String?
    /// Local draft for the "Default search text" field, committed to the engine
    /// on submit/disappear rather than on every keystroke (which would round-trip
    /// through the collection each character and fight the text cursor).
    @State private var defaultSearchTextDraft = ""

    // MARK: - Daily review reminder (app-local; AnkiDroid's review reminder)

    /// Whether the daily review reminder is on. Persisted app-locally and shared
    /// with the store (which reschedules with a fresh due count on background).
    @AppStorage(ReviewReminders.enabledKey) private var reminderEnabled = false
    /// The reminder's daily hour/minute (persisted app-locally).
    @AppStorage(ReviewReminders.hourKey) private var reminderHour = ReviewReminderSchedule.defaultHour
    @AppStorage(ReviewReminders.minuteKey) private var reminderMinute = ReviewReminderSchedule.defaultMinute
    /// Set when authorization was refused, so the section can point the user to
    /// iOS Settings instead of silently failing.
    @State private var reminderPermissionDenied = false
    /// Programmatic push of the Advanced screen (used by the automation hook so a
    /// screenshot can land directly on the maintenance tools).
    @State private var goAdvanced = false

    var body: some View {
        Form {
            accountSection
            serverSection
            syncSection
            notificationsSection
            appearanceSection
            schedulingSection
            reviewingSection
            autoAdvanceSection
            controlsSection
            editingSection
            backupsSection
            notetypesSection
            dataSection
            advancedSection
            aboutSection
        }
        .scrollContentBackground(.hidden)
        .background(DS.background.ignoresSafeArea())
        .tint(DS.accent)
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        // Programmatic route to Advanced for the screenshot/automation hook; the
        // Advanced row also pushes it via its own NavigationLink for normal use.
        .navigationDestination(isPresented: $goAdvanced) {
            AdvancedSettingsView(store: store)
        }
        .task {
            // Screenshot/automation hook: show the daily reminder enabled (toggle
            // + time visible) without going through the permission prompt.
            if ProcessInfo.processInfo.arguments.contains("-demoReviewReminder") {
                reminderEnabled = true
                reminderHour = 20
                reminderMinute = 0
            }
            store.loadPreferences()
            reconcileServer()
            defaultSearchTextDraft = store.editingPrefs.defaultSearchText
            await reconcileReminderAuthorization()
            // Screenshot/automation hook: jump straight to the Advanced screen.
            if ProcessInfo.processInfo.arguments.contains("-startInAdvanced")
                || ProcessInfo.processInfo.arguments.contains("-demoCheckDatabase")
                || ProcessInfo.processInfo.arguments.contains("-demoEmptyCards") {
                goAdvanced = true
            }
        }
        // Re-seed the picker when the login state or the in-use server changes
        // (e.g. logging out while on this screen, or a shard reassignment), so it
        // never diverges from the server `sync()` actually uses.
        .onChange(of: store.isLoggedIn) { _ in reconcileServer() }
        .onChange(of: store.activeSyncServer) { _ in reconcileServer() }
        // Keep the draft in step when the engine value changes from elsewhere
        // (e.g. a sync), unless the user is mid-edit with an unsaved change.
        .onChange(of: store.editingPrefs.defaultSearchText) { newValue in
            if newValue != defaultSearchTextDraft { defaultSearchTextDraft = newValue }
        }
        // Commit any pending search-text edit when leaving the screen.
        .onDisappear { commitDefaultSearchText() }
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

    // MARK: - Syncing (app-local)

    /// Sync behaviour toggles (Anki's Preferences ▸ Syncing). The engine
    /// `Preferences` message exposes neither, so they're stored on this device:
    /// auto-sync drives `sync()` on app open/close, and "Sync media" gates the
    /// media phase of every sync.
    private var syncSection: some View {
        Section {
            Toggle("Automatically sync on open/close", isOn: $store.autoSyncEnabled)
            Toggle("Synchronize audio and images too", isOn: $store.fetchMediaOnSync)
        } header: {
            sectionHeader("Syncing")
        } footer: {
            sectionFooter(
                store.isLoggedIn
                    ? "Auto-sync runs when you open or leave the app. Turn off media syncing to sync the collection only."
                    : "These apply once you log in. Turn off media syncing to sync the collection only."
            )
        }
        .font(DS.Typography.body)
        .foregroundStyle(DS.textPrimary)
    }

    // MARK: - Notifications (daily review reminder; app-local)

    /// A daily local-notification reminder to study, cloning AnkiDroid's review
    /// reminder. Enabling requests notification authorization; the time picker
    /// (re)schedules a repeating `UNCalendarNotificationTrigger`. Enable + time
    /// are app-local (`@AppStorage`); the store reschedules with a fresh due
    /// count when the app backgrounds so the body reads "You have N cards due".
    private var notificationsSection: some View {
        Section {
            Toggle("Daily review reminder", isOn: reminderToggleBinding)
                .accessibilityIdentifier("reviewReminderToggle")
            if reminderEnabled {
                DatePicker(
                    "Remind me at",
                    selection: reminderTimeBinding,
                    displayedComponents: .hourAndMinute
                )
                .accessibilityIdentifier("reviewReminderTime")
            }
            if reminderPermissionDenied {
                Text("Notifications are turned off for Anki Speedrun. Enable them in iOS Settings ▸ Notifications to get reminders.")
                    .font(DS.Typography.caption)
                    .foregroundStyle(DS.again)
            }
        } header: {
            sectionHeader("Notifications")
        } footer: {
            sectionFooter("Get a daily reminder to study at the time you choose. The reminder shows how many cards are due. Stored on this device.")
        }
        .font(DS.Typography.body)
        .foregroundStyle(DS.textPrimary)
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

            Picker(selection: uiSizeBinding) {
                ForEach(UISize.allCases) { size in
                    Text(size.label).tag(size)
                }
            } label: {
                Text("Interface size")
                    .font(DS.Typography.body)
                    .foregroundStyle(DS.textPrimary)
            }
            .pickerStyle(.menu)
            .tint(DS.textSecondary)

            Toggle("Full-screen reviewer", isOn: $fullScreenReviewer)
                .font(DS.Typography.body)
                .foregroundStyle(DS.textPrimary)
        } header: {
            sectionHeader("Appearance")
        } footer: {
            sectionFooter("“System” follows your device's light/dark appearance. Interface size scales the app's text. Full-screen review hides the status bar for a distraction-free session.")
        }
    }

    // MARK: - Scheduling (engine-backed)

    /// Anki's Preferences ▸ Scheduling. Engine-backed via `Preferences.scheduling`
    /// (the next-day rollover hour and the learn-ahead limit), so these sync
    /// across devices and affect the scheduler on every client.
    private var schedulingSection: some View {
        Section {
            if store.preferencesAvailable {
                Stepper(value: rolloverBinding, in: 0...23) {
                    HStack {
                        Text("Next day starts at")
                        Spacer()
                        Text(rolloverLabel(store.schedulingPrefs.rollover))
                            .foregroundStyle(DS.textSecondary)
                            .monospacedDigit()
                    }
                }
                Stepper(value: learnAheadBinding, in: 0...1440, step: 5) {
                    HStack {
                        Text("Learn ahead limit")
                        Spacer()
                        Text("\(store.schedulingPrefs.learnAheadMinutes) min")
                            .foregroundStyle(DS.textSecondary)
                            .monospacedDigit()
                    }
                }
            } else {
                Text("Scheduling preferences are unavailable.")
                    .font(DS.Typography.body)
                    .foregroundStyle(DS.textSecondary)
            }
        } header: {
            sectionHeader("Scheduling")
        } footer: {
            sectionFooter("“Next day starts at” sets the hour a new day begins for due cards. “Learn ahead limit” lets the scheduler show learning cards early when nothing else is due. Stored in your collection.")
        }
        .font(DS.Typography.body)
        .foregroundStyle(DS.textPrimary)
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
                Toggle("Interrupt current audio when answering", isOn: boolBinding(
                    get: { store.reviewingPrefs.interruptAudioWhenAnswering },
                    set: store.setInterruptAudioWhenAnswering
                ))
                Stepper(value: timeboxMinutesBinding, in: 0...600, step: 5) {
                    HStack {
                        Text("Timebox time limit")
                        Spacer()
                        Text(store.reviewingPrefs.timeLimitMinutes == 0
                             ? "Off"
                             : "\(store.reviewingPrefs.timeLimitMinutes) min")
                            .foregroundStyle(DS.textSecondary)
                            .monospacedDigit()
                    }
                }
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

    // MARK: - Auto Advance (session enable; timing lives in Deck Options)

    /// Anki's "Auto Advance". Only the session *enable* toggle is a client
    /// setting; the per-side seconds and the question/answer actions come from the
    /// current card's DECK CONFIG (edited in Deck Options ▸ Auto Advance), so the
    /// reviewer reads them per card from the engine — not from this screen.
    private var autoAdvanceSection: some View {
        Section {
            Toggle("Auto advance", isOn: $store.autoAdvanceEnabled)
        } header: {
            sectionHeader("Auto Advance")
        } footer: {
            sectionFooter(
                "When on, cards advance on their own using the timing and actions from each deck's options (Deck Options ▸ Auto Advance). Set a side's seconds to 0 there to disable it. The toggle is stored on this device."
            )
        }
        .font(DS.Typography.body)
        .foregroundStyle(DS.textPrimary)
    }

    // MARK: - Controls / Gestures

    /// Entry to the reviewer gesture settings — AnkiDroid keeps a "Controls"
    /// category for its configurable gestures; we mirror that with a row into the
    /// native gesture editor (tap zones, swipes, long-press, double-tap → action).
    private var controlsSection: some View {
        Section {
            NavigationLink {
                ControlsSettingsView(store: store)
            } label: {
                Label("Gestures", systemImage: "hand.tap")
                    .font(DS.Typography.body)
                    .foregroundStyle(DS.textPrimary)
            }
            .accessibilityIdentifier("controlsSettings")
        } header: {
            sectionHeader("Controls")
        } footer: {
            sectionFooter("Choose what tapping a card zone, swiping, long-pressing, or double-tapping does during review. Stored on this device.")
        }
    }

    // MARK: - Editing (engine-backed)

    /// Anki's Preferences ▸ Editing/Browsing tab. Engine-backed via
    /// `Preferences.editing`, so these sync across devices (even where this
    /// client doesn't yet act on every one, e.g. the desktop honours them when
    /// pasting/searching).
    private var editingSection: some View {
        Section {
            if store.preferencesAvailable {
                Toggle("Paste without shift key strips formatting", isOn: boolBinding(
                    get: { store.editingPrefs.pasteStripsFormatting },
                    set: store.setPasteStripsFormatting
                ))
                Toggle("Paste clipboard images as PNG", isOn: boolBinding(
                    get: { store.editingPrefs.pasteImagesAsPng },
                    set: store.setPasteImagesAsPng
                ))
                Toggle("When adding, default to current deck", isOn: boolBinding(
                    get: { store.editingPrefs.addingDefaultsToCurrentDeck },
                    set: store.setAddingDefaultsToCurrentDeck
                ))
                Toggle("Ignore accents in search (slower)", isOn: boolBinding(
                    get: { store.editingPrefs.ignoreAccentsInSearch },
                    set: store.setIgnoreAccentsInSearch
                ))
                Toggle("Render LaTeX", isOn: boolBinding(
                    get: { store.editingPrefs.renderLatex },
                    set: store.setRenderLatex
                ))
                HStack {
                    Text("Default search text")
                    Spacer()
                    TextField("e.g. deck:current", text: $defaultSearchTextDraft)
                        .multilineTextAlignment(.trailing)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .foregroundStyle(DS.textSecondary)
                        .frame(maxWidth: 180)
                        .onSubmit { commitDefaultSearchText() }
                }
            } else {
                Text("Editing preferences are unavailable.")
                    .font(DS.Typography.body)
                    .foregroundStyle(DS.textSecondary)
            }
        } header: {
            sectionHeader("Editing")
        } footer: {
            sectionFooter("Stored in your collection and kept in sync across devices. “When adding, default to current deck” off means the deck changes with the note type.")
        }
        .font(DS.Typography.body)
        .foregroundStyle(DS.textPrimary)
    }

    // MARK: - Backups (engine-backed)

    /// Anki's Preferences ▸ Backups. Engine-backed via `Preferences.backups`
    /// (how many daily/weekly/monthly snapshots to keep and the minimum interval
    /// between automatic ones), plus an immediate "Create backup now" action.
    private var backupsSection: some View {
        Section {
            if store.preferencesAvailable {
                Stepper(value: backupCountBinding(\.daily, store.setDailyBackupsToKeep), in: 0...999) {
                    countLabel("Daily backups to keep", store.backupLimits.daily)
                }
                Stepper(value: backupCountBinding(\.weekly, store.setWeeklyBackupsToKeep), in: 0...999) {
                    countLabel("Weekly backups to keep", store.backupLimits.weekly)
                }
                Stepper(value: backupCountBinding(\.monthly, store.setMonthlyBackupsToKeep), in: 0...999) {
                    countLabel("Monthly backups to keep", store.backupLimits.monthly)
                }
                Stepper(value: backupCountBinding(\.minimumIntervalMins, store.setMinutesBetweenBackups), in: 0...1440, step: 5) {
                    countLabel("Minutes between backups", store.backupLimits.minimumIntervalMins)
                }
            }
            Button {
                Task { await store.createBackupNow() }
            } label: {
                HStack {
                    Label("Create backup now", systemImage: "externaldrive.badge.timemachine")
                        .foregroundStyle(DS.accent)
                    if store.backupInProgress {
                        Spacer()
                        ProgressView()
                    }
                }
            }
            .disabled(store.backupInProgress)
            .accessibilityIdentifier("createBackupNow")
            if let message = store.lastBackupMessage {
                Text(message)
                    .font(DS.Typography.caption)
                    .foregroundStyle(DS.textSecondary)
            }
        } header: {
            sectionHeader("Backups")
        } footer: {
            sectionFooter("Anki periodically backs up your collection. Backups are kept on this device; restore one via Import & Export.")
        }
        .font(DS.Typography.body)
        .foregroundStyle(DS.textPrimary)
    }

    /// A "Title …… N" row used by the backup-limit steppers.
    private func countLabel(_ title: String, _ count: Int) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text("\(count)")
                .foregroundStyle(DS.textSecondary)
                .monospacedDigit()
        }
    }

    // MARK: - Note types

    /// Entry to "Manage note types" — AnkiDroid keeps note-type management in its
    /// settings; we mirror that with a row into the native manager (add / clone /
    /// rename / delete note types, edit fields, edit card templates).
    private var notetypesSection: some View {
        Section {
            NavigationLink {
                ManageNotetypesView(store: store)
            } label: {
                Label("Manage note types", systemImage: "square.stack.3d.up")
                    .font(DS.Typography.body)
                    .foregroundStyle(DS.textPrimary)
            }
            .accessibilityIdentifier("manageNotetypes")
        } header: {
            sectionHeader("Note types")
        } footer: {
            sectionFooter("Add, clone, rename, or delete note types, and edit their fields and card templates.")
        }
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

    // MARK: - Advanced (maintenance tools)

    /// Entry to the Advanced screen — AnkiDroid's "Advanced" settings category
    /// with the database-maintenance tools (check database, empty cards, force
    /// full sync, restore from backup).
    private var advancedSection: some View {
        Section {
            NavigationLink {
                AdvancedSettingsView(store: store)
            } label: {
                Label("Advanced", systemImage: "wrench.and.screwdriver")
                    .font(DS.Typography.body)
                    .foregroundStyle(DS.textPrimary)
            }
            .accessibilityIdentifier("advancedSettings")
        } header: {
            sectionHeader("Advanced")
        } footer: {
            sectionFooter("Database maintenance: check database, find empty cards, force a full sync, or restore from a backup.")
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

    private var uiSizeBinding: Binding<UISize> {
        Binding(
            get: { UISize.from(rawValue: uiSizeRaw) },
            set: { uiSizeRaw = $0.rawValue }
        )
    }

    /// Commits the "Default search text" draft to the engine if it changed,
    /// avoiding a redundant write (and its preferences reload) when unchanged.
    private func commitDefaultSearchText() {
        let trimmed = defaultSearchTextDraft
        if trimmed != store.editingPrefs.defaultSearchText {
            store.setDefaultSearchText(trimmed)
        }
    }

    /// An `Int` binding for a backup-limit stepper: reads the named field from the
    /// store's snapshot and routes writes through the given engine-backed setter.
    private func backupCountBinding(
        _ keyPath: KeyPath<BackupLimitsPrefs, Int>,
        _ set: @escaping (Int) -> Void
    ) -> Binding<Int> {
        Binding(
            get: { store.backupLimits[keyPath: keyPath] },
            set: { set($0) }
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

    // MARK: Scheduling / Reviewing stepper bindings

    private var rolloverBinding: Binding<Int> {
        Binding(get: { store.schedulingPrefs.rollover }, set: { store.setNextDayStartsAt($0) })
    }

    private var learnAheadBinding: Binding<Int> {
        Binding(get: { store.schedulingPrefs.learnAheadMinutes }, set: { store.setLearnAheadMinutes($0) })
    }

    private var timeboxMinutesBinding: Binding<Int> {
        Binding(get: { store.reviewingPrefs.timeLimitMinutes }, set: { store.setTimeboxMinutes($0) })
    }

    /// Formats a rollover hour (0–23) as a localized time-of-day, e.g. "4 AM".
    private func rolloverLabel(_ hour: Int) -> String {
        var components = DateComponents()
        components.hour = hour
        components.minute = 0
        if let date = Calendar.current.date(from: components) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        return "\(hour):00"
    }

    // MARK: Review-reminder bindings & authorization

    /// Toggling on requests notification authorization and schedules the daily
    /// reminder on success; on denial it reverts the toggle and shows the hint.
    /// Toggling off cancels any pending reminder. All notification-center work is
    /// crash-proofed inside the manager.
    private var reminderToggleBinding: Binding<Bool> {
        Binding(
            get: { reminderEnabled },
            set: { newValue in
                if newValue {
                    Task {
                        let granted = await store.reviewReminders.requestAuthorization()
                        if granted {
                            reminderEnabled = true
                            reminderPermissionDenied = false
                            await store.reviewReminders.schedule(
                                hour: reminderHour, minute: reminderMinute,
                                dueCount: store.totalDueForReminder
                            )
                        } else {
                            reminderEnabled = false
                            reminderPermissionDenied = true
                        }
                    }
                } else {
                    reminderEnabled = false
                    reminderPermissionDenied = false
                    store.reviewReminders.cancel()
                }
            }
        )
    }

    /// Binds the time picker to the stored hour/minute, rescheduling the reminder
    /// (when enabled) whenever the chosen time changes.
    private var reminderTimeBinding: Binding<Date> {
        Binding(
            get: {
                Calendar.current.date(
                    from: DateComponents(hour: reminderHour, minute: reminderMinute)
                ) ?? Date()
            },
            set: { newDate in
                let components = Calendar.current.dateComponents([.hour, .minute], from: newDate)
                reminderHour = components.hour ?? ReviewReminderSchedule.defaultHour
                reminderMinute = components.minute ?? ReviewReminderSchedule.defaultMinute
                if reminderEnabled {
                    Task {
                        await store.reviewReminders.schedule(
                            hour: reminderHour, minute: reminderMinute,
                            dueCount: store.totalDueForReminder
                        )
                    }
                }
            }
        )
    }

    /// On appear, reconcile the toggle with the system authorization status: if
    /// the user revoked permission in iOS Settings, turn the reminder off and
    /// show the hint; if still authorized, make sure a reminder is scheduled.
    private func reconcileReminderAuthorization() async {
        guard reminderEnabled else { return }
        switch await store.reviewReminders.authorizationStatus() {
        case .authorized, .provisional, .ephemeral:
            reminderPermissionDenied = false
            await store.reviewReminders.schedule(
                hour: reminderHour, minute: reminderMinute,
                dueCount: store.totalDueForReminder
            )
        case .denied:
            reminderEnabled = false
            reminderPermissionDenied = true
            store.reviewReminders.cancel()
        case .notDetermined:
            break
        @unknown default:
            break
        }
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
    case ankiweb
    case other

    /// Classifies a stored endpoint into a picker choice. A nil/empty endpoint or
    /// any AnkiWeb host — `ankiweb.net` or a `*.ankiweb.net` shard such as
    /// `sync.ankiweb.net` / `sync-xxx.ankiweb.net` — is AnkiWeb; anything else is
    /// a custom ("Other") server.
    static func classify(_ endpoint: String?) -> ServerChoice {
        guard let endpoint,
              !endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return .ankiweb }
        if endpoint.isAnkiWebHost { return .ankiweb }
        return .other
    }
}

private extension String {
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
