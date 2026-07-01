import Foundation
import XCTest
@testable import AnkiKit

final class AnkiKitTests: XCTestCase {
    /// Opens a backend on a fresh, temporary collection.
    private func freshCollection() throws -> Backend {
        try openCollection(in: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString))
    }

    /// Opens a backend on a collection rooted at `dir` (created if needed), so the
    /// caller knows the on-disk paths — used by the `.colpkg` round-trip, which
    /// must close, replace, and reopen the same collection files.
    private func openCollection(in dir: URL) throws -> Backend {
        let backend = try Backend()
        let mediaFolder = dir.appendingPathComponent("collection.media")
        try FileManager.default.createDirectory(at: mediaFolder, withIntermediateDirectories: true)
        try backend.openCollection(
            path: dir.appendingPathComponent("collection.anki2").path,
            mediaFolder: mediaFolder.path,
            mediaDB: dir.appendingPathComponent("collection.media.db2").path
        )
        return backend
    }

    private func basicNotetypeID(_ backend: Backend) throws -> Int64 {
        let notetypes = try backend.notetypeNames()
        let basic = try XCTUnwrap(
            notetypes.first(where: { $0.name.hasPrefix("Basic") }),
            "fresh collection should ship a Basic notetype"
        )
        return basic.id
    }

    func testBuildHash() {
        let hash = Backend.buildHash()
        print("buildHash:", hash)
        XCTAssertFalse(hash.isEmpty, "buildHash should be non-empty")
    }

    func testNotetypeCSS() throws {
        let backend = try freshCollection()
        let css = try backend.notetypeCSS(notetypeID: try basicNotetypeID(backend))
        print("notetype css:", css)
        XCTAssertFalse(css.isEmpty, "notetype CSS should be non-empty")
        XCTAssertTrue(css.contains(".card"), "notetype CSS should target the .card element")
    }

    func testDescribeNextStatesAndUndo() throws {
        let backend = try freshCollection()
        let notetypeID = try basicNotetypeID(backend)
        _ = try backend.addNote(notetypeID: notetypeID, fields: ["Front", "Back"], deckID: 1)

        let queued = try backend.queuedCards()
        let card = try XCTUnwrap(queued.cards.first, "the added card should be queued")

        // describe_next_states: one interval label per answer button.
        let labels = try backend.describeNextStates(card.states)
        print("interval labels:", labels)
        XCTAssertEqual(labels.count, 4, "expected [again, hard, good, easy]")
        XCTAssertTrue(labels.allSatisfy { !$0.isEmpty }, "interval labels should be non-empty")

        // Answering is undoable; undo restores the card to the queue.
        try backend.answer(card: card, rating: .good, millisecondsTaken: 1000)
        XCTAssertFalse(try backend.undoStatus().undo.isEmpty, "answering should be undoable")

        _ = try backend.undo()
        let requeued = try backend.queuedCards()
        XCTAssertFalse(requeued.cards.isEmpty, "undo should restore the answered card")
    }

    /// `getPreferences`/`setPreferences` round-trip through the real engine
    /// (ConfigService, service 9, methods 9/10). Flipping reviewing booleans,
    /// writing them, then re-reading proves both the service/method indices and
    /// that the change persists in the collection.
    func testPreferencesRoundTrip() throws {
        let backend = try freshCollection()

        let original = try backend.getPreferences()
        let flippedIntervals = !original.reviewing.showIntervalsOnButtons
        let flippedDueCounts = !original.reviewing.showRemainingDueCounts
        let flippedHideAudio = !original.reviewing.hideAudioPlayButtons

        var updated = original
        updated.reviewing.showIntervalsOnButtons = flippedIntervals
        updated.reviewing.showRemainingDueCounts = flippedDueCounts
        updated.reviewing.hideAudioPlayButtons = flippedHideAudio
        _ = try backend.setPreferences(updated)

        let readBack = try backend.getPreferences()
        XCTAssertEqual(readBack.reviewing.showIntervalsOnButtons, flippedIntervals,
                       "showIntervalsOnButtons should persist through the engine")
        XCTAssertEqual(readBack.reviewing.showRemainingDueCounts, flippedDueCounts,
                       "showRemainingDueCounts should persist through the engine")
        XCTAssertEqual(readBack.reviewing.hideAudioPlayButtons, flippedHideAudio,
                       "hideAudioPlayButtons should persist through the engine")
    }

    func testOpenCollectionAndListDecks() throws {
        let backend = try Backend()

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let mediaFolder = dir.appendingPathComponent("collection.media")
        try FileManager.default.createDirectory(at: mediaFolder, withIntermediateDirectories: true)

        let colPath = dir.appendingPathComponent("collection.anki2").path
        let mediaDB = dir.appendingPathComponent("collection.media.db2").path

        try backend.openCollection(path: colPath, mediaFolder: mediaFolder.path, mediaDB: mediaDB)

        let decks = try backend.deckNames()
        print("decks:", decks.map { $0.name })
        XCTAssertTrue(decks.contains { $0.name == "Default" }, "fresh collection should have a Default deck")
    }

    // MARK: - Sync

    /// `syncAuth` builds the proto with the right fields, treating an empty
    /// endpoint as "unset" (i.e. default AnkiWeb).
    func testSyncAuthBuilder() {
        let withEndpoint = Backend.syncAuth(hkey: "abc", endpoint: "http://localhost:8080/")
        XCTAssertEqual(withEndpoint.hkey, "abc")
        XCTAssertTrue(withEndpoint.hasEndpoint)
        XCTAssertEqual(withEndpoint.endpoint, "http://localhost:8080/")

        let noEndpoint = Backend.syncAuth(hkey: "abc", endpoint: "")
        XCTAssertEqual(noEndpoint.hkey, "abc")
        XCTAssertFalse(noEndpoint.hasEndpoint, "empty endpoint should be left unset")
    }

    /// `syncStatus` resolves entirely offline when the collection has unsynced
    /// changes — a fresh, never-synced collection reports FULL_SYNC (its schema
    /// post-dates the zero last-sync stamp) without any network round-trip.
    func testSyncStatusOfflineForFreshCollection() throws {
        let backend = try freshCollection()
        let resp = try backend.syncStatus(auth: Backend.syncAuth(hkey: "dummy"))
        print("sync status:", resp.required)
        XCTAssertEqual(resp.required, .fullSync,
                       "a fresh collection has never synced, so a full sync is required")
    }

    /// `SyncError` decodes the backend's protobuf `BackendError` and maps its
    /// `kind` to the UI-facing classification used to drive error handling.
    func testSyncErrorClassification() throws {
        func decode(_ kind: Anki_Backend_BackendError.Kind, _ message: String) throws -> SyncError {
            var backendError = Anki_Backend_BackendError()
            backendError.kind = kind
            backendError.message = message
            let wrapped = AnkiError.backendError(try backendError.serializedData())
            return try XCTUnwrap(SyncError(wrapped))
        }

        XCTAssertEqual(try decode(.syncAuthError, "bad auth").kind, .authFailed)
        XCTAssertEqual(try decode(.networkError, "offline").kind, .network)
        XCTAssertEqual(try decode(.syncServerMessage, "msg").kind, .serverMessage)
        XCTAssertEqual(try decode(.interrupted, "").kind, .interrupted)
        XCTAssertEqual(try decode(.dbError, "boom").kind, .other)
        XCTAssertEqual(try decode(.syncAuthError, "bad auth").message, "bad auth")

        // A non-backend error is not a SyncError.
        XCTAssertNil(SyncError(AnkiError.openBackendFailed))
    }

    /// Logging in against an unreachable endpoint exercises the real `sync_login`
    /// RPC and the error-decoding path: it must throw a decodable backend error
    /// that is *not* misclassified as an auth failure (it never reached a server).
    func testSyncLoginUnreachableEndpointThrows() throws {
        let backend = try Backend()
        do {
            _ = try backend.syncLogin(
                username: "test", password: "test", endpoint: "http://127.0.0.1:1/"
            )
            XCTFail("login to a closed port should throw")
        } catch {
            let syncError = try XCTUnwrap(SyncError(error), "expected a decodable backend error")
            XCTAssertNotEqual(syncError.kind, .authFailed,
                              "an unreachable server is a network error, not an auth failure")
        }
    }

    /// `SyncCredentials` round-trips through JSON (the form persisted in the
    /// Keychain), preserving a nil endpoint as "default server".
    func testSyncCredentialsCodableRoundTrip() throws {
        let custom = SyncCredentials(username: "u", hkey: "k", endpoint: "http://localhost:8080/")
        let encoded = try JSONEncoder().encode(custom)
        XCTAssertEqual(try JSONDecoder().decode(SyncCredentials.self, from: encoded), custom)

        let defaultServer = SyncCredentials(username: "u", hkey: "k")
        XCTAssertNil(defaultServer.endpoint)
        let encoded2 = try JSONEncoder().encode(defaultServer)
        XCTAssertEqual(try JSONDecoder().decode(SyncCredentials.self, from: encoded2), defaultServer)
    }

    func testDeckTreeAndSetCurrentDeck() throws {
        let backend = try Backend()

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let mediaFolder = dir.appendingPathComponent("collection.media")
        try FileManager.default.createDirectory(at: mediaFolder, withIntermediateDirectories: true)

        let colPath = dir.appendingPathComponent("collection.anki2").path
        let mediaDB = dir.appendingPathComponent("collection.media.db2").path

        try backend.openCollection(path: colPath, mediaFolder: mediaFolder.path, mediaDB: mediaDB)

        let tree = try backend.deckTree()
        print("deckTree:", tree.map { $0.name })
        XCTAssertTrue(tree.contains { $0.name == "Default" }, "deckTree should include the Default deck")

        // Default deck always has id 1; selecting it should not throw.
        XCTAssertNoThrow(try backend.setCurrentDeck(id: 1))
    }

    // MARK: - Note add/edit

    /// `notetypeFields` returns the notetype's field names in ordinal order, so
    /// the editor's labels line up with a note's `fields`. The Basic notetype's
    /// fields are `Front`/`Back` (matches the core's own service test).
    func testNotetypeFieldsAreOrdered() throws {
        let backend = try freshCollection()
        let fields = try backend.notetypeFields(notetypeID: try basicNotetypeID(backend))
        print("notetype fields:", fields)
        XCTAssertEqual(fields, ["Front", "Back"], "Basic notetype has ordered Front/Back fields")
    }

    /// `getNote` round-trips an added note's notetype, field values, and tags —
    /// the data the editor loads to populate its inputs in EDIT mode.
    func testGetNoteReturnsFieldsTagsAndNotetype() throws {
        let backend = try freshCollection()
        let notetypeID = try basicNotetypeID(backend)
        let nid = try backend.addNote(
            notetypeID: notetypeID, fields: ["Q", "A"], deckID: 1, tags: ["t1", "t2"]
        )

        let note = try backend.getNote(noteID: nid)
        XCTAssertEqual(note.id, nid)
        XCTAssertEqual(note.notetypeID, notetypeID)
        XCTAssertEqual(note.fields, ["Q", "A"], "fields should round-trip in order")
        XCTAssertEqual(note.tags, ["t1", "t2"], "tags should round-trip")
    }

    /// `updateNote` persists edited fields and tags (read-modify-write through
    /// `update_notes`), and records an undo entry so the edit is reversible —
    /// matching AnkiDroid saving an edited note.
    func testUpdateNotePersistsFieldsAndTags() throws {
        let backend = try freshCollection()
        let notetypeID = try basicNotetypeID(backend)
        let nid = try backend.addNote(notetypeID: notetypeID, fields: ["Q", "A"], deckID: 1)

        try backend.updateNote(noteID: nid, fields: ["Q2", "A2"], tags: ["edited"])

        let note = try backend.getNote(noteID: nid)
        XCTAssertEqual(note.fields, ["Q2", "A2"], "edited fields should persist")
        XCTAssertEqual(note.tags, ["edited"], "edited tags should persist")
        XCTAssertEqual(note.notetypeID, notetypeID, "editing fields must not change the notetype")
        XCTAssertFalse(try backend.undoStatus().undo.isEmpty, "editing a note should be undoable")
    }

    // MARK: - Card Browser

    /// `searchCards` resolves Anki search syntax to card ids: an empty query
    /// returns every card, and a `deck:`/field query narrows the results — the
    /// search powering the browser's results list.
    func testSearchCardsResolvesQueryToCardIDs() throws {
        let backend = try freshCollection()
        let notetypeID = try basicNotetypeID(backend)
        _ = try backend.addNote(notetypeID: notetypeID, fields: ["Apple", "Fruit"], deckID: 1)
        _ = try backend.addNote(notetypeID: notetypeID, fields: ["Beta", "Greek"], deckID: 1)

        let all = try backend.searchCards(query: "")
        XCTAssertEqual(all.count, 2, "empty query should return every card")

        let byDeck = try backend.searchCards(query: "deck:Default")
        XCTAssertEqual(byDeck.count, 2, "both cards live in the Default deck")

        let byField = try backend.searchCards(query: "Apple")
        XCTAssertEqual(byField.count, 1, "only one card contains 'Apple'")

        // An invalid search string (a misplaced `and` operator) surfaces as a
        // backend error, which the browser shows as an invalid-search message.
        XCTAssertThrowsError(try backend.searchCards(query: "and")) { error in
            guard case AnkiError.backendError = error else {
                return XCTFail("expected a backend error for an invalid query")
            }
        }
    }

    /// `cardBrowserRows(cardIDs:)` assembles the display rows the list renders —
    /// the windowed page fetch: resolve ids first, then build a row per id from a
    /// single browser-row call (state derived from the row's color). With the
    /// default columns it returns the engine-stripped question/answer snippet and
    /// the deck name as the ordered cells, plus the default (unflagged,
    /// unsuspended) state for a fresh card.
    func testCardBrowserRowReturnsSnippetDeckAndState() throws {
        let backend = try freshCollection()
        let notetypeID = try basicNotetypeID(backend)
        let nid = try backend.addNote(notetypeID: notetypeID, fields: ["Front Q", "Back A"], deckID: 1)

        let ids = try backend.searchCards(query: "")
        let rows = try backend.cardBrowserRows(cardIDs: ids)
        let row = try XCTUnwrap(rows.first, "the added card should produce a browser row")
        // Default columns are question / answer / deck, so the cells line up.
        XCTAssertEqual(row.cells.count, 3, "default config yields three cells")
        XCTAssertTrue(row.cell(0).contains("Front Q"), "cell 0 (question) should show the front")
        XCTAssertTrue(row.cell(1).contains("Back A"), "cell 1 (answer) should show the back")
        XCTAssertEqual(row.cell(2), "Default", "cell 2 (deck) is the Default deck")
        XCTAssertEqual(row.flag, 0, "a new card has no flag")
        XCTAssertFalse(row.suspended, "a new card is not suspended")
        // The owning note id (used to open the editor) is resolved on demand via
        // getCard rather than carried on every row, so verify that linkage here.
        XCTAssertEqual(try backend.getCard(cardID: row.id).noteID, nid,
                       "the row's card should resolve back to its note")
    }

    // MARK: - Card Browser: configurable columns

    /// `allBrowserColumns` (SearchService 29, 6) lists the engine's selectable
    /// columns with display labels and sort capability — the source for the
    /// column picker and sort menu. The default question/answer/deck keys are
    /// present, every column has a non-empty label, and at least one column is
    /// sortable (so the sort menu is never empty).
    func testAllBrowserColumnsListsSelectableColumns() throws {
        let backend = try freshCollection()
        let columns = try backend.allBrowserColumns()
        XCTAssertFalse(columns.isEmpty, "the engine should offer selectable columns")

        let keys = Set(columns.map(\.key))
        for expected in ["question", "answer", "deck"] {
            XCTAssertTrue(keys.contains(expected), "columns should include '\(expected)'")
        }
        XCTAssertTrue(columns.allSatisfy { !$0.label.isEmpty }, "every column has a display label")
        XCTAssertTrue(columns.contains { $0.sortable }, "at least one column should be sortable")
    }

    /// `cardBrowserRows(cardIDs:columns:)` honors an arbitrary column set and
    /// order: requesting `[deck, question]` returns those two cells in that
    /// order, proving the rows are generalized from the hardcoded three.
    func testCardBrowserRowsHonorConfiguredColumnsAndOrder() throws {
        let backend = try freshCollection()
        let notetypeID = try basicNotetypeID(backend)
        _ = try backend.addNote(notetypeID: notetypeID, fields: ["Front Q", "Back A"], deckID: 1)

        let ids = try backend.searchCards(query: "")
        let rows = try backend.cardBrowserRows(cardIDs: ids, columns: ["deck", "question"])
        let row = try XCTUnwrap(rows.first, "the added card should produce a browser row")
        XCTAssertEqual(row.cells.count, 2, "two configured columns yield two cells")
        XCTAssertEqual(row.cell(0), "Default", "cell 0 should be the deck (first configured column)")
        XCTAssertTrue(row.cell(1).contains("Front Q"), "cell 1 should be the question (second column)")
    }

    // MARK: - Card Browser: tap-to-sort

    /// A non-default sort reorders the ids: with two notes whose sort fields are
    /// "Apple"/"Banana", ascending sort-field order differs from descending, and
    /// descending is exactly the reverse — proving the `BrowserSort` is applied to
    /// `browserCardIDs` and that direction matters. (Creation order is Banana
    /// then Apple, so the sort is doing real work, not echoing insertion order.)
    func testNonDefaultSortOrdersIDsDifferently() throws {
        let backend = try freshCollection()
        let notetypeID = try basicNotetypeID(backend)
        _ = try backend.addNote(notetypeID: notetypeID, fields: ["Banana", "B"], deckID: 1)
        _ = try backend.addNote(notetypeID: notetypeID, fields: ["Apple", "A"], deckID: 1)

        let ascending = try backend.browserCardIDs(
            query: "", sort: BrowserSort(column: "noteFld", reverse: false))
        let descending = try backend.browserCardIDs(
            query: "", sort: BrowserSort(column: "noteFld", reverse: true))

        XCTAssertEqual(ascending.count, 2, "both cards should be returned")
        XCTAssertNotEqual(ascending, descending, "reversing the sort must change the order")
        XCTAssertEqual(descending, ascending.reversed(), "descending is the ascending order reversed")

        // Sanity-check the ascending direction is actually by sort field: the
        // first id's note should be "Apple".
        let firstNoteID = try backend.getCard(cardID: try XCTUnwrap(ascending.first)).noteID
        XCTAssertEqual(try backend.getNote(noteID: firstNoteID).fields.first, "Apple",
                       "ascending sort-field order should put 'Apple' first")
    }

    // MARK: - Card Browser: find & replace

    /// `findAndReplace` (SearchService 29, 5) replaces literal text across a
    /// note's fields, returns the number of notes changed, and is undoable —
    /// the browser's Find & Replace. With no field name it touches all fields.
    func testFindAndReplaceChangesFieldAndIsUndoable() throws {
        let backend = try freshCollection()
        let notetypeID = try basicNotetypeID(backend)
        let nid = try backend.addNote(notetypeID: notetypeID, fields: ["Hello world", "world"], deckID: 1)

        let changed = try backend.findAndReplace(
            noteIDs: [nid], search: "world", replacement: "there")
        XCTAssertEqual(changed, 1, "the one note should be changed")

        let note = try backend.getNote(noteID: nid)
        XCTAssertEqual(note.fields[0], "Hello there", "all-fields replace updates the front")
        XCTAssertEqual(note.fields[1], "there", "all-fields replace updates the back too")
        XCTAssertFalse(try backend.undoStatus().undo.isEmpty, "find & replace should be undoable")
    }

    /// `findAndReplace` scoped to a single field by name changes only that field,
    /// leaving the other untouched — the "in: <field>" option of the dialog.
    func testFindAndReplaceFieldScopedLeavesOtherFields() throws {
        let backend = try freshCollection()
        let notetypeID = try basicNotetypeID(backend)
        let nid = try backend.addNote(notetypeID: notetypeID, fields: ["cat", "cat"], deckID: 1)

        let changed = try backend.findAndReplace(
            noteIDs: [nid], search: "cat", replacement: "dog", fieldName: "Front")
        XCTAssertEqual(changed, 1, "the note should be changed")

        let note = try backend.getNote(noteID: nid)
        XCTAssertEqual(note.fields[0], "dog", "the named field (Front) should be replaced")
        XCTAssertEqual(note.fields[1], "cat", "the other field (Back) should be untouched")
    }

    /// `findAndReplace` with `regex: true` applies a regular expression with
    /// capture-group replacement (`$1`), matching desktop/AnkiDroid's regex mode.
    func testFindAndReplaceRegexUsesCaptureGroups() throws {
        let backend = try freshCollection()
        let notetypeID = try basicNotetypeID(backend)
        let nid = try backend.addNote(notetypeID: notetypeID, fields: ["abc123", "B"], deckID: 1)

        _ = try backend.findAndReplace(
            noteIDs: [nid], search: #"(\d+)"#, replacement: "[$1]", regex: true)
        XCTAssertEqual(try backend.getNote(noteID: nid).fields[0], "abc[123]",
                       "the regex capture group should be wrapped in brackets")
    }

    /// `searchNotes` (SearchService 29, 2) resolves a search to NOTE ids (the
    /// "all matching notes" Find & Replace scope): a reversed note's two cards
    /// collapse to a single note id.
    func testSearchNotesResolvesToNoteIDs() throws {
        let backend = try freshCollection()
        let notetypes = try backend.notetypeNames()
        let reversed = try XCTUnwrap(
            notetypes.first { $0.name == "Basic (and reversed card)" },
            "fresh collection ships the reversed Basic note type"
        )
        let nid = try backend.addNote(notetypeID: reversed.id, fields: ["Q", "A"], deckID: 1)

        XCTAssertEqual(try backend.searchCards(query: "").count, 2, "the reversed note has two cards")
        XCTAssertEqual(try backend.searchNotes(query: ""), [nid],
                       "the two sibling cards collapse to one matching note id")
    }

    /// `allFieldNames` returns the union of field names across note types — the
    /// Find & Replace "in field" candidates. A fresh collection's Basic types
    /// contribute Front/Back.
    func testAllFieldNamesUnionsNotetypeFields() throws {
        let backend = try freshCollection()
        let names = try backend.allFieldNames()
        XCTAssertTrue(names.contains("Front"), "Basic note types contribute a Front field")
        XCTAssertTrue(names.contains("Back"), "Basic note types contribute a Back field")
        XCTAssertEqual(Set(names).count, names.count, "field names should be de-duplicated")
    }

    // MARK: - Card Browser: notes / cards mode

    /// The `browserTableShowNotesMode` config (which drives whether
    /// `browser_row_for_id` treats an id as a card or a note) defaults to cards
    /// mode and round-trips through `setBrowserNotesMode`.
    func testBrowserNotesModeConfigRoundTrips() throws {
        let backend = try freshCollection()
        XCTAssertFalse(try backend.getConfigBool(.browserTableShowNotesMode),
                       "a fresh collection defaults to cards mode")
        try backend.setBrowserNotesMode(true)
        XCTAssertTrue(try backend.getConfigBool(.browserTableShowNotesMode),
                      "notes mode should persist")
        try backend.setBrowserNotesMode(false)
        XCTAssertFalse(try backend.getConfigBool(.browserTableShowNotesMode),
                       "switching back to cards mode should persist")
    }

    /// Notes mode collapses a note's sibling cards into a single row: a reversed
    /// note (two cards) plus a basic note (one card) yields three *card* rows but
    /// two *note* rows, and `browserRows(…mode: .notes)` builds one row per note
    /// id — so notes mode returns fewer/equal rows than cards mode.
    func testBrowserNotesModeReturnsFewerRowsThanCards() throws {
        let backend = try freshCollection()
        let reversed = try XCTUnwrap(
            try backend.notetypeNames().first { $0.name == "Basic (and reversed card)" },
            "fresh collection ships the reversed Basic note type"
        )
        _ = try backend.addNote(notetypeID: reversed.id, fields: ["Q", "A"], deckID: 1)
        _ = try backend.addNote(notetypeID: try basicNotetypeID(backend),
                                fields: ["Front", "Back"], deckID: 1)

        let cardIDs = try backend.browserRowIDs(query: "", sort: .default, mode: .cards)
        let noteIDs = try backend.browserRowIDs(query: "", sort: .default, mode: .notes)
        XCTAssertEqual(cardIDs.count, 3, "reversed note (2 cards) + basic note (1 card) = 3 cards")
        XCTAssertEqual(noteIDs.count, 2, "the same content collapses to 2 notes")
        XCTAssertLessThanOrEqual(noteIDs.count, cardIDs.count,
                                 "notes mode never returns more rows than cards mode")

        // Notes-mode rows build one row per note id (the engine renders the
        // note's first card + note-level cells).
        let rows = try backend.browserRows(
            ids: noteIDs, columns: Backend.defaultBrowserColumns, mode: .notes)
        XCTAssertEqual(rows.count, 2, "one browser row per note in notes mode")
        XCTAssertTrue(rows.allSatisfy { !$0.cells.isEmpty }, "each notes-mode row has cells")
    }

    /// Notes-mode bulk/preview id resolution: a reversed note expands to its two
    /// cards (`cardIDs(forNoteIDs:)`, used by notes-mode card actions), and
    /// `firstCardID(ofNote:)` returns one of them (used by notes-mode Preview /
    /// Card Info).
    func testNotesModeCardResolution() throws {
        let backend = try freshCollection()
        let reversed = try XCTUnwrap(
            try backend.notetypeNames().first { $0.name == "Basic (and reversed card)" }
        )
        let nid = try backend.addNote(notetypeID: reversed.id, fields: ["Q", "A"], deckID: 1)

        let cards = try backend.cardIDs(forNoteIDs: [nid])
        XCTAssertEqual(cards.count, 2, "the reversed note expands to its two cards")
        let first = try XCTUnwrap(try backend.firstCardID(ofNote: nid))
        XCTAssertTrue(cards.contains(first), "the note's first card is one of its cards")
    }

    // MARK: - Card Browser: preview

    /// `cardPreview` renders a card's question and answer (reusing the reviewer's
    /// render path) and carries the notetype CSS and template ordinal — the data
    /// the browser Preview sheet shows read-only.
    func testCardPreviewRendersFrontBackAndCSS() throws {
        let backend = try freshCollection()
        let notetypeID = try basicNotetypeID(backend)
        _ = try backend.addNote(notetypeID: notetypeID,
                                fields: ["Capital of France", "Paris"], deckID: 1)
        let cardID = try XCTUnwrap(try backend.searchCards(query: "").first)

        let preview = try backend.cardPreview(cardID: cardID)
        XCTAssertTrue(preview.question.contains("Capital of France"),
                      "the preview front should render the question")
        XCTAssertTrue(preview.answer.contains("Paris"),
                      "the preview back should render the answer")
        XCTAssertTrue(preview.css.contains(".card"),
                      "the preview should carry the notetype CSS")
        XCTAssertEqual(preview.ordinal, 0, "a Basic card is template ordinal 0")
    }

    // MARK: - Card Browser: filter sidebar (tags + saved searches)

    /// `allTags` lists every tag used in the collection — the sidebar's Tags
    /// section. Tags added to a note show up.
    func testAllTagsListsCollectionTags() throws {
        let backend = try freshCollection()
        let nid = try backend.addNote(notetypeID: try basicNotetypeID(backend),
                                      fields: ["Q", "A"], deckID: 1)
        _ = try backend.addNoteTags(noteIDs: [nid], tags: "geography capital")

        let tags = try backend.allTags()
        XCTAssertTrue(tags.contains("geography"), "an added tag should be listed")
        XCTAssertTrue(tags.contains("capital"), "all added tags should be listed")
    }

    /// Saved searches round-trip through the `savedFilters` config: a fresh
    /// collection has none, saving adds them (sorted case-insensitively by name),
    /// saving an existing name overwrites it, and removing deletes it — the
    /// browser sidebar's Saved Searches store.
    func testSavedSearchesRoundTrip() throws {
        let backend = try freshCollection()
        XCTAssertTrue(backend.savedSearches().isEmpty,
                      "a fresh collection has no saved searches")

        try backend.saveSearch(name: "Suspended", query: "is:suspended")
        try backend.saveSearch(name: "Hard", query: "tag:hard")
        let saved = backend.savedSearches()
        XCTAssertEqual(saved.map(\.name), ["Hard", "Suspended"],
                       "saved searches come back sorted case-insensitively by name")
        XCTAssertEqual(saved.first { $0.name == "Hard" }?.query, "tag:hard",
                       "the saved query round-trips")

        // Saving an existing name overwrites its query, not adds a duplicate.
        try backend.saveSearch(name: "Hard", query: "tag:difficult")
        XCTAssertEqual(backend.savedSearches().count, 2, "overwrite keeps the count at two")
        XCTAssertEqual(backend.savedSearches().first { $0.name == "Hard" }?.query, "tag:difficult",
                       "the overwritten query is stored")

        try backend.removeSavedSearch(name: "Hard")
        XCTAssertEqual(backend.savedSearches().map(\.name), ["Suspended"],
                       "removing deletes exactly that saved search")
    }

    /// Suspending then unsuspending a card flips its `suspended` state (read back
    /// through the browser row), and suspending is undoable — matching
    /// AnkiDroid's browser suspend/unsuspend toggle.
    func testSuspendAndUnsuspendCards() throws {
        let backend = try freshCollection()
        let notetypeID = try basicNotetypeID(backend)
        _ = try backend.addNote(notetypeID: notetypeID, fields: ["Q", "A"], deckID: 1)
        let cardID = try XCTUnwrap(try backend.searchCards(query: "").first)

        let suspended = try backend.suspendCards(cardIDs: [cardID])
        XCTAssertEqual(suspended, 1, "one card should be suspended")
        XCTAssertTrue(try backend.cardBrowserRow(cardID: cardID).suspended, "card should read as suspended")
        XCTAssertFalse(try backend.undoStatus().undo.isEmpty, "suspending should be undoable")

        try backend.unsuspendCards(cardIDs: [cardID])
        XCTAssertFalse(try backend.cardBrowserRow(cardID: cardID).suspended, "card should no longer be suspended")
    }

    /// `setFlag` sets and clears a card's flag color, visible on the browser row.
    func testSetFlagSetsAndClears() throws {
        let backend = try freshCollection()
        let notetypeID = try basicNotetypeID(backend)
        _ = try backend.addNote(notetypeID: notetypeID, fields: ["Q", "A"], deckID: 1)
        let cardID = try XCTUnwrap(try backend.searchCards(query: "").first)

        XCTAssertEqual(try backend.setFlag(cardIDs: [cardID], flag: 1), 1, "one card flagged")
        XCTAssertEqual(try backend.cardBrowserRow(cardID: cardID).flag, 1, "flag should be red (1)")

        _ = try backend.setFlag(cardIDs: [cardID], flag: 0)
        XCTAssertEqual(try backend.cardBrowserRow(cardID: cardID).flag, 0, "flag should be cleared")
    }

    /// `removeNotesForCards` deletes the notes behind the given cards, so a
    /// follow-up search no longer finds them — the browser's delete action.
    func testRemoveNotesForCardsDeletes() throws {
        let backend = try freshCollection()
        let notetypeID = try basicNotetypeID(backend)
        _ = try backend.addNote(notetypeID: notetypeID, fields: ["Doomed", "Card"], deckID: 1)
        let cardID = try XCTUnwrap(try backend.searchCards(query: "").first)

        let removed = try backend.removeNotesForCards(cardIDs: [cardID])
        XCTAssertEqual(removed, 1, "one note should be removed")
        XCTAssertTrue(try backend.searchCards(query: "").isEmpty, "the card should be gone after delete")
    }

    // MARK: - Card Browser bulk actions (multi-select)

    /// `setDeck` (CardsService, service 5, method 3) moves the selected cards to a
    /// target deck — the browser's bulk "Change deck" — and the move is undoable.
    /// Read back through `getCard(cardID:).deckID`, mirroring AnkiDroid's
    /// `col.setDeck(cardIds, deckId)`.
    func testSetDeckMovesSelectedCards() throws {
        let backend = try freshCollection()
        let notetypeID = try basicNotetypeID(backend)
        _ = try backend.addNote(notetypeID: notetypeID, fields: ["Q1", "A1"], deckID: 1)
        _ = try backend.addNote(notetypeID: notetypeID, fields: ["Q2", "A2"], deckID: 1)
        let cardIDs = try backend.searchCards(query: "")
        XCTAssertEqual(cardIDs.count, 2, "two cards start in the Default deck")

        let targetDeck = try backend.createDeck(name: "Moved")
        let moved = try backend.setDeck(cardIDs: cardIDs, deckID: targetDeck)
        XCTAssertEqual(moved, 2, "both selected cards should move")

        for cardID in cardIDs {
            XCTAssertEqual(try backend.getCard(cardID: cardID).deckID, targetDeck,
                           "each card should now live in the target deck")
        }
        XCTAssertEqual(try backend.searchCards(query: "deck:Moved").count, 2,
                       "both cards should be found in the new deck")
        XCTAssertFalse(try backend.undoStatus().undo.isEmpty, "changing deck should be undoable")
    }

    /// `addTags`/`removeTags` (card-id wrappers over TagsService 45,7 / 45,8)
    /// bulk add then remove a tag across the notes behind a card selection. With
    /// a two-card (reversed) note, BOTH card ids collapse to one note via
    /// `noteIDs(forCardIDs:)`, so the tag lands once — the browser's bulk
    /// add/remove tags. Read back through `getNote(noteID:).tags`.
    func testBulkAddAndRemoveTagsByCardIDs() throws {
        let backend = try freshCollection()
        let notetypes = try backend.notetypeNames()
        let reversed = try XCTUnwrap(
            notetypes.first { $0.name == "Basic (and reversed card)" },
            "fresh collection ships the reversed Basic note type"
        )
        let nid = try backend.addNote(notetypeID: reversed.id, fields: ["Q", "A"], deckID: 1)
        let cardIDs = try backend.searchCards(query: "")
        XCTAssertEqual(cardIDs.count, 2, "a reversed note produces two cards")

        // Both sibling card ids resolve to the single owning note.
        XCTAssertEqual(try backend.noteIDs(forCardIDs: cardIDs), [nid],
                       "sibling cards collapse to one note id")

        let changed = try backend.addTags(cardIDs: cardIDs, tags: "marked hard")
        XCTAssertEqual(changed, 1, "the one underlying note is tagged once, not per card")
        let tagged = try backend.getNote(noteID: nid).tags
        XCTAssertTrue(tagged.contains("hard"), "the added tag should be present")
        XCTAssertTrue(tagged.contains("marked"), "multiple space-separated tags should all be added")
        XCTAssertFalse(try backend.undoStatus().undo.isEmpty, "adding tags should be undoable")

        _ = try backend.removeTags(cardIDs: cardIDs, tags: "hard")
        let afterRemove = try backend.getNote(noteID: nid).tags
        XCTAssertFalse(afterRemove.contains("hard"), "the removed tag should be gone")
        XCTAssertTrue(afterRemove.contains("marked"), "untouched tags should remain")
    }

    /// `setMarked` (card-id wrapper) bulk-marks then unmarks the notes behind a
    /// selection by toggling the `marked` tag — the browser's bulk Mark/Unmark.
    /// Verified via `isNoteMarked`.
    func testBulkSetMarkedByCardIDs() throws {
        let backend = try freshCollection()
        let notetypeID = try basicNotetypeID(backend)
        let nid1 = try backend.addNote(notetypeID: notetypeID, fields: ["Q1", "A1"], deckID: 1)
        let nid2 = try backend.addNote(notetypeID: notetypeID, fields: ["Q2", "A2"], deckID: 1)
        let cardIDs = try backend.searchCards(query: "")

        XCTAssertEqual(try backend.setMarked(cardIDs: cardIDs, marked: true), 2, "both notes marked")
        XCTAssertTrue(try backend.isNoteMarked(noteID: nid1), "first note should be marked")
        XCTAssertTrue(try backend.isNoteMarked(noteID: nid2), "second note should be marked")

        _ = try backend.setMarked(cardIDs: cardIDs, marked: false)
        XCTAssertFalse(try backend.isNoteMarked(noteID: nid1), "first note should be unmarked")
        XCTAssertFalse(try backend.isNoteMarked(noteID: nid2), "second note should be unmarked")
    }

    /// `buryCards` (SchedulerService 13,14 mode BURY_USER) buries an entire
    /// selection — the browser's bulk Bury — removing them all from the study
    /// queue. Complements the single-card reviewer test with a multi-card op.
    func testBulkBuryCardsLeavesQueue() throws {
        let backend = try freshCollection()
        let notetypeID = try basicNotetypeID(backend)
        for i in 0..<3 {
            _ = try backend.addNote(notetypeID: notetypeID, fields: ["BQ\(i)", "BA\(i)"], deckID: 1)
        }
        let cardIDs = try backend.searchCards(query: "")
        XCTAssertEqual(cardIDs.count, 3, "three cards start queued")

        let buried = try backend.buryCards(cardIDs: cardIDs)
        XCTAssertEqual(buried, 3, "all three selected cards should be buried")
        XCTAssertTrue(try backend.queuedCards().cards.isEmpty, "buried cards should leave the queue")
        XCTAssertFalse(try backend.undoStatus().undo.isEmpty, "burying should be undoable")
    }

    // MARK: - Deck management

    /// `createDeck` adds a normal deck (new_deck + add_deck), `renameDeck`
    /// changes its name in place, and `removeDecks` deletes it (and its cards) —
    /// the create / rename / delete flow behind AnkiDroid's DeckPicker. The deck
    /// is observed through `deckNames()`, and adding a note to it proves it's a
    /// real, usable deck.
    func testCreateRenameRemoveDeck() throws {
        let backend = try freshCollection()
        let notetypeID = try basicNotetypeID(backend)

        let deckID = try backend.createDeck(name: "Spanish")
        XCTAssertGreaterThan(deckID, 0, "a created deck should have a real id")
        XCTAssertTrue(
            try backend.deckNames().contains { $0.id == deckID && $0.name == "Spanish" },
            "the new deck should appear in the deck list"
        )

        try backend.renameDeck(id: deckID, name: "Spanish Verbs")
        let renamed = try backend.deckNames().first { $0.id == deckID }
        XCTAssertEqual(renamed?.name, "Spanish Verbs", "the deck should keep its id but change name")

        // Put a card in the deck so the delete reports the card it removes
        // (remove_decks returns the card count, not the deck count).
        _ = try backend.addNote(notetypeID: notetypeID, fields: ["Q", "A"], deckID: deckID)
        let removedCards = try backend.removeDecks(ids: [deckID])
        XCTAssertEqual(removedCards, 1, "deleting the deck removes its one card")
        XCTAssertFalse(
            try backend.deckNames().contains { $0.id == deckID },
            "the deck should be gone after delete"
        )
    }

    /// A created deck reports the default preset limits (20 new / 200 reviews),
    /// and `setDeckLimits` persists new values that read back through `deckLimits`
    /// — the get/set behind the deck-options new/day & reviews/day controls.
    /// Setting is undoable (update_deck_configs records an undo entry).
    func testDeckLimitsGetSetRoundTrip() throws {
        let backend = try freshCollection()
        let deckID = try backend.createDeck(name: "Limits")

        let defaults = try backend.deckLimits(deckID: deckID)
        XCTAssertEqual(defaults.newPerDay, Backend.defaultNewCardsPerDay,
                       "a deck with no override falls back to the preset new/day default")
        XCTAssertEqual(defaults.reviewsPerDay, Backend.defaultReviewsPerDay,
                       "a deck with no override falls back to the preset reviews/day default")

        try backend.setDeckLimits(deckID: deckID, newPerDay: 30, reviewsPerDay: 150)

        let updated = try backend.deckLimits(deckID: deckID)
        XCTAssertEqual(updated.newPerDay, 30, "new/day override should persist")
        XCTAssertEqual(updated.reviewsPerDay, 150, "reviews/day override should persist")
        XCTAssertFalse(try backend.undoStatus().undo.isEmpty, "changing limits should be undoable")
    }

    /// `setDeckLimits` clamps out-of-range values to the engine's 0…9999 window
    /// (`ensure_u32_valid`), so a wildly large input is stored capped rather than
    /// rejected.
    func testDeckLimitsClampLargeValues() throws {
        let backend = try freshCollection()
        let deckID = try backend.createDeck(name: "Clamp")

        try backend.setDeckLimits(deckID: deckID, newPerDay: 100_000, reviewsPerDay: -5)

        let limits = try backend.deckLimits(deckID: deckID)
        XCTAssertEqual(limits.newPerDay, 9999, "an over-large new/day should clamp to 9999")
        XCTAssertEqual(limits.reviewsPerDay, 0, "a negative reviews/day should clamp to 0")
    }

    /// `setDeckLimits` edits the deck's PRESET (deck config), like desktop and
    /// AnkiDroid — not a per-deck override — and `deckLimits` reads that preset
    /// value back, never a hardcoded 20/200. Proves both halves of the fix: the
    /// read falls back to the real preset when there's no override, and the write
    /// lands on the preset config rather than on the deck.
    func testDeckLimitsEditPresetNotOverride() throws {
        let backend = try freshCollection()
        let deckID = try backend.createDeck(name: "Preset")

        // With no per-deck override, the read returns the deck's actual preset
        // (the default preset's 20/200) — not a hardcoded constant.
        let defaults = try backend.deckLimits(deckID: deckID)
        XCTAssertEqual(defaults.newPerDay, 20, "reads the preset new/day, not a constant")
        XCTAssertEqual(defaults.reviewsPerDay, 200, "reads the preset reviews/day, not a constant")

        try backend.setDeckLimits(deckID: deckID, newPerDay: 42, reviewsPerDay: 99)

        // The new values read back…
        let updated = try backend.deckLimits(deckID: deckID)
        XCTAssertEqual(updated.newPerDay, 42)
        XCTAssertEqual(updated.reviewsPerDay, 99)

        // …and are stored on the PRESET, not as a per-deck override on the deck.
        let deck = try backend.deck(id: deckID)
        XCTAssertFalse(deck.normal.hasNewLimit, "no per-deck new override should be written")
        XCTAssertFalse(deck.normal.hasReviewLimit, "no per-deck review override should be written")

        let forUpdate = try backend.deckConfigsForUpdate(deckID: deckID)
        let configID = forUpdate.currentDeck.configID
        let config = try XCTUnwrap(
            forUpdate.allConfig.first { $0.config.id == configID }?.config,
            "the deck's assigned preset should be among the configs"
        )
        XCTAssertEqual(config.config.newPerDay, 42, "the preset holds the new/day value")
        XCTAssertEqual(config.config.reviewsPerDay, 99, "the preset holds the reviews/day value")
    }

    // MARK: - Import / Export

    /// Round-trips notes through a `.apkg`: export a source collection's notes
    /// (ImportExportService, service 39, method 4), then import them into a fresh
    /// collection (service 39, method 2) and assert the notes survive. Proves the
    /// service/method indices, the request/response shapes, and the export note
    /// count. Clone of AnkiDroid's apkg export/import driving the same backend.
    func testExportThenImportAnkiPackageRoundTrip() throws {
        let source = try freshCollection()
        let notetypeID = try basicNotetypeID(source)
        _ = try source.addNote(notetypeID: notetypeID, fields: ["RoundTripQ", "RoundTripA"], deckID: 1)
        _ = try source.addNote(notetypeID: notetypeID, fields: ["SecondQ", "SecondA"], deckID: 1)

        let apkg = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).apkg")
        defer { try? FileManager.default.removeItem(at: apkg) }

        let exportedCount = try source.exportAnkiPackage(
            outPath: apkg.path,
            limit: Backend.wholeCollectionExportLimit(),
            withScheduling: true, withMedia: true, legacy: false
        )
        XCTAssertEqual(exportedCount, 2, "both notes should be exported")
        XCTAssertTrue(FileManager.default.fileExists(atPath: apkg.path), "an .apkg file should be written")

        let dest = try freshCollection()
        XCTAssertTrue(try dest.searchCards(query: "").isEmpty, "a fresh collection starts with no cards")

        let result = try dest.importAnkiPackage(path: apkg.path)
        XCTAssertEqual(result.found, 2, "the import log should report two notes found")

        XCTAssertEqual(try dest.searchCards(query: "").count, 2, "both notes should be imported")
        XCTAssertEqual(try dest.searchCards(query: "RoundTripQ").count, 1,
                       "the imported note's field text should be searchable")
    }

    /// Importing a missing `.apkg` surfaces a decodable backend error (the UI
    /// shows its message), rather than crashing or silently succeeding.
    func testImportAnkiPackageMissingFileThrows() throws {
        let backend = try freshCollection()
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).apkg")
        XCTAssertThrowsError(try backend.importAnkiPackage(path: missing.path)) { error in
            guard case AnkiError.backendError = error else {
                return XCTFail("expected a backend error for a missing package")
            }
        }
    }

    /// Round-trips the whole collection through a `.colpkg`: export it (service
    /// 39, method 1) — which leaves the collection closed, so we reopen — then
    /// import it into a second collection (service 39, method 0), which requires
    /// the destination closed and is reopened afterwards. Asserts the notes
    /// survive. Clone of AnkiDroid's colpkg export/import open/close lifecycle.
    func testColpkgExportImportRoundTrip() throws {
        // Source collection with two notes, exported to a .colpkg.
        let sourceDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source = try openCollection(in: sourceDir)
        let notetypeID = try basicNotetypeID(source)
        _ = try source.addNote(notetypeID: notetypeID, fields: ["ColQ", "ColA"], deckID: 1)
        _ = try source.addNote(notetypeID: notetypeID, fields: ["ColQ2", "ColA2"], deckID: 1)

        let colpkg = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).colpkg")
        defer { try? FileManager.default.removeItem(at: colpkg) }

        try source.exportCollectionPackage(outPath: colpkg.path, includeMedia: true)
        // Export takes the collection; reopen it (mirrors AnkiDroid's reopen()).
        try source.openCollection(
            path: sourceDir.appendingPathComponent("collection.anki2").path,
            mediaFolder: sourceDir.appendingPathComponent("collection.media").path,
            mediaDB: sourceDir.appendingPathComponent("collection.media.db2").path
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: colpkg.path), "a .colpkg file should be written")

        // Destination collection: replace its contents with the .colpkg.
        let destDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let dest = try openCollection(in: destDir)
        XCTAssertTrue(try dest.searchCards(query: "").isEmpty, "the destination starts empty")

        let destCol = destDir.appendingPathComponent("collection.anki2").path
        let destMediaFolder = destDir.appendingPathComponent("collection.media").path
        let destMediaDB = destDir.appendingPathComponent("collection.media.db2").path

        // Colpkg import requires the collection closed; reopen afterwards.
        try dest.closeCollection()
        try dest.importCollectionPackage(
            colPath: destCol, backupPath: colpkg.path,
            mediaFolder: destMediaFolder, mediaDB: destMediaDB
        )
        try dest.openCollection(path: destCol, mediaFolder: destMediaFolder, mediaDB: destMediaDB)

        XCTAssertEqual(try dest.searchCards(query: "").count, 2,
                       "the destination should now hold the source collection's notes")
        XCTAssertEqual(try dest.searchCards(query: "ColQ2").count, 1,
                       "the replaced collection's note text should be searchable")
    }

    // MARK: - CSV / text import

    /// `getCsvMetadata` (ImportExportService 39, 5) inspects a tab-separated file
    /// and reports its columns + delimiter, then `importCsv` (39, 6) adds the rows
    /// as notes using a chosen note type + per-field column mapping — the engine
    /// behind the CSV import wizard. A two-column, two-row TSV imports as two
    /// Basic notes whose Front/Back fields come from columns 1/2, and the mapped
    /// field text is searchable. Proves the service/method indices, the
    /// `CsvMetadata`/`ImportCsvRequest` shapes, and the column→field mapping.
    func testCsvImportMapsColumnsToFieldsAndAddsNotes() throws {
        let backend = try freshCollection()
        let notetypeID = try basicNotetypeID(backend)

        let csv = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: csv) }
        // Tab-separated (Anki's native text delimiter), no header row.
        try "Hello\tWorld\nFoo\tBar\n".write(to: csv, atomically: true, encoding: .utf8)

        // Metadata detection: two columns, tab delimiter auto-detected.
        let metadata = try backend.getCsvMetadata(path: csv.path, notetypeID: notetypeID, deckID: 1)
        XCTAssertEqual(metadata.columnLabels.count, 2, "the file has two columns")
        XCTAssertEqual(metadata.delimiter, .tab, "a tab-separated file should detect the tab delimiter")

        // Map Front←column 1, Back←column 2 (one-based) onto the Basic note type.
        var toImport = metadata
        var mapped = Anki_ImportExport_CsvMetadata.MappedNotetype()
        mapped.id = notetypeID
        mapped.fieldColumns = [1, 2]
        toImport.globalNotetype = mapped
        toImport.deckID = 1

        let result = try backend.importCsv(path: csv.path, metadata: toImport)
        XCTAssertEqual(result.found, 2, "both rows should be found as notes")
        XCTAssertEqual(result.imported, 2, "both rows should be added to the fresh collection")

        XCTAssertEqual(try backend.searchCards(query: "").count, 2, "two notes should now exist")
        let noteID = try XCTUnwrap(try backend.searchNotes(query: "Hello").first,
                                   "the mapped Front text should be searchable")
        XCTAssertEqual(try backend.getNote(noteID: noteID).fields, ["Hello", "World"],
                       "columns 1/2 should map onto the Front/Back fields")
    }

    /// Importing a column into the Tags field works via `tagsColumn`: a
    /// three-column TSV whose third column is mapped to tags lands those tags on
    /// the note — the "Tags" target of the mapping UI.
    func testCsvImportTagsColumnAddsTags() throws {
        let backend = try freshCollection()
        let notetypeID = try basicNotetypeID(backend)

        let csv = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: csv) }
        try "Q1\tA1\tanimal mammal\n".write(to: csv, atomically: true, encoding: .utf8)

        var metadata = try backend.getCsvMetadata(path: csv.path, notetypeID: notetypeID, deckID: 1)
        var mapped = Anki_ImportExport_CsvMetadata.MappedNotetype()
        mapped.id = notetypeID
        mapped.fieldColumns = [1, 2] // Front←1, Back←2; column 3 is tags
        metadata.globalNotetype = mapped
        metadata.deckID = 1
        metadata.tagsColumn = 3

        _ = try backend.importCsv(path: csv.path, metadata: metadata)
        let noteID = try XCTUnwrap(try backend.searchNotes(query: "Q1").first)
        let tags = try backend.getNote(noteID: noteID).tags
        XCTAssertTrue(tags.contains("animal"), "the tags column should add its tags")
        XCTAssertTrue(tags.contains("mammal"), "space-separated tags in the column should all land")
    }

    // MARK: - Notes / cards text (CSV) export

    /// `exportNoteCsv` (ImportExportService 39, 7) writes the collection's notes
    /// to a tab-separated text file and returns the note count — the "Notes in
    /// Plain Text" export. The produced file exists and contains each note's
    /// mapped field text (and, with `withTags`, its tags). Proves the
    /// service/method indices and the `ExportNoteCsvRequest` shape.
    func testExportNoteCsvWritesNotesWithFieldsAndTags() throws {
        let backend = try freshCollection()
        let notetypeID = try basicNotetypeID(backend)
        _ = try backend.addNote(notetypeID: notetypeID, fields: ["ExportFront", "ExportBack"],
                                deckID: 1, tags: ["geo"])
        _ = try backend.addNote(notetypeID: notetypeID, fields: ["SecondQ", "SecondA"], deckID: 1)

        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: out) }

        let count = try backend.exportNoteCsv(
            outPath: out.path, limit: Backend.wholeCollectionExportLimit(),
            withHtml: false, withTags: true
        )
        XCTAssertEqual(count, 2, "both notes should be exported")
        XCTAssertTrue(FileManager.default.fileExists(atPath: out.path), "a text file should be written")

        let contents = try String(contentsOf: out, encoding: .utf8)
        XCTAssertTrue(contents.contains("ExportFront"), "the first note's Front should be written")
        XCTAssertTrue(contents.contains("ExportBack"), "the first note's Back should be written")
        XCTAssertTrue(contents.contains("SecondQ"), "the second note should be written too")
        XCTAssertTrue(contents.contains("geo"), "with-tags should include the note's tags")
    }

    /// `exportCardCsv` (ImportExportService 39, 8) writes each card's rendered
    /// question/answer to a tab-separated text file and returns the card count —
    /// the "Cards in Plain Text" export. With `withHtml: false` the rendered text
    /// is stripped to plain text and still carries the field contents.
    func testExportCardCsvWritesRenderedCards() throws {
        let backend = try freshCollection()
        let notetypeID = try basicNotetypeID(backend)
        _ = try backend.addNote(notetypeID: notetypeID, fields: ["CardQ", "CardA"], deckID: 1)

        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: out) }

        let count = try backend.exportCardCsv(
            outPath: out.path, limit: Backend.wholeCollectionExportLimit(), withHtml: false
        )
        XCTAssertEqual(count, 1, "the one card should be exported")
        XCTAssertTrue(FileManager.default.fileExists(atPath: out.path), "a text file should be written")

        let contents = try String(contentsOf: out, encoding: .utf8)
        XCTAssertTrue(contents.contains("CardQ"), "the rendered question text should be present")
        XCTAssertTrue(contents.contains("CardA"), "the rendered answer text should be present")
    }

    /// Round-trips notes through a CSV/text file: export a source collection's
    /// notes (with the note-type and deck columns) and re-import them into a fresh
    /// collection, asserting the field text survives. Exercises `exportNoteCsv`
    /// and `importCsv` together, including the `notetypeColumn`/`deckColumn`
    /// mapping the engine writes and reads back.
    func testNoteCsvExportThenReimportRoundTrip() throws {
        let source = try freshCollection()
        let notetypeID = try basicNotetypeID(source)
        _ = try source.addNote(notetypeID: notetypeID, fields: ["RtFront", "RtBack"], deckID: 1)

        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: out) }

        // Export with the note-type column so a re-import can resolve the type.
        let exported = try source.exportNoteCsv(
            outPath: out.path, limit: Backend.wholeCollectionExportLimit(),
            withHtml: false, withTags: true, withDeck: true, withNotetype: true
        )
        XCTAssertEqual(exported, 1, "the one note should be exported")

        // Re-import into a fresh collection. The header (#notetype column / #deck
        // column) lets getCsvMetadata derive a notetype-column mapping.
        let dest = try freshCollection()
        let metadata = try dest.getCsvMetadata(path: out.path)
        let result = try dest.importCsv(path: out.path, metadata: metadata)
        XCTAssertGreaterThanOrEqual(result.found, 1, "the exported note should be found on re-import")

        XCTAssertEqual(try dest.searchNotes(query: "RtFront").count, 1,
                       "the round-tripped note's field text should be searchable")
    }

    // MARK: - Statistics

    /// `graphs` (StatsService, service 43, method 2) returns real data from the
    /// engine: with three freshly added Basic notes the collection has three new
    /// cards, which the Card Counts data reflects — proving the service/method
    /// indices and the `GraphsResponse` shape.
    func testGraphsReturnsRealCardCounts() throws {
        let backend = try freshCollection()
        let notetypeID = try basicNotetypeID(backend)
        for i in 0..<3 {
            _ = try backend.addNote(notetypeID: notetypeID, fields: ["Q\(i)", "A\(i)"], deckID: 1)
        }

        let resp = try backend.graphs(search: "", days: 0)
        XCTAssertEqual(resp.cardCounts.includingInactive.newCards, 3,
                       "three added Basic notes should be three new cards")

        let summary = Backend.makeStatsSummary(from: resp, period: .allTime)
        XCTAssertEqual(summary.cardCounts.new, 3, "summary should mirror the engine's new-card count")
        XCTAssertEqual(summary.totalCards, 3, "total cards should sum every state bucket")
    }

    /// Card Counts separates suspended/buried cards into their own buckets
    /// (desktop's default `card_counts_separate_inactive = true`): suspending one
    /// of three new cards leaves two `new` and one `suspended`, rather than
    /// folding the suspended card back into `new`. Proves `makeStatsSummary` reads
    /// the inactive-*excluding* counts, so Suspended/Buried can actually render.
    func testStatsSummarySeparatesSuspendedCards() throws {
        let backend = try freshCollection()
        let notetypeID = try basicNotetypeID(backend)
        for i in 0..<3 {
            _ = try backend.addNote(notetypeID: notetypeID, fields: ["SQ\(i)", "SA\(i)"], deckID: 1)
        }
        let cardID = try XCTUnwrap(try backend.searchCards(query: "").first)
        _ = try backend.suspendCards(cardIDs: [cardID])

        let summary = try backend.statsSummary(period: .allTime)
        XCTAssertEqual(summary.cardCounts.suspended, 1,
                       "a suspended card is its own bucket, not folded into new/young")
        XCTAssertEqual(summary.cardCounts.new, 2, "the two non-suspended cards stay new")
        XCTAssertEqual(summary.totalCards, 3, "every card is still counted once")
    }

    /// Answering a card is recorded in the engine's revlog and surfaces in the
    /// graphs' Today block: after one answer, today's answer count is 1. This
    /// proves `statsSummary` reads live review data, not a static snapshot.
    func testStatsSummaryReflectsAnswersToday() throws {
        let backend = try freshCollection()
        let notetypeID = try basicNotetypeID(backend)
        _ = try backend.addNote(notetypeID: notetypeID, fields: ["Front", "Back"], deckID: 1)

        // Nothing answered yet.
        let before = try backend.statsSummary(period: .month)
        XCTAssertEqual(before.today.answerCount, 0, "no reviews answered yet")

        // Answer the one queued card.
        let card = try XCTUnwrap(try backend.queuedCards().cards.first)
        try backend.answer(card: card, rating: .good, millisecondsTaken: 1500)

        let after = try backend.statsSummary(period: .month)
        XCTAssertEqual(after.today.answerCount, 1, "one card answered today")
        XCTAssertEqual(after.today.correctCount, 1, "a 'good' answer counts as correct")
        XCTAssertEqual(after.today.againCount, 0, "nothing was answered 'again'")
        XCTAssertEqual(after.today.retentionPercent, 100, "today's retention is 100%")
    }

    /// `makeStatsSummary` applies desktop Anki's period windows: Future Due keeps
    /// the backlog (day < 0, matching desktop's default `future_due_show_backlog`)
    /// and caps to the range's upper bound, while Reviews keeps past days
    /// (day <= 0) down to the range's lower bound. Tested as a pure mapping on a
    /// hand-built response, with no backend.
    func testMakeStatsSummaryClipsToPeriod() {
        var resp = Anki_Stats_GraphsResponse()
        // Future due across backlog, today, near future, and far future.
        var futureDue = Anki_Stats_GraphsResponse.FutureDue()
        futureDue.futureDue = [-2: 5, 0: 1, 1: 2, 40: 9]
        resp.futureDue = futureDue
        // Reviews on today, within a month, and far in the past.
        func reviews(_ count: UInt32) -> Anki_Stats_GraphsResponse.ReviewCountsAndTimes.Reviews {
            var r = Anki_Stats_GraphsResponse.ReviewCountsAndTimes.Reviews()
            r.young = count
            return r
        }
        var rcat = Anki_Stats_GraphsResponse.ReviewCountsAndTimes()
        rcat.count = [0: reviews(3), -5: reviews(2), -40: reviews(7)]
        resp.reviews = rcat

        let month = Backend.makeStatsSummary(from: resp, period: .month)
        XCTAssertEqual(month.futureDue.map(\.day), [-2, 0, 1],
                       "month future-due keeps the backlog (-2) but drops the >31d bar (40)")
        XCTAssertEqual(month.reviews.map(\.day), [-5, 0],
                       "month reviews keep only the last 30 days (drops -40)")

        let all = Backend.makeStatsSummary(from: resp, period: .allTime)
        XCTAssertEqual(all.futureDue.map(\.day), [-2, 0, 1, 40],
                       "all-time keeps every future bar including the backlog")
        XCTAssertEqual(all.reviews.map(\.day), [-40, -5, 0],
                       "all-time keeps every past review day")
    }

    // MARK: - Card Info

    /// `cardStats`/`cardInfo` (StatsService, service 43, method 0) returns real
    /// per-card data: a freshly added Basic card reports its deck, note type, and
    /// a clean (no reviews/lapses, never-reviewed) history — proving the
    /// service/method indices and the `CardStatsResponse` shape.
    func testCardInfoReturnsRealData() throws {
        let backend = try freshCollection()
        let notetypeID = try basicNotetypeID(backend)
        _ = try backend.addNote(notetypeID: notetypeID, fields: ["InfoQ", "InfoA"], deckID: 1)
        let cardID = try XCTUnwrap(try backend.searchCards(query: "").first)

        let info = try backend.cardInfo(cardID: cardID)
        XCTAssertEqual(info.cardID, cardID, "info should be for the requested card")
        XCTAssertEqual(info.deck, "Default", "the card lives in the Default deck")
        XCTAssertTrue(info.notetype.hasPrefix("Basic"), "note type name should come through")
        XCTAssertGreaterThan(info.added, 0, "added timestamp should be set")
        XCTAssertEqual(info.reviews, 0, "a new card has no reviews")
        XCTAssertEqual(info.lapses, 0, "a new card has no lapses")
        XCTAssertNil(info.firstReview, "a new card has never been reviewed")
        XCTAssertNotNil(info.duePosition, "a new card has a queue position")
    }

    /// After answering a card, its info reflects the review: the review count
    /// rises and a first/latest review timestamp appears — proving `cardInfo`
    /// reads live data, not a static snapshot.
    func testCardInfoReflectsAReview() throws {
        let backend = try freshCollection()
        let notetypeID = try basicNotetypeID(backend)
        _ = try backend.addNote(notetypeID: notetypeID, fields: ["Front", "Back"], deckID: 1)
        let card = try XCTUnwrap(try backend.queuedCards().cards.first)
        try backend.answer(card: card, rating: .good, millisecondsTaken: 1200)

        let info = try backend.cardInfo(cardID: card.card.id)
        XCTAssertEqual(info.reviews, 1, "one review should be recorded")
        XCTAssertNotNil(info.firstReview, "a reviewed card has a first-review time")
        XCTAssertNotNil(info.latestReview, "a reviewed card has a latest-review time")
    }

    // MARK: - Change Note Type

    /// `changeNotetypeInfo` (NotetypesService, service 23, method 14) returns the
    /// old/new field names and a sensible default mapping (matched by name), and
    /// `changeNotetype` (23, 15) applies it: the note adopts the new type while
    /// the default map preserves its field contents. Proves both indices and the
    /// `ChangeNotetypeInfo`/`ChangeNotetypeRequest` shapes.
    func testChangeNotetypeRemapsNoteAndPreservesFields() throws {
        let backend = try freshCollection()
        let notetypes = try backend.notetypeNames()
        let basic = try XCTUnwrap(notetypes.first { $0.name == "Basic" })
        let reversed = try XCTUnwrap(
            notetypes.first { $0.name == "Basic (and reversed card)" },
            "fresh collection ships the reversed Basic note type"
        )
        let nid = try backend.addNote(notetypeID: basic.id, fields: ["Q", "A"], deckID: 1)

        let info = try backend.changeNotetypeInfo(oldNotetypeID: basic.id, newNotetypeID: reversed.id)
        XCTAssertEqual(info.oldFieldNames, ["Front", "Back"], "Basic has Front/Back fields")
        XCTAssertEqual(info.newFieldNames, ["Front", "Back"], "reversed Basic also has Front/Back")
        XCTAssertEqual(info.defaultFieldMap, [0, 1], "matching names map straight across")
        XCTAssertFalse(info.isCloze, "neither note type is cloze")

        try backend.changeNotetype(
            noteIDs: [nid], info: info,
            fieldMap: info.defaultFieldMap, templateMap: info.defaultTemplateMap
        )

        let note = try backend.getNote(noteID: nid)
        XCTAssertEqual(note.notetypeID, reversed.id, "the note should adopt the new note type")
        XCTAssertEqual(note.fields, ["Q", "A"], "the default mapping preserves field contents")
        XCTAssertFalse(try backend.undoStatus().undo.isEmpty, "changing note type should be undoable")
    }

    // MARK: - Manage Note Types

    /// `notetypeNamesAndCounts` (NotetypesService 23, 9) lists every note type
    /// with its note count — the data behind the "Manage note types" list. A
    /// fresh collection ships the stock types with zero notes; adding a Basic note
    /// bumps that type's count to one.
    func testNotetypeNamesAndCountsReflectsUsage() throws {
        let backend = try freshCollection()
        let before = try backend.notetypeNamesAndCounts()
        XCTAssertFalse(before.isEmpty, "a fresh collection ships stock note types")
        let basic = try XCTUnwrap(before.first { $0.name == "Basic" })
        XCTAssertEqual(basic.useCount, 0, "no notes use Basic yet")

        _ = try backend.addNote(notetypeID: basic.id, fields: ["Q", "A"], deckID: 1)

        let after = try backend.notetypeNamesAndCounts()
        XCTAssertEqual(after.first { $0.id == basic.id }?.useCount, 1,
                       "the added note should be counted against Basic")
    }

    /// `addStockNotetype` (get_stock_notetype_legacy 23,5 → add_notetype_legacy
    /// 23,2) creates a new note type from a stock kind under a chosen name — the
    /// "Add" path of AnkiDroid's Add-note-type dialog. The new type appears in the
    /// list and carries the stock kind's fields (Basic → Front/Back).
    func testAddStockNotetypeCreatesNamedType() throws {
        let backend = try freshCollection()
        let newID = try backend.addStockNotetype(kind: .basic, name: "My Basic")
        XCTAssertGreaterThan(newID, 0, "a created note type has a real id")

        XCTAssertTrue(try backend.notetypeNames().contains { $0.id == newID && $0.name == "My Basic" },
                      "the new note type should appear in the list")
        XCTAssertEqual(try backend.notetypeFields(notetypeID: newID), ["Front", "Back"],
                       "a Basic-derived type has Front/Back fields")
    }

    /// `cloneNotetype` (get_notetype 23,6 → add_notetype 23,0) copies an existing
    /// note type's fields/templates under a new name — the "Clone" path of the
    /// Add dialog.
    func testCloneNotetypeCopiesFieldsAndTemplates() throws {
        let backend = try freshCollection()
        let source = try XCTUnwrap(
            try backend.notetypeNames().first { $0.name == "Basic (and reversed card)" }
        )
        let original = try backend.notetype(id: source.id)

        let cloneID = try backend.cloneNotetype(id: source.id, name: "Reversed Copy")
        XCTAssertNotEqual(cloneID, source.id, "the clone is a distinct note type")

        let clone = try backend.notetype(id: cloneID)
        XCTAssertEqual(clone.name, "Reversed Copy")
        XCTAssertEqual(clone.fieldNames, original.fieldNames, "the clone copies the fields")
        XCTAssertEqual(clone.templates.count, original.templates.count,
                       "the clone copies the card templates (two for a reversed type)")
    }

    /// `renameNotetype` (get_notetype → update_notetype 23,1) changes a note
    /// type's name in place, keeping its id — AnkiDroid's rename action.
    func testRenameNotetypeRoundTrips() throws {
        let backend = try freshCollection()
        let cloneID = try backend.cloneNotetype(id: try basicNotetypeID(backend), name: "To Rename")

        try backend.renameNotetype(id: cloneID, name: "Renamed")
        XCTAssertEqual(try backend.notetype(id: cloneID).name, "Renamed",
                       "the note type keeps its id but changes name")
        XCTAssertTrue(try backend.notetypeNames().contains { $0.id == cloneID && $0.name == "Renamed" })
    }

    /// `removeNotetype` (23, 11) deletes a note type so it no longer appears in
    /// the list — AnkiDroid's delete action (the can't-delete-the-last guard lives
    /// in the UI).
    func testRemoveNotetypeDeletesIt() throws {
        let backend = try freshCollection()
        let cloneID = try backend.cloneNotetype(id: try basicNotetypeID(backend), name: "Doomed Type")
        XCTAssertTrue(try backend.notetypeNames().contains { $0.id == cloneID })

        try backend.removeNotetype(id: cloneID)
        XCTAssertFalse(try backend.notetypeNames().contains { $0.id == cloneID },
                       "the deleted note type should be gone")
    }

    // MARK: - Fields editor

    /// Adding, renaming, repositioning, and removing fields each round-trips
    /// through `update_notetype`, and the engine keeps a note's stored values
    /// aligned by ordinal: a new field is appended empty, a reposition shuffles
    /// the values to match, and a removal drops the corresponding value. Mirrors
    /// AnkiDroid's `ModelFieldEditor`.
    func testFieldAddRepositionRemoveKeepsNotesAligned() throws {
        let backend = try freshCollection()
        let typeID = try backend.cloneNotetype(id: try basicNotetypeID(backend), name: "Fields Type")
        let noteID = try backend.addNote(notetypeID: typeID, fields: ["Q", "A"], deckID: 1)

        // Add: a new field is appended (empty on existing notes).
        try backend.addNotetypeField(notetypeID: typeID, name: "Extra")
        XCTAssertEqual(try backend.notetypeFields(notetypeID: typeID), ["Front", "Back", "Extra"])
        XCTAssertEqual(try backend.getNote(noteID: noteID).fields, ["Q", "A", ""],
                       "existing notes gain an empty value for the new field")

        // Rename: the label changes, contents stay put.
        try backend.renameNotetypeField(notetypeID: typeID, at: 0, to: "Question")
        XCTAssertEqual(try backend.notetypeFields(notetypeID: typeID), ["Question", "Back", "Extra"])

        // Reposition: moving "Extra" (idx 2) to the front shuffles the values too.
        try backend.moveNotetypeField(notetypeID: typeID, from: 2, to: 0)
        XCTAssertEqual(try backend.notetypeFields(notetypeID: typeID), ["Extra", "Question", "Back"])
        XCTAssertEqual(try backend.getNote(noteID: noteID).fields, ["", "Q", "A"],
                       "repositioning a field moves each note's value with it")

        // Remove: dropping the first field drops its value.
        try backend.removeNotetypeField(notetypeID: typeID, at: 0)
        XCTAssertEqual(try backend.notetypeFields(notetypeID: typeID), ["Question", "Back"])
        XCTAssertEqual(try backend.getNote(noteID: noteID).fields, ["Q", "A"],
                       "removing a field drops the matching value")
    }

    /// A note type must keep at least one field: removing the last field is a
    /// no-op (the guard in `removeField`), so the field set is unchanged.
    func testRemoveLastFieldIsRefused() throws {
        let backend = try freshCollection()
        let typeID = try backend.cloneNotetype(id: try basicNotetypeID(backend), name: "One Field Type")
        try backend.removeNotetypeField(notetypeID: typeID, at: 1) // drop "Back"
        XCTAssertEqual(try backend.notetypeFields(notetypeID: typeID), ["Front"])

        // Attempting to remove the only remaining field changes nothing.
        try backend.removeNotetypeField(notetypeID: typeID, at: 0)
        XCTAssertEqual(try backend.notetypeFields(notetypeID: typeID), ["Front"],
                       "a note type must retain at least one field")
    }

    /// `setNotetypeSortField` persists the sort-field index through
    /// `update_notetype`, and repositioning a field keeps the sort field pointing
    /// at the same field.
    func testSortFieldSetAndFollowsReposition() throws {
        let backend = try freshCollection()
        let typeID = try backend.cloneNotetype(id: try basicNotetypeID(backend), name: "Sort Type")

        try backend.setNotetypeSortField(notetypeID: typeID, at: 1)
        XCTAssertEqual(try backend.notetype(id: typeID).config.sortFieldIdx, 1,
                       "the sort field index should persist")

        // Move "Back" (the sort field, idx 1) to the front; sort idx follows to 0.
        try backend.moveNotetypeField(notetypeID: typeID, from: 1, to: 0)
        XCTAssertEqual(try backend.notetype(id: typeID).config.sortFieldIdx, 0,
                       "the sort field should track the moved field")
    }

    // MARK: - Card Template editor

    /// Editing a template's front/back and the shared styling persists through
    /// `update_notetype` and reads back via `get_notetype` — the Card Template
    /// editor's Save.
    func testEditTemplateFrontBackAndCSSPersist() throws {
        let backend = try freshCollection()
        let typeID = try backend.cloneNotetype(id: try basicNotetypeID(backend), name: "Template Type")

        var nt = try backend.notetype(id: typeID)
        nt.setTemplate(at: 0, front: "Q: {{Front}}", back: "A: {{Back}}")
        nt.setCSS(".card { color: rgb(1, 2, 3); }")
        try backend.updateNotetype(nt)

        let reloaded = try backend.notetype(id: typeID)
        XCTAssertEqual(reloaded.templates[0].config.qFormat, "Q: {{Front}}", "front format persists")
        XCTAssertEqual(reloaded.templates[0].config.aFormat, "A: {{Back}}", "back format persists")
        XCTAssertTrue(reloaded.config.css.contains("rgb(1, 2, 3)"), "styling CSS persists")
    }

    /// Adding a card template creates a new card on each existing note, and
    /// removing it drops back to one template — the Card Template editor's
    /// add/remove (a normal note type keeps ≥1 template).
    func testAddAndRemoveCardTemplate() throws {
        let backend = try freshCollection()
        let typeID = try backend.cloneNotetype(id: try basicNotetypeID(backend), name: "Multi-card Type")
        let noteID = try backend.addNote(notetypeID: typeID, fields: ["Q", "A"], deckID: 1)
        XCTAssertEqual(try backend.searchCards(query: "nid:\(noteID)").count, 1, "one card to start")

        var nt = try backend.notetype(id: typeID)
        nt.addTemplate(named: "Card 2")
        try backend.updateNotetype(nt)
        let withTwo = try backend.notetype(id: typeID)
        XCTAssertEqual(withTwo.templates.count, 2, "a second template was added")
        XCTAssertEqual(withTwo.templateNames.last, "Card 2")
        XCTAssertEqual(try backend.searchCards(query: "nid:\(noteID)").count, 2,
                       "adding a template generates a card for the existing note")

        var trimmed = try backend.notetype(id: typeID)
        trimmed.removeTemplate(at: 1)
        try backend.updateNotetype(trimmed)
        XCTAssertEqual(try backend.notetype(id: typeID).templates.count, 1, "the template was removed")
    }

    /// `renderUncommittedCard` (CardRenderingService 27, 7) renders a sample note
    /// against an *edited, unsaved* template — the Card Template editor's live
    /// preview. The edited front shows immediately, with the sample field values
    /// filled in, without persisting anything.
    func testPreviewReflectsEditedTemplateWithoutSaving() throws {
        let backend = try freshCollection()
        let typeID = try backend.cloneNotetype(id: try basicNotetypeID(backend), name: "Preview Type")

        let nt = try backend.notetype(id: typeID)
        var edited = nt.templates[0]
        edited.config.qFormat = "PREVIEW {{Front}}"

        let rendered = try backend.renderUncommittedCard(
            note: nt.sampleNote(), cardOrd: 0, template: edited
        )
        XCTAssertTrue(rendered.question.contains("PREVIEW"),
                      "the preview reflects the edited (unsaved) front template")
        XCTAssertTrue(rendered.question.contains("(Front)"),
                      "the sample note fills the field with its name")
        XCTAssertTrue(rendered.answer.contains("(Back)"),
                      "the back renders the sample note's other field")

        // The edit was never saved, so the stored template is untouched.
        XCTAssertEqual(try backend.notetype(id: typeID).templates[0].config.qFormat, "{{Front}}",
                       "previewing must not persist the edit")
    }

    // MARK: - Filtered Decks

    /// Creating a filtered deck gathers matching cards, the deck shows up in the
    /// deck tree as filtered, and emptying it returns the cards to their home
    /// deck. Exercises `get_or_create_filtered_deck` (7, 19) +
    /// `add_or_update_filtered_deck` (7, 20) + `rebuild_filtered_deck` (13, 16) +
    /// `empty_filtered_deck` (13, 15) against the real engine.
    func testCreateRebuildEmptyFilteredDeck() throws {
        let backend = try freshCollection()
        let notetypeID = try basicNotetypeID(backend)
        for i in 0..<3 {
            _ = try backend.addNote(notetypeID: notetypeID, fields: ["FQ\(i)", "FA\(i)"], deckID: 1)
        }

        let result = try backend.createFilteredDeck(
            name: "Cram", search: "deck:Default", limit: 50, order: .orderAdded, reschedule: true
        )
        XCTAssertGreaterThan(result.deckID, 0, "a created filtered deck has a real id")
        XCTAssertEqual(result.cardCount, 3, "all three Default cards are gathered")

        // It appears in the deck tree, flagged as filtered.
        let entry = try XCTUnwrap(
            try backend.deckTree().first { $0.id == result.deckID },
            "the filtered deck should appear in the deck list"
        )
        XCTAssertTrue(entry.filtered, "the new deck is a filtered deck")
        XCTAssertEqual(entry.name, "Cram")

        // The gathered cards now live in the filtered deck.
        XCTAssertEqual(try backend.searchCards(query: "deck:Cram").count, 3,
                       "the cards moved into the filtered deck")

        // Rebuild re-gathers the same cards.
        XCTAssertEqual(try backend.rebuildFilteredDeck(deckID: result.deckID), 3,
                       "rebuild gathers the same three cards")

        // Emptying returns them to their home deck (the filtered deck remains).
        try backend.emptyFilteredDeck(deckID: result.deckID)
        XCTAssertEqual(try backend.searchCards(query: "deck:Cram").count, 0,
                       "emptying returns the cards to their home deck")
        XCTAssertTrue(try backend.deckNames().contains { $0.id == result.deckID },
                      "the emptied filtered deck still exists")
    }

    /// A filtered deck whose search matches nothing is rejected by the engine
    /// (matching desktop's `allow_empty = false`), surfacing as a decodable
    /// backend error the UI can show.
    func testCreateFilteredDeckEmptyMatchThrows() throws {
        let backend = try freshCollection()
        XCTAssertThrowsError(
            try backend.createFilteredDeck(
                name: "Empty", search: "tag:does-not-exist", limit: 10,
                order: .orderDue, reschedule: true
            )
        ) { error in
            guard case AnkiError.backendError = error else {
                return XCTFail("expected a backend error for an empty filtered deck")
            }
        }
    }

    /// A filtered deck built from two search terms gathers the cards matched by
    /// EACH term (Anki's filtered dialog supports up to two filters, each with
    /// its own search / order / limit). Two notes tagged `alpha` / `beta` are
    /// pulled in by `tag:alpha` and `tag:beta` respectively, so the deck holds
    /// both. Exercises the multi-term `createFilteredDeck(name:terms:reschedule:)`.
    func testCreateFilteredDeckWithTwoSearchTerms() throws {
        let backend = try freshCollection()
        let notetypeID = try basicNotetypeID(backend)
        _ = try backend.addNote(notetypeID: notetypeID, fields: ["AQ", "AA"], deckID: 1, tags: ["alpha"])
        _ = try backend.addNote(notetypeID: notetypeID, fields: ["BQ", "BA"], deckID: 1, tags: ["beta"])
        // A third, untagged card should be matched by neither filter.
        _ = try backend.addNote(notetypeID: notetypeID, fields: ["CQ", "CA"], deckID: 1)

        let result = try backend.createFilteredDeck(
            name: "TwoFilters",
            terms: [
                FilteredSearchTermInput(search: "tag:alpha", limit: 10, order: .orderAdded),
                FilteredSearchTermInput(search: "tag:beta", limit: 10, order: .orderAdded),
            ],
            reschedule: true
        )
        XCTAssertGreaterThan(result.deckID, 0, "a created two-filter deck has a real id")
        XCTAssertEqual(result.cardCount, 2, "both the alpha and beta cards are gathered")
        XCTAssertEqual(try backend.searchCards(query: "deck:TwoFilters tag:alpha").count, 1,
                       "the first filter pulled in the alpha card")
        XCTAssertEqual(try backend.searchCards(query: "deck:TwoFilters tag:beta").count, 1,
                       "the second filter pulled in the beta card")
        XCTAssertEqual(try backend.searchCards(query: "deck:TwoFilters").count, 2,
                       "the untagged card matched neither filter")
    }

    /// A blank second filter row is ignored, so a two-term call with an empty
    /// second search behaves like a single-filter deck rather than erroring.
    func testCreateFilteredDeckIgnoresEmptySecondFilter() throws {
        let backend = try freshCollection()
        let notetypeID = try basicNotetypeID(backend)
        _ = try backend.addNote(notetypeID: notetypeID, fields: ["Q", "A"], deckID: 1, tags: ["alpha"])

        let result = try backend.createFilteredDeck(
            name: "OneRealFilter",
            terms: [
                FilteredSearchTermInput(search: "tag:alpha", limit: 10, order: .orderAdded),
                FilteredSearchTermInput(search: "  ", limit: 10, order: .orderDue),
            ],
            reschedule: true
        )
        XCTAssertEqual(result.cardCount, 1, "only the non-empty filter contributes cards")
    }

    // MARK: - Custom Study

    /// `customStudyDefaults` (SchedulerService 13, 28) reports the deck's
    /// available new/review counts for the dialog's prefill: a fresh Default deck
    /// with one Basic note has one available new card. Proves the service/method
    /// indices and the `CustomStudyDefaultsResponse` shape.
    func testCustomStudyDefaultsReportsAvailableCounts() throws {
        let backend = try freshCollection()
        let notetypeID = try basicNotetypeID(backend)
        _ = try backend.addNote(notetypeID: notetypeID, fields: ["Q", "A"], deckID: 1)

        let defaults = try backend.customStudyDefaults(deckID: 1)
        XCTAssertEqual(defaults.availableNew, 1, "the one added Basic card is available as new")
        XCTAssertEqual(defaults.extendNew, 0, "nothing extended yet, so the new default is 0")
    }

    /// `customStudy` with `extendNew` bumps today's new-card limit in place
    /// (returning `.extendedLimits`, NOT building a deck), and the new extend
    /// value reads back through `customStudyDefaults` — mirroring desktop's
    /// `custom_study_extends_new_limit` engine test.
    func testCustomStudyExtendNewLimitChangesDefaults() throws {
        let backend = try freshCollection()

        let outcome = try backend.customStudy(deckID: 1, choice: .extendNew(delta: 5))
        XCTAssertEqual(outcome, .extendedLimits, "extending limits must not build a filtered deck")

        let defaults = try backend.customStudyDefaults(deckID: 1)
        XCTAssertEqual(defaults.extendNew, 5, "the extended new limit should persist")
        XCTAssertFalse(
            try backend.deckNames().contains { $0.name == Backend.customStudySessionDeckName },
            "no Custom Study Session deck should be created for a limit extension"
        )
    }

    /// `customStudy` with a session option (here "study by card state" → new
    /// cards) builds the "Custom Study Session" filtered deck, gathers the
    /// matching cards into it, and returns the session deck id so the caller can
    /// study it. Clone of AnkiDroid's CUSTOM_STUDY_SESSION flow.
    func testCustomStudyBuildsCustomStudySessionDeck() throws {
        let backend = try freshCollection()
        let notetypeID = try basicNotetypeID(backend)
        for i in 0..<3 {
            _ = try backend.addNote(notetypeID: notetypeID, fields: ["Q\(i)", "A\(i)"], deckID: 1)
        }

        let outcome = try backend.customStudy(
            deckID: 1,
            choice: .cardStateOrTag(CustomStudyCram(kind: .newCardsOnly, cardLimit: 100))
        )
        guard case let .builtSession(sessionID) = outcome else {
            return XCTFail("a card-state session should build the Custom Study Session deck")
        }
        XCTAssertGreaterThan(sessionID, 0, "the session deck should have a real id")

        let entry = try XCTUnwrap(
            try backend.deckTree().first { $0.id == sessionID },
            "the session deck should appear in the deck tree"
        )
        XCTAssertTrue(entry.filtered, "the Custom Study Session deck is a filtered deck")
        XCTAssertEqual(entry.name, Backend.customStudySessionDeckName)
        XCTAssertEqual(try backend.searchCards(query: "deck:\"\(Backend.customStudySessionDeckName)\"").count, 3,
                       "all three new cards are gathered into the session deck")
    }

    /// A session whose search matches no cards is rejected by the engine
    /// (`allow_empty = false` → `CustomStudyError::NoMatchingCards`), surfacing
    /// as a decodable backend error: "review forgotten" on a collection with no
    /// reviewed cards matches nothing.
    func testCustomStudyNoMatchingCardsThrows() throws {
        let backend = try freshCollection()
        let notetypeID = try basicNotetypeID(backend)
        _ = try backend.addNote(notetypeID: notetypeID, fields: ["Q", "A"], deckID: 1)

        XCTAssertThrowsError(
            try backend.customStudy(deckID: 1, choice: .reviewForgotten(days: 1))
        ) { error in
            guard case AnkiError.backendError = error else {
                return XCTFail("expected a backend error when no cards match the session")
            }
        }
    }

    // MARK: - Subdeck collapse / unbury

    /// `setDeckCollapsed` (DecksService 7, 11) persists a deck's collapsed state,
    /// which the deck tree reflects on its node — the data behind the DeckPicker's
    /// expand/collapse chevron. A parent with a subdeck reports `hasChildren`;
    /// collapsing it sets `collapsed` and hides the child from the flattened deck
    /// list, and expanding it re-shows the child. Round-trips through the real
    /// engine. (The initial collapsed state of a freshly created parent is left
    /// to the engine — AnkiDroid renders from this same tree — so the test sets
    /// the state explicitly rather than assuming a default.)
    func testSetDeckCollapsedHidesAndShowsSubdecks() throws {
        let backend = try freshCollection()
        // `Parent::Child` auto-creates the parent plus the nested subdeck.
        _ = try backend.createDeck(name: "Parent::Child")

        func parent(in tree: [DeckTreeEntry]) throws -> DeckTreeEntry {
            try XCTUnwrap(tree.first { $0.fullName == "Parent" }, "the Parent deck should exist")
        }

        // The parent advertises a subdeck regardless of its collapse state.
        XCTAssertTrue(try parent(in: backend.deckTree()).hasChildren, "the parent has a subdeck")

        // Force expanded: the parent reads not-collapsed and the child row shows.
        try backend.setDeckCollapsed(deckID: try parent(in: backend.deckTree()).id, collapsed: false)
        let expanded = try backend.deckTree()
        XCTAssertFalse(try parent(in: expanded).collapsed, "an expanded parent reads as not collapsed")
        XCTAssertTrue(expanded.contains { $0.fullName == "Parent::Child" },
                      "the child shows while the parent is expanded")

        // Collapse the parent: the child row disappears; the parent reads collapsed.
        try backend.setDeckCollapsed(deckID: try parent(in: expanded).id, collapsed: true)
        let collapsed = try backend.deckTree()
        XCTAssertTrue(try parent(in: collapsed).collapsed, "the parent should read as collapsed")
        XCTAssertFalse(collapsed.contains { $0.fullName == "Parent::Child" },
                       "a collapsed parent hides its subdecks from the list")

        // Expand again: the child reappears.
        try backend.setDeckCollapsed(deckID: try parent(in: collapsed).id, collapsed: false)
        let reexpanded = try backend.deckTree()
        XCTAssertFalse(try parent(in: reexpanded).collapsed, "the parent should read as expanded again")
        XCTAssertTrue(reexpanded.contains { $0.fullName == "Parent::Child" },
                      "expanding restores the subdeck row")
    }

    /// `unburyDeck` (SchedulerService 13, 13) returns a deck's buried cards to the
    /// study queue — the deck "Unbury" action. Burying the only card empties the
    /// queue; unburying the deck restores it, and the op is undoable.
    func testUnburyDeckRestoresBuriedCards() throws {
        let backend = try freshCollection()
        let notetypeID = try basicNotetypeID(backend)
        _ = try backend.addNote(notetypeID: notetypeID, fields: ["Q", "A"], deckID: 1)
        let cardID = try XCTUnwrap(try backend.searchCards(query: "").first)

        _ = try backend.buryCards(cardIDs: [cardID])
        XCTAssertTrue(try backend.queuedCards().cards.isEmpty, "burying the only card empties the queue")

        try backend.unburyDeck(deckID: 1)
        XCTAssertFalse(try backend.queuedCards().cards.isEmpty,
                       "unburying the deck restores its buried card to the queue")
        XCTAssertFalse(try backend.undoStatus().undo.isEmpty, "unbury should be undoable")
    }

    // MARK: - Reviewer card actions

    /// `buryCards` (bury_or_suspend, BURY_USER on card ids) removes the card from
    /// the study queue and is undoable — the reviewer's "Bury card" action.
    func testBuryCardLeavesQueueAndIsUndoable() throws {
        let backend = try freshCollection()
        let notetypeID = try basicNotetypeID(backend)
        _ = try backend.addNote(notetypeID: notetypeID, fields: ["Q", "A"], deckID: 1)
        let card = try XCTUnwrap(try backend.queuedCards().cards.first, "the added card should be queued")

        let buried = try backend.buryCards(cardIDs: [card.card.id])
        XCTAssertEqual(buried, 1, "one card should be buried")
        XCTAssertTrue(try backend.queuedCards().cards.isEmpty, "the buried card should leave the queue")
        XCTAssertFalse(try backend.undoStatus().undo.isEmpty, "burying should be undoable")

        _ = try backend.undo()
        XCTAssertFalse(try backend.queuedCards().cards.isEmpty, "undo should restore the buried card")
    }

    /// `buryNotes` (bury_or_suspend, BURY_USER on note ids) buries every card of
    /// the note — the reviewer's "Bury note" action. With one card this matches
    /// burying the card, but it targets the note id rather than the card id.
    func testBuryNoteLeavesQueue() throws {
        let backend = try freshCollection()
        let notetypeID = try basicNotetypeID(backend)
        let nid = try backend.addNote(notetypeID: notetypeID, fields: ["Q", "A"], deckID: 1)

        let buried = try backend.buryNotes(noteIDs: [nid])
        XCTAssertEqual(buried, 1, "the note's one card should be buried")
        XCTAssertTrue(try backend.queuedCards().cards.isEmpty, "the buried note's card should leave the queue")
    }

    /// `suspendNotes` (bury_or_suspend, SUSPEND on note ids) suspends the note's
    /// card, visible on the browser row — the reviewer's "Suspend note" action.
    func testSuspendNoteSuspendsCard() throws {
        let backend = try freshCollection()
        let notetypeID = try basicNotetypeID(backend)
        let nid = try backend.addNote(notetypeID: notetypeID, fields: ["Q", "A"], deckID: 1)
        let cardID = try XCTUnwrap(try backend.searchCards(query: "").first)

        let suspended = try backend.suspendNotes(noteIDs: [nid])
        XCTAssertEqual(suspended, 1, "the note's one card should be suspended")
        XCTAssertTrue(try backend.cardBrowserRow(cardID: cardID).suspended, "the card should read as suspended")
    }

    /// `toggleMark` flips the note's `marked` tag and reports the new state, and
    /// `isNoteMarked` reads it back — the reviewer's Mark/Unmark action, which
    /// AnkiDroid implements as a tag toggle.
    func testToggleMarkAddsAndRemovesMarkedTag() throws {
        let backend = try freshCollection()
        let notetypeID = try basicNotetypeID(backend)
        let nid = try backend.addNote(notetypeID: notetypeID, fields: ["Q", "A"], deckID: 1)

        XCTAssertFalse(try backend.isNoteMarked(noteID: nid), "a new note is not marked")

        XCTAssertTrue(try backend.toggleMark(noteID: nid), "marking should report the marked state")
        XCTAssertTrue(try backend.isNoteMarked(noteID: nid), "the note should now be marked")
        XCTAssertTrue(try backend.getNote(noteID: nid).tags.contains("marked"),
                      "marking should add the 'marked' tag")
        XCTAssertFalse(try backend.undoStatus().undo.isEmpty, "marking should be undoable")

        XCTAssertFalse(try backend.toggleMark(noteID: nid), "unmarking should report the unmarked state")
        XCTAssertFalse(try backend.isNoteMarked(noteID: nid), "the note should no longer be marked")
        XCTAssertFalse(try backend.getNote(noteID: nid).tags.contains("marked"),
                       "unmarking should remove the 'marked' tag")
    }

    /// `setDueDate` (SchedulerService 13, 19) reschedules a card from an Anki
    /// date spec — the reviewer's "Set due date". Setting a new card to "3" days
    /// converts it to a review due in the future, so it leaves today's queue; the
    /// op is undoable, and undo restores it to the queue. (The RPC returns
    /// `OpChanges`, not a count.) Mirrors AnkiDroid's set-due-date action.
    func testSetDueDateReschedulesAndIsUndoable() throws {
        let backend = try freshCollection()
        let notetypeID = try basicNotetypeID(backend)
        _ = try backend.addNote(notetypeID: notetypeID, fields: ["Due", "Date"], deckID: 1)
        let cardID = try XCTUnwrap(try backend.searchCards(query: "").first, "the added card should exist")
        XCTAssertFalse(try backend.queuedCards().cards.isEmpty, "the new card starts queued for today")

        _ = try backend.setDueDate(cardIDs: [cardID], days: "3")
        XCTAssertFalse(try backend.undoStatus().undo.isEmpty, "set due date should be undoable")
        XCTAssertTrue(try backend.queuedCards().cards.isEmpty,
                      "a card rescheduled 3 days out should leave today's queue")

        _ = try backend.undo()
        XCTAssertFalse(try backend.queuedCards().cards.isEmpty,
                       "undo should restore the card to today's queue")
    }

    /// `removeNotes(noteIDs:)` deletes the note (and its cards) so a follow-up
    /// search no longer finds it — the reviewer's Delete-note action, which knows
    /// the current card's note id.
    func testRemoveNotesByNoteIDDeletes() throws {
        let backend = try freshCollection()
        let notetypeID = try basicNotetypeID(backend)
        let nid = try backend.addNote(notetypeID: notetypeID, fields: ["Doomed", "Note"], deckID: 1)

        let removed = try backend.removeNotes(noteIDs: [nid])
        XCTAssertEqual(removed, 1, "one note should be removed")
        XCTAssertTrue(try backend.searchCards(query: "").isEmpty, "the note's card should be gone after delete")
    }

    // MARK: - Media

    /// A tiny but valid 1×1 PNG, used to exercise `addMediaFile` with real bytes.
    private static let onePixelPNG = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="
    )!

    /// `addMediaFile` (MediaService, service 41, method 1) writes bytes into the
    /// collection's `collection.media` folder and returns the stored filename —
    /// the engine-managed name to embed in a field as `<img src="NAME">`. Proves
    /// the service/method indices and that the file actually lands on disk (so a
    /// later media sync can upload it), mirroring AnkiDroid's `Media.addFile`.
    func testAddMediaFileStoresBytesAndReturnsStoredName() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let backend = try openCollection(in: dir)
        let mediaFolder = dir.appendingPathComponent("collection.media")

        let stored = try backend.addMediaFile(desiredName: "front.png", data: Self.onePixelPNG)
        XCTAssertEqual(stored, "front.png", "an un-colliding name should be kept as-is")

        let onDisk = mediaFolder.appendingPathComponent(stored)
        XCTAssertTrue(FileManager.default.fileExists(atPath: onDisk.path),
                      "the stored file should exist in collection.media")
        XCTAssertEqual(try Data(contentsOf: onDisk), Self.onePixelPNG,
                       "the stored bytes should match what was added")
    }

    /// Adding the *same* name with *different* bytes makes the engine pick a new,
    /// non-colliding name (e.g. `front_<hash>.png`) rather than overwriting —
    /// the deduplication that makes the returned name the safe one to reference.
    /// Identical bytes under the same name reuse the existing file.
    func testAddMediaFileDeduplicatesCollidingName() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let backend = try openCollection(in: dir)

        let first = try backend.addMediaFile(desiredName: "audio.mp3", data: Data("one".utf8))
        XCTAssertEqual(first, "audio.mp3")

        // Same name, different content → renamed to avoid clobbering the first.
        let second = try backend.addMediaFile(desiredName: "audio.mp3", data: Data("two".utf8))
        XCTAssertNotEqual(second, first, "colliding different bytes must not reuse the name")
        XCTAssertTrue(second.hasSuffix(".mp3"), "the dedup name keeps the extension")

        // Same name, identical content → the engine reuses the existing file.
        let third = try backend.addMediaFile(desiredName: "audio.mp3", data: Data("one".utf8))
        XCTAssertEqual(third, first, "identical bytes under the same name reuse the stored file")
    }

    // MARK: - Preferences (Editing & Backups)

    /// The `editing` sub-message of `Preferences` round-trips through the engine,
    /// proving the Settings "Editing" toggles persist. Flips the booleans and a
    /// string field, writes the whole `Preferences`, and re-reads — also checking
    /// that an unrelated sub-message (`reviewing`) is preserved by the
    /// read-modify-write, since the Settings screen only mutates one field at a
    /// time on top of the full message.
    func testEditingPreferencesRoundTrip() throws {
        let backend = try freshCollection()

        let original = try backend.getPreferences()
        let reviewingBefore = original.reviewing.showIntervalsOnButtons
        let flippedPasteStrips = !original.editing.pasteStripsFormatting
        let flippedPastePng = !original.editing.pasteImagesAsPng
        let flippedAccents = !original.editing.ignoreAccentsInSearch
        let flippedAddDefault = !original.editing.addingDefaultsToCurrentDeck

        var updated = original
        updated.editing.pasteStripsFormatting = flippedPasteStrips
        updated.editing.pasteImagesAsPng = flippedPastePng
        updated.editing.ignoreAccentsInSearch = flippedAccents
        updated.editing.addingDefaultsToCurrentDeck = flippedAddDefault
        updated.editing.defaultSearchText = "deck:current"
        _ = try backend.setPreferences(updated)

        let readBack = try backend.getPreferences()
        XCTAssertEqual(readBack.editing.pasteStripsFormatting, flippedPasteStrips)
        XCTAssertEqual(readBack.editing.pasteImagesAsPng, flippedPastePng)
        XCTAssertEqual(readBack.editing.ignoreAccentsInSearch, flippedAccents)
        XCTAssertEqual(readBack.editing.addingDefaultsToCurrentDeck, flippedAddDefault)
        XCTAssertEqual(readBack.editing.defaultSearchText, "deck:current")
        XCTAssertEqual(readBack.reviewing.showIntervalsOnButtons, reviewingBefore,
                       "writing editing prefs must not disturb the reviewing sub-message")
    }

    /// The `backups` (BackupLimits) sub-message round-trips through the engine —
    /// the Settings "Backups" section's daily/weekly/monthly counts and the
    /// minimum interval between automatic backups.
    func testBackupLimitsRoundTrip() throws {
        let backend = try freshCollection()

        var updated = try backend.getPreferences()
        updated.backups.daily = 9
        updated.backups.weekly = 8
        updated.backups.monthly = 7
        updated.backups.minimumIntervalMins = 45
        _ = try backend.setPreferences(updated)

        let readBack = try backend.getPreferences().backups
        XCTAssertEqual(readBack.daily, 9)
        XCTAssertEqual(readBack.weekly, 8)
        XCTAssertEqual(readBack.monthly, 7)
        XCTAssertEqual(readBack.minimumIntervalMins, 45)
    }

    /// `createBackup(force:)` writes a `.colpkg` snapshot into the given folder
    /// and `awaitBackupCompletion()` blocks until it's done — the Settings
    /// "Create backup now" action. `force` bypasses the minimum-interval check so
    /// a backup is always produced. Proves the CollectionService 3/2 + 3/3
    /// indices and that a file actually lands on disk.
    func testCreateBackupWritesColpkg() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let backend = try openCollection(in: dir)
        // Some content so there is a collection worth snapshotting.
        _ = try backend.addNote(notetypeID: try basicNotetypeID(backend), fields: ["Q", "A"], deckID: 1)

        let backupFolder = dir.appendingPathComponent("backups")
        try FileManager.default.createDirectory(at: backupFolder, withIntermediateDirectories: true)

        let created = try backend.createBackup(
            backupFolder: backupFolder.path, force: true, waitForCompletion: true
        )
        XCTAssertTrue(created, "a forced backup should always be created")
        // awaitBackupCompletion is a no-op here (we waited) but must not throw.
        try backend.awaitBackupCompletion()

        let files = try FileManager.default.contentsOfDirectory(atPath: backupFolder.path)
        XCTAssertTrue(files.contains { $0.hasSuffix(".colpkg") },
                      "a .colpkg backup file should be written into the backup folder")
    }

    // MARK: - Gesture configuration (Controls / Gestures)

    /// The shipped defaults reproduce the app's prior reviewer behavior + the
    /// AnkiDroid-faithful edge layout: center tap reveals, edges/swipes map to
    /// the four ratings (left = Again, right = Easy, up/top = Good, down/bottom =
    /// Hard), long-press edits, double-tap is unbound.
    func testGestureConfigDefaults() {
        let config = GestureConfig.defaults
        XCTAssertEqual(config.command(for: .tapCenter), .showAnswer)
        XCTAssertEqual(config.command(for: .tapLeft), .answerAgain)
        XCTAssertEqual(config.command(for: .tapRight), .answerEasy)
        XCTAssertEqual(config.command(for: .tapTop), .answerGood)
        XCTAssertEqual(config.command(for: .tapBottom), .answerHard)
        XCTAssertEqual(config.command(for: .swipeLeft), .answerAgain)
        XCTAssertEqual(config.command(for: .swipeRight), .answerEasy)
        XCTAssertEqual(config.command(for: .swipeUp), .answerGood)
        XCTAssertEqual(config.command(for: .swipeDown), .answerHard)
        XCTAssertEqual(config.command(for: .longPress), .editNote)
        XCTAssertEqual(config.command(for: .doubleTap), .none)
        // The four corners of the 3×3 grid ship unbound (AnkiDroid-faithful; the
        // user can bind them in Controls).
        XCTAssertEqual(config.command(for: .tapTopLeft), .none)
        XCTAssertEqual(config.command(for: .tapTopRight), .none)
        XCTAssertEqual(config.command(for: .tapBottomLeft), .none)
        XCTAssertEqual(config.command(for: .tapBottomRight), .none)
        XCTAssertTrue(config.isDefault)
    }

    /// Encoding then decoding the defaults yields an identical config (the
    /// round-trip the Settings screen relies on to persist to `UserDefaults`).
    func testGestureConfigRoundTripsDefaults() throws {
        let data = try GestureConfig.defaults.jsonData()
        let decoded = GestureConfig.from(jsonData: data)
        XCTAssertEqual(decoded, .defaults)
        XCTAssertTrue(decoded.isDefault)
    }

    /// A customized config round-trips exactly, including a gesture explicitly set
    /// to `.none` (disabled) — proving `none` is persisted, not confused with a
    /// missing/defaulted key.
    func testGestureConfigRoundTripsCustomized() throws {
        var config = GestureConfig.defaults
        config.set(.undo, for: .doubleTap)
        config.set(.replayAudio, for: .longPress)
        config.set(.none, for: .tapCenter)         // disable reveal-on-center-tap
        config.set(.flagRed, for: .tapTop)
        XCTAssertFalse(config.isDefault)

        let data = try config.jsonData()
        let decoded = GestureConfig.from(jsonData: data)
        XCTAssertEqual(decoded, config)
        XCTAssertEqual(decoded.command(for: .doubleTap), .undo)
        XCTAssertEqual(decoded.command(for: .longPress), .replayAudio)
        XCTAssertEqual(decoded.command(for: .tapCenter), .none)
        XCTAssertEqual(decoded.command(for: .tapTop), .flagRed)
    }

    /// Tolerant decoding: unknown gesture/command keys are ignored and any gesture
    /// absent from the blob falls back to its default, so a config written by a
    /// different app version still decodes to a complete, valid mapping.
    func testGestureConfigTolerantDecoding() throws {
        let json = """
        {
          "swipeLeft": "undo",
          "tapTop": "notARealCommand",
          "notARealGesture": "answerGood"
        }
        """
        let decoded = GestureConfig.from(jsonData: Data(json.utf8))
        // Recognized override applied.
        XCTAssertEqual(decoded.command(for: .swipeLeft), .undo)
        // Unknown command value ignored → the gesture keeps its default.
        XCTAssertEqual(decoded.command(for: .tapTop), GestureConfig.defaults.command(for: .tapTop))
        // A gesture absent from the blob keeps its default.
        XCTAssertEqual(decoded.command(for: .tapCenter), .showAnswer)
    }

    /// Corrupt or empty data never throws — it degrades to the defaults so the
    /// reviewer always has a usable gesture map.
    func testGestureConfigFromBadDataFallsBackToDefaults() {
        XCTAssertEqual(GestureConfig.from(jsonData: nil), .defaults)
        XCTAssertEqual(GestureConfig.from(jsonData: Data("not json".utf8)), .defaults)
    }

    /// The tap-zone partition is AnkiDroid's 3×3 grid: each axis split into equal
    /// thirds, giving nine cells (four corners, four mid-edges, and center).
    func testTapZonePartition() {
        // Center cell (middle third on both axes).
        XCTAssertEqual(TapZone.from(x: 0.5, y: 0.5), .center)
        // Four mid-edges.
        XCTAssertEqual(TapZone.from(x: 0.5, y: 0.1), .top)
        XCTAssertEqual(TapZone.from(x: 0.5, y: 0.9), .bottom)
        XCTAssertEqual(TapZone.from(x: 0.1, y: 0.5), .left)
        XCTAssertEqual(TapZone.from(x: 0.9, y: 0.5), .right)
        // Four corners.
        XCTAssertEqual(TapZone.from(x: 0.1, y: 0.1), .topLeft)
        XCTAssertEqual(TapZone.from(x: 0.9, y: 0.1), .topRight)
        XCTAssertEqual(TapZone.from(x: 0.1, y: 0.9), .bottomLeft)
        XCTAssertEqual(TapZone.from(x: 0.9, y: 0.9), .bottomRight)
        // Third boundaries: strictly < ⅓ is the low band; ≥ ⅓ (and < ⅔) is middle.
        XCTAssertEqual(TapZone.from(x: 0.3, y: 0.3), .topLeft, "0.3 < ⅓ on both axes")
        XCTAssertEqual(TapZone.from(x: 0.4, y: 0.4), .center, "0.4 is in [⅓, ⅔) on both axes")
        // Corners resolve to the diagonal cell, not an edge.
        XCTAssertEqual(TapZone.from(x: 0.05, y: 0.2), .topLeft)
        // Each zone maps back to its tap gesture, and all nine cells exist.
        XCTAssertEqual(TapZone.center.gesture, .tapCenter)
        XCTAssertEqual(TapZone.left.gesture, .tapLeft)
        XCTAssertEqual(TapZone.topLeft.gesture, .tapTopLeft)
        XCTAssertEqual(TapZone.bottomRight.gesture, .tapBottomRight)
        XCTAssertEqual(TapZone.allCases.count, 9)
    }

    /// Every `ViewerCommand` appears exactly once in `menuOrder`, so the settings
    /// picker can't silently omit (or duplicate) a command.
    func testViewerCommandMenuOrderIsComplete() {
        XCTAssertEqual(Set(ViewerCommand.menuOrder), Set(ViewerCommand.allCases))
        XCTAssertEqual(ViewerCommand.menuOrder.count, ViewerCommand.allCases.count)
    }

    /// Flag commands expose their Anki flag number (1 red … 7 purple); non-flag
    /// commands don't, and the grading commands are the four ratings.
    func testViewerCommandFlagAndGradingMetadata() {
        XCTAssertEqual(ViewerCommand.flagRed.flagNumber, 1)
        XCTAssertEqual(ViewerCommand.flagPurple.flagNumber, 7)
        XCTAssertNil(ViewerCommand.showAnswer.flagNumber)
        XCTAssertEqual(
            Set(ViewerCommand.allCases.filter { $0.isGrading }),
            [.answerAgain, .answerHard, .answerGood, .answerEasy]
        )
    }

    // MARK: - Auto advance (deck-config sourced)

    /// The question-side deck-config action maps to the reviewer's intent: reveal
    /// the answer, or (non-grading) show a reminder. A question timer never grades.
    func testAutoAdvanceMapsQuestionActions() {
        XCTAssertEqual(AutoAdvanceAction.forQuestion(.showAnswer), .showAnswer)
        XCTAssertEqual(AutoAdvanceAction.forQuestion(.showReminder), .showReminder)
    }

    /// The answer-side deck-config action maps to bury / a specific rating / a
    /// reminder. Guards the tricky detail that the proto enum's raw order
    /// (again=1, good=2, hard=3) differs from the rating order (again=1, hard=2,
    /// good=3), so the mapping must be by case — `answerHard` → `.hard`, not the
    /// rating whose raw value is 3.
    func testAutoAdvanceMapsAnswerActions() {
        XCTAssertEqual(AutoAdvanceAction.forAnswer(.buryCard), .bury)
        XCTAssertEqual(AutoAdvanceAction.forAnswer(.answerAgain), .answer(.again))
        XCTAssertEqual(AutoAdvanceAction.forAnswer(.answerGood), .answer(.good))
        XCTAssertEqual(AutoAdvanceAction.forAnswer(.answerHard), .answer(.hard))
        XCTAssertEqual(AutoAdvanceAction.forAnswer(.showReminder), .showReminder)
    }

    /// `plan(showingAnswer:)` picks the shown side's seconds + action, and returns
    /// nil when that side's timer is 0 (disabled) — matching Anki's per-side
    /// enable-by-nonzero-seconds behavior.
    func testAutoAdvancePlanPerSideAndZeroDisables() {
        let questionOnly = AutoAdvanceConfig(
            secondsToShowQuestion: 5, secondsToShowAnswer: 0,
            questionAction: .showAnswer, answerAction: .buryCard
        )
        XCTAssertEqual(questionOnly.plan(showingAnswer: false),
                       AutoAdvancePlan(seconds: 5, action: .showAnswer))
        XCTAssertNil(questionOnly.plan(showingAnswer: true),
                     "0 seconds disables the answer side")

        let answerOnly = AutoAdvanceConfig(
            secondsToShowQuestion: 0, secondsToShowAnswer: 9,
            questionAction: .showReminder, answerAction: .answerHard
        )
        XCTAssertNil(answerOnly.plan(showingAnswer: false),
                     "0 seconds disables the question side")
        XCTAssertEqual(answerOnly.plan(showingAnswer: true),
                       AutoAdvancePlan(seconds: 9, action: .answer(.hard)))
    }

    /// `AutoAdvanceConfig(config:)` reads the four fields off a deck config's
    /// `Config` message.
    func testAutoAdvanceConfigInitFromConfigMessage() {
        var config = Anki_DeckConfig_DeckConfig.Config()
        config.secondsToShowQuestion = 4
        config.secondsToShowAnswer = 7
        config.questionAction = .showReminder
        config.answerAction = .answerAgain
        let settings = AutoAdvanceConfig(config: config)
        XCTAssertEqual(settings.secondsToShowQuestion, 4)
        XCTAssertEqual(settings.secondsToShowAnswer, 7)
        XCTAssertEqual(settings.questionAction, .showReminder)
        XCTAssertEqual(settings.answerAction, .answerAgain)
    }

    /// A card's governing deck is its home deck when it's in a filtered deck
    /// (`originalDeckID` set), else its own deck — Anki's `current_deck_id()`.
    func testAutoAdvanceEffectiveDeckIDPrefersOriginal() {
        XCTAssertEqual(AutoAdvanceConfig.effectiveDeckID(deckID: 42, originalDeckID: 0), 42)
        XCTAssertEqual(AutoAdvanceConfig.effectiveDeckID(deckID: 99, originalDeckID: 42), 42)
    }

    /// End-to-end: a fresh deck's preset reports auto-advance disabled with Anki's
    /// default actions; editing the preset's auto-advance fields through the
    /// deck-options RPC is then read back by `autoAdvanceConfig(forDeckID:)` — the
    /// path the reviewer uses to source per-card timing/actions from the engine.
    func testAutoAdvanceConfigReadsEditedDeckConfig() throws {
        let backend = try freshCollection()
        let deckID = try backend.createDeck(name: "AutoAdvance")

        let defaults = try backend.autoAdvanceConfig(forDeckID: deckID)
        XCTAssertEqual(defaults.secondsToShowQuestion, 0)
        XCTAssertEqual(defaults.secondsToShowAnswer, 0)
        XCTAssertEqual(defaults.questionAction, .showAnswer)
        XCTAssertEqual(defaults.answerAction, .buryCard)

        // Edit the deck's assigned preset via the same RPC the deck-options screen
        // uses (update_deck_configs, 11/7), mirroring `setDeckLimits`.
        let forUpdate = try backend.deckConfigsForUpdate(deckID: deckID)
        let configID = forUpdate.currentDeck.configID
        var selected = try XCTUnwrap(
            forUpdate.allConfig.first { $0.config.id == configID }?.config,
            "the deck's assigned preset should be among the configs"
        )
        selected.config.secondsToShowQuestion = 6
        selected.config.secondsToShowAnswer = 12
        selected.config.questionAction = .showReminder
        selected.config.answerAction = .answerGood

        var req = Anki_DeckConfig_UpdateDeckConfigsRequest()
        req.targetDeckID = deckID
        req.configs = [selected]
        req.mode = .normal
        req.cardStateCustomizer = forUpdate.cardStateCustomizer
        req.limits = forUpdate.currentDeck.limits
        req.newCardsIgnoreReviewLimit = forUpdate.newCardsIgnoreReviewLimit
        req.fsrs = forUpdate.fsrs
        req.applyAllParentLimits = forUpdate.applyAllParentLimits
        req.fsrsReschedule = false
        req.fsrsHealthCheck = forUpdate.fsrsHealthCheck
        _ = try backend.run(
            service: 11, method: 7, req, returning: Anki_Collection_OpChangesWithId.self
        )

        let edited = try backend.autoAdvanceConfig(forDeckID: deckID)
        XCTAssertEqual(edited.secondsToShowQuestion, 6, "reads the edited question seconds")
        XCTAssertEqual(edited.secondsToShowAnswer, 12, "reads the edited answer seconds")
        XCTAssertEqual(edited.questionAction, .showReminder)
        XCTAssertEqual(edited.answerAction, .answerGood)

        // …and the resolved per-side plans reflect the edited timing/actions.
        XCTAssertEqual(edited.plan(showingAnswer: false),
                       AutoAdvancePlan(seconds: 6, action: .showReminder))
        XCTAssertEqual(edited.plan(showingAnswer: true),
                       AutoAdvancePlan(seconds: 12, action: .answer(.good)))
    }

    // MARK: - Note editor parity

    /// The cloze stock note type a fresh collection ships (for cloze-specific
    /// checks / previews).
    private func clozeNotetypeID(_ backend: Backend) throws -> Int64 {
        let notetypes = try backend.notetypeNames()
        let cloze = try XCTUnwrap(
            notetypes.first(where: { $0.name.hasPrefix("Cloze") }),
            "fresh collection should ship a Cloze notetype"
        )
        return cloze.id
    }

    /// `note_fields_check` (NotesService 25,11) over the live engine: a fresh
    /// first field is NORMAL, an empty one is EMPTY, and one matching an existing
    /// note of the same type is DUPLICATE — but only when the id differs (an
    /// EDIT-mode self-check passing the note's own id is NORMAL, not a dupe).
    func testNoteFieldsCheckStates() throws {
        let backend = try freshCollection()
        let notetypeID = try basicNotetypeID(backend)

        // Clean, non-duplicate note.
        XCTAssertEqual(
            try backend.noteFieldsCheck(notetypeID: notetypeID, fields: ["Bonjour", "Hello"]),
            .normal
        )
        // Empty first field.
        XCTAssertEqual(
            try backend.noteFieldsCheck(notetypeID: notetypeID, fields: ["", "Hello"]),
            .empty
        )

        // Persist it, then an identical first field is a duplicate.
        let noteID = try backend.addNote(notetypeID: notetypeID, fields: ["Bonjour", "Hello"], deckID: 1)
        XCTAssertEqual(
            try backend.noteFieldsCheck(notetypeID: notetypeID, fields: ["Bonjour", "Different"]),
            .duplicate
        )
        // Passing the note's own id excludes it (EDIT mode → not a self-duplicate).
        XCTAssertEqual(
            try backend.noteFieldsCheck(
                notetypeID: notetypeID, fields: ["Bonjour", "Hello"], noteID: noteID
            ),
            .normal
        )
    }

    /// Cloze-specific fields-check states + `cloze_numbers_in_note`: a `{{cN::…}}`
    /// in a non-cloze type is NOTETYPE_NOT_CLOZE; a cloze type with no deletions
    /// is MISSING_CLOZE; and the cloze numbers are enumerated for the preview.
    func testClozeChecksAndNumbers() throws {
        let backend = try freshCollection()
        let basic = try basicNotetypeID(backend)
        let cloze = try clozeNotetypeID(backend)

        XCTAssertEqual(
            try backend.noteFieldsCheck(notetypeID: basic, fields: ["{{c1::x}}", ""]),
            .notetypeNotCloze
        )
        XCTAssertEqual(
            try backend.noteFieldsCheck(notetypeID: cloze, fields: ["no deletions here", ""]),
            .missingCloze
        )
        XCTAssertEqual(
            try backend.noteFieldsCheck(notetypeID: cloze, fields: ["{{c1::a}} and {{c2::b}}", ""]),
            .normal
        )
        XCTAssertEqual(
            try backend.clozeNumbersInNote(notetypeID: cloze, fields: ["{{c1::a}} {{c2::b}}", ""]),
            [1, 2]
        )
        XCTAssertEqual(
            try backend.clozeNumbersInNote(notetypeID: cloze, fields: ["plain", ""]),
            []
        )
    }

    /// The pure state→warning mapping the editor uses: every engine state maps to
    /// the right `NoteFieldsWarning` (or nil), only the duplicate highlights the
    /// first field, and every warning has a non-empty message.
    func testNoteFieldsWarningMapping() {
        XCTAssertNil(Anki_Notes_NoteFieldsCheckResponse.State.normal.editorWarning)
        XCTAssertEqual(Anki_Notes_NoteFieldsCheckResponse.State.duplicate.editorWarning, .duplicate)
        XCTAssertEqual(Anki_Notes_NoteFieldsCheckResponse.State.empty.editorWarning, .emptyFirstField)
        XCTAssertEqual(Anki_Notes_NoteFieldsCheckResponse.State.missingCloze.editorWarning, .missingCloze)
        XCTAssertEqual(
            Anki_Notes_NoteFieldsCheckResponse.State.notetypeNotCloze.editorWarning,
            .clozeOutsideClozeNotetype
        )
        XCTAssertEqual(
            Anki_Notes_NoteFieldsCheckResponse.State.fieldNotCloze.editorWarning,
            .clozeInNonClozeField
        )

        // Only the duplicate warns with the red first-field highlight.
        XCTAssertTrue(NoteFieldsWarning.duplicate.highlightsFirstField)
        for warning: NoteFieldsWarning in [.emptyFirstField, .missingCloze, .clozeOutsideClozeNotetype, .clozeInNonClozeField] {
            XCTAssertFalse(warning.highlightsFirstField)
        }
        for warning: NoteFieldsWarning in [.duplicate, .emptyFirstField, .missingCloze, .clozeOutsideClozeNotetype, .clozeInNonClozeField] {
            XCTAssertFalse(warning.message.isEmpty)
        }
    }

    /// The per-notetype sticky mutators + their load-mutate-save wrapper round-trip
    /// through the live engine: flipping a field's sticky flag persists to the note
    /// type (survives a re-read), exactly like Anki's sticky fields.
    func testStickyFieldRoundTrip() throws {
        let backend = try freshCollection()
        let notetypeID = try basicNotetypeID(backend)

        // A fresh Basic type has no sticky fields.
        XCTAssertEqual(try backend.notetypeFieldStickies(notetypeID: notetypeID), [false, false])

        // Pure mutator: flip the first field sticky in-memory.
        var nt = try backend.notetype(id: notetypeID)
        XCTAssertEqual(nt.fieldStickies, [false, false])
        XCTAssertEqual(nt.toggleFieldSticky(at: 0), true)
        XCTAssertEqual(nt.fieldStickies, [true, false])
        nt.setFieldSticky(at: 0, false)
        XCTAssertEqual(nt.fieldStickies, [false, false])
        XCTAssertNil(nt.toggleFieldSticky(at: 9)) // out of range → nil

        // Backend wrapper persists it: re-reading reflects the change.
        try backend.setNotetypeFieldSticky(notetypeID: notetypeID, at: 0, sticky: true)
        XCTAssertEqual(try backend.notetypeFieldStickies(notetypeID: notetypeID), [true, false])
        try backend.setNotetypeFieldSticky(notetypeID: notetypeID, at: 0, sticky: false)
        XCTAssertEqual(try backend.notetypeFieldStickies(notetypeID: notetypeID), [false, false])
    }

    /// The editor's Preview data source (`render_uncommitted_card` per card): a
    /// Basic note yields one card whose rendered HTML reflects the uncommitted
    /// field values, and a cloze note yields one card per cloze number.
    func testRenderUncommittedNoteCards() throws {
        let backend = try freshCollection()
        let basic = try basicNotetypeID(backend)
        let cloze = try clozeNotetypeID(backend)

        let basicCards = try backend.renderUncommittedNoteCards(
            notetypeID: basic, fields: ["Capital of France", "Paris"]
        )
        XCTAssertEqual(basicCards.count, 1, "Basic has a single card template")
        let front = try XCTUnwrap(basicCards.first)
        XCTAssertEqual(front.ordinal, 0)
        XCTAssertTrue(front.question.contains("Capital of France"), "front reflects field 1")
        XCTAssertTrue(front.answer.contains("Paris"), "back reflects field 2")
        XCTAssertFalse(front.css.isEmpty, "carries the note type CSS")

        // A two-deletion cloze note previews two cards (Cloze 1 / Cloze 2).
        let clozeCards = try backend.renderUncommittedNoteCards(
            notetypeID: cloze, fields: ["{{c1::alpha}} then {{c2::beta}}", ""]
        )
        XCTAssertEqual(clozeCards.count, 2)
        XCTAssertEqual(clozeCards.map { $0.ordinal }, [0, 1])
        XCTAssertEqual(clozeCards.map { $0.label }, ["Cloze 1", "Cloze 2"])
    }

    /// Tag-autocomplete pure logic: token parsing, prefix/substring filtering with
    /// hierarchical (`parent::child`) tags, exclusion of already-entered tags, and
    /// token completion.
    func testTagSuggestions() {
        let tags = ["anatomy::heart", "anatomy::lung", "biology", "chemistry"]

        // Current token = the run after the last whitespace.
        XCTAssertEqual(TagSuggestions.currentToken(in: "anat"), "anat")
        XCTAssertEqual(TagSuggestions.currentToken(in: "biology anat"), "anat")
        XCTAssertEqual(TagSuggestions.currentToken(in: "biology "), "")
        XCTAssertEqual(TagSuggestions.currentToken(in: ""), "")

        // Committed tokens exclude the partial one still being typed.
        XCTAssertEqual(TagSuggestions.committedTokens(in: "biology anat"), ["biology"])
        XCTAssertEqual(TagSuggestions.committedTokens(in: "biology chem "), ["biology", "chem"])
        XCTAssertEqual(TagSuggestions.committedTokens(in: ""), [])

        // Prefix matches (hierarchical parent) come first.
        XCTAssertEqual(
            TagSuggestions.suggestions(for: "anat", allTags: tags),
            ["anatomy::heart", "anatomy::lung"]
        )
        // Substring match on a child segment surfaces the full hierarchical tag.
        XCTAssertEqual(TagSuggestions.suggestions(for: "heart", allTags: tags), ["anatomy::heart"])
        // Case-insensitive.
        XCTAssertEqual(TagSuggestions.suggestions(for: "BIO", allTags: tags), ["biology"])
        // Already-entered tags are excluded.
        XCTAssertEqual(
            TagSuggestions.suggestions(for: "anat", allTags: tags, existing: ["anatomy::heart"]),
            ["anatomy::lung"]
        )
        // An exact, complete token yields no suggestion, and an empty token none.
        XCTAssertEqual(TagSuggestions.suggestions(for: "biology", allTags: tags), [])
        XCTAssertEqual(TagSuggestions.suggestions(for: "", allTags: tags), [])

        // Completion replaces the partial token and appends a trailing space,
        // leaving earlier tags intact.
        XCTAssertEqual(
            TagSuggestions.complete("biology anat", with: "anatomy::heart"),
            "biology anatomy::heart "
        )
        XCTAssertEqual(TagSuggestions.complete("anat", with: "anatomy::heart"), "anatomy::heart ")
    }
}
