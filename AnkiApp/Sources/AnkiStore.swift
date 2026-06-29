import Foundation
import AnkiKit

@MainActor
final class AnkiStore: ObservableObject {
    @Published var buildHash = ""
    @Published var status = "Starting…"
    /// Decks shown on the Home screen, flattened from the backend deck tree
    /// with per-deck new/learning/review counts.
    @Published var decks: [DeckTreeEntry] = []

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

    /// Custom server endpoint from the stored credentials (nil = default AnkiWeb).
    private var savedEndpoint: String?
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

    /// Media folder backing `<img src="...">` resolution in the reviewer.
    /// Matches the folder passed to `openCollection` in `boot()`.
    var mediaFolderURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("collection.media")
    }

    func boot() {
        guard backend == nil else { return }
        buildHash = Backend.buildHash()
        do {
            let backend = try Backend()
            self.backend = backend
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let mediaFolder = mediaFolderURL
            try? FileManager.default.createDirectory(at: mediaFolder, withIntermediateDirectories: true)
            try backend.openCollection(
                path: docs.appendingPathComponent("collection.anki2").path,
                mediaFolder: mediaFolder.path,
                mediaDB: docs.appendingPathComponent("collection.media.db2").path
            )
            try seedIfNeeded(backend)
            refreshDecks()
            refreshUndo()
            loadLoginState()
            status = "Engine OK"
        } catch {
            status = "Error: \(error)"
        }
    }

    /// Reload the deck list and its counts (e.g. after returning from review).
    func refreshDecks() {
        guard let backend else { return }
        do {
            decks = try backend.deckTree()
        } catch {
            status = "Deck list error: \(error)"
        }
    }

    /// Select `id` as the current deck (so the scheduler scopes study to it and
    /// its subdecks), reset reviewer state, and load the first queued card.
    func selectDeck(id: Int64) {
        guard let backend else { return }
        do {
            try backend.setCurrentDeck(id: id)
            reviewDone = false
            showingAnswer = false
            currentQuestion = ""
            currentAnswer = ""
            currentCSS = ""
            currentIntervals = []
            currentCard = nil
            loadNext()
        } catch {
            status = "Select error: \(error)"
        }
    }

    private func seedIfNeeded(_ backend: Backend) throws {
        let key = "seeded_v1"
        if UserDefaults.standard.bool(forKey: key) { return }
        guard let basic = try backend.notetypeNames().first(where: { $0.name.hasPrefix("Basic") }) else { return }
        let cards: [(String, String)] = [
            ("What is the powerhouse of the cell?", "The mitochondria"),
            ("Which ion's gradient drives ATP synthase?", "The proton (H⁺) gradient"),
            ("Normal resting membrane potential of a neuron?", "About −70 mV"),
            ("Enzyme that unwinds DNA at the replication fork?", "Helicase"),
            ("Henderson–Hasselbalch: pH = ?", "pKa + log([A⁻]/[HA])"),
        ]
        for (q, a) in cards {
            _ = try backend.addNote(notetypeID: basic.id, fields: [q, a], deckID: 1)
        }
        UserDefaults.standard.set(true, forKey: key)
    }

    func startReview() {
        if currentQuestion.isEmpty && !reviewDone { loadNext() }
    }

    func loadNext() {
        guard let backend else { return }
        showingAnswer = false
        do {
            let q = try backend.queuedCards()
            guard let first = q.cards.first else {
                currentCard = nil
                reviewDone = true
                currentQuestion = ""
                currentAnswer = ""
                currentCSS = ""
                currentIntervals = []
                refreshUndo()
                return
            }
            reviewDone = false
            currentCard = first
            currentOrdinal = Int(first.card.templateIdx)
            let rendered = try backend.renderCard(cardID: first.card.id)
            currentQuestion = rendered.question
            currentAnswer = rendered.answer
            currentCSS = rendered.css
            // One interval label per button: [again, hard, good, easy].
            // Ignore an unexpected shape rather than mislabeling buttons.
            let intervals = (try? backend.describeNextStates(first.states)) ?? []
            currentIntervals = intervals.count == 4 ? intervals : []
            cardShownAt = Date()
            refreshUndo()
        } catch {
            status = "Review error: \(error)"
        }
    }

    func reveal() { showingAnswer = true }

    func rate(_ rating: Anki_Scheduler_CardAnswer.Rating) {
        guard let backend, let card = currentCard else { return }
        let ms = UInt32(min(60_000, Date().timeIntervalSince(cardShownAt) * 1000))
        try? backend.answer(card: card, rating: rating, millisecondsTaken: ms)
        loadNext()
    }

    /// Reverts the last undoable action (e.g. the previous answer) and reloads
    /// the queue so the restored card is shown again.
    func undo() {
        guard let backend, canUndo else { return }
        do {
            _ = try backend.undo()
            loadNext()
        } catch {
            status = "Undo error: \(error)"
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
            savedEndpoint = creds.endpoint
        }
    }

    /// Exchanges username/password (+ optional custom server) for a host key and
    /// persists it. Returns true on success. On failure, `loginErrorMessage` is
    /// set for the login sheet. Mirrors AnkiDroid's `LoginViewModel.handleLogin`.
    func login(username: String, password: String, endpoint: String?) async -> Bool {
        guard let backend else { return false }
        loginErrorMessage = nil
        let user = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let server = endpoint?.trimmingCharacters(in: .whitespacesAndNewlines)
        let serverOrNil = (server?.isEmpty == false) ? server : nil
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
            savedEndpoint = resolvedEndpoint
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
        savedEndpoint = nil
        syncPhase = .idle
    }

    /// Kicks off a sync from a background-spawned task, e.g. right after a
    /// successful login (AnkiDroid offers "Sync now?" after login).
    func startSync() {
        Task { await sync() }
    }

    /// Testing/automation hook (mirrors the existing `-startInReview` launch
    /// argument): when launched with `-autoSync 1 -syncUser <u> -syncPass <p>
    /// [-syncServer <url>]`, log in and sync automatically so the flow can be
    /// driven and screenshotted from `simctl`. No-op in normal use.
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

    /// Runs a collection sync followed by a media sync, cloning AnkiDroid's
    /// `handleNormalSync`: a normal collection sync, then branching on the
    /// server's `required` verdict into a forced upload/download or a conflict
    /// prompt, and finally a background media sync that we poll to completion.
    func sync() async {
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
            // The server may hand us a new endpoint to use going forward.
            if response.hasNewEndpoint, !response.newEndpoint.isEmpty {
                auth = Backend.syncAuth(hkey: creds.hkey, endpoint: response.newEndpoint)
                savedEndpoint = response.newEndpoint
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
        try await runDetached {
            try backend.fullUploadOrDownload(auth: authForFull, upload: upload, serverUsn: mediaUsn)
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
        lastMediaError = nil
        syncPhase = .mediaSyncing("")
        do {
            if startNew {
                let authForMedia = auth
                try await runDetached { try backend.syncMedia(auth: authForMedia) }
            }
            while true {
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

    /// Runs a blocking backend call off the main actor so the UI stays
    /// responsive, then resumes on the main actor. Safe because `Backend` is
    /// `Sendable` (the Rust core is internally synchronized).
    private func runDetached<T: Sendable>(
        _ work: @escaping @Sendable () throws -> T
    ) async throws -> T {
        try await Task.detached(priority: .userInitiated, operation: work).value
    }
}
