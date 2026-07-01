import SwiftUI
import UIKit
import AnkiKit

/// Home screen: the deck list, cloning AnkiDroid's DeckPicker.
///
/// One row per deck (`DeckRow`) showing the deck name and its new / learning /
/// review counts. Tapping a row selects that deck as current (scoping study to
/// it and its subdecks) and pushes the reviewer.
struct HomeView: View {
    @StateObject private var store = AnkiStore()
    /// Drives auto-sync on app open/close (Anki's "Automatically sync on profile
    /// open/close"); `hasLaunched` keeps the launch `.active` from double-syncing
    /// with the boot-time open sync.
    @Environment(\.scenePhase) private var scenePhase
    @State private var hasLaunched = false
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

    // Custom study (full-parity): Anki's preset dialog, opened per deck from the
    // deck context menu. `customStudyTarget` drives the sheet; building a session
    // deck selects it in the store and `customStudyStartedSession` then pushes
    // the reviewer once the sheet dismisses.
    @State private var customStudyTarget: CustomStudyTarget?
    @State private var customStudyStartedSession = false

    // Deck-list parity (full-parity): subdeck collapse, the deck overview shown
    // on tap, and the expanded per-deck context menu (browse / add note /
    // create subdeck / export / unbury), cloning AnkiDroid's DeckPicker.
    /// Drives pushing the deck overview; `overviewDeckID` is the tapped deck.
    @State private var overviewDeckID: Int64?
    @State private var goOverview = false
    /// "Browse" for a specific deck: pre-filtered card browser.
    @State private var browseDeckQuery = ""
    @State private var goDeckBrowse = false
    /// "Add note" targeting a specific deck (its id), driving the editor sheet.
    @State private var addNoteTarget: AddNoteTarget?
    /// "Create subdeck": the parent deck being added under, plus the typed name.
    @State private var createSubdeckParent: DeckTreeEntry?
    @State private var subdeckNameInput = ""
    /// A produced per-deck `.apkg` export awaiting the share sheet.
    @State private var deckExportShare: ExportShareItem?
    // Card Info / Change Note Type (T3.3) screenshot/automation hooks.
    @State private var cardInfoTarget: CardInfoTarget?
    @State private var changeNotetypeNoteID: HomeNoteTarget?

    // Note-type management (full-parity) screenshot/automation hooks: jump
    // straight to the manager list, a note type's Fields editor, or its Card
    // Template editor.
    @State private var goManageNotetypes = false
    @State private var fieldsEditorTarget: NotetypeScreenTarget?
    @State private var goFieldsEditor = false
    @State private var templateEditorTarget: NotetypeScreenTarget?

    var body: some View {
        NavigationStack {
            ZStack {
                DS.background.ignoresSafeArea()
                // Disable backend-touching controls (deck taps → study, deck
                // create/rename/delete) while an exclusive backend op runs, so a
                // tap can't hit a closed collection mid import/export/full-sync.
                content
                    .disabled(store.isBackendBusy)
            }
            .overlay(alignment: .top) {
                if store.isBackendBusy { busyIndicator }
            }
            .animation(.easeInOut(duration: 0.2), value: store.isBackendBusy)
            .sheet(isPresented: $showAddNote) {
                NoteEditorView(store: store, mode: .add(defaultDeckID: store.currentDeckID)) {
                    store.refreshDecks()
                }
            }
            // "Add note" from a deck's context menu, defaulting to that deck.
            .sheet(item: $addNoteTarget) { target in
                NoteEditorView(store: store, mode: .add(defaultDeckID: target.deckID)) {
                    store.refreshDecks()
                }
            }
            // The produced per-deck export handed to the system share sheet.
            .sheet(item: $deckExportShare) { item in
                ShareSheet(items: [item.url])
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
            .navigationDestination(isPresented: $goManageNotetypes) {
                ManageNotetypesView(store: store)
            }
            .navigationDestination(isPresented: $goFieldsEditor) {
                if let target = fieldsEditorTarget {
                    NotetypeFieldsEditorView(store: store, notetypeID: target.id, notetypeName: target.name)
                }
            }
            .sheet(item: $templateEditorTarget) { target in
                CardTemplateEditorView(store: store, notetypeID: target.id, notetypeName: target.name)
            }
            // Tapping a deck opens its overview (counts + Study + quick links)
            // rather than jumping straight into the reviewer.
            .navigationDestination(isPresented: $goOverview) {
                if let id = overviewDeckID {
                    DeckOverviewView(store: store, deckID: id)
                }
            }
            // "Browse" from a deck's context menu: the card browser pre-filtered
            // to that deck.
            .navigationDestination(isPresented: $goDeckBrowse) {
                CardBrowserView(store: store, initialQuery: browseDeckQuery)
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
                    .disabled(store.isBackendBusy)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        goBrowse = true
                    } label: {
                        Image(systemName: "magnifyingglass")
                    }
                    .accessibilityLabel("Browse cards")
                    .disabled(store.isBackendBusy)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showAddNote = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Add note")
                    .disabled(store.isBackendBusy)
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
            // Create filtered deck — clone of AnkiDroid's filtered-deck builder.
            .sheet(isPresented: $showCreateFilteredDeck) {
                FilteredDeckView(store: store) { _ in
                    store.refreshDecks()
                }
            }
            // Custom study — Anki's preset dialog for a specific deck. Building a
            // session deck selects it in the store; we push the reviewer once the
            // sheet has dismissed (avoids a sheet-dismiss/navigation race).
            .sheet(item: $customStudyTarget, onDismiss: {
                if customStudyStartedSession {
                    customStudyStartedSession = false
                    goReview = true
                }
            }) { target in
                CustomStudyView(store: store, deckID: target.deckID) {
                    customStudyStartedSession = true
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
                Text("Use “::” to make a subdeck, e.g. Spanish::Verbs.")
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
            // Create subdeck — prompts for a child name added under the deck,
            // cloning AnkiDroid's "Create subdeck" deck action.
            .alert("New Subdeck", isPresented: createSubdeckPresented) {
                TextField("Subdeck name", text: $subdeckNameInput)
                    .autocorrectionDisabled()
                Button("Create") { performCreateSubdeck() }
                Button("Cancel", role: .cancel) { createSubdeckParent = nil; subdeckNameInput = "" }
            } message: {
                Text(createSubdeckMessage)
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
            // Shared result banner for deck actions that report an outcome
            // (filtered rebuild/empty, unbury).
            .alert("Deck", isPresented: deckResultPresented) {
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
            await store.boot()
            // Auto-sync on app open (Anki's "Automatically sync on open/close"),
            // a no-op unless enabled and logged in. `hasLaunched` then lets the
            // scene-phase handler treat later foregrounds as re-opens.
            store.autoSyncIfEnabled()
            hasLaunched = true
            #if DEBUG
            // Launch-argument automation hooks for UI tests / screenshots.
            // Compiled only into debug builds; release ships none of this.
            // Seed a nested subdeck tree (expanded or collapsed) for the
            // collapse/expand screenshots before any deck-dependent hooks read
            // the deck list.
            store.prepareSubdeckDemoIfRequested()
            if ProcessInfo.processInfo.arguments.contains("-startInReview") {
                goReview = true
            }
            // Open the reviewer with the card-action menu showing (for the
            // reviewer-menu screenshot); ReviewerView reads the same argument.
            if ProcessInfo.processInfo.arguments.contains("-startInReviewMenu") {
                goReview = true
            }
            // Reviewer feature demos: enable the relevant preference (and, for
            // audio, seed a [sound:] card in its own deck) then open the reviewer.
            // ReviewerView reads -demoSetDueDate to open the set-due prompt.
            if ProcessInfo.processInfo.arguments.contains("-demoRemainingCounts")
                || ProcessInfo.processInfo.arguments.contains("-demoAudioButtons")
                || ProcessInfo.processInfo.arguments.contains("-demoSetDueDate") {
                store.prepareReviewerFeatureDemosIfRequested()
                goReview = true
            }
            if ProcessInfo.processInfo.arguments.contains("-startInSettings") {
                goSettings = true
            }
            if ProcessInfo.processInfo.arguments.contains("-startInImportExport") {
                goImportExport = true
            }
            // Open Import & Export and surface the destructive replace
            // confirmation (used for the import-replace screenshot).
            if ProcessInfo.processInfo.arguments.contains("-startInImportReplaceConfirm") {
                goImportExport = true
            }
            // Open Import & Export and present the CSV import wizard / text export
            // options (used for the CSV-mapping and text-export screenshots).
            // ImportExportView reads the same arguments to drive the sheets.
            if ProcessInfo.processInfo.arguments.contains("-startInCSVImport")
                || ProcessInfo.processInfo.arguments.contains("-startInTextExport") {
                goImportExport = true
            }
            if ProcessInfo.processInfo.arguments.contains("-startInAddNote") {
                showAddNote = true
            }
            // Open the browser; the `-demoBrowser…` variants additionally drive a
            // specific feature for its screenshot (multi-select, extra columns,
            // the column picker, or Find & Replace). CardBrowserView reads them.
            if ProcessInfo.processInfo.arguments.contains("-startInBrowser")
                || ProcessInfo.processInfo.arguments.contains("-demoBrowserSelect")
                || ProcessInfo.processInfo.arguments.contains("-demoBrowserColumnsApplied")
                || ProcessInfo.processInfo.arguments.contains("-demoBrowserColumns")
                || ProcessInfo.processInfo.arguments.contains("-demoBrowserFindReplace") {
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
            // Open the deck overview (study options) for the first deck.
            if ProcessInfo.processInfo.arguments.contains("-startInDeckOverview") {
                if let first = store.decks.first {
                    overviewDeckID = first.id
                    goOverview = true
                }
            }
            if ProcessInfo.processInfo.arguments.contains("-startInCreateFilteredDeck") {
                showCreateFilteredDeck = true
            }
            // Open Custom Study for the first deck (full-parity screenshot hook).
            if ProcessInfo.processInfo.arguments.contains("-startInCustomStudy") {
                if let first = store.decks.first {
                    customStudyTarget = CustomStudyTarget(deckID: first.id)
                }
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
            // Note-type management screenshots. `-startInManageNotetypes` opens
            // the manager (pair with `-startInAddNotetype` for the add dialog);
            // `-startInNotetypeFields` opens a Basic type's Fields editor; and
            // `-startInCardTemplate` opens a (reversed) type's Card Template editor
            // so the live preview and multi-card switcher show.
            if ProcessInfo.processInfo.arguments.contains("-startInManageNotetypes") {
                goManageNotetypes = true
            }
            if ProcessInfo.processInfo.arguments.contains("-startInNotetypeFields") {
                let all = store.availableNotetypes()
                if let target = all.first(where: { $0.name.hasPrefix("Basic") }) ?? all.first {
                    fieldsEditorTarget = NotetypeScreenTarget(id: target.id, name: target.name)
                    goFieldsEditor = true
                }
            }
            if ProcessInfo.processInfo.arguments.contains("-startInCardTemplate") {
                let all = store.availableNotetypes()
                let target = all.first(where: { $0.name == "Basic (and reversed card)" })
                    ?? all.first(where: { $0.name.hasPrefix("Basic") })
                    ?? all.first
                if let target {
                    templateEditorTarget = NotetypeScreenTarget(id: target.id, name: target.name)
                }
            }
            if UserDefaults.standard.bool(forKey: "showLogin") {
                store.showLogin = true
            }
            store.autoLoginAndSyncIfRequested()
            #endif
        }
        .onChange(of: scenePhase) { phase in
            // Auto-sync on app open/close. On close (`.background`) the sync is
            // best-effort — iOS may suspend the app before it finishes — so the
            // reliable counterpart is the re-open sync when foregrounding again.
            // The launch open-sync runs in `.task`, so skip the first `.active`.
            switch phase {
            case .active:
                if hasLaunched { store.autoSyncIfEnabled() }
            case .background:
                store.autoSyncIfEnabled()
            default:
                break
            }
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

    /// Lightweight "Working…" affordance shown while an exclusive backend
    /// operation (import / export / full-sync collection replace) runs, so the
    /// user has feedback that the (disabled) backend-touching controls are
    /// intentionally paused for the moment rather than broken.
    private var busyIndicator: some View {
        HStack(spacing: DS.Spacing.s) {
            ProgressView()
            Text("Working…")
                .font(DS.Typography.caption.weight(.semibold))
                .foregroundStyle(DS.textPrimary)
        }
        .padding(.horizontal, DS.Spacing.m)
        .padding(.vertical, DS.Spacing.s)
        .background(DS.surface, in: Capsule())
        .overlay(Capsule().strokeBorder(DS.separator, lineWidth: 1))
        .padding(.top, DS.Spacing.s)
        .transition(.opacity)
        .accessibilityLabel("Working")
    }

    private var deckList: some View {
        VStack(spacing: 0) {
            ForEach(Array(store.decks.enumerated()), id: \.element.id) { index, deck in
                if index > 0 {
                    Divider()
                        .overlay(DS.separator)
                        .padding(.leading, DS.Spacing.l)
                }
                // Tapping the row opens the deck overview; the leading chevron
                // (on decks with subdecks) toggles collapse without navigating.
                DeckRow(
                    deck: deck,
                    onSelect: { openDeckOverview(deck) },
                    onToggleCollapse: { store.toggleDeckCollapsed(deck) }
                )
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

    /// Per-deck long-press menu, cloning AnkiDroid's DeckPicker context menu:
    /// Browse, Add note, Rename, Create subdeck, Custom study / Options (normal)
    /// or Rebuild / Empty (filtered), Unbury, Export deck, and Delete. "Options"
    /// and "Custom study" only apply to normal decks (filtered decks have no
    /// per-day limits and are themselves the custom-study target); "Delete" is
    /// hidden for the Default deck (which Anki always keeps).
    @ViewBuilder
    private func deckRowMenu(_ deck: DeckTreeEntry) -> some View {
        // Open the deck's cards or jump to adding one.
        Button {
            browseDeck(deck)
        } label: {
            Label("Browse", systemImage: "magnifyingglass")
        }
        Button {
            addNoteTarget = AddNoteTarget(deckID: deck.id)
        } label: {
            Label("Add note", systemImage: "square.and.pencil")
        }

        Divider()

        Button {
            beginRename(deck)
        } label: {
            Label("Rename", systemImage: "pencil")
        }
        Button {
            beginCreateSubdeck(deck)
        } label: {
            Label("Create subdeck", systemImage: "folder.badge.plus")
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
            // Custom study opens Anki's preset dialog scoped to this deck.
            Button {
                customStudyTarget = CustomStudyTarget(deckID: deck.id)
            } label: {
                Label("Custom study", systemImage: "graduationcap")
            }
        }

        // Return this deck's buried cards to the study queue.
        Button {
            unburyDeck(deck)
        } label: {
            Label("Unbury", systemImage: "eye")
        }
        // Export this deck (and its subdecks) as a shareable .apkg.
        Button {
            exportDeck(deck)
        } label: {
            Label("Export deck", systemImage: "square.and.arrow.up")
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

    private var createSubdeckPresented: Binding<Bool> {
        Binding(get: { createSubdeckParent != nil }, set: { if !$0 { createSubdeckParent = nil } })
    }

    private var createSubdeckMessage: String {
        guard let parent = createSubdeckParent else { return "" }
        return "Create a subdeck under “\(parent.fullName)”."
    }

    private func beginCreateDeck() {
        deckNameInput = ""
        showCreateDeck = true
    }

    private func beginRename(_ deck: DeckTreeEntry) {
        deckNameInput = deck.fullName
        renameTarget = deck
    }

    /// Opens the deck overview (counts + Study + quick links) for a tapped deck.
    /// AnkiDroid shows this study-options screen instead of dropping the user
    /// straight into the reviewer (which, at 0 due, would be a bare "caught up").
    private func openDeckOverview(_ deck: DeckTreeEntry) {
        overviewDeckID = deck.id
        goOverview = true
    }

    /// Opens the card browser pre-filtered to a deck (and its subdecks). The full
    /// `::` name is quoted so decks with spaces still match.
    private func browseDeck(_ deck: DeckTreeEntry) {
        browseDeckQuery = "deck:\"\(deck.fullName)\""
        goDeckBrowse = true
    }

    private func beginCreateSubdeck(_ deck: DeckTreeEntry) {
        subdeckNameInput = ""
        createSubdeckParent = deck
    }

    private func performCreateSubdeck() {
        guard let parent = createSubdeckParent else { return }
        let name = subdeckNameInput.trimmingCharacters(in: .whitespacesAndNewlines)
        createSubdeckParent = nil
        subdeckNameInput = ""
        guard !name.isEmpty else { return }
        runDeckAction { try await store.createSubdeck(under: parent, name: name) }
    }

    /// Returns a deck's buried cards to the study queue, reporting the outcome.
    private func unburyDeck(_ deck: DeckTreeEntry) {
        runDeckAction {
            try await store.unburyDeck(id: deck.id)
            deckActionResult = "Returned any buried cards in “\(deck.name)” to study."
        }
    }

    /// Exports a deck (and its subdecks) as a `.apkg`, then hands it to the share
    /// sheet — reusing the same engine export the Import & Export screen uses.
    /// The export runs as an exclusive backend op (so the busy indicator shows
    /// and backend-touching controls disable for its duration).
    private func exportDeck(_ deck: DeckTreeEntry) {
        Task { @MainActor in
            do {
                let url = try await store.exportDeck(
                    id: deck.id, name: deck.fullName, includeMedia: true
                )
                deckExportShare = ExportShareItem(url: url)
            } catch {
                deckActionError = describe(error)
            }
        }
    }

    private func createDeck() {
        let name = deckNameInput.trimmingCharacters(in: .whitespacesAndNewlines)
        deckNameInput = ""
        guard !name.isEmpty else { return }
        runDeckAction { try await store.createDeck(name: name) }
    }

    private func performRename() {
        guard let deck = renameTarget else { return }
        let name = deckNameInput.trimmingCharacters(in: .whitespacesAndNewlines)
        renameTarget = nil
        deckNameInput = ""
        guard !name.isEmpty, name != deck.fullName else { return }
        runDeckAction { try await store.renameDeck(id: deck.id, name: name) }
    }

    private func performDelete(_ deck: DeckTreeEntry) {
        pendingDelete = nil
        runDeckAction { try await store.deleteDeck(id: deck.id) }
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

    /// Runs a deck mutation off the main actor, surfacing a readable message on
    /// failure (the store already refreshes the deck list on success). The work
    /// runs in a `Task` so the backend write doesn't block the main thread.
    private func runDeckAction(_ work: @escaping () async throws -> Void) {
        Task { @MainActor in
            do {
                try await work()
            } catch {
                deckActionError = describe(error)
            }
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

/// Identifiable wrapper carrying a note type's id + name for the note-type
/// management screenshot hooks (Fields / Card Template editors).
private struct NotetypeScreenTarget: Identifiable {
    let id: Int64
    let name: String
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
        // Also disabled during an exclusive backend op (import/export/full-sync)
        // so a sync can't start mid close→reopen window.
        .disabled(store.syncPhase.isActive || store.isBackendBusy)
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

/// A single deck row: an expand/collapse chevron (on decks with subdecks) and
/// the indented leaf name on the left, three colored counts on the right. Count
/// colors mirror AnkiDroid's deck picker (new = indigo/accent, learning = red,
/// review = green); zero counts are muted.
///
/// The expander and the deck body are *sibling* buttons (not nested), so tapping
/// the chevron toggles collapse while tapping the rest opens the deck overview.
private struct DeckRow: View {
    let deck: DeckTreeEntry
    let onSelect: () -> Void
    let onToggleCollapse: () -> Void

    var body: some View {
        HStack(spacing: DS.Spacing.s) {
            // Indentation lives on the expander so names line up under it; the
            // chevron rotates to point down when expanded, right when collapsed.
            expander
                .padding(.leading, CGFloat(deck.depth) * DS.Spacing.l)

            Button(action: onSelect) {
                deckBody
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, DS.Spacing.l)
        .frame(minHeight: DS.minTapTarget)
        .contentShape(Rectangle())
    }

    /// Expand/collapse control for decks with subdecks; a matching spacer for
    /// leaf decks so all names stay aligned regardless of whether they expand.
    @ViewBuilder
    private var expander: some View {
        if deck.hasChildren {
            Button(action: onToggleCollapse) {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(DS.textSecondary)
                    .rotationEffect(.degrees(deck.collapsed ? 0 : 90))
                    .frame(width: 28, height: DS.minTapTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(deck.collapsed ? "Expand \(deck.name)" : "Collapse \(deck.name)")
            .accessibilityIdentifier("deckExpander")
        } else {
            Color.clear.frame(width: 28, height: DS.minTapTarget)
        }
    }

    private var deckBody: some View {
        HStack(spacing: DS.Spacing.m) {
            Text(deck.name)
                .font(DS.Typography.body)
                .foregroundStyle(deck.filtered ? DS.good : DS.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)

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
        .frame(minHeight: DS.minTapTarget)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(deck.fullName), \(deck.newCount) new, \(deck.learnCount) learning, \(deck.reviewCount) to review"
        )
    }
}

/// Identifiable wrapper so the Add-note sheet can be driven by `.sheet(item:)`
/// from a chosen deck id (the deck's context-menu "Add note").
private struct AddNoteTarget: Identifiable {
    let id = UUID()
    let deckID: Int64
}

/// Identifiable wrapper so the Custom Study sheet can be driven per deck via
/// `.sheet(item:)` (its id is the deck id).
private struct CustomStudyTarget: Identifiable {
    let deckID: Int64
    var id: Int64 { deckID }
}

/// Identifiable wrapper so a produced per-deck export file can drive
/// `.sheet(item:)` for the system share sheet.
private struct ExportShareItem: Identifiable {
    let id = UUID()
    let url: URL
}

/// Minimal `UIActivityViewController` bridge for the system share sheet, used to
/// hand a produced `.apkg` to AirDrop, Files, Mail, etc. (Mirrors the share
/// sheet in `ImportExportView`; kept file-private here to avoid coupling.)
private struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
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
