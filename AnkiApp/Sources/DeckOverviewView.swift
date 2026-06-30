import SwiftUI
import AnkiKit

/// Deck overview / study-options screen, cloning AnkiDroid's deck overview
/// (`StudyOptionsFragment` / the deck's "Study Options").
///
/// Tapping a deck on Home opens this brief screen — the deck name, its
/// new / learning / review counts, and a prominent **Study** button — rather
/// than dumping the user straight into the reviewer (which, for a deck with 0
/// cards due, would land on a bare "all caught up" screen). When there's
/// nothing due it shows the congrats state and offers Custom study instead.
/// Quick links mirror the deck's context actions (Browse, plus Custom study /
/// Deck options for normal decks).
///
/// The deck is looked up live from `store.decks` by id so its counts stay
/// current as the deck list refreshes (e.g. after returning from review).
struct DeckOverviewView: View {
    @ObservedObject var store: AnkiStore
    let deckID: Int64

    @Environment(\.dismiss) private var dismiss

    @State private var goReview = false
    @State private var goBrowse = false
    @State private var showOptions = false
    @State private var showCustomStudy = false
    /// Set when a Custom Study session deck was built, so the sheet's dismissal
    /// pushes the reviewer for it (selected by the store on build).
    @State private var customStudyStartedSession = false

    /// The deck being shown, resolved live from the published deck list so its
    /// counts update as the tree refreshes; nil if it was deleted out from under
    /// the screen.
    private var deck: DeckTreeEntry? {
        store.decks.first { $0.id == deckID }
    }

    var body: some View {
        ZStack {
            DS.background.ignoresSafeArea()
            if let deck {
                content(for: deck)
                    .disabled(store.isBackendBusy)
            } else {
                missingState
            }
        }
        .navigationTitle(deck?.name ?? "Deck")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: $goReview) {
            ReviewerView(store: store)
        }
        .navigationDestination(isPresented: $goBrowse) {
            CardBrowserView(store: store, initialQuery: deckSearchQuery)
        }
        .sheet(isPresented: $showOptions) {
            if let deck {
                DeckOptionsView(store: store, deck: deck) { store.refreshDecks() }
            }
        }
        // Custom study opens Anki's preset dialog for this deck. Building a
        // session deck selects it in the store; we then push the reviewer once
        // the sheet has dismissed (avoids a sheet-dismiss/navigation race).
        .sheet(isPresented: $showCustomStudy, onDismiss: {
            if customStudyStartedSession {
                customStudyStartedSession = false
                goReview = true
            }
        }) {
            CustomStudyView(store: store, deckID: deckID) {
                customStudyStartedSession = true
            }
        }
        // Returning from the reviewer: refresh counts so the overview reflects
        // what was studied.
        .onChange(of: goReview) { presented in
            if !presented { store.refreshDecks() }
        }
        .onChange(of: goBrowse) { presented in
            if !presented { store.refreshDecks() }
        }
        .task {
            #if DEBUG
            // Screenshot hook: open straight into the reviewer from the overview.
            if ProcessInfo.processInfo.arguments.contains("-demoDeckOverviewStudy"),
               let deck, deck.hasCardsReadyToStudy {
                study(deck)
            }
            #endif
        }
    }

    // MARK: - Content

    private func content(for deck: DeckTreeEntry) -> some View {
        ScrollView {
            VStack(spacing: DS.Spacing.l) {
                countsCard(for: deck)
                studySection(for: deck)
                quickLinks(for: deck)
            }
            .padding(DS.Spacing.l)
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
        }
    }

    /// The three colored counts (new / learning / review), mirroring the deck
    /// list's columns but enlarged for the overview.
    private func countsCard(for deck: DeckTreeEntry) -> some View {
        HStack(spacing: 0) {
            countTile(label: "New", count: deck.newCount, color: DS.accent)
            divider
            countTile(label: "Learn", count: deck.learnCount, color: DS.again)
            divider
            countTile(label: "Due", count: deck.reviewCount, color: DS.easy)
        }
        .dsCard(padding: DS.Spacing.l)
    }

    private func countTile(label: String, count: Int, color: Color) -> some View {
        VStack(spacing: DS.Spacing.xs) {
            Text("\(count)")
                .font(.system(.title, design: .rounded).weight(.bold))
                .monospacedDigit()
                .foregroundStyle(count == 0 ? DS.textSecondary : color)
            Text(label)
                .font(DS.Typography.caption)
                .foregroundStyle(DS.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(count) \(label)")
    }

    private var divider: some View {
        Rectangle()
            .fill(DS.separator)
            .frame(width: 1, height: 36)
    }

    @ViewBuilder
    private func studySection(for deck: DeckTreeEntry) -> some View {
        if deck.hasCardsReadyToStudy {
            Button {
                study(deck)
            } label: {
                Text("Study Now")
            }
            .buttonStyle(.dsPrimary)
            .accessibilityIdentifier("studyDeck")
        } else {
            // Anki's congrats state: nothing due, so don't enter a bare reviewer.
            VStack(spacing: DS.Spacing.s) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 36))
                    .foregroundStyle(DS.easy)
                Text("Congratulations! You have finished this deck for now.")
                    .font(DS.Typography.body)
                    .foregroundStyle(DS.textPrimary)
                    .multilineTextAlignment(.center)
                if !deck.filtered {
                    Text("Use Custom study to review ahead or study more.")
                        .font(DS.Typography.caption)
                        .foregroundStyle(DS.textSecondary)
                        .multilineTextAlignment(.center)
                }
            }
            .frame(maxWidth: .infinity)
            .dsCard(padding: DS.Spacing.l)
            .accessibilityIdentifier("deckCaughtUp")
        }
    }

    /// Secondary deck actions, gated like the deck context menu: Browse is always
    /// available; Custom study and Deck options apply to normal decks only
    /// (filtered decks have no per-day limits, and Custom study itself builds a
    /// filtered deck).
    @ViewBuilder
    private func quickLinks(for deck: DeckTreeEntry) -> some View {
        VStack(spacing: 0) {
            linkRow(title: "Browse", systemImage: "magnifyingglass") {
                goBrowse = true
            }
            if !deck.filtered {
                rowDivider
                linkRow(title: "Custom study", systemImage: "slider.horizontal.3") {
                    showCustomStudy = true
                }
                rowDivider
                linkRow(title: "Deck options", systemImage: "gearshape") {
                    showOptions = true
                }
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

    private func linkRow(title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: DS.Spacing.m) {
                Image(systemName: systemImage)
                    .foregroundStyle(DS.accent)
                    .frame(width: 24)
                Text(title)
                    .font(DS.Typography.body)
                    .foregroundStyle(DS.textPrimary)
                Spacer(minLength: 0)
                Image(systemName: "chevron.forward")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(DS.textSecondary)
            }
            .padding(.horizontal, DS.Spacing.l)
            .frame(minHeight: DS.minTapTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var rowDivider: some View {
        Divider()
            .overlay(DS.separator)
            .padding(.leading, DS.Spacing.l)
    }

    private var missingState: some View {
        VStack(spacing: DS.Spacing.m) {
            Image(systemName: "tray")
                .font(.system(size: 40))
                .foregroundStyle(DS.textSecondary)
            Text("This deck is no longer available.")
                .font(DS.Typography.body)
                .foregroundStyle(DS.textSecondary)
            Button("Back") { dismiss() }
                .buttonStyle(.dsSecondary)
        }
        .padding(DS.Spacing.xl)
    }

    // MARK: - Actions

    /// Anki search that scopes the browser to this deck and its subdecks. The
    /// full `::` name is quoted so decks with spaces match.
    private var deckSearchQuery: String {
        guard let deck else { return "" }
        return "deck:\"\(deck.fullName)\""
    }

    /// Enters the reviewer, but only once the deck is actually selected — guard
    /// navigation on `selectDeck` so a failed selection can't push an empty
    /// reviewer.
    private func study(_ deck: DeckTreeEntry) {
        guard deck.hasCardsReadyToStudy else { return }
        guard store.selectDeck(id: deck.id) else { return }
        goReview = true
    }
}
