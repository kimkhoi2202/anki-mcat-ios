import SwiftUI
import AnkiKit

/// MCAT coverage map (PRD 7c) — "list every MCAT outline topic, mark deck
/// coverage, show % on the dashboard; below the line, abstain."
///
/// Lists the four AAMC sections with the share of `MCATOutline` topics that have
/// at least one card in the collection (computed by the engine via
/// `AnkiStore.loadCoverage()` → `Backend.coverage`), each broken down into its
/// covered / missing topics. When overall coverage is below the give-up line
/// (`CoverageReport.scoringThreshold`, 50%) it shows an explicit abstain banner
/// instead of implying the deck is ready to be scored.
///
/// This screen deliberately stops at coverage: the Memory / Performance /
/// Readiness scores are the next task. They will consume the same
/// `CoverageReport` (`fractionCovered` as "% of exam covered",
/// `meetsCoverageThreshold` as the coverage half of the give-up rule).
struct CoverageView: View {
    @ObservedObject var store: AnkiStore

    var body: some View {
        ZStack {
            DS.background.ignoresSafeArea()
            content
        }
        .navigationTitle("MCAT Coverage")
        .navigationBarTitleDisplayMode(.inline)
        .task { await store.loadCoverage() }
    }

    @ViewBuilder
    private var content: some View {
        if let report = store.coverage {
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Spacing.l) {
                    explainer
                    if !report.meetsCoverageThreshold {
                        AbstainBanner(percent: report.percentCovered)
                    }
                    OverallCoverageCard(report: report)
                    ForEach(report.sections) { section in
                        SectionCoverageCard(section: section)
                    }
                    footnote
                }
                .padding(DS.Spacing.l)
            }
        } else if let error = store.coverageError {
            errorState(error)
        } else {
            loadingState
        }
    }

    private var explainer: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            Text("How much of the exam your deck touches")
                .font(DS.Typography.title)
                .foregroundStyle(DS.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Text("A topic counts as covered once it has at least one card. Coverage is one input to the upcoming scores — not a score itself.")
                .font(DS.Typography.caption)
                .foregroundStyle(DS.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Honest footnote: names the taxonomy's provenance and granularity, since the
    /// percentage is only meaningful relative to the outline it's measured against.
    private var footnote: some View {
        Text("Topics are a representative subset of the AAMC MCAT content outline (≈11–14 per section), not the full list. Percentages are of those topics.")
            .font(DS.Typography.caption)
            .foregroundStyle(DS.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, DS.Spacing.xs)
    }

    private var loadingState: some View {
        VStack(spacing: DS.Spacing.m) {
            ProgressView()
            Text("Mapping coverage…")
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
            Text("Couldn’t load coverage")
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

/// The give-up banner shown when overall coverage is under the scoring line. The
/// app refuses to imply readiness it can't support (PRD honesty + give-up rules).
private struct AbstainBanner: View {
    let percent: Int

    private var threshold: Int { Int((CoverageReport.scoringThreshold * 100).rounded()) }

    var body: some View {
        HStack(alignment: .top, spacing: DS.Spacing.m) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(DS.Typography.headline)
                .foregroundStyle(DS.hard)
            VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                Text("Not enough coverage to score yet — \(percent)% of MCAT topics studied")
                    .font(DS.Typography.body.weight(.semibold))
                    .foregroundStyle(DS.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Scores stay hidden until at least \(threshold)% of topics have a card. Study the missing topics below to unlock them.")
                    .font(DS.Typography.caption)
                    .foregroundStyle(DS.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(DS.Spacing.l)
        .background(
            DS.hard.opacity(0.12),
            in: RoundedRectangle(cornerRadius: DS.Radius.large, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.large, style: .continuous)
                .strokeBorder(DS.hard.opacity(0.5), lineWidth: 1)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Not enough coverage to score yet. \(percent) percent of MCAT topics studied. Scores stay hidden until at least \(threshold) percent.")
    }
}

/// The overall rollup: a big percentage, the covered/total topic count, and a bar.
private struct OverallCoverageCard: View {
    let report: CoverageReport

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.s) {
            HStack(alignment: .firstTextBaseline) {
                Text("Overall")
                    .font(DS.Typography.headline)
                    .foregroundStyle(DS.textPrimary)
                Spacer(minLength: DS.Spacing.s)
                Text("\(report.percentCovered)%")
                    .font(DS.Typography.title)
                    .monospacedDigit()
                    .foregroundStyle(CoveragePalette.color(report.fractionCovered))
            }
            CoverageBar(fraction: report.fractionCovered)
            Text("\(report.coveredTopics) of \(report.totalTopics) topics studied")
                .font(DS.Typography.caption)
                .foregroundStyle(DS.textSecondary)
        }
        .dsCard()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Overall coverage \(report.percentCovered) percent, \(report.coveredTopics) of \(report.totalTopics) topics studied")
    }
}

/// One section: header (short + full name, percent, covered/total, bar) and the
/// per-topic covered / missing breakdown.
private struct SectionCoverageCard: View {
    let section: SectionCoverage

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.m) {
            header
            Divider().overlay(DS.separator)
            VStack(spacing: DS.Spacing.s) {
                ForEach(section.topics) { topic in
                    TopicRow(topic: topic)
                }
            }
        }
        .dsCard()
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            HStack(alignment: .firstTextBaseline) {
                Text(section.section)
                    .font(DS.Typography.headline)
                    .foregroundStyle(DS.textPrimary)
                Spacer(minLength: DS.Spacing.s)
                Text("\(section.coveredCount)/\(section.totalCount) · \(section.percentCovered)%")
                    .font(DS.Typography.body.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(CoveragePalette.color(section.fractionCovered))
            }
            if let fullName = MCATOutline.fullName(forSection: section.section) {
                Text(fullName)
                    .font(DS.Typography.caption)
                    .foregroundStyle(DS.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            CoverageBar(fraction: section.fractionCovered)
                .padding(.top, DS.Spacing.xs)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(section.section), \(section.coveredCount) of \(section.totalCount) topics studied, \(section.percentCovered) percent")
    }
}

/// A single topic line: a covered/missing icon and the topic name (muted when
/// missing). Card-count appears for covered topics.
private struct TopicRow: View {
    let topic: TopicCoverage

    var body: some View {
        HStack(spacing: DS.Spacing.s) {
            Image(systemName: topic.isCovered ? "checkmark.circle.fill" : "circle")
                .font(DS.Typography.body)
                .foregroundStyle(topic.isCovered ? DS.easy : DS.textSecondary)
            Text(topic.name)
                .font(DS.Typography.body)
                .foregroundStyle(topic.isCovered ? DS.textPrimary : DS.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: DS.Spacing.s)
            Text(trailing)
                .font(DS.Typography.caption)
                .monospacedDigit()
                .foregroundStyle(DS.textSecondary)
        }
        .frame(minHeight: 28)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    private var trailing: String {
        if topic.isCovered {
            let noun = topic.cardCount == 1 ? "card" : "cards"
            return "\(topic.cardCount) \(noun)"
        }
        return "missing"
    }

    private var accessibilityLabel: String {
        topic.isCovered
            ? "\(topic.name), covered, \(topic.cardCount) \(topic.cardCount == 1 ? "card" : "cards")"
            : "\(topic.name), missing"
    }
}

/// A horizontal coverage meter (0…1), colored by how much is covered.
private struct CoverageBar: View {
    let fraction: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(DS.separator)
                Capsule()
                    .fill(CoveragePalette.color(fraction))
                    .frame(width: max(4, geo.size.width * clamped))
            }
        }
        .frame(height: 6)
        .accessibilityHidden(true)
    }

    private var clamped: Double { min(1, max(0, fraction)) }
}

/// Shared coverage color scale: red below the give-up line, amber approaching it,
/// green once comfortably covered. Keeps the overall card, section headers, and
/// bars consistent.
private enum CoveragePalette {
    static func color(_ fraction: Double) -> Color {
        if fraction >= CoverageReport.scoringThreshold { return DS.easy }
        if fraction >= 0.30 { return DS.hard }
        return DS.again
    }
}
