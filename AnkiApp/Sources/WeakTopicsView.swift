import SwiftUI
import UIKit
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
        Group {
            if store.weakTopics.isEmpty {
                MCATEmptyState(icon: "checkmark.seal", title: "No due review cards yet",
                               message: "Points-at-stake ranks topics by FSRS recall on cards that are due for review. Once this deck has due, MCAT-tagged review cards, their weakest topics show up here.")
            } else {
                list
            }
        }
        .navigationTitle("Focus Weak Topics")
        .navigationBarTitleDisplayMode(.inline)
        .tint(DS.accent)
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

    private var list: some View {
        List {
            Section {
                ForEach(Array(store.weakTopics.enumerated()), id: \.element.id) { index, topic in
                    WeakTopicRow(rank: index + 1, topic: topic, isWeakest: index == 0)
                }
            } header: {
                Text("Weakest topics first")
            } footer: {
                Text("Ranking for “\(deck.fullName)”. Your due review cards, reordered weakest-topic-first by the engine’s points-at-stake score — weakness is 1 − average recall, computed on-device from each card’s FSRS memory.")
            }

            Section {
                Button {
                    store.startWeakTopicsReview()
                    goReview = true
                } label: {
                    Label(studyButtonTitle, systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(store.weakTopicsCardCount == 0)
                .accessibilityLabel("Study weakest topics first, \(store.weakTopicsCardCount) cards")
            }
            .listRowBackground(Color.clear)
        }
        .listStyle(.insetGrouped)
    }

    private var studyButtonTitle: String {
        let count = store.weakTopicsCardCount
        let noun = count == 1 ? "card" : "cards"
        return "Study weakest first · \(count) \(noun)"
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
        HStack(alignment: .top, spacing: 12) {
            rankBadge
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(topic.topic)
                        .font(.body.weight(.semibold))
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text(weaknessPercent)
                        .font(.body.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(weaknessColor)
                }
                ProgressView(value: min(1, max(0, topic.weakness)))
                    .tint(weaknessColor)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    private var rankBadge: some View {
        Text("\(rank)")
            .font(.caption.weight(.bold))
            .monospacedDigit()
            .foregroundStyle(isWeakest ? Color.white : .secondary)
            .frame(width: 26, height: 26)
            .background(isWeakest ? DS.again : Color(.tertiarySystemFill), in: Circle())
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
