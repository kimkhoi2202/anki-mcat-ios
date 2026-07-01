import Foundation

/// Pure model + builders behind the Card Browser sidebar's **hierarchical**
/// Decks and Tags trees — the collapsible outline that mirrors Anki's browser
/// sidebar. Kept UI-independent (no SwiftUI) so the tree building and the
/// `deck:` / `tag:` query generation are easy to unit-test.
///
/// Anki stores decks and tags flat: a deck's full name and a tag are both
/// `parent::child::leaf` strings, and the `::` separators imply the hierarchy.
/// The builders below reconstruct that hierarchy so the sidebar can show
/// expand/collapse chevrons, and each node exposes the exact Anki search term a
/// tap applies (the tap-to-search behaviour Anki's sidebar uses).

/// One node of the sidebar's **Tags** tree, built from the collection's flat
/// `parent::child::leaf` tag strings.
public struct SidebarTagNode: Identifiable, Sendable, Equatable {
    /// The full `::`-joined tag path (e.g. `anatomy::heart`). Unique across the
    /// tree, so it's both the `id` and the key under which the UI persists this
    /// node's expand/collapse state.
    public let path: String
    /// The leaf component shown in the row (the last `::` segment).
    public let name: String
    /// Child nodes (deeper tag paths), sorted case-insensitively by leaf name.
    public let children: [SidebarTagNode]

    public var id: String { path }
    public var hasChildren: Bool { !children.isEmpty }

    /// The Anki search term a tap on this node applies. A node with children is
    /// a subtree, so it uses Anki's `tag:path::*` subtree query (which matches
    /// the child tags); a leaf uses an exact `tag:path`. Mirrors Anki's browser
    /// sidebar, whose parent-tag click searches the whole subtree.
    public var searchTerm: String {
        hasChildren ? "tag:\(path)::*" : "tag:\(path)"
    }

    public init(path: String, name: String, children: [SidebarTagNode]) {
        self.path = path
        self.name = name
        self.children = children
    }

    /// Builds the tag forest from the collection's flat tag list by splitting
    /// each tag on `::`. Intermediate segments become parent nodes even when the
    /// parent itself isn't a stored tag (Anki shows `a` as a group when only
    /// `a::b` exists). Blank tags and empty segments are ignored, duplicate
    /// paths collapse to one node, and every level is sorted case-insensitively
    /// by leaf name — matching the engine's already-sorted tag output.
    public static func buildTree(from tags: [String]) -> [SidebarTagNode] {
        // A mutable reference tree assembled first, then frozen into value nodes.
        final class Builder {
            let path: String
            let name: String
            var children: [String: Builder] = [:]
            init(path: String, name: String) {
                self.path = path
                self.name = name
            }
            func frozen() -> [SidebarTagNode] {
                children.values
                    .map { SidebarTagNode(path: $0.path, name: $0.name, children: $0.frozen()) }
                    .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            }
        }

        let root = Builder(path: "", name: "")
        for tag in tags {
            let segments = tag
                .components(separatedBy: "::")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            guard !segments.isEmpty else { continue }
            var current = root
            var pathSoFar = ""
            for segment in segments {
                pathSoFar = pathSoFar.isEmpty ? segment : "\(pathSoFar)::\(segment)"
                if let existing = current.children[segment] {
                    current = existing
                } else {
                    let child = Builder(path: pathSoFar, name: segment)
                    current.children[segment] = child
                    current = child
                }
            }
        }
        return root.frozen()
    }
}

/// One node of the sidebar's **Decks** tree, built from the engine's deck tree.
/// Carries the per-deck new/learning/review counts so the sidebar can show them
/// like Anki's deck list, and the children so it can expand/collapse.
public struct SidebarDeckNode: Identifiable, Sendable, Equatable {
    public let id: Int64
    /// The leaf component shown in the row (the deck's own name segment).
    public let name: String
    /// The full `Parent::Child::Leaf` deck name (what the `deck:` query targets).
    public let fullName: String
    /// Whether this is a filtered/custom-study deck (rendered distinctly).
    public let filtered: Bool
    public let newCount: Int
    public let learnCount: Int
    public let reviewCount: Int
    /// Child decks, in the engine's order.
    public let children: [SidebarDeckNode]

    public var hasChildren: Bool { !children.isEmpty }

    /// The Anki search term a tap on this node applies: `deck:"Full::Name"`. The
    /// name is quoted so decks with spaces still match, and Anki's `deck:` term
    /// already includes subdecks, so a parent needs no extra subtree syntax.
    public var searchTerm: String {
        SidebarDeckNode.deckSearchTerm(fullName: fullName)
    }

    public init(
        id: Int64, name: String, fullName: String, filtered: Bool,
        newCount: Int, learnCount: Int, reviewCount: Int, children: [SidebarDeckNode]
    ) {
        self.id = id
        self.name = name
        self.fullName = fullName
        self.filtered = filtered
        self.newCount = newCount
        self.learnCount = learnCount
        self.reviewCount = reviewCount
        self.children = children
    }

    /// The `deck:"Full::Name"` search term for a deck, quoting the name so
    /// decks with spaces match. Mirrors the deck-browse action elsewhere in the
    /// app and Anki's sidebar deck click.
    public static func deckSearchTerm(fullName: String) -> String {
        "deck:\"\(fullName)\""
    }

    /// Rebuilds the deck hierarchy from the engine's depth-first `DeckTreeEntry`
    /// list (as returned by `Backend.fullDeckTree()`), where each entry's `depth`
    /// is 0 for a top-level deck and increases by one per level. Preserves the
    /// engine's ordering at every level; a well-formed pre-order list yields the
    /// full nested tree, and any stray deeper-than-expected entry is skipped
    /// defensively rather than crashing.
    public static func buildTree(from entries: [DeckTreeEntry]) -> [SidebarDeckNode] {
        var index = 0
        func build(atDepth depth: Int) -> [SidebarDeckNode] {
            var nodes: [SidebarDeckNode] = []
            while index < entries.count {
                let entry = entries[index]
                if entry.depth < depth { break }        // belongs to an ancestor level
                if entry.depth > depth {                 // malformed jump — skip defensively
                    index += 1
                    continue
                }
                index += 1                               // consume this entry
                let children = build(atDepth: depth + 1)  // gather its subtree
                nodes.append(
                    SidebarDeckNode(
                        id: entry.id,
                        name: entry.name,
                        fullName: entry.fullName,
                        filtered: entry.filtered,
                        newCount: entry.newCount,
                        learnCount: entry.learnCount,
                        reviewCount: entry.reviewCount,
                        children: children
                    )
                )
            }
            return nodes
        }
        return build(atDepth: 0)
    }
}
