import Foundation
import SwiftProtobuf

/// A deck's basic daily study limits, decoupled from the generated protobuf the
/// same way `DeckTreeEntry` / `NoteForEditing` are.
///
/// These are the v3 scheduler's per-deck limit overrides (`Deck.Normal.new_limit`
/// / `review_limit`). When a deck has no override, the effective limit is its
/// preset's `new_per_day` / `reviews_per_day` (default 20 / 200 — see
/// `rslib/src/deckconfig/mod.rs`), which is what `deckLimits` falls back to.
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
}

/// Deck-management convenience methods — create / rename / delete decks and
/// get/set their basic daily limits, cloning AnkiDroid's DeckPicker deck
/// operations (`CreateDeckDialog`, the deck context menu's rename/delete, and
/// the deck-options limits).
///
/// All of these live on `DecksService` (backend service index 7, the same
/// service as `deckTree`/`setCurrentDeck`). The method indices are the methods'
/// positions in `proto/anki/decks.proto`'s `DecksService`, anchored by the three
/// already verified in `BackendDecks.swift`: `DeckTree` = 4, `GetDeckNames` = 13,
/// `SetCurrentDeck` = 22. Message shapes come from `decks.proto` / `collection.proto`.
public extension Backend {
    /// Anki's default preset limits (`rslib/src/deckconfig/mod.rs`: `new_per_day:
    /// 20`, `reviews_per_day: 200`), used as the effective value when a deck has
    /// no per-deck override set.
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

    /// Reads a deck's basic daily limits.
    ///
    /// Returns the per-deck `new_limit` / `review_limit` override when set,
    /// otherwise the standard preset default (20 / 200). The v3 scheduler resolves
    /// the effective limit exactly this way — `current_new_limit(...).unwrap_or(
    /// config.new_per_day)` in `rslib/src/decks/limits.rs`.
    func deckLimits(deckID: Int64) throws -> DeckLimits {
        let normal = try deck(id: deckID).normal
        return DeckLimits(
            newPerDay: normal.hasNewLimit ? Int(normal.newLimit) : Backend.defaultNewCardsPerDay,
            reviewsPerDay: normal.hasReviewLimit ? Int(normal.reviewLimit) : Backend.defaultReviewsPerDay
        )
    }

    /// Sets a deck's basic daily limits as per-deck overrides.
    ///
    /// Read-modify-write: the deck is fetched (7, 8), only its `new_limit` /
    /// `review_limit` are set (everything else — config id, description, … — is
    /// preserved), then saved via `UpdateDeck` (7, 9), which records an undo entry.
    /// Throws `notANormalDeck` for filtered decks (they have no per-day limits, and
    /// writing `normal` would convert them).
    func setDeckLimits(deckID: Int64, newPerDay: Int, reviewsPerDay: Int) throws {
        var deck = try deck(id: deckID)
        guard case .normal = deck.kind else { throw DeckManagementError.notANormalDeck }
        deck.normal.newLimit = clampLimit(newPerDay)
        deck.normal.reviewLimit = clampLimit(reviewsPerDay)
        _ = try run(service: 7, method: 9, input: try deck.serializedData())
    }

    private func clampLimit(_ value: Int) -> UInt32 {
        UInt32(min(max(value, 0), Backend.maxPerDayLimit))
    }
}
