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
}
