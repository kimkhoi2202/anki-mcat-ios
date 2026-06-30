import SwiftUI
import AnkiKit

/// "Focus weak topics" study mode (PRD 7a) — the user-facing surface for the
/// Rust points-at-stake change running on-device.
///
/// Shows a read-out of the deck's MCAT topics ranked weakest-first by the
/// engine's points-at-stake score (topic weakness = `1 − average FSRS recall`),
/// then lets the user study the deck's due review cards in that order. The
/// ordering and per-topic data come straight from the engine RPC
/// (`SchedulerService.GetPointsAtStakeQueue`, service 13/39) via
/// `AnkiStore.loadWeakTopics`.
struct WeakTopicsView: View {
    @ObservedObject var store: AnkiStore
    let deck: DeckTreeEntry

    @State private var goReview = false
    @State private var loaded = false

    var body: some View {
        ZStack {
            DS.background.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Spacing.l) {
                    explainer
                    if store.weakTopics.isEmpty {
                        emptyState
                    } else {
                        topicsCard
                        studyButton
                    }
                }
                .padding(DS.Spacing.l)
            }
        }
        .navigationTitle("Focus Weak Topics")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: $goReview) {
            ReviewerView(store: store)
        }
        .task {
            // Load once; the engine call scopes the ranking to this deck.
            guard !loaded else { return }
            loaded = true
            store.loadWeakTopics(deckID: deck.id, deckName: deck.fullName)
        }
    }

    private var explainer: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            Text(deck.fullName)
                .font(DS.Typography.title)
                .foregroundStyle(DS.textPrimary)
                .lineLimit(2)
            Text("Your due review cards, reordered weakest-topic-first by the engine’s points-at-stake score. Weakness is 1 − average recall, computed on-device from each card’s FSRS memory.")
                .font(DS.Typography.caption)
                .foregroundStyle(DS.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var topicsCard: some View {
        VStack(spacing: 0) {
            ForEach(Array(store.weakTopics.enumerated()), id: \.element.id) { index, topic in
                if index > 0 {
                    Divider().overlay(DS.separator)
                }
                WeakTopicRow(rank: index + 1, topic: topic, isWeakest: index == 0)
            }
        }
        .dsCard(padding: 0)
    }

    private var studyButton: some View {
        Button {
            store.startWeakTopicsReview()
            goReview = true
        } label: {
            Text(studyButtonTitle)
        }
        .buttonStyle(.dsPrimary)
        .disabled(store.weakTopicsCardCount == 0)
        .accessibilityLabel("Study weakest topics first, \(store.weakTopicsCardCount) cards")
    }

    private var studyButtonTitle: String {
        let count = store.weakTopicsCardCount
        let noun = count == 1 ? "card" : "cards"
        return "Study weakest first · \(count) \(noun)"
    }

    private var emptyState: some View {
        VStack(spacing: DS.Spacing.m) {
            Image(systemName: "checkmark.seal")
                .font(.system(size: 40))
                .foregroundStyle(DS.textSecondary)
            Text("No due review cards yet")
                .font(DS.Typography.headline)
                .foregroundStyle(DS.textPrimary)
            Text("Points-at-stake ranks topics by FSRS recall on cards that are due for review. Once this deck has due, MCAT-tagged review cards, their weakest topics show up here.")
                .font(DS.Typography.caption)
                .foregroundStyle(DS.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, DS.Spacing.xl)
        .dsCard()
    }
}

/// One ranked topic in the read-out: rank badge, topic name, weakness percentage
/// with a proportional bar, and a card-count / average-recall subtitle. The
/// weakest topic (rank 1) is highlighted since it studies first.
private struct WeakTopicRow: View {
    let rank: Int
    let topic: WeakTopic
    let isWeakest: Bool

    var body: some View {
        HStack(alignment: .top, spacing: DS.Spacing.m) {
            rankBadge
            VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                HStack(alignment: .firstTextBaseline) {
                    Text(topic.topic)
                        .font(DS.Typography.body.weight(.semibold))
                        .foregroundStyle(DS.textPrimary)
                        .lineLimit(1)
                    Spacer(minLength: DS.Spacing.s)
                    Text(weaknessPercent)
                        .font(DS.Typography.body.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(weaknessColor)
                }
                WeaknessBar(fraction: topic.weakness)
                Text(subtitle)
                    .font(DS.Typography.caption)
                    .foregroundStyle(DS.textSecondary)
            }
        }
        .padding(DS.Spacing.l)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    private var rankBadge: some View {
        Text("\(rank)")
            .font(DS.Typography.caption.weight(.bold))
            .monospacedDigit()
            .foregroundStyle(isWeakest ? Color.white : DS.textSecondary)
            .frame(width: 26, height: 26)
            .background(isWeakest ? DS.again : DS.background, in: Circle())
            .overlay(Circle().strokeBorder(DS.separator, lineWidth: isWeakest ? 0 : 1))
            .accessibilityHidden(true)
    }

    private var weaknessPercent: String {
        "\(Int((topic.weakness * 100).rounded()))% weak"
    }

    private var weaknessColor: Color {
        if topic.weakness >= 0.40 { return DS.again }
        if topic.weakness >= 0.15 { return DS.hard }
        return DS.easy
    }

    private var subtitle: String {
        let noun = topic.cardCount == 1 ? "due card" : "due cards"
        var parts = ["\(topic.cardCount) \(noun)"]
        if let recall = topic.meanRetrievability {
            parts.append("avg recall \(Int((recall * 100).rounded()))%")
        }
        return parts.joined(separator: " · ")
    }

    private var accessibilityLabel: String {
        var label = "Rank \(rank), \(topic.topic), \(weaknessPercent), \(subtitle)"
        if isWeakest { label += ", studied first" }
        return label
    }
}

/// A horizontal weakness meter (0…1), colored by severity to match the
/// percentage label. Purely decorative — the row carries the spoken value.
private struct WeaknessBar: View {
    let fraction: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(DS.separator)
                Capsule()
                    .fill(color)
                    .frame(width: max(4, geo.size.width * clamped))
            }
        }
        .frame(height: 6)
        .accessibilityHidden(true)
    }

    private var clamped: Double { min(1, max(0, fraction)) }

    private var color: Color {
        if fraction >= 0.40 { return DS.again }
        if fraction >= 0.15 { return DS.hard }
        return DS.easy
    }
}
