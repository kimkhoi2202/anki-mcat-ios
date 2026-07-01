import Foundation
import AnkiKit
import WidgetKit
#if canImport(UIKit)
import UIKit
#endif

@MainActor
final class AnkiStore: ObservableObject {
    @Published var buildHash = ""
    @Published var status = "Starting…"
    /// Decks shown on the Home screen, flattened from the backend deck tree
    /// with per-deck new/learning/review counts.
    @Published var decks: [DeckTreeEntry] = []
    /// The deck most recently selected for study (defaults to the Default deck,
    /// which always has id 1). Used as the default target when adding a note,
    /// mirroring how AnkiDroid's NoteEditor defaults to the current deck.
    @Published var currentDeckID: Int64 = 1

    /// True while an *exclusive* backend operation is in flight — import, export,
    /// or a full-sync collection replace. These run as several FFI calls with the
    /// Rust mutex released between them (the close→import→reopen / replace window),
    /// during which another `@MainActor` backend call (a deck tap, add note, rate,
    /// or a web-page `/_anki` call) could hit a *closed* collection and error, or
    /// block on the mutex. The UI observes this to disable backend-touching
    /// controls for the operation's duration, mirroring how AnkiDroid serializes
    /// these behind its collection lock. Set only via `runExclusive`.
    @Published private(set) var isBackendBusy = false

    @Published var currentQuestion = ""
    @Published var currentAnswer = ""
    /// The current card's notetype CSS, injected into the reviewer WebView.
    @Published var currentCSS = ""
    /// Template ordinal of the current card (drives the `cardN` body class).
    @Published var currentOrdinal = 0
    /// Projected interval labels for the four answer buttons, in order
    /// `[again, hard, good, easy]`. Empty until a card is loaded.
    @Published var currentIntervals: [String] = []
    @Published var showingAnswer = false
    @Published var reviewDone = false

    /// Remaining new / learning / review counts for the deck being studied, taken
    /// from the scheduler queue (`QueuedCards.newCount`/`learningCount`/
    /// `reviewCount`). Shown during review when `showRemainingDueCounts` is on,
    /// mirroring AnkiDroid's colored `new+learn+review` count in the reviewer.
    @Published var newCount = 0
    @Published var learningCount = 0
    @Published var reviewCount = 0

    /// Current card's flag color (0 = none, 1...7 = red/orange/green/blue/pink/
    /// turquoise/purple). Drives the on-card flag indicator and the menu's
    /// current-flag checkmark, updated in place by the flag action.
    @Published var currentFlag = 0
    /// Whether the current card's note is marked (carries the `marked` tag).
    /// Drives the on-card star indicator and the Mark/Unmark menu item.
    @Published var isMarked = false
    /// Legacy reload token (no longer bumped now that audio plays natively via
    /// `CardAudioPlayer`); kept so the card WebView's `reloadToken` input stays
    /// wired without behavior change.
    @Published var replayToken = 0

    /// A card's type-in-the-answer target: the field to compare against and
    /// whether the diff treats combining characters as separate (Anki's `nc`
    /// variant sets `combining = false`).
    struct TypeAnswerField: Equatable, Sendable {
        let fieldName: String
        let combining: Bool
    }

    /// The current card's type-in-the-answer field, if its template uses
    /// `{{type:Field}}`; drives the native answer input and the back-side diff.
    @Published var typeAnswer: TypeAnswerField?
    /// The user's typed answer for a `{{type:}}` card.
    @Published var typedAnswer: String = ""

    /// Whether the backend has an action to undo (drives the Undo control).
    @Published var canUndo = false
    /// Localized name of the next undoable action (e.g. "Answer Card").
    @Published var undoName = ""

    // MARK: - Sync state

    /// Whether a sync account (host key) is stored in the Keychain.
    @Published var isLoggedIn = false
    /// The logged-in account name, for display.
    @Published var syncUsername = ""
    /// Drives presentation of the login sheet.
    @Published var showLogin = false
    /// Last login error message, shown in the login sheet.
    @Published var loginErrorMessage: String?
    /// Current sync phase, driving the Home progress/result banner.
    @Published var syncPhase: SyncPhase = .idle
    /// Drives the full-sync conflict dialog (clone of AnkiDroid's
    /// `DIALOG_SYNC_CONFLICT_RESOLUTION`): the collections diverged and the user
    /// must choose to upload (keep this device) or download (keep the server).
    @Published var pendingConflict = false

    /// The sync server the user has chosen for the *next* login (nil = default
    /// AnkiWeb), edited on the Settings screen while logged out. Mirrors
    /// AnkiDroid's custom sync server preference (read by `getEndpoint()`);
    /// persisted in UserDefaults so it survives launches and logout. It is the
    /// user's intent only — never overwritten by a server-assigned shard, which
    /// lives in `activeSyncServer`.
    @Published private(set) var preferredSyncServer: String?

    /// The sync server actually in use while logged in, taken from the stored
    /// credentials' endpoint (which AnkiWeb may set to an assigned shard, e.g.
    /// `sync.ankiweb.net`); nil = AnkiWeb default. Only meaningful when
    /// `isLoggedIn`. `sync()` uses `creds.endpoint`, so this is what the Settings
    /// screen shows (read-only) to avoid diverging from the server in use.
    @Published private(set) var activeSyncServer: String?

    private static let preferredServerKey = "preferredSyncServerEndpoint"
    /// Wall-clock cap on the media-sync poll loop, so a stuck server-side media
    /// sync can't spin the banner (and keep the Sync button disabled) forever.
    /// Generous enough for a large first media download; on timeout media is
    /// reported as a non-fatal error and the collection sync still succeeds.
    private static let mediaSyncTimeout: TimeInterval = 300

    // MARK: - Preferences state (engine-backed)

    /// Scheduling preferences from the engine `Preferences.scheduling` sub-message
    /// — Anki's Preferences ▸ Scheduling (next-day rollover hour, learn-ahead
    /// limit). Collection prefs, so they sync across devices.
    @Published var schedulingPrefs = SchedulingPrefs()
    /// Reviewing preferences read from the engine `Preferences` message, shown as
    /// toggles on the Settings screen. Cloned from AnkiDroid's Appearance/Study
    /// settings, which read/write the same collection prefs.
    @Published var reviewingPrefs = ReviewingPrefs()
    /// Editing preferences from the engine `Preferences.editing` sub-message —
    /// Anki's Preferences ▸ Editing/Browsing tab (paste behaviour, search). These
    /// are collection prefs, so they sync across devices.
    @Published var editingPrefs = EditingPrefs()
    /// Backup limits from the engine `Preferences.backups` sub-message — Anki's
    /// Preferences ▸ Backups (how many daily/weekly/monthly backups to keep, and
    /// the minimum interval between automatic backups).
    @Published var backupLimits = BackupLimitsPrefs()
    /// Whether the engine `Preferences` were successfully loaded (drives whether
    /// the Settings screen shows the engine-backed Reviewing/Editing/Backups
    /// rows). Loaded together from a single `getPreferences()`.
    @Published private(set) var preferencesAvailable = false

    /// True while a manual "Create backup now" snapshot is being written, so the
    /// Settings row can show progress and disable itself.
    @Published private(set) var backupInProgress = false
    /// Outcome of the most recent manual backup, shown transiently in Settings.
    @Published var lastBackupMessage: String?

    // MARK: - Notifications (daily review reminder)

    /// Schedules the daily review-reminder local notification (AnkiDroid's review
    /// reminder). The enable flag and time live in `UserDefaults` (edited on the
    /// Settings screen); the store reschedules with a fresh due count when the
    /// app backgrounds, so the "You have N cards due" body stays current.
    let reviewReminders = ReviewReminders()

    // MARK: - Sync settings (app-local)
    //
    // Anki's Preferences ▸ Syncing has "Automatically sync on profile
    // open/close" and "Synchronize audio and images too". The engine
    // `Preferences` message exposes *neither* (they're client behaviour, not
    // collection data), so — like AnkiDroid, which keeps them in its own
    // SharedPreferences — they live here in `UserDefaults` and are honoured by
    // the app's sync flow rather than round-tripping through the collection.

    /// "Automatically sync on profile open/close": when on (and logged in), the
    /// app syncs on launch and when backgrounded. Default on, to match Anki.
    @Published var autoSyncEnabled = true {
        didSet { UserDefaults.standard.set(autoSyncEnabled, forKey: Self.autoSyncKey) }
    }
    /// "Synchronize audio and images too": when off, syncs skip the media phase
    /// (collection only). Default on, matching Anki and the prior behaviour.
    @Published var fetchMediaOnSync = true {
        didSet { UserDefaults.standard.set(fetchMediaOnSync, forKey: Self.fetchMediaKey) }
    }
    private static let autoSyncKey = "autoSyncEnabled"
    private static let fetchMediaKey = "fetchMediaOnSync"

    // MARK: - Auto-advance state (app-local enable + engine-sourced timing)
    //
    // Anki's "Auto Advance": after the question shows for N seconds do the deck's
    // question action (default: reveal the answer), and after the answer shows for
    // M seconds do the deck's answer action (default: bury the card). The *timing*
    // (`seconds_to_show_question`/`seconds_to_show_answer`) and the *actions*
    // (`questionAction`/`answerAction`) live in the DECK CONFIG, not the global
    // `Reviewing` preferences — so they're read per card from the engine (see
    // `autoAdvanceConfigForCurrentCard`), edited by the user in Deck Options.
    //
    // Only the *session enable* toggle is client behaviour, so it (alone) is
    // persisted app-locally. Default off, so review never auto-advances unless the
    // user explicitly enables it.

    /// Whether auto-advance is enabled (the reviewer/Settings toggle). Persisted;
    /// toggling it cancels or (re)schedules the timer for the current side. The
    /// per-side seconds and actions come from the current card's deck config, not
    /// from here.
    @Published var autoAdvanceEnabled = false {
        didSet {
            UserDefaults.standard.set(autoAdvanceEnabled, forKey: Self.autoAdvanceEnabledKey)
            if autoAdvanceEnabled { scheduleAutoAdvanceForCurrentSide() } else { cancelAutoAdvance() }
        }
    }

    /// A brief, non-grading notice shown when a side's timer elapses and the deck
    /// config's action for that side is "show reminder" (Anki shows a tooltip).
    /// The reviewer renders it as a transient toast; it clears itself after a
    /// short delay (and on card change / leaving the reviewer).
    @Published var autoAdvanceReminder: String?

    private static let autoAdvanceEnabledKey = "autoAdvanceEnabled"

    // MARK: - Gesture configuration (app-local)
    //
    // AnkiDroid's configurable reviewer gestures (tap zones, swipes, long-press,
    // double-tap → a `ViewerCommand`). Like AnkiDroid, these are client
    // behaviour, not collection data, so the whole `GestureConfig` is persisted
    // app-locally as JSON in `UserDefaults`. The reviewer reads `gestureConfig`
    // to dispatch gestures; the Controls settings screen edits it. The model
    // (defaults, JSON round-trip, tap-zone partition) lives in `AnkiKit` so it's
    // unit-tested there.

    /// The gesture → action mapping used by the reviewer. Defaults reproduce the
    /// app's prior reviewer behavior (see `GestureConfig.defaults`). Any change
    /// (from the settings screen) persists immediately.
    @Published var gestureConfig = GestureConfig.defaults {
        didSet {
            guard gestureConfig != oldValue else { return }
            persistGestureConfig()
        }
    }
    private static let gestureConfigKey = "gestureConfig"

    /// Resets every gesture binding to the shipped defaults (the settings
    /// screen's "Reset to defaults"). Persisted via the `didSet` above.
    func resetGestureConfig() {
        gestureConfig = .defaults
    }

    /// Writes the current gesture config to `UserDefaults` as JSON.
    private func persistGestureConfig() {
        guard let data = try? gestureConfig.jsonData() else { return }
        UserDefaults.standard.set(data, forKey: Self.gestureConfigKey)
    }

    /// Loads the persisted gesture config from `UserDefaults` (defaults when
    /// absent/corrupt). Read once at boot; the published setter persists changes.
    private func loadGesturePrefs() {
        let data = UserDefaults.standard.data(forKey: Self.gestureConfigKey)
        gestureConfig = GestureConfig.from(jsonData: data)
    }

    // MARK: - Whiteboard (drawing overlay in the reviewer)

    /// Whether the reviewer's whiteboard drawing overlay is shown. When on, the
    /// PencilKit canvas captures drawing over the card (the on-screen reviewer
    /// controls stay usable); when off, the card behaves normally. Persisted so
    /// the toggle is remembered across reviewer sessions, matching AnkiDroid.
    @Published var whiteboardVisible = false {
        didSet {
            guard whiteboardVisible != oldValue else { return }
            UserDefaults.standard.set(whiteboardVisible, forKey: Self.whiteboardVisibleKey)
        }
    }
    private static let whiteboardVisibleKey = "whiteboardVisible"

    /// Toggles the whiteboard overlay — the reviewer hook for the
    /// `toggleWhiteboard` gesture command and the on-screen toggle button.
    func toggleWhiteboard() {
        whiteboardVisible.toggle()
    }

    /// Loads the persisted whiteboard visibility at boot (default off).
    private func loadWhiteboardPrefs() {
        whiteboardVisible = UserDefaults.standard.bool(forKey: Self.whiteboardVisibleKey)
    }

    /// Pending auto-advance timer (the deck's question/answer action); cancelled
    /// on any manual interaction, side/card change, overlay, or leaving the
    /// reviewer.
    private var autoAdvanceTask: Task<Void, Never>?
    /// Auto-dismiss timer for `autoAdvanceReminder` (the "time elapsed" notice).
    private var autoAdvanceReminderTask: Task<Void, Never>?
    /// True only while the reviewer screen is on top, so a timer never fires after
    /// the user has navigated away (set by the reviewer's appear/disappear).
    private var reviewerActive = false
    /// True while a menu/sheet/prompt is over the reviewer, so auto-advance pauses
    /// instead of grading behind a dialog (driven by the reviewer view).
    private var autoAdvancePaused = false
    /// Auto-advance settings resolved from the current card's deck config; `nil`
    /// until a card is presented or when the config can't be read. Recomputed per
    /// card so timing/actions always reflect the deck the card belongs to.
    private var currentAutoAdvanceConfig: AutoAdvanceConfig?
    /// Per-deck cache of resolved auto-advance settings, so a session doesn't
    /// refetch the deck config for every card. Cleared when a reviewer session
    /// ends so re-entering picks up any Deck Options edits made in between.
    private var autoAdvanceConfigByDeck: [Int64: AutoAdvanceConfig] = [:]

    /// Auth + media USN captured when a full-sync conflict is raised, reused once
    /// the user picks a resolution.
    private var pendingConflictAuth: Anki_Sync_SyncAuth?
    private var pendingConflictMediaUsn: Int32 = 0
    /// Last media-sync error message, if any. Media sync is best-effort (as in
    /// AnkiDroid, where it runs in a background worker), so a media failure is
    /// noted alongside an otherwise-successful collection sync rather than
    /// failing the whole sync.
    private var lastMediaError: String?

    private var backend: Backend?
    private var currentCard: Anki_Scheduler_QueuedCards.QueuedCard?
    private var cardShownAt = Date()

    /// Monotonic token guarding `decks` against out-of-order deck-tree fetches.
    /// `refreshDecks()` now reads the tree off the main actor, so two rapid
    /// refreshes can finish in either order; only the most recent request is
    /// allowed to publish, so a slow earlier fetch can't clobber a newer one.
    private var decksRefreshToken = 0

    /// The backend handle for the embedded Anki web pages (Statistics, Card Info,
    /// Deck Options), which call it off the main actor through the `/_anki` bridge.
    /// `Backend` is `Sendable` and internally thread-safe (mutex-guarded).
    var sharedBackend: Backend? { backend }

    /// The current card's audio (sound/video filenames) per side, autoplayed on
    /// front/back and replayed by "Replay audio". Cloned from Anki, which plays
    /// the question side on show and the answer side on reveal.
    private var currentQuestionAudio: [CardAudio] = []
    private var currentAnswerAudio: [CardAudio] = []
    /// The current card's answer HTML exactly as rendered, with any `[[type:…]]`
    /// placeholder still intact. `currentAnswer` is *derived* from this on every
    /// reveal — substituting the type-in diff, or stripping the placeholder —
    /// rather than mutating it in place, so re-revealing after a flip-back or an
    /// in-place note edit recomputes correctly instead of consuming the
    /// placeholder once.
    private var pristineAnswer = ""
    private let cardAudioPlayer = CardAudioPlayer()

    /// The card currently shown in the reviewer, if any — used to open Card Info
    /// from the reviewer's toolbar.
    var currentCardID: Int64? { currentCard?.card.id }

    /// The note behind the current card, if any — used by the reviewer's note
    /// actions (Edit / Mark / Bury note / Suspend note / Delete note).
    var currentNoteID: Int64? { currentCard?.card.noteID }

    /// Directory holding the collection and its media (the app's Documents).
    private var documentsURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
    /// The collection database file (`collection.anki2`).
    private var collectionURL: URL { documentsURL.appendingPathComponent("collection.anki2") }
    /// The media database file (`collection.media.db2`).
    private var mediaDBURL: URL { documentsURL.appendingPathComponent("collection.media.db2") }
    /// Media folder backing `<img src="...">` resolution in the reviewer.
    /// Matches the folder passed to `openCollection` in `boot()`.
    var mediaFolderURL: URL {
        documentsURL.appendingPathComponent("collection.media")
    }

    /// Boots the engine: open the collection, seed demo cards on first launch,
    /// and load derived UI state. `async` so `HomeView`'s `.task` doesn't block
    /// the first frame — the heavy backend steps (creating the backend, the
    /// disk-I/O `openCollection`, and the first-launch demo seeding) run off the
    /// main actor, with `@Published` state assigned back on the main actor.
    func boot() async {
        guard backend == nil else { return }
        buildHash = Backend.buildHash()
        // Capture the on-disk paths on the main actor (they read FileManager
        // URLs) so the detached open can run with just these `Sendable` values.
        let mediaFolder = mediaFolderURL
        let colPath = collectionURL.path
        let mediaDBPath = mediaDBURL.path
        // Open the engine in the user's language — Anki's own translation catalog
        // (the same one Desktop and AnkiDroid use) — so the web screens (stats,
        // deck options, card info) and every engine-sourced string localize like
        // AnkiDroid instead of being pinned to English. An optional in-app
        // override (Settings ▸ Language) wins over the device's languages; "en" is
        // always the final fallback (Anki's source language). Read here on the
        // main actor and captured as a Sendable [String] for the detached open.
        let backendLangs = Self.preferredBackendLangs()
        let newBackend: Backend
        do {
            // Create + open the collection off the main actor; the handle stays
            // local until the open succeeds.
            newBackend = try await runDetached {
                let backend = try Backend(preferredLangs: backendLangs)
                try Self.openDefaultCollection(
                    backend, mediaFolder: mediaFolder, colPath: colPath, mediaDBPath: mediaDBPath
                )
                return backend
            }
        } catch {
            // A failed open (corrupt/locked db, schema too new, disk full) must
            // not leave a non-nil handle behind, or the `backend == nil` guard
            // would block every retry — even across relaunches. Keep it nil so
            // the next boot() can try again.
            self.backend = nil
            status = "Couldn't open the collection: \(error)"
            return
        }
        // Retain the handle only now that the collection is actually open.
        self.backend = newBackend
        // Make the engine's translation catalog available to the native UI so
        // `Loc.tr(...)` resolves strings in the collection's language.
        Loc.configure(backend: newBackend)
        // Seeding demo cards is best-effort (and runs note inserts, so it's
        // offloaded too); a hiccup must not brick a good open.
        try? await runDetached { try Self.seedIfNeeded(newBackend) }
        // Initial deck load is awaited (off-main) so the first render and any
        // launch hooks see a populated deck list.
        await reloadDeckTree()
        refreshUndo()
        loadPreferredSyncServer()
        loadLoginState()
        loadPreferences()
        loadAutoAdvancePrefs()
        loadWhiteboardPrefs()
        loadGesturePrefs()
        loadSyncPrefs()
        status = "Engine OK"
    }

    /// The engine's preferred-language list, in priority order: an in-app override
    /// (Settings ▸ Language, the `appLanguageOverride` default) when set to a
    /// concrete language, otherwise the device's preferred languages — always
    /// ending in English (Anki's source language) as the final fallback. Shared by
    /// `boot()` and `reopenForLanguageChange()` so both open the collection with an
    /// identical language resolution. Call on the main actor and capture the
    /// resulting `[String]` (Sendable) for the detached open.
    private static func preferredBackendLangs() -> [String] {
        var langs: [String]
        if let override = UserDefaults.standard.string(forKey: "appLanguageOverride"),
           override != "system", !override.isEmpty {
            langs = [override]
        } else {
            langs = Locale.preferredLanguages
        }
        if !langs.contains("en") { langs.append("en") }
        return langs
    }

    /// Re-opens the collection in a freshly-created backend so a Language change
    /// (Settings ▸ Language) takes effect immediately. The engine picks its
    /// translation catalog at `Backend.init(preferredLangs:)` — the catalog that
    /// `Loc.tr(...)` and the bundled web screens read — so switching languages
    /// means closing the current collection and re-opening it in a new backend
    /// built with the new preferred languages. Mirrors `boot()`'s open logic (same
    /// `preferredBackendLangs()`, same `openDefaultCollection`) and, like the other
    /// close→reopen paths, runs under `runExclusive` with the blocking FFI work on
    /// a detached task so no concurrent `@MainActor` backend call hits a closed
    /// collection.
    func reopenForLanguageChange() async {
        guard let oldBackend = backend else { return }
        let mediaFolder = mediaFolderURL
        let colPath = collectionURL.path
        let mediaDBPath = mediaDBURL.path
        let backendLangs = Self.preferredBackendLangs()
        let newBackend: Backend
        do {
            newBackend = try await runExclusive {
                try await runDetached {
                    // Close the current collection first so the new backend can
                    // open the same db file without contending for the SQLite lock;
                    // tolerate an already-closed handle.
                    _ = try? oldBackend.closeCollection()
                    let backend = try Backend(preferredLangs: backendLangs)
                    do {
                        try Self.openDefaultCollection(
                            backend, mediaFolder: mediaFolder,
                            colPath: colPath, mediaDBPath: mediaDBPath
                        )
                    } catch {
                        // Re-opening in the new backend failed; restore the old
                        // one so the app isn't left with a closed collection.
                        _ = try? oldBackend.openCollection(
                            path: colPath, mediaFolder: mediaFolder.path, mediaDB: mediaDBPath
                        )
                        throw error
                    }
                    return backend
                }
            }
        } catch {
            status = "Couldn't switch language: \(error)"
            return
        }
        // Swap in the new backend (the old one deinits and frees its handle) and
        // repoint the translation bridge, then refresh the language-dependent UI.
        self.backend = newBackend
        Loc.configure(backend: newBackend)
        await reloadDeckTree()
    }

    /// Loads the persisted app-local sync settings (auto-sync on open/close,
    /// fetch-media-on-sync) from `UserDefaults`. Both default on (Anki's
    /// defaults) when unset; read once at boot, with the published setters
    /// keeping `UserDefaults` in sync thereafter.
    private func loadSyncPrefs() {
        let defaults = UserDefaults.standard
        autoSyncEnabled = (defaults.object(forKey: Self.autoSyncKey) as? Bool) ?? true
        fetchMediaOnSync = (defaults.object(forKey: Self.fetchMediaKey) as? Bool) ?? true
    }

    /// Loads the persisted auto-advance *enable* toggle from `UserDefaults` (the
    /// only client-side auto-advance setting; timing/actions come from the deck
    /// config). Read once at boot; the published setter keeps it in sync.
    private func loadAutoAdvancePrefs() {
        autoAdvanceEnabled = UserDefaults.standard.bool(forKey: Self.autoAdvanceEnabledKey)
    }

    /// Opens (or reopens) the collection at the app's standard Documents paths.
    /// `nonisolated static` so it can run inside a detached (off-main) task at
    /// boot; the close→reopen paths in import/export call `openCollection`
    /// directly.
    nonisolated private static func openDefaultCollection(
        _ backend: Backend, mediaFolder: URL, colPath: String, mediaDBPath: String
    ) throws {
        try? FileManager.default.createDirectory(at: mediaFolder, withIntermediateDirectories: true)
        try backend.openCollection(
            path: colPath,
            mediaFolder: mediaFolder.path,
            mediaDB: mediaDBPath
        )
    }

    /// Reload the deck list and its counts (e.g. after returning from review).
    /// Fire-and-forget: the actual deck-tree read is offloaded by `reloadDeckTree`
    /// so this stays a cheap, synchronous call from every mutation site and the
    /// UI. Signature is unchanged so all call sites keep working.
    func refreshDecks() {
        Task { await reloadDeckTree() }
    }

    /// Fetches the deck tree off the main actor (it's O(collection) and computes
    /// due counts, so on a large collection it would hitch the UI if run inline),
    /// then publishes it on the main actor. A generation token drops a stale
    /// result so rapid successive refreshes never publish out of order.
    private func reloadDeckTree() async {
        guard let backend else { return }
        decksRefreshToken &+= 1
        let token = decksRefreshToken
        do {
            let tree = try await runDetached { try backend.deckTree() }
            // A newer refresh started while this one was in flight — drop it.
            guard token == decksRefreshToken else { return }
            decks = tree
            // Push the fresh due counts to the home-screen widget's shared store.
            updateWidgetSnapshot()
        } catch {
            guard token == decksRefreshToken else { return }
            status = "Deck list error: \(error)"
        }
    }

    /// Publish today's due counts to the shared App Group so the home-screen
    /// widget can render them, then ask WidgetKit to refresh. Called from the
    /// single point where `decks` changes (`reloadDeckTree`), so every deck
    /// refresh — boot, returning from review/browse, add/delete, sync — keeps
    /// the widget current. Mirrors AnkiDroid refreshing its DeckPicker widget
    /// whenever due counts change.
    ///
    /// Safe when there's no widget / App Group: `save()` no-ops without the
    /// shared suite, and `reloadAllTimelines()` is a no-op with no widgets
    /// installed — so this never affects the app build or behavior. Also called
    /// from the scene-phase handler so backgrounding the app refreshes the
    /// widget's "updated" stamp even if no deck mutation occurred.
    func updateWidgetSnapshot() {
        // Only top-level decks (depth 0); Anki already folds each subdeck's
        // counts into its top-level parent, so summing these avoids double
        // counting and matches the totals AnkiDroid's widget shows.
        let topLevel = decks.filter { $0.depth == 0 }
        let totalNew = topLevel.reduce(0) { $0 + $1.newCount }
        let totalLearn = topLevel.reduce(0) { $0 + $1.learnCount }
        let totalReview = topLevel.reduce(0) { $0 + $1.reviewCount }
        // A few decks with something to study, most-loaded first, for the
        // medium widget's per-deck rows.
        let deckRows = topLevel
            .filter { $0.hasCardsReadyToStudy }
            .sorted {
                ($0.newCount + $0.learnCount + $0.reviewCount)
                    > ($1.newCount + $1.learnCount + $1.reviewCount)
            }
            .prefix(4)
            .map {
                AnkiWidgetDeckDue(
                    name: $0.name, new: $0.newCount, learn: $0.learnCount, review: $0.reviewCount
                )
            }
        let snapshot = AnkiWidgetSnapshot(
            totalNew: totalNew,
            totalLearn: totalLearn,
            totalReview: totalReview,
            decks: Array(deckRows),
            updatedAt: Date()
        )
        snapshot.save()
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// Select `id` as the current deck (so the scheduler scopes study to it and
    /// its subdecks), reset reviewer state, and load the first queued card.
    /// Returns whether the selection succeeded so a caller (e.g. the deck
    /// overview's "Study") can guard navigation on it, only entering the reviewer
    /// when the deck was actually selected.
    @discardableResult
    func selectDeck(id: Int64) -> Bool {
        guard let backend else { return false }
        do {
            try backend.setCurrentDeck(id: id)
            currentDeckID = id
            reviewDone = false
            showingAnswer = false
            currentQuestion = ""
            currentAnswer = ""
            currentCSS = ""
            currentIntervals = []
            currentFlag = 0
            isMarked = false
            newCount = 0
            learningCount = 0
            reviewCount = 0
            currentCard = nil
            loadNext()
            return true
        } catch {
            status = "Select error: \(error)"
            return false
        }
    }

    // MARK: - Deck management

    /// Creates a new deck (`::`-separated names create subdecks), then refreshes
    /// the deck list so it appears. Runs the backend write off the main actor so
    /// the UI stays responsive. Throws so the caller can surface a clear message
    /// (e.g. an invalid name). Clone of AnkiDroid's create-deck action.
    func createDeck(name: String) async throws {
        guard let backend else { throw NoteEditorError.collectionNotReady }
        _ = try await runDetached { try backend.createDeck(name: name) }
        refreshDecks()
        refreshUndo()
    }

    /// Renames a deck in place (reparenting its subdecks), then refreshes the
    /// list. Runs off the main actor so a large reparent doesn't hang the UI.
    /// Clone of AnkiDroid's rename context action.
    func renameDeck(id: Int64, name: String) async throws {
        guard let backend else { throw NoteEditorError.collectionNotReady }
        try await runDetached { try backend.renameDeck(id: id, name: name) }
        refreshDecks()
        refreshUndo()
    }

    /// Deletes a deck and its cards, then refreshes the list. Runs off the main
    /// actor (deleting a big deck removes all its cards) so the UI stays
    /// responsive. Clone of AnkiDroid's delete-deck action (the confirmation
    /// lives in the view).
    func deleteDeck(id: Int64) async throws {
        guard let backend else { throw NoteEditorError.collectionNotReady }
        _ = try await runDetached { try backend.removeDecks(ids: [id]) }
        // Deleting the current deck falls study back to the Default deck.
        if currentDeckID == id { currentDeckID = 1 }
        refreshDecks()
        refreshUndo()
    }

    /// Toggles whether a deck is collapsed in the deck list (hiding/showing its
    /// subdecks), persisting it to the engine so it round-trips and syncs.
    /// Fire-and-forget like the other deck mutations: the set + reload run off
    /// the main actor, then `refreshDecks()` republishes the tree (whose nodes
    /// now carry the new collapsed state). Clone of AnkiDroid's DeckPicker
    /// expand/collapse chevron.
    func toggleDeckCollapsed(_ deck: DeckTreeEntry) {
        guard let backend else { return }
        let newValue = !deck.collapsed
        Task { @MainActor in
            do {
                try await runDetached { try backend.setDeckCollapsed(deckID: deck.id, collapsed: newValue) }
                refreshDecks()
            } catch {
                status = "Collapse error: \(error)"
            }
        }
    }

    /// Creates a subdeck (`Parent::Child`) under an existing deck, then refreshes
    /// the list. If the parent was collapsed (Anki creates parents collapsed by
    /// default), it's expanded so the freshly created child is actually visible —
    /// matching the user's intent of adding a subdeck they can see. Runs the
    /// backend writes off the main actor. Throws so the caller can surface a
    /// clear message (e.g. an invalid/duplicate name).
    func createSubdeck(under parent: DeckTreeEntry, name: String) async throws {
        guard let backend else { throw NoteEditorError.collectionNotReady }
        let fullName = "\(parent.fullName)::\(name)"
        let wasCollapsed = parent.collapsed
        try await runDetached {
            _ = try backend.createDeck(name: fullName)
            // Reveal the new child if its parent was collapsed.
            if wasCollapsed {
                try backend.setDeckCollapsed(deckID: parent.id, collapsed: false)
            }
        }
        refreshDecks()
        refreshUndo()
    }

    /// Returns a deck's buried cards (both scheduler- and user-buried) to the
    /// study queue, then refreshes the deck counts (unburying changes how many
    /// cards are due). Runs off the main actor. Clone of AnkiDroid's deck
    /// "Unbury" context action. Undoable via the engine.
    func unburyDeck(id: Int64) async throws {
        guard let backend else { throw NoteEditorError.collectionNotReady }
        try await runDetached { try backend.unburyDeck(deckID: id) }
        refreshDecks()
        refreshUndo()
    }

    /// Reads a deck's basic daily limits (new/day, reviews/day) for the options
    /// sheet; returns nil if the collection isn't ready or the deck can't be read.
    func deckLimits(forDeck id: Int64) -> DeckLimits? {
        guard let backend else { return nil }
        return try? backend.deckLimits(deckID: id)
    }

    /// Persists a deck's basic daily limits, then refreshes the list (the new
    /// limit changes how many cards are due). Throws so the options sheet can
    /// surface a clear message.
    func setDeckLimits(forDeck id: Int64, newPerDay: Int, reviewsPerDay: Int) throws {
        guard let backend else { throw NoteEditorError.collectionNotReady }
        try backend.setDeckLimits(deckID: id, newPerDay: newPerDay, reviewsPerDay: reviewsPerDay)
        refreshDecks()
        refreshUndo()
    }

    // MARK: - Note add/edit

    /// All notetypes (id + name) for the editor's notetype picker. Wraps
    /// `notetypeNames()`; returns an empty list if the collection isn't ready.
    func availableNotetypes() -> [(id: Int64, name: String)] {
        guard let backend else { return [] }
        return (try? backend.notetypeNames()) ?? []
    }

    /// Ordered field names for a notetype, used to label the editor's per-field
    /// inputs (aligns with a note's `fields`).
    func fieldNames(forNotetype notetypeID: Int64) -> [String] {
        guard let backend else { return [] }
        return (try? backend.notetypeFields(notetypeID: notetypeID)) ?? []
    }

    /// Whether `notetypeID` is an Image Occlusion note type (its config's
    /// `original_stock_kind` is IMAGE_OCCLUSION). The Note Editor uses this to
    /// switch to the image-occlusion add flow (pick image → web editor) instead of
    /// showing the raw IO fields, mirroring AnkiDroid's `NoteType.isImageOcclusion`.
    func isImageOcclusionNotetype(_ notetypeID: Int64) -> Bool {
        guard let backend, let notetype = try? backend.notetype(id: notetypeID) else { return false }
        return notetype.config.originalStockKind == .imageOcclusion
    }

    /// Sets the collection's current deck without touching the reviewer. New image
    /// occlusion notes are added to the *current* deck by the engine
    /// (`add_image_occlusion_note` reads `get_current_deck`, which takes no deck
    /// argument), so the add flow calls this to target the deck the user picked
    /// before opening the web editor.
    func setCurrentDeck(_ deckID: Int64) {
        guard let backend else { return }
        try? backend.setCurrentDeck(id: deckID)
        currentDeckID = deckID
    }

    /// Loads an existing note's notetype, fields, and tags for editing.
    func note(forEditing noteID: Int64) -> NoteForEditing? {
        guard let backend else { return nil }
        return try? backend.getNote(noteID: noteID)
    }

    /// Adds a new note (ADD mode), then refreshes the deck counts so the new
    /// card shows up on Home. Throws so the editor can surface a clear message.
    func addNote(notetypeID: Int64, fields: [String], tags: [String], deckID: Int64) throws {
        guard let backend else { throw NoteEditorError.collectionNotReady }
        _ = try backend.addNote(notetypeID: notetypeID, fields: fields, deckID: deckID, tags: tags)
        refreshDecks()
        refreshUndo()
    }

    /// Saves edited fields/tags for an existing note (EDIT mode), then refreshes
    /// derived state. Throws so the editor can surface a clear message.
    func updateNote(noteID: Int64, fields: [String], tags: [String]) throws {
        guard let backend else { throw NoteEditorError.collectionNotReady }
        try backend.updateNote(noteID: noteID, fields: fields, tags: tags)
        refreshDecks()
        refreshUndo()
    }

    /// Stores picked/recorded media into the open collection's `collection.media`
    /// folder (via the engine, so the name is sanitized + deduplicated and the
    /// media DB is updated for the next sync) and returns the *stored* filename to
    /// embed in a field as `<img src="NAME">` or `[sound:NAME]`. Mirrors
    /// AnkiDroid's NoteEditor saving multimedia through `col.media.addFile`.
    ///
    /// Runs off the main actor because the bytes (a photo or audio clip) can be
    /// large and the write touches disk; `Backend` is `Sendable`/thread-safe.
    /// Throws so the editor can surface a clear message.
    func addMediaFile(data: Data, desiredName: String) async throws -> String {
        guard let backend else { throw NoteEditorError.collectionNotReady }
        return try await runDetached { try backend.addMediaFile(desiredName: desiredName, data: data) }
    }

    /// Runs the engine's `note_fields_check` on an uncommitted note (notetype +
    /// field values), off the main actor, for the editor's live duplicate / empty
    /// / cloze warning. Best-effort: nil if the collection isn't ready or the
    /// check fails (e.g. a transient field-count mismatch mid note-type switch),
    /// which the editor treats as "no warning".
    func checkNoteFields(
        notetypeID: Int64, fields: [String], noteID: Int64 = 0
    ) async -> Anki_Notes_NoteFieldsCheckResponse.State? {
        guard let backend else { return nil }
        return try? await runDetached {
            try backend.noteFieldsCheck(notetypeID: notetypeID, fields: fields, noteID: noteID)
        }
    }

    /// The current per-notetype sticky flags (field order) — which fields keep
    /// their value for the next added note. Loaded when the editor's field set
    /// (re)loads. Best-effort: empty list if unavailable.
    func notetypeFieldStickies(_ notetypeID: Int64) -> [Bool] {
        guard let backend else { return [] }
        return (try? backend.notetypeFieldStickies(notetypeID: notetypeID)) ?? []
    }

    /// Flips a field's sticky flag on the note type and persists it (so it
    /// survives relaunch and syncs), off the main actor. Throws so the editor can
    /// revert its optimistic toggle and surface a message.
    func setNotetypeFieldSticky(notetypeID: Int64, at index: Int, sticky: Bool) async throws {
        guard let backend else { throw NoteEditorError.collectionNotReady }
        try await runDetached {
            try backend.setNotetypeFieldSticky(notetypeID: notetypeID, at: index, sticky: sticky)
        }
        refreshUndo()
    }

    /// Renders every card an uncommitted note (notetype + field values) would
    /// generate, for the editor's Preview sheet, off the main actor. Best-effort:
    /// empty list if the collection isn't ready or rendering fails.
    func renderUncommittedNoteCards(notetypeID: Int64, fields: [String]) async -> [EditorCardPreview] {
        guard let backend else { return [] }
        return (try? await runDetached {
            try backend.renderUncommittedNoteCards(notetypeID: notetypeID, fields: fields)
        }) ?? []
    }

    // MARK: - Card Browser

    /// Resolves a Card Browser search to its matching *row* ids (card ids in
    /// cards mode, note ids in notes mode) in the given sort order, off the main
    /// actor. Cheap even on a huge collection — it returns ids only; the browser
    /// then fetches row DATA lazily, a page at a time, via
    /// `browserRows(forIDs:columns:mode:)`. Throws so the browser can show an
    /// invalid-search / not-ready message; an empty result is a normal empty list.
    func browserItemIDs(
        query: String, sort: BrowserSort = .default, mode: BrowserMode = .cards
    ) async throws -> [Int64] {
        guard let backend else { throw NoteEditorError.collectionNotReady }
        return try await runDetached { try backend.browserRowIDs(query: query, sort: sort, mode: mode) }
    }

    /// The full set of selectable browser columns (labels + sort behavior) for
    /// the column picker and the sort menu, off the main actor. Best-effort:
    /// returns [] if the collection isn't ready or the call fails, so the UI just
    /// shows no extra options and keeps its persisted defaults.
    func allBrowserColumns() async -> [BrowserColumn] {
        guard let backend else { return [] }
        return (try? await runDetached { try backend.allBrowserColumns() }) ?? []
    }

    /// Builds the display rows for one page of row ids (the rows currently on
    /// screen) for the given active `columns` and `mode`, off the main actor —
    /// one backend call per row. The ids are card ids in cards mode and note ids
    /// in notes mode. Concurrently deleted rows are skipped, so the result may be
    /// shorter than the input. A page-level failure (e.g. the collection isn't
    /// ready) yields an empty page rather than throwing, so the browser simply
    /// leaves those rows as placeholders to retry later instead of erroring the
    /// whole list.
    func browserRows(
        forIDs ids: [Int64], columns: [String] = Backend.defaultBrowserColumns,
        mode: BrowserMode = .cards
    ) async -> [CardBrowserRow] {
        guard let backend else { return [] }
        return (try? await runDetached { try backend.browserRows(ids: ids, columns: columns, mode: mode) }) ?? []
    }

    /// Resolves the note id behind a card on demand — for opening the editor or
    /// Change Note Type from a single tapped browser row (cards mode) — off the
    /// main actor. Returns nil if the card was concurrently deleted.
    func noteID(forCard cardID: Int64) async -> Int64? {
        guard let backend else { return nil }
        return (try? await runDetached { try backend.getCard(cardID: cardID) })?.noteID
    }

    /// Resolves note ids to every card id belonging to those notes, off the main
    /// actor — the notes-mode bridge for the card-level browser actions (suspend
    /// / flag / deck / bury), whose selection is note ids. Best-effort: [] on
    /// failure.
    func cardIDs(forNotes noteIDs: [Int64]) async -> [Int64] {
        guard let backend else { return [] }
        return (try? await runDetached { try backend.cardIDs(forNoteIDs: noteIDs) }) ?? []
    }

    /// Resolves a note to its first (lowest-ordinal) card, off the main actor —
    /// used by notes-mode Preview / Card Info, which act on a concrete card.
    /// Returns nil if the note was concurrently deleted.
    func firstCardID(ofNote noteID: Int64) async -> Int64? {
        guard let backend else { return nil }
        return (try? await runDetached { try backend.firstCardID(ofNote: noteID) }) ?? nil
    }

    /// Renders a card for the read-only browser Preview (question/answer HTML,
    /// notetype CSS, and template ordinal), off the main actor — reusing the
    /// reviewer's render path without any scheduling side effects. Best-effort:
    /// nil if the card can't be rendered.
    func cardPreview(cardID: Int64) async -> CardPreviewContent? {
        guard let backend else { return nil }
        return try? await runDetached { try backend.cardPreview(cardID: cardID) }
    }

    /// Deletes the given notes (and all of their cards) off the main actor — the
    /// notes-mode delete, where the browser selection is note ids. Returns the
    /// note ids removed so the browser can drop exactly those rows in place.
    @discardableResult
    func deleteNotes(noteIDs: [Int64]) async throws -> [Int64] {
        guard let backend else { throw NoteEditorError.collectionNotReady }
        _ = try await runDetached { try backend.removeNotes(noteIDs: noteIDs) }
        refreshDecks()
        refreshUndo()
        return noteIDs
    }

    // MARK: - Card Browser filter sidebar

    /// All tags in the collection (engine-sorted), off the main actor — the
    /// sidebar's Tags section. Best-effort: [] on failure.
    func allTags() async -> [String] {
        guard let backend else { return [] }
        return (try? await runDetached { try backend.allTags() }) ?? []
    }

    /// The full deck hierarchy (every deck incl. collapsed subdecks and filtered
    /// decks) with its new/learn/review counts, off the main actor — the source
    /// for the sidebar's collapsible Decks tree. Unlike the Home deck list it
    /// ignores the reviewer collapse state, so the browser's OWN per-node
    /// expansion controls which subdecks show. Best-effort: [] on failure.
    func browserDeckTree() async -> [DeckTreeEntry] {
        guard let backend else { return [] }
        return (try? await runDetached { try backend.fullDeckTree() }) ?? []
    }

    /// The collection's saved searches (Anki's browser sidebar "Saved
    /// Searches"), off the main actor. Best-effort: [] on failure.
    func savedSearches() async -> [SavedSearch] {
        guard let backend else { return [] }
        return (try? await runDetached { backend.savedSearches() }) ?? []
    }

    /// Saves (or overwrites) a named saved search, off the main actor, then
    /// refreshes undo state. Throws so the UI can surface a save failure.
    func saveSearch(name: String, query: String) async throws {
        guard let backend else { throw NoteEditorError.collectionNotReady }
        try await runDetached { try backend.saveSearch(name: name, query: query) }
        refreshUndo()
    }

    /// Suspends or unsuspends the given cards off the main actor, then refreshes
    /// derived state. Suspended cards leave the study queue, so deck counts are
    /// refreshed too.
    func setCardsSuspended(_ cardIDs: [Int64], suspended: Bool) async throws {
        guard let backend else { throw NoteEditorError.collectionNotReady }
        try await runDetached {
            if suspended {
                _ = try backend.suspendCards(cardIDs: cardIDs)
            } else {
                try backend.unsuspendCards(cardIDs: cardIDs)
            }
        }
        refreshDecks()
        refreshUndo()
    }

    /// Sets (1...7) or clears (0) the flag color on the given cards, off the main
    /// actor.
    func setFlag(_ cardIDs: [Int64], flag: Int) async throws {
        guard let backend else { throw NoteEditorError.collectionNotReady }
        _ = try await runDetached { try backend.setFlag(cardIDs: cardIDs, flag: flag) }
        refreshUndo()
    }

    /// Deletes the notes behind the given cards off the main actor (a delete can
    /// cascade to many sibling cards, so it must not block the main thread), then
    /// refreshes derived state. Returns every card id removed — the affected
    /// notes' cards, resolved before the delete — so the browser can drop exactly
    /// those rows in place instead of re-running the whole search.
    @discardableResult
    func deleteNotes(forCards cardIDs: [Int64]) async throws -> [Int64] {
        guard let backend else { throw NoteEditorError.collectionNotReady }
        let removed = try await runDetached { () throws -> [Int64] in
            // Resolve every card of the affected notes BEFORE deleting (a note's
            // siblings are deleted too), so the caller can remove exactly those
            // rows. Best-effort: fall back to the tapped cards if a lookup fails.
            var affected = Set(cardIDs)
            for cardID in cardIDs {
                if let noteID = try? backend.getCard(cardID: cardID).noteID,
                   let siblings = try? backend.searchCards(query: "nid:\(noteID)") {
                    affected.formUnion(siblings)
                }
            }
            _ = try backend.removeNotesForCards(cardIDs: cardIDs)
            return Array(affected)
        }
        refreshDecks()
        refreshUndo()
        return removed
    }

    // MARK: - Card Browser bulk actions (multi-select)
    //
    // Each applies one backend op to every selected card off the main actor (a
    // big selection mustn't block the UI), then refreshes derived state. The
    // browser updates the affected rows in place afterwards. Mirrors AnkiDroid's
    // CardBrowser bulk operations. All are undoable through the engine.

    /// Moves the selected cards to `deckID` (a normal deck), off the main actor.
    /// Cards leaving/entering decks change deck counts, so the deck list is
    /// refreshed.
    func setDeck(forCards cardIDs: [Int64], deckID: Int64) async throws {
        guard let backend else { throw NoteEditorError.collectionNotReady }
        _ = try await runDetached { try backend.setDeck(cardIDs: cardIDs, deckID: deckID) }
        refreshDecks()
        refreshUndo()
    }

    /// Buries the selected cards (manual bury), off the main actor. Buried cards
    /// leave the study queue, so deck counts are refreshed.
    func buryCards(_ cardIDs: [Int64]) async throws {
        guard let backend else { throw NoteEditorError.collectionNotReady }
        _ = try await runDetached { try backend.buryCards(cardIDs: cardIDs) }
        refreshDecks()
        refreshUndo()
    }

    /// Adds the given space-separated tag(s) to the notes behind the selected
    /// cards, off the main actor.
    func addTags(forCards cardIDs: [Int64], tags: String) async throws {
        guard let backend else { throw NoteEditorError.collectionNotReady }
        _ = try await runDetached { try backend.addTags(cardIDs: cardIDs, tags: tags) }
        refreshUndo()
    }

    /// Removes the given space-separated tag(s) from the notes behind the
    /// selected cards, off the main actor.
    func removeTags(forCards cardIDs: [Int64], tags: String) async throws {
        guard let backend else { throw NoteEditorError.collectionNotReady }
        _ = try await runDetached { try backend.removeTags(cardIDs: cardIDs, tags: tags) }
        refreshUndo()
    }

    /// Marks or unmarks the notes behind the selected cards (toggling the
    /// `marked` tag), off the main actor.
    func setMarked(forCards cardIDs: [Int64], marked: Bool) async throws {
        guard let backend else { throw NoteEditorError.collectionNotReady }
        _ = try await runDetached { try backend.setMarked(cardIDs: cardIDs, marked: marked) }
        refreshUndo()
    }

    // MARK: - Card Browser find & replace

    /// Resolves a selection of card ids to their owning note ids (siblings
    /// collapse to one note), off the main actor — the Find & Replace
    /// "selected notes" scope. Best-effort: [] on failure.
    func noteIDs(forCards cardIDs: [Int64]) async -> [Int64] {
        guard let backend else { return [] }
        return (try? await runDetached { try backend.noteIDs(forCardIDs: cardIDs) }) ?? []
    }

    /// Resolves a search to its matching NOTE ids, off the main actor — the Find &
    /// Replace "all matching notes" scope when there's no explicit selection.
    func searchNotes(query: String) async throws -> [Int64] {
        guard let backend else { throw NoteEditorError.collectionNotReady }
        return try await runDetached { try backend.searchNotes(query: query) }
    }

    /// The candidate field names for Find & Replace's "in field" picker (the
    /// union across note types), off the main actor. Best-effort: [] on failure.
    func browserFieldNames() async -> [String] {
        guard let backend else { return [] }
        return (try? await runDetached { try backend.allFieldNames() }) ?? []
    }

    /// Runs Find & Replace across the given notes off the main actor (it can touch
    /// many notes, so it must not block the UI), returning the number of notes
    /// changed. `fieldName` nil/empty = all fields. Undoable via the engine;
    /// derived undo state is refreshed.
    @discardableResult
    func findAndReplace(
        noteIDs: [Int64], search: String, replacement: String,
        regex: Bool, matchCase: Bool, fieldName: String?
    ) async throws -> Int {
        guard let backend else { throw NoteEditorError.collectionNotReady }
        let changed = try await runDetached {
            try backend.findAndReplace(
                noteIDs: noteIDs, search: search, replacement: replacement,
                regex: regex, matchCase: matchCase, fieldName: fieldName
            )
        }
        refreshUndo()
        return changed
    }

    // MARK: - Statistics

    /// Loads the stats summary for the whole collection over the given period,
    /// off the main actor (the engine gathers and aggregates the revlog, which
    /// can be heavy on large collections). Mirrors how AnkiDroid's Statistics
    /// screen reads `col.graphs(...)`; here we render the data natively instead
    /// of in a WebView. Throws so the Stats screen can surface a clear message.
    func statsSummary(period: StatsPeriod) async throws -> StatsSummary {
        guard let backend else { throw NoteEditorError.collectionNotReady }
        return try await runDetached { try backend.statsSummary(period: period) }
    }

    // MARK: - Card Info

    /// Loads a single card's statistics for the Card Info screen, off the main
    /// actor (the engine gathers the card's revlog). Mirrors how AnkiDroid's Card
    /// Info screen reads `col.cardStats(cid)`. Throws so the view can surface a
    /// clear message.
    func cardInfo(cardID: Int64) async throws -> CardInfo {
        guard let backend else { throw NoteEditorError.collectionNotReady }
        return try await runDetached { try backend.cardInfo(cardID: cardID) }
    }

    /// The id of the first card in the collection (collection order), or nil if
    /// there are none. Used by the debug screenshot hook to open Card Info.
    func firstCardID() async -> Int64? {
        guard let backend else { return nil }
        return (try? await runDetached { try backend.searchCards(query: "") })?.first
    }

    /// The note id behind the first card in the collection, or nil if there are
    /// none. Used by the debug screenshot hook to open Change Note Type.
    func firstNoteID() async -> Int64? {
        guard let backend, let cardID = await firstCardID() else { return nil }
        return (try? await runDetached { try backend.getCard(cardID: cardID) })?.noteID
    }

    // MARK: - Change Note Type

    /// The notetype id behind a note (the "old" type when changing it). Returns
    /// nil if the note can't be read.
    func notetypeID(forNote noteID: Int64) -> Int64? {
        guard let backend else { return nil }
        return (try? backend.getNote(noteID: noteID))?.notetypeID
    }

    /// Computes the default field/template mapping for moving notes from one
    /// notetype to another, for the change-notetype mapping UI. Throws so the
    /// view can surface a clear message.
    func changeNotetypeInfo(oldNotetypeID: Int64, newNotetypeID: Int64) throws -> ChangeNotetypeInfo {
        guard let backend else { throw NoteEditorError.collectionNotReady }
        return try backend.changeNotetypeInfo(oldNotetypeID: oldNotetypeID, newNotetypeID: newNotetypeID)
    }

    /// Applies a notetype change to the given notes using the chosen mapping,
    /// then refreshes derived state (cards may be added/removed). Runs the
    /// conversion off the main actor (it rewrites every affected note/card) so
    /// the UI doesn't hang. Throws so the view can surface a clear message.
    func changeNotetype(
        noteIDs: [Int64], info: ChangeNotetypeInfo,
        fieldMap: [Int?], templateMap: [Int?]
    ) async throws {
        guard let backend else { throw NoteEditorError.collectionNotReady }
        try await runDetached {
            try backend.changeNotetype(
                noteIDs: noteIDs, info: info, fieldMap: fieldMap, templateMap: templateMap
            )
        }
        refreshDecks()
        refreshUndo()
    }

    // MARK: - Note type management

    /// Every note type with its note count, for the "Manage note types" list.
    /// Off the main actor; best-effort (empty on failure / not ready).
    func notetypeUseCounts() async -> [NotetypeUseCount] {
        guard let backend else { return [] }
        return (try? await runDetached { try backend.notetypeNamesAndCounts() }) ?? []
    }

    /// Loads a note type's full editable model (fields, templates, CSS) for the
    /// Fields / Card Template editors. Off the main actor; nil if it can't load.
    func loadNotetype(id: Int64) async -> Anki_Notetypes_Notetype? {
        guard let backend else { return nil }
        return try? await runDetached { try backend.notetype(id: id) }
    }

    /// The stock note types (kind + display name) offered as bases in the "Add
    /// note type" dialog, plus the existing note types to clone. Off the main
    /// actor; best-effort.
    func addNotetypeBases() async -> (stock: [(kind: Anki_Notetypes_StockNotetype.Kind, name: String)],
                                      existing: [(id: Int64, name: String)]) {
        guard let backend else { return ([], []) }
        let result = try? await runDetached { () -> ([(Anki_Notetypes_StockNotetype.Kind, String)], [(Int64, String)]) in
            let stock = Anki_Notetypes_StockNotetype.Kind.allCases.compactMap {
                kind -> (Anki_Notetypes_StockNotetype.Kind, String)? in
                guard let name = try? backend.stockNotetypeName(kind: kind), !name.isEmpty else { return nil }
                return (kind, name)
            }
            let existing = (try? backend.notetypeNames()) ?? []
            return (stock, existing.map { ($0.id, $0.name) })
        }
        guard let result else { return ([], []) }
        return (result.0.map { (kind: $0.0, name: $0.1) }, result.1.map { (id: $0.0, name: $0.1) })
    }

    /// Adds a new note type from a stock kind (the Add dialog's "Add" option),
    /// off the main actor. Throws so the dialog can surface a clear message.
    func addStockNotetype(kind: Anki_Notetypes_StockNotetype.Kind, name: String) async throws {
        guard let backend else { throw NoteEditorError.collectionNotReady }
        _ = try await runDetached { try backend.addStockNotetype(kind: kind, name: name) }
        refreshUndo()
    }

    /// Clones an existing note type under a new name (the Add dialog's "Clone"
    /// option), off the main actor.
    func cloneNotetype(id: Int64, name: String) async throws {
        guard let backend else { throw NoteEditorError.collectionNotReady }
        _ = try await runDetached { try backend.cloneNotetype(id: id, name: name) }
        refreshUndo()
    }

    /// Renames a note type in place, off the main actor.
    func renameNotetype(id: Int64, name: String) async throws {
        guard let backend else { throw NoteEditorError.collectionNotReady }
        try await runDetached { try backend.renameNotetype(id: id, name: name) }
        refreshUndo()
    }

    /// Deletes a note type and all of its notes/cards, off the main actor (a big
    /// type can cascade to many notes), then refreshes deck counts. The
    /// can't-delete-the-last guard lives in the view.
    func deleteNotetype(id: Int64) async throws {
        guard let backend else { throw NoteEditorError.collectionNotReady }
        try await runDetached { try backend.removeNotetype(id: id) }
        refreshDecks()
        refreshUndo()
    }

    /// Persists an edited note type (the Card Template editor's Save), off the
    /// main actor (it can rewrite every note/card of the type). The engine
    /// validates templates and throws on problems, which the editor surfaces.
    func saveNotetype(_ notetype: Anki_Notetypes_Notetype) async throws {
        guard let backend else { throw NoteEditorError.collectionNotReady }
        try await runDetached { try backend.updateNotetype(notetype) }
        refreshDecks()
        refreshUndo()
    }

    // MARK: - Fields editor (atomic per-op saves, like AnkiDroid)

    /// Appends a field to a note type (added empty to every note), off the main
    /// actor.
    func addNotetypeField(notetypeID: Int64, name: String) async throws {
        guard let backend else { throw NoteEditorError.collectionNotReady }
        try await runDetached { try backend.addNotetypeField(notetypeID: notetypeID, name: name) }
        refreshUndo()
    }

    /// Renames the field at `index`, off the main actor.
    func renameNotetypeField(notetypeID: Int64, at index: Int, to name: String) async throws {
        guard let backend else { throw NoteEditorError.collectionNotReady }
        try await runDetached { try backend.renameNotetypeField(notetypeID: notetypeID, at: index, to: name) }
        refreshUndo()
    }

    /// Moves the field at `from` to `to`, off the main actor.
    func moveNotetypeField(notetypeID: Int64, from: Int, to: Int) async throws {
        guard let backend else { throw NoteEditorError.collectionNotReady }
        try await runDetached { try backend.moveNotetypeField(notetypeID: notetypeID, from: from, to: to) }
        refreshUndo()
    }

    /// Removes the field at `index` (refused for the last field), off the main
    /// actor.
    func removeNotetypeField(notetypeID: Int64, at index: Int) async throws {
        guard let backend else { throw NoteEditorError.collectionNotReady }
        try await runDetached { try backend.removeNotetypeField(notetypeID: notetypeID, at: index) }
        refreshUndo()
    }

    /// Sets the note type's sort field, off the main actor.
    func setNotetypeSortField(notetypeID: Int64, at index: Int) async throws {
        guard let backend else { throw NoteEditorError.collectionNotReady }
        try await runDetached { try backend.setNotetypeSortField(notetypeID: notetypeID, at: index) }
        refreshUndo()
    }

    // MARK: - Card-template preview

    /// Renders a sample card's question/answer for the Card Template editor's live
    /// preview, off the main actor. Uses the (possibly unsaved) `template` so
    /// edits show immediately; the CSS is applied by the view from the edited note
    /// type. Best-effort: nil if rendering fails.
    func renderNotetypePreview(
        note: Anki_Notes_Note, cardOrd: Int, template: Anki_Notetypes_Notetype.Template
    ) async -> (question: String, answer: String)? {
        guard let backend else { return nil }
        return try? await runDetached {
            try backend.renderUncommittedCard(note: note, cardOrd: cardOrd, template: template)
        }
    }

    // MARK: - Filtered Decks

    /// Creates a filtered deck from a single search query / limit / order and
    /// builds it. Convenience over the two-filter variant below.
    @discardableResult
    func createFilteredDeck(
        name: String, search: String, limit: Int,
        order: FilteredDeckOrder, reschedule: Bool
    ) async throws -> FilteredDeckResult {
        try await createFilteredDeck(
            name: name,
            terms: [FilteredSearchTermInput(search: search, limit: limit, order: order)],
            reschedule: reschedule
        )
    }

    /// Creates a filtered deck from one or two search terms (each with its own
    /// search / order / limit) and the reschedule flag, then refreshes the deck
    /// list so it appears. The engine selects the new deck as current, so study
    /// pulls from it next. Throws so the caller can surface a clear message
    /// (e.g. an empty match). Clone of AnkiDroid's filtered-deck dialog, which
    /// supports up to two filters.
    @discardableResult
    func createFilteredDeck(
        name: String, terms: [FilteredSearchTermInput], reschedule: Bool
    ) async throws -> FilteredDeckResult {
        guard let backend else { throw NoteEditorError.collectionNotReady }
        // Gathering cards into the filtered deck can be heavy on a large
        // collection, so run it off the main actor to keep the UI responsive.
        let result = try await runDetached {
            try backend.createFilteredDeck(name: name, terms: terms, reschedule: reschedule)
        }
        currentDeckID = result.deckID
        refreshDecks()
        refreshUndo()
        return result
    }

    // MARK: - Custom Study

    /// Loads the Custom Study dialog's prefill values for a deck (today's extend
    /// defaults, available new/review counts, and the deck's tags), off the main
    /// actor. Best-effort: returns nil if the collection isn't ready or the call
    /// fails, so the dialog falls back to its own defaults. Clone of AnkiDroid's
    /// `CustomStudyDialog.loadCustomStudyDefaults`.
    func customStudyDefaults(forDeck deckID: Int64) async -> CustomStudyDefaults? {
        guard let backend else { return nil }
        return try? await runDetached { try backend.customStudyDefaults(deckID: deckID) }
    }

    /// Applies a Custom Study choice for a deck through the engine, off the main
    /// actor (a session build gathers cards, which can be heavy). For the session
    /// options the engine builds/updates the "Custom Study Session" filtered deck
    /// and we select it as current (loading its first card) so the caller can
    /// jump straight into the reviewer; for limit extensions the deck's limits
    /// change in place and study continues in the original deck. Deck counts and
    /// undo state are refreshed either way. Throws so the dialog can surface a
    /// clear message (e.g. "No cards matched"). Clone of AnkiDroid's
    /// `CustomStudyDialog.customStudy` + DeckPicker's result handling.
    @discardableResult
    func applyCustomStudy(forDeck deckID: Int64, choice: CustomStudyChoice) async throws -> CustomStudyOutcome {
        guard let backend else { throw NoteEditorError.collectionNotReady }
        let outcome = try await runDetached { try backend.customStudy(deckID: deckID, choice: choice) }
        if case let .builtSession(sessionID) = outcome {
            // Select the freshly built session deck so the reviewer studies it.
            selectDeck(id: sessionID)
        }
        refreshDecks()
        refreshUndo()
        return outcome
    }

    /// Re-gathers a filtered deck's cards from its search, returning the count.
    /// Clone of AnkiDroid's "Rebuild" custom-study action.
    @discardableResult
    func rebuildFilteredDeck(deckID: Int64) throws -> Int {
        guard let backend else { throw NoteEditorError.collectionNotReady }
        let count = try backend.rebuildFilteredDeck(deckID: deckID)
        refreshDecks()
        refreshUndo()
        return count
    }

    /// Empties a filtered deck (returns its cards to their home decks). Clone of
    /// AnkiDroid's "Empty" custom-study action.
    func emptyFilteredDeck(deckID: Int64) throws {
        guard let backend else { throw NoteEditorError.collectionNotReady }
        try backend.emptyFilteredDeck(deckID: deckID)
        refreshDecks()
        refreshUndo()
    }

    /// Seeds a few plain Basic cards into the Default deck on first launch, so a
    /// fresh install has something to review. Runs once (guarded by a
    /// `UserDefaults` flag). `nonisolated static` so it can run inside a detached
    /// (off-main) task at boot — it touches only the backend and `UserDefaults`
    /// (both thread-safe), never `@Published` state.
    nonisolated private static func seedIfNeeded(_ backend: Backend) throws {
        let key = "seeded_v1"
        if UserDefaults.standard.bool(forKey: key) { return }
        // Only seed a genuinely fresh collection. Gating on the collection
        // actually being empty (rather than only the UserDefaults flag) means a
        // UserDefaults reset can't re-seed a real collection, and a partial seed
        // failure can't duplicate demo notes on the next launch — the notes
        // already added leave the collection non-empty, so we skip. Setting the
        // guard up front too means a mid-seed failure won't re-run the adds.
        guard try backend.searchCards(query: "").isEmpty else {
            UserDefaults.standard.set(true, forKey: key)
            return
        }
        UserDefaults.standard.set(true, forKey: key)
        let notetypes = try backend.notetypeNames()
        // A "Basic (type in the answer)" card first, so the type-in flow is easy
        // to find when reviewing the demo deck.
        if let typeNotetype = notetypes.first(where: { $0.name.lowercased().contains("type in the answer") }) {
            _ = try backend.addNote(
                notetypeID: typeNotetype.id,
                fields: ["What is the capital of Japan?", "Tokyo"],
                deckID: 1
            )
        }
        guard let basic = notetypes.first(where: {
            $0.name.hasPrefix("Basic") && !$0.name.lowercased().contains("type")
        }) else {
            return
        }
        let cards: [(String, String)] = [
            ("What is the capital of France?", "Paris"),
            ("What is 2 + 2?", "4"),
            ("What is the largest planet in the Solar System?", "Jupiter"),
        ]
        for (q, a) in cards {
            _ = try backend.addNote(notetypeID: basic.id, fields: [q, a], deckID: 1)
        }
    }

    func startReview() {
        // The reviewer is now on top; allow auto-advance timers to run (they're
        // suppressed whenever the reviewer isn't the active screen).
        reviewerActive = true
        if currentQuestion.isEmpty && !reviewDone {
            loadNext()
        } else {
            // Returning to an already-loaded card (e.g. back from a push): re-resolve
            // the deck config (Deck Options may have changed while away) and resume
            // auto-advance for whichever side is currently shown.
            currentAutoAdvanceConfig = nil
            scheduleAutoAdvanceForCurrentSide()
        }
    }

    /// The reviewer left the screen: stop auto-advance so a pending timer can't
    /// reveal or grade a card after the user has navigated away. Audio is stopped
    /// separately by `stopReviewAudio()`. The per-deck config cache is dropped so
    /// a later session re-reads settings edited in Deck Options in the meantime.
    func endAutoAdvanceSession() {
        reviewerActive = false
        cancelAutoAdvance()
        clearAutoAdvanceReminder()
        autoAdvanceConfigByDeck.removeAll()
        currentAutoAdvanceConfig = nil
    }

    func loadNext() {
        guard let backend else { return }
        showingAnswer = false
        do {
            let q = try backend.queuedCards()
            // Surface the queue's remaining counts (honored by the reviewer's
            // remaining-count display, gated on `showRemainingDueCounts`).
            newCount = Int(q.newCount)
            learningCount = Int(q.learningCount)
            reviewCount = Int(q.reviewCount)
            guard let first = q.cards.first else {
                finishReview()
                return
            }
            try present(first)
        } catch {
            status = "Review error: \(error)"
        }
    }

    /// Renders a queued card into the reviewer's published state, presenting the
    /// card and its answer-button intervals.
    private func present(_ queued: Anki_Scheduler_QueuedCards.QueuedCard) throws {
        guard let backend else { return }
        reviewDone = false
        currentCard = queued
        currentOrdinal = Int(queued.card.templateIdx)
        let rendered = try backend.renderCard(cardID: queued.card.id)
        let q = (try? backend.extractAudio(text: rendered.question, questionSide: true))
            ?? (text: rendered.question, audio: [])
        let a = (try? backend.extractAudio(text: rendered.answer, questionSide: false))
            ?? (text: rendered.answer, audio: [])
        currentCSS = rendered.css
        currentQuestionAudio = q.audio
        currentAnswerAudio = a.audio
        // Type-in-the-answer: a [[type:Field]] placeholder means a native input
        // on the front and the diff on the back (clone of Anki's typeans flow).
        typeAnswer = Self.parseTypeField(in: q.text)
        typedAnswer = ""
        currentQuestion = Self.stripTypePlaceholders(q.text)
        pristineAnswer = a.text
        // Not shown until reveal() derives it; keep a placeholder-free default so
        // a raw `[[type:…]]` can never appear, even transiently.
        currentAnswer = Self.stripTypePlaceholders(pristineAnswer)
        // One interval label per button: [again, hard, good, easy].
        // Ignore an unexpected shape rather than mislabeling buttons.
        let intervals = (try? backend.describeNextStates(queued.states)) ?? []
        currentIntervals = intervals.count == 4 ? intervals : []
        // Flag/marked indicators for the new card (mirrors AnkiDroid emitting
        // flagFlow / isMarkedFlow on each card change).
        currentFlag = Int(queued.card.flags)
        isMarked = (try? backend.isNoteMarked(noteID: queued.card.noteID)) ?? false
        cardShownAt = Date()
        // A new card: drop the previous card's resolved auto-advance settings (the
        // next schedule re-resolves from this card's deck) and any stale reminder.
        currentAutoAdvanceConfig = nil
        clearAutoAdvanceReminder()
        refreshUndo()
        // Autoplay the question side's audio, as Anki does on showing a card.
        cardAudioPlayer.play(currentQuestionAudio, mediaFolder: mediaFolderURL)
        // Start the auto-advance question timer for the freshly shown card.
        scheduleAutoAdvanceForCurrentSide()
    }

    /// Clears reviewer state to the "all caught up" end-of-session screen.
    private func finishReview() {
        currentCard = nil
        reviewDone = true
        currentQuestion = ""
        currentAnswer = ""
        currentCSS = ""
        currentIntervals = []
        currentFlag = 0
        isMarked = false
        newCount = 0
        learningCount = 0
        reviewCount = 0
        currentQuestionAudio = []
        currentAnswerAudio = []
        cardAudioPlayer.stop()
        // No card to advance from, so stop any pending auto-advance timer and
        // clear its per-card settings / reminder.
        cancelAutoAdvance()
        currentAutoAdvanceConfig = nil
        clearAutoAdvanceReminder()
        typeAnswer = nil
        typedAnswer = ""
        refreshUndo()
    }

    func reveal() {
        // A gentle, diffuse "flip" tap as the answer is revealed.
        Haptics.flip()
        showingAnswer = true
        // Recompute the shown answer from the pristine copy every time, so a
        // flip-back → edit-typed-answer → reveal recomputes the diff instead of
        // reusing an already-consumed placeholder.
        currentAnswer = renderedAnswer()
        // Autoplay the answer side's audio, as Anki does on flipping to the back.
        cardAudioPlayer.play(currentAnswerAudio, mediaFolder: mediaFolderURL)
        // Switch the auto-advance timer to the answer side (cancels the question
        // timer; whether triggered by the user or by auto-reveal).
        scheduleAutoAdvanceForCurrentSide()
    }

    /// Builds the answer HTML to display from `pristineAnswer`: substitutes the
    /// type-in-the-answer diff (typed vs the expected field value) for the
    /// `[[type:…]]` placeholder when the card has a supported type field, and
    /// otherwise strips any placeholder so a raw `[[type:…]]` — e.g. an
    /// unsupported `[[type:cloze:…]]` — never leaks onto the back. Pure function
    /// of `pristineAnswer`/`typedAnswer`, so it's safe to call repeatedly.
    /// Mirrors Anki's reviewer typeans substitution.
    private func renderedAnswer() -> String {
        // No supported type-in field (plain card, or an unsupported cloze
        // type-in): never show a raw placeholder.
        guard let field = typeAnswer, let backend, let card = currentCard else {
            return Self.stripTypePlaceholders(pristineAnswer)
        }
        let expected = expectedFieldValue(field.fieldName, noteID: card.card.noteID) ?? ""
        let diff = (try? backend.compareAnswer(
            expected: expected, typed: typedAnswer, combining: field.combining
        )) ?? ""
        guard !diff.isEmpty else {
            return Self.stripTypePlaceholders(pristineAnswer)
        }
        // Escape regex-replacement metacharacters so the diff HTML inserts literally.
        let safe = diff
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "$", with: "\\$")
        return pristineAnswer.replacingOccurrences(
            of: "\\[\\[type:[^\\]]*\\]\\]", with: safe, options: .regularExpression
        )
    }

    /// The value of a note's field by name (notetype field order aligns with the
    /// note's field values), used as the expected type-in answer.
    private func expectedFieldValue(_ fieldName: String, noteID: Int64) -> String? {
        guard let backend,
              let note = try? backend.getNote(noteID: noteID),
              let names = try? backend.notetypeFields(notetypeID: note.notetypeID),
              let index = names.firstIndex(of: fieldName),
              index < note.fields.count
        else { return nil }
        return note.fields[index]
    }

    /// Parses the first `[[type:Field]]` / `[[type:nc:Field]]` placeholder; cloze
    /// type-in answers are not yet supported (returns nil).
    static func parseTypeField(in html: String) -> TypeAnswerField? {
        guard let range = html.range(of: "\\[\\[type:[^\\]]*\\]\\]", options: .regularExpression)
        else { return nil }
        var inner = html[range].dropFirst(7).dropLast(2)  // strip "[[type:" … "]]"
        if inner.hasPrefix("cloze:") { return nil }
        var combining = true
        if inner.hasPrefix("nc:") { combining = false; inner = inner.dropFirst(3) }
        let name = String(inner)
        return name.isEmpty ? nil : TypeAnswerField(fieldName: name, combining: combining)
    }

    /// Removes any `[[type:…]]` placeholders from rendered HTML for display.
    static func stripTypePlaceholders(_ html: String) -> String {
        html.replacingOccurrences(
            of: "\\[\\[type:[^\\]]*\\]\\]", with: "", options: .regularExpression
        )
    }

    /// Returns from the answer back to the question (the "tap center = flip"
    /// gesture toggling A → Q). Cheap local state flip; no engine call. Resumes
    /// the auto-advance question timer for the now-shown question.
    func flipBack() {
        Haptics.flip()
        showingAnswer = false
        scheduleAutoAdvanceForCurrentSide()
    }

    func rate(_ rating: Anki_Scheduler_CardAnswer.Rating) {
        guard let backend, let card = currentCard else { return }
        // Acting on the card: drop any pending auto-advance timer so a failed
        // answer can't leave one behind to re-grade (a successful answer reloads
        // the next card, which reschedules from scratch).
        cancelAutoAdvance()
        // Clamp to non-negative: if the wall clock moves backward (NTP/manual
        // change) the elapsed product is negative, and `UInt32(negativeDouble)`
        // is a fatal trap. Cap at 60s as Anki does.
        let ms = UInt32(min(60_000, max(0, Date().timeIntervalSince(cardShownAt) * 1000)))
        do {
            try backend.answer(card: card, rating: rating, millisecondsTaken: ms)
            // Only advance once the answer is actually recorded.
            loadNext()
            // Haptic confirmation: the subtle review-loop grade tick, upgraded to
            // a success flourish when this answer clears the deck (the rewarding
            // "finished" moment).
            if currentCard == nil { Haptics.success() } else { Haptics.grade() }
        } catch {
            // A failed answer (DB/scheduler error, stale state) must not be
            // silently dropped while the UI advances as if the review counted.
            // Surface it and keep the current card/answer shown so the user can
            // retry instead of losing study data.
            status = "Answer error: \(error)"
            Haptics.error()
        }
    }

    // MARK: - Reviewer card actions

    /// Card-action menu actions, cloning AnkiDroid's `ReviewerViewModel`.
    ///
    /// Flag and Mark update the current card *in place* (so the indicators change
    /// without leaving the card); Bury, Suspend, and Delete remove the current
    /// card from the queue and advance to the next one (AnkiDroid's
    /// `updateCurrentCard()` after these actions). Each runs through an undoable
    /// backend op, so the toolbar Undo reverts it.

    /// Sets (1...7) or clears (0) the current card's flag color, updating the
    /// on-card indicator in place. Clone of `ReviewerViewModel.setFlag`.
    func setReviewerFlag(_ flag: Int) {
        guard let backend, let cardID = currentCardID else { return }
        do {
            _ = try backend.setFlag(cardIDs: [cardID], flag: flag)
            currentFlag = flag
            Haptics.selection()
            refreshUndo()
        } catch {
            status = "Flag error: \(error)"
            Haptics.error()
        }
    }

    /// Toggles the current card's flag: tapping the active color clears it,
    /// otherwise sets the new color (clone of `ReviewerViewModel.toggleFlag`).
    func toggleReviewerFlag(_ flag: Int) {
        setReviewerFlag(currentFlag == flag ? 0 : flag)
    }

    /// Toggles the `marked` tag on the current card's note, updating the on-card
    /// star in place. Clone of `ReviewerViewModel.toggleMark`.
    func toggleMark() {
        guard let backend, let noteID = currentNoteID else { return }
        do {
            isMarked = try backend.toggleMark(noteID: noteID)
            Haptics.selection()
            refreshUndo()
        } catch {
            status = "Mark error: \(error)"
            Haptics.error()
        }
    }

    /// Buries the current card (manual bury) and advances. Clone of `buryCard`.
    func buryCard() {
        guard let backend, let cardID = currentCardID else { return }
        do {
            _ = try backend.buryCards(cardIDs: [cardID])
            Haptics.tap()
            afterCardRemovedFromQueue()
        } catch {
            status = "Bury error: \(error)"
            Haptics.error()
        }
    }

    /// Buries every card of the current card's note and advances. Clone of
    /// `buryNote`.
    func buryNote() {
        guard let backend, let noteID = currentNoteID else { return }
        do {
            _ = try backend.buryNotes(noteIDs: [noteID])
            Haptics.tap()
            afterCardRemovedFromQueue()
        } catch {
            status = "Bury error: \(error)"
            Haptics.error()
        }
    }

    /// Suspends the current card and advances. Clone of `suspendCard`.
    func suspendCard() {
        guard let backend, let cardID = currentCardID else { return }
        do {
            _ = try backend.suspendCards(cardIDs: [cardID])
            Haptics.tap()
            afterCardRemovedFromQueue()
        } catch {
            status = "Suspend error: \(error)"
            Haptics.error()
        }
    }

    /// Suspends every card of the current card's note and advances. Clone of
    /// `suspendNote`.
    func suspendNote() {
        guard let backend, let noteID = currentNoteID else { return }
        do {
            _ = try backend.suspendNotes(noteIDs: [noteID])
            Haptics.tap()
            afterCardRemovedFromQueue()
        } catch {
            status = "Suspend error: \(error)"
            Haptics.error()
        }
    }

    /// Deletes the current card's note (and its cards) and advances. Clone of
    /// `deleteNote`.
    func deleteCurrentNote() {
        guard let backend, let noteID = currentNoteID else { return }
        do {
            _ = try backend.removeNotes(noteIDs: [noteID])
            Haptics.warning()
            afterCardRemovedFromQueue()
        } catch {
            status = "Delete error: \(error)"
            Haptics.error()
        }
    }

    /// Re-renders the current card in place after its note was edited (so the
    /// reviewer reflects the new fields without advancing), refreshing the
    /// flag/marked indicators and deck counts. Clone of AnkiDroid refreshing the
    /// shown card after returning from the editor.
    func reloadCurrentCard() {
        guard let backend, let card = currentCard else { return }
        do {
            let rendered = try backend.renderCard(cardID: card.card.id)
            let q = (try? backend.extractAudio(text: rendered.question, questionSide: true))
                ?? (text: rendered.question, audio: [])
            let a = (try? backend.extractAudio(text: rendered.answer, questionSide: false))
                ?? (text: rendered.answer, audio: [])
            currentCSS = rendered.css
            currentQuestionAudio = q.audio
            currentAnswerAudio = a.audio
            typeAnswer = Self.parseTypeField(in: q.text)
            currentQuestion = Self.stripTypePlaceholders(q.text)
            pristineAnswer = a.text
            // Re-derive the shown answer from the fresh pristine copy (re-applying
            // the type-in diff if the answer is currently revealed) so an in-place
            // note edit never leaves a raw `[[type:…]]` placeholder on the back.
            // Keep the user's typed answer so the recomputed diff still reflects
            // what they entered.
            currentAnswer = showingAnswer
                ? renderedAnswer()
                : Self.stripTypePlaceholders(pristineAnswer)
            if let fresh = try? backend.getCard(cardID: card.card.id) {
                currentFlag = Int(fresh.flags)
            }
            isMarked = (try? backend.isNoteMarked(noteID: card.card.noteID)) ?? isMarked
            refreshDecks()
            refreshUndo()
        } catch {
            status = "Reload error: \(error)"
        }
    }

    /// Replays the current side's audio in sequence (clone of AnkiDroid's
    /// `replayMedia` / Anki's "Replay audio"), restarting from the first clip.
    func replayAudio() {
        cardAudioPlayer.play(currentSideAudio, mediaFolder: mediaFolderURL)
    }

    /// The audio segments of the side currently shown (question or answer), in
    /// play order. Backs the per-segment replay buttons (gated on
    /// `showPlayButtonsOnAudio`) so the user can replay one specific
    /// `[sound:]`/`{{tts}}` clip. Empty when the current side has no audio.
    var currentSideAudio: [CardAudio] {
        showingAnswer ? currentAnswerAudio : currentQuestionAudio
    }

    /// Plays a single audio segment of the current side by index (one of the
    /// per-segment replay buttons), in addition to the autoplay on show/reveal.
    /// Out-of-range indexes are ignored. Clone of AnkiDroid's per-`[sound:]` play
    /// buttons on cards with audio.
    func playAudioSegment(at index: Int) {
        cardAudioPlayer.play(oneOf: currentSideAudio, index: index, mediaFolder: mediaFolderURL)
    }

    /// Stops any card audio (e.g. when leaving the reviewer).
    func stopReviewAudio() {
        cardAudioPlayer.stop()
    }

    /// Reschedules the current card from an Anki due-date spec (a number of days
    /// like `"3"`, a range like `"7-14"`, or `"0"` for today), then advances and
    /// refreshes like the other card actions. Clone of AnkiDroid's reviewer "Set
    /// due date" (`ReviewerViewModel.setDueDate`). Undoable via the toolbar.
    /// A blank spec is a no-op (the prompt was dismissed without input).
    func setReviewerDueDate(_ days: String) {
        guard let backend, let cardID = currentCardID else { return }
        let spec = days.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !spec.isEmpty else { return }
        do {
            _ = try backend.setDueDate(cardIDs: [cardID], days: spec)
            // Rescheduling typically moves the card out of today's queue, so
            // advance to the next card and refresh counts, as bury/suspend do.
            afterCardRemovedFromQueue()
        } catch {
            status = "Set due date error: \(error)"
        }
    }

    // MARK: - Auto-advance scheduling

    /// Pauses (or resumes) auto-advance while a menu, sheet, or prompt is over the
    /// reviewer, so a timer never reveals or grades behind a dialog. The reviewer
    /// view sets this from whether any overlay is presented; resuming reschedules
    /// the timer for the side currently shown.
    func setAutoAdvancePaused(_ paused: Bool) {
        autoAdvancePaused = paused
        if paused { cancelAutoAdvance() } else { scheduleAutoAdvanceForCurrentSide() }
    }

    /// Cancels any pending auto-advance timer.
    func cancelAutoAdvance() {
        autoAdvanceTask?.cancel()
        autoAdvanceTask = nil
    }

    /// (Re)schedules the auto-advance action for the side currently shown, if
    /// auto-advance is on, the reviewer is active and not paused, a card is shown,
    /// and that side's timer (from the deck config) is non-zero.
    ///
    /// The timing and actions come from the CURRENT CARD's deck config (Anki's
    /// `AutoAdvance._load_conf` via `config_dict_for_deck_id`): after the question
    /// shows for `secondsToShowQuestion` it performs `questionAction` (default:
    /// reveal); after the answer shows for `secondsToShowAnswer` it performs
    /// `answerAction` (default: bury). Grading only ever happens on the answer
    /// side, and only when the user has explicitly enabled auto-advance, so a card
    /// is never silently graded otherwise.
    func scheduleAutoAdvanceForCurrentSide() {
        cancelAutoAdvance()
        guard autoAdvanceEnabled, reviewerActive, !autoAdvancePaused,
              !reviewDone, currentCard != nil else { return }
        guard let plan = autoAdvanceConfigForCurrentCard()?.plan(showingAnswer: showingAnswer)
        else { return }
        let onAnswer = showingAnswer
        let nanos = UInt64(max(0, plan.seconds) * 1_000_000_000)
        autoAdvanceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: nanos)
            guard let self, !Task.isCancelled else { return }
            // The side/card must be unchanged since scheduling, and auto-advance
            // still active — otherwise a state change raced the timer.
            guard self.autoAdvanceEnabled, self.reviewerActive, !self.autoAdvancePaused,
                  !self.reviewDone, self.showingAnswer == onAnswer, self.currentCard != nil
            else { return }
            self.performAutoAdvance(plan.action, onAnswer: onAnswer)
        }
    }

    /// Performs a resolved auto-advance action for a side. Grading and burying can
    /// only run from the answer side (`onAnswer`), preserving the safety rule that
    /// a question-side timer never grades — the question action is only ever
    /// reveal or a reminder, but the guard is kept as defence in depth.
    private func performAutoAdvance(_ action: AutoAdvanceAction, onAnswer: Bool) {
        switch action {
        case .showAnswer:
            reveal()
        case .bury:
            guard onAnswer else { return }
            buryCard()
        case .answer(let rating):
            guard onAnswer, showingAnswer else { return }
            rate(rating)
        case .showReminder:
            showAutoAdvanceReminder(onAnswer
                ? "Answer time elapsed"
                : "Question time elapsed")
        }
    }

    /// The current card's auto-advance settings, resolved from the deck the card
    /// belongs to (its home deck when it's in a filtered deck). Memoised for the
    /// current card and cached per deck, so a session doesn't refetch the deck
    /// config for every card. Returns `nil` if there's no card or the config
    /// can't be read (in which case no timer is scheduled).
    private func autoAdvanceConfigForCurrentCard() -> AutoAdvanceConfig? {
        if let config = currentAutoAdvanceConfig { return config }
        guard let backend, let card = currentCard?.card else { return nil }
        let deckID = AutoAdvanceConfig.effectiveDeckID(
            deckID: card.deckID, originalDeckID: card.originalDeckID
        )
        if let cached = autoAdvanceConfigByDeck[deckID] {
            currentAutoAdvanceConfig = cached
            return cached
        }
        guard let config = try? backend.autoAdvanceConfig(forDeckID: deckID) else { return nil }
        autoAdvanceConfigByDeck[deckID] = config
        currentAutoAdvanceConfig = config
        return config
    }

    /// Shows a transient "time elapsed" reminder (the deck's "show reminder"
    /// auto-advance action), auto-clearing after a short delay. Non-grading: the
    /// card is left as-is for the user to act on, matching Anki's tooltip.
    private func showAutoAdvanceReminder(_ message: String) {
        autoAdvanceReminder = message
        autoAdvanceReminderTask?.cancel()
        autoAdvanceReminderTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard let self, !Task.isCancelled else { return }
            self.autoAdvanceReminder = nil
        }
    }

    /// Clears any shown auto-advance reminder and its dismiss timer.
    private func clearAutoAdvanceReminder() {
        autoAdvanceReminderTask?.cancel()
        autoAdvanceReminderTask = nil
        if autoAdvanceReminder != nil { autoAdvanceReminder = nil }
    }

    /// Shared tail for bury/suspend/delete: the current card has left the queue,
    /// so refresh the deck counts and load the next card.
    private func afterCardRemovedFromQueue() {
        refreshDecks()
        loadNext()
    }

    /// Reverts the last undoable action (e.g. the previous answer) and reloads
    /// the queue so the restored card is shown again.
    func undo() {
        guard let backend, canUndo else { return }
        do {
            _ = try backend.undo()
            loadNext()
            Haptics.tap()
        } catch {
            status = "Undo error: \(error)"
            Haptics.error()
        }
    }

    /// Refreshes `canUndo`/`undoName` from the backend's undo status.
    private func refreshUndo() {
        guard let backend else { return }
        if let status = try? backend.undoStatus() {
            undoName = status.undo
            canUndo = !status.undo.isEmpty
        } else {
            undoName = ""
            canUndo = false
        }
    }

    // MARK: - Sync

    /// Loads any saved login from the Keychain on launch (clone of AnkiDroid's
    /// `isLoggedIn()` reading `Prefs.hkey`).
    private func loadLoginState() {
        if let creds = SyncKeychain.load() {
            isLoggedIn = true
            syncUsername = creds.username
            // Reflect the server actually in use (which may be an AnkiWeb shard)
            // without clobbering the user's next-login choice in
            // `preferredSyncServer`. nil endpoint = AnkiWeb default.
            activeSyncServer = creds.endpoint
        }
    }

    /// Persists the user's chosen sync server for the next login (nil/"" =
    /// AnkiWeb) and publishes it. The Settings server picker writes here while
    /// logged out; `login` reads it as the endpoint to authenticate against.
    func setPreferredSyncServer(_ endpoint: String?) {
        let trimmed = endpoint?.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = (trimmed?.isEmpty == false) ? trimmed : nil
        preferredSyncServer = value
        let defaults = UserDefaults.standard
        if let value {
            defaults.set(value, forKey: Self.preferredServerKey)
        } else {
            defaults.removeObject(forKey: Self.preferredServerKey)
        }
    }

    /// Loads the persisted sync server preference at launch.
    private func loadPreferredSyncServer() {
        preferredSyncServer = UserDefaults.standard.string(forKey: Self.preferredServerKey)
    }

    /// Exchanges username/password (+ optional custom server) for a host key and
    /// persists it. Returns true on success. On failure, `loginErrorMessage` is
    /// set for the login sheet. Mirrors AnkiDroid's `LoginViewModel.handleLogin`.
    func login(username: String, password: String, endpoint: String? = nil) async -> Bool {
        guard let backend else { return false }
        loginErrorMessage = nil
        let user = username.trimmingCharacters(in: .whitespacesAndNewlines)
        // Endpoint comes from the Settings server preference unless one is passed
        // explicitly (e.g. the debug auto-login hook). Mirrors getEndpoint().
        let chosen = (endpoint ?? preferredSyncServer)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let serverOrNil = (chosen?.isEmpty == false) ? chosen : nil
        do {
            let auth = try await runDetached {
                try backend.syncLogin(username: user, password: password, endpoint: serverOrNil)
            }
            let resolvedEndpoint = auth.hasEndpoint ? auth.endpoint : serverOrNil
            try SyncKeychain.save(
                SyncCredentials(username: user, hkey: auth.hkey, endpoint: resolvedEndpoint)
            )
            isLoggedIn = true
            syncUsername = user
            // Remember the *chosen* server for next time (not the shard AnkiWeb
            // may resolve to); the resolved endpoint is the one now in use.
            setPreferredSyncServer(serverOrNil)
            activeSyncServer = resolvedEndpoint
            return true
        } catch {
            if let syncError = SyncError(error) {
                loginErrorMessage = syncError.message.isEmpty
                    ? defaultMessage(for: syncError.kind)
                    : syncError.message
            } else {
                loginErrorMessage = "Login failed: \(error)"
            }
            return false
        }
    }

    /// Clears the saved login (clone of AnkiDroid's `updateLogin("", "")`).
    func logout() {
        SyncKeychain.clear()
        isLoggedIn = false
        syncUsername = ""
        // No server is in use once logged out; the picker becomes editable again.
        activeSyncServer = nil
        // Keep `preferredSyncServer` so the next login uses the same server
        // (AnkiDroid likewise keeps the custom sync server preference on logout).
        syncPhase = .idle
    }

    /// Kicks off a sync from a background-spawned task, e.g. right after a
    /// successful login (AnkiDroid offers "Sync now?" after login).
    func startSync() {
        Task { await sync() }
    }

    #if DEBUG
    /// Debug-only testing/automation hook (mirrors the `-startInReview` launch
    /// argument): when launched with `-autoSync 1 -syncUser <u> -syncPass <p>
    /// [-syncServer <url>]`, log in and sync automatically so the flow can be
    /// driven and screenshotted from `simctl`. Excluded from release builds.
    func autoLoginAndSyncIfRequested() {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: "autoSync"),
              let user = defaults.string(forKey: "syncUser"),
              let pass = defaults.string(forKey: "syncPass")
        else { return }
        let server = defaults.string(forKey: "syncServer")
        Task {
            var loggedIn = isLoggedIn
            if !loggedIn {
                loggedIn = await login(username: user, password: pass, endpoint: server)
            }
            if loggedIn { await sync() }
        }
    }

    /// Debug-only automation hook (mirrors the `-startInReview` launch
    /// argument): when launched with `-studySome`, answer a handful of due cards
    /// so the Statistics screen has real review history (Today / Reviews /
    /// Future Due) to render in screenshots. Excluded from release builds.
    func studySomeIfRequested() {
        guard ProcessInfo.processInfo.arguments.contains("-studySome") else { return }
        guard let backend else { return }
        let ratings: [Anki_Scheduler_CardAnswer.Rating] =
            [.good, .easy, .good, .again, .good, .hard, .easy, .good]
        for (index, rating) in ratings.enumerated() {
            guard let card = try? backend.queuedCards().cards.first else { break }
            try? backend.answer(
                card: card, rating: rating, millisecondsTaken: UInt32(800 + index * 250)
            )
        }
        refreshDecks()
        refreshUndo()
    }

    /// Debug-only screenshot hook for the deck-list subdeck collapse feature.
    /// `-demoSubdecks` seeds a nested `Languages` deck tree (Spanish/French, with
    /// Spanish::Verbs) and a couple of cards so counts show, then EXPANDS it;
    /// `-demoSubdecksCollapsed` seeds the same tree but COLLAPSES the parent so
    /// its subdecks are hidden — the two states for the collapse/expand
    /// screenshots. Idempotent (skips re-creating an existing `Languages` tree)
    /// and excluded from release builds.
    func prepareSubdeckDemoIfRequested() {
        let args = ProcessInfo.processInfo.arguments
        let wantExpanded = args.contains("-demoSubdecks")
        let wantCollapsed = args.contains("-demoSubdecksCollapsed")
        guard wantExpanded || wantCollapsed else { return }
        guard let backend else { return }
        let parentName = "Languages"
        do {
            let existing = try backend.deckNames()
            let alreadySeeded = existing.contains {
                $0.name == parentName || $0.name.hasPrefix("\(parentName)::")
            }
            if !alreadySeeded {
                let spanish = try backend.createDeck(name: "\(parentName)::Spanish")
                _ = try backend.createDeck(name: "\(parentName)::French")
                _ = try backend.createDeck(name: "\(parentName)::Spanish::Verbs")
                let notetypes = try backend.notetypeNames()
                if let basic = notetypes.first(where: {
                    $0.name.hasPrefix("Basic") && !$0.name.lowercased().contains("type")
                }) {
                    _ = try backend.addNote(notetypeID: basic.id, fields: ["Hola", "Hello"], deckID: spanish)
                    _ = try backend.addNote(notetypeID: basic.id, fields: ["Gato", "Cat"], deckID: spanish)
                }
            }
            // Set the parent (and, when expanding, the Spanish subdeck) collapse
            // state so the screenshot shows the intended tree.
            let names = try backend.deckNames()
            func deckID(_ full: String) -> Int64? { names.first { $0.name == full }?.id }
            if let parentID = deckID(parentName) {
                try backend.setDeckCollapsed(deckID: parentID, collapsed: wantCollapsed)
            }
            if wantExpanded, let spanishID = deckID("\(parentName)::Spanish") {
                try backend.setDeckCollapsed(deckID: spanishID, collapsed: false)
            }
            refreshDecks()
        } catch {
            status = "Subdeck demo seed error: \(error)"
        }
    }

    /// `-demoBrowserSidebarTree` seeds a nested deck tree (Languages → Spanish →
    /// Verbs, plus French) AND hierarchical tags (`language::spanish::…`,
    /// `grammar::verbs`) so the Card Browser sidebar's collapsible Decks/Tags
    /// outline has real, multi-level content to screenshot. It also primes the
    /// per-node expansion state (the same `@AppStorage` keys the sidebar rows
    /// use) so a nested branch shows already expanded. Idempotent (skips the
    /// re-seed once the tree exists); excluded from release builds.
    func prepareBrowserSidebarDemoIfRequested() {
        guard ProcessInfo.processInfo.arguments.contains("-demoBrowserSidebarTree") else { return }
        guard let backend else { return }
        let parentName = "Languages"
        do {
            let existing = try backend.deckNames()
            let alreadySeeded = existing.contains {
                $0.name == parentName || $0.name.hasPrefix("\(parentName)::")
            }
            if !alreadySeeded {
                let spanish = try backend.createDeck(name: "\(parentName)::Spanish")
                _ = try backend.createDeck(name: "\(parentName)::French")
                _ = try backend.createDeck(name: "\(parentName)::Spanish::Verbs")
                let notetypes = try backend.notetypeNames()
                if let basic = notetypes.first(where: {
                    $0.name.hasPrefix("Basic") && !$0.name.lowercased().contains("type")
                }) {
                    let hola = try backend.addNote(
                        notetypeID: basic.id, fields: ["Hola", "Hello"], deckID: spanish)
                    let gato = try backend.addNote(
                        notetypeID: basic.id, fields: ["Gato", "Cat"], deckID: spanish)
                    // Hierarchical tags so the Tags outline nests too.
                    _ = try backend.addNoteTags(noteIDs: [hola], tags: "language::spanish::greetings")
                    _ = try backend.addNoteTags(
                        noteIDs: [gato], tags: "language::spanish::animals grammar::verbs")
                }
            }
            // Prime the sidebar's expansion state (same UserDefaults keys the
            // deck/tag rows read via @AppStorage) so a nested branch is already
            // open in the screenshot.
            let names = try backend.deckNames()
            func deckID(_ full: String) -> Int64? { names.first { $0.name == full }?.id }
            let defaults = UserDefaults.standard
            // `-demoBrowserSidebarCollapseDecks` collapses the deck subtree so the
            // (also-nested) Tags outline fits on screen for its own screenshot.
            let expandDecks = !ProcessInfo.processInfo.arguments
                .contains("-demoBrowserSidebarCollapseDecks")
            for full in [parentName, "\(parentName)::Spanish"] {
                if let id = deckID(full) {
                    defaults.set(expandDecks, forKey: "cardBrowser.sidebar.deckExpanded.\(id)")
                }
            }
            for path in ["language", "language::spanish", "grammar"] {
                defaults.set(true, forKey: "cardBrowser.sidebar.tagExpanded.\(path)")
            }
            refreshDecks()
        } catch {
            status = "Browser sidebar demo seed error: \(error)"
        }
    }

    /// Debug-only screenshot hooks for the reviewer features. `-demoRemainingCounts`
    /// turns on the remaining-count display; `-demoAudioButtons` turns on the
    /// per-segment play buttons and seeds a `[sound:]` card in its own deck so it
    /// is the first card shown (the file itself can be absent — only the AV tag is
    /// needed for the button to render). Excluded from release builds.
    func prepareReviewerFeatureDemosIfRequested() {
        let args = ProcessInfo.processInfo.arguments
        if args.contains("-demoRemainingCounts") {
            setShowRemainingDueCounts(true)
        }
        if args.contains("-demoAudioButtons") {
            setShowPlayButtonsOnAudio(true)
            guard let backend else { return }
            do {
                let deckID = try backend.createDeck(name: "Audio Demo")
                let notetypes = try backend.notetypeNames()
                if let basic = notetypes.first(where: {
                    $0.name.hasPrefix("Basic") && !$0.name.lowercased().contains("type")
                }) {
                    _ = try backend.addNote(
                        notetypeID: basic.id,
                        fields: ["Listen and repeat [sound:demo.mp3]", "Bonjour"],
                        deckID: deckID
                    )
                }
                selectDeck(id: deckID)
            } catch {
                status = "Audio demo seed error: \(error)"
            }
        }
    }

    /// Debug-only screenshot hook for the Image Occlusion reviewer
    /// (`-demoImageOcclusion`). Ensures an I/O note type exists, draws a small
    /// labeled diagram into the media folder, and seeds one I/O note (building the
    /// occlusion cloze field directly, in Anki's `to-cloze` format) in its own
    /// deck, then selects it so the reviewer opens on the I/O card with masks
    /// drawn. Idempotent (skips if the demo deck exists); excluded from release.
    func prepareImageOcclusionDemoIfRequested() {
        guard ProcessInfo.processInfo.arguments.contains("-demoImageOcclusion") else { return }
        guard let backend else { return }
        let deckName = "Image Occlusion Demo"
        do {
            if let existing = try backend.deckNames().first(where: { $0.name == deckName }) {
                selectDeck(id: existing.id)
                return
            }
            // ImageOcclusionService.addImageOcclusionNotetype (service 37, method
            // 3): adds an I/O note type if none exists. Input is generic Empty.
            _ = try backend.run(service: 37, method: 3, input: Data())
            guard let io = try backend.notetypeNames().first(where: { isImageOcclusionNotetype($0.id) }) else {
                status = "Image occlusion demo: no I/O note type"
                return
            }
            // Draw a diagram and write it into the media folder so the reviewer's
            // media handler can serve it as `<img src="…">`.
            let imageName = "io-demo-diagram.png"
            try FileManager.default.createDirectory(at: mediaFolderURL, withIntermediateDirectories: true)
            try Self.imageOcclusionDemoPNG().write(to: mediaFolderURL.appendingPathComponent(imageName))
            // Two rectangular masks over the two labeled regions, in "hide all"
            // mode (`:oi=1`) so both show on the question side. Format matches
            // ts/routes/image-occlusion/shapes/to-cloze.ts.
            let occlusions = [
                "{{c1::image-occlusion:rect:left=0.08:top=0.15:width=0.38:height=0.22:oi=1}}",
                "{{c2::image-occlusion:rect:left=0.55:top=0.55:width=0.34:height=0.28:oi=1}}",
            ].joined(separator: "<br>") + "<br>"
            let deckID = try backend.createDeck(name: deckName)
            // I/O note type fields, in order: Occlusions, Image, Header, Back Extra, Comments.
            _ = try backend.addNote(
                notetypeID: io.id,
                fields: [occlusions, "<img src=\"\(imageName)\">", "Name the hidden parts", "", ""],
                deckID: deckID
            )
            selectDeck(id: deckID)
        } catch {
            status = "Image occlusion demo seed error: \(error)"
        }
    }

    /// Debug-only screenshot hook for MathJax/LaTeX rendering (`-demoMathJax`).
    /// Seeds one Basic note whose fields contain inline `\(…\)` and display
    /// `\[…\]` math in its own deck, then selects it so the reviewer opens on the
    /// math card. Idempotent; excluded from release builds.
    func prepareMathJaxDemoIfRequested() {
        guard ProcessInfo.processInfo.arguments.contains("-demoMathJax") else { return }
        guard let backend else { return }
        let deckName = "MathJax Demo"
        do {
            if let existing = try backend.deckNames().first(where: { $0.name == deckName }) {
                selectDeck(id: existing.id)
                return
            }
            guard let basic = try backend.notetypeNames().first(where: {
                $0.name.hasPrefix("Basic") && !$0.name.lowercased().contains("type")
            }) else {
                status = "MathJax demo: no Basic note type"
                return
            }
            let deckID = try backend.createDeck(name: deckName)
            let front = "Pythagorean theorem: \\(x^2 + y^2 = z^2\\)"
            let back = "Euler's identity: \\(e^{i\\pi} + 1 = 0\\)"
                + "<br><br>Gaussian integral: \\[\\int_{-\\infty}^{\\infty} e^{-x^2}\\,dx = \\sqrt{\\pi}\\]"
            _ = try backend.addNote(notetypeID: basic.id, fields: [front, back], deckID: deckID)
            selectDeck(id: deckID)
        } catch {
            status = "MathJax demo seed error: \(error)"
        }
    }

    #if canImport(UIKit)
    /// Renders the small labeled diagram used by the Image Occlusion demo, so the
    /// drawn masks visibly cover content in the verification screenshot. The two
    /// masked regions (see `prepareImageOcclusionDemoIfRequested`) sit over the
    /// "Nucleus" and "Mitochondria" boxes.
    private static func imageOcclusionDemoPNG() -> Data {
        let size = CGSize(width: 600, height: 400)
        let format = UIGraphicsImageRendererFormat.default()
        format.opaque = true
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.pngData { ctx in
            let cg = ctx.cgContext
            UIColor(white: 0.97, alpha: 1).setFill()
            cg.fill(CGRect(origin: .zero, size: size))
            ("Cell Diagram" as NSString).draw(
                at: CGPoint(x: 20, y: 14),
                withAttributes: [
                    .font: UIFont.boldSystemFont(ofSize: 26),
                    .foregroundColor: UIColor(white: 0.15, alpha: 1),
                ]
            )
            func box(_ rect: CGRect, _ color: UIColor, _ label: String) {
                color.setFill()
                UIBezierPath(roundedRect: rect, cornerRadius: 10).fill()
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: UIFont.systemFont(ofSize: 18, weight: .semibold),
                    .foregroundColor: UIColor.white,
                ]
                let label = label as NSString
                let textSize = label.size(withAttributes: attrs)
                label.draw(
                    at: CGPoint(x: rect.midX - textSize.width / 2, y: rect.midY - textSize.height / 2),
                    withAttributes: attrs
                )
            }
            // Positions mirror the normalized mask rects above (600×400 canvas).
            box(CGRect(x: 48, y: 60, width: 228, height: 88),
                UIColor(red: 0.20, green: 0.50, blue: 0.80, alpha: 1), "Nucleus")
            box(CGRect(x: 330, y: 60, width: 204, height: 88),
                UIColor(red: 0.30, green: 0.60, blue: 0.35, alpha: 1), "Ribosome")
            box(CGRect(x: 48, y: 220, width: 228, height: 112),
                UIColor(red: 0.55, green: 0.40, blue: 0.70, alpha: 1), "Membrane")
            box(CGRect(x: 330, y: 220, width: 204, height: 112),
                UIColor(red: 0.85, green: 0.45, blue: 0.20, alpha: 1), "Mitochondria")
        }
    }
    #endif
    #endif

    /// Runs a collection sync followed by a media sync, cloning AnkiDroid's
    /// `handleNormalSync`: a normal collection sync, then branching on the
    /// server's `required` verdict into a forced upload/download or a conflict
    /// prompt, and finally a background media sync that we poll to completion.
    func sync() async {
        // Reentrancy guard: programmatic callers (post-login auto-sync, the debug
        // hook) can fire while a sync is already running; a second run would stomp
        // `syncPhase` and double-write the keychain. Bail if one is in flight.
        guard !syncPhase.isActive else { return }
        guard let backend else { return }
        guard let creds = SyncKeychain.load() else {
            showLogin = true
            return
        }
        var auth = Backend.syncAuth(hkey: creds.hkey, endpoint: creds.endpoint)
        syncPhase = .syncing("Checking…")
        do {
            let authForCollection = auth
            let response = try await runDetached {
                try backend.syncCollection(auth: authForCollection, syncMedia: false)
            }
            // The server may hand us a new endpoint (shard) to use going forward.
            // Record it as the in-use endpoint (creds + activeSyncServer), but not
            // as the user's chosen server — an AnkiWeb shard isn't a custom server.
            if response.hasNewEndpoint, !response.newEndpoint.isEmpty {
                auth = Backend.syncAuth(hkey: creds.hkey, endpoint: response.newEndpoint)
                activeSyncServer = response.newEndpoint
                try? SyncKeychain.save(
                    SyncCredentials(username: creds.username, hkey: creds.hkey, endpoint: response.newEndpoint)
                )
            }
            let mediaUsn = response.serverMediaUsn

            switch response.required {
            case .noChanges:
                await mediaPhase(auth: auth, startNew: true)
                syncPhase = .success(
                    successMessage(response.serverMessage.isEmpty ? "Up to date" : response.serverMessage)
                )
            case .fullDownload:
                try await runFullSync(auth: auth, upload: false, mediaUsn: mediaUsn)
            case .fullUpload:
                try await runFullSync(auth: auth, upload: true, mediaUsn: mediaUsn)
            case .fullSync:
                // Collections diverged: ask the user which side to keep.
                pendingConflictAuth = auth
                pendingConflictMediaUsn = mediaUsn
                pendingConflict = true
                syncPhase = .idle
            case .normalSync, .UNRECOGNIZED:
                // sync_collection never returns these as a final state.
                syncPhase = .failed(.init(kind: .other, message: "Unexpected sync state"))
            }
        } catch {
            handleSyncError(error)
        }
        refreshAfterSync()
    }

    /// Resolves a full-sync conflict by replacing one side wholesale, then
    /// syncing media. `upload` keeps this device's collection; otherwise the
    /// server's collection is downloaded. Clone of AnkiDroid's
    /// `handleUpload`/`handleDownload`.
    func resolveConflict(upload: Bool) async {
        pendingConflict = false
        guard let auth = pendingConflictAuth else { return }
        let mediaUsn = pendingConflictMediaUsn
        pendingConflictAuth = nil
        do {
            try await runFullSync(auth: auth, upload: upload, mediaUsn: mediaUsn)
        } catch {
            handleSyncError(error)
        }
        refreshAfterSync()
    }

    /// Cancels a pending full-sync conflict without changing anything.
    func cancelConflict() {
        pendingConflict = false
        pendingConflictAuth = nil
        syncPhase = .idle
    }

    /// Dismisses a terminal success/failure banner.
    func dismissSyncResult() {
        switch syncPhase {
        case .success, .failed: syncPhase = .idle
        default: break
        }
    }

    /// Replaces the whole collection in one direction. The core takes, replaces,
    /// and re-opens the collection itself and (because we pass `serverUsn`) also
    /// starts a background media sync, which we then poll.
    private func runFullSync(auth: Anki_Sync_SyncAuth, upload: Bool, mediaUsn: Int32) async throws {
        guard let backend else { return }
        syncPhase = .syncing(upload ? "Uploading to server…" : "Downloading from server…")
        let authForFull = auth
        // The collection replace is the exclusive critical section: the core
        // takes/replaces/reopens the collection, so block concurrent
        // backend-touching UI for just that window. The media phase below polls
        // a background sync (up to several minutes) while the collection is open,
        // so it stays *outside* the gate to avoid locking the UI for that long.
        // Only hand the core a server media USN (which makes it kick off a
        // background media sync after the full sync) when media syncing is on.
        let fullSyncMediaUsn: Int32? = fetchMediaOnSync ? mediaUsn : nil
        try await runExclusive {
            try await runDetached {
                try backend.fullUploadOrDownload(auth: authForFull, upload: upload, serverUsn: fullSyncMediaUsn)
            }
            if !upload {
                // A full download replaced the whole collection, which may not
                // contain the previously-current deck. Fall back to the Default
                // deck (id 1) so the next "Add note"/selectDeck doesn't target a
                // missing deck — mirroring the colpkg-import replace path. Covers
                // both a server-forced full download and the conflict download.
                currentDeckID = 1
            }
        }
        // full_sync_inner already kicked off media sync; just monitor it.
        await mediaPhase(auth: auth, startNew: false)
        syncPhase = .success(successMessage(upload ? "Uploaded to server" : "Downloaded from server"))
    }

    /// Runs the media-sync phase (clone of AnkiDroid's `SyncMediaWorker` +
    /// `monitorMediaSync`): optionally starting a new media sync, then polling it
    /// to completion. Best-effort: a media failure is recorded in
    /// `lastMediaError` rather than thrown, so it doesn't fail the collection
    /// sync that already succeeded.
    private func mediaPhase(auth: Anki_Sync_SyncAuth, startNew: Bool) async {
        guard let backend else { return }
        // "Synchronize audio and images too" off → collection-only sync; skip
        // starting/polling the media phase. (For a full sync the core may still
        // bundle media when given a server USN, so `runFullSync` also withholds
        // that USN when this is off.)
        guard fetchMediaOnSync else { return }
        lastMediaError = nil
        syncPhase = .mediaSyncing("")
        // Bound the poll loop: a server-side stuck media sync would otherwise
        // leave the banner spinning and the Sync button disabled forever.
        let deadline = Date().addingTimeInterval(Self.mediaSyncTimeout)
        do {
            if startNew {
                let authForMedia = auth
                try await runDetached { try backend.syncMedia(auth: authForMedia) }
            }
            while true {
                if Date() >= deadline {
                    // Non-fatal: the collection sync already succeeded, so just
                    // note the media timeout and stop polling.
                    lastMediaError = "media sync timed out"
                    break
                }
                let status = try await runDetached { try backend.mediaSyncStatus() }
                if !status.active { break }
                let progress = status.progress
                syncPhase = .mediaSyncing(
                    [progress.added, progress.removed, progress.checked]
                        .filter { !$0.isEmpty }
                        .joined(separator: " · ")
                )
                try await Task.sleep(nanoseconds: 150_000_000)
            }
        } catch is CancellationError {
            // A cancelled poll (e.g. the surrounding task was torn down, which
            // makes `Task.sleep` throw) is a clean stop, not a media failure —
            // same as the user-interrupted case below.
            return
        } catch {
            if let syncError = SyncError(error), syncError.kind == .interrupted { return }
            lastMediaError = SyncError(error)?.message ?? "media sync failed"
        }
    }

    /// Builds a success banner message, appending any non-fatal media error.
    private func successMessage(_ base: String) -> String {
        if let mediaError = lastMediaError, !mediaError.isEmpty {
            return "\(base) (media: \(mediaError))"
        }
        return base
    }

    /// Maps a thrown backend error to a terminal `syncPhase`, logging the user
    /// out on auth failure (clone of AnkiDroid catching
    /// `BackendSyncAuthFailedException` then `updateLogin("", "")`).
    private func handleSyncError(_ error: Error) {
        guard let syncError = SyncError(error) else {
            syncPhase = .failed(.init(kind: .other, message: "Sync failed: \(error)"))
            return
        }
        let message = syncError.message.isEmpty
            ? defaultMessage(for: syncError.kind)
            : syncError.message
        switch syncError.kind {
        case .authFailed:
            logout()
            syncPhase = .failed(.init(kind: .auth, message: message))
        case .network:
            syncPhase = .failed(.init(kind: .network, message: message))
        case .serverMessage:
            syncPhase = .failed(.init(kind: .server, message: message))
        case .interrupted:
            syncPhase = .idle
        case .other:
            syncPhase = .failed(.init(kind: .other, message: message))
        }
    }

    /// Refreshes derived UI state after any sync (the collection may have been
    /// replaced by a full download).
    private func refreshAfterSync() {
        refreshDecks()
        refreshUndo()
        loadPreferences()
    }

    private func defaultMessage(for kind: SyncError.Kind) -> String {
        switch kind {
        case .authFailed: return "Authentication failed. Please log in again."
        case .network: return "A network error has occurred."
        case .serverMessage: return "The server reported a problem."
        case .interrupted: return "Sync cancelled."
        case .other: return "Sync failed."
        }
    }

    // MARK: - Preferences (engine-backed)

    /// Loads the collection `Preferences` message (Reviewing / Editing / Backups
    /// sub-messages) into the view-facing snapshots. Read locally (fast
    /// SQLite-backed call), mirroring how AnkiDroid's settings screens populate
    /// their controls from `col.getPreferences()`. All three are loaded together
    /// from one round-trip.
    func loadPreferences() {
        guard let backend else { return }
        do {
            let prefs = try backend.getPreferences()
            schedulingPrefs = SchedulingPrefs(prefs.scheduling)
            reviewingPrefs = ReviewingPrefs(prefs.reviewing)
            editingPrefs = EditingPrefs(prefs.editing)
            backupLimits = BackupLimitsPrefs(prefs.backups)
            preferencesAvailable = true
        } catch {
            preferencesAvailable = false
            status = "Preferences error: \(error)"
        }
    }

    // MARK: Reviewing

    /// "Show next review time above answer buttons" (engine
    /// `reviewing.show_intervals_on_buttons`).
    func setShowIntervalsOnButtons(_ value: Bool) {
        updatePreferences { $0.reviewing.showIntervalsOnButtons = value }
    }

    /// "Show remaining card count" during review (engine
    /// `reviewing.show_remaining_due_counts`).
    func setShowRemainingDueCounts(_ value: Bool) {
        updatePreferences { $0.reviewing.showRemainingDueCounts = value }
    }

    /// "Show play buttons on cards with audio". Stored inverted in the engine as
    /// `reviewing.hide_audio_play_buttons` (as in AnkiDroid).
    func setShowPlayButtonsOnAudio(_ value: Bool) {
        updatePreferences { $0.reviewing.hideAudioPlayButtons = !value }
    }

    /// "Interrupt current audio when answering" (engine
    /// `reviewing.interrupt_audio_when_answering`). Engine-backed so it syncs to
    /// the desktop/AnkiDroid reviewers; the iOS reviewer already cancels prior
    /// audio on each side/card transition.
    func setInterruptAudioWhenAnswering(_ value: Bool) {
        updatePreferences { $0.reviewing.interruptAudioWhenAnswering = value }
    }

    /// "Timebox time limit" in minutes (engine `reviewing.time_limit_secs`,
    /// stored in seconds like Anki desktop; 0 disables the timebox).
    func setTimeboxMinutes(_ minutes: Int) {
        updatePreferences { $0.reviewing.timeLimitSecs = UInt32(max(0, minutes) * 60) }
    }

    // MARK: Scheduling

    /// "Next day starts at" — the hour (0–23) the collection rolls over to the
    /// next day (engine `scheduling.rollover`).
    func setNextDayStartsAt(_ hour: Int) {
        updatePreferences { $0.scheduling.rollover = UInt32(min(max(0, hour), 23)) }
    }

    /// "Learn ahead limit" in minutes (engine `scheduling.learn_ahead_secs`,
    /// stored in seconds like Anki desktop): how far ahead the scheduler will pull
    /// learning cards when nothing else is due.
    func setLearnAheadMinutes(_ minutes: Int) {
        updatePreferences { $0.scheduling.learnAheadSecs = UInt32(max(0, minutes) * 60) }
    }

    // MARK: Editing

    /// "Paste without shift key strips formatting" (engine
    /// `editing.paste_strips_formatting`).
    func setPasteStripsFormatting(_ value: Bool) {
        updatePreferences { $0.editing.pasteStripsFormatting = value }
    }

    /// "Paste clipboard images as PNG" (engine `editing.paste_images_as_png`).
    func setPasteImagesAsPng(_ value: Bool) {
        updatePreferences { $0.editing.pasteImagesAsPng = value }
    }

    /// Default deck behaviour: on = "When adding, default to current deck"; off =
    /// "Change deck depending on note type" (engine
    /// `editing.adding_defaults_to_current_deck`).
    func setAddingDefaultsToCurrentDeck(_ value: Bool) {
        updatePreferences { $0.editing.addingDefaultsToCurrentDeck = value }
    }

    /// "Ignore accents in search (slower)" (engine
    /// `editing.ignore_accents_in_search`).
    func setIgnoreAccentsInSearch(_ value: Bool) {
        updatePreferences { $0.editing.ignoreAccentsInSearch = value }
    }

    /// "Default search text" used as the browser's starting query, e.g.
    /// "deck:current" (engine `editing.default_search_text`).
    func setDefaultSearchText(_ value: String) {
        updatePreferences { $0.editing.defaultSearchText = value }
    }

    /// "Render LaTeX" — whether the editor/reviewer renders `[latex]`/`[$]` math
    /// (engine `editing.render_latex`).
    func setRenderLatex(_ value: Bool) {
        updatePreferences { $0.editing.renderLatex = value }
    }

    // MARK: Backups

    /// "Daily backups to keep" (engine `backups.daily`). Clamped to non-negative.
    func setDailyBackupsToKeep(_ value: Int) {
        updatePreferences { $0.backups.daily = UInt32(max(0, value)) }
    }

    /// "Weekly backups to keep" (engine `backups.weekly`).
    func setWeeklyBackupsToKeep(_ value: Int) {
        updatePreferences { $0.backups.weekly = UInt32(max(0, value)) }
    }

    /// "Monthly backups to keep" (engine `backups.monthly`).
    func setMonthlyBackupsToKeep(_ value: Int) {
        updatePreferences { $0.backups.monthly = UInt32(max(0, value)) }
    }

    /// "Minutes between automatic backups" (engine
    /// `backups.minimum_interval_mins`).
    func setMinutesBetweenBackups(_ value: Int) {
        updatePreferences { $0.backups.minimumIntervalMins = UInt32(max(0, value)) }
    }

    /// Read-modify-write the whole engine `Preferences` message, then re-read so
    /// the UI reflects the persisted truth (clone of AnkiDroid's
    /// `prefs.copy { … }; setPreferences(newPrefs)`). Mutating the fetched
    /// message — rather than building a fresh one — preserves every field the UI
    /// doesn't surface. On failure the reload reverts the control to the engine's
    /// actual value.
    private func updatePreferences(
        _ mutate: (inout Anki_Config_Preferences) -> Void
    ) {
        guard let backend else { return }
        do {
            var prefs = try backend.getPreferences()
            mutate(&prefs)
            _ = try backend.setPreferences(prefs)
        } catch {
            status = "Preferences error: \(error)"
        }
        loadPreferences()
    }

    /// Folder holding `.colpkg` backup snapshots, a `backups` subfolder of the
    /// app's Documents (next to the collection) — matching Anki desktop's
    /// `<profile>/backups`. Created on demand.
    private var backupsFolderURL: URL {
        documentsURL.appendingPathComponent("backups", isDirectory: true)
    }

    /// "Create backup now": writes a forced `.colpkg` snapshot into
    /// `backupsFolderURL` and waits for it to finish, then prunes old backups per
    /// the engine's backup limits. Two-phase like AnkiDroid's `BackendBackups`
    /// (create returns after the initial copy; `awaitBackupCompletion` blocks for
    /// the rest), both run off the main actor so the UI stays responsive.
    func createBackupNow() async {
        guard let backend, !backupInProgress else { return }
        backupInProgress = true
        defer { backupInProgress = false }
        let folder = backupsFolderURL
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let path = folder.path
            try await runDetached {
                _ = try backend.createBackup(backupFolder: path, force: true, waitForCompletion: false)
                try backend.awaitBackupCompletion()
            }
            lastBackupMessage = "Backup created."
        } catch {
            lastBackupMessage = "Backup failed: \(error)"
        }
    }

    // MARK: - Advanced maintenance (AnkiDroid database tools)

    /// Runs "Check database" (fsck): a full integrity/repair pass. Gated behind
    /// `runExclusive` (it holds the backend for a long, collection-wide op) and
    /// dispatched off the main actor. Returns the summary of problems found and
    /// fixed; derived UI state is refreshed since the pass may alter cards/decks.
    func checkDatabase() async throws -> DatabaseCheckSummary {
        guard let backend else { throw NoteEditorError.collectionNotReady }
        let problems = try await runExclusive {
            try await runDetached { try backend.checkDatabase() }
        }
        refreshDecks()
        refreshUndo()
        return DatabaseCheckSummary(problems: problems)
    }

    /// Fetches the "Empty cards" report (notes with cards that render to nothing),
    /// summarized for the confirmation. Read-only, so it runs off the main actor
    /// without the exclusive gate.
    func emptyCardsSummary() async throws -> EmptyCardsSummary {
        guard let backend else { throw NoteEditorError.collectionNotReady }
        let report = try await runDetached { try backend.emptyCardsReport() }
        return EmptyCardsSummary(report)
    }

    /// Deletes the given empty cards (and any notes orphaned by the removal),
    /// returning the number removed. Off the main actor; refreshes counts after.
    @discardableResult
    func deleteEmptyCards(_ cardIDs: [Int64]) async throws -> Int {
        guard let backend else { throw NoteEditorError.collectionNotReady }
        guard !cardIDs.isEmpty else { return 0 }
        let removed = try await runDetached { try backend.removeCards(cardIDs: cardIDs) }
        refreshDecks()
        refreshUndo()
        return removed
    }

    /// Arms a full (one-way) sync on the next sync — AnkiDroid's "Force a
    /// one-way sync" — by bumping the schema modification time. Does NOT sync
    /// immediately (matching AnkiDroid); the next `sync()` performs the full
    /// up/down. Off the main actor; refreshes state since arming discards the
    /// undo/study queues upstream.
    func armFullSync() async throws {
        guard let backend else { throw NoteEditorError.collectionNotReady }
        try await runDetached { try backend.setSchemaModified() }
        refreshDecks()
        refreshUndo()
    }

    /// Whether a full sync is already armed (`scm > ls`), so the UI can show it.
    func isFullSyncArmed() async -> Bool {
        guard let backend else { return false }
        return (try? await runDetached { try backend.schemaChanged() }) ?? false
    }

    /// The `.colpkg` backups on disk (newest first), for "Restore from backup".
    func backupFiles() -> [BackupFile] {
        BackupFile.list(in: backupsFolderURL)
    }

    /// Restores a backup by replacing the whole collection with the chosen
    /// `.colpkg`, reusing the same close→import→reopen flow as a `.colpkg`
    /// import. Destructive — the caller confirms first.
    @discardableResult
    func restoreBackup(_ file: BackupFile) async throws -> ImportOutcome {
        try await importPackage(from: file.url)
    }

    // MARK: - Review reminder rescheduling

    /// Total cards due right now across top-level decks (Anki folds subdeck
    /// counts into their parent), used for the reminder body's "N cards due".
    var totalDueForReminder: Int {
        decks.filter { $0.depth == 0 }
            .reduce(0) { $0 + $1.newCount + $1.learnCount + $1.reviewCount }
    }

    /// Reschedules the daily review reminder with the current due count when it's
    /// enabled (a no-op otherwise). Called when the app backgrounds so the "You
    /// have N cards due" body reflects the latest counts. Never throws/crashes.
    func refreshReviewReminderIfEnabled() {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: ReviewReminders.enabledKey) else { return }
        let hour = defaults.object(forKey: ReviewReminders.hourKey) as? Int
            ?? ReviewReminderSchedule.defaultHour
        let minute = defaults.object(forKey: ReviewReminders.minuteKey) as? Int
            ?? ReviewReminderSchedule.defaultMinute
        let due = totalDueForReminder
        Task { await reviewReminders.schedule(hour: hour, minute: minute, dueCount: due) }
    }

    /// Syncs on app open/close when "Automatically sync on profile open/close" is
    /// on and the user is logged in. A no-op otherwise — in particular it never
    /// pops the login sheet (unlike a manual `sync()`), so an unauthenticated
    /// launch stays quiet. Honours the sync reentrancy guard inside `sync()`.
    func autoSyncIfEnabled() {
        guard autoSyncEnabled, isLoggedIn else { return }
        Task { await sync() }
    }

    // MARK: - Import / Export

    /// Imports a picked `.apkg`/`.colpkg`. Cloning AnkiDroid's import flow:
    /// a `.colpkg` (or the conventional `collection.apkg`) replaces the whole
    /// collection — which requires the collection closed, then reopened — while
    /// any other `.apkg` imports its notes into the open collection.
    ///
    /// The document picker hands back a security-scoped URL that the engine may
    /// not be able to read directly, so we copy it into our temp directory first
    /// (mirroring AnkiDroid copying the import into its cache). Derived UI state
    /// is refreshed on success.
    func importPackage(
        from url: URL,
        apkgOptions: Anki_ImportExport_ImportAnkiPackageOptions? = nil
    ) async throws -> ImportOutcome {
        guard let backend else { throw NoteEditorError.collectionNotReady }
        let isColpkg = Self.isCollectionPackage(url.lastPathComponent)
        let localURL = try copyIntoTemp(url)
        defer { try? FileManager.default.removeItem(at: localURL) }

        let packagePath = localURL.path
        let colPath = collectionURL.path
        let mediaFolder = mediaFolderURL.path
        let mediaDB = mediaDBURL.path

        // Exclusive: a .colpkg replace closes the collection (close→import→reopen
        // window), and even a deck import holds the backend for the whole call, so
        // gate concurrent backend-touching UI for the operation's duration.
        return try await runExclusive {
            let outcome: ImportOutcome
            if isColpkg {
                try await runDetached {
                    // .colpkg replaces the collection file: close, import, reopen.
                    // Tolerate an already-closed collection (e.g. a prior failed
                    // import or a closed handle left it shut) so the replacement
                    // can still be written instead of aborting on a close that
                    // throws.
                    _ = try? backend.closeCollection()
                    do {
                        try backend.importCollectionPackage(
                            colPath: colPath, backupPath: packagePath,
                            mediaFolder: mediaFolder, mediaDB: mediaDB
                        )
                    } catch {
                        // Import failed before swapping the file in; reopen the
                        // unchanged collection so the app isn't left closed.
                        _ = try? backend.openCollection(path: colPath, mediaFolder: mediaFolder, mediaDB: mediaDB)
                        throw error
                    }
                    try backend.openCollection(path: colPath, mediaFolder: mediaFolder, mediaDB: mediaDB)
                }
                // The replaced collection may not contain the previously-current deck.
                currentDeckID = 1
                outcome = .collectionReplaced
            } else {
                // `apkgOptions == nil` uses the backend defaults (a plain
                // shared-deck import); the import options sheet passes an explicit
                // options proto built from the user's selections.
                let result = try await runDetached {
                    try backend.importAnkiPackage(path: packagePath, options: apkgOptions)
                }
                outcome = .deckPackage(result)
            }
            refreshAfterImport()
            return outcome
        }
    }

    /// ImportExportService.getImportAnkiPackagePresets (39, 3). Reads the saved
    /// `.apkg` import options (update conditions, merge note types, with
    /// scheduling / deck presets) from the open collection's config — the values
    /// the import options sheet seeds itself from. Read-only, so it runs off the
    /// main actor without the exclusive-op gate (matching `prepareCsvImport`).
    func importAnkiPackagePresets() async throws -> Anki_ImportExport_ImportAnkiPackageOptions {
        guard let backend else { throw NoteEditorError.collectionNotReady }
        return try await runDetached { try backend.importAnkiPackagePresets() }
    }

    /// Exports a deck (and its subdecks) to a temporary `.apkg`, returning the
    /// file URL for the share sheet. Includes scheduling so the deck transfers
    /// with its progress; `includeMedia` carries referenced media.
    func exportDeck(id: Int64, name: String, includeMedia: Bool) async throws -> URL {
        guard let backend else { throw NoteEditorError.collectionNotReady }
        let outURL = Self.exportFileURL(name: name, ext: "apkg")
        let path = outURL.path
        // Exclusive: the export holds the backend for the whole (possibly long)
        // write, so gate concurrent backend-touching UI for its duration.
        return try await runExclusive {
            _ = try await runDetached {
                try backend.exportAnkiPackage(deckID: id, outPath: path, withMedia: includeMedia)
            }
            return outURL
        }
    }

    /// Exports the whole collection to a temporary `.colpkg`, returning the file
    /// URL for the share sheet. The core takes the collection to export it,
    /// leaving it closed, so we reopen afterwards (AnkiDroid's `reopen()`).
    func exportWholeCollection(includeMedia: Bool) async throws -> URL {
        guard let backend else { throw NoteEditorError.collectionNotReady }
        let outURL = Self.exportFileURL(name: "collection", ext: "colpkg")
        let path = outURL.path
        let colPath = collectionURL.path
        let mediaFolder = mediaFolderURL.path
        let mediaDB = mediaDBURL.path
        // Exclusive: exporting the whole collection takes (closes) it and we
        // reopen afterwards, so gate concurrent backend-touching UI for that
        // close→reopen window.
        return try await runExclusive {
            try await runDetached {
                do {
                    try backend.exportCollectionPackage(outPath: path, includeMedia: includeMedia, legacy: false)
                } catch {
                    _ = try? backend.openCollection(path: colPath, mediaFolder: mediaFolder, mediaDB: mediaDB)
                    throw error
                }
                try backend.openCollection(path: colPath, mediaFolder: mediaFolder, mediaDB: mediaDB)
            }
            return outURL
        }
    }

    // MARK: - CSV / text import

    /// Copies a picked `.csv`/`.tsv`/`.txt` file into the app's temp dir (so the
    /// engine can read it by path) and asks the engine for its `CsvMetadata`
    /// (detected delimiter, columns, preview rows, and a default note-type + deck
    /// + field→column mapping) — the data the CSV import wizard shows. Reading
    /// metadata doesn't mutate the collection, so it isn't gated behind
    /// `runExclusive`. The caller owns the returned temp file and must remove it
    /// when the wizard is dismissed (on import success or cancel); on failure
    /// here it's cleaned up before throwing.
    func prepareCsvImport(
        from url: URL
    ) async throws -> (localURL: URL, metadata: Anki_ImportExport_CsvMetadata) {
        guard let backend else { throw NoteEditorError.collectionNotReady }
        let localURL = try copyIntoTemp(url)
        do {
            let path = localURL.path
            let metadata = try await runDetached { try backend.getCsvMetadata(path: path) }
            return (localURL, metadata)
        } catch {
            try? FileManager.default.removeItem(at: localURL)
            throw error
        }
    }

    /// Re-derives the engine's default CSV metadata/mapping for a chosen note type
    /// / delimiter / is-HTML — what Anki's wizard does when the user changes those
    /// controls (the engine recomputes a sensible default field mapping). Doesn't
    /// mutate the collection.
    func recomputeCsvMetadata(
        path: String,
        delimiter: Anki_ImportExport_CsvMetadata.Delimiter?,
        notetypeID: Int64?,
        deckID: Int64?,
        isHtml: Bool?
    ) async throws -> Anki_ImportExport_CsvMetadata {
        guard let backend else { throw NoteEditorError.collectionNotReady }
        return try await runDetached {
            try backend.getCsvMetadata(
                path: path, delimiter: delimiter, notetypeID: notetypeID,
                deckID: deckID, isHtml: isHtml
            )
        }
    }

    /// Imports the CSV/text file at `path` using the chosen `metadata` (note type,
    /// deck, field/tags column mapping, delimiter, is-HTML, duplicate handling).
    /// Runs inside the exclusive-op gate since it mutates the collection, off the
    /// main actor, and refreshes derived UI state on success. Returns the
    /// add/update/duplicate summary (same shape as an `.apkg` import).
    func importCsv(
        path: String, metadata: Anki_ImportExport_CsvMetadata
    ) async throws -> ImportResult {
        guard let backend else { throw NoteEditorError.collectionNotReady }
        return try await runExclusive {
            let result = try await runDetached {
                try backend.importCsv(path: path, metadata: metadata)
            }
            refreshAfterImport()
            return result
        }
    }

    // MARK: - Notes / cards text (CSV) export

    /// Exports notes to a temporary tab-separated text file, returning the file
    /// URL for the share sheet. `deckID == nil` exports the whole collection;
    /// otherwise it scopes to that deck (and its subdecks). The `with*` toggles
    /// mirror Anki's text-export dialog (keep HTML, include tags/deck/notetype
    /// columns). Gated behind `runExclusive` as it holds the backend for the write.
    func exportNotesText(
        deckID: Int64?,
        name: String,
        withHTML: Bool,
        withTags: Bool,
        withDeck: Bool,
        withNotetype: Bool
    ) async throws -> URL {
        guard let backend else { throw NoteEditorError.collectionNotReady }
        let outURL = Self.exportFileURL(name: deckID == nil ? "All notes" : name, ext: "txt")
        let path = outURL.path
        let limit = Self.exportLimit(deckID: deckID)
        return try await runExclusive {
            _ = try await runDetached {
                try backend.exportNoteCsv(
                    outPath: path, limit: limit, withHtml: withHTML,
                    withTags: withTags, withDeck: withDeck, withNotetype: withNotetype
                )
            }
            return outURL
        }
    }

    /// Exports cards (each card's rendered question/answer) to a temporary
    /// tab-separated text file, returning the file URL for the share sheet. Scope
    /// and gating match `exportNotesText`; `withHTML` keeps the rendered HTML.
    func exportCardsText(deckID: Int64?, name: String, withHTML: Bool) async throws -> URL {
        guard let backend else { throw NoteEditorError.collectionNotReady }
        let outURL = Self.exportFileURL(name: deckID == nil ? "All cards" : name, ext: "txt")
        let path = outURL.path
        let limit = Self.exportLimit(deckID: deckID)
        return try await runExclusive {
            _ = try await runDetached {
                try backend.exportCardCsv(outPath: path, limit: limit, withHtml: withHTML)
            }
            return outURL
        }
    }

    /// An `ExportLimit` for an optional deck scope: a specific deck, or the whole
    /// collection when `deckID` is `nil`.
    private static func exportLimit(deckID: Int64?) -> Anki_ImportExport_ExportLimit {
        if let deckID { return Backend.exportLimit(deckID: deckID) }
        return Backend.wholeCollectionExportLimit()
    }

    /// Clone of AnkiDroid's `ImportUtils.isCollectionPackage`: a `.colpkg`, or the
    /// conventional whole-collection export name `collection.apkg`, is a full
    /// collection import; any other `.apkg` is a note/deck import.
    static func isCollectionPackage(_ filename: String) -> Bool {
        let lower = filename.lowercased()
        return lower.hasSuffix(".colpkg") || lower == "collection.apkg"
    }

    /// Copies a (possibly security-scoped) picked file into the app's temp dir so
    /// the engine can read it by path, preserving the extension. The caller is
    /// responsible for removing the returned file.
    private func copyIntoTemp(_ url: URL) throws -> URL {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let ext = url.pathExtension.isEmpty ? "apkg" : url.pathExtension
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(ext)
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.copyItem(at: url, to: dest)
        return dest
    }

    /// A temp URL for a produced export, named after the deck/collection so the
    /// share sheet offers a sensible filename. Path-unsafe characters in deck
    /// names (`/`, `:`, the `::` subdeck separator) are flattened.
    private static func exportFileURL(name: String, ext: String) -> URL {
        let cleaned = name
            .replacingOccurrences(of: "::", with: "-")
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let base = cleaned.isEmpty ? "Export" : cleaned
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("exports", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(base).appendingPathExtension(ext)
        try? FileManager.default.removeItem(at: url)
        return url
    }

    /// Refreshes derived UI state after an import (the collection's decks, undo
    /// availability, and preferences may all have changed — especially after a
    /// whole-collection replace).
    private func refreshAfterImport() {
        refreshDecks()
        refreshUndo()
        loadPreferences()
    }

    /// Runs a blocking backend call off the main actor so the UI stays
    /// responsive, then resumes on the main actor. Safe because `Backend` is
    /// `Sendable` (the Rust core is internally synchronized).
    private func runDetached<T: Sendable>(
        _ work: @escaping @Sendable () throws -> T
    ) async throws -> T {
        try await Task.detached(priority: .userInitiated, operation: work).value
    }

    /// Marks an *exclusive* backend operation (import / export / full-sync) so the
    /// UI can disable backend-touching controls for its whole duration. The op
    /// spans several FFI calls with the Rust mutex released between them — the
    /// close→reopen / whole-collection-replace window — so treating it as one
    /// critical section keeps a concurrent `@MainActor` backend call from hitting
    /// a closed collection (clone of AnkiDroid serializing behind its collection
    /// lock). `isBackendBusy` is always cleared on completion, including on throw.
    /// The body runs on the main actor; only its inner `runDetached` calls go
    /// off-main.
    private func runExclusive<T>(_ work: () async throws -> T) async rethrows -> T {
        isBackendBusy = true
        defer { isBackendBusy = false }
        return try await work()
    }
}

/// The result of importing a package, for the confirmation shown to the user.
enum ImportOutcome: Equatable {
    /// A `.apkg` was imported into the open collection (with its note summary).
    case deckPackage(ImportResult)
    /// A `.colpkg` replaced the entire collection.
    case collectionReplaced
}

/// Errors surfaced by the note editor's save path before they reach the engine.
enum NoteEditorError: LocalizedError {
    /// The backend hasn't finished opening the collection yet.
    case collectionNotReady

    var errorDescription: String? {
        switch self {
        case .collectionNotReady:
            return "The collection isn’t ready yet. Please try again in a moment."
        }
    }
}

/// Plain, view-facing snapshot of the engine's reviewing preferences. Decouples
/// the SwiftUI layer from the generated protobuf type.
struct ReviewingPrefs: Equatable {
    /// "Show next review time above answer buttons". Defaults to `true` to match
    /// the engine's default (`estTimes`), so interval labels stay visible before
    /// the engine prefs load (or if they can't be read) rather than vanishing.
    var showIntervalsOnButtons = true
    /// "Show remaining card count" during review.
    var showRemainingDueCounts = false
    /// "Show play buttons on cards with audio" (inverse of the engine's
    /// `hide_audio_play_buttons`).
    var showPlayButtonsOnAudio = false
    /// "Interrupt current audio when answering".
    var interruptAudioWhenAnswering = false
    /// "Timebox time limit" in seconds (0 disables). Surfaced in Settings as
    /// minutes, matching Anki desktop.
    var timeLimitSecs = 0

    init() {}

    init(_ reviewing: Anki_Config_Preferences.Reviewing) {
        showIntervalsOnButtons = reviewing.showIntervalsOnButtons
        showRemainingDueCounts = reviewing.showRemainingDueCounts
        showPlayButtonsOnAudio = !reviewing.hideAudioPlayButtons
        interruptAudioWhenAnswering = reviewing.interruptAudioWhenAnswering
        timeLimitSecs = Int(reviewing.timeLimitSecs)
    }

    /// The timebox limit as whole minutes (rounded down), for the Settings
    /// stepper. Anki stores/edits this value in minutes.
    var timeLimitMinutes: Int { timeLimitSecs / 60 }
}

/// Plain, view-facing snapshot of the engine's editing preferences (Anki's
/// Preferences ▸ Editing/Browsing tab). Decouples the SwiftUI layer from the
/// generated protobuf type. Defaults mirror the proto defaults; the engine's
/// real values overwrite them as soon as `loadPreferences()` runs.
struct EditingPrefs: Equatable {
    /// "Paste without shift key strips formatting".
    var pasteStripsFormatting = false
    /// "Paste clipboard images as PNG".
    var pasteImagesAsPng = false
    /// "When adding, default to current deck" (off = "Change deck depending on
    /// note type").
    var addingDefaultsToCurrentDeck = false
    /// "Ignore accents in search (slower)".
    var ignoreAccentsInSearch = false
    /// "Default search text" for the browser (e.g. "deck:current").
    var defaultSearchText = ""
    /// "Render LaTeX" — render `[latex]`/`[$]` math in the editor and reviewer.
    var renderLatex = false

    init() {}

    init(_ editing: Anki_Config_Preferences.Editing) {
        pasteStripsFormatting = editing.pasteStripsFormatting
        pasteImagesAsPng = editing.pasteImagesAsPng
        addingDefaultsToCurrentDeck = editing.addingDefaultsToCurrentDeck
        ignoreAccentsInSearch = editing.ignoreAccentsInSearch
        defaultSearchText = editing.defaultSearchText
        renderLatex = editing.renderLatex
    }
}

/// Plain, view-facing snapshot of the engine's scheduling preferences (Anki's
/// Preferences ▸ Scheduling). Values map 1:1 to `Preferences.Scheduling`;
/// seconds-based fields are surfaced as minutes by the Settings screen.
struct SchedulingPrefs: Equatable {
    /// "Next day starts at" — the rollover hour, 0–23.
    var rollover = 4
    /// "Learn ahead limit" in seconds (surfaced as minutes).
    var learnAheadSecs = 1200

    init() {}

    init(_ scheduling: Anki_Config_Preferences.Scheduling) {
        rollover = Int(scheduling.rollover)
        learnAheadSecs = Int(scheduling.learnAheadSecs)
    }

    /// The learn-ahead limit as whole minutes (rounded down), for the stepper.
    var learnAheadMinutes: Int { learnAheadSecs / 60 }
}

/// Plain, view-facing snapshot of the engine's backup limits (Anki's
/// Preferences ▸ Backups). Counts are surfaced as `Int` for SwiftUI steppers;
/// the store clamps and stores them back as the proto's `UInt32`.
struct BackupLimitsPrefs: Equatable {
    /// "Daily backups to keep".
    var daily = 0
    /// "Weekly backups to keep".
    var weekly = 0
    /// "Monthly backups to keep".
    var monthly = 0
    /// "Minutes between automatic backups".
    var minimumIntervalMins = 0

    init() {}

    init(_ backups: Anki_Config_Preferences.BackupLimits) {
        daily = Int(backups.daily)
        weekly = Int(backups.weekly)
        monthly = Int(backups.monthly)
        minimumIntervalMins = Int(backups.minimumIntervalMins)
    }
}
