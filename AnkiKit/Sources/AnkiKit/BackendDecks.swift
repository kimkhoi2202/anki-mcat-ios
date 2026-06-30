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
                newCount: Int(node.newCount),
                learnCount: Int(node.learnCount),
                reviewCount: Int(node.reviewCount)
            )
        )
        for child in node.children {
            flatten(child, parentName: fullName, into: &rows)
        }
    }
}
