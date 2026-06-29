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
    @State private var goSettings = false
    @State private var showAddNote = false

    var body: some View {
        NavigationStack {
            ZStack {
                DS.background.ignoresSafeArea()
                content
            }
            .sheet(isPresented: $showAddNote) {
                NoteEditorView(store: store, mode: .add(defaultDeckID: store.currentDeckID)) {
                    store.refreshDecks()
                }
            }
            .navigationTitle("Decks")
            .navigationDestination(isPresented: $goReview) {
                ReviewerView(store: store)
            }
            .navigationDestination(isPresented: $goSettings) {
                SettingsView(store: store)
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    NavigationLink {
                        SettingsView(store: store)
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Settings")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showAddNote = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Add note")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    SyncToolbarButton(store: store)
                }
            }
            .overlay(alignment: .bottom) {
                SyncBanner(store: store)
            }
        }
        .sheet(isPresented: $store.showLogin) {
            LoginView(store: store)
        }
        .confirmationDialog(
            "Select collection to keep",
            isPresented: $store.pendingConflict,
            titleVisibility: .visible
        ) {
            // Clone of AnkiDroid's DIALOG_SYNC_CONFLICT_RESOLUTION: the two
            // collections diverged and can't be merged, so the user keeps one.
            Button("Upload to server", role: .destructive) {
                Task { await store.resolveConflict(upload: true) }
            }
            Button("Download from server", role: .destructive) {
                Task { await store.resolveConflict(upload: false) }
            }
            Button("Cancel", role: .cancel) { store.cancelConflict() }
        } message: {
            Text("The collections can’t be combined.\nWhich collection do you want to keep?")
        }
        .task {
            store.boot()
            #if DEBUG
            // Launch-argument automation hooks for UI tests / screenshots.
            // Compiled only into debug builds; release ships none of this.
            if ProcessInfo.processInfo.arguments.contains("-startInReview") {
                goReview = true
            }
            if ProcessInfo.processInfo.arguments.contains("-startInSettings") {
                goSettings = true
            }
            if ProcessInfo.processInfo.arguments.contains("-startInAddNote") {
                showAddNote = true
            }
            if UserDefaults.standard.bool(forKey: "showLogin") {
                store.showLogin = true
            }
            store.autoLoginAndSyncIfRequested()
            #endif
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

/// The Home sync control, cloning AnkiDroid's DeckPicker sync action.
///
/// When logged in a tap runs a collection + media sync; while syncing it shows a
/// spinner and is disabled. When logged out it opens the login sheet. A context
/// menu (long-press) shows the account and a log-out action.
private struct SyncToolbarButton: View {
    @ObservedObject var store: AnkiStore

    var body: some View {
        Button {
            if store.isLoggedIn {
                Task { await store.sync() }
            } else {
                store.showLogin = true
            }
        } label: {
            if store.syncPhase.isActive {
                ProgressView()
            } else {
                Image(systemName: store.isLoggedIn
                    ? "arrow.triangle.2.circlepath"
                    : "person.crop.circle.badge.plus")
            }
        }
        .disabled(store.syncPhase.isActive)
        .accessibilityLabel(store.isLoggedIn ? "Sync now" : "Log in to sync")
        .contextMenu {
            if store.isLoggedIn {
                Section("Signed in as \(store.syncUsername)") {
                    Button(role: .destructive) {
                        store.logout()
                    } label: {
                        Label("Log out", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                }
            }
        }
    }
}

/// A floating bottom banner reflecting `AnkiStore.syncPhase`: an indeterminate
/// spinner while the collection syncs, live counts during media sync, and a
/// tappable success/error result. Success auto-dismisses; an auth failure offers
/// a shortcut back to login.
private struct SyncBanner: View {
    @ObservedObject var store: AnkiStore

    var body: some View {
        content
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, DS.Spacing.l)
            .padding(.bottom, DS.Spacing.m)
            .animation(.easeInOut(duration: 0.2), value: store.syncPhase)
    }

    @ViewBuilder
    private var content: some View {
        switch store.syncPhase {
        case .idle:
            EmptyView()
        case .syncing(let text):
            progressCard(title: text.isEmpty ? "Syncing…" : text, detail: nil)
        case .mediaSyncing(let text):
            progressCard(title: "Syncing media…", detail: text.isEmpty ? nil : text)
        case .success(let message):
            resultCard(icon: "checkmark.circle.fill", tint: DS.easy, message: message)
                .onTapGesture { store.dismissSyncResult() }
                .task(id: message) {
                    try? await Task.sleep(nanoseconds: 2_500_000_000)
                    store.dismissSyncResult()
                }
        case .failed(let failure):
            resultCard(icon: "exclamationmark.triangle.fill", tint: DS.again, message: failure.message)
                .onTapGesture { store.dismissSyncResult() }
                .overlay(alignment: .trailing) {
                    if failure.kind == .auth {
                        Button("Log in") { store.showLogin = true }
                            .font(DS.Typography.caption.weight(.semibold))
                            .foregroundStyle(DS.accent)
                            .padding(.trailing, DS.Spacing.m)
                    }
                }
        }
    }

    private func progressCard(title: String, detail: String?) -> some View {
        HStack(spacing: DS.Spacing.m) {
            ProgressView()
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(DS.Typography.body)
                    .foregroundStyle(DS.textPrimary)
                if let detail {
                    Text(detail)
                        .font(DS.Typography.caption)
                        .foregroundStyle(DS.textSecondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .dsCard(padding: DS.Spacing.m)
    }

    private func resultCard(icon: String, tint: Color, message: String) -> some View {
        HStack(spacing: DS.Spacing.m) {
            Image(systemName: icon)
                .foregroundStyle(tint)
            Text(message)
                .font(DS.Typography.body)
                .foregroundStyle(DS.textPrimary)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .dsCard(padding: DS.Spacing.m)
        .accessibilityElement(children: .combine)
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
