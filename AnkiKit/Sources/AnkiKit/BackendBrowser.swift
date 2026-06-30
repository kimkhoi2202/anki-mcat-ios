import Foundation
import SwiftProtobuf

/// One row of the Card Browser, assembled entirely from the engine's
/// browser-row API. Decouples the SwiftUI layer from the generated protobuf
/// (the same way `DeckTreeEntry`/`NoteForEditing` do).
///
/// Mirrors AnkiDroid's CardBrowser row: a question/answer snippet, the deck name,
/// and the per-card flag / suspended indicators. Built from a single
/// `browser_row_for_id` call (one backend call per displayed row); the owning
/// note id isn't carried here because the browser only needs it for the rare
/// single-row edit / change-note-type action, where it's resolved on demand
/// (see `Backend.getCard`) rather than fetched for every displayed row.
public struct CardBrowserRow: Identifiable, Sendable, Equatable {
    /// The card id (the browser lists one entry per card, like AnkiDroid's
    /// default cards mode).
    public let id: Int64
    /// Engine-stripped question text (HTML reduced to one display line).
    public let question: String
    /// Engine-stripped answer text (with the shared question prefix removed).
    public let answer: String
    /// Human-readable deck name (including any filtered-deck origin).
    public let deck: String
    /// Flag color, 0 = none, 1...7 = red/orange/green/blue/pink/turquoise/purple.
    public let flag: Int
    /// Whether the card is currently suspended.
    public let suspended: Bool

    public init(
        id: Int64, question: String, answer: String,
        deck: String, flag: Int, suspended: Bool
    ) {
        self.id = id
        self.question = question
        self.answer = answer
        self.deck = deck
        self.flag = flag
        self.suspended = suspended
    }
}

/// Card Browser convenience methods. Service/method indices come from the
/// generated `_backend_generated.py` reference; message shapes from the
/// `search.proto` / `cards.proto` / `notes.proto` / `scheduler.proto` definitions.
public extension Backend {
    /// The columns the browser list renders, in display order: a question and
    /// answer snippet plus the deck. `browser_row_for_id` builds its cells from
    /// whatever columns are active, so this order is the cells' order. Keys are
    /// the camelCase `Column` serializations from rslib `browser_table.rs`.
    private static var browserColumns: [String] { ["question", "answer", "deck"] }

    /// Anki's default browser sort: by the note's sort field, ascending. This is
    /// the engine's own default (`"sortType": "noteFld", "sortBackwards": false`
    /// in rslib `config/schema11.rs`), applied so the list isn't in arbitrary
    /// creation order. A configurable tap-to-sort UI is a separate later task; an
    /// unknown column would be ignored by the core (`Column::from_str(..)
    /// .unwrap_or_default()`), so this is always safe.
    private static var defaultBrowserSort: Anki_Search_SortOrder {
        var order = Anki_Search_SortOrder()
        var builtin = Anki_Search_SortOrder.Builtin()
        builtin.column = "noteFld"
        builtin.reverse = false
        order.builtin = builtin
        return order
    }

    /// SearchService.searchCards (29, 1).
    ///
    /// Resolves an Anki search string (e.g. `deck:Biology tag:hard`) to the
    /// matching card ids, mirroring AnkiDroid's `col.findCards(search)`. The order
    /// is left unset, so the core returns cards in collection (creation) order.
    /// An invalid query throws a backend error, which the UI surfaces.
    func searchCards(query: String) throws -> [Int64] {
        var req = Anki_Search_SearchRequest()
        req.search = query
        return try run(service: 29, method: 1, req, returning: Anki_Search_SearchResponse.self).ids
    }

    /// Resolves a Card Browser search to its matching card ids in Anki's default
    /// browser sort order (see `defaultBrowserSort`), mirroring AnkiDroid building
    /// its browser list with the configured sort. Returns ids only, so it stays
    /// cheap even on very large collections — the row DATA for the cards actually
    /// on screen is fetched lazily, a page at a time, via `cardBrowserRows(cardIDs:)`.
    /// An invalid query throws a backend error, which the UI surfaces.
    func browserCardIDs(query: String) throws -> [Int64] {
        var req = Anki_Search_SearchRequest()
        req.search = query
        req.order = Backend.defaultBrowserSort
        return try run(service: 29, method: 1, req, returning: Anki_Search_SearchResponse.self).ids
    }

    /// SearchService.setActiveBrowserColumns (29, 8).
    ///
    /// Stores the active browser columns in the collection's in-memory state.
    /// `browserRow` requires this — without it the core returns "Active browser
    /// columns not set." (see rslib `browser_table.rs::browser_row_for_id`).
    func setActiveBrowserColumns(_ columns: [String]) throws {
        var req = Anki_Generic_StringList()
        req.vals = columns
        _ = try run(service: 29, method: 8, input: try req.serializedData())
    }

    /// SearchService.browserRowForId (29, 7).
    ///
    /// Returns the card's display cells (in the active-column order) plus a
    /// `color` encoding its flag/suspended/marked state — the data AnkiDroid's
    /// browser renders per row. The engine does the HTML→text reduction and AV
    /// tag prettifying, so the snippets are display-ready.
    func browserRow(cardID: Int64) throws -> Anki_Search_BrowserRow {
        var req = Anki_Generic_Int64()
        req.val = cardID
        return try run(service: 29, method: 7, req, returning: Anki_Search_BrowserRow.self)
    }

    /// CardsService.getCard (5, 0).
    ///
    /// Used to resolve a card's owning note id on demand — e.g. when the browser
    /// opens the editor or Change Note Type for a single tapped row — and for the
    /// reviewer's per-card needs. The browser row itself no longer needs this
    /// (its flag/suspended state comes from the browser row's `color`), so it is
    /// not called for every displayed row.
    func getCard(cardID: Int64) throws -> Anki_Cards_Card {
        var req = Anki_Cards_CardId()
        req.cid = cardID
        return try run(service: 5, method: 0, req, returning: Anki_Cards_Card.self)
    }

    /// CardsService.updateCards (5, 1).
    ///
    /// Persists full `Card` records back to the collection (read-modify-write
    /// from `getCard`). Used to write card-level scheduling fields the higher
    /// level RPCs don't expose directly — e.g. seeding FSRS memory state for the
    /// points-at-stake tests. Pass `skipUndoEntry: true` to avoid recording an
    /// undo step.
    func updateCards(_ cards: [Anki_Cards_Card], skipUndoEntry: Bool = false) throws {
        var req = Anki_Cards_UpdateCardsRequest()
        req.cards = cards
        req.skipUndoEntry = skipUndoEntry
        _ = try run(service: 5, method: 1, input: try req.serializedData())
    }

    /// Builds one display row, setting the active columns first so the call is
    /// self-contained (the batch `cardBrowserRows` sets them once and uses the
    /// private builder directly to avoid repeating the per-row column write).
    func cardBrowserRow(cardID: Int64) throws -> CardBrowserRow {
        try setActiveBrowserColumns(Backend.browserColumns)
        return try buildBrowserRow(cardID: cardID)
    }

    /// Builds the display rows for an explicit, already-resolved page of card ids
    /// — the Card Browser's windowed page fetch. Sets the active columns once,
    /// then makes exactly ONE backend call per card (`browser_row_for_id`),
    /// deriving each row's flag/suspended state from that row's `color` rather
    /// than a second `getCard`. Only the cards currently on screen are passed in,
    /// so this stays bounded regardless of how large the full result set is.
    ///
    /// A card that fails to build (e.g. concurrently deleted) is skipped rather
    /// than failing the whole page, so the result may be shorter than `cardIDs`.
    func cardBrowserRows(cardIDs: [Int64]) throws -> [CardBrowserRow] {
        try setActiveBrowserColumns(Backend.browserColumns)
        var rows: [CardBrowserRow] = []
        rows.reserveCapacity(cardIDs.count)
        for id in cardIDs {
            if let row = try? buildBrowserRow(cardID: id) {
                rows.append(row)
            }
        }
        return rows
    }

    /// Builds one display row from a single `browser_row_for_id` call: the
    /// question / answer / deck snippet cells plus the flag and suspended state,
    /// both decoded from the row's `color`. Assumes the active columns are
    /// already set (`browser_row_for_id` errors otherwise).
    private func buildBrowserRow(cardID: Int64) throws -> CardBrowserRow {
        let row = try browserRow(cardID: cardID)
        func cell(_ index: Int) -> String {
            index < row.cells.count ? row.cells[index].text : ""
        }
        let state = Backend.flagAndSuspended(from: row.color)
        return CardBrowserRow(
            id: cardID,
            question: cell(0),
            answer: cell(1),
            deck: cell(2),
            flag: state.flag,
            suspended: state.suspended
        )
    }

    /// Decodes the engine's single per-row `color` into the (flag, suspended)
    /// pair the row badges render. The core encodes ONE state per row, with the
    /// priority flag > marked > suspended > buried (rslib
    /// `browser_table.rs::get_row_color`); a card that is both flagged and
    /// suspended therefore reads as flagged, matching desktop and AnkiDroid,
    /// which likewise colour the row by this single value.
    static func flagAndSuspended(
        from color: Anki_Search_BrowserRow.Color
    ) -> (flag: Int, suspended: Bool) {
        switch color {
        case .flagRed: return (1, false)
        case .flagOrange: return (2, false)
        case .flagGreen: return (3, false)
        case .flagBlue: return (4, false)
        case .flagPink: return (5, false)
        case .flagTurquoise: return (6, false)
        case .flagPurple: return (7, false)
        case .suspended: return (0, true)
        default: return (0, false)
        }
    }

    /// SchedulerService.buryOrSuspendCards (13, 14) with mode SUSPEND. Returns
    /// the number of cards affected. Mirrors AnkiDroid's `sched.suspendCards`.
    @discardableResult
    func suspendCards(cardIDs: [Int64]) throws -> Int {
        var req = Anki_Scheduler_BuryOrSuspendCardsRequest()
        req.cardIds = cardIDs
        req.mode = .suspend
        let resp = try run(service: 13, method: 14, req, returning: Anki_Collection_OpChangesWithCount.self)
        return Int(resp.count)
    }

    /// SchedulerService.restoreBuriedAndSuspendedCards (13, 12). Unsuspends (and
    /// unburies) the given cards. Mirrors AnkiDroid's `sched.unsuspendCards`.
    func unsuspendCards(cardIDs: [Int64]) throws {
        var req = Anki_Cards_CardIds()
        req.cids = cardIDs
        _ = try run(service: 13, method: 12, input: try req.serializedData())
    }

    /// CardsService.setFlag (5, 4). `flag` 0 clears the flag; 1...7 set a color.
    /// Returns the number of cards affected. Mirrors AnkiDroid's flag actions.
    @discardableResult
    func setFlag(cardIDs: [Int64], flag: Int) throws -> Int {
        var req = Anki_Cards_SetFlagRequest()
        req.cardIds = cardIDs
        req.flag = UInt32(flag)
        let resp = try run(service: 5, method: 4, req, returning: Anki_Collection_OpChangesWithCount.self)
        return Int(resp.count)
    }

    /// NotesService.removeNotes (25, 7) by card ids.
    ///
    /// Deletes the notes *behind* the given cards (and therefore all of those
    /// notes' cards) — the core resolves card ids to their notes. Returns the
    /// number of notes removed. Mirrors AnkiDroid's `deleteSelectedNotes`, which
    /// calls `removeNotes(cardIds = ...)`.
    @discardableResult
    func removeNotesForCards(cardIDs: [Int64]) throws -> Int {
        var req = Anki_Notes_RemoveNotesRequest()
        req.cardIds = cardIDs
        let resp = try run(service: 25, method: 7, req, returning: Anki_Collection_OpChangesWithCount.self)
        return Int(resp.count)
    }
}
