import Foundation
import SwiftProtobuf

/// Anki's Custom Study presets, cloning AnkiDroid's `CustomStudyDialog`
/// (`ContextMenuOption`). Each case is a user choice already resolved to its
/// entered value and maps 1:1 onto the engine's `CustomStudyRequest` oneof
/// (see `qt/aqt/customstudy.py::accept` and `rslib/.../custom_study.rs`).
public enum CustomStudyChoice: Sendable, Equatable {
    /// Increase today's new-card limit by `delta` (may be negative to reduce).
    case extendNew(delta: Int)
    /// Increase today's review limit by `delta` (may be negative to reduce).
    case extendReview(delta: Int)
    /// Review cards forgotten (answered "Again") in the last `days` days.
    case reviewForgotten(days: Int)
    /// Review cards due in the next `days` days ("review ahead").
    case reviewAhead(days: Int)
    /// Preview new cards added in the last `days` days.
    case previewNew(days: Int)
    /// Study by card state or tag (Anki's "cram"): up to `cardLimit` cards of a
    /// chosen state, optionally limited to / excluding tags.
    case cardStateOrTag(CustomStudyCram)

    /// Whether applying this choice builds/updates the "Custom Study Session"
    /// filtered deck (so the caller should then study it), rather than only
    /// extending the deck's daily limits in place. Mirrors AnkiDroid's
    /// `CustomStudyAction` split (CUSTOM_STUDY_SESSION vs EXTEND_STUDY_LIMITS).
    public var buildsFilteredDeck: Bool {
        switch self {
        case .extendNew, .extendReview:
            return false
        case .reviewForgotten, .reviewAhead, .previewNew, .cardStateOrTag:
            return true
        }
    }
}

/// The "Study by card state or tag" options (engine `CustomStudyRequest.Cram`).
public struct CustomStudyCram: Sendable, Equatable {
    /// The card state to gather (new / due / review / all).
    public var kind: CustomStudyCramKind
    /// Maximum number of cards to gather.
    public var cardLimit: Int
    /// Cards must match one of these tags, if non-empty.
    public var tagsToInclude: [String]
    /// Cards must not match any of these tags.
    public var tagsToExclude: [String]

    public init(
        kind: CustomStudyCramKind, cardLimit: Int,
        tagsToInclude: [String] = [], tagsToExclude: [String] = []
    ) {
        self.kind = kind
        self.cardLimit = cardLimit
        self.tagsToInclude = tagsToInclude
        self.tagsToExclude = tagsToExclude
    }
}

/// The card-state filter for "Study by card state or tag", mirroring AnkiDroid's
/// `CustomStudyCardState` (and desktop's `cardType` list), in display order. The
/// `proto` mapping targets the engine `CustomStudyRequest.Cram.CramKind`.
public enum CustomStudyCramKind: Int, Sendable, CaseIterable, Identifiable {
    case newCardsOnly
    case dueCardsOnly
    case allReviewCardsInRandomOrder
    case allCardsInRandomOrder

    public var id: Int { rawValue }

    /// User-facing label, matching desktop Anki's `custom_study_*` strings.
    public var label: String {
        switch self {
        case .newCardsOnly: return "New cards only"
        case .dueCardsOnly: return "Due cards only"
        case .allReviewCardsInRandomOrder: return "All review cards in random order"
        case .allCardsInRandomOrder: return "All cards in random order (don't reschedule)"
        }
    }

    /// Maps to the generated protobuf cram-kind enum (due=0, new=1, review=2,
    /// all=3), independent of this enum's declaration order.
    var proto: Anki_Scheduler_CustomStudyRequest.Cram.CramKind {
        switch self {
        case .newCardsOnly: return .new
        case .dueCardsOnly: return .due
        case .allReviewCardsInRandomOrder: return .review
        case .allCardsInRandomOrder: return .all
        }
    }
}

/// Prefill values for the Custom Study dialog, from the engine
/// `CustomStudyDefaultsResponse`. Mirrors AnkiDroid's `CustomStudyDefaults`.
public struct CustomStudyDefaults: Sendable, Equatable {
    /// Default for "increase today's new card limit by".
    public let extendNew: Int
    /// Default for "increase today's review limit by".
    public let extendReview: Int
    /// New cards available in this deck (excluding subdecks).
    public let availableNew: Int
    /// Review cards available in this deck (excluding subdecks).
    public let availableReview: Int
    /// New cards available in subdecks only.
    public let availableNewInChildren: Int
    /// Review cards available in subdecks only.
    public let availableReviewInChildren: Int
    /// The deck's tags, each pre-marked include/exclude from the last cram.
    public let tags: [CustomStudyTag]

    public init(
        extendNew: Int, extendReview: Int,
        availableNew: Int, availableReview: Int,
        availableNewInChildren: Int, availableReviewInChildren: Int,
        tags: [CustomStudyTag]
    ) {
        self.extendNew = extendNew
        self.extendReview = extendReview
        self.availableNew = availableNew
        self.availableReview = availableReview
        self.availableNewInChildren = availableNewInChildren
        self.availableReviewInChildren = availableReviewInChildren
        self.tags = tags
    }
}

/// One of a deck's tags as offered in the Custom Study tag picker, with its
/// remembered include/exclude state (engine `CustomStudyDefaultsResponse.Tag`).
public struct CustomStudyTag: Sendable, Equatable, Identifiable {
    public let name: String
    public let include: Bool
    public let exclude: Bool

    public var id: String { name }

    public init(name: String, include: Bool, exclude: Bool) {
        self.name = name
        self.include = include
        self.exclude = exclude
    }
}

/// The outcome of applying a Custom Study choice, telling the caller whether a
/// filtered "Custom Study Session" deck was built (and to study it) or the
/// deck's limits were merely extended in place.
public enum CustomStudyOutcome: Sendable, Equatable {
    /// The deck's daily new/review limits were extended in place — no new deck.
    /// Study continues in the original deck (refresh its counts).
    case extendedLimits
    /// The "Custom Study Session" filtered deck was built/updated; its id is
    /// provided so the caller can select and study it.
    case builtSession(deckID: Int64)
}

/// Custom Study RPCs (the preset dialog behind AnkiDroid's "Custom study").
/// Both live on `SchedulerService` (service 13); indices confirmed in
/// `_backend_generated.py` / `AnkiWebMethods`:
///   - custom_study          (13, 27)
///   - custom_study_defaults (13, 28)
public extension Backend {
    /// The localized name the engine gives the temporary custom-study filtered
    /// deck (`tr.custom_study_custom_study_session()`); it resolves to English
    /// here since the backend is opened with `preferredLangs: ["en"]`.
    static let customStudySessionDeckName = "Custom Study Session"

    /// SchedulerService.customStudyDefaults (13, 28). Prefill values for the
    /// Custom Study dialog: today's extend defaults, the available new/review
    /// counts (with subdeck breakdown), and the deck's tags.
    func customStudyDefaults(deckID: Int64) throws -> CustomStudyDefaults {
        var req = Anki_Scheduler_CustomStudyDefaultsRequest()
        req.deckID = deckID
        let resp = try run(
            service: 13, method: 28, req,
            returning: Anki_Scheduler_CustomStudyDefaultsResponse.self
        )
        return CustomStudyDefaults(
            extendNew: Int(resp.extendNew),
            extendReview: Int(resp.extendReview),
            availableNew: Int(resp.availableNew),
            availableReview: Int(resp.availableReview),
            availableNewInChildren: Int(resp.availableNewInChildren),
            availableReviewInChildren: Int(resp.availableReviewInChildren),
            tags: resp.tags.map {
                CustomStudyTag(name: $0.name, include: $0.include, exclude: $0.exclude)
            }
        )
    }

    /// SchedulerService.customStudy (13, 27). Applies a Custom Study choice for
    /// `deckID`. For limit extensions the engine bumps today's new/review limits
    /// in place; for the other options it builds/updates the "Custom Study
    /// Session" filtered deck (gathering matching cards) and we resolve its id so
    /// the caller can study it. Clone of AnkiDroid's `CustomStudyDialog.customStudy`.
    ///
    /// The engine aborts the build (and throws) if a session's search matches no
    /// cards (`allow_empty = false`), surfaced to the user.
    @discardableResult
    func customStudy(deckID: Int64, choice: CustomStudyChoice) throws -> CustomStudyOutcome {
        var req = Anki_Scheduler_CustomStudyRequest()
        req.deckID = deckID
        switch choice {
        case .extendNew(let delta):
            req.newLimitDelta = Int32(clamping: delta)
        case .extendReview(let delta):
            req.reviewLimitDelta = Int32(clamping: delta)
        case .reviewForgotten(let days):
            req.forgotDays = UInt32(max(0, days))
        case .reviewAhead(let days):
            req.reviewAheadDays = UInt32(max(0, days))
        case .previewNew(let days):
            req.previewDays = UInt32(max(0, days))
        case .cardStateOrTag(let cram):
            var c = Anki_Scheduler_CustomStudyRequest.Cram()
            c.kind = cram.kind.proto
            c.cardLimit = UInt32(max(0, cram.cardLimit))
            c.tagsToInclude = cram.tagsToInclude
            c.tagsToExclude = cram.tagsToExclude
            req.cram = c
        }
        // custom_study returns OpChanges; the work is the side effect (limits
        // bumped, or the filtered deck built/updated).
        _ = try run(service: 13, method: 27, req, returning: Anki_Collection_OpChanges.self)

        guard choice.buildsFilteredDeck else { return .extendedLimits }
        // The engine named the new/updated deck "Custom Study Session"; resolve
        // its id from the deck tree (filtered decks are always top-level, so the
        // name is unique) so the caller can select and study it.
        if let session = try deckTree().first(where: {
            $0.filtered && $0.name == Self.customStudySessionDeckName
        }) {
            return .builtSession(deckID: session.id)
        }
        // The build succeeded but the deck wasn't found (shouldn't happen); fall
        // back to a non-navigating outcome rather than throwing.
        return .extendedLimits
    }
}
