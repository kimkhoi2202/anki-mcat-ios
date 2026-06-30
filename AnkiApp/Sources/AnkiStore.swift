import Foundation
import AnkiKit

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

    /// User-selected sync server (nil = default AnkiWeb), edited on the Settings
    /// screen and used as the endpoint when logging in. Mirrors AnkiDroid's
    /// custom sync server preference (read by `getEndpoint()`); persisted in
    /// UserDefaults so it survives launches and logout.
    @Published private(set) var preferredSyncServer: String?

    /// The group's self-hosted sync server (deployed on Fly.io).
    static let mcatSyncServerURL = "https://anki-mcat-sync.fly.dev/"
    private static let preferredServerKey = "preferredSyncServerEndpoint"
    /// Wall-clock cap on the media-sync poll loop, so a stuck server-side media
    /// sync can't spin the banner (and keep the Sync button disabled) forever.
    /// Generous enough for a large first media download; on timeout media is
    /// reported as a non-fatal error and the collection sync still succeeds.
    private static let mediaSyncTimeout: TimeInterval = 300

    // MARK: - Preferences state (engine-backed)

    /// Reviewing preferences read from the engine `Preferences` message, shown as
    /// toggles on the Settings screen. Cloned from AnkiDroid's Appearance/Study
    /// settings, which read/write the same collection prefs.
    @Published var reviewingPrefs = ReviewingPrefs()
    /// Whether `reviewingPrefs` was successfully loaded from the engine (drives
    /// whether the Settings screen shows the reviewing toggles).
    @Published private(set) var preferencesAvailable = false

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

    /// The backend handle for the embedded Anki web pages (Statistics, Card Info,
    /// Deck Options), which call it off the main actor through the `/_anki` bridge.
    /// `Backend` is `Sendable` and internally thread-safe (mutex-guarded).
    var sharedBackend: Backend? { backend }

    /// The current card's audio (sound/video filenames) per side, autoplayed on
    /// front/back and replayed by "Replay audio". Cloned from Anki, which plays
    /// the question side on show and the answer side on reveal.
    private var currentQuestionAudio: [CardAudio] = []
    private var currentAnswerAudio: [CardAudio] = []
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

    func boot() {
        guard backend == nil else { return }
        buildHash = Backend.buildHash()
        let backend: Backend
        do {
            backend = try Backend()
            try openDefaultCollection(backend)
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
        self.backend = backend
        // Seeding demo cards is best-effort; a hiccup must not brick a good open.
        try? seedIfNeeded(backend)
        refreshDecks()
        refreshUndo()
        loadPreferredSyncServer()
        loadLoginState()
        loadPreferences()
        status = "Engine OK"
    }

    /// Opens (or reopens) the collection at the app's standard Documents paths.
    /// Used at launch and to reopen after a `.colpkg` import/export, which close
    /// the collection around replacing/reading the file.
    private func openDefaultCollection(_ backend: Backend) throws {
        try? FileManager.default.createDirectory(at: mediaFolderURL, withIntermediateDirectories: true)
        try backend.openCollection(
            path: collectionURL.path,
            mediaFolder: mediaFolderURL.path,
            mediaDB: mediaDBURL.path
        )
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
            currentDeckID = id
            reviewDone = false
            showingAnswer = false
            currentQuestion = ""
            currentAnswer = ""
            currentCSS = ""
            currentIntervals = []
            currentFlag = 0
            isMarked = false
            currentCard = nil
            loadNext()
        } catch {
            status = "Select error: \(error)"
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

    // MARK: - Card Browser

    /// Runs a Card Browser search and builds its display rows off the main actor
    /// (the per-card render can be heavy for large result sets), then returns
    /// them to the caller on the main actor. Throws so the browser can show an
    /// invalid-search / not-ready message; an empty result is a normal empty list.
    func browserRows(query: String) async throws -> [CardBrowserRow] {
        guard let backend else { throw NoteEditorError.collectionNotReady }
        return try await runDetached { try backend.cardBrowserRows(query: query) }
    }

    /// Suspends or unsuspends the given cards, then refreshes derived state.
    /// Suspended cards leave the study queue, so deck counts are refreshed too.
    func setCardsSuspended(_ cardIDs: [Int64], suspended: Bool) throws {
        guard let backend else { throw NoteEditorError.collectionNotReady }
        if suspended {
            _ = try backend.suspendCards(cardIDs: cardIDs)
        } else {
            try backend.unsuspendCards(cardIDs: cardIDs)
        }
        refreshDecks()
        refreshUndo()
    }

    /// Sets (1...7) or clears (0) the flag color on the given cards.
    func setFlag(_ cardIDs: [Int64], flag: Int) throws {
        guard let backend else { throw NoteEditorError.collectionNotReady }
        _ = try backend.setFlag(cardIDs: cardIDs, flag: flag)
        refreshUndo()
    }

    /// Deletes the notes behind the given cards, then refreshes derived state.
    func deleteNotes(forCards cardIDs: [Int64]) throws {
        guard let backend else { throw NoteEditorError.collectionNotReady }
        _ = try backend.removeNotesForCards(cardIDs: cardIDs)
        refreshDecks()
        refreshUndo()
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

    // MARK: - Filtered Decks

    /// Creates a filtered deck from a search query / limit / order and builds it,
    /// then refreshes the deck list so it appears. The engine selects the new
    /// deck as current, so study pulls from it next. Throws so the caller can
    /// surface a clear message (e.g. an empty match). Clone of AnkiDroid's
    /// create-filtered-deck (custom study) flow.
    @discardableResult
    func createFilteredDeck(
        name: String, search: String, limit: Int,
        order: FilteredDeckOrder, reschedule: Bool
    ) async throws -> FilteredDeckResult {
        guard let backend else { throw NoteEditorError.collectionNotReady }
        // Gathering cards into the filtered deck can be heavy on a large
        // collection, so run it off the main actor to keep the UI responsive.
        let result = try await runDetached {
            try backend.createFilteredDeck(
                name: name, search: search, limit: limit, order: order, reschedule: reschedule
            )
        }
        currentDeckID = result.deckID
        refreshDecks()
        refreshUndo()
        return result
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
    /// `UserDefaults` flag).
    private func seedIfNeeded(_ backend: Backend) throws {
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
        if currentQuestion.isEmpty && !reviewDone { loadNext() }
    }

    func loadNext() {
        guard let backend else { return }
        showingAnswer = false
        do {
            let q = try backend.queuedCards()
            guard let first = q.cards.first else {
                finishReview()
                return
            }
            try present(first)
        } catch {
            status = "Review error: \(error)"
        }
    }

    /// Renders a queued card into the reviewer's published state. Shared by the
    /// normal queue loader and the weak-topics loader so both present cards (and
    /// their answer-button intervals) identically; only the *choice* of card
    /// differs between modes.
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
        currentAnswer = a.text
        // One interval label per button: [again, hard, good, easy].
        // Ignore an unexpected shape rather than mislabeling buttons.
        let intervals = (try? backend.describeNextStates(queued.states)) ?? []
        currentIntervals = intervals.count == 4 ? intervals : []
        // Flag/marked indicators for the new card (mirrors AnkiDroid emitting
        // flagFlow / isMarkedFlow on each card change).
        currentFlag = Int(queued.card.flags)
        isMarked = (try? backend.isNoteMarked(noteID: queued.card.noteID)) ?? false
        cardShownAt = Date()
        refreshUndo()
        // Autoplay the question side's audio, as Anki does on showing a card.
        cardAudioPlayer.play(currentQuestionAudio, mediaFolder: mediaFolderURL)
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
        currentQuestionAudio = []
        currentAnswerAudio = []
        cardAudioPlayer.stop()
        typeAnswer = nil
        typedAnswer = ""
        refreshUndo()
    }

    func reveal() {
        showingAnswer = true
        if let typeAnswer { applyTypeAnswerDiff(typeAnswer) }
        // Autoplay the answer side's audio, as Anki does on flipping to the back.
        cardAudioPlayer.play(currentAnswerAudio, mediaFolder: mediaFolderURL)
    }

    /// Computes the type-in-the-answer diff (typed vs the expected field value)
    /// and substitutes it into the answer HTML where the `[[type:…]]` placeholder
    /// is, mirroring Anki's reviewer.
    private func applyTypeAnswerDiff(_ field: TypeAnswerField) {
        guard let backend, let card = currentCard else { return }
        let expected = expectedFieldValue(field.fieldName, noteID: card.card.noteID) ?? ""
        let diff = (try? backend.compareAnswer(
            expected: expected, typed: typedAnswer, combining: field.combining
        )) ?? ""
        guard !diff.isEmpty else {
            currentAnswer = Self.stripTypePlaceholders(currentAnswer)
            return
        }
        // Escape regex-replacement metacharacters so the diff HTML inserts literally.
        let safe = diff
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "$", with: "\\$")
        currentAnswer = currentAnswer.replacingOccurrences(
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
    /// gesture toggling A → Q). Cheap local state flip; no engine call.
    func flipBack() { showingAnswer = false }

    func rate(_ rating: Anki_Scheduler_CardAnswer.Rating) {
        guard let backend, let card = currentCard else { return }
        let ms = UInt32(min(60_000, Date().timeIntervalSince(cardShownAt) * 1000))
        do {
            try backend.answer(card: card, rating: rating, millisecondsTaken: ms)
            // Only advance once the answer is actually recorded.
            loadNext()
        } catch {
            // A failed answer (DB/scheduler error, stale state) must not be
            // silently dropped while the UI advances as if the review counted.
            // Surface it and keep the current card/answer shown so the user can
            // retry instead of losing study data.
            status = "Answer error: \(error)"
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
            refreshUndo()
        } catch {
            status = "Flag error: \(error)"
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
            refreshUndo()
        } catch {
            status = "Mark error: \(error)"
        }
    }

    /// Buries the current card (manual bury) and advances. Clone of `buryCard`.
    func buryCard() {
        guard let backend, let cardID = currentCardID else { return }
        do {
            _ = try backend.buryCards(cardIDs: [cardID])
            afterCardRemovedFromQueue()
        } catch {
            status = "Bury error: \(error)"
        }
    }

    /// Buries every card of the current card's note and advances. Clone of
    /// `buryNote`.
    func buryNote() {
        guard let backend, let noteID = currentNoteID else { return }
        do {
            _ = try backend.buryNotes(noteIDs: [noteID])
            afterCardRemovedFromQueue()
        } catch {
            status = "Bury error: \(error)"
        }
    }

    /// Suspends the current card and advances. Clone of `suspendCard`.
    func suspendCard() {
        guard let backend, let cardID = currentCardID else { return }
        do {
            _ = try backend.suspendCards(cardIDs: [cardID])
            afterCardRemovedFromQueue()
        } catch {
            status = "Suspend error: \(error)"
        }
    }

    /// Suspends every card of the current card's note and advances. Clone of
    /// `suspendNote`.
    func suspendNote() {
        guard let backend, let noteID = currentNoteID else { return }
        do {
            _ = try backend.suspendNotes(noteIDs: [noteID])
            afterCardRemovedFromQueue()
        } catch {
            status = "Suspend error: \(error)"
        }
    }

    /// Deletes the current card's note (and its cards) and advances. Clone of
    /// `deleteNote`.
    func deleteCurrentNote() {
        guard let backend, let noteID = currentNoteID else { return }
        do {
            _ = try backend.removeNotes(noteIDs: [noteID])
            afterCardRemovedFromQueue()
        } catch {
            status = "Delete error: \(error)"
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
            typedAnswer = ""
            currentQuestion = Self.stripTypePlaceholders(q.text)
            currentAnswer = a.text
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

    /// Replays the current side's audio by forcing the card WebView to reload
    /// (restarting any embedded media). Clone of AnkiDroid's `replayMedia` in
    /// spirit; a native `[sound:]`/AV-tag player is deferred.
    func replayAudio() {
        cardAudioPlayer.play(
            showingAnswer ? currentAnswerAudio : currentQuestionAudio,
            mediaFolder: mediaFolderURL
        )
    }

    /// Stops any card audio (e.g. when leaving the reviewer).
    func stopReviewAudio() {
        cardAudioPlayer.stop()
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
            if let endpoint = creds.endpoint, !endpoint.isEmpty {
                preferredSyncServer = endpoint
            }
        }
    }

    /// Persists the user's chosen sync server (nil/"" = AnkiWeb) and publishes it.
    /// The Settings server picker writes here; `login` reads it as the endpoint.
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
            setPreferredSyncServer(resolvedEndpoint)
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
            // The server may hand us a new endpoint to use going forward.
            if response.hasNewEndpoint, !response.newEndpoint.isEmpty {
                auth = Backend.syncAuth(hkey: creds.hkey, endpoint: response.newEndpoint)
                setPreferredSyncServer(response.newEndpoint)
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
        if !upload {
            // A full download replaced the whole collection, which may not
            // contain the previously-current deck. Fall back to the Default deck
            // (id 1) so the next "Add note"/selectDeck doesn't target a missing
            // deck — mirroring the colpkg-import replace path. Covers both a
            // server-forced full download and the conflict-resolution download.
            currentDeckID = 1
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

    /// Loads the reviewing preferences from the engine `Preferences` message.
    /// Read locally (fast SQLite-backed call), mirroring how AnkiDroid's settings
    /// screens populate their toggles from `col.getPreferences()`.
    func loadPreferences() {
        guard let backend else { return }
        do {
            reviewingPrefs = ReviewingPrefs(try backend.getPreferences().reviewing)
            preferencesAvailable = true
        } catch {
            preferencesAvailable = false
            status = "Preferences error: \(error)"
        }
    }

    /// "Show next review time above answer buttons" (engine
    /// `reviewing.show_intervals_on_buttons`).
    func setShowIntervalsOnButtons(_ value: Bool) {
        updateReviewing { $0.showIntervalsOnButtons = value }
    }

    /// "Show remaining card count" during review (engine
    /// `reviewing.show_remaining_due_counts`).
    func setShowRemainingDueCounts(_ value: Bool) {
        updateReviewing { $0.showRemainingDueCounts = value }
    }

    /// "Show play buttons on cards with audio". Stored inverted in the engine as
    /// `reviewing.hide_audio_play_buttons` (as in AnkiDroid).
    func setShowPlayButtonsOnAudio(_ value: Bool) {
        updateReviewing { $0.hideAudioPlayButtons = !value }
    }

    /// Read-modify-write a single reviewing preference through the engine, then
    /// re-read so the UI reflects the persisted truth (clone of AnkiDroid's
    /// `prefs.copy { reviewing = ... }; setPreferences(newPrefs)`). On failure the
    /// reload reverts the toggle to the engine's actual value.
    private func updateReviewing(
        _ mutate: (inout Anki_Config_Preferences.Reviewing) -> Void
    ) {
        guard let backend else { return }
        do {
            var prefs = try backend.getPreferences()
            mutate(&prefs.reviewing)
            _ = try backend.setPreferences(prefs)
        } catch {
            status = "Preferences error: \(error)"
        }
        loadPreferences()
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
    func importPackage(from url: URL) async throws -> ImportOutcome {
        guard let backend else { throw NoteEditorError.collectionNotReady }
        let isColpkg = Self.isCollectionPackage(url.lastPathComponent)
        let localURL = try copyIntoTemp(url)
        defer { try? FileManager.default.removeItem(at: localURL) }

        let packagePath = localURL.path
        let colPath = collectionURL.path
        let mediaFolder = mediaFolderURL.path
        let mediaDB = mediaDBURL.path

        let outcome: ImportOutcome
        if isColpkg {
            try await runDetached {
                // .colpkg replaces the collection file: close, import, reopen.
                // Tolerate an already-closed collection (e.g. a prior failed
                // import or a closed handle left it shut) so the replacement can
                // still be written instead of aborting on a close that throws.
                try? backend.closeCollection()
                do {
                    try backend.importCollectionPackage(
                        colPath: colPath, backupPath: packagePath,
                        mediaFolder: mediaFolder, mediaDB: mediaDB
                    )
                } catch {
                    // Import failed before swapping the file in; reopen the
                    // unchanged collection so the app isn't left closed.
                    try? backend.openCollection(path: colPath, mediaFolder: mediaFolder, mediaDB: mediaDB)
                    throw error
                }
                try backend.openCollection(path: colPath, mediaFolder: mediaFolder, mediaDB: mediaDB)
            }
            // The replaced collection may not contain the previously-current deck.
            currentDeckID = 1
            outcome = .collectionReplaced
        } else {
            let result = try await runDetached { try backend.importAnkiPackage(path: packagePath) }
            outcome = .deckPackage(result)
        }
        refreshAfterImport()
        return outcome
    }

    /// Exports a deck (and its subdecks) to a temporary `.apkg`, returning the
    /// file URL for the share sheet. Includes scheduling so the deck transfers
    /// with its progress; `includeMedia` carries referenced media.
    func exportDeck(id: Int64, name: String, includeMedia: Bool) async throws -> URL {
        guard let backend else { throw NoteEditorError.collectionNotReady }
        let outURL = Self.exportFileURL(name: name, ext: "apkg")
        let path = outURL.path
        _ = try await runDetached {
            try backend.exportAnkiPackage(deckID: id, outPath: path, withMedia: includeMedia)
        }
        return outURL
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
        try await runDetached {
            do {
                try backend.exportCollectionPackage(outPath: path, includeMedia: includeMedia, legacy: false)
            } catch {
                try? backend.openCollection(path: colPath, mediaFolder: mediaFolder, mediaDB: mediaDB)
                throw error
            }
            try backend.openCollection(path: colPath, mediaFolder: mediaFolder, mediaDB: mediaDB)
        }
        return outURL
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
    /// "Show next review time above answer buttons".
    var showIntervalsOnButtons = false
    /// "Show remaining card count" during review.
    var showRemainingDueCounts = false
    /// "Show play buttons on cards with audio" (inverse of the engine's
    /// `hide_audio_play_buttons`).
    var showPlayButtonsOnAudio = false

    init() {}

    init(_ reviewing: Anki_Config_Preferences.Reviewing) {
        showIntervalsOnButtons = reviewing.showIntervalsOnButtons
        showRemainingDueCounts = reviewing.showRemainingDueCounts
        showPlayButtonsOnAudio = !reviewing.hideAudioPlayButtons
    }
}
