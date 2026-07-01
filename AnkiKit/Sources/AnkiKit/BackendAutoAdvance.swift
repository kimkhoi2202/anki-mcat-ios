import Foundation
import SwiftProtobuf

/// The reviewer behaviour to perform when an auto-advance timer for a side
/// elapses. A pure, engine-independent mapping of the deck config's
/// `QuestionAction`/`AnswerAction`, so the reviewer's timer logic and the
/// action mapping are unit-testable without the UI. Mirrors Anki's
/// `AutoAdvance._on_..._time_elapsed` dispatch in `qt/aqt/reviewer.py`.
public enum AutoAdvanceAction: Equatable, Sendable {
    /// Reveal the answer — the question side's default action.
    case showAnswer
    /// Bury the current card — the answer side's default action.
    case bury
    /// Grade the card with a rating (only ever on the answer side).
    case answer(Anki_Scheduler_CardAnswer.Rating)
    /// Show a brief, non-grading on-screen reminder that the side's time elapsed
    /// (Anki shows a tooltip; the app shows a transient notice).
    case showReminder

    /// The action for a question-side timeout, from the deck config's
    /// `QuestionAction`. Anki's question actions are only "show answer" (default)
    /// or "show reminder"; an unknown value falls back to Anki's default (show
    /// answer), never a grade.
    public static func forQuestion(
        _ action: Anki_DeckConfig_DeckConfig.Config.QuestionAction
    ) -> AutoAdvanceAction {
        switch action {
        case .showAnswer: return .showAnswer
        case .showReminder: return .showReminder
        case .UNRECOGNIZED: return .showAnswer
        }
    }

    /// The action for an answer-side timeout, from the deck config's
    /// `AnswerAction`. Note the proto enum's raw order (again=1, good=2, hard=3)
    /// differs from the rating order (again=1, hard=2, good=3), so this maps by
    /// case, not by number. An unknown value falls back to Anki's default (bury).
    public static func forAnswer(
        _ action: Anki_DeckConfig_DeckConfig.Config.AnswerAction
    ) -> AutoAdvanceAction {
        switch action {
        case .buryCard: return .bury
        case .answerAgain: return .answer(.again)
        case .answerGood: return .answer(.good)
        case .answerHard: return .answer(.hard)
        case .showReminder: return .showReminder
        case .UNRECOGNIZED: return .bury
        }
    }
}

/// A scheduled auto-advance: how long to wait before performing `action`.
public struct AutoAdvancePlan: Equatable, Sendable {
    /// Delay before the action fires (seconds).
    public let seconds: Double
    /// What to do when the delay elapses.
    public let action: AutoAdvanceAction

    public init(seconds: Double, action: AutoAdvanceAction) {
        self.seconds = seconds
        self.action = action
    }
}

/// A deck's auto-advance settings, sourced from its deck config
/// (`secondsToShowQuestion`/`secondsToShowAnswer` + `questionAction`/
/// `answerAction`). A pure value type so the per-side timing/action decision is
/// unit-testable without a backend. This is Anki's model: auto-advance timing
/// and actions live in the *deck config*, not the global reviewing prefs.
public struct AutoAdvanceConfig: Equatable, Sendable {
    /// Seconds the question shows before its timer fires (0 disables that side).
    public var secondsToShowQuestion: Double
    /// Seconds the answer shows before its timer fires (0 disables that side).
    public var secondsToShowAnswer: Double
    /// What the question-side timer does when it elapses.
    public var questionAction: Anki_DeckConfig_DeckConfig.Config.QuestionAction
    /// What the answer-side timer does when it elapses.
    public var answerAction: Anki_DeckConfig_DeckConfig.Config.AnswerAction

    public init(
        secondsToShowQuestion: Double,
        secondsToShowAnswer: Double,
        questionAction: Anki_DeckConfig_DeckConfig.Config.QuestionAction,
        answerAction: Anki_DeckConfig_DeckConfig.Config.AnswerAction
    ) {
        self.secondsToShowQuestion = secondsToShowQuestion
        self.secondsToShowAnswer = secondsToShowAnswer
        self.questionAction = questionAction
        self.answerAction = answerAction
    }

    /// Builds the settings from a deck config's `Config` message.
    public init(config: Anki_DeckConfig_DeckConfig.Config) {
        self.init(
            secondsToShowQuestion: Double(config.secondsToShowQuestion),
            secondsToShowAnswer: Double(config.secondsToShowAnswer),
            questionAction: config.questionAction,
            answerAction: config.answerAction
        )
    }

    /// The auto-advance plan for the side currently shown, or `nil` when that
    /// side's timer is disabled (0 seconds), matching Anki (0 disables a side).
    /// Grading is only ever produced for the answer side, so a stray question
    /// timer can never grade.
    public func plan(showingAnswer: Bool) -> AutoAdvancePlan? {
        let seconds = showingAnswer ? secondsToShowAnswer : secondsToShowQuestion
        guard seconds > 0 else { return nil }
        let action = showingAnswer
            ? AutoAdvanceAction.forAnswer(answerAction)
            : AutoAdvanceAction.forQuestion(questionAction)
        return AutoAdvancePlan(seconds: seconds, action: action)
    }

    /// The deck whose config governs a card: the card's original (home) deck when
    /// it's in a filtered deck (`originalDeckID != 0`), otherwise the card's own
    /// deck. Mirrors Anki's `Card.current_deck_id()`, which `AutoAdvance` uses to
    /// look up the config so a filtered card keeps its home deck's settings.
    public static func effectiveDeckID(deckID: Int64, originalDeckID: Int64) -> Int64 {
        originalDeckID != 0 ? originalDeckID : deckID
    }
}

public extension Backend {
    /// Reads a deck's auto-advance settings from its assigned preset (deck
    /// config) via `get_deck_configs_for_update` (DeckConfigService 11, method 6)
    /// — the same call powering the deck-options screen — resolving the deck's
    /// preset the way the scheduler does (the assigned config, else the engine
    /// defaults). This is how the reviewer sources per-card auto-advance timing
    /// and actions, cloning Anki's `decks.config_dict_for_deck_id(deck_id)`.
    func autoAdvanceConfig(forDeckID deckID: Int64) throws -> AutoAdvanceConfig {
        let forUpdate = try deckConfigsForUpdate(deckID: deckID)
        let configID = forUpdate.currentDeck.configID
        let config = forUpdate.allConfig.first { $0.config.id == configID }?.config.config
            ?? forUpdate.defaults.config
        return AutoAdvanceConfig(config: config)
    }
}
