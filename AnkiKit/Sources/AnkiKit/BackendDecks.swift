import Foundation
import SwiftProtobuf

/// One deck as shown in the deck list, flattened from the backend's deck tree.
///
/// Mirrors AnkiDroid's `DeckNode`/`DisplayDeckNode`: `name` is the leaf path
/// component (the core already returns just the last segment), `depth` drives
/// indentation for subdecks (top-level decks are depth 0), and the three counts
/// are the new/learning/review numbers the DeckPicker renders per row.
public struct DeckTreeEntry: Identifiable, Sendable {
    public let id: Int64
    public let name: String
    public let fullName: String
    public let depth: Int
    public let filtered: Bool
    /// Whether this deck is collapsed in the deck list (its subdecks hidden).
    /// Mirrors the engine node's `collapsed` flag — the deck's reviewer
    /// `study_collapsed` state — and is toggled via `setDeckCollapsed`, so it
    /// round-trips and syncs. Drives the rotation of the DeckPicker chevron.
    public let collapsed: Bool
    /// Whether this deck has at least one subdeck. Drives whether the deck list
    /// shows an expand/collapse chevron (leaf decks get none), matching
    /// AnkiDroid's `DeckNode` exposing its children.
    public let hasChildren: Bool
    public let newCount: Int
    public let learnCount: Int
    public let reviewCount: Int

    /// True when there is at least one card ready to study (matches
    /// `DeckNode.hasCardsReadyToStudy()`).
    public var hasCardsReadyToStudy: Bool {
        newCount > 0 || learnCount > 0 || reviewCount > 0
    }
}

public extension Backend {
    /// DecksService.deckTree (service 7, method 4).
    ///
    /// Passing a non-zero `now` (current Unix time, in seconds) makes the core
    /// include the new/learn/review counts — this is what `sched.deck_due_tree()`
    /// does. With `now == 0` (`decks.deck_tree()`) the core returns the tree
    /// without counts. The returned root is synthetic, so its children are the
    /// top-level decks; the whole tree is flattened depth-first preserving order.
    func deckTree() throws -> [DeckTreeEntry] {
        var req = Anki_Decks_DeckTreeRequest()
        req.now = Int64(Date().timeIntervalSince1970)
        let root = try run(service: 7, method: 4, req, returning: Anki_Decks_DeckTreeNode.self)
        var rows: [DeckTreeEntry] = []
        for child in root.children {
            Backend.flatten(child, parentName: "", into: &rows)
        }
        return rows
    }

    /// DecksService.setCurrentDeck (service 7, method 22).
    ///
    /// Selects `id` as the current deck so the scheduler studies it and its
    /// subdecks next. Mirrors `decks.select()` in `handleDeckSelection`.
    func setCurrentDeck(id: Int64) throws {
        var req = Anki_Decks_DeckId()
        req.did = id
        _ = try run(service: 7, method: 22, input: try req.serializedData())
    }

    /// DecksService.setDeckCollapsed (service 7, method 11).
    ///
    /// Persists whether a deck is collapsed in the deck list, so its subdecks
    /// hide/show and the change round-trips (and syncs) like any other deck
    /// edit. Uses the `REVIEWER` scope — the deck-list/study collapse that the
    /// `DeckTreeNode.collapsed` flag reflects, matching AnkiDroid's DeckPicker
    /// expander. (The separate `BROWSER` scope is the card browser's sidebar
    /// collapse, which we don't touch here.)
    func setDeckCollapsed(deckID: Int64, collapsed: Bool) throws {
        var req = Anki_Decks_SetDeckCollapsedRequest()
        req.deckID = deckID
        req.collapsed = collapsed
        req.scope = .reviewer
        _ = try run(service: 7, method: 11, input: try req.serializedData())
    }

    /// SchedulerService.unburyDeck (service 13, method 13).
    ///
    /// Returns a deck's buried cards to the study queue — both scheduler- and
    /// user-buried (mode `ALL`) — the action behind AnkiDroid's deck "Unbury"
    /// context item. Undoable through the engine.
    func unburyDeck(deckID: Int64) throws {
        var req = Anki_Scheduler_UnburyDeckRequest()
        req.deckID = deckID
        req.mode = .all
        _ = try run(service: 13, method: 13, input: try req.serializedData())
    }

    private static func flatten(
        _ node: Anki_Decks_DeckTreeNode,
        parentName: String,
        into rows: inout [DeckTreeEntry]
    ) {
        let fullName = parentName.isEmpty ? node.name : "\(parentName)::\(node.name)"
        rows.append(
            DeckTreeEntry(
                id: node.deckID,
                name: node.name,
                fullName: fullName,
                depth: max(0, Int(node.level) - 1),
                filtered: node.filtered,
                collapsed: node.collapsed,
                hasChildren: !node.children.isEmpty,
                newCount: Int(node.newCount),
                learnCount: Int(node.learnCount),
                reviewCount: Int(node.reviewCount)
            )
        )
        // A collapsed deck hides its subdecks in the list — AnkiDroid's
        // DeckPicker renders no rows beneath a collapsed parent. The collapsed
        // node still carries the aggregated child counts, so the visible row
        // stays accurate; we just stop descending into its children.
        guard !node.collapsed else { return }
        for child in node.children {
            flatten(child, parentName: fullName, into: &rows)
        }
    }
}
