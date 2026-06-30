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
    /// single browser-row call (state derived from the row's color). It returns
    /// the engine-stripped question/answer snippet, the deck name, and the
    /// default (unflagged, unsuspended) state for a fresh card.
    func testCardBrowserRowReturnsSnippetDeckAndState() throws {
        let backend = try freshCollection()
        let notetypeID = try basicNotetypeID(backend)
        let nid = try backend.addNote(notetypeID: notetypeID, fields: ["Front Q", "Back A"], deckID: 1)

        let ids = try backend.searchCards(query: "")
        let rows = try backend.cardBrowserRows(cardIDs: ids)
        let row = try XCTUnwrap(rows.first, "the added card should produce a browser row")
        XCTAssertTrue(row.question.contains("Front Q"), "question snippet should show the front")
        XCTAssertTrue(row.answer.contains("Back A"), "answer snippet should show the back")
        XCTAssertEqual(row.deck, "Default", "card lives in the Default deck")
        XCTAssertEqual(row.flag, 0, "a new card has no flag")
        XCTAssertFalse(row.suspended, "a new card is not suspended")
        // The owning note id (used to open the editor) is resolved on demand via
        // getCard rather than carried on every row, so verify that linkage here.
        XCTAssertEqual(try backend.getCard(cardID: row.id).noteID, nid,
                       "the row's card should resolve back to its note")
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
}
