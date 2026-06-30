import Foundation
import SwiftProtobuf

/// A deck's basic daily study limits, decoupled from the generated protobuf the
/// same way `DeckTreeEntry` / `NoteForEditing` are.
///
/// These are the effective new/review-per-day limits the deck-options screen
/// shows and edits. They normally live on the deck's *preset* (the
/// `DeckConfig`'s `new_per_day` / `reviews_per_day`); the v3 scheduler also
/// honours an optional per-deck override (`Deck.Normal.new_limit` /
/// `review_limit`) when one is set. `deckLimits` resolves the same way the
/// scheduler does (`current_new_limit(...).unwrap_or(config.new_per_day)` in
/// `rslib/src/decks/limits.rs`): the override if present, otherwise the preset.
public struct DeckLimits: Sendable, Equatable {
    /// New cards introduced per day.
    public var newPerDay: Int
    /// Maximum reviews per day.
    public var reviewsPerDay: Int

    public init(newPerDay: Int, reviewsPerDay: Int) {
        self.newPerDay = newPerDay
        self.reviewsPerDay = reviewsPerDay
    }
}

/// Errors raised by the deck-management helpers before they reach the engine.
public enum DeckManagementError: Error, Sendable {
    /// Daily limits only apply to normal decks; filtered/dynamic decks are
    /// scheduled differently and have no new/review-per-day setting.
    case notANormalDeck
    /// The deck's assigned preset wasn't among the collection's deck configs —
    /// not expected for a normal deck (every deck references a real config id).
    case deckConfigMissing
}

/// Deck-management convenience methods — create / rename / delete decks and
/// get/set their basic daily limits, cloning AnkiDroid's DeckPicker deck
/// operations (`CreateDeckDialog`, the deck context menu's rename/delete, and
/// the deck-options limits).
///
/// The create / rename / delete / getDeck calls live on `DecksService` (backend
/// service index 7, the same service as `deckTree`/`setCurrentDeck`); their
/// method indices are the methods' positions in `proto/anki/decks.proto`'s
/// `DecksService`, anchored by the three already verified in `BackendDecks.swift`:
/// `DeckTree` = 4, `GetDeckNames` = 13, `SetCurrentDeck` = 22. The daily-limit
/// get/set go through `DeckConfigService` (service index 11) —
/// `GetDeckConfigsForUpdate` = 6, `UpdateDeckConfigs` = 7, both confirmed against
/// `_backend_generated.py`. Message shapes come from `decks.proto` /
/// `deck_config.proto` / `collection.proto`.
public extension Backend {
    /// Anki's default preset limits (`rslib/src/deckconfig/mod.rs`: `new_per_day:
    /// 20`, `reviews_per_day: 200`). Used only as placeholder values in the
    /// options UI before the deck's real limits are loaded — `deckLimits` reads
    /// the deck's actual preset, never these constants.
    static let defaultNewCardsPerDay = 20
    static let defaultReviewsPerDay = 200

    /// The engine clamps per-day limits to this range (`ensure_u32_valid` in
    /// `rslib/src/deckconfig/mod.rs`); we clamp before writing so the stored
    /// value matches what the scheduler will honor.
    private static var maxPerDayLimit: Int { 9999 }

    /// Creates a new normal deck and returns its id.
    ///
    /// Uses the modern (non-legacy) flow `pylib`'s `add_normal_deck_with_name`
    /// uses: `NewDeck` (7, 0) returns a blank deck template, we set its name, and
    /// `AddDeck` (7, 1) inserts it, returning `OpChangesWithId` whose `id` is the
    /// new deck. `::`-separated names create subdecks, matching AnkiDroid's
    /// `CreateDeckDialog`. A name collision or invalid name surfaces as a backend
    /// error for the caller to show.
    @discardableResult
    func createDeck(name: String) throws -> Int64 {
        var deck = try run(service: 7, method: 0, Anki_Generic_Empty(), returning: Anki_Decks_Deck.self)
        deck.name = name
        let resp = try run(service: 7, method: 1, deck, returning: Anki_Collection_OpChangesWithId.self)
        return resp.id
    }

    /// DecksService.renameDeck (7, 18).
    ///
    /// Renames the deck (and reparents its subdecks under the new prefix), the
    /// same call behind `decks.rename()` and AnkiDroid's rename context action.
    /// Renaming onto a filtered deck's child throws a backend error.
    func renameDeck(id: Int64, name: String) throws {
        var req = Anki_Decks_RenameDeckRequest()
        req.deckID = id
        req.newName = name
        _ = try run(service: 7, method: 18, input: try req.serializedData())
    }

    /// DecksService.removeDecks (7, 16). Deletes the given decks (and their
    /// subdecks and cards). The returned `OpChangesWithCount.count` is the number
    /// of *cards* removed (see `remove_decks_and_child_decks` in
    /// `rslib/src/decks/remove.rs`), not decks. Mirrors `decks.remove()` behind
    /// AnkiDroid's delete-deck action.
    @discardableResult
    func removeDecks(ids: [Int64]) throws -> Int {
        var req = Anki_Decks_DeckIds()
        req.dids = ids
        let resp = try run(service: 7, method: 16, req, returning: Anki_Collection_OpChangesWithCount.self)
        return Int(resp.count)
    }

    /// DecksService.getDeck (7, 8). Loads the full deck record (used for the
    /// read-modify-write behind `setDeckLimits`).
    func deck(id: Int64) throws -> Anki_Decks_Deck {
        var req = Anki_Decks_DeckId()
        req.did = id
        return try run(service: 7, method: 8, req, returning: Anki_Decks_Deck.self)
    }

    /// Reads a deck's basic daily limits for the deck-options screen.
    ///
    /// Returns the per-deck `new_limit` / `review_limit` override when one is set,
    /// otherwise the deck's actual preset values (`DeckConfig.new_per_day` /
    /// `reviews_per_day`) — the same resolution the v3 scheduler uses
    /// (`current_new_limit(...).unwrap_or(config.new_per_day)` in
    /// `rslib/src/decks/limits.rs`), and what desktop/AnkiDroid show. Reads via
    /// `get_deck_configs_for_update` (DeckConfigService 11, method 6), the call
    /// that powers the desktop options screen.
    func deckLimits(deckID: Int64) throws -> DeckLimits {
        let forUpdate = try deckConfigsForUpdate(deckID: deckID)
        let limits = forUpdate.currentDeck.limits
        let preset = presetConfig(in: forUpdate)
        return DeckLimits(
            newPerDay: limits.hasNew ? Int(limits.new) : Int(preset.newPerDay),
            reviewsPerDay: limits.hasReview ? Int(limits.review) : Int(preset.reviewsPerDay)
        )
    }

    /// Sets a deck's basic daily limits by editing its PRESET (deck config),
    /// exactly like desktop Anki and AnkiDroid's deck options — rather than
    /// silently writing per-deck `new_limit` / `review_limit` overrides, which
    /// would diverge from every other client and quietly change scheduling.
    ///
    /// Read-modify-write through the deck-options RPCs: fetch the deck's configs
    /// (`get_deck_configs_for_update`, 11, 6), set the assigned preset's
    /// `new_per_day` / `reviews_per_day`, then save via `update_deck_configs`
    /// (11, 7), which records an undo entry. Any existing per-deck limits (today's
    /// adjustments, desired retention, …) are round-tripped unchanged, and the
    /// collection's FSRS / parent-limit toggles are passed back as-is so saving a
    /// limit never flips them. Throws `notANormalDeck` for filtered decks.
    func setDeckLimits(deckID: Int64, newPerDay: Int, reviewsPerDay: Int) throws {
        guard case .normal = try deck(id: deckID).kind else {
            throw DeckManagementError.notANormalDeck
        }
        let forUpdate = try deckConfigsForUpdate(deckID: deckID)
        let configID = forUpdate.currentDeck.configID
        guard var selected = forUpdate.allConfig
            .first(where: { $0.config.id == configID })?.config
        else {
            throw DeckManagementError.deckConfigMissing
        }
        selected.config.newPerDay = clampLimit(newPerDay)
        selected.config.reviewsPerDay = clampLimit(reviewsPerDay)

        var req = Anki_DeckConfig_UpdateDeckConfigsRequest()
        req.targetDeckID = deckID
        // The deck is assigned whichever config comes last; passing only the
        // deck's own (edited) preset keeps it on that preset and leaves the
        // other presets untouched (unchanged configs may be omitted).
        req.configs = [selected]
        req.mode = .normal
        req.cardStateCustomizer = forUpdate.cardStateCustomizer
        // Preserve any existing per-deck limits/retention rather than clearing them.
        req.limits = forUpdate.currentDeck.limits
        req.newCardsIgnoreReviewLimit = forUpdate.newCardsIgnoreReviewLimit
        // Pass the collection's current scheduling toggles back unchanged so a
        // limit edit can't flip FSRS or parent-limit behaviour.
        req.fsrs = forUpdate.fsrs
        req.applyAllParentLimits = forUpdate.applyAllParentLimits
        req.fsrsReschedule = false
        req.fsrsHealthCheck = forUpdate.fsrsHealthCheck
        _ = try run(service: 11, method: 7, input: try req.serializedData())
    }

    /// DeckConfigService.getDeckConfigsForUpdate (11, 6). The data behind the
    /// deck-options screen: every preset, the current deck's assigned preset id
    /// and per-deck limits, and the collection's scheduling flags. Confirmed in
    /// `_backend_generated.py` (`_run_command(11, 6, …)`).
    func deckConfigsForUpdate(deckID: Int64) throws -> Anki_DeckConfig_DeckConfigsForUpdate {
        var req = Anki_Decks_DeckId()
        req.did = deckID
        return try run(service: 11, method: 6, req, returning: Anki_DeckConfig_DeckConfigsForUpdate.self)
    }

    /// The current deck's assigned preset within a `DeckConfigsForUpdate`, falling
    /// back to the engine-provided defaults if (impossibly) it isn't present.
    private func presetConfig(
        in forUpdate: Anki_DeckConfig_DeckConfigsForUpdate
    ) -> Anki_DeckConfig_DeckConfig.Config {
        let configID = forUpdate.currentDeck.configID
        let config = forUpdate.allConfig.first { $0.config.id == configID }?.config
            ?? forUpdate.defaults
        return config.config
    }

    private func clampLimit(_ value: Int) -> UInt32 {
        UInt32(min(max(value, 0), Backend.maxPerDayLimit))
    }
}
