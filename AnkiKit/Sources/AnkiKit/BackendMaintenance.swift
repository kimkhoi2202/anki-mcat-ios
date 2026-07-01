import Foundation
import SwiftProtobuf

/// Collection-maintenance convenience methods, cloning AnkiDroid's Advanced /
/// database-tools actions. Service/method indices come from the generated
/// `_backend_generated.py` reference:
///
/// | action          | service.method | request → response                         |
/// |-----------------|----------------|--------------------------------------------|
/// | check database  | 3.6            | Empty → CheckDatabaseResponse (`problems`) |
/// | get empty cards | 27.5           | Empty → EmptyCardsReport                   |
/// | remove cards    | 5.2            | RemoveCardsRequest → OpChangesWithCount    |
///
/// "Force full sync" has no protobuf RPC: both pylib (`Collection.mod_schema` →
/// `update col set scm=?`) and AnkiDroid (`setSchemaModified`) bump the schema
/// modification time with a direct SQL write, which we mirror through
/// `runDBCommand` (`anki_run_db_command`).
public extension Backend {
    /// CollectionService.checkDatabase (3, 6). Runs Anki's "Check database"
    /// (fsck): a full integrity/repair pass returning the list of problems it
    /// found and fixed (empty when the collection is healthy). This can take a
    /// while on a large collection, so callers run it off the main actor.
    func checkDatabase() throws -> [String] {
        try run(
            service: 3, method: 6,
            Anki_Generic_Empty(), returning: Anki_Collection_CheckDatabaseResponse.self
        ).problems
    }

    /// CardRenderingService.getEmptyCards (27, 5). Returns the notes that have
    /// empty cards (a card whose template renders to nothing), each with the
    /// specific empty card ids and whether removing them would delete the whole
    /// note. Read-only — the report is shown before the user confirms deletion.
    func emptyCardsReport() throws -> Anki_CardRendering_EmptyCardsReport {
        try run(
            service: 27, method: 5,
            Anki_Generic_Empty(), returning: Anki_CardRendering_EmptyCardsReport.self
        )
    }

    /// CardsService.removeCards (5, 2). Deletes the given cards (and any notes
    /// left with no cards — the core removes orphaned notes, matching pylib's
    /// `remove_cards_and_orphaned_notes`). Returns the number of cards removed.
    @discardableResult
    func removeCards(cardIDs: [Int64]) throws -> Int {
        var req = Anki_Cards_RemoveCardsRequest()
        req.cardIds = cardIDs
        let resp = try run(
            service: 5, method: 2, req, returning: Anki_Collection_OpChangesWithCount.self
        )
        return Int(resp.count)
    }

    /// Arms a one-way / full sync on the *next* sync, mirroring AnkiDroid's
    /// "Force a one-way sync" (`Collection.modSchema(check = false)` →
    /// `setSchemaModified`) and pylib's `Collection.mod_schema`. Both perform a
    /// direct `update col set scm=?` so the schema modification time exceeds the
    /// last-sync time (`scm > ls`), which the sync handshake detects and requires
    /// a full up/down sync for. Also bumps `mod` like AnkiDroid. As a side effect
    /// (as upstream documents) this discards the undo and study queues.
    ///
    /// `now` is injectable for tests; production uses the current time in ms.
    func setSchemaModified(now: Date = Date()) throws {
        let ms = Int64((now.timeIntervalSince1970 * 1000).rounded())
        _ = try runDBCommand(
            DBRequest.query(sql: "update col set scm=?, mod=?", intArgs: [ms, ms])
        )
    }

    /// Whether the collection's schema has changed since the last sync
    /// (`scm > ls`) — i.e. the next sync will be a full sync. Lets the UI show
    /// when a full sync is already armed. Reads the flag with a scalar DB query.
    func schemaChanged() throws -> Bool {
        let data = try runDBCommand(
            DBRequest.query(sql: "select scm > ls from col", intArgs: [], firstRowOnly: true)
        )
        return (DBRequest.firstScalarInt(data) ?? 0) != 0
    }
}

/// Builds/parses the JSON payloads for `Backend.runDBCommand`, matching Anki's
/// `DbRequest`/`DbResult` serde shapes (`rslib/src/backend/dbproxy.rs`). Kept as
/// pure, dependency-free logic so the payload construction is unit-testable
/// without a live backend.
public enum DBRequest {
    /// Encodes a `query`-kind request with integer bind args (the only kind the
    /// maintenance helpers need). `first_row_only` mirrors the proto field that
    /// selects `db_query_row` vs `db_query`.
    public static func query(
        sql: String, intArgs: [Int64], firstRowOnly: Bool = false
    ) -> Data {
        let object: [String: Any] = [
            "kind": "query",
            "sql": sql,
            "args": intArgs.map { NSNumber(value: $0) },
            "first_row_only": firstRowOnly,
        ]
        // These inputs are always encodable; fall back to an empty object rather
        // than throwing so a scheduling/maintenance call can't crash the app.
        return (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
    }

    /// Extracts the first scalar integer from a `DbResult` JSON payload — an
    /// array of rows (`[[value, …], …]`), each row an array of column values.
    /// Returns nil when the result is `null`/empty or the first cell isn't a
    /// number. Used to read single-value queries like `select scm > ls from col`.
    public static func firstScalarInt(_ data: Data) -> Int64? {
        guard
            let top = try? JSONSerialization.jsonObject(with: data),
            let rows = top as? [Any],
            let firstRow = rows.first as? [Any],
            let cell = firstRow.first as? NSNumber
        else { return nil }
        return cell.int64Value
    }
}

/// A view-facing summary of a "Check database" run, decoupling the SwiftUI layer
/// from the raw `problems` list. Pure and testable.
public struct DatabaseCheckSummary: Equatable, Sendable {
    /// The problems the check found and fixed (verbatim from the engine).
    public let problems: [String]

    public init(problems: [String]) {
        self.problems = problems
    }

    /// Whether the collection was healthy (no problems found).
    public var isHealthy: Bool { problems.isEmpty }

    /// A one-line headline: Anki's "Database rebuilt and optimized." on success,
    /// or an "N problem(s) found and fixed" count otherwise.
    public var headline: String {
        if isHealthy { return "Database rebuilt and optimized." }
        let n = problems.count
        return n == 1 ? "1 problem found and fixed." : "\(n) problems found and fixed."
    }
}

/// A view-facing summary of an "Empty cards" report: the total empty cards, how
/// many notes they span, and which notes would be deleted entirely. Also exposes
/// the flat list of card ids to remove. Pure and testable.
public struct EmptyCardsSummary: Equatable, Sendable {
    /// Number of notes that have at least one empty card.
    public let noteCount: Int
    /// Total number of empty cards across those notes.
    public let cardCount: Int
    /// Number of notes that would be deleted entirely (all their cards empty).
    public let notesToDeleteCount: Int
    /// Every empty card id, ready to pass to `removeCards`.
    public let cardIDsToDelete: [Int64]

    public init(
        noteCount: Int, cardCount: Int, notesToDeleteCount: Int, cardIDsToDelete: [Int64]
    ) {
        self.noteCount = noteCount
        self.cardCount = cardCount
        self.notesToDeleteCount = notesToDeleteCount
        self.cardIDsToDelete = cardIDsToDelete
    }

    /// Maps a raw `EmptyCardsReport` to the summary, flattening every note's
    /// empty card ids (mirrors Anki's default "delete all empty cards", which
    /// removes notes left with no cards as orphans).
    public init(_ report: Anki_CardRendering_EmptyCardsReport) {
        var ids: [Int64] = []
        var toDelete = 0
        for note in report.notes {
            ids.append(contentsOf: note.cardIds)
            if note.willDeleteNote { toDelete += 1 }
        }
        self.init(
            noteCount: report.notes.count,
            cardCount: ids.count,
            notesToDeleteCount: toDelete,
            cardIDsToDelete: ids
        )
    }

    /// Whether there are any empty cards to remove.
    public var isEmpty: Bool { cardCount == 0 }

    /// A one-line headline describing what deletion will do, e.g.
    /// "3 empty cards in 2 notes (1 note will be deleted)".
    public var headline: String {
        if isEmpty { return "No empty cards." }
        let cards = cardCount == 1 ? "1 empty card" : "\(cardCount) empty cards"
        let notes = noteCount == 1 ? "1 note" : "\(noteCount) notes"
        var text = "\(cards) in \(notes)"
        if notesToDeleteCount > 0 {
            let deleted = notesToDeleteCount == 1
                ? "1 note will be deleted"
                : "\(notesToDeleteCount) notes will be deleted"
            text += " (\(deleted))"
        }
        return text
    }
}
