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
