import SwiftUI
import AnkiKit

/// Card Browser — a native SwiftUI clone of AnkiDroid's CardBrowser.
///
/// A search field (Anki search syntax) over a results list; each row shows a
/// question/answer snippet, the deck, and flag / suspended indicators. Tapping a
/// row edits the card's note (reusing `NoteEditorView` in EDIT mode); swipe or
/// long-press expose Suspend/Unsuspend, Flag, and Delete actions.
///
/// The list is *windowed* (see `CardBrowserModel`): a search resolves the full
/// list of matching card ids cheaply, but row DATA is fetched lazily a page at a
/// time for only the cards scrolled into view, so the browser opens quickly and
/// uses bounded memory even on collections with tens of thousands of cards.
///
/// Scope (T2.2): search + results + tap-to-edit + suspend/flag/delete. No column
/// customization, saved searches, multi-select, or preview pane.
@MainActor
struct CardBrowserView: View {
    @ObservedObject var store: AnkiStore
    @StateObject private var model: CardBrowserModel

    @State private var editTarget: EditTarget?
    @State private var infoTarget: CardTarget?
    @State private var changeTypeTarget: NoteTarget?
    @State private var pendingDelete: CardBrowserRow?

    // Multi-select bulk-action UI state.
    /// Presents the "Change deck" picker for the selection.
    @State private var showingDeckPicker = false
    /// Drives the bulk-delete confirmation for the selection.
    @State private var pendingBulkDelete = false
    /// Which tag prompt (add / remove) is showing, if any.
    @State private var tagSheet: TagSheetKind?
    /// The space-separated tag text entered in the add/remove tag prompt.
    @State private var tagInput = ""

    /// Opens the browser with an initial query (empty = all cards, matching
    /// AnkiDroid's default "show everything" browse).
    init(store: AnkiStore, initialQuery: String = "") {
        self.store = store
        _model = StateObject(wrappedValue: CardBrowserModel(store: store, initialQuery: initialQuery))
    }

    /// Identifiable wrapper so the edit sheet can be driven by `.sheet(item:)`.
    private struct EditTarget: Identifiable { let id: Int64 }
    /// Identifiable wrapper for a card-scoped sheet (Card Info), keyed by card id.
    private struct CardTarget: Identifiable { let id: Int64 }
    /// Identifiable wrapper for a note-scoped sheet (Change Note Type), keyed by note id.
    private struct NoteTarget: Identifiable { let id: Int64 }

    var body: some View {
        ZStack {
            DS.background.ignoresSafeArea()
            content
        }
        .navigationTitle(navigationTitle)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(
            text: queryBinding,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: "Search (e.g. deck:Biology, tag:hard)"
        )
        .autocorrectionDisabled()
        .textInputAutocapitalization(.never)
        .onSubmit(of: .search) { model.submitSearch() }
        .toolbar { selectionToolbar }
        // The bottom bulk-action bar slides in while multi-select is active.
        .safeAreaInset(edge: .bottom) {
            if model.isSelecting { bulkActionBar }
        }
        .task {
            // Initial load (the view's `.task` runs once on appear).
            model.startIfNeeded()
            #if DEBUG
            // Screenshot/automation hook: open straight into multi-select with a
            // few rows selected so a screenshot shows the selection UI + bar.
            if ProcessInfo.processInfo.arguments.contains("-demoBrowserSelect") {
                await model.demoEnterSelectionForScreenshot()
            }
            #endif
        }
        .sheet(isPresented: $showingDeckPicker) {
            DeckPickerSheet(decks: store.decks.filter { !$0.filtered }) { deckID in
                model.bulkSetDeck(deckID)
                showingDeckPicker = false
            } onCancel: {
                showingDeckPicker = false
            }
        }
        .alert(
            tagSheet?.title ?? "",
            isPresented: tagAlertPresented,
            presenting: tagSheet
        ) { kind in
            TextField("Tags (space-separated)", text: $tagInput)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            Button("Cancel", role: .cancel) { tagInput = "" }
            Button(kind.actionTitle) {
                switch kind {
                case .add: model.bulkAddTags(tagInput)
                case .remove: model.bulkRemoveTags(tagInput)
                }
                tagInput = ""
            }
        } message: { kind in
            Text(kind.message)
        }
        .confirmationDialog(
            "Delete notes?",
            isPresented: $pendingBulkDelete,
            titleVisibility: .visible
        ) {
            Button("Delete ^[\(model.selectedCount) note](inflect: true)", role: .destructive) {
                model.bulkDelete()
                pendingBulkDelete = false
            }
            Button("Cancel", role: .cancel) { pendingBulkDelete = false }
        } message: {
            Text("This deletes the selected notes and all their cards. You can undo it from the reviewer.")
        }
        .sheet(item: $editTarget) { target in
            NoteEditorView(store: store, mode: .edit(noteID: target.id)) {
                model.refresh()
            }
        }
        .sheet(item: $infoTarget) { target in
            CardInfoView(store: store, cardID: target.id)
        }
        .sheet(item: $changeTypeTarget) { target in
            ChangeNotetypeView(store: store, noteID: target.id) {
                model.refresh()
            }
        }
        .confirmationDialog(
            "Delete note?",
            isPresented: deleteDialogPresented,
            titleVisibility: .visible,
            presenting: pendingDelete
        ) { row in
            Button("Delete", role: .destructive) {
                model.delete(row)
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: { _ in
            // remove_notes deletes the note behind the card (and its siblings);
            // it records an undo entry, mirroring AnkiDroid's delete.
            Text("This deletes the note and all its cards. You can undo it from the reviewer.")
        }
        .alert("Action failed", isPresented: actionErrorPresented) {
            Button("OK", role: .cancel) { model.actionError = nil }
        } message: {
            Text(model.actionError ?? "")
        }
    }

    // MARK: - Content states

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .loading:
            loadingState
        case .failed(let message):
            failedState(message)
        case .loaded:
            if model.cardIDs.isEmpty {
                emptyState
            } else {
                resultsList
            }
        }
    }

    private var resultsList: some View {
        List {
            Section {
                // `List` instantiates only the rows near the viewport, so iterating
                // the full id list is cheap; each row pages its data in on demand.
                // The `.task` re-fires both on first appearance and whenever a new
                // search/refresh bumps `loadGeneration`, so on-screen rows reload
                // even when they never left the viewport.
                ForEach(model.cardIDs, id: \.self) { cardID in
                    rowView(cardID)
                        .listRowBackground(rowBackground(cardID))
                        .listRowSeparatorTint(DS.separator)
                        .task(id: model.loadGeneration) { model.ensureLoaded(cardID: cardID) }
                }
            } header: {
                Text("^[\(model.cardIDs.count) card](inflect: true)")
                    .font(DS.Typography.caption)
                    .foregroundStyle(DS.textSecondary)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(DS.background)
    }

    /// One results row. In normal mode it's the loaded card row with its
    /// tap-to-edit / swipe / context actions; in multi-select mode it's a
    /// selectable row (leading checkmark, tap toggles). A page still loading
    /// shows a lightweight placeholder in either mode.
    @ViewBuilder
    private func rowView(_ cardID: Int64) -> some View {
        if model.isSelecting {
            selectableRow(cardID)
        } else {
            normalRow(cardID)
        }
    }

    /// Normal-mode row: tap edits, swipe/long-press expose the single-row actions.
    @ViewBuilder
    private func normalRow(_ cardID: Int64) -> some View {
        if let row = model.rowsByID[cardID] {
            Button {
                openEditor(forCard: row.id)
            } label: {
                CardBrowserRowView(row: row)
            }
            .buttonStyle(.plain)
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button(role: .destructive) {
                    pendingDelete = row
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                Button {
                    model.toggleSuspend(row)
                } label: {
                    Label(
                        row.suspended ? "Unsuspend" : "Suspend",
                        systemImage: row.suspended ? "play.fill" : "pause.fill"
                    )
                }
                .tint(DS.hard)
            }
            .contextMenu { rowMenu(row) }
        } else {
            CardBrowserRowPlaceholder()
        }
    }

    /// Multi-select row: a leading checkmark + the row content (loaded row or
    /// placeholder). Tapping toggles the card's membership in the selection; the
    /// checkmark renders from the id alone, so even a not-yet-loaded row shows
    /// its selected state without forcing a fetch.
    private func selectableRow(_ cardID: Int64) -> some View {
        Button {
            model.toggleSelection(cardID)
        } label: {
            HStack(spacing: DS.Spacing.m) {
                Image(systemName: model.isSelected(cardID) ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(model.isSelected(cardID) ? DS.accent : DS.textSecondary)
                    .accessibilityHidden(true)
                selectableRowContent(cardID)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(model.isSelected(cardID) ? "Selected" : "Not selected")
        .accessibilityAddTraits(model.isSelected(cardID) ? [.isSelected] : [])
    }

    @ViewBuilder
    private func selectableRowContent(_ cardID: Int64) -> some View {
        if let row = model.rowsByID[cardID] {
            CardBrowserRowView(row: row)
        } else {
            CardBrowserRowPlaceholder()
        }
    }

    /// Tints a selected row in multi-select mode; otherwise the standard surface.
    private func rowBackground(_ cardID: Int64) -> Color {
        model.isSelecting && model.isSelected(cardID) ? DS.accent.opacity(0.12) : DS.surface
    }

    /// The shared long-press menu: enter multi-select, card info, change note
    /// type, suspend toggle, a flag submenu, and delete.
    @ViewBuilder
    private func rowMenu(_ row: CardBrowserRow) -> some View {
        // Long-press → multi-select, seeded with this row (AnkiDroid's
        // long-press-to-multiselect entry point).
        Button {
            model.enterSelection(initial: row.id)
        } label: {
            Label("Select", systemImage: "checkmark.circle")
        }

        Divider()

        Button {
            infoTarget = CardTarget(id: row.id)
        } label: {
            Label("Card Info", systemImage: "info.circle")
        }

        Button {
            openChangeNotetype(forCard: row.id)
        } label: {
            Label("Change Note Type", systemImage: "arrow.triangle.2.circlepath")
        }

        Divider()

        Button {
            model.toggleSuspend(row)
        } label: {
            Label(
                row.suspended ? "Unsuspend" : "Suspend",
                systemImage: row.suspended ? "play.fill" : "pause.fill"
            )
        }

        Menu {
            ForEach(CardFlag.allCases) { flag in
                Button {
                    model.setFlag(row.id, flag: flag.rawValue)
                } label: {
                    Label(flag.label, systemImage: row.flag == flag.rawValue ? "checkmark" : flag.systemImage)
                }
            }
        } label: {
            Label("Flag", systemImage: "flag")
        }

        Divider()

        Button(role: .destructive) {
            pendingDelete = row
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }

    private var loadingState: some View {
        VStack(spacing: DS.Spacing.m) {
            ProgressView()
            Text("Searching…")
                .font(DS.Typography.caption)
                .foregroundStyle(DS.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: DS.Spacing.m) {
            Image(systemName: "rectangle.stack.badge.questionmark")
                .font(.system(size: 44))
                .foregroundStyle(DS.textSecondary)
            Text("No cards found")
                .font(DS.Typography.headline)
                .foregroundStyle(DS.textPrimary)
            Text(model.query.isEmpty
                ? "This collection has no cards yet."
                : "No cards match this search.")
                .font(DS.Typography.caption)
                .foregroundStyle(DS.textSecondary)
        }
        .multilineTextAlignment(.center)
        .padding(DS.Spacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func failedState(_ message: String) -> some View {
        VStack(spacing: DS.Spacing.m) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 44))
                .foregroundStyle(DS.again)
            Text("Invalid search")
                .font(DS.Typography.headline)
                .foregroundStyle(DS.textPrimary)
            Text(message)
                .font(DS.Typography.caption)
                .foregroundStyle(DS.textSecondary)
        }
        .multilineTextAlignment(.center)
        .padding(DS.Spacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Multi-select chrome

    /// Inline title: "Browse" normally; the live selected count while selecting.
    private var navigationTitle: String {
        guard model.isSelecting else { return "Browse" }
        return model.selectedCount == 0 ? "Select Cards" : "\(model.selectedCount) selected"
    }

    /// Toolbar: a "Select" entry point normally; Cancel + Select-All/Deselect-All
    /// while selecting. Mirrors AnkiDroid's multiselect action bar affordances.
    @ToolbarContentBuilder
    private var selectionToolbar: some ToolbarContent {
        if model.isSelecting {
            ToolbarItem(placement: .topBarLeading) {
                Button("Cancel") { model.exitSelection() }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button(model.allSelected ? "Deselect All" : "Select All") {
                    if model.allSelected { model.deselectAll() } else { model.selectAll() }
                }
                .disabled(model.cardIDs.isEmpty)
            }
        } else {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Select") { model.enterSelection() }
                    .disabled(model.cardIDs.isEmpty)
            }
        }
    }

    /// Bottom bulk-action bar shown while selecting: Change Deck, Flag, status
    /// (suspend/unsuspend/bury), tags (mark/unmark/add/remove), and Delete —
    /// AnkiDroid's browser bulk operations. Grouped actions open menus; all are
    /// disabled with an empty selection.
    private var bulkActionBar: some View {
        HStack(spacing: 0) {
            bulkBarButton("Deck", systemImage: "tray.full") { showingDeckPicker = true }
            flagBarMenu
            statusBarMenu
            tagsBarMenu
            bulkBarButton("Delete", systemImage: "trash", destructive: true) {
                pendingBulkDelete = true
            }
        }
        .disabled(model.selectedCount == 0)
        .padding(.vertical, DS.Spacing.xs)
        .background(.bar)
    }

    /// Flag 0–7 applied to the whole selection.
    private var flagBarMenu: some View {
        Menu {
            ForEach(CardFlag.allCases) { flag in
                Button {
                    model.bulkSetFlag(flag.rawValue)
                } label: {
                    Label(flag.label, systemImage: flag.systemImage)
                }
            }
        } label: {
            bulkBarLabel("Flag", systemImage: "flag")
        }
        .disabled(model.selectedCount == 0)
    }

    /// Suspend / Unsuspend / Bury for the whole selection.
    private var statusBarMenu: some View {
        Menu {
            Button {
                model.bulkSetSuspended(true)
            } label: {
                Label("Suspend", systemImage: "pause.fill")
            }
            Button {
                model.bulkSetSuspended(false)
            } label: {
                Label("Unsuspend", systemImage: "play.fill")
            }
            Divider()
            Button {
                model.bulkBury()
            } label: {
                Label("Bury", systemImage: "eye.slash")
            }
        } label: {
            bulkBarLabel("Suspend", systemImage: "pause.circle")
        }
        .disabled(model.selectedCount == 0)
    }

    /// Mark / Unmark and Add / Remove tags for the whole selection.
    private var tagsBarMenu: some View {
        Menu {
            Button {
                model.bulkSetMarked(true)
            } label: {
                Label("Mark", systemImage: "star.fill")
            }
            Button {
                model.bulkSetMarked(false)
            } label: {
                Label("Unmark", systemImage: "star.slash")
            }
            Divider()
            Button {
                tagInput = ""
                tagSheet = .add
            } label: {
                Label("Add Tags", systemImage: "tag")
            }
            Button {
                tagInput = ""
                tagSheet = .remove
            } label: {
                Label("Remove Tags", systemImage: "tag.slash")
            }
        } label: {
            bulkBarLabel("Tags", systemImage: "tag")
        }
        .disabled(model.selectedCount == 0)
    }

    /// One tappable bottom-bar item (icon over caption), evenly sized.
    private func bulkBarButton(
        _ title: String, systemImage: String,
        destructive: Bool = false, action: @escaping () -> Void
    ) -> some View {
        Button(role: destructive ? .destructive : nil, action: action) {
            bulkBarLabel(title, systemImage: systemImage, destructive: destructive)
        }
        .accessibilityLabel(title)
    }

    /// Shared bottom-bar item appearance (icon over caption), used by both the
    /// plain buttons and the menu labels so the whole bar reads consistently.
    private func bulkBarLabel(
        _ title: String, systemImage: String, destructive: Bool = false
    ) -> some View {
        VStack(spacing: 2) {
            Image(systemName: systemImage)
                .font(.system(size: 18))
            Text(title)
                .font(.caption2)
        }
        .frame(maxWidth: .infinity)
        .frame(minHeight: DS.minTapTarget)
        .foregroundStyle(destructive ? DS.again : DS.accent)
        .contentShape(Rectangle())
    }

    // MARK: - Actions

    /// Resolves the row's note id on demand (one quick backend call, made only
    /// for the single tapped row rather than for every displayed row) and opens
    /// the note editor for it.
    private func openEditor(forCard cardID: Int64) {
        Task {
            if let noteID = await store.noteID(forCard: cardID) {
                editTarget = EditTarget(id: noteID)
            }
        }
    }

    /// Resolves the row's note id on demand, then opens Change Note Type for it.
    private func openChangeNotetype(forCard cardID: Int64) {
        Task {
            if let noteID = await store.noteID(forCard: cardID) {
                changeTypeTarget = NoteTarget(id: noteID)
            }
        }
    }

    // MARK: - Bindings & helpers

    /// Drives the search field: every keystroke flows through the model's
    /// debounce, and the clear/✗ button (which sets the text to empty) re-runs
    /// the search.
    private var queryBinding: Binding<String> {
        Binding(get: { model.query }, set: { model.queryChanged($0) })
    }

    private var deleteDialogPresented: Binding<Bool> {
        Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })
    }

    private var actionErrorPresented: Binding<Bool> {
        Binding(get: { model.actionError != nil }, set: { if !$0 { model.actionError = nil } })
    }

    /// Drives the add/remove-tag prompt; clearing it resets the typed text so a
    /// dismissed prompt doesn't leak its input into the next one.
    private var tagAlertPresented: Binding<Bool> {
        Binding(get: { tagSheet != nil }, set: { if !$0 { tagSheet = nil; tagInput = "" } })
    }
}

/// Which bulk tag prompt is showing, and its copy. Identifiable so it can key the
/// `.alert(presenting:)` content.
private enum TagSheetKind: Identifiable {
    case add, remove

    var id: Int { self == .add ? 0 : 1 }
    var title: String { self == .add ? "Add Tags" : "Remove Tags" }
    var actionTitle: String { self == .add ? "Add" : "Remove" }
    var message: String {
        self == .add
            ? "Add space-separated tags to the selected notes."
            : "Remove space-separated tags from the selected notes."
    }
}

/// A simple deck chooser for the bulk "Change deck" action: lists the normal
/// (non-filtered) decks by full path and reports the picked deck id. Filtered
/// decks are excluded because cards can't be moved into them.
private struct DeckPickerSheet: View {
    let decks: [DeckTreeEntry]
    let onSelect: (Int64) -> Void
    let onCancel: () -> Void

    var body: some View {
        NavigationStack {
            ZStack {
                DS.background.ignoresSafeArea()
                if decks.isEmpty {
                    Text("No decks available.")
                        .font(DS.Typography.caption)
                        .foregroundStyle(DS.textSecondary)
                } else {
                    List(decks) { deck in
                        Button {
                            onSelect(deck.id)
                        } label: {
                            HStack(spacing: DS.Spacing.m) {
                                Image(systemName: "rectangle.stack")
                                    .foregroundStyle(DS.textSecondary)
                                Text(deck.fullName)
                                    .font(DS.Typography.body)
                                    .foregroundStyle(DS.textPrimary)
                                Spacer(minLength: 0)
                            }
                            .frame(minHeight: DS.minTapTarget)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(DS.surface)
                        .listRowSeparatorTint(DS.separator)
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .background(DS.background)
                }
            }
            .navigationTitle("Change Deck")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onCancel() }
                }
            }
        }
    }
}

/// Owns the Card Browser's windowed data and search state, off the View so the
/// paging/caching logic stays contained and testable.
///
/// A search resolves the *full* list of matching card ids once (cheap — ids
/// only). Row DATA is then fetched lazily, a page at a time, for the cards
/// actually scrolled into view, and old rows are evicted as the user scrolls
/// away, so memory stays bounded regardless of the result-set size. Per-row
/// mutations (suspend/flag/delete) update the affected rows in place rather than
/// re-running the whole search.
@MainActor
final class CardBrowserModel: ObservableObject {
    enum LoadPhase: Equatable {
        case loading
        case loaded
        case failed(String)
    }

    /// Full, ordered list of matching card ids — cheap to hold (just ids) even
    /// for tens of thousands of cards.
    @Published private(set) var cardIDs: [Int64] = []
    /// Display rows for the pages visited so far, keyed by card id. Bounded by
    /// `maxCachedRows` so long scrolls don't grow memory without limit.
    @Published private(set) var rowsByID: [Int64: CardBrowserRow] = [:]
    @Published private(set) var phase: LoadPhase = .loading
    /// Message for the "Action failed" alert (a suspend/flag/delete error).
    @Published var actionError: String?
    /// The live query text, bound to the search field.
    @Published var query: String
    /// Bumped on every search/refresh. Each row keys its load `.task` on this, so
    /// a new search (or a post-edit cache drop) re-triggers loading for the rows
    /// already on screen — SwiftUI's `.onAppear` alone wouldn't re-fire for a row
    /// that never left the viewport.
    @Published private(set) var loadGeneration = 0

    /// Whether the browser is in multi-select mode (AnkiDroid's CardBrowser
    /// multiselect). Entered from the toolbar "Select" button or a row's "Select"
    /// context action; while on, a row tap toggles selection instead of opening
    /// the editor, and a bottom action bar applies bulk ops to the selection.
    @Published var isSelecting = false
    /// The selected card ids — ids ONLY, so selecting thousands of cards (incl.
    /// Select All) stays cheap and never materializes the windowed row list.
    @Published private(set) var selection: Set<Int64> = []

    private let store: AnkiStore
    /// O(1) position lookup so an appearing row can find (and page-load) its window.
    private var indexByID: [Int64: Int] = [:]
    /// Card ids whose page fetch is currently in flight (dedupes overlapping loads).
    private var loadingIDs: Set<Int64> = []
    /// Monotonic search id: results and page loads from a superseded search are
    /// discarded. This is the verified out-of-order search guard, extended to
    /// cover the lazy page loads too.
    private var searchSeq = 0
    /// Pending debounced live search (fires ~`debounceNanos` after the last keystroke).
    private var debounceTask: Task<Void, Never>?
    private var didStart = false

    /// Cards fetched per page. ~75 keeps each page fetch quick while limiting how
    /// many fetches a fast scroll triggers.
    static let pageSize = 75
    /// Upper bound on cached rows (~8 pages); farther rows are evicted so memory
    /// stays bounded even when scrolling through a huge collection.
    private static let maxCachedRows = pageSize * 8
    /// Debounce window for live typing.
    private static let debounceNanos: UInt64 = 300_000_000

    init(store: AnkiStore, initialQuery: String) {
        self.store = store
        self.query = initialQuery
    }

    // MARK: Search

    /// Runs the initial search once, when the view first appears.
    func startIfNeeded() {
        guard !didStart else { return }
        didStart = true
        runSearch()
    }

    /// Live-search entry point from the search field. Debounces so we don't
    /// re-query on every keystroke; because the clear/✗ button sets the text to
    /// empty, this also re-runs the search when the field is cleared.
    func queryChanged(_ newValue: String) {
        guard newValue != query else { return }
        query = newValue
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.debounceNanos)
            if Task.isCancelled { return }
            self?.runSearch()
        }
    }

    /// Immediate search (the keyboard's Search/return key); cancels any pending
    /// debounce so we don't double-query.
    func submitSearch() {
        debounceTask?.cancel()
        runSearch()
    }

    /// Refreshes after an edit / note-type change that may have changed a row's
    /// content (or which cards exist): drop the cached rows so the on-screen page
    /// reloads fresh, then re-resolve the id list (picking up any added/removed
    /// cards). The list keeps showing its rows as placeholders during the reload
    /// rather than dropping to a spinner, since the id list is still populated.
    func refresh() {
        rowsByID = [:]
        runSearch()
    }

    /// Re-resolves the (sorted) card id list — cheap, ids only. Results from a
    /// superseded search are ignored. Existing rows stay visible during a refresh;
    /// only the very first load (no ids yet) shows the full-screen spinner. The
    /// rows' own load `.task` (keyed on `loadGeneration`) then pages data in for
    /// whatever is on screen.
    func runSearch() {
        searchSeq += 1
        loadGeneration += 1
        let seq = searchSeq
        let currentQuery = query
        loadingIDs.removeAll()
        if cardIDs.isEmpty { phase = .loading }
        Task {
            do {
                let ids = try await store.browserCardIDs(query: currentQuery)
                guard seq == searchSeq else { return }
                setIDs(ids)
                phase = .loaded
            } catch {
                guard seq == searchSeq else { return }
                setIDs([])
                rowsByID = [:]
                phase = .failed(describeBrowserError(error))
            }
        }
    }

    // MARK: Lazy page loading

    /// Loads the page containing `cardID` if it isn't already loaded or loading.
    /// Driven by each row's load `.task`, so only pages near the viewport are
    /// fetched. Overlapping calls for the same page are de-duped via `loadingIDs`.
    func ensureLoaded(cardID: Int64) {
        guard rowsByID[cardID] == nil,
              !loadingIDs.contains(cardID),
              let index = indexByID[cardID] else { return }
        let start = (index / Self.pageSize) * Self.pageSize
        let end = min(start + Self.pageSize, cardIDs.count)
        let pageIDs = Array(cardIDs[start..<end]).filter {
            rowsByID[$0] == nil && !loadingIDs.contains($0)
        }
        guard !pageIDs.isEmpty else { return }
        pageIDs.forEach { loadingIDs.insert($0) }
        let seq = searchSeq
        Task {
            let fetched = await store.browserRows(forCardIDs: pageIDs)
            // Discard a page that belongs to a superseded search; its loadingIDs
            // were already cleared by the newer `runSearch`.
            guard seq == searchSeq else { return }
            pageIDs.forEach { loadingIDs.remove($0) }
            var updated = rowsByID
            for row in fetched { updated[row.id] = row }
            rowsByID = updated
            evictDistantRows(around: index)
        }
    }

    /// Keeps only the `maxCachedRows` rows nearest the current viewport, dropping
    /// the farthest, so scrolling through a large collection doesn't accumulate
    /// every row in memory. Evicted rows reload on demand if scrolled back to.
    private func evictDistantRows(around index: Int) {
        guard rowsByID.count > Self.maxCachedRows else { return }
        let nearest = rowsByID.keys
            .sorted { abs((indexByID[$0] ?? 0) - index) < abs((indexByID[$1] ?? 0) - index) }
            .prefix(Self.maxCachedRows)
        rowsByID = Dictionary(uniqueKeysWithValues: nearest.map { ($0, rowsByID[$0]!) })
    }

    // MARK: Per-row mutations (incremental — no full re-search)

    /// Suspends/unsuspends a card, then reloads just that one row in place.
    func toggleSuspend(_ row: CardBrowserRow) {
        Task {
            do {
                try await store.setCardsSuspended([row.id], suspended: !row.suspended)
                reloadRow(cardID: row.id)
            } catch {
                actionError = describeBrowserError(error)
            }
        }
    }

    /// Sets/clears a card's flag, then reloads just that one row in place.
    func setFlag(_ cardID: Int64, flag: Int) {
        Task {
            do {
                try await store.setFlag([cardID], flag: flag)
                reloadRow(cardID: cardID)
            } catch {
                actionError = describeBrowserError(error)
            }
        }
    }

    /// Deletes the note behind a row and removes exactly the affected rows (the
    /// note's cards, including siblings) from the list in place — no re-search.
    func delete(_ row: CardBrowserRow) {
        Task {
            do {
                let removed = try await store.deleteNotes(forCards: [row.id])
                removeCards(removed.isEmpty ? [row.id] : removed)
            } catch {
                actionError = describeBrowserError(error)
            }
        }
    }

    /// Re-fetches a single row's data after a per-row mutation, updating just
    /// that row in place (or dropping it if the card vanished).
    private func reloadRow(cardID: Int64) {
        let seq = searchSeq
        Task {
            let fetched = await store.browserRows(forCardIDs: [cardID])
            guard seq == searchSeq else { return }
            if let row = fetched.first {
                rowsByID[cardID] = row
            } else {
                removeCards([cardID])
            }
        }
    }

    // MARK: Selection (multi-select)

    var selectedCount: Int { selection.count }
    /// True when every matching card is selected (drives Select-All/Deselect-All).
    var allSelected: Bool { !cardIDs.isEmpty && selection.count == cardIDs.count }

    func isSelected(_ cardID: Int64) -> Bool { selection.contains(cardID) }

    /// Enters multi-select mode, optionally seeding the selection with the row it
    /// was started on (the long-press/"Select" entry point selects that row).
    func enterSelection(initial cardID: Int64? = nil) {
        isSelecting = true
        if let cardID { selection = [cardID] }
    }

    /// Leaves multi-select mode and clears the selection.
    func exitSelection() {
        isSelecting = false
        selection.removeAll()
    }

    /// Toggles a row's membership in the selection (the in-select-mode tap).
    func toggleSelection(_ cardID: Int64) {
        if selection.contains(cardID) {
            selection.remove(cardID)
        } else {
            selection.insert(cardID)
        }
    }

    /// Selects every matching card (ids only — no row data is loaded).
    func selectAll() { selection = Set(cardIDs) }

    /// Clears the selection but stays in select mode.
    func deselectAll() { selection.removeAll() }

    #if DEBUG
    /// Screenshot/automation hook: wait for the initial id list to load, then
    /// enter multi-select with the first few rows selected so a screenshot
    /// captures the selection UI and the bottom action bar. Debug-only.
    func demoEnterSelectionForScreenshot() async {
        for _ in 0..<60 {
            if !cardIDs.isEmpty { break }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        isSelecting = true
        selection = Set(cardIDs.prefix(3))
    }
    #endif

    // MARK: Bulk actions (multi-select)
    //
    // Each applies one backend op to the whole selection off-main (via the
    // store), then refreshes the affected rows in place. Non-destructive ops keep
    // the selection and stay in select mode (as AnkiDroid does); delete clears
    // the selection and exits. All stay undoable via the engine.

    func bulkSetDeck(_ deckID: Int64) {
        runBulk { try await self.store.setDeck(forCards: $0, deckID: deckID) }
    }

    func bulkSetFlag(_ flag: Int) {
        runBulk { try await self.store.setFlag($0, flag: flag) }
    }

    func bulkSetSuspended(_ suspended: Bool) {
        runBulk { try await self.store.setCardsSuspended($0, suspended: suspended) }
    }

    func bulkBury() {
        runBulk { try await self.store.buryCards($0) }
    }

    func bulkSetMarked(_ marked: Bool) {
        runBulk { try await self.store.setMarked(forCards: $0, marked: marked) }
    }

    func bulkAddTags(_ tags: String) {
        let trimmed = tags.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        runBulk { try await self.store.addTags(forCards: $0, tags: trimmed) }
    }

    func bulkRemoveTags(_ tags: String) {
        let trimmed = tags.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        runBulk { try await self.store.removeTags(forCards: $0, tags: trimmed) }
    }

    /// Deletes the notes behind the selection (and their sibling cards), removes
    /// exactly those rows in place, then exits select mode — matching AnkiDroid,
    /// which leaves multiselect after a destructive bulk action.
    func bulkDelete() {
        let ids = Array(selection)
        guard !ids.isEmpty else { return }
        Task {
            do {
                let removed = try await store.deleteNotes(forCards: ids)
                removeCards(removed.isEmpty ? ids : removed)
                exitSelection()
            } catch {
                actionError = describeBrowserError(error)
            }
        }
    }

    /// Shared driver for the non-destructive bulk ops: run `op` over the current
    /// selection, then reload the affected rows in place so their badges update,
    /// keeping the selection and select mode.
    private func runBulk(_ op: @escaping ([Int64]) async throws -> Void) {
        let ids = Array(selection)
        guard !ids.isEmpty else { return }
        Task {
            do {
                try await op(ids)
                reloadRows(Set(ids))
            } catch {
                actionError = describeBrowserError(error)
            }
        }
    }

    /// Drops cached data for the given cards and re-triggers loading for whatever
    /// is on screen (by bumping `loadGeneration`), so a bulk action's badge
    /// changes appear without re-resolving the whole id list or losing scroll
    /// position. Off-screen affected rows simply reload when next scrolled to.
    private func reloadRows(_ ids: Set<Int64>) {
        guard !ids.isEmpty else { return }
        var updated = rowsByID
        for id in ids { updated[id] = nil }
        rowsByID = updated
        loadGeneration += 1
    }

    // MARK: List bookkeeping

    /// Replaces the id list and rebuilds the position index, pruning cached rows
    /// whose card is no longer present (keeps memory bounded after a delete or a
    /// narrower search).
    private func setIDs(_ ids: [Int64]) {
        cardIDs = ids
        indexByID = Self.indexMap(for: ids)
        if !rowsByID.isEmpty {
            rowsByID = rowsByID.filter { indexByID[$0.key] != nil }
        }
        // Drop any selected ids the new result set no longer contains, so the
        // selected-count and bulk ops never reference cards that aren't listed
        // (a narrower re-search keeps the still-matching selection).
        if !selection.isEmpty {
            selection = selection.filter { indexByID[$0] != nil }
        }
    }

    /// Removes rows from the list in place and reindexes — used after a delete so
    /// the deleted note's cards disappear without rebuilding the whole list.
    private func removeCards(_ ids: [Int64]) {
        let removal = Set(ids)
        cardIDs.removeAll { removal.contains($0) }
        for id in ids {
            rowsByID[id] = nil
            loadingIDs.remove(id)
        }
        indexByID = Self.indexMap(for: cardIDs)
    }

    private static func indexMap(for ids: [Int64]) -> [Int64: Int] {
        var map: [Int64: Int] = [:]
        map.reserveCapacity(ids.count)
        for (i, id) in ids.enumerated() { map[id] = i }
        return map
    }
}

/// Extracts a human-readable message from a thrown error, decoding the engine's
/// protobuf `BackendError` when present (e.g. an invalid search).
private func describeBrowserError(_ error: Error) -> String {
    if case let AnkiError.backendError(data) = error,
       let backendError = try? Anki_Backend_BackendError(serializedBytes: data),
       !backendError.message.isEmpty {
        return backendError.message
    }
    return error.localizedDescription
}

/// One results row: question (primary) + answer (secondary) + deck, with flag
/// and suspended indicators. Mirrors AnkiDroid's browser row content.
private struct CardBrowserRowView: View {
    let row: CardBrowserRow

    var body: some View {
        HStack(spacing: DS.Spacing.m) {
            VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                Text(displayQuestion)
                    .font(DS.Typography.body.weight(.semibold))
                    .foregroundStyle(DS.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                if !row.answer.isEmpty {
                    Text(row.answer)
                        .font(DS.Typography.caption)
                        .foregroundStyle(DS.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                HStack(spacing: DS.Spacing.s) {
                    Label(row.deck, systemImage: "rectangle.stack")
                        .font(DS.Typography.caption)
                        .foregroundStyle(DS.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if row.suspended {
                        suspendedBadge
                    }
                }
            }

            Spacer(minLength: 0)

            if let flagColor = CardFlag(rawValue: row.flag)?.color {
                Image(systemName: "flag.fill")
                    .font(.caption)
                    .foregroundStyle(flagColor)
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, DS.Spacing.xs)
        .frame(minHeight: DS.minTapTarget)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint("Edit note")
    }

    private var displayQuestion: String {
        row.question.isEmpty ? "(empty)" : row.question
    }

    private var suspendedBadge: some View {
        Text("Suspended")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(DS.hard)
            .padding(.horizontal, DS.Spacing.s)
            .padding(.vertical, 2)
            .background(
                DS.hard.opacity(0.15),
                in: Capsule()
            )
    }

    private var accessibilityLabel: String {
        var parts = [displayQuestion]
        if !row.answer.isEmpty { parts.append(row.answer) }
        parts.append("deck \(row.deck)")
        if let name = CardFlag(rawValue: row.flag)?.spokenName { parts.append(name) }
        if row.suspended { parts.append("suspended") }
        return parts.joined(separator: ", ")
    }
}

/// Stand-in row shown while a page's data is still loading. Sized like a real
/// row (redacted bars) so the list height is stable and scrolling stays smooth.
private struct CardBrowserRowPlaceholder: View {
    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            RoundedRectangle(cornerRadius: 4)
                .fill(DS.textSecondary.opacity(0.18))
                .frame(width: 220, height: 13)
            RoundedRectangle(cornerRadius: 4)
                .fill(DS.textSecondary.opacity(0.10))
                .frame(width: 140, height: 11)
        }
        .padding(.vertical, DS.Spacing.xs)
        .frame(minHeight: DS.minTapTarget, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading card")
    }
}

/// The eight Anki flag states (none + seven colors), matching AnkiDroid's flag
/// palette and the engine's `set_flag` codes (0 clears; 1...7 set a color).
private enum CardFlag: Int, CaseIterable, Identifiable {
    case none = 0, red, orange, green, blue, pink, turquoise, purple

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .none: return "No Flag"
        case .red: return "Red"
        case .orange: return "Orange"
        case .green: return "Green"
        case .blue: return "Blue"
        case .pink: return "Pink"
        case .turquoise: return "Turquoise"
        case .purple: return "Purple"
        }
    }

    /// Indicator color, or nil for "no flag".
    var color: Color? {
        switch self {
        case .none: return nil
        case .red: return .red
        case .orange: return .orange
        case .green: return .green
        case .blue: return .blue
        case .pink: return .pink
        case .turquoise: return .teal
        case .purple: return .purple
        }
    }

    var systemImage: String {
        self == .none ? "flag.slash" : "flag.fill"
    }

    /// VoiceOver phrasing for a set flag (nil for none).
    var spokenName: String? {
        self == .none ? nil : "\(label) flag"
    }
}
