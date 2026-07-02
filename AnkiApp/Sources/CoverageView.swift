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
struct CoverageView: View {
    @ObservedObject var store: AnkiStore

    var body: some View {
        Group {
            if let report = store.coverage {
                list(report)
            } else if let error = store.coverageError {
                errorState(error)
            } else {
                ProgressView("Mapping coverage…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("MCAT Coverage")
        .navigationBarTitleDisplayMode(.inline)
        .tint(DS.accent)
        .task { await store.loadCoverage() }
    }

    private func list(_ report: CoverageReport) -> some View {
        List {
            if !report.meetsCoverageThreshold {
                AbstainBanner(percent: report.percentCovered)
            }

            Section {
                HStack(alignment: .firstTextBaseline) {
                    Text("\(report.percentCovered)%")
                        .font(.title.bold())
                        .monospacedDigit()
                        .foregroundStyle(CoveragePalette.color(report.fractionCovered))
                    Spacer(minLength: 8)
                    Text("\(report.coveredTopics) of \(report.totalTopics) topics")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                ProgressView(value: report.fractionCovered)
                    .tint(CoveragePalette.color(report.fractionCovered))
            } header: {
                Text("Overall coverage")
            } footer: {
                Text("A topic counts as covered once it has at least one card. Coverage is one input to the upcoming scores — not a score itself.")
            }

            ForEach(report.sections) { section in
                Section {
                    ProgressView(value: section.fractionCovered)
                        .tint(CoveragePalette.color(section.fractionCovered))
                    ForEach(section.topics) { topic in
                        TopicRow(topic: topic)
                    }
                } header: {
                    HStack(alignment: .firstTextBaseline) {
                        Text(section.section)
                        Spacer(minLength: 8)
                        Text("\(section.coveredCount)/\(section.totalCount) · \(section.percentCovered)%")
                            .monospacedDigit()
                            .foregroundStyle(CoveragePalette.color(section.fractionCovered))
                    }
                } footer: {
                    if let fullName = MCATOutline.fullName(forSection: section.section) {
                        Text(fullName)
                    }
                }
            }

            Section {
                Text("Topics are a representative subset of the AAMC MCAT content outline (≈11–14 per section), not the full list. Percentages are of those topics.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .listStyle(.insetGrouped)
    }

    private func errorState(_ message: String) -> some View {
        MCATEmptyState(icon: "exclamationmark.triangle", title: "Couldn’t load coverage", message: message)
    }
}

/// The give-up banner shown when overall coverage is under the scoring line. The
/// app refuses to imply readiness it can't support (PRD honesty + give-up rules).
private struct AbstainBanner: View {
    let percent: Int

    private var threshold: Int { Int((CoverageReport.scoringThreshold * 100).rounded()) }

    var body: some View {
        Section {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(DS.hard)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Not enough coverage to score yet — \(percent)% of MCAT topics studied")
                        .font(.subheadline.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Scores stay hidden until at least \(threshold)% of topics have a card. Study the missing topics below to unlock them.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .listRowBackground(DS.hard.opacity(0.12))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Not enough coverage to score yet. \(percent) percent of MCAT topics studied. Scores stay hidden until at least \(threshold) percent.")
    }
}

/// A single topic line: a covered/missing icon and the topic name (muted when
/// missing). Card-count appears for covered topics.
private struct TopicRow: View {
    let topic: TopicCoverage

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: topic.isCovered ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(topic.isCovered ? DS.easy : Color.secondary)
            Text(topic.name)
                .foregroundStyle(topic.isCovered ? Color.primary : Color.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            Text(trailing)
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
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

/// Shared coverage color scale: red below the give-up line, amber approaching it,
/// green once comfortably covered.
private enum CoveragePalette {
    static func color(_ fraction: Double) -> Color {
        if fraction >= CoverageReport.scoringThreshold { return DS.easy }
        if fraction >= 0.30 { return DS.hard }
        return DS.again
    }
}
