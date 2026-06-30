import Foundation
import SwiftProtobuf

/// The order in which a filtered deck gathers its cards, mirroring Anki's
/// "Cards selected by" options (`Deck.Filtered.SearchTerm.Order`). The raw
/// values match the protobuf enum so the UI can offer a clean Swift type without
/// importing the generated enum.
public enum FilteredDeckOrder: Int, Sendable, CaseIterable, Identifiable {
    case oldestSeenFirst = 0
    case random = 1
    case increasingIntervals = 2
    case decreasingIntervals = 3
    case mostLapses = 4
    case orderAdded = 5
    case orderDue = 6
    case latestAddedFirst = 7
    case relativeOverdueness = 10

    public var id: Int { rawValue }

    /// User-facing label, matching desktop Anki's order menu (`decks_*` strings).
    public var label: String {
        switch self {
        case .oldestSeenFirst: return "Oldest seen first"
        case .random: return "Random"
        case .increasingIntervals: return "Increasing intervals"
        case .decreasingIntervals: return "Decreasing intervals"
        case .mostLapses: return "Most lapses"
        case .orderAdded: return "Order added"
        case .orderDue: return "Order due"
        case .latestAddedFirst: return "Latest added first"
        case .relativeOverdueness: return "Relative overdueness"
        }
    }

    /// Maps to the generated protobuf order enum.
    var proto: Anki_Decks_Deck.Filtered.SearchTerm.Order {
        Anki_Decks_Deck.Filtered.SearchTerm.Order(rawValue: rawValue) ?? .due
    }
}

/// The outcome of creating a filtered deck: its new id plus how many cards the
/// engine gathered into it.
public struct FilteredDeckResult: Sendable, Equatable {
    public let deckID: Int64
    public let cardCount: Int

    public init(deckID: Int64, cardCount: Int) {
        self.deckID = deckID
        self.cardCount = cardCount
    }
}

/// Filtered-deck convenience methods (Anki's custom-study essentials). The deck
/// CRUD lives on `DecksService` (service 7) and the build/empty on
/// `SchedulerService` (service 13); indices confirmed in `_backend_generated.py`:
///   - get_or_create_filtered_deck (7, 19)
///   - add_or_update_filtered_deck (7, 20)
///   - filtered_deck_order_labels (7, 21)
///   - empty_filtered_deck (13, 15)
///   - rebuild_filtered_deck (13, 16)
public extension Backend {
    /// Creates a filtered deck from a single search term and builds it.
    ///
    /// Clones Anki's create-filtered-deck flow: fetch a default template
    /// (`get_or_create_filtered_deck` with id 0), set the name and one search
    /// term (query / limit / order), then `add_or_update_filtered_deck`, which
    /// also gathers the matching cards and returns the new deck id.
    ///
    /// The engine aborts the build (and the whole creation) if the search is
    /// invalid or matches no cards — `allow_empty` is left false, matching the
    /// desktop dialog — so the thrown backend error is surfaced to the user.
    @discardableResult
    func createFilteredDeck(
        name: String, search: String, limit: Int,
        order: FilteredDeckOrder, reschedule: Bool
    ) throws -> FilteredDeckResult {
        // Start from a fresh template (id 0 → "create").
        var req = Anki_Decks_DeckId()
        req.did = 0
        var update = try run(service: 7, method: 19, req, returning: Anki_Decks_FilteredDeckForUpdate.self)

        update.name = name
        var term = Anki_Decks_Deck.Filtered.SearchTerm()
        term.search = search
        term.limit = UInt32(max(0, limit))
        term.order = order.proto
        update.config.searchTerms = [term]
        update.config.reschedule = reschedule
        // Authentic behaviour: refuse to create an empty filtered deck.
        update.allowEmpty = false

        let created = try run(service: 7, method: 20, update, returning: Anki_Collection_OpChangesWithId.self)
        let deckID = created.id
        // `add_or_update_filtered_deck` already built the deck and gathered its
        // cards; count them with a cheap search (`did:` matches cards whose deck
        // is this one) instead of calling rebuild, which would gather a second
        // time. A freshly created filtered deck has no subdecks, so this is exact.
        let count = try searchCards(query: "did:\(deckID)").count
        return FilteredDeckResult(deckID: deckID, cardCount: count)
    }

    /// SchedulerService.rebuildFilteredDeck (13, 16). Re-gathers the deck's cards
    /// from its search, returning how many were pulled in. Mirrors AnkiDroid's
    /// "Rebuild" custom-study action.
    @discardableResult
    func rebuildFilteredDeck(deckID: Int64) throws -> Int {
        var req = Anki_Decks_DeckId()
        req.did = deckID
        let resp = try run(service: 13, method: 16, req, returning: Anki_Collection_OpChangesWithCount.self)
        return Int(resp.count)
    }

    /// SchedulerService.emptyFilteredDeck (13, 15). Returns every card in the
    /// filtered deck to its home deck (the deck itself stays). Mirrors
    /// AnkiDroid's "Empty" custom-study action.
    func emptyFilteredDeck(deckID: Int64) throws {
        var req = Anki_Decks_DeckId()
        req.did = deckID
        _ = try run(service: 13, method: 15, input: try req.serializedData())
    }

    /// DecksService.filteredDeckOrderLabels (7, 21). The engine's localized
    /// "Cards selected by" labels, in `FilteredDeckOrder` raw-value order.
    func filteredDeckOrderLabels() throws -> [String] {
        try run(service: 7, method: 21, Anki_Generic_Empty(), returning: Anki_Generic_StringList.self).vals
    }
}
