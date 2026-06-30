import SwiftUI
import AnkiKit

/// The MCAT readiness dashboard — the three scores (Memory / Performance /
/// Readiness), each as a range, with the full honesty read-out; or the abstain
/// state when the deck is below the give-up line.
///
/// Honesty rule (mandatory): when scored, every number is shown with its
/// evidence, what data is missing, the likely range, a confidence indicator, the
/// % of exam covered, the last-updated time, the main reasons, and the single
/// best next thing to study. Below the line (`ReadinessAssessment.isScored ==
/// false`) it shows NO scores — only the give-up line, what's missing, and the
/// best next thing. Performance (and the Readiness that depends on it) is clearly
/// labelled provisional/uncalibrated.
struct ReadinessDashboardView: View {
    @ObservedObject var store: AnkiStore
    /// When true (a screenshot/automation hook), seed + show the scored demo deck
    /// on first appearance instead of the real deck's abstain state.
    var autoLoadDemo = false

    @State private var didLoad = false

    var body: some View {
        ZStack {
            DS.background.ignoresSafeArea()
            content
        }
        .navigationTitle("Readiness")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard !didLoad else { return }
            didLoad = true
            if autoLoadDemo {
                await store.seedAndShowReadinessDemo()
            } else {
                await store.loadReadiness(forDeck: store.readinessDeckName)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let assessment = store.readiness {
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Spacing.l) {
                    explainer
                    if isDemoDeck { DemoBanner() }
                    deckSwitcher
                    if assessment.isScored {
                        ScoredContent(assessment: assessment)
                    } else {
                        AbstainContent(assessment: assessment)
                    }
                }
                .padding(DS.Spacing.l)
            }
            .overlay(alignment: .top) {
                if store.readinessLoading { refreshingBar }
            }
        } else if let error = store.readinessError {
            errorState(error)
        } else {
            loadingState
        }
    }

    private var isDemoDeck: Bool { store.readinessDeckName == AnkiStore.demoReadinessDeckName }

    private var explainer: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            Text("How ready you are — honestly")
                .font(DS.Typography.title)
                .foregroundStyle(DS.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Three separate scores, each a range. \(ScoreModel.giveUpRule)")
                .font(DS.Typography.caption)
                .foregroundStyle(DS.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Scoring deck: \(store.readinessDeckName)")
                .font(DS.Typography.caption)
                .foregroundStyle(DS.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Switches the dashboard between the real deck (which abstains) and the
    /// clearly-marked scored demo deck, so both states are reachable.
    @ViewBuilder
    private var deckSwitcher: some View {
        if isDemoDeck {
            switcherButton(
                title: "Back to real deck (“\(AnkiStore.realReadinessDeckName)”)",
                systemImage: "arrow.uturn.backward", tint: DS.accent
            ) {
                Task { await store.loadReadiness(forDeck: AnkiStore.realReadinessDeckName) }
            }
        } else {
            switcherButton(
                title: store.readinessDemoSeeded
                    ? "Show the scored demo deck"
                    : "Load a scored demo deck (simulated history)",
                systemImage: "wand.and.stars", tint: DS.accent
            ) {
                Task {
                    if store.readinessDemoSeeded {
                        await store.loadReadiness(forDeck: AnkiStore.demoReadinessDeckName)
                    } else {
                        await store.seedAndShowReadinessDemo()
                    }
                }
            }
            .disabled(store.readinessLoading)
        }
    }

    private func switcherButton(
        title: String, systemImage: String, tint: Color, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(DS.Typography.body.weight(.semibold))
                .foregroundStyle(tint)
                .frame(maxWidth: .infinity)
                .frame(minHeight: DS.minTapTarget)
                .background(DS.surface, in: RoundedRectangle(cornerRadius: DS.Radius.large, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: DS.Radius.large, style: .continuous)
                        .strokeBorder(DS.separator, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }

    private var refreshingBar: some View {
        HStack(spacing: DS.Spacing.s) {
            ProgressView()
            Text("Updating…")
                .font(DS.Typography.caption)
                .foregroundStyle(DS.textSecondary)
        }
        .padding(.vertical, DS.Spacing.s)
        .padding(.horizontal, DS.Spacing.m)
        .background(DS.surface, in: Capsule())
        .overlay(Capsule().strokeBorder(DS.separator, lineWidth: 1))
        .padding(.top, DS.Spacing.s)
    }

    private var loadingState: some View {
        VStack(spacing: DS.Spacing.m) {
            ProgressView()
            Text("Scoring…")
                .font(DS.Typography.caption)
                .foregroundStyle(DS.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: DS.Spacing.m) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 40))
                .foregroundStyle(DS.hard)
            Text("Couldn’t compute scores")
                .font(DS.Typography.headline)
                .foregroundStyle(DS.textPrimary)
            Text(message)
                .font(DS.Typography.caption)
                .foregroundStyle(DS.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(DS.Spacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Demo banner

/// Prominent, unmissable marker that the scored deck is a demo with a simulated
/// study history — so its scores can never be mistaken for the real deck's.
private struct DemoBanner: View {
    var body: some View {
        HStack(alignment: .top, spacing: DS.Spacing.m) {
            Image(systemName: "wand.and.stars")
                .font(DS.Typography.headline)
                .foregroundStyle(DS.accent)
            VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                Text("Demo deck — simulated study history")
                    .font(DS.Typography.body.weight(.semibold))
                    .foregroundStyle(DS.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Real MCAT facts with a seeded FSRS history so the scored state is reachable. Every number below is still computed by the engine from that stored state — nothing is hand-written. The real “\(AnkiStore.realReadinessDeckName)” deck correctly abstains.")
                    .font(DS.Typography.caption)
                    .foregroundStyle(DS.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(DS.Spacing.l)
        .background(DS.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: DS.Radius.large, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.large, style: .continuous)
                .strokeBorder(DS.accent.opacity(0.5), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Scored content

private struct ScoredContent: View {
    let assessment: ReadinessAssessment

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.l) {
            if let memory = assessment.memory,
               let performance = assessment.performance,
               let readiness = assessment.readiness {
                ScoresSummaryCard(memory: memory, performance: performance, readiness: readiness)
            }
            if let memory = assessment.memory {
                MemoryCard(memory: memory, confidence: assessment.memoryConfidence,
                           cards: assessment.cardsWithMemoryState)
            }
            if let performance = assessment.performance {
                PerformanceCard(performance: performance)
            }
            if let readiness = assessment.readiness {
                ReadinessCard(readiness: readiness, percentCovered: assessment.coverage.percentCovered)
            }
            HonestyReadout(assessment: assessment)
            CoverageSummaryCard(coverage: assessment.coverage)
        }
    }
}

/// A compact "all three scores at a glance" card — each as a range with a mini
/// bar — so the three-scores-with-ranges story is visible at once. The detailed
/// per-score cards (with evidence and the provisional labels) follow below.
private struct ScoresSummaryCard: View {
    let memory: ScoreRange
    let performance: ScoreRange
    let readiness: ReadinessProjection

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.m) {
            Text("Your three scores")
                .font(DS.Typography.headline)
                .foregroundStyle(DS.textPrimary)
            row(title: "Memory", value: memory.percentRangeText, note: "real FSRS recall",
                low: memory.low, point: memory.point, high: memory.high, tint: DS.easy)
            Divider().overlay(DS.separator)
            row(title: "Performance", value: performance.percentRangeText, note: "provisional",
                low: performance.low, point: performance.point, high: performance.high, tint: DS.hard)
            Divider().overlay(DS.separator)
            row(title: "Readiness", value: readiness.rangeText, note: "MCAT 472–528 · provisional",
                low: frac(readiness.low), point: frac(readiness.point), high: frac(readiness.high), tint: DS.accent)
        }
        .dsCard()
        .accessibilityElement(children: .contain)
    }

    private func frac(_ score: Int) -> Double {
        Double(score - ScoreModel.scaleMin) / Double(ScoreModel.scaleMax - ScoreModel.scaleMin)
    }

    private func row(
        title: String, value: String, note: String,
        low: Double, point: Double, high: Double, tint: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(DS.Typography.body.weight(.semibold))
                    .foregroundStyle(DS.textPrimary)
                Spacer(minLength: DS.Spacing.s)
                Text(value)
                    .font(DS.Typography.body.weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(tint)
            }
            Text(note)
                .font(DS.Typography.caption)
                .foregroundStyle(DS.textSecondary)
            RangeBar(low: low, point: point, high: high, tint: tint)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title): \(value), \(note).")
    }
}

/// A score header: name + one-line definition.
private struct ScoreHeader: View {
    let name: String
    let definition: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(name)
                .font(DS.Typography.headline)
                .foregroundStyle(DS.textPrimary)
            Text(definition)
                .font(DS.Typography.caption)
                .foregroundStyle(DS.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A small pill, e.g. a confidence or "provisional" chip.
private struct Chip: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text)
            .font(DS.Typography.caption.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, DS.Spacing.s)
            .padding(.vertical, 3)
            .background(tint.opacity(0.14), in: Capsule())
    }
}

/// A 0–1 range band with a point marker, used by the score cards.
private struct RangeBar: View {
    /// Range in `0...1`.
    let low: Double
    let point: Double
    let high: Double
    let tint: Color

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(DS.separator)
                Capsule()
                    .fill(tint.opacity(0.30))
                    .frame(width: max(6, w * (clamped(high) - clamped(low))))
                    .offset(x: w * clamped(low))
                RoundedRectangle(cornerRadius: 1)
                    .fill(tint)
                    .frame(width: 3)
                    .offset(x: w * clamped(point) - 1.5)
            }
        }
        .frame(height: 12)
        .accessibilityHidden(true)
    }

    private func clamped(_ v: Double) -> Double { min(1, max(0, v)) }
}

private struct MemoryCard: View {
    let memory: ScoreRange
    let confidence: ScoreConfidence
    let cards: Int

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.m) {
            HStack(alignment: .top) {
                ScoreHeader(name: "Memory", definition: "Chance of recalling a fact you’ve studied, right now.")
                Spacer(minLength: DS.Spacing.s)
                Chip(text: "confidence: \(confidence.label)", tint: DS.good)
            }
            HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.s) {
                Text(memory.percentRangeText)
                    .font(DS.Typography.title)
                    .monospacedDigit()
                    .foregroundStyle(DS.easy)
                Text("≈\(memory.percentPoint)%")
                    .font(DS.Typography.caption)
                    .monospacedDigit()
                    .foregroundStyle(DS.textSecondary)
            }
            RangeBar(low: memory.low, point: memory.point, high: memory.high, tint: DS.easy)
            Text("Mean real FSRS retrievability across \(cards) studied \(cards == 1 ? "card" : "cards") (95% interval).")
                .font(DS.Typography.caption)
                .foregroundStyle(DS.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .dsCard()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Memory, \(memory.percentLow) to \(memory.percentHigh) percent, point \(memory.percentPoint) percent, confidence \(confidence.label), from \(cards) cards.")
    }
}

private struct PerformanceCard: View {
    let performance: ScoreRange

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.m) {
            HStack(alignment: .top) {
                ScoreHeader(name: "Performance", definition: "Chance of answering a new exam-style question correctly.")
                Spacer(minLength: DS.Spacing.s)
                Chip(text: "provisional", tint: DS.hard)
            }
            HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.s) {
                Text(performance.percentRangeText)
                    .font(DS.Typography.title)
                    .monospacedDigit()
                    .foregroundStyle(DS.hard)
                Text("≈\(performance.percentPoint)%")
                    .font(DS.Typography.caption)
                    .monospacedDigit()
                    .foregroundStyle(DS.textSecondary)
            }
            RangeBar(low: performance.low, point: performance.point, high: performance.high, tint: DS.hard)
            Text(ScoreModel.provisionalLabel)
                .font(DS.Typography.caption.weight(.semibold))
                .foregroundStyle(DS.hard)
                .fixedSize(horizontal: false, vertical: true)
        }
        .dsCard()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Performance, provisional, \(performance.percentLow) to \(performance.percentHigh) percent. \(ScoreModel.provisionalLabel)")
    }
}

private struct ReadinessCard: View {
    let readiness: ReadinessProjection
    let percentCovered: Int

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.m) {
            HStack(alignment: .top) {
                ScoreHeader(name: "Readiness", definition: "Projected MCAT total on the 472–528 scale.")
                Spacer(minLength: DS.Spacing.s)
                Chip(text: "provisional", tint: DS.accent)
            }
            HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.s) {
                Text(readiness.rangeText)
                    .font(.system(.largeTitle, design: .rounded).weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(DS.accent)
                Text("≈\(readiness.point)")
                    .font(DS.Typography.caption)
                    .monospacedDigit()
                    .foregroundStyle(DS.textSecondary)
            }
            ScaleBar(low: readiness.low, point: readiness.point, high: readiness.high)
            HStack {
                Text("472")
                Spacer()
                Text("500")
                Spacer()
                Text("528")
            }
            .font(DS.Typography.caption)
            .monospacedDigit()
            .foregroundStyle(DS.textSecondary)
            Text("Likely range \(readiness.rangeText) · confidence: low — \(percentCovered)% of topics studied. Maps the provisional Performance onto the scale.")
                .font(DS.Typography.caption)
                .foregroundStyle(DS.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .dsCard()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Readiness, provisional, projected \(readiness.point), likely range \(readiness.low) to \(readiness.high) on the 472 to 528 scale, confidence low, \(percentCovered) percent of topics studied.")
    }

    /// A 472–528 scaled-score track with the projected band + point marker.
    private struct ScaleBar: View {
        let low: Int
        let point: Int
        let high: Int

        private func frac(_ score: Int) -> Double {
            let span = Double(ScoreModel.scaleMax - ScoreModel.scaleMin)
            return min(1, max(0, (Double(score) - Double(ScoreModel.scaleMin)) / span))
        }

        var body: some View {
            GeometryReader { geo in
                let w = geo.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(DS.separator)
                    Capsule()
                        .fill(DS.accent.opacity(0.30))
                        .frame(width: max(6, w * (frac(high) - frac(low))))
                        .offset(x: w * frac(low))
                    RoundedRectangle(cornerRadius: 1)
                        .fill(DS.accent)
                        .frame(width: 3)
                        .offset(x: w * frac(point) - 1.5)
                }
            }
            .frame(height: 12)
            .accessibilityHidden(true)
        }
    }
}

// MARK: - Honesty read-out

/// The mandatory honesty read-out: reasons, what's missing, last-updated + %
/// covered + graded reviews, and the single best next thing to study.
private struct HonestyReadout: View {
    let assessment: ReadinessAssessment

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.m) {
            Text("The honest read-out")
                .font(DS.Typography.headline)
                .foregroundStyle(DS.textPrimary)

            BestNextThing(text: assessment.bestNextThing)

            labelledList(title: "Why these numbers", items: assessment.reasons, icon: "info.circle")
            labelledList(title: "What’s missing", items: assessment.missingData, icon: "questionmark.circle")

            Divider().overlay(DS.separator)

            DSStatRow("% of exam covered", value: "\(assessment.coverage.percentCovered)%")
            DSStatRow("Graded reviews", value: "\(assessment.gradedReviews)")
            DSStatRow("Studied cards", value: "\(assessment.studiedCardCount)")
            DSStatRow("Past-prediction accuracy", value: "not enough history yet")
            DSStatRow("Last updated", value: assessment.lastUpdated.formatted(date: .abbreviated, time: .shortened))
        }
        .dsCard()
    }

    private func labelledList(title: String, items: [String], icon: String) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            Text(title)
                .font(DS.Typography.body.weight(.semibold))
                .foregroundStyle(DS.textPrimary)
            ForEach(items, id: \.self) { item in
                HStack(alignment: .top, spacing: DS.Spacing.s) {
                    Image(systemName: icon)
                        .font(DS.Typography.caption)
                        .foregroundStyle(DS.textSecondary)
                        .padding(.top, 2)
                    Text(item)
                        .font(DS.Typography.caption)
                        .foregroundStyle(DS.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
            }
        }
    }
}

/// The single best next thing to study — highlighted, since the honesty rule
/// requires it on every read-out (scored or abstaining).
private struct BestNextThing: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: DS.Spacing.m) {
            Image(systemName: "target")
                .font(DS.Typography.headline)
                .foregroundStyle(DS.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text("Best next thing to study")
                    .font(DS.Typography.caption.weight(.semibold))
                    .foregroundStyle(DS.textSecondary)
                Text(text)
                    .font(DS.Typography.body.weight(.semibold))
                    .foregroundStyle(DS.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(DS.Spacing.m)
        .background(DS.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: DS.Radius.medium, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Abstain content

/// The give-up state: NO scores, the explicit threshold, what's missing (with
/// progress), and the single best next thing to study.
private struct AbstainContent: View {
    let assessment: ReadinessAssessment

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.l) {
            banner
            ThresholdProgressCard(assessment: assessment)
            VStack(alignment: .leading, spacing: DS.Spacing.m) {
                BestNextThing(text: assessment.bestNextThing)
                missingList
            }
            .dsCard()
            CoverageSummaryCard(coverage: assessment.coverage)
        }
    }

    private var banner: some View {
        HStack(alignment: .top, spacing: DS.Spacing.m) {
            Image(systemName: "hand.raised.fill")
                .font(DS.Typography.headline)
                .foregroundStyle(DS.hard)
            VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                Text("No scores yet — not enough data")
                    .font(DS.Typography.body.weight(.semibold))
                    .foregroundStyle(DS.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(ScoreModel.giveUpRule)
                    .font(DS.Typography.caption)
                    .foregroundStyle(DS.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(DS.Spacing.l)
        .background(DS.hard.opacity(0.12), in: RoundedRectangle(cornerRadius: DS.Radius.large, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.large, style: .continuous)
                .strokeBorder(DS.hard.opacity(0.5), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
    }

    private var missingList: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            Text("What’s missing")
                .font(DS.Typography.body.weight(.semibold))
                .foregroundStyle(DS.textPrimary)
            ForEach(assessment.missingData, id: \.self) { item in
                HStack(alignment: .top, spacing: DS.Spacing.s) {
                    Image(systemName: "questionmark.circle")
                        .font(DS.Typography.caption)
                        .foregroundStyle(DS.textSecondary)
                        .padding(.top, 2)
                    Text(item)
                        .font(DS.Typography.caption)
                        .foregroundStyle(DS.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
            }
        }
    }
}

/// The two give-up gates shown as progress toward their thresholds.
private struct ThresholdProgressCard: View {
    let assessment: ReadinessAssessment

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.m) {
            Text("Progress to scoring")
                .font(DS.Typography.headline)
                .foregroundStyle(DS.textPrimary)
            gate(
                title: "Graded reviews",
                value: assessment.gradedReviews,
                target: ScoreModel.gradedReviewThreshold,
                met: assessment.meetsGradedReviewThreshold,
                fraction: Double(assessment.gradedReviews) / Double(ScoreModel.gradedReviewThreshold),
                detail: "\(assessment.gradedReviews) / \(ScoreModel.gradedReviewThreshold)"
            )
            gate(
                title: "Topic coverage",
                value: assessment.coverage.percentCovered,
                target: Int(ScoreModel.coverageThreshold * 100),
                met: assessment.meetsCoverageThreshold,
                fraction: assessment.coverage.fractionCovered / ScoreModel.coverageThreshold,
                detail: "\(assessment.coverage.percentCovered)% / \(Int(ScoreModel.coverageThreshold * 100))%"
            )
        }
        .dsCard()
    }

    private func gate(
        title: String, value: Int, target: Int, met: Bool, fraction: Double, detail: String
    ) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            HStack {
                Image(systemName: met ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(met ? DS.easy : DS.textSecondary)
                Text(title)
                    .font(DS.Typography.body)
                    .foregroundStyle(DS.textPrimary)
                Spacer(minLength: DS.Spacing.s)
                Text(detail)
                    .font(DS.Typography.body.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(met ? DS.easy : DS.hard)
            }
            ProgressTrack(fraction: fraction, tint: met ? DS.easy : DS.hard)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title): \(detail), \(met ? "met" : "not met").")
    }
}

/// A simple 0–1 progress meter (clamped), for the abstain gates.
private struct ProgressTrack: View {
    let fraction: Double
    let tint: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(DS.separator)
                Capsule()
                    .fill(tint)
                    .frame(width: max(4, geo.size.width * min(1, max(0, fraction))))
            }
        }
        .frame(height: 6)
        .accessibilityHidden(true)
    }
}

// MARK: - Coverage summary (compact)

/// A compact coverage read-out (overall + per section), shown under the scores as
/// the "% of exam covered" context and the four-section (118–132) structure. The
/// full per-topic breakdown lives on the dedicated Coverage screen.
private struct CoverageSummaryCard: View {
    let coverage: CoverageReport

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.m) {
            HStack(alignment: .firstTextBaseline) {
                Text("Exam coverage")
                    .font(DS.Typography.headline)
                    .foregroundStyle(DS.textPrimary)
                Spacer(minLength: DS.Spacing.s)
                Text("\(coverage.percentCovered)%")
                    .font(DS.Typography.headline)
                    .monospacedDigit()
                    .foregroundStyle(color(coverage.fractionCovered))
            }
            ProgressTrack(fraction: coverage.fractionCovered, tint: color(coverage.fractionCovered))
            ForEach(coverage.sections) { section in
                HStack {
                    Text(section.section)
                        .font(DS.Typography.caption)
                        .foregroundStyle(DS.textSecondary)
                    Spacer(minLength: DS.Spacing.s)
                    Text("\(section.coveredCount)/\(section.totalCount) · \(section.percentCovered)%")
                        .font(DS.Typography.caption)
                        .monospacedDigit()
                        .foregroundStyle(color(section.fractionCovered))
                }
            }
            Text("The four sections each score 118–132 (total 472–528). Per-section score projection is deferred until per-section calibration.")
                .font(DS.Typography.caption)
                .foregroundStyle(DS.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .dsCard()
    }

    private func color(_ fraction: Double) -> Color {
        if fraction >= CoverageReport.scoringThreshold { return DS.easy }
        if fraction >= 0.30 { return DS.hard }
        return DS.again
    }
}
