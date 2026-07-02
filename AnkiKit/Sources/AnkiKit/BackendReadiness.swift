import Foundation

/// The three MCAT scores (Memory / Performance / Readiness) and the give-up rule
/// that gates them (PRD "The three scores", "Honesty rule", "Give-up / abstain").
///
/// Design goals, in order of importance, because honesty is graded and
/// "fabricated or misleading readiness numbers = automatic fail":
///
/// 1. **Real data first.** Memory is computed only from the engine's own FSRS
///    retrievability (`StatsService.card_stats`, 43/0, which derives it via
///    `FSRS::current_retrievability_seconds` from each card's stored memory
///    state). Nothing in this file invents a retrievability value.
/// 2. **Every score is a range, never a single blended number.** `ScoreRange`
///    and `ReadinessProjection` carry a low/point/high.
/// 3. **Provisional things are labelled provisional.** There is no validated
///    exam-question model yet, so Performance (and the Readiness that depends on
///    it) is explicitly marked uncalibrated, discounted from Memory, and given a
///    wide range.
/// 4. **Abstain by default.** Below the give-up line the scores are `nil` and the
///    caller must show what's missing instead of a number.
///
/// The pure math lives in `ScoreModel` so it can be unit-tested with no backend;
/// `Backend.readinessEvidence(forDeck:)` gathers the real inputs from the engine;
/// `ReadinessAssessment.make(...)` assembles everything the dashboard shows.

// MARK: - Score values

/// A score as an honest range in `0...1` — a point estimate plus a low/high
/// bound. Initialisation clamps every component to `0...1` and orders them so
/// `low <= point <= high` always holds.
public struct ScoreRange: Sendable, Equatable {
    public let low: Double
    public let point: Double
    public let high: Double

    public init(low: Double, point: Double, high: Double) {
        let p = ScoreRange.clamp(point)
        self.point = p
        self.low = min(p, ScoreRange.clamp(low))
        self.high = max(p, ScoreRange.clamp(high))
    }

    private static func clamp(_ v: Double) -> Double { min(1, max(0, v)) }

    /// Half-width of the interval (`(high − low) / 2`) — how uncertain the
    /// estimate is, in probability units.
    public var halfWidth: Double { (high - low) / 2 }

    /// Point estimate as a rounded whole percentage.
    public var percentPoint: Int { Int((point * 100).rounded()) }
    /// Low bound as a rounded whole percentage.
    public var percentLow: Int { Int((low * 100).rounded()) }
    /// High bound as a rounded whole percentage.
    public var percentHigh: Int { Int((high * 100).rounded()) }
    /// The range as a percent string, e.g. `"61–78%"`.
    public var percentRangeText: String { "\(percentLow)–\(percentHigh)%" }
}

/// A projected MCAT score on the real scaled-score axis (total 472–528, each of
/// the four sections 118–132), as a range. Components are rounded to whole scaled
/// points, clamped to the valid total range, and ordered `low <= point <= high`.
public struct ReadinessProjection: Sendable, Equatable {
    public let low: Int
    public let point: Int
    public let high: Int

    public init(low: Int, point: Int, high: Int) {
        let p = ReadinessProjection.clamp(point)
        self.point = p
        self.low = min(p, ReadinessProjection.clamp(low))
        self.high = max(p, ReadinessProjection.clamp(high))
    }

    private static func clamp(_ v: Int) -> Int {
        min(ScoreModel.scaleMax, max(ScoreModel.scaleMin, v))
    }

    /// The range as a scaled-score string, e.g. `"498–511"`.
    public var rangeText: String { "\(low)–\(high)" }
}

/// How much to trust a score. Memory's tier scales with how many real cards back
/// it; Performance and Readiness are pinned to `.low` until the held-out
/// exam-style evaluation calibrates them (PRD: AI/eval phase).
public enum ScoreConfidence: String, Sendable, Equatable {
    case low
    case moderate
    case high

    public var label: String {
        switch self {
        case .low: return "low"
        case .moderate: return "moderate"
        case .high: return "high"
        }
    }
}

// MARK: - Engine evidence

/// The real, engine-sourced inputs behind the Memory score and the graded-review
/// half of the give-up rule, for one deck. Gathered by
/// `Backend.readinessEvidence(forDeck:)`; consumed by `ReadinessAssessment`.
public struct MemoryEvidence: Sendable, Equatable {
    /// Real per-card FSRS retrievability (`0...1`) for every studied card that
    /// carries FSRS memory state — straight from `card_stats`. The Memory score
    /// is computed only from these values.
    public let retrievabilities: [Double]
    /// Total graded reviews across the deck's studied cards: the sum of each
    /// card's review count (`card.reps`, surfaced as `CardStatsResponse.reviews`).
    /// A manual reschedule does not increment `reps`, so this counts graded
    /// answers only — the PRD's "graded reviews".
    public let gradedReviews: Int
    /// Studied cards considered (cards that have left the new queue). Some may
    /// lack FSRS memory state (e.g. reviewed under the SM-2 scheduler); those are
    /// counted here but excluded from `retrievabilities`, and the gap is surfaced
    /// as missing data.
    public let studiedCardCount: Int

    public init(retrievabilities: [Double], gradedReviews: Int, studiedCardCount: Int) {
        self.retrievabilities = retrievabilities
        self.gradedReviews = gradedReviews
        self.studiedCardCount = studiedCardCount
    }

    /// Studied cards that actually contributed an FSRS retrievability.
    public var cardsWithMemoryState: Int { retrievabilities.count }
}

// MARK: - The score models (pure, testable)

/// The pure score math, with every constant documented (and mirrored in
/// `docs/score-models.md`). No I/O, so it is fully unit-testable.
public enum ScoreModel {
    // MARK: Give-up rule

    /// Graded reviews required before any score is shown.
    public static let gradedReviewThreshold = 200
    /// Topic coverage required before any score is shown (shared with
    /// `CoverageReport`, so the abstain banner and the scores use one line).
    public static let coverageThreshold = CoverageReport.scoringThreshold // 0.5

    /// The exact, documented give-up line shown on screen and in the docs.
    public static let giveUpRule =
        "No score until ≥\(gradedReviewThreshold) graded reviews AND ≥\(Int(coverageThreshold * 100))% topic coverage."

    // MARK: Memory

    /// z for a 95% normal-approximation confidence interval on the mean.
    static let memoryCIZ = 1.96

    // MARK: Performance (provisional, uncalibrated)

    /// Multiple-choice guessing floor for an unstudied question (the MCAT is
    /// 4-option, so ≈0.25). Applied to the un-covered share of the exam.
    public static let guessBaseline = 0.25
    /// Recall→application "transfer" multiplier range. Recall of a memorised fact
    /// over-states the chance of answering a *new* exam-style question (PRD 7d
    /// paraphrase gap), so Performance discounts Memory by this factor. The range
    /// is deliberately wide because it is **not yet calibrated** against held-out
    /// exam-style questions.
    public static let transferLow = 0.50
    public static let transferMid = 0.675
    public static let transferHigh = 0.85

    /// The label every Performance (and Readiness) read-out must carry.
    public static let provisionalLabel =
        "Provisional — not yet calibrated against held-out exam-style questions."

    // MARK: Readiness scale

    /// MCAT total scaled-score range.
    public static let scaleMin = 472
    public static let scaleMax = 528
    /// MCAT per-section scaled-score range (documented; per-section projection is
    /// deferred until per-section calibration — see docs/score-models.md).
    public static let sectionScaleMin = 118
    public static let sectionScaleMax = 132

    // MARK: Functions

    /// Memory = the chance of recalling a *taught* fact now, as a range.
    ///
    /// The point estimate is the mean real FSRS retrievability across the studied
    /// cards. The range is a 95% normal-approximation confidence interval on that
    /// mean (`mean ± z·SE`, `SE = sd/√n`) — a **count-based** interval that
    /// narrows as more cards back it. Clamped to `0...1`.
    ///
    /// Returns `nil` when there is no real retrievability data (the caller then
    /// abstains). With a single card the spread is undefined, so the interval
    /// collapses to the point and the caller should treat confidence as low.
    public static func memoryScore(retrievabilities: [Double]) -> ScoreRange? {
        guard !retrievabilities.isEmpty else { return nil }
        let n = Double(retrievabilities.count)
        let mean = retrievabilities.reduce(0, +) / n
        guard retrievabilities.count >= 2 else {
            return ScoreRange(low: mean, point: mean, high: mean)
        }
        let variance = retrievabilities.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / (n - 1)
        let standardError = (variance / n).squareRoot()
        let margin = memoryCIZ * standardError
        return ScoreRange(low: mean - margin, point: mean, high: mean + margin)
    }

    /// Performance = the chance of answering a *new* exam-style question
    /// correctly, as a **provisional** range.
    ///
    /// Expected value over the whole exam: on the covered share you apply a
    /// transfer-discounted recall; on the un-covered share you fall back to the
    /// multiple-choice guess floor:
    ///
    ///   p = coverage · (memory · transfer) + (1 − coverage) · guessBaseline
    ///
    /// The low/high propagate Memory's own low/high through the wide transfer
    /// range, so the interval is intentionally broad. This is NOT a validated
    /// model — see `provisionalLabel`.
    public static func performanceScore(memory: ScoreRange, coverageFraction coverage: Double) -> ScoreRange {
        let c = min(1, max(0, coverage))
        func blend(_ mem: Double, _ transfer: Double) -> Double {
            c * (mem * transfer) + (1 - c) * guessBaseline
        }
        return ScoreRange(
            low: blend(memory.low, transferLow),
            point: blend(memory.point, transferMid),
            high: blend(memory.high, transferHigh)
        )
    }

    /// Maps a correctness probability to the MCAT total scaled score by linear
    /// interpolation across `scaleMin...scaleMax` (`472 + p·56`). Documented as a
    /// first-order, uncalibrated mapping.
    public static func scaledScore(forProbability p: Double) -> Int {
        let clamped = min(1, max(0, p))
        return Int((Double(scaleMin) + clamped * Double(scaleMax - scaleMin)).rounded())
    }

    /// Readiness = the projected MCAT total, as a range, by mapping the
    /// provisional Performance range onto the 472–528 scale.
    public static func readinessProjection(performance: ScoreRange) -> ReadinessProjection {
        ReadinessProjection(
            low: scaledScore(forProbability: performance.low),
            point: scaledScore(forProbability: performance.point),
            high: scaledScore(forProbability: performance.high)
        )
    }

    /// The give-up rule: both halves must clear their line.
    public static func meetsGiveUpThreshold(gradedReviews: Int, coverageFraction: Double) -> Bool {
        gradedReviews >= gradedReviewThreshold && coverageFraction >= coverageThreshold
    }

    /// Memory's confidence tier, from how many real cards back it. (Memory is
    /// real FSRS data, so unlike Performance/Readiness it can earn confidence
    /// above `.low`.)
    public static func memoryConfidence(cardCount: Int) -> ScoreConfidence {
        switch cardCount {
        case let n where n >= 80: return .high
        case let n where n >= 25: return .moderate
        default: return .low
        }
    }
}

// MARK: - The assembled assessment

/// Everything the Readiness dashboard renders for one deck: the gating verdict,
/// the three scores (or `nil` when abstaining), and the full honesty read-out
/// (evidence, missing data, confidence, % covered, last-updated, main reasons,
/// and the single best next thing to study).
public struct ReadinessAssessment: Sendable, Equatable {
    /// Deck-scoped coverage map (also the "% of exam covered" signal).
    public let coverage: CoverageReport
    /// Total graded reviews behind the assessment.
    public let gradedReviews: Int
    /// Studied cards considered, and how many carried FSRS memory state.
    public let studiedCardCount: Int
    public let cardsWithMemoryState: Int
    /// When the assessment was computed (the honesty rule's "last-updated time").
    public let lastUpdated: Date

    /// Memory — real FSRS recall of taught facts (range). `nil` when abstaining
    /// or when no studied card carries FSRS memory state.
    public let memory: ScoreRange?
    /// Performance — provisional chance on a new exam-style question (range).
    public let performance: ScoreRange?
    /// Readiness — projected MCAT total on the 472–528 scale (range).
    public let readiness: ReadinessProjection?
    /// Confidence in the Memory estimate.
    public let memoryConfidence: ScoreConfidence

    /// The main reasons behind the numbers (or behind abstaining).
    public let reasons: [String]
    /// What data is still missing (honesty rule).
    public let missingData: [String]
    /// The single best next thing to study (honesty rule).
    public let bestNextThing: String

    // MARK: Gating

    public var meetsGradedReviewThreshold: Bool { gradedReviews >= ScoreModel.gradedReviewThreshold }
    public var meetsCoverageThreshold: Bool { coverage.meetsCoverageThreshold }

    /// True only when both give-up halves clear AND there is real memory data to
    /// score. When false the dashboard shows the abstain state.
    public var isScored: Bool {
        meetsGradedReviewThreshold && meetsCoverageThreshold && memory != nil
    }

    public init(
        coverage: CoverageReport,
        gradedReviews: Int,
        studiedCardCount: Int,
        cardsWithMemoryState: Int,
        lastUpdated: Date,
        memory: ScoreRange?,
        performance: ScoreRange?,
        readiness: ReadinessProjection?,
        memoryConfidence: ScoreConfidence,
        reasons: [String],
        missingData: [String],
        bestNextThing: String
    ) {
        self.coverage = coverage
        self.gradedReviews = gradedReviews
        self.studiedCardCount = studiedCardCount
        self.cardsWithMemoryState = cardsWithMemoryState
        self.lastUpdated = lastUpdated
        self.memory = memory
        self.performance = performance
        self.readiness = readiness
        self.memoryConfidence = memoryConfidence
        self.reasons = reasons
        self.missingData = missingData
        self.bestNextThing = bestNextThing
    }
}

public extension ReadinessAssessment {
    /// Assembles a `ReadinessAssessment` from deck-scoped coverage and real
    /// engine evidence. Pure (no I/O), so the give-up gating and the read-out are
    /// unit-testable. `weakestStudiedTopic` (e.g. from the points-at-stake queue)
    /// is the preferred "best next thing" when scored; otherwise the most
    /// impactful missing topic is used.
    static func make(
        coverage: CoverageReport,
        evidence: MemoryEvidence,
        weakestStudiedTopic: String? = nil,
        now: Date = Date()
    ) -> ReadinessAssessment {
        let meetsReviews = evidence.gradedReviews >= ScoreModel.gradedReviewThreshold
        let meetsCoverage = coverage.meetsCoverageThreshold
        let computedMemory = ScoreModel.memoryScore(retrievabilities: evidence.retrievabilities)
        let gated = meetsReviews && meetsCoverage && computedMemory != nil

        // Give-up rule: below the line show NO scores at all — not even the (real)
        // Memory number. Only the inputs/progress (coverage %, review counts) and
        // the read-out are exposed when abstaining.
        let memory: ScoreRange?
        let performance: ScoreRange?
        let readiness: ReadinessProjection?
        if gated, let computedMemory {
            let perf = ScoreModel.performanceScore(memory: computedMemory, coverageFraction: coverage.fractionCovered)
            memory = computedMemory
            performance = perf
            readiness = ScoreModel.readinessProjection(performance: perf)
        } else {
            memory = nil
            performance = nil
            readiness = nil
        }

        let reasons = makeReasons(
            coverage: coverage, evidence: evidence, memory: memory
        )
        let missingData = makeMissingData(
            coverage: coverage, evidence: evidence,
            meetsReviews: meetsReviews, meetsCoverage: meetsCoverage, hasMemory: memory != nil
        )
        let bestNext = makeBestNextThing(
            coverage: coverage, gated: gated,
            meetsReviews: meetsReviews, meetsCoverage: meetsCoverage,
            gradedReviews: evidence.gradedReviews, weakestStudiedTopic: weakestStudiedTopic
        )

        return ReadinessAssessment(
            coverage: coverage,
            gradedReviews: evidence.gradedReviews,
            studiedCardCount: evidence.studiedCardCount,
            cardsWithMemoryState: evidence.cardsWithMemoryState,
            lastUpdated: now,
            memory: memory,
            performance: performance,
            readiness: readiness,
            memoryConfidence: ScoreModel.memoryConfidence(cardCount: evidence.cardsWithMemoryState),
            reasons: reasons,
            missingData: missingData,
            bestNextThing: bestNext
        )
    }

    private static func makeReasons(
        coverage: CoverageReport, evidence: MemoryEvidence, memory: ScoreRange?
    ) -> [String] {
        var reasons: [String] = []
        // `memory` is non-nil only when scored, so the score number is never
        // surfaced while abstaining.
        if let memory {
            reasons.append(
                "Memory is the mean real FSRS retrievability of \(evidence.cardsWithMemoryState) studied "
                + "\(evidence.cardsWithMemoryState == 1 ? "card" : "cards") (\(memory.percentPoint)%, "
                + "95% interval \(memory.percentRangeText))."
            )
            reasons.append(
                "Performance discounts Memory by the recall→application gap and the un-covered share; "
                + "Readiness maps that onto the 472–528 scale."
            )
        }
        reasons.append(
            "Coverage is \(coverage.percentCovered)% of \(coverage.totalTopics) outline topics "
            + "(\(coverage.coveredTopics) with at least one card)."
        )
        reasons.append(
            "\(evidence.gradedReviews) graded "
            + "\(evidence.gradedReviews == 1 ? "review" : "reviews") across "
            + "\(evidence.studiedCardCount) studied \(evidence.studiedCardCount == 1 ? "card" : "cards")."
        )
        return reasons
    }

    private static func makeMissingData(
        coverage: CoverageReport, evidence: MemoryEvidence,
        meetsReviews: Bool, meetsCoverage: Bool, hasMemory: Bool
    ) -> [String] {
        var missing: [String] = []
        if !meetsReviews {
            missing.append(
                "Need ≥\(ScoreModel.gradedReviewThreshold) graded reviews — have \(evidence.gradedReviews)."
            )
        }
        if !meetsCoverage {
            missing.append(
                "Need ≥\(Int(ScoreModel.coverageThreshold * 100))% topic coverage — have \(coverage.percentCovered)%."
            )
        }
        if !hasMemory && (meetsReviews || meetsCoverage) {
            missing.append("No studied card carries FSRS memory state yet, so Memory can't be computed.")
        }
        let withoutMemory = evidence.studiedCardCount - evidence.cardsWithMemoryState
        if withoutMemory > 0 {
            missing.append(
                "\(withoutMemory) studied \(withoutMemory == 1 ? "card has" : "cards have") no FSRS memory state "
                + "and are excluded from Memory."
            )
        }
        // Always true until the eval phase (PRD): performance is uncalibrated and
        // there is no prediction history to score accuracy against.
        missing.append("Performance is not yet calibrated against held-out exam-style questions.")
        missing.append("Past-prediction accuracy: not enough history yet.")
        return missing
    }

    private static func makeBestNextThing(
        coverage: CoverageReport, gated: Bool,
        meetsReviews: Bool, meetsCoverage: Bool,
        gradedReviews: Int, weakestStudiedTopic: String?
    ) -> String {
        // Below the coverage line, the highest-leverage move is to start the most
        // impactful missing topic.
        if !meetsCoverage, let missing = coverage.mostImpactfulMissingTopic {
            return "Add cards for “\(missing.name)” (\(missing.section)) — the biggest coverage gap."
        }
        // Coverage is fine but not enough graded reviews yet: keep reviewing.
        if !meetsReviews {
            let remaining = max(0, ScoreModel.gradedReviewThreshold - gradedReviews)
            if let weakestStudiedTopic {
                return "Review \(remaining) more cards — start with your weakest area, \(weakestStudiedTopic)."
            }
            return "Review \(remaining) more cards to reach the \(ScoreModel.gradedReviewThreshold)-review line."
        }
        // Scored: shore up the weakest studied area, else close a coverage gap.
        if let weakestStudiedTopic {
            return "Review your weakest area: \(weakestStudiedTopic)."
        }
        if let missing = coverage.mostImpactfulMissingTopic {
            return "Add cards for “\(missing.name)” (\(missing.section)) to raise coverage."
        }
        return "Keep your reviews current to hold your recall."
    }
}

// MARK: - Engine gathering

public extension Backend {
    /// Gathers the real Memory inputs and graded-review count for one deck.
    ///
    /// Studied cards are `deck:"<deck>" -is:new`. For each, `card_stats` (43/0)
    /// returns the engine's own FSRS retrievability (computed from the card's
    /// memory state via `current_retrievability_seconds`) and the card's review
    /// count (`reps`). Retrievabilities are collected only where memory state
    /// exists; the review counts are summed into the graded-review total. No value
    /// here is synthesised — it is all read back from the core.
    func readinessEvidence(forDeck deck: String) throws -> MemoryEvidence {
        let query = "deck:\(Backend.quoteSearchValue(deck)) -is:new"
        let ids = try searchCards(query: query)
        var retrievabilities: [Double] = []
        retrievabilities.reserveCapacity(ids.count)
        var gradedReviews = 0
        for id in ids {
            let stats = try cardStats(cardID: id)
            gradedReviews += Int(stats.reviews)
            if stats.hasFsrsRetrievability {
                retrievabilities.append(Double(stats.fsrsRetrievability))
            }
        }
        return MemoryEvidence(
            retrievabilities: retrievabilities,
            gradedReviews: gradedReviews,
            studiedCardCount: ids.count
        )
    }

    /// Convenience: deck-scoped coverage + evidence assembled into a full
    /// `ReadinessAssessment`. `weakestStudiedTopic` is an optional best-next-thing
    /// hint (e.g. from the points-at-stake queue).
    func readinessAssessment(
        forDeck deck: String,
        topics: [CoverageTopic],
        weakestStudiedTopic: String? = nil,
        now: Date = Date()
    ) throws -> ReadinessAssessment {
        let coverage = try coverage(forTopics: topics, inDeck: deck)
        let evidence = try readinessEvidence(forDeck: deck)
        return ReadinessAssessment.make(
            coverage: coverage, evidence: evidence,
            weakestStudiedTopic: weakestStudiedTopic, now: now
        )
    }
}
