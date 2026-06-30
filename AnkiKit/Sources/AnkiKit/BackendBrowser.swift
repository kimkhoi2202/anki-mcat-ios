import Foundation
import SwiftProtobuf

/// One row of the Card Browser, assembled entirely from the engine's
/// browser-row API. Decouples the SwiftUI layer from the generated protobuf
/// (the same way `DeckTreeEntry`/`NoteForEditing` do).
///
/// Mirrors AnkiDroid's CardBrowser row: the engine-stripped cell text for each
/// *active* column (in column order) plus the per-card flag / suspended
/// indicators. Built from a single `browser_row_for_id` call (one backend call
/// per displayed row); the owning note id isn't carried here because the
/// browser only needs it for the rare single-row edit / change-note-type
/// action, where it's resolved on demand (see `Backend.getCard`) rather than
/// fetched for every displayed row.
///
/// The cells are generalized from the original hardcoded question/answer/deck to
/// the N columns the user has configured: `cells[i]` is the display text for the
/// column at index `i` of the active-columns list passed to `cardBrowserRows`.
public struct CardBrowserRow: Identifiable, Sendable, Equatable {
    /// The card id (the browser lists one entry per card, like AnkiDroid's
    /// default cards mode).
    public let id: Int64
    /// Engine-stripped, display-ready cell text for each active column, in the
    /// same order the columns were requested. The engine does the HTML→text
    /// reduction and AV-tag prettifying, so each cell is ready to render.
    public let cells: [String]
    /// Flag color, 0 = none, 1...7 = red/orange/green/blue/pink/turquoise/purple.
    public let flag: Int
    /// Whether the card is currently suspended.
    public let suspended: Bool

    public init(id: Int64, cells: [String], flag: Int, suspended: Bool) {
        self.id = id
        self.cells = cells
        self.flag = flag
        self.suspended = suspended
    }

    /// The cell text at `index`, or "" when out of range — defensive for a row
    /// built from fewer columns than the renderer happens to expect.
    public func cell(_ index: Int) -> String {
        index >= 0 && index < cells.count ? cells[index] : ""
    }
}

/// A selectable browser column, decoded from the engine's `all_browser_columns`
/// list: the `key` the engine identifies it by (used both to activate it and to
/// sort on it), a human display `label`, and whether/how the engine can sort by
/// it. Drives the column picker and the sort menu.
public struct BrowserColumn: Identifiable, Sendable, Equatable, Hashable {
    /// The engine column key (the camelCase `Column` serialization, e.g.
    /// `question`, `deck`, `cardDue`, `noteFld`).
    public let key: String
    /// The cards-mode display label (e.g. "Question", "Due"), already localized
    /// by the engine.
    public let label: String
    /// Whether the engine can sort the result by this column (some columns, like
    /// the rendered question/answer, aren't sortable).
    public let sortable: Bool
    /// The column's natural default direction when first sorted (some columns —
    /// e.g. due/created — default to descending on desktop).
    public let defaultReverse: Bool

    public var id: String { key }

    public init(key: String, label: String, sortable: Bool, defaultReverse: Bool) {
        self.key = key
        self.label = label
        self.sortable = sortable
        self.defaultReverse = defaultReverse
    }
}

/// A browser sort choice: which builtin column to order by, and whether to
/// reverse it. Generalizes the old fixed "sort field, ascending" default into a
/// value the UI can change and persist.
public struct BrowserSort: Sendable, Equatable {
    /// The builtin column key to sort by (parsed by the core's `Column::from_str`;
    /// an unknown key is ignored and the core falls back to its default).
    public var column: String
    /// Sort descending when true.
    public var reverse: Bool

    public init(column: String, reverse: Bool) {
        self.column = column
        self.reverse = reverse
    }

    /// Anki's engine default browser sort: by the note's sort field, ascending
    /// (`"sortType": "noteFld", "sortBackwards": false` in rslib
    /// `config/schema11.rs`), so the list isn't in arbitrary creation order.
    public static let `default` = BrowserSort(column: "noteFld", reverse: false)
}

/// Card Browser convenience methods. Service/method indices come from the
/// generated `_backend_generated.py` reference; message shapes from the
/// `search.proto` / `cards.proto` / `notes.proto` / `scheduler.proto` definitions.
public extension Backend {
    /// Anki's default browser columns (question/answer snippet + deck), the
    /// out-of-the-box layout AnkiDroid/desktop show before any customization.
    /// `browser_row_for_id` builds its cells from whatever columns are active, so
    /// this order is the cells' order. Keys are the camelCase `Column`
    /// serializations from rslib `browser_table.rs`. Used as the fallback when no
    /// custom column set is configured.
    static let defaultBrowserColumns: [String] = ["question", "answer", "deck"]

    /// Builds the engine `SortOrder` for a `BrowserSort`. An unknown column would
    /// be ignored by the core (`Column::from_str(..).unwrap_or_default()`), so any
    /// value here is safe.
    private static func sortOrder(from sort: BrowserSort) -> Anki_Search_SortOrder {
        var order = Anki_Search_SortOrder()
        var builtin = Anki_Search_SortOrder.Builtin()
        builtin.column = sort.column
        builtin.reverse = sort.reverse
        order.builtin = builtin
        return order
    }

    /// SearchService.allBrowserColumns (29, 6).
    ///
    /// The full set of columns the browser can show — the source for the column
    /// picker (which columns + order) and the sort menu (which columns are
    /// sortable and their default direction). Each entry carries the engine
    /// `key` (used to activate the column AND to sort by it), the cards-mode
    /// display label, and the column's sort capability. Mirrors AnkiDroid's
    /// column manager, which lists the same engine-provided columns.
    func allBrowserColumns() throws -> [BrowserColumn] {
        let resp = try run(
            service: 29, method: 6, Anki_Generic_Empty(),
            returning: Anki_Search_BrowserColumns.self
        )
        return resp.columns.map { col in
            BrowserColumn(
                key: col.key,
                label: col.cardsModeLabel.isEmpty ? col.key : col.cardsModeLabel,
                sortable: col.sortingCards != .none,
                defaultReverse: col.sortingCards == .descending
            )
        }
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

    /// SearchService.searchNotes (29, 2).
    ///
    /// Resolves an Anki search string to the matching NOTE ids (a note's sibling
    /// cards collapse to a single note). Used to scope Find & Replace to "all
    /// matching notes" when the browser has no explicit selection.
    func searchNotes(query: String) throws -> [Int64] {
        var req = Anki_Search_SearchRequest()
        req.search = query
        return try run(service: 29, method: 2, req, returning: Anki_Search_SearchResponse.self).ids
    }

    /// Resolves a Card Browser search to its matching card ids in the given sort
    /// order, mirroring AnkiDroid building its browser list with the configured
    /// sort. Returns ids only, so it stays cheap even on very large collections —
    /// the row DATA for the cards actually on screen is fetched lazily, a page at
    /// a time, via `cardBrowserRows(cardIDs:columns:)`. An invalid query throws a
    /// backend error, which the UI surfaces.
    func browserCardIDs(query: String, sort: BrowserSort) throws -> [Int64] {
        var req = Anki_Search_SearchRequest()
        req.search = query
        req.order = Backend.sortOrder(from: sort)
        return try run(service: 29, method: 1, req, returning: Anki_Search_SearchResponse.self).ids
    }

    /// Convenience overload using Anki's default browser sort (sort field,
    /// ascending). Kept so callers that don't drive a custom sort stay simple.
    func browserCardIDs(query: String) throws -> [Int64] {
        try browserCardIDs(query: query, sort: .default)
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
    /// level RPCs don't expose directly — e.g. seeding FSRS memory state. Pass
    /// `skipUndoEntry: true` to avoid recording an undo step.
    func updateCards(_ cards: [Anki_Cards_Card], skipUndoEntry: Bool = false) throws {
        var req = Anki_Cards_UpdateCardsRequest()
        req.cards = cards
        req.skipUndoEntry = skipUndoEntry
        _ = try run(service: 5, method: 1, input: try req.serializedData())
    }

    /// Builds one display row for the given active `columns`, setting them first
    /// so the call is self-contained (the batch `cardBrowserRows` sets them once
    /// and uses the private builder directly to avoid repeating the per-row column
    /// write). Defaults to the question/answer/deck layout.
    func cardBrowserRow(
        cardID: Int64, columns: [String] = Backend.defaultBrowserColumns
    ) throws -> CardBrowserRow {
        try setActiveBrowserColumns(columns)
        return try buildBrowserRow(cardID: cardID)
    }

    /// Builds the display rows for an explicit, already-resolved page of card ids
    /// — the Card Browser's windowed page fetch — for the given active `columns`.
    /// Sets the active columns once, then makes exactly ONE backend call per card
    /// (`browser_row_for_id`), deriving each row's cells from the active columns
    /// and its flag/suspended state from that row's `color` rather than a second
    /// `getCard`. Only the cards currently on screen are passed in, so this stays
    /// bounded regardless of how large the full result set is.
    ///
    /// A card that fails to build (e.g. concurrently deleted) is skipped rather
    /// than failing the whole page, so the result may be shorter than `cardIDs`.
    func cardBrowserRows(
        cardIDs: [Int64], columns: [String] = Backend.defaultBrowserColumns
    ) throws -> [CardBrowserRow] {
        try setActiveBrowserColumns(columns)
        var rows: [CardBrowserRow] = []
        rows.reserveCapacity(cardIDs.count)
        for id in cardIDs {
            if let row = try? buildBrowserRow(cardID: id) {
                rows.append(row)
            }
        }
        return rows
    }

    /// Builds one display row from a single `browser_row_for_id` call: the cell
    /// text for every active column (in order) plus the flag and suspended state,
    /// both decoded from the row's `color`. Assumes the active columns are
    /// already set (`browser_row_for_id` errors otherwise).
    private func buildBrowserRow(cardID: Int64) throws -> CardBrowserRow {
        let row = try browserRow(cardID: cardID)
        let state = Backend.flagAndSuspended(from: row.color)
        return CardBrowserRow(
            id: cardID,
            cells: row.cells.map { $0.text },
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

    // MARK: - Multi-select bulk actions
    //
    // The Card Browser's bulk operations all take an array of *card* ids (the
    // browser's selection is a set of card ids). Card-level ops (`setDeck`,
    // `setFlag`, `suspendCards`, `buryCards`, `removeNotesForCards`) hit the
    // engine directly with those ids; note-level ops (tags / marked) resolve
    // the cards to their owning notes first (`noteIDs(forCardIDs:)`). Mirrors
    // AnkiDroid's CardBrowser bulk actions, which likewise dispatch the
    // selection to the matching backend ops.

    /// CardsService.setDeck (5, 3). Moves the given cards to `deckID` (a normal,
    /// non-filtered deck), returning the number of cards moved. Mirrors
    /// AnkiDroid's browser "Change deck" (`col.setDeck(cardIds, deckId)`); the
    /// op is undoable. A card already in a filtered deck keeps that filtered
    /// placement's home set to the new deck, as the core handles.
    @discardableResult
    func setDeck(cardIDs: [Int64], deckID: Int64) throws -> Int {
        var req = Anki_Cards_SetDeckRequest()
        req.cardIds = cardIDs
        req.deckID = deckID
        let resp = try run(service: 5, method: 3, req, returning: Anki_Collection_OpChangesWithCount.self)
        return Int(resp.count)
    }

    /// Resolves a list of card ids to their owning note ids, de-duplicated and in
    /// first-seen order (sibling cards of one note collapse to a single note id).
    /// Used by the note-level bulk actions (tags / marked) so a selection of
    /// cards maps onto the notes the engine's tag RPCs operate on. A card that
    /// can't be read (e.g. concurrently deleted) is skipped.
    func noteIDs(forCardIDs cardIDs: [Int64]) throws -> [Int64] {
        var seen = Set<Int64>()
        var noteIDs: [Int64] = []
        for cardID in cardIDs {
            guard let noteID = try? getCard(cardID: cardID).noteID else { continue }
            if seen.insert(noteID).inserted { noteIDs.append(noteID) }
        }
        return noteIDs
    }

    /// Adds the given space-separated tag(s) to the notes behind the cards,
    /// returning the number of notes changed. Card-id wrapper over
    /// `addNoteTags` for the browser's bulk "Add tags". Undoable.
    @discardableResult
    func addTags(cardIDs: [Int64], tags: String) throws -> Int {
        let noteIDs = try noteIDs(forCardIDs: cardIDs)
        guard !noteIDs.isEmpty else { return 0 }
        return try addNoteTags(noteIDs: noteIDs, tags: tags)
    }

    /// Removes the given space-separated tag(s) from the notes behind the cards,
    /// returning the number of notes changed. Card-id wrapper over
    /// `removeNoteTags` for the browser's bulk "Remove tags". Undoable.
    @discardableResult
    func removeTags(cardIDs: [Int64], tags: String) throws -> Int {
        let noteIDs = try noteIDs(forCardIDs: cardIDs)
        guard !noteIDs.isEmpty else { return 0 }
        return try removeNoteTags(noteIDs: noteIDs, tags: tags)
    }

    /// Marks or unmarks the notes behind the cards by bulk add/removing the
    /// `marked` tag (Anki's marked convention; see `toggleMark`). Unlike the
    /// reviewer's per-note `toggleMark`, this sets an explicit state across the
    /// whole selection — the browser exposes separate Mark / Unmark actions, so a
    /// mixed selection lands on a single, predictable result. Returns the number
    /// of notes changed.
    @discardableResult
    func setMarked(cardIDs: [Int64], marked: Bool) throws -> Int {
        let noteIDs = try noteIDs(forCardIDs: cardIDs)
        guard !noteIDs.isEmpty else { return 0 }
        return marked
            ? try addNoteTags(noteIDs: noteIDs, tags: Backend.markedTag)
            : try removeNoteTags(noteIDs: noteIDs, tags: Backend.markedTag)
    }

    // MARK: - Find & Replace

    /// SearchService.findAndReplace (29, 5).
    ///
    /// Finds `search` in the given notes' fields and replaces it with
    /// `replacement`, returning the number of notes changed. `regex` treats
    /// `search` as a regular expression (otherwise a literal substring);
    /// `matchCase` makes the match case-sensitive. `fieldName` limits the op to a
    /// single field by name — nil or empty means ALL fields (a field name absent
    /// from a given note simply matches nothing there). Undoable via the engine
    /// (records an undo entry). Mirrors AnkiDroid's browser Find & Replace, which
    /// drives the same RPC. An invalid regex throws a backend error the UI shows.
    @discardableResult
    func findAndReplace(
        noteIDs: [Int64], search: String, replacement: String,
        regex: Bool = false, matchCase: Bool = false, fieldName: String? = nil
    ) throws -> Int {
        var req = Anki_Search_FindAndReplaceRequest()
        req.nids = noteIDs
        req.search = search
        req.replacement = replacement
        req.regex = regex
        req.matchCase = matchCase
        if let fieldName, !fieldName.isEmpty { req.fieldName = fieldName }
        let resp = try run(service: 29, method: 5, req, returning: Anki_Collection_OpChangesWithCount.self)
        return Int(resp.count)
    }

    /// The union of field names across every note type, sorted — the candidate
    /// "in field" options for Find & Replace (alongside an implicit "all
    /// fields"). Bounded by the number of note types, so it's cheap. Using the
    /// union (rather than only the scoped notes' fields) is safe because a field
    /// name absent from a given note simply matches nothing there.
    func allFieldNames() throws -> [String] {
        var seen = Set<String>()
        var names: [String] = []
        for notetype in try notetypeNames() {
            for field in (try? notetypeFields(notetypeID: notetype.id)) ?? [] {
                if seen.insert(field).inserted { names.append(field) }
            }
        }
        return names.sorted()
    }
}
