import Foundation
import XCTest
@testable import AnkiKit

final class AnkiKitTests: XCTestCase {
    /// Opens a backend on a fresh, temporary collection.
    private func freshCollection() throws -> Backend {
        let backend = try Backend()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
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

    /// `cardBrowserRow` assembles the display row the list renders: the
    /// engine-stripped question/answer snippet, the deck name, the owning note id,
    /// and default (unflagged, unsuspended) state for a fresh card.
    func testCardBrowserRowReturnsSnippetDeckAndState() throws {
        let backend = try freshCollection()
        let notetypeID = try basicNotetypeID(backend)
        let nid = try backend.addNote(notetypeID: notetypeID, fields: ["Front Q", "Back A"], deckID: 1)

        let rows = try backend.cardBrowserRows(query: "")
        let row = try XCTUnwrap(rows.first, "the added card should produce a browser row")
        XCTAssertEqual(row.noteID, nid, "row should point back to its note")
        XCTAssertTrue(row.question.contains("Front Q"), "question snippet should show the front")
        XCTAssertTrue(row.answer.contains("Back A"), "answer snippet should show the back")
        XCTAssertEqual(row.deck, "Default", "card lives in the Default deck")
        XCTAssertEqual(row.flag, 0, "a new card has no flag")
        XCTAssertFalse(row.suspended, "a new card is not suspended")
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
}
