import SwiftUI
import AnkiKit

/// Home screen: the deck list, cloning AnkiDroid's DeckPicker.
///
/// One row per deck (`DeckRow`) showing the deck name and its new / learning /
/// review counts. Tapping a row selects that deck as current (scoping study to
/// it and its subdecks) and pushes the reviewer.
struct HomeView: View {
    @StateObject private var store = AnkiStore()
    @State private var goReview = false

    var body: some View {
        NavigationStack {
            ZStack {
                DS.background.ignoresSafeArea()
                content
            }
            .navigationTitle("Decks")
            .navigationDestination(isPresented: $goReview) {
                ReviewerView(store: store)
            }
        }
        .task {
            store.boot()
            if ProcessInfo.processInfo.arguments.contains("-startInReview") {
                goReview = true
            }
        }
        .onChange(of: goReview) { presented in
            // Returning from the reviewer: refresh per-deck counts.
            if !presented { store.refreshDecks() }
        }
    }

    @ViewBuilder
    private var content: some View {
        if store.decks.isEmpty {
            emptyState
        } else {
            ScrollView {
                deckList
                    .padding(DS.Spacing.l)
            }
        }
    }

    private var deckList: some View {
        VStack(spacing: 0) {
            ForEach(Array(store.decks.enumerated()), id: \.element.id) { index, deck in
                if index > 0 {
                    Divider()
                        .overlay(DS.separator)
                        .padding(.leading, DS.Spacing.l)
                }
                Button {
                    store.selectDeck(id: deck.id)
                    goReview = true
                } label: {
                    DeckRow(deck: deck)
                }
                .buttonStyle(.plain)
            }
        }
        .background(
            DS.surface,
            in: RoundedRectangle(cornerRadius: DS.Radius.large, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.large, style: .continuous)
                .strokeBorder(DS.separator, lineWidth: 1)
        )
    }

    private var emptyState: some View {
        VStack(spacing: DS.Spacing.m) {
            Image(systemName: "tray")
                .font(.system(size: 44))
                .foregroundStyle(DS.textSecondary)
            Text("No decks yet")
                .font(DS.Typography.headline)
                .foregroundStyle(DS.textPrimary)
            Text(store.status)
                .font(DS.Typography.caption)
                .foregroundStyle(DS.textSecondary)
        }
        .multilineTextAlignment(.center)
        .padding(DS.Spacing.xl)
    }
}

/// A single deck row: indented leaf name on the left, three colored counts on
/// the right. Count colors mirror AnkiDroid's deck picker (new = indigo/accent,
/// learning = red, review = green); zero counts are muted.
private struct DeckRow: View {
    let deck: DeckTreeEntry

    var body: some View {
        HStack(spacing: DS.Spacing.m) {
            Text(deck.name)
                .font(DS.Typography.body)
                .foregroundStyle(deck.filtered ? DS.good : DS.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.leading, CGFloat(deck.depth) * DS.Spacing.l)

            Spacer(minLength: DS.Spacing.s)

            HStack(spacing: DS.Spacing.s) {
                CountLabel(count: deck.newCount, color: DS.accent)
                CountLabel(count: deck.learnCount, color: DS.again)
                CountLabel(count: deck.reviewCount, color: DS.easy)
            }

            Image(systemName: "chevron.forward")
                .font(.caption.weight(.semibold))
                .foregroundStyle(DS.textSecondary)
        }
        .padding(.horizontal, DS.Spacing.l)
        .frame(minHeight: DS.minTapTarget)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(deck.fullName), \(deck.newCount) new, \(deck.learnCount) learning, \(deck.reviewCount) to review"
        )
    }
}

/// A single deck count: a monospaced-digit number, colored when non-zero and
/// muted at zero, in a fixed-width slot so columns stay aligned across rows.
private struct CountLabel: View {
    let count: Int
    let color: Color

    var body: some View {
        Text("\(count)")
            .font(DS.Typography.body)
            .monospacedDigit()
            .foregroundStyle(count == 0 ? DS.textSecondary : color)
            .frame(minWidth: 26, alignment: .trailing)
    }
}
