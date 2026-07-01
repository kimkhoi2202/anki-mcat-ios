import Foundation

/// Pure helpers behind the note editor's tag autocomplete, mirroring AnkiDroid's
/// `TagsUtil` / the tag `AutoCompleteAdapter`: tags are a space-separated string,
/// and as the user types a token the editor suggests matching existing tags
/// (from `Backend.allTags()`), completing the token on tap. Anki tags are
/// hierarchical (`parent::child`), which falls out naturally since a token is
/// matched against — and completed to — the whole tag string.
///
/// Kept UI-independent so the token parsing / filtering / completion rules are
/// easy to unit-test.
public enum TagSuggestions {
    /// The partial tag currently being typed: the run after the last whitespace.
    /// When `text` is empty or ends in whitespace the token is empty (nothing to
    /// suggest against).
    public static func currentToken(in text: String) -> String {
        guard let lastWhitespace = text.lastIndex(where: { $0.isWhitespace }) else {
            return text
        }
        return String(text[text.index(after: lastWhitespace)...])
    }

    /// The already-committed tags (every whitespace-separated token except the
    /// partial one still being typed). Used to avoid suggesting a tag the note
    /// already carries.
    public static func committedTokens(in text: String) -> [String] {
        let tokens = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        // A trailing space means the last token is finished; otherwise it's still
        // being typed and shouldn't count as committed.
        if let last = text.last, last.isWhitespace { return tokens }
        return tokens.isEmpty ? [] : Array(tokens.dropLast())
    }

    /// Suggestions for `token` from `allTags`: tags containing the token
    /// (case-insensitive), with prefix matches first, then substring matches —
    /// both preserving `allTags`' order (the engine returns them sorted). Excludes
    /// the token itself when it's already an exact tag, and any tag in `existing`
    /// (the note's already-entered tags). Returns nothing for an empty token.
    ///
    /// Substring matching means `heart` surfaces `anatomy::heart`, and `anat`
    /// surfaces `anatomy::heart` / `anatomy::lung`, so hierarchical tags are
    /// discoverable from any segment.
    public static func suggestions(
        for token: String, allTags: [String], existing: [String] = [], limit: Int = 12
    ) -> [String] {
        let needle = token.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return [] }
        let taken = Set(existing.map { $0.lowercased() })

        var prefixMatches: [String] = []
        var substringMatches: [String] = []
        var seen = Set<String>()
        for tag in allTags {
            let lower = tag.lowercased()
            if lower == needle { continue }          // already fully typed
            if taken.contains(lower) { continue }    // already on the note
            guard seen.insert(lower).inserted else { continue } // de-dupe
            if lower.hasPrefix(needle) {
                prefixMatches.append(tag)
            } else if lower.contains(needle) {
                substringMatches.append(tag)
            }
        }
        return Array((prefixMatches + substringMatches).prefix(limit))
    }

    /// Replaces the partial token in `text` with `tag`, appending a trailing
    /// space so the user can immediately type the next tag. Leaves any earlier,
    /// already-committed tags untouched.
    public static func complete(_ text: String, with tag: String) -> String {
        if let lastWhitespace = text.lastIndex(where: { $0.isWhitespace }) {
            return String(text[...lastWhitespace]) + tag + " "
        }
        return tag + " "
    }
}
