import Foundation

/// AnkiDroid's configurable reviewer gestures, ported to touch.
///
/// This is the pure, engine-independent data model behind the app's
/// "Controls / Gestures" settings and the reviewer's gesture dispatcher. It
/// lives in `AnkiKit` (not the app target) so the defaults, JSON persistence,
/// and tap-zone partition can be unit-tested without the UI — mirroring how
/// `SyncKeychain` keeps a pure, testable utility here.
///
/// The three pieces are:
/// - ``ViewerCommand`` — the actions a gesture can trigger, cloning AnkiDroid's
///   `ViewerCommand` set (adapted to what this client can do today).
/// - ``ReviewerGesture`` — the recognizable touch gestures (tap zones, swipes,
///   long-press, double-tap). Named `ReviewerGesture` (not `Gesture`) to avoid a
///   clash with SwiftUI's `Gesture` protocol in the app's views.
/// - ``GestureConfig`` — the persisted `ReviewerGesture -> ViewerCommand`
///   mapping, with AnkiDroid-faithful defaults and a reset.
///
/// The mapping is neutral about *how* a command is performed (the app wires each
/// command to the matching `AnkiStore` reviewer method); it only records intent.

// MARK: - ViewerCommand

/// A reviewer action a gesture can be bound to, cloning AnkiDroid's
/// `ViewerCommand`. Raw values are the stable keys persisted in JSON, so they
/// must not change once shipped.
///
/// `title`/`systemImage` are plain strings (an SF Symbol name is just a string),
/// so this stays UI-framework-free and usable from `AnkiKit`.
public enum ViewerCommand: String, Codable, CaseIterable, Identifiable, Sendable {
    /// No action (the gesture is unbound / disabled).
    case none
    /// Reveal the answer (and, if already shown, flip back to the question) —
    /// AnkiDroid's flip/answer behavior for a single tap.
    case showAnswer
    /// Grade the shown card. These only apply once the answer is visible (the
    /// reviewer enforces this, so a gesture can never silently grade a question).
    case answerAgain, answerHard, answerGood, answerEasy
    /// Undo the last undoable action.
    case undo
    /// Open the note editor for the current card's note.
    case editNote
    /// Bury the current card / every card of its note.
    case buryCard, buryNote
    /// Suspend the current card / every card of its note.
    case suspendCard, suspendNote
    /// Delete the current card's note (routed through a confirmation).
    case deleteNote
    /// Toggle the `marked` tag on the current note.
    case markNote
    /// Toggle a flag color on the current card (1…7 = red…purple), mirroring
    /// AnkiDroid's per-color flag commands.
    case flagRed, flagOrange, flagGreen, flagBlue, flagPink, flagTurquoise, flagPurple
    /// Replay the current side's audio.
    case replayAudio
    /// Open Card Info for the current card.
    case cardInfo
    /// Open the note editor to add a new note.
    case addNote
    /// Toggle the whiteboard. The whiteboard UI lands in a later task; this
    /// command exists now and is wired to a reviewer hook (a no-op toggle) so
    /// users can bind it and the later work can fill it in.
    case toggleWhiteboard
    /// Leave the reviewer (pop back to the deck list).
    case exitReviewer

    public var id: String { rawValue }

    /// Human-readable label shown in the settings picker and menus.
    public var title: String {
        switch self {
        case .none: return "Nothing"
        case .showAnswer: return "Show answer / flip"
        case .answerAgain: return "Answer: Again"
        case .answerHard: return "Answer: Hard"
        case .answerGood: return "Answer: Good"
        case .answerEasy: return "Answer: Easy"
        case .undo: return "Undo"
        case .editNote: return "Edit note"
        case .buryCard: return "Bury card"
        case .buryNote: return "Bury note"
        case .suspendCard: return "Suspend card"
        case .suspendNote: return "Suspend note"
        case .deleteNote: return "Delete note"
        case .markNote: return "Mark note"
        case .flagRed: return "Flag: Red"
        case .flagOrange: return "Flag: Orange"
        case .flagGreen: return "Flag: Green"
        case .flagBlue: return "Flag: Blue"
        case .flagPink: return "Flag: Pink"
        case .flagTurquoise: return "Flag: Turquoise"
        case .flagPurple: return "Flag: Purple"
        case .replayAudio: return "Replay audio"
        case .cardInfo: return "Card info"
        case .addNote: return "Add note"
        case .toggleWhiteboard: return "Toggle whiteboard"
        case .exitReviewer: return "Exit reviewer"
        }
    }

    /// SF Symbol name for the command (used by the settings menu). Kept as a bare
    /// string so this file needs no UI framework.
    public var systemImage: String {
        switch self {
        case .none: return "circle.slash"
        case .showAnswer: return "eye"
        case .answerAgain: return "arrow.counterclockwise"
        case .answerHard: return "tortoise"
        case .answerGood: return "checkmark"
        case .answerEasy: return "hare"
        case .undo: return "arrow.uturn.backward"
        case .editNote: return "pencil"
        case .buryCard: return "rectangle.stack"
        case .buryNote: return "rectangle.stack.fill"
        case .suspendCard: return "pause.circle"
        case .suspendNote: return "pause.circle.fill"
        case .deleteNote: return "trash"
        case .markNote: return "star"
        case .flagRed, .flagOrange, .flagGreen, .flagBlue,
             .flagPink, .flagTurquoise, .flagPurple: return "flag.fill"
        case .replayAudio: return "speaker.wave.2"
        case .cardInfo: return "info.circle"
        case .addNote: return "square.and.pencil"
        case .toggleWhiteboard: return "scribble.variable"
        case .exitReviewer: return "xmark"
        }
    }

    /// For the flag commands, the Anki flag number (1 red … 7 purple); nil for
    /// non-flag commands. Lets the dispatcher route to `toggleReviewerFlag(n)`.
    public var flagNumber: Int? {
        switch self {
        case .flagRed: return 1
        case .flagOrange: return 2
        case .flagGreen: return 3
        case .flagBlue: return 4
        case .flagPink: return 5
        case .flagTurquoise: return 6
        case .flagPurple: return 7
        default: return nil
        }
    }

    /// Whether this command grades the card (so the reviewer only performs it
    /// while the answer is shown — the swipe/tap-vs-answer safety rule).
    public var isGrading: Bool {
        switch self {
        case .answerAgain, .answerHard, .answerGood, .answerEasy: return true
        default: return false
        }
    }

    /// Display order for the settings picker, grouped like AnkiDroid's command
    /// list (reveal/grade, then note/card actions, flags, then app actions).
    /// Every case appears exactly once; a compile-time check in the tests guards
    /// against a new command being forgotten here.
    public static let menuOrder: [ViewerCommand] = [
        .none,
        .showAnswer,
        .answerAgain, .answerHard, .answerGood, .answerEasy,
        .undo,
        .editNote, .addNote,
        .markNote,
        .buryCard, .buryNote,
        .suspendCard, .suspendNote,
        .deleteNote,
        .flagRed, .flagOrange, .flagGreen, .flagBlue, .flagPink, .flagTurquoise, .flagPurple,
        .replayAudio,
        .cardInfo,
        .toggleWhiteboard,
        .exitReviewer,
    ]
}

// MARK: - ReviewerGesture

/// A touch gesture the reviewer recognizes over the card. Tap zones follow a
/// sensible 5-zone split (center + four edges) — AnkiDroid uses a 3×3 grid, but
/// a large central target plus four edge regions is the touch-appropriate
/// adaptation. Raw values are the stable persisted keys.
///
/// Named `ReviewerGesture` rather than `Gesture` so it doesn't collide with
/// SwiftUI's `Gesture` protocol in the app's views.
public enum ReviewerGesture: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    case tapTop, tapBottom, tapLeft, tapRight, tapCenter
    case swipeUp, swipeDown, swipeLeft, swipeRight
    case longPress
    case doubleTap

    public var id: String { rawValue }

    /// Human-readable label for the settings row.
    public var title: String {
        switch self {
        case .tapTop: return "Tap top"
        case .tapBottom: return "Tap bottom"
        case .tapLeft: return "Tap left"
        case .tapRight: return "Tap right"
        case .tapCenter: return "Tap center"
        case .swipeUp: return "Swipe up"
        case .swipeDown: return "Swipe down"
        case .swipeLeft: return "Swipe left"
        case .swipeRight: return "Swipe right"
        case .longPress: return "Long press"
        case .doubleTap: return "Double tap"
        }
    }

    /// Whether this gesture is one of the five tap zones (used to group the
    /// settings screen).
    public var isTapZone: Bool {
        switch self {
        case .tapTop, .tapBottom, .tapLeft, .tapRight, .tapCenter: return true
        default: return false
        }
    }

    /// Whether this gesture is one of the four swipes.
    public var isSwipe: Bool {
        switch self {
        case .swipeUp, .swipeDown, .swipeLeft, .swipeRight: return true
        default: return false
        }
    }
}

// MARK: - TapZone

/// The five tap regions of the card. Kept separate from ``ReviewerGesture`` so
/// the point → zone partition is a pure, testable function the reviewer calls
/// with a normalized tap location.
public enum TapZone: String, CaseIterable, Sendable {
    case top, bottom, left, right, center

    /// The gesture this zone maps to.
    public var gesture: ReviewerGesture {
        switch self {
        case .top: return .tapTop
        case .bottom: return .tapBottom
        case .left: return .tapLeft
        case .right: return .tapRight
        case .center: return .tapCenter
        }
    }

    /// Half-width/height of the square central zone in normalized units. `0.25`
    /// makes the center span x,y ∈ [0.25, 0.75] — a comfortable "tap to reveal"
    /// target — with the surrounding ring split into the four edges. A larger,
    /// touch-friendly center than AnkiDroid's 1/9 grid cell.
    public static let centerHalfExtent = 0.25

    /// Classifies a tap at a location normalized to 0…1 in the card's bounds
    /// (origin top-left) into a zone. The central square is the center; outside
    /// it, whichever axis the point is more extreme on picks the edge (ties, i.e.
    /// exact diagonals/corners, resolve to the vertical top/bottom edge). Pure,
    /// so it's unit-tested directly.
    public static func from(x: Double, y: Double) -> TapZone {
        let dx = x - 0.5
        let dy = y - 0.5
        if abs(dx) <= centerHalfExtent && abs(dy) <= centerHalfExtent {
            return .center
        }
        if abs(dx) > abs(dy) {
            return dx < 0 ? .left : .right
        } else {
            return dy < 0 ? .top : .bottom
        }
    }
}

// MARK: - GestureConfig

/// The persisted mapping of every ``ReviewerGesture`` to a ``ViewerCommand``.
///
/// Serialized as a flat `{ "gestureRawValue": "commandRawValue" }` JSON object
/// (stored as a string in `UserDefaults` by the app). Decoding is *tolerant*: it
/// starts from ``defaults`` and overlays any recognized entries, so a config
/// saved by a different app version — missing new gestures, or carrying commands
/// this version doesn't know — still yields a complete, valid mapping.
public struct GestureConfig: Codable, Equatable, Sendable {
    /// Backing map. Always complete for the current gesture set after
    /// `init`/decode (missing gestures fall back to their default).
    private var bindings: [ReviewerGesture: ViewerCommand]

    /// Builds a config from an explicit map, filling any missing gesture from
    /// ``defaults`` so `command(for:)` is always defined.
    public init(bindings: [ReviewerGesture: ViewerCommand]) {
        var complete = Self.defaultBindings
        for (gesture, command) in bindings {
            complete[gesture] = command
        }
        self.bindings = complete
    }

    /// The command bound to a gesture (``ViewerCommand/none`` if unbound).
    public func command(for gesture: ReviewerGesture) -> ViewerCommand {
        bindings[gesture] ?? .none
    }

    /// Binds (or clears, with `.none`) a gesture to a command.
    public mutating func set(_ command: ViewerCommand, for gesture: ReviewerGesture) {
        bindings[gesture] = command
    }

    /// Whether every binding matches the shipped defaults (drives disabling the
    /// "Reset to defaults" control when there's nothing to reset).
    public var isDefault: Bool { self == .defaults }

    // MARK: Defaults

    /// AnkiDroid-faithful default bindings, chosen to reproduce this app's prior
    /// hardcoded reviewer behavior while adding zone/edge parity:
    ///
    /// - **Tap center** → *Show answer / flip* (reveal; flip back when shown) —
    ///   preserves the old "tap center to reveal / flip back".
    /// - **Tap & swipe edges → the four ratings**, laid out to match the on-screen
    ///   answer-button order and the app's prior swipe map:
    ///   left = Again, right = Easy, top/up = Good, bottom/down = Hard.
    ///   (Grading only fires once the answer is shown, so on the question side the
    ///   edges do nothing — no accidental grade.)
    /// - **Long press** → *Edit note*.
    /// - **Double tap** → *Nothing* (AnkiDroid ships it unbound; keeping it unbound
    ///   also keeps single taps snappy, since no double-tap disambiguation delay
    ///   is added unless the user binds it).
    ///
    /// Gestures not listed default to ``ViewerCommand/none``.
    public static let defaultBindings: [ReviewerGesture: ViewerCommand] = [
        .tapCenter: .showAnswer,
        .tapLeft: .answerAgain,
        .tapRight: .answerEasy,
        .tapTop: .answerGood,
        .tapBottom: .answerHard,
        .swipeLeft: .answerAgain,
        .swipeRight: .answerEasy,
        .swipeUp: .answerGood,
        .swipeDown: .answerHard,
        .longPress: .editNote,
        .doubleTap: .none,
    ]

    /// The default configuration.
    public static let defaults = GestureConfig(rawBindings: defaultBindings)

    /// Private initializer that trusts `raw` to be complete (used only for
    /// ``defaults`` to avoid the fill-in copy referencing itself during static
    /// initialization).
    private init(rawBindings raw: [ReviewerGesture: ViewerCommand]) {
        self.bindings = raw
    }

    // MARK: Codable (tolerant, flat string map)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode([String: String].self)
        var merged = Self.defaultBindings
        for (key, value) in raw {
            guard let gesture = ReviewerGesture(rawValue: key),
                  let command = ViewerCommand(rawValue: value) else { continue }
            merged[gesture] = command
        }
        self.bindings = merged
    }

    public func encode(to encoder: Encoder) throws {
        // Emit every gesture explicitly so the JSON is a stable, exact snapshot.
        var raw: [String: String] = [:]
        for gesture in ReviewerGesture.allCases {
            raw[gesture.rawValue] = command(for: gesture).rawValue
        }
        var container = encoder.singleValueContainer()
        try container.encode(raw)
    }

    // MARK: JSON helpers (persistence)

    /// Encodes to JSON `Data` for `UserDefaults`. Deterministic key order so a
    /// re-save doesn't needlessly churn the stored blob.
    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    /// Decodes from JSON `Data`, falling back to ``defaults`` on any error (a
    /// corrupt/absent blob should never brick the reviewer's gestures).
    public static func from(jsonData data: Data?) -> GestureConfig {
        guard let data else { return .defaults }
        return (try? JSONDecoder().decode(GestureConfig.self, from: data)) ?? .defaults
    }
}
