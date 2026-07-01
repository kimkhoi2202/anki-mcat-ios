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

/// A touch gesture the reviewer recognizes over the card. Tap zones are
/// AnkiDroid's 3×3 grid — nine cells (the four corners, four mid-edges, and
/// center), with each axis split into equal thirds. Raw values are the stable
/// persisted keys: the original five zones keep their keys, and the four corners
/// were added for full grid parity (tolerant decoding fills them in for configs
/// written by an older build that only knew five zones).
///
/// Named `ReviewerGesture` rather than `Gesture` so it doesn't collide with
/// SwiftUI's `Gesture` protocol in the app's views.
public enum ReviewerGesture: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    // Nine tap zones — AnkiDroid's 3×3 grid, in reading order.
    case tapTopLeft, tapTop, tapTopRight
    case tapLeft, tapCenter, tapRight
    case tapBottomLeft, tapBottom, tapBottomRight
    case swipeUp, swipeDown, swipeLeft, swipeRight
    case longPress
    case doubleTap

    public var id: String { rawValue }

    /// Human-readable label for the settings row.
    public var title: String {
        switch self {
        case .tapTopLeft: return "Tap top-left"
        case .tapTop: return "Tap top"
        case .tapTopRight: return "Tap top-right"
        case .tapLeft: return "Tap left"
        case .tapCenter: return "Tap center"
        case .tapRight: return "Tap right"
        case .tapBottomLeft: return "Tap bottom-left"
        case .tapBottom: return "Tap bottom"
        case .tapBottomRight: return "Tap bottom-right"
        case .swipeUp: return "Swipe up"
        case .swipeDown: return "Swipe down"
        case .swipeLeft: return "Swipe left"
        case .swipeRight: return "Swipe right"
        case .longPress: return "Long press"
        case .doubleTap: return "Double tap"
        }
    }

    /// Whether this gesture is one of the nine tap zones (used to group the
    /// settings screen).
    public var isTapZone: Bool {
        switch self {
        case .tapTopLeft, .tapTop, .tapTopRight,
             .tapLeft, .tapCenter, .tapRight,
             .tapBottomLeft, .tapBottom, .tapBottomRight: return true
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

/// The nine tap regions of the card — AnkiDroid's 3×3 grid. Kept separate from
/// ``ReviewerGesture`` so the point → zone partition is a pure, testable
/// function the reviewer calls with a normalized tap location.
public enum TapZone: String, CaseIterable, Sendable {
    case topLeft, top, topRight
    case left, center, right
    case bottomLeft, bottom, bottomRight

    /// The gesture this zone maps to.
    public var gesture: ReviewerGesture {
        switch self {
        case .topLeft: return .tapTopLeft
        case .top: return .tapTop
        case .topRight: return .tapTopRight
        case .left: return .tapLeft
        case .center: return .tapCenter
        case .right: return .tapRight
        case .bottomLeft: return .tapBottomLeft
        case .bottom: return .tapBottom
        case .bottomRight: return .tapBottomRight
        }
    }

    /// Classifies a tap at a location normalized to 0…1 in the card's bounds
    /// (origin top-left) into one of AnkiDroid's nine 3×3 grid cells. Each axis
    /// is split into equal thirds — `[0, ⅓)`, `[⅓, ⅔)`, `[⅔, 1]` — and the cell
    /// is the resulting (row, column) pair. Pure, so it's unit-tested directly.
    public static func from(x: Double, y: Double) -> TapZone {
        func third(_ v: Double) -> Int {
            if v < 1.0 / 3.0 { return 0 }
            if v < 2.0 / 3.0 { return 1 }
            return 2
        }
        switch (third(y), third(x)) {
        case (0, 0): return .topLeft
        case (0, 1): return .top
        case (0, 2): return .topRight
        case (1, 0): return .left
        case (1, 1): return .center
        case (1, 2): return .right
        case (2, 0): return .bottomLeft
        case (2, 1): return .bottom
        default:     return .bottomRight
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
    /// - **Corners** (top-left/right, bottom-left/right) → *Nothing* — unbound by
    ///   default, matching AnkiDroid; available to bind in Controls.
    /// - **Long press** → *Edit note*.
    /// - **Double tap** → *Nothing* (AnkiDroid ships it unbound; keeping it unbound
    ///   also keeps single taps snappy, since no double-tap disambiguation delay
    ///   is added unless the user binds it).
    ///
    /// Every gesture is listed explicitly (the corners and double-tap ship
    /// unbound as ``ViewerCommand/none``), so the canonical `defaults` and a
    /// config decoded from its own JSON hold identical, complete maps.
    public static let defaultBindings: [ReviewerGesture: ViewerCommand] = [
        .tapCenter: .showAnswer,
        .tapLeft: .answerAgain,
        .tapRight: .answerEasy,
        .tapTop: .answerGood,
        .tapBottom: .answerHard,
        .tapTopLeft: .none,
        .tapTopRight: .none,
        .tapBottomLeft: .none,
        .tapBottomRight: .none,
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
