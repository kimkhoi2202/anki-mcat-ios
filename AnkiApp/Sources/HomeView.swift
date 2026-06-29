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
    @State private var goBrowse = false
    @State private var goStats = false
    @State private var goImportExport = false
    @State private var showAddNote = false

    // Deck management (T2.3), cloning AnkiDroid's DeckPicker create-deck dialog
    // and per-deck context menu (rename / options / delete).
    @State private var showCreateDeck = false
    @State private var deckNameInput = ""
    @State private var renameTarget: DeckTreeEntry?
    @State private var pendingDelete: DeckTreeEntry?
    @State private var optionsTarget: DeckTreeEntry?
    @State private var deckActionError: String?

    // Filtered decks (T3.3): create from Home, plus rebuild/empty per filtered
    // deck — Anki's custom-study essentials.
    @State private var showCreateFilteredDeck = false
    @State private var deckActionResult: String?
    // Card Info / Change Note Type (T3.3) screenshot/automation hooks.
    @State private var cardInfoTarget: CardInfoTarget?
    @State private var changeNotetypeNoteID: HomeNoteTarget?

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
            .navigationDestination(isPresented: $goBrowse) {
                CardBrowserView(store: store)
            }
            .navigationDestination(isPresented: $goStats) {
                StatsView(store: store)
            }
            .navigationDestination(isPresented: $goImportExport) {
                ImportExportView(store: store)
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
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        goStats = true
                    } label: {
                        Image(systemName: "chart.bar.xaxis")
                    }
                    .accessibilityLabel("Statistics")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        goBrowse = true
                    } label: {
                        Image(systemName: "magnifyingglass")
                    }
                    .accessibilityLabel("Browse cards")
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
            .sheet(item: $optionsTarget) { deck in
                DeckOptionsView(store: store, deck: deck) {
                    store.refreshDecks()
                }
            }
            // Create filtered deck — clone of AnkiDroid's custom-study / filtered
            // deck builder.
            .sheet(isPresented: $showCreateFilteredDeck) {
                FilteredDeckView(store: store) { _ in
                    store.refreshDecks()
                }
            }
            .sheet(item: $cardInfoTarget) { target in
                CardInfoView(store: store, cardID: target.id)
            }
            .sheet(item: $changeNotetypeNoteID) { target in
                ChangeNotetypeView(store: store, noteID: target.id) {
                    store.refreshDecks()
                }
            }
            // Create deck — clone of AnkiDroid's CreateDeckDialog text prompt.
            .alert("New Deck", isPresented: $showCreateDeck) {
                TextField("Deck name", text: $deckNameInput)
                    .autocorrectionDisabled()
                Button("Create") { createDeck() }
                Button("Cancel", role: .cancel) { deckNameInput = "" }
            } message: {
                Text("Use “::” to make a subdeck, e.g. MCAT::Biology.")
            }
            // Rename deck — same dialog AnkiDroid reuses for renames.
            .alert("Rename Deck", isPresented: renamePresented) {
                TextField("Deck name", text: $deckNameInput)
                    .autocorrectionDisabled()
                Button("Rename") { performRename() }
                Button("Cancel", role: .cancel) { renameTarget = nil; deckNameInput = "" }
            } message: {
                Text("Enter a new name for this deck.")
            }
            // Delete deck — confirmation clone of DeckPickerConfirmDeleteDeckDialog.
            .confirmationDialog(
                "Delete deck?",
                isPresented: deletePresented,
                titleVisibility: .visible,
                presenting: pendingDelete
            ) { deck in
                Button("Delete", role: .destructive) { performDelete(deck) }
                Button("Cancel", role: .cancel) { pendingDelete = nil }
            } message: { deck in
                Text("This permanently deletes “\(deck.fullName)” and all of its cards. You can undo it from the reviewer.")
            }
            .alert("Action failed", isPresented: deckErrorPresented) {
                Button("OK", role: .cancel) { deckActionError = nil }
            } message: {
                Text(deckActionError ?? "")
            }
            .alert("Filtered deck", isPresented: deckResultPresented) {
                Button("OK", role: .cancel) { deckActionResult = nil }
            } message: {
                Text(deckActionResult ?? "")
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
            if ProcessInfo.processInfo.arguments.contains("-startInImportExport") {
                goImportExport = true
            }
            if ProcessInfo.processInfo.arguments.contains("-startInAddNote") {
                showAddNote = true
            }
            if ProcessInfo.processInfo.arguments.contains("-startInBrowser") {
                goBrowse = true
            }
            // Answer a few cards first so the stats screen has real review
            // history to show (used for the T3.1 screenshot).
            store.studySomeIfRequested()
            if ProcessInfo.processInfo.arguments.contains("-startInStats") {
                goStats = true
            }
            if ProcessInfo.processInfo.arguments.contains("-startInCreateDeck") {
                showCreateDeck = true
            }
            if ProcessInfo.processInfo.arguments.contains("-startInDeckOptions") {
                optionsTarget = store.decks.first
            }
            if ProcessInfo.processInfo.arguments.contains("-startInCreateFilteredDeck") {
                showCreateFilteredDeck = true
            }
            // Open Card Info for the first card (used for the T3.3 screenshot).
            if ProcessInfo.processInfo.arguments.contains("-startInCardInfo") {
                if let cardID = await store.firstCardID() {
                    cardInfoTarget = CardInfoTarget(id: cardID)
                }
            }
            // Open Change Note Type for the first note (T3.3 verification hook).
            if ProcessInfo.processInfo.arguments.contains("-startInChangeNotetype") {
                if let noteID = await store.firstNoteID() {
                    changeNotetypeNoteID = HomeNoteTarget(id: noteID)
                }
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
        .onChange(of: goBrowse) { presented in
            // Returning from the browser: suspend/delete may have changed counts.
            if !presented { store.refreshDecks() }
        }
    }

    @ViewBuilder
    private var content: some View {
        if store.decks.isEmpty {
            emptyState
        } else {
            ScrollView {
                VStack(spacing: DS.Spacing.l) {
                    deckList
                    newDeckButton
                    newFilteredDeckButton
                }
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
                // Long-press deck actions, cloning AnkiDroid's DeckPickerContextMenu.
                .contextMenu { deckRowMenu(deck) }
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

    /// Per-deck long-press menu: rename, options (limits), and delete — the
    /// subset of AnkiDroid's deck context menu in T2.3's scope. "Options" is
    /// hidden for filtered decks (they have no new/review-per-day limits) and
    /// "Delete" for the Default deck (which Anki always keeps).
    @ViewBuilder
    private func deckRowMenu(_ deck: DeckTreeEntry) -> some View {
        Button {
            beginRename(deck)
        } label: {
            Label("Rename", systemImage: "pencil")
        }

        if deck.filtered {
            // Filtered decks get Anki's custom-study rebuild/empty instead of the
            // per-day limit options (which only apply to normal decks).
            Button {
                rebuildFiltered(deck)
            } label: {
                Label("Rebuild", systemImage: "arrow.clockwise")
            }
            Button {
                emptyFiltered(deck)
            } label: {
                Label("Empty", systemImage: "tray")
            }
        } else {
            Button {
                optionsTarget = deck
            } label: {
                Label("Options", systemImage: "slider.horizontal.3")
            }
        }

        if deck.id != Self.defaultDeckID {
            Divider()
            Button(role: .destructive) {
                pendingDelete = deck
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    /// Full-width "New Deck" action below the list, keeping deck creation out of
    /// the already-busy toolbar (add-note / browse / sync).
    private var newDeckButton: some View {
        Button {
            beginCreateDeck()
        } label: {
            Label("New Deck", systemImage: "folder.badge.plus")
                .font(DS.Typography.body.weight(.semibold))
                .foregroundStyle(DS.accent)
                .frame(maxWidth: .infinity)
                .frame(minHeight: DS.minTapTarget)
                .background(
                    DS.surface,
                    in: RoundedRectangle(cornerRadius: DS.Radius.large, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: DS.Radius.large, style: .continuous)
                        .strokeBorder(DS.separator, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("New deck")
    }

    /// Full-width "New Filtered Deck" action (Anki's custom study), kept beside
    /// "New Deck" and out of the busy toolbar.
    private var newFilteredDeckButton: some View {
        Button {
            showCreateFilteredDeck = true
        } label: {
            Label("New Filtered Deck", systemImage: "line.3.horizontal.decrease.circle")
                .font(DS.Typography.body.weight(.semibold))
                .foregroundStyle(DS.good)
                .frame(maxWidth: .infinity)
                .frame(minHeight: DS.minTapTarget)
                .background(
                    DS.surface,
                    in: RoundedRectangle(cornerRadius: DS.Radius.large, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: DS.Radius.large, style: .continuous)
                        .strokeBorder(DS.separator, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("New filtered deck")
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
            Button {
                beginCreateDeck()
            } label: {
                Label("New Deck", systemImage: "folder.badge.plus")
            }
            .buttonStyle(.borderedProminent)
            .tint(DS.accent)
            .padding(.top, DS.Spacing.s)
        }
        .multilineTextAlignment(.center)
        .padding(DS.Spacing.xl)
    }

    // MARK: - Deck management actions

    /// The Default deck always has id 1 and can't be deleted (Anki recreates it).
    private static let defaultDeckID: Int64 = 1

    private var renamePresented: Binding<Bool> {
        Binding(get: { renameTarget != nil }, set: { if !$0 { renameTarget = nil } })
    }

    private var deletePresented: Binding<Bool> {
        Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })
    }

    private var deckErrorPresented: Binding<Bool> {
        Binding(get: { deckActionError != nil }, set: { if !$0 { deckActionError = nil } })
    }

    private var deckResultPresented: Binding<Bool> {
        Binding(get: { deckActionResult != nil }, set: { if !$0 { deckActionResult = nil } })
    }

    private func beginCreateDeck() {
        deckNameInput = ""
        showCreateDeck = true
    }

    private func beginRename(_ deck: DeckTreeEntry) {
        deckNameInput = deck.fullName
        renameTarget = deck
    }

    private func createDeck() {
        let name = deckNameInput.trimmingCharacters(in: .whitespacesAndNewlines)
        deckNameInput = ""
        guard !name.isEmpty else { return }
        runDeckAction { try store.createDeck(name: name) }
    }

    private func performRename() {
        guard let deck = renameTarget else { return }
        let name = deckNameInput.trimmingCharacters(in: .whitespacesAndNewlines)
        renameTarget = nil
        deckNameInput = ""
        guard !name.isEmpty, name != deck.fullName else { return }
        runDeckAction { try store.renameDeck(id: deck.id, name: name) }
    }

    private func performDelete(_ deck: DeckTreeEntry) {
        pendingDelete = nil
        runDeckAction { try store.deleteDeck(id: deck.id) }
    }

    /// Re-gathers a filtered deck's cards, reporting the count (Anki's "Rebuild").
    private func rebuildFiltered(_ deck: DeckTreeEntry) {
        do {
            let count = try store.rebuildFilteredDeck(deckID: deck.id)
            deckActionResult = "“\(deck.name)” now holds ^[\(count) card](inflect: true)."
        } catch {
            deckActionError = describe(error)
        }
    }

    /// Returns a filtered deck's cards to their home decks (Anki's "Empty").
    private func emptyFiltered(_ deck: DeckTreeEntry) {
        do {
            try store.emptyFilteredDeck(deckID: deck.id)
            deckActionResult = "“\(deck.name)” was emptied; its cards returned to their decks."
        } catch {
            deckActionError = describe(error)
        }
    }

    /// Runs a deck mutation, surfacing a readable message on failure (the store
    /// already refreshes the deck list on success).
    private func runDeckAction(_ work: () throws -> Void) {
        do {
            try work()
        } catch {
            deckActionError = describe(error)
        }
    }

    /// Extracts a human-readable message from a thrown error, decoding the
    /// engine's protobuf `BackendError` when present (e.g. an invalid deck name).
    private func describe(_ error: Error) -> String {
        if case let AnkiError.backendError(data) = error,
           let backendError = try? Anki_Backend_BackendError(serializedBytes: data),
           !backendError.message.isEmpty {
            return backendError.message
        }
        return error.localizedDescription
    }
}

/// Identifiable wrapper so the Change Note Type sheet can be driven by
/// `.sheet(item:)` from an optional note id (used by the verification hook).
private struct HomeNoteTarget: Identifiable {
    let id: Int64
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
