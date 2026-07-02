import SwiftUI
import UIKit
import AnkiKit

/// The MCAT readiness dashboard — the three scores (Memory / Performance /
/// Readiness), each as a range, with the full honesty read-out; or the abstain
/// state when the deck is below the give-up line.
///
/// Honesty rule (mandatory): when scored, every number is shown with its
/// evidence, what data is missing, the likely range, a confidence indicator, the
/// % of exam covered, the last-updated time, the main reasons, and the single
/// best next thing to study. Below the line it shows NO scores — only the
/// give-up line, what's missing, and the best next thing. Performance (and the
/// Readiness that depends on it) is clearly labelled provisional/uncalibrated.
struct ReadinessDashboardView: View {
    @ObservedObject var store: AnkiStore
    /// When true (a screenshot/automation hook), seed + show the scored demo deck
    /// on first appearance instead of the real deck's abstain state.
    var autoLoadDemo = false

    @State private var didLoad = false

    var body: some View {
        Group {
            if let assessment = store.readiness {
                list(assessment)
            } else if let error = store.readinessError {
                MCATEmptyState(icon: "exclamationmark.triangle", title: "Couldn’t compute scores", message: error)
            } else {
                ProgressView("Scoring…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("Readiness")
        .navigationBarTitleDisplayMode(.inline)
        .tint(DS.accent)
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

    private var isDemoDeck: Bool { store.readinessDeckName == AnkiStore.demoReadinessDeckName }

    private func list(_ assessment: ReadinessAssessment) -> some View {
        List {
            Section {
                deckSwitcher
            } header: {
                Text("Scoring deck")
            } footer: {
                Text("“\(store.readinessDeckName)” — three separate scores, each a range. \(ScoreModel.giveUpRule)")
            }

            if isDemoDeck { demoBanner }

            if assessment.isScored {
                scoredSections(assessment)
            } else {
                abstainSections(assessment)
            }
        }
        .listStyle(.insetGrouped)
        .overlay(alignment: .top) {
            if store.readinessLoading {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Updating…").font(.caption).foregroundStyle(.secondary)
                }
                .padding(.vertical, 8).padding(.horizontal, 14)
                .background(.regularMaterial, in: Capsule())
                .padding(.top, 8)
            }
        }
    }

    // MARK: - Deck switcher

    @ViewBuilder
    private var deckSwitcher: some View {
        if isDemoDeck {
            Button {
                Task { await store.loadReadiness(forDeck: AnkiStore.realReadinessDeckName) }
            } label: {
                Label("Back to real deck (“\(AnkiStore.realReadinessDeckName)”)", systemImage: "arrow.uturn.backward")
            }
        } else {
            Button {
                Task {
                    if store.readinessDemoSeeded {
                        await store.loadReadiness(forDeck: AnkiStore.demoReadinessDeckName)
                    } else {
                        await store.seedAndShowReadinessDemo()
                    }
                }
            } label: {
                Label(
                    store.readinessDemoSeeded ? "Show the scored demo deck" : "Load a scored demo deck (simulated history)",
                    systemImage: "wand.and.stars"
                )
            }
            .disabled(store.readinessLoading)
        }
    }

    private var demoBanner: some View {
        Section {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "wand.and.stars").foregroundStyle(DS.accent)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Demo deck — simulated study history")
                        .font(.subheadline.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Real MCAT facts with a seeded FSRS history so the scored state is reachable. Every number below is still computed by the engine from that stored state — nothing is hand-written. The real “\(AnkiStore.realReadinessDeckName)” deck correctly abstains.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .listRowBackground(DS.accent.opacity(0.12))
        .accessibilityElement(children: .combine)
    }

    // MARK: - Scored

    @ViewBuilder
    private func scoredSections(_ assessment: ReadinessAssessment) -> some View {
        if let memory = assessment.memory,
           let performance = assessment.performance,
           let readiness = assessment.readiness {
            Section("Your three scores") {
                summaryRow(title: "Memory", value: memory.percentRangeText, note: "real FSRS recall",
                           low: memory.low, point: memory.point, high: memory.high, tint: DS.easy)
                summaryRow(title: "Performance", value: performance.percentRangeText, note: "provisional",
                           low: performance.low, point: performance.point, high: performance.high, tint: DS.hard)
                summaryRow(title: "Readiness", value: readiness.rangeText, note: "MCAT 472–528 · provisional",
                           low: frac(readiness.low), point: frac(readiness.point), high: frac(readiness.high), tint: DS.accent)
            }
        }

        if let memory = assessment.memory {
            Section {
                scoreValueRow(memory.percentRangeText, approx: "≈\(memory.percentPoint)%", tint: DS.easy,
                              chip: Chip(text: "confidence: \(assessment.memoryConfidence.label)", tint: DS.good))
                RangeBar(low: memory.low, point: memory.point, high: memory.high, tint: DS.easy)
                    .listRowSeparator(.hidden)
            } header: {
                Text("Memory")
            } footer: {
                Text("Chance of recalling a fact you’ve studied, right now. Mean real FSRS retrievability across \(assessment.cardsWithMemoryState) studied \(assessment.cardsWithMemoryState == 1 ? "card" : "cards") (95% interval).")
            }
        }

        if let performance = assessment.performance {
            Section {
                scoreValueRow(performance.percentRangeText, approx: "≈\(performance.percentPoint)%", tint: DS.hard,
                              chip: Chip(text: "provisional", tint: DS.hard))
                RangeBar(low: performance.low, point: performance.point, high: performance.high, tint: DS.hard)
                    .listRowSeparator(.hidden)
            } header: {
                Text("Performance")
            } footer: {
                Text("Chance of answering a new exam-style question correctly. \(ScoreModel.provisionalLabel)")
            }
        }

        if let readiness = assessment.readiness {
            Section {
                scoreValueRow(readiness.rangeText, approx: "≈\(readiness.point)", tint: DS.accent,
                              chip: Chip(text: "provisional", tint: DS.accent), large: true)
                ScaleBar(low: readiness.low, point: readiness.point, high: readiness.high)
                    .listRowSeparator(.hidden)
                HStack {
                    Text("472"); Spacer(); Text("500"); Spacer(); Text("528")
                }
                .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                .listRowSeparator(.hidden)
            } header: {
                Text("Readiness")
            } footer: {
                Text("Projected MCAT total on the 472–528 scale. Likely range \(readiness.rangeText) · confidence: low — \(assessment.coverage.percentCovered)% of topics studied. Maps the provisional Performance onto the scale.")
            }
        }

        honestyReadout(assessment)
        coverageSummary(assessment.coverage)
    }

    // MARK: - Abstain

    @ViewBuilder
    private func abstainSections(_ assessment: ReadinessAssessment) -> some View {
        Section {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "hand.raised.fill").foregroundStyle(DS.hard)
                VStack(alignment: .leading, spacing: 4) {
                    Text("No scores yet — not enough data")
                        .font(.subheadline.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(ScoreModel.giveUpRule)
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .listRowBackground(DS.hard.opacity(0.12))

        Section("Progress to scoring") {
            gateRow(title: "Graded reviews", met: assessment.meetsGradedReviewThreshold,
                    fraction: Double(assessment.gradedReviews) / Double(ScoreModel.gradedReviewThreshold),
                    detail: "\(assessment.gradedReviews) / \(ScoreModel.gradedReviewThreshold)")
            gateRow(title: "Topic coverage", met: assessment.meetsCoverageThreshold,
                    fraction: assessment.coverage.fractionCovered / ScoreModel.coverageThreshold,
                    detail: "\(assessment.coverage.percentCovered)% / \(Int(ScoreModel.coverageThreshold * 100))%")
        }

        Section {
            bestNextThingRow(assessment.bestNextThing)
        }
        .listRowBackground(DS.accent.opacity(0.10))

        if !assessment.missingData.isEmpty {
            Section("What’s missing") {
                ForEach(assessment.missingData, id: \.self) { item in
                    Label(item, systemImage: "questionmark.circle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }

        coverageSummary(assessment.coverage)
    }

    // MARK: - Honesty read-out

    @ViewBuilder
    private func honestyReadout(_ assessment: ReadinessAssessment) -> some View {
        Section {
            bestNextThingRow(assessment.bestNextThing)
        }
        .listRowBackground(DS.accent.opacity(0.10))

        if !assessment.reasons.isEmpty {
            Section("Why these numbers") {
                ForEach(assessment.reasons, id: \.self) { item in
                    Label(item, systemImage: "info.circle")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
        }

        if !assessment.missingData.isEmpty {
            Section("What’s missing") {
                ForEach(assessment.missingData, id: \.self) { item in
                    Label(item, systemImage: "questionmark.circle")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
        }

        Section("Evidence") {
            LabeledContent("% of exam covered", value: "\(assessment.coverage.percentCovered)%")
            LabeledContent("Graded reviews", value: "\(assessment.gradedReviews)")
            LabeledContent("Studied cards", value: "\(assessment.studiedCardCount)")
            LabeledContent("Past-prediction accuracy", value: "not enough history yet")
            LabeledContent("Last updated", value: assessment.lastUpdated.formatted(date: .abbreviated, time: .shortened))
        }
    }

    private func coverageSummary(_ coverage: CoverageReport) -> some View {
        Section {
            HStack(alignment: .firstTextBaseline) {
                Text("\(coverage.percentCovered)%")
                    .font(.title3.bold()).monospacedDigit()
                    .foregroundStyle(coverageColor(coverage.fractionCovered))
                Spacer(minLength: 8)
            }
            ProgressView(value: coverage.fractionCovered)
                .tint(coverageColor(coverage.fractionCovered))
            ForEach(coverage.sections) { section in
                HStack {
                    Text(section.section).foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Text("\(section.coveredCount)/\(section.totalCount) · \(section.percentCovered)%")
                        .font(.caption).monospacedDigit()
                        .foregroundStyle(coverageColor(section.fractionCovered))
                }
            }
        } header: {
            Text("Exam coverage")
        } footer: {
            Text("The four sections each score 118–132 (total 472–528). Per-section score projection is deferred until per-section calibration.")
        }
    }

    // MARK: - Row builders

    private func summaryRow(
        title: String, value: String, note: String,
        low: Double, point: Double, high: Double, tint: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.body.weight(.semibold))
                Spacer(minLength: 8)
                Text(value).font(.body.weight(.bold)).monospacedDigit().foregroundStyle(tint)
            }
            Text(note).font(.caption).foregroundStyle(.secondary)
            RangeBar(low: low, point: point, high: high, tint: tint)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title): \(value), \(note).")
    }

    private func scoreValueRow(_ range: String, approx: String, tint: Color, chip: Chip, large: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(range)
                .font(large ? .system(.largeTitle, design: .rounded).weight(.bold) : .title2.weight(.bold))
                .monospacedDigit()
                .foregroundStyle(tint)
            Text(approx).font(.caption).monospacedDigit().foregroundStyle(.secondary)
            Spacer(minLength: 8)
            chip
        }
    }

    private func gateRow(title: String, met: Bool, fraction: Double, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: met ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(met ? DS.easy : Color.secondary)
                Text(title)
                Spacer(minLength: 8)
                Text(detail).font(.body.weight(.semibold)).monospacedDigit()
                    .foregroundStyle(met ? DS.easy : DS.hard)
            }
            ProgressView(value: min(1, max(0, fraction))).tint(met ? DS.easy : DS.hard)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title): \(detail), \(met ? "met" : "not met").")
    }

    private func bestNextThingRow(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "target").foregroundStyle(DS.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text("Best next thing to study")
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text(text).font(.body.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - Helpers

    private func frac(_ score: Int) -> Double {
        Double(score - ScoreModel.scaleMin) / Double(ScoreModel.scaleMax - ScoreModel.scaleMin)
    }

    private func coverageColor(_ fraction: Double) -> Color {
        if fraction >= CoverageReport.scoringThreshold { return DS.easy }
        if fraction >= 0.30 { return DS.hard }
        return DS.again
    }
}

// MARK: - Small components

/// A small pill, e.g. a confidence or "provisional" chip.
private struct Chip: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(tint.opacity(0.15), in: Capsule())
    }
}

/// A 0–1 range band with a point marker, used by the score rows.
private struct RangeBar: View {
    let low: Double
    let point: Double
    let high: Double
    let tint: Color

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(Color(.systemFill))
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
                Capsule().fill(Color(.systemFill))
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
