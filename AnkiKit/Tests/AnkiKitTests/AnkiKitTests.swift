import Foundation
import XCTest
@testable import AnkiKit

final class AnkiKitTests: XCTestCase {
    func testBuildHash() {
        let hash = Backend.buildHash()
        print("buildHash:", hash)
        XCTAssertFalse(hash.isEmpty, "buildHash should be non-empty")
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
}
