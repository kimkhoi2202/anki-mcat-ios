import Foundation
import SwiftProtobuf

/// One saved search from the browser sidebar (Anki's "Saved Searches"): a
/// user-given `name` and the search string it stands for. Decouples the SwiftUI
/// layer from the raw config JSON, the same way `CardBrowserRow` /
/// `DeckTreeEntry` do.
public struct SavedSearch: Identifiable, Sendable, Equatable {
    public let name: String
    public let query: String
    public var id: String { name }

    public init(name: String, query: String) {
        self.name = name
        self.query = query
    }
}

/// Card Browser sidebar data sources: the tag list, and the saved-search store.
///
/// These back the phone's "Filters" panel — the mobile form of Anki's browser
/// sidebar. Decks come from the existing `deckTree()`, flags/card-state are
/// fixed sets built in the UI, and tags + saved searches come from here.
public extension Backend {
    /// TagsService.allTags (service 45, method 1).
    ///
    /// Every tag used in the collection, already sorted by the engine — the
    /// source for the sidebar's Tags section (each maps to a `tag:"…"` search).
    /// Mirrors AnkiDroid's `col.tags.all()` / desktop's sidebar tag tree source.
    func allTags() throws -> [String] {
        try run(service: 45, method: 1, Anki_Generic_Empty(), returning: Anki_Generic_StringList.self).vals
    }

    /// The collection config key under which Anki stores the browser sidebar's
    /// saved searches — a JSON object mapping a display name to its search
    /// string (desktop `qt/aqt/browser/sidebar/tree.py` reads/writes the same
    /// `savedFilters` key via `col.get_config`/`set_config`).
    static let savedSearchesConfigKey = "savedFilters"

    /// Reads the collection's saved searches, sorted case-insensitively by name.
    ///
    /// The `savedFilters` config is a `{name: search}` JSON object; a collection
    /// that has never saved one stores nothing, in which case the core returns
    /// the JSON literal `null` (or the key read fails). Either is treated as "no
    /// saved searches" rather than an error, matching how desktop defaults a
    /// missing key to an empty map.
    func savedSearches() -> [SavedSearch] {
        savedSearchesMap()
            .map { SavedSearch(name: $0.key, query: $0.value) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Adds (or overwrites) a saved search by name, round-tripping through the
    /// `savedFilters` config. Read-modify-write so existing entries are kept.
    /// Undoable is left off (as pylib's `set_config` default), since this is
    /// browser view state rather than user-content. Mirrors desktop's "Save
    /// Current Search".
    func saveSearch(name: String, query: String) throws {
        var dict = savedSearchesMap()
        dict[name] = query
        try writeSavedSearches(dict)
    }

    /// Removes a saved search by name (no-op if absent). Round-trips the
    /// `savedFilters` config the same way `saveSearch` does.
    func removeSavedSearch(name: String) throws {
        var dict = savedSearchesMap()
        guard dict.removeValue(forKey: name) != nil else { return }
        try writeSavedSearches(dict)
    }

    /// Decodes the `savedFilters` config into a `[name: search]` map. A missing
    /// key (a read error or the JSON literal `null`), or any non-object payload,
    /// decodes to an empty map — matching desktop, which defaults a missing key
    /// to `{}` rather than treating it as an error.
    private func savedSearchesMap() -> [String: String] {
        guard let data = try? getConfigJson(key: Backend.savedSearchesConfigKey),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: String] else {
            return [:]
        }
        return dict
    }

    /// Serializes a `[name: search]` map back into the `savedFilters` config.
    private func writeSavedSearches(_ dict: [String: String]) throws {
        let data = try JSONSerialization.data(withJSONObject: dict)
        try setConfigJson(key: Backend.savedSearchesConfigKey, valueJSON: data)
    }
}
