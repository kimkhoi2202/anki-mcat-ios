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
/// Scope: search + results + tap-to-edit + suspend/flag/delete, multi-select
/// bulk actions, configurable columns (picker + order, persisted), tap-to-sort
/// (column + direction, persisted), Find & Replace, a Cards/Notes mode toggle
/// (persisted, one row per card or per note), a phone-appropriate filter sidebar
/// (Saved Searches / Decks / Tags / Flags / Card State / Today, each setting an
/// Anki search term), and a read-only card Preview (rendered front/back via the
/// reviewer's `CardWebView`, with a flip control and no grading).
@MainActor
struct CardBrowserView: View {
    @ObservedObject var store: AnkiStore
    @StateObject private var model: CardBrowserModel

    @State private var editTarget: EditTarget?
    @State private var infoTarget: CardTarget?
    @State private var changeTypeTarget: NoteTarget?
    @State private var pendingDelete: CardBrowserRow?

    // Browser power-feature sheets.
    /// Presents the column picker (which columns + their order).
    @State private var showingColumnPicker = false
    /// Presents the Find & Replace sheet.
    @State private var showingFindReplace = false
    /// Presents the filter sidebar ("Filters" panel: decks/tags/flags/state/saved).
    @State private var showingSidebar = false
    /// Drives the read-only card Preview sheet, keyed by the resolved card id.
    @State private var previewTarget: PreviewTarget?
    /// Drives the "Save current search" naming prompt, and holds the typed name.
    @State private var showingSaveSearch = false
    @State private var saveSearchName = ""

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
    /// Identifiable wrapper for the Preview sheet, keyed by the resolved card id.
    private struct PreviewTarget: Identifiable { let id: Int64 }

    var body: some View {
        browserSecondarySheets(browserPrimarySheets(browserCore))
    }

    /// The core browser surface (results list + search field + toolbars + bulk
    /// bar + initial task). Split from the sheet/alert modifiers so each stays a
    /// small type-check unit — the combined body otherwise exceeds the Swift
    /// type-checker's budget ("unable to type-check in reasonable time").
    private var browserCore: some View {
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
        .toolbar { filtersToolbar }
        .toolbar { overflowToolbar }
        // The bottom bulk-action bar slides in while multi-select is active.
        .safeAreaInset(edge: .bottom) {
            if model.isSelecting { bulkActionBar }
        }
        .task {
            // Initial load (the view's `.task` runs once on appear).
            model.startIfNeeded()
            #if DEBUG
            // Screenshot/automation hooks for the browser power features.
            let arguments = ProcessInfo.processInfo.arguments
            // Open straight into multi-select with a few rows selected so a
            // screenshot shows the selection UI + bar.
            if arguments.contains("-demoBrowserSelect") {
                await model.demoEnterSelectionForScreenshot()
            }
            // Configure a richer column set so the list shows the N-column row
            // layout (extra labeled lines) in a screenshot.
            if arguments.contains("-demoBrowserColumnsApplied") {
                await model.demoApplyRichColumnsForScreenshot()
            }
            // Present the column picker (waits for the engine column list first).
            if arguments.contains("-demoBrowserColumns") {
                await model.demoWaitForMetadataForScreenshot()
                showingColumnPicker = true
            }
            // Present the Find & Replace sheet (waits for field names first).
            if arguments.contains("-demoBrowserFindReplace") {
                await model.demoWaitForMetadataForScreenshot()
                showingFindReplace = true
            }
            // Switch to Notes mode (one row per note) for its screenshot.
            if arguments.contains("-demoBrowserNotesMode") {
                await model.demoEnterNotesModeForScreenshot()
            }
            // Present the filter sidebar (loads decks/tags/saved first).
            if arguments.contains("-demoBrowserSidebar") {
                await model.demoWaitForIDsForScreenshot()
                await model.demoLoadSidebarForScreenshot()
                showingSidebar = true
            }
            // Present the read-only Preview for the first row.
            if arguments.contains("-demoBrowserPreview") {
                await model.demoWaitForIDsForScreenshot()
                if let firstRow = model.cardIDs.first,
                   let cardID = await model.resolveCardID(forRow: firstRow) {
                    previewTarget = PreviewTarget(id: cardID)
                }
            }
            #endif
        }
    }

    /// First group of browser sheets/alerts (column picker, Find & Replace, and
    /// the bulk deck/tag/delete prompts). Applied to `browserCore` via the body.
    private func browserPrimarySheets(_ view: some View) -> some View {
        view
        .sheet(isPresented: $showingColumnPicker) {
            ColumnPickerSheet(
                available: model.availableColumns,
                activeKeys: model.activeColumnKeys
            ) { keys in
                model.setActiveColumns(keys)
                showingColumnPicker = false
            } onCancel: {
                showingColumnPicker = false
            }
        }
        .sheet(isPresented: $showingFindReplace) {
            FindReplaceSheet(
                fieldNames: model.fieldNames,
                selectedCount: model.selectedCount
            ) { find, replacement, regex, matchCase, fieldName, onlySelected in
                showingFindReplace = false
                model.runFindReplace(
                    find: find, replacement: replacement, regex: regex,
                    matchCase: matchCase, fieldName: fieldName, onlySelected: onlySelected
                )
            } onCancel: {
                showingFindReplace = false
            }
        }
        .alert(Loc.tr("browsing-find-and-replace"), isPresented: findReplaceResultPresented) {
            Button("OK", role: .cancel) { model.findReplaceResult = nil }
        } message: {
            Text(model.findReplaceResult ?? "")
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
            Button(Loc.tr("actions-cancel"), role: .cancel) { tagInput = "" }
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
            Button(Loc.tr("actions-cancel"), role: .cancel) { pendingBulkDelete = false }
        } message: {
            Text("This deletes the selected notes and all their cards. You can undo it from the reviewer.")
        }
    }

    /// Second group of browser sheets/alerts (edit / card info / change-notetype
    /// / the new filter sidebar / card preview / save-search / per-row delete /
    /// errors). Applied over `browserPrimarySheets` via the body.
    private func browserSecondarySheets(_ view: some View) -> some View {
        view
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
        .sheet(isPresented: $showingSidebar) {
            BrowserSidebarSheet(
                deckTree: model.sidebarDeckTree,
                tags: model.tags,
                savedSearches: model.savedSearches,
                activeQuery: model.query,
                onApply: { term in
                    model.applySearch(term)
                    showingSidebar = false
                },
                onSaveCurrent: {
                    saveSearchName = ""
                    showingSidebar = false
                    showingSaveSearch = true
                },
                onDismiss: { showingSidebar = false }
            )
        }
        .sheet(item: $previewTarget) { target in
            CardPreviewSheet(store: store, cardID: target.id)
        }
        .alert(Loc.tr("browsing-sidebar-save-current-search"), isPresented: $showingSaveSearch) {
            TextField("Name", text: $saveSearchName)
                .autocorrectionDisabled()
            Button(Loc.tr("actions-cancel"), role: .cancel) { saveSearchName = "" }
            Button(Loc.tr("actions-save")) {
                model.saveCurrentSearch(name: saveSearchName)
                saveSearchName = ""
            }
        } message: {
            Text("Save the current search so you can reuse it from the Filters panel.")
        }
        .alert("Couldn't save search", isPresented: saveSearchErrorPresented) {
            Button("OK", role: .cancel) { model.saveSearchError = nil }
        } message: {
            Text(model.saveSearchError ?? "")
        }
        .confirmationDialog(
            "Delete note?",
            isPresented: deleteDialogPresented,
            titleVisibility: .visible,
            presenting: pendingDelete
        ) { row in
            Button(Loc.tr("actions-delete"), role: .destructive) {
                model.delete(row)
                pendingDelete = nil
            }
            Button(Loc.tr("actions-cancel"), role: .cancel) { pendingDelete = nil }
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
                // Plain runtime string (mode-dependent noun), so pluralize
                // manually rather than with ^[…](inflect:) markup.
                Text(rowCountLabel)
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
                openEditor(forRow: row.id)
            } label: {
                CardBrowserRowView(row: row, columns: model.activeColumns)
            }
            .buttonStyle(.plain)
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button(role: .destructive) {
                    pendingDelete = row
                } label: {
                    Label(Loc.tr("actions-delete"), systemImage: "trash")
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
            CardBrowserRowView(row: row, columns: model.activeColumns)
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
            Label(Loc.tr("actions-select"), systemImage: "checkmark.circle")
        }

        Divider()

        Button {
            openPreview(forRow: row.id)
        } label: {
            Label(Loc.tr("actions-preview"), systemImage: "eye")
        }

        Button {
            openCardInfo(forRow: row.id)
        } label: {
            Label(Loc.tr("actions-card-info"), systemImage: "info.circle")
        }

        Button {
            openChangeNotetype(forRow: row.id)
        } label: {
            Label(Loc.tr("browsing-change-note-type"), systemImage: "arrow.triangle.2.circlepath")
        }

        Divider()

        Button {
            model.toggleSuspend(row)
        } label: {
            // "Unsuspend" has no matching catalog key, so it stays English.
            Label(
                row.suspended ? "Unsuspend" : Loc.tr("studying-suspend"),
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
            Label(Loc.tr("browsing-flag"), systemImage: "flag")
        }

        Divider()

        Button(role: .destructive) {
            pendingDelete = row
        } label: {
            Label(Loc.tr("actions-delete"), systemImage: "trash")
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
            Text("No \(model.itemNoun)s found")
                .font(DS.Typography.headline)
                .foregroundStyle(DS.textPrimary)
            Text(model.query.isEmpty
                ? "This collection has no \(model.itemNoun)s yet."
                : "No \(model.itemNoun)s match this search.")
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
        guard model.isSelecting else { return Loc.tr("qt-misc-browse") }
        return model.selectedCount == 0
            ? "Select \(model.mode == .notes ? "Notes" : "Cards")"
            : "\(model.selectedCount) selected"
    }

    /// The row-count header text ("N cards" / "N notes"), pluralized for the
    /// current mode.
    private var rowCountLabel: String {
        let count = model.cardIDs.count
        return "\(count) \(model.itemNoun)\(count == 1 ? "" : "s")"
    }

    /// Toolbar: a "Select" entry point normally; Cancel + Select-All/Deselect-All
    /// while selecting. Mirrors AnkiDroid's multiselect action bar affordances.
    @ToolbarContentBuilder
    private var selectionToolbar: some ToolbarContent {
        if model.isSelecting {
            ToolbarItem(placement: .topBarLeading) {
                Button(Loc.tr("actions-cancel")) { model.exitSelection() }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button(model.allSelected ? "Deselect All" : "Select All") {
                    if model.allSelected { model.deselectAll() } else { model.selectAll() }
                }
                .disabled(model.cardIDs.isEmpty)
            }
        } else {
            ToolbarItem(placement: .topBarTrailing) {
                Button(Loc.tr("actions-select")) { model.enterSelection() }
                    .disabled(model.cardIDs.isEmpty)
            }
        }
    }

    /// A leading "Filters" button (hidden while multi-selecting, when the leading
    /// slot shows Cancel) that opens the phone's filter sidebar — the mobile form
    /// of AnkiDroid/desktop's browser sidebar.
    @ToolbarContentBuilder
    private var filtersToolbar: some ToolbarContent {
        if !model.isSelecting {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    openSidebar()
                } label: {
                    Label("Filters", systemImage: "line.3.horizontal.decrease.circle")
                }
                .accessibilityLabel("Filters")
            }
        }
    }

    /// Overflow menu (always present): the Cards/Notes mode toggle, then Sort ▸,
    /// Columns…, and Find & Replace… — the browser power features. Mirrors
    /// AnkiDroid's browser overflow, which gathers the mode switch, sort,
    /// column-management, and find-replace there. Find & Replace auto-scopes to
    /// the selection when one exists.
    @ToolbarContentBuilder
    private var overflowToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                // Cards vs Notes: a checkmarked inline picker, like desktop's
                // browser "Cards"/"Notes" toggle.
                Picker("View", selection: modeBinding) {
                    Label(Loc.tr("browsing-cards"), systemImage: "rectangle.on.rectangle").tag(BrowserMode.cards)
                    Label(Loc.tr("browsing-notes"), systemImage: "note.text").tag(BrowserMode.notes)
                }
                Divider()
                sortMenu
                Button {
                    showingColumnPicker = true
                } label: {
                    Label("Columns…", systemImage: "slider.horizontal.3")
                }
                Button {
                    showingFindReplace = true
                } label: {
                    Label("Find & Replace…", systemImage: "text.magnifyingglass")
                }
                Divider()
                Button {
                    openSidebar()
                } label: {
                    Label("Filters…", systemImage: "line.3.horizontal.decrease.circle")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .accessibilityLabel("Browser options")
        }
    }

    /// Sort submenu: one entry per sortable column. The active column shows an
    /// up/down chevron for the current direction; tapping it flips direction,
    /// tapping another switches to it.
    private var sortMenu: some View {
        Menu {
            ForEach(model.sortMenuColumns) { column in
                Button {
                    model.applySort(columnKey: column.key)
                } label: {
                    if model.sort.column == column.key {
                        Label(
                            column.label,
                            systemImage: model.sort.reverse ? "chevron.down" : "chevron.up"
                        )
                    } else {
                        Text(column.label)
                    }
                }
            }
        } label: {
            Label("Sort", systemImage: "arrow.up.arrow.down")
        }
    }

    /// Bottom bulk-action bar shown while selecting: Change Deck, Flag, status
    /// (suspend/unsuspend/bury), tags (mark/unmark/add/remove), and Delete —
    /// AnkiDroid's browser bulk operations. Grouped actions open menus; all are
    /// disabled with an empty selection.
    private var bulkActionBar: some View {
        HStack(spacing: 0) {
            bulkBarButton(Loc.tr("decks-deck"), systemImage: "tray.full") { showingDeckPicker = true }
            flagBarMenu
            statusBarMenu
            tagsBarMenu
            bulkBarButton(Loc.tr("actions-delete"), systemImage: "trash", destructive: true) {
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
            bulkBarLabel(Loc.tr("browsing-flag"), systemImage: "flag")
        }
        .disabled(model.selectedCount == 0)
    }

    /// Suspend / Unsuspend / Bury for the whole selection.
    private var statusBarMenu: some View {
        Menu {
            Button {
                model.bulkSetSuspended(true)
            } label: {
                Label(Loc.tr("studying-suspend"), systemImage: "pause.fill")
            }
            Button {
                model.bulkSetSuspended(false)
            } label: {
                // "Unsuspend" has no matching catalog key, so it stays English.
                Label("Unsuspend", systemImage: "play.fill")
            }
            Divider()
            Button {
                model.bulkBury()
            } label: {
                Label(Loc.tr("studying-bury"), systemImage: "eye.slash")
            }
        } label: {
            bulkBarLabel(Loc.tr("studying-suspend"), systemImage: "pause.circle")
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
            bulkBarLabel(Loc.tr("editing-tags"), systemImage: "tag")
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
    /// the note editor for it. Mode-aware: the row id is already the note id in
    /// notes mode, else it's resolved from the card.
    private func openEditor(forRow rowID: Int64) {
        Task {
            if let noteID = await model.resolveNoteID(forRow: rowID) {
                editTarget = EditTarget(id: noteID)
            }
        }
    }

    /// Resolves the row's note id on demand, then opens Change Note Type for it.
    private func openChangeNotetype(forRow rowID: Int64) {
        Task {
            if let noteID = await model.resolveNoteID(forRow: rowID) {
                changeTypeTarget = NoteTarget(id: noteID)
            }
        }
    }

    /// Resolves the row to a concrete card id (the note's first card in notes
    /// mode) and opens Card Info for it.
    private func openCardInfo(forRow rowID: Int64) {
        Task {
            if let cardID = await model.resolveCardID(forRow: rowID) {
                infoTarget = CardTarget(id: cardID)
            }
        }
    }

    /// Resolves the row to a concrete card id and opens the read-only Preview
    /// (Anki's browser Preview — rendered front/back with a flip, no grading).
    private func openPreview(forRow rowID: Int64) {
        Task {
            if let cardID = await model.resolveCardID(forRow: rowID) {
                previewTarget = PreviewTarget(id: cardID)
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

    private var findReplaceResultPresented: Binding<Bool> {
        Binding(get: { model.findReplaceResult != nil }, set: { if !$0 { model.findReplaceResult = nil } })
    }

    private var saveSearchErrorPresented: Binding<Bool> {
        Binding(get: { model.saveSearchError != nil }, set: { if !$0 { model.saveSearchError = nil } })
    }

    /// Drives the Cards/Notes toggle in the overflow menu.
    private var modeBinding: Binding<BrowserMode> {
        Binding(get: { model.mode }, set: { model.setMode($0) })
    }

    /// Loads the sidebar's data sources (if needed) and presents the Filters panel.
    private func openSidebar() {
        model.loadSidebarIfNeeded()
        showingSidebar = true
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
            .navigationTitle(Loc.tr("browsing-change-deck"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(Loc.tr("actions-cancel")) { onCancel() }
                }
            }
        }
    }
}

/// The browser column picker: choose which columns show and in what order,
/// mirroring AnkiDroid's "Manage columns". A "Shown" section holds the active
/// columns (reorder + remove via Edit), and an "Available" section lists the
/// rest (tap to add). Reports the chosen ordered keys on Done.
private struct ColumnPickerSheet: View {
    let available: [BrowserColumn]
    let onApply: ([String]) -> Void
    let onCancel: () -> Void

    /// Working copy of the active columns (full metadata), edited locally and
    /// only committed on Done.
    @State private var active: [BrowserColumn]
    @State private var editMode: EditMode = .inactive

    init(
        available: [BrowserColumn],
        activeKeys: [String],
        onApply: @escaping ([String]) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.available = available
        self.onApply = onApply
        self.onCancel = onCancel
        // Resolve the active keys to full columns in their saved order, dropping
        // any the engine no longer knows.
        let byKey = Dictionary(uniqueKeysWithValues: available.map { ($0.key, $0) })
        _active = State(initialValue: activeKeys.compactMap { byKey[$0] })
    }

    /// Columns not currently shown (the "add" candidates).
    private var inactive: [BrowserColumn] {
        let activeKeys = Set(active.map(\.key))
        return available.filter { !activeKeys.contains($0.key) }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                DS.background.ignoresSafeArea()
                if available.isEmpty {
                    ProgressView("Loading columns…")
                        .font(DS.Typography.caption)
                        .foregroundStyle(DS.textSecondary)
                } else {
                    list
                }
            }
            .navigationTitle("Columns")
            .navigationBarTitleDisplayMode(.inline)
            .environment(\.editMode, $editMode)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(Loc.tr("actions-cancel")) { onCancel() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    EditButton()
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { onApply(active.map(\.key)) }
                        .disabled(active.isEmpty)
                }
            }
        }
    }

    private var list: some View {
        List {
            Section {
                ForEach(active) { column in
                    Text(column.label)
                        .font(DS.Typography.body)
                        .foregroundStyle(DS.textPrimary)
                        .listRowBackground(DS.surface)
                }
                .onMove { active.move(fromOffsets: $0, toOffset: $1) }
                .onDelete(perform: remove)
            } header: {
                Text("Shown")
            } footer: {
                Text("Tap Edit to reorder or remove. The first column is the row's headline.")
            }

            if !inactive.isEmpty {
                Section("Add") {
                    ForEach(inactive) { column in
                        Button {
                            active.append(column)
                        } label: {
                            HStack(spacing: DS.Spacing.m) {
                                Image(systemName: "plus.circle.fill")
                                    .foregroundStyle(DS.accent)
                                Text(column.label)
                                    .font(DS.Typography.body)
                                    .foregroundStyle(DS.textPrimary)
                                Spacer(minLength: 0)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(DS.surface)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
    }

    /// Removes shown columns, but never the last one (an empty row is meaningless).
    private func remove(at offsets: IndexSet) {
        guard active.count - offsets.count >= 1 else { return }
        active.remove(atOffsets: offsets)
    }
}

/// The browser Find & Replace sheet (AnkiDroid's browser find&replace): a find
/// term + replacement, regex / match-case options, an "in field" picker (all
/// fields or one named field), and a scope toggle — selected notes when a
/// selection exists, else all notes matching the current search. Reports the
/// inputs on Replace; the caller resolves the note scope and runs the engine op.
private struct FindReplaceSheet: View {
    let fieldNames: [String]
    let selectedCount: Int
    let onReplace: (
        _ find: String, _ replacement: String, _ regex: Bool,
        _ matchCase: Bool, _ fieldName: String?, _ onlySelected: Bool
    ) -> Void
    let onCancel: () -> Void

    @State private var find = ""
    @State private var replacement = ""
    @State private var regex = false
    @State private var matchCase = false
    /// Empty tag = "All fields"; otherwise the chosen field name.
    @State private var fieldSelection = ""
    @State private var onlySelected: Bool

    init(
        fieldNames: [String],
        selectedCount: Int,
        onReplace: @escaping (String, String, Bool, Bool, String?, Bool) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.fieldNames = fieldNames
        self.selectedCount = selectedCount
        self.onReplace = onReplace
        self.onCancel = onCancel
        // Default to the selection when there is one (AnkiDroid's default scope).
        _onlySelected = State(initialValue: selectedCount > 0)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Find", text: $find)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    TextField("Replace with", text: $replacement)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }

                Section {
                    Toggle(Loc.tr("browsing-treat-input-as-regular-expression"), isOn: $regex)
                    Toggle("Match case", isOn: $matchCase)
                    Picker("In", selection: $fieldSelection) {
                        Text("All fields").tag("")
                        ForEach(fieldNames, id: \.self) { name in
                            Text(name).tag(name)
                        }
                    }
                }

                Section {
                    if selectedCount > 0 {
                        Toggle("Only selected notes (\(selectedCount))", isOn: $onlySelected)
                    } else {
                        Text("Applies to all notes matching the current search.")
                            .font(DS.Typography.caption)
                            .foregroundStyle(DS.textSecondary)
                    }
                } footer: {
                    Text("Find & Replace runs over the chosen notes' fields and is undoable.")
                }
            }
            .navigationTitle(Loc.tr("browsing-find-and-replace"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(Loc.tr("actions-cancel")) { onCancel() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Replace") {
                        onReplace(
                            find, replacement, regex, matchCase,
                            fieldSelection.isEmpty ? nil : fieldSelection, onlySelected
                        )
                    }
                    .disabled(find.isEmpty)
                }
            }
        }
    }
}

/// The browser's read-only card Preview (Anki's browser Preview): the card's
/// rendered front/back shown in the reviewer's exact styling via `CardWebView`,
/// with a button to flip between sides. No grading and no scheduling — it reuses
/// only the render path, never the review loop. The card is rendered off-main
/// via the store; a spinner shows until it lands.
private struct CardPreviewSheet: View {
    @ObservedObject var store: AnkiStore
    let cardID: Int64

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss

    /// The rendered card (question/answer/CSS/ordinal); nil until loaded.
    @State private var preview: CardPreviewContent?
    /// Which side is showing (false = front/question, true = back/answer).
    @State private var showingBack = false

    var body: some View {
        NavigationStack {
            ZStack {
                DS.background.ignoresSafeArea()
                if let preview {
                    VStack(spacing: 0) {
                        CardWebView(
                            html: showingBack ? preview.answer : preview.question,
                            css: preview.css,
                            ordinal: preview.ordinal,
                            isDark: colorScheme == .dark,
                            mediaFolder: store.mediaFolderURL
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        Divider()
                        Button {
                            showingBack.toggle()
                        } label: {
                            Text(showingBack ? "Show Front" : "Show Back")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.dsPrimary)
                        .padding()
                    }
                } else {
                    ProgressView("Loading…")
                        .font(DS.Typography.caption)
                        .foregroundStyle(DS.textSecondary)
                }
            }
            .navigationTitle(Loc.tr("actions-preview"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                // Segmented Front/Back control, mirroring desktop's Preview
                // header — a second way to flip besides the bottom button.
                ToolbarItem(placement: .principal) {
                    if preview != nil {
                        Picker("Side", selection: $showingBack) {
                            Text(Loc.tr("notetypes-front-field")).tag(false)
                            Text(Loc.tr("notetypes-back-field")).tag(true)
                        }
                        .pickerStyle(.segmented)
                        .frame(maxWidth: 200)
                    }
                }
            }
            .task { preview = await store.cardPreview(cardID: cardID) }
        }
    }
}

/// The browser's filter sidebar as a phone-appropriate presented sheet — the
/// mobile form of AnkiDroid/desktop's browser sidebar. Sections for Saved
/// Searches, Decks, Tags, Flags, Card State, and Today; tapping an item sets the
/// browser search to the matching Anki term (e.g. `deck:"X"`, `tag:"Y"`,
/// `flag:1`, `is:suspended`, `added:1`), the default single-click behaviour.
/// A "Save Search" action stores the current search as a named saved search.
///
/// Decks and Tags render as collapsible outline trees (native `DisclosureGroup`
/// rows): the deck hierarchy from the engine's deck tree, and a tag hierarchy
/// rebuilt from the flat `a::b::c` tag strings. Each node's expand/collapse
/// state persists per node (keyed by deck id / tag path in `UserDefaults` via
/// `@AppStorage`), so reopening the browser remembers what was expanded; the
/// node matching the current search is highlighted.
///
/// Takes plain data + closures (no model), so it stays a pure, previewable view.
private struct BrowserSidebarSheet: View {
    /// The full deck hierarchy (with counts), rebuilt into an outline tree.
    let deckTree: [DeckTreeEntry]
    let tags: [String]
    let savedSearches: [SavedSearch]
    /// The browser's current search string, used to highlight the active node.
    let activeQuery: String
    /// Called with the chosen Anki search term (the caller sets it as the query).
    let onApply: (String) -> Void
    /// Called to save the current search (the caller prompts for a name).
    let onSaveCurrent: () -> Void
    let onDismiss: () -> Void

    /// The deck outline, re-nested from the flat engine tree. Recomputed on
    /// render — cheap for the deck counts a collection realistically has.
    private var deckNodes: [SidebarDeckNode] { SidebarDeckNode.buildTree(from: deckTree) }
    /// The tag outline, rebuilt from the flat `::`-separated tag strings.
    private var tagNodes: [SidebarTagNode] { SidebarTagNode.buildTree(from: tags) }

    var body: some View {
        NavigationStack {
            ZStack {
                DS.background.ignoresSafeArea()
                List {
                    savedSearchesSection
                    decksSection
                    tagsSection
                    flagsSection
                    cardStateSection
                    todaySection
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("Filters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { onDismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save Search") { onSaveCurrent() }
                }
            }
        }
    }

    // MARK: Sections

    @ViewBuilder
    private var savedSearchesSection: some View {
        Section(Loc.tr("browsing-sidebar-saved-searches")) {
            if savedSearches.isEmpty {
                Text("Save the current search with “Save Search”.")
                    .font(DS.Typography.caption)
                    .foregroundStyle(DS.textSecondary)
            } else {
                ForEach(savedSearches) { saved in
                    filterRow(saved.name, systemImage: "bookmark",
                              isActive: saved.query == activeQuery) { onApply(saved.query) }
                }
            }
        }
    }

    /// The Decks outline: top-level decks expand (by default) to reveal their
    /// subdecks, each a `DisclosureGroup` whose expansion persists per deck id.
    @ViewBuilder
    private var decksSection: some View {
        if !deckNodes.isEmpty {
            Section(Loc.tr("browsing-sidebar-decks")) {
                ForEach(deckNodes) { node in
                    SidebarDeckRow(
                        node: node, activeQuery: activeQuery,
                        defaultExpanded: true, onApply: onApply
                    )
                }
            }
        }
    }

    /// The Tags outline: a "No tags" shortcut, then the hierarchy rebuilt from
    /// the flat `::`-separated tag strings. A parent tag applies a subtree query
    /// (`tag:x::*`); a leaf an exact `tag:x`. Expansion persists per tag path.
    @ViewBuilder
    private var tagsSection: some View {
        Section(Loc.tr("browsing-sidebar-tags")) {
            filterRow("No tags", systemImage: "tag.slash",
                      isActive: activeQuery == "tag:none") { onApply("tag:none") }
            ForEach(tagNodes) { node in
                SidebarTagRow(
                    node: node, activeQuery: activeQuery,
                    defaultExpanded: true, onApply: onApply
                )
            }
        }
    }

    private var flagsSection: some View {
        Section(Loc.tr("browsing-sidebar-flags")) {
            ForEach(CardFlag.allCases) { flag in
                let term = "flag:\(flag.rawValue)"
                filterRow(
                    flag.label,
                    systemImage: flag == .none ? "flag.slash" : "flag.fill",
                    iconColor: flag.color ?? DS.textSecondary,
                    isActive: term == activeQuery
                ) { onApply(term) }
            }
        }
    }

    private var cardStateSection: some View {
        Section(Loc.tr("browsing-sidebar-card-state")) {
            filterRow(Loc.tr("actions-new"), systemImage: "sparkles",
                      isActive: activeQuery == "is:new") { onApply("is:new") }
            filterRow(Loc.tr("scheduling-learning"), systemImage: "hourglass",
                      isActive: activeQuery == "is:learn") { onApply("is:learn") }
            filterRow(Loc.tr("browsing-sidebar-card-state-review"), systemImage: "checkmark.circle",
                      isActive: activeQuery == "is:review") { onApply("is:review") }
            filterRow(Loc.tr("browsing-sidebar-due-today"), systemImage: "calendar",
                      isActive: activeQuery == "is:due") { onApply("is:due") }
            filterRow(Loc.tr("browsing-suspended"), systemImage: "pause.circle",
                      isActive: activeQuery == "is:suspended") { onApply("is:suspended") }
            filterRow(Loc.tr("browsing-buried"), systemImage: "eye.slash",
                      isActive: activeQuery == "is:buried") { onApply("is:buried") }
        }
    }

    private var todaySection: some View {
        // "Added Today" / "Studied Today" have no matching catalog keys, so they
        // stay English; only the section header localizes.
        Section(Loc.tr("browsing-today")) {
            filterRow("Added Today", systemImage: "plus.square.on.square",
                      isActive: activeQuery == "added:1") { onApply("added:1") }
            filterRow("Studied Today", systemImage: "clock.arrow.circlepath",
                      isActive: activeQuery == "rated:1") { onApply("rated:1") }
        }
    }

    /// One tappable filter row (icon + label), with an optional active checkmark
    /// + tinted background when it matches the current search. Used by the fixed
    /// sections (saved searches, flags, card state, today); the deck/tag trees
    /// use their own recursive rows.
    private func filterRow(
        _ title: String, systemImage: String, iconColor: Color = DS.accent,
        isActive: Bool = false, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: DS.Spacing.m) {
                Image(systemName: systemImage)
                    .foregroundStyle(iconColor)
                    .frame(width: 24)
                Text(title)
                    .font(DS.Typography.body)
                    .foregroundStyle(DS.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                if isActive { SidebarActiveCheck() }
            }
            .frame(minHeight: DS.minTapTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(isActive ? DS.accent.opacity(0.15) : DS.surface)
    }
}

/// A trailing checkmark marking the sidebar row whose term is the active search.
private struct SidebarActiveCheck: View {
    var body: some View {
        Image(systemName: "checkmark")
            .font(.caption.weight(.bold))
            .foregroundStyle(DS.accent)
            .accessibilityLabel("Active filter")
    }
}

/// One node of the browser sidebar's Decks outline. A deck with subdecks is a
/// `DisclosureGroup` (its chevron expands/collapses; tapping the label applies
/// the deck filter); a leaf deck is a plain filter row. Expansion persists per
/// deck id via `@AppStorage`, so it's remembered across browser opens. New /
/// learning / review counts render on the right, like Anki's deck list.
private struct SidebarDeckRow: View {
    let node: SidebarDeckNode
    let activeQuery: String
    /// Default expansion when this node has never been toggled (top level opens).
    let defaultExpanded: Bool
    let onApply: (String) -> Void
    @AppStorage private var expanded: Bool

    init(
        node: SidebarDeckNode, activeQuery: String,
        defaultExpanded: Bool, onApply: @escaping (String) -> Void
    ) {
        self.node = node
        self.activeQuery = activeQuery
        self.defaultExpanded = defaultExpanded
        self.onApply = onApply
        _expanded = AppStorage(
            wrappedValue: defaultExpanded,
            "cardBrowser.sidebar.deckExpanded.\(node.id)"
        )
    }

    private var isActive: Bool { node.searchTerm == activeQuery }

    var body: some View {
        if node.hasChildren {
            DisclosureGroup(isExpanded: $expanded) {
                ForEach(node.children) { child in
                    SidebarDeckRow(
                        node: child, activeQuery: activeQuery,
                        defaultExpanded: false, onApply: onApply
                    )
                }
            } label: {
                label
            }
            .listRowBackground(isActive ? DS.accent.opacity(0.15) : DS.surface)
        } else {
            label
                .listRowBackground(isActive ? DS.accent.opacity(0.15) : DS.surface)
        }
    }

    private var label: some View {
        Button {
            onApply(node.searchTerm)
        } label: {
            HStack(spacing: DS.Spacing.m) {
                Image(systemName: node.filtered ? "line.3.horizontal.decrease.circle" : "rectangle.stack")
                    .foregroundStyle(node.filtered ? DS.good : DS.accent)
                    .frame(width: 24)
                Text(node.name)
                    .font(DS.Typography.body)
                    .foregroundStyle(node.filtered ? DS.good : DS.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: DS.Spacing.s)
                counts
                if isActive { SidebarActiveCheck() }
            }
            .frame(minHeight: DS.minTapTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// New / learning / review counts (muted at zero), mirroring the deck list.
    private var counts: some View {
        HStack(spacing: DS.Spacing.s) {
            countText(node.newCount, color: DS.accent)
            countText(node.learnCount, color: DS.again)
            countText(node.reviewCount, color: DS.easy)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(node.newCount) new, \(node.learnCount) learning, \(node.reviewCount) to review"
        )
    }

    private func countText(_ count: Int, color: Color) -> some View {
        Text("\(count)")
            .font(DS.Typography.caption)
            .monospacedDigit()
            .foregroundStyle(count == 0 ? DS.textSecondary : color)
    }
}

/// One node of the browser sidebar's Tags outline. A tag with children is a
/// `DisclosureGroup` applying a subtree filter (`tag:path::*`); a leaf applies
/// an exact `tag:path`. Expansion persists per tag path via `@AppStorage`.
private struct SidebarTagRow: View {
    let node: SidebarTagNode
    let activeQuery: String
    let defaultExpanded: Bool
    let onApply: (String) -> Void
    @AppStorage private var expanded: Bool

    init(
        node: SidebarTagNode, activeQuery: String,
        defaultExpanded: Bool, onApply: @escaping (String) -> Void
    ) {
        self.node = node
        self.activeQuery = activeQuery
        self.defaultExpanded = defaultExpanded
        self.onApply = onApply
        _expanded = AppStorage(
            wrappedValue: defaultExpanded,
            "cardBrowser.sidebar.tagExpanded.\(node.path)"
        )
    }

    private var isActive: Bool { node.searchTerm == activeQuery }

    var body: some View {
        if node.hasChildren {
            DisclosureGroup(isExpanded: $expanded) {
                ForEach(node.children) { child in
                    SidebarTagRow(
                        node: child, activeQuery: activeQuery,
                        defaultExpanded: false, onApply: onApply
                    )
                }
            } label: {
                label
            }
            .listRowBackground(isActive ? DS.accent.opacity(0.15) : DS.surface)
        } else {
            label
                .listRowBackground(isActive ? DS.accent.opacity(0.15) : DS.surface)
        }
    }

    private var label: some View {
        Button {
            onApply(node.searchTerm)
        } label: {
            HStack(spacing: DS.Spacing.m) {
                Image(systemName: node.hasChildren ? "tag.circle" : "tag")
                    .foregroundStyle(DS.accent)
                    .frame(width: 24)
                Text(node.name)
                    .font(DS.Typography.body)
                    .foregroundStyle(DS.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                if isActive { SidebarActiveCheck() }
            }
            .frame(minHeight: DS.minTapTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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

    /// Full, ordered list of matching *row* ids — card ids in cards mode, note
    /// ids in notes mode (see `mode`). Cheap to hold (just ids) even for tens of
    /// thousands of rows.
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

    // MARK: Configurable columns + sort (persisted)

    /// Every selectable column the engine offers (labels + sort capability),
    /// loaded once from `all_browser_columns`. Empty until loaded; the picker and
    /// sort menu read from it.
    @Published private(set) var availableColumns: [BrowserColumn] = []
    /// The active columns, in display order — the keys passed to the engine for
    /// each row's cells. Persisted in UserDefaults; defaults to question/answer/
    /// deck (the out-of-the-box AnkiDroid layout).
    @Published private(set) var activeColumnKeys: [String]
    /// The current sort (builtin column + direction). Persisted; defaults to the
    /// engine's sort-field-ascending. Re-running the search applies it.
    @Published private(set) var sort: BrowserSort
    /// Candidate field names for Find & Replace's "in field" picker (union over
    /// note types), loaded lazily.
    @Published private(set) var fieldNames: [String] = []
    /// Result banner after a Find & Replace run ("Updated N notes." or an empty-
    /// scope note); drives a short confirmation alert.
    @Published var findReplaceResult: String?

    /// Whether the browser lists one row per card (Anki's default) or one row
    /// per note — the Cards/Notes toggle. Persisted; changing it re-resolves the
    /// id list (cards vs notes) and clears the selection, which is keyed to the
    /// displayed id space. `cardIDs` then holds card ids or note ids accordingly.
    @Published private(set) var mode: BrowserMode

    // MARK: Filter sidebar (phone "Filters" panel)

    /// All tags in the collection, for the sidebar's Tags tree. Loaded lazily
    /// when the sidebar first opens.
    @Published private(set) var tags: [String] = []
    /// The full deck hierarchy (all decks incl. collapsed subdecks + filtered,
    /// with counts), for the sidebar's collapsible Decks tree. Loaded lazily.
    @Published private(set) var sidebarDeckTree: [DeckTreeEntry] = []
    /// The collection's saved searches, for the sidebar's Saved Searches
    /// section. Loaded lazily and refreshed after saving a new one.
    @Published private(set) var savedSearches: [SavedSearch] = []
    /// A transient error shown if saving the current search fails.
    @Published var saveSearchError: String?

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

    // UserDefaults keys for the persisted column set + sort choice + list mode.
    private static let columnsDefaultsKey = "cardBrowser.activeColumns"
    private static let sortColumnDefaultsKey = "cardBrowser.sortColumn"
    private static let sortReverseDefaultsKey = "cardBrowser.sortReverse"
    private static let modeDefaultsKey = "cardBrowser.mode"

    init(store: AnkiStore, initialQuery: String) {
        self.store = store
        self.query = initialQuery

        // Restore the persisted column set + sort, falling back to Anki's
        // defaults. Stored as plain keys/booleans so a schema-less restore is
        // safe; unknown column keys are pruned once the engine list loads.
        let defaults = UserDefaults.standard
        let savedColumns = defaults.stringArray(forKey: Self.columnsDefaultsKey) ?? []
        self.activeColumnKeys = savedColumns.isEmpty ? Backend.defaultBrowserColumns : savedColumns
        if let savedSortColumn = defaults.string(forKey: Self.sortColumnDefaultsKey),
           !savedSortColumn.isEmpty {
            self.sort = BrowserSort(
                column: savedSortColumn,
                reverse: defaults.bool(forKey: Self.sortReverseDefaultsKey)
            )
        } else {
            self.sort = .default
        }
        // Restore the persisted Cards/Notes mode (defaults to cards, Anki's
        // default). The engine's own notes-mode config is written to match on
        // the first row fetch, so the two never diverge.
        self.mode = BrowserMode(rawValue: defaults.string(forKey: Self.modeDefaultsKey) ?? "") ?? .cards
    }

    // MARK: Search

    /// Runs the initial search once, when the view first appears, and loads the
    /// engine's column/field metadata that the picker, sort menu, and Find &
    /// Replace draw from.
    func startIfNeeded() {
        guard !didStart else { return }
        didStart = true
        runSearch()
        loadMetadataIfNeeded()
    }

    // MARK: Configurable columns + sort

    /// Lazily loads the engine's full column list (for the picker + sort menu)
    /// and the field-name list (for Find & Replace). Prunes any persisted active
    /// column key the engine no longer recognizes so the row builder never asks
    /// for an invalid column.
    func loadMetadataIfNeeded() {
        if availableColumns.isEmpty {
            Task {
                let columns = await store.allBrowserColumns()
                guard !columns.isEmpty else { return }
                availableColumns = columns
                let known = Set(columns.map(\.key))
                let pruned = activeColumnKeys.filter { known.contains($0) }
                let resolved = pruned.isEmpty
                    ? Backend.defaultBrowserColumns.filter { known.contains($0) }
                    : pruned
                if resolved != activeColumnKeys, !resolved.isEmpty {
                    activeColumnKeys = resolved
                    persistColumns()
                    rowsByID = [:]
                    loadGeneration += 1
                }
            }
        }
        if fieldNames.isEmpty {
            Task { fieldNames = await store.browserFieldNames() }
        }
    }

    /// The active columns resolved to full metadata (label / sortable). Falls
    /// back to a humanized key when the engine list hasn't loaded yet, so rows
    /// still render sensible headers immediately on first open.
    var activeColumns: [BrowserColumn] {
        activeColumnKeys.map { key in
            availableColumns.first { $0.key == key }
                ?? BrowserColumn(key: key, label: Self.humanize(key), sortable: false, defaultReverse: false)
        }
    }

    /// The columns the sort menu offers (only engine-sortable ones). If the
    /// engine list hasn't loaded yet, expose at least the current sort column so
    /// the menu can still show/flip it.
    var sortMenuColumns: [BrowserColumn] {
        let sortable = availableColumns.filter(\.sortable)
        if sortable.isEmpty {
            return [BrowserColumn(
                key: sort.column, label: label(forColumnKey: sort.column),
                sortable: true, defaultReverse: sort.reverse
            )]
        }
        return sortable
    }

    /// The display label for a column key (engine label if loaded, else a
    /// humanized fallback).
    func label(forColumnKey key: String) -> String {
        availableColumns.first { $0.key == key }?.label ?? Self.humanize(key)
    }

    /// Applies a new active-column set (order + membership) from the picker:
    /// persists it, then drops cached rows and re-triggers loading so the new
    /// cells appear — no re-search needed, since the id list/order is unchanged.
    /// Always keeps at least one column (an empty row would be meaningless).
    func setActiveColumns(_ keys: [String]) {
        let cleaned = keys.isEmpty ? Backend.defaultBrowserColumns : keys
        guard cleaned != activeColumnKeys else { return }
        activeColumnKeys = cleaned
        persistColumns()
        // Invalidate any in-flight page loads, which fetched cells for the OLD
        // column set: bumping `searchSeq` makes their results be discarded so
        // they can't land afterward and populate rows whose cells no longer line
        // up with the new active columns. Clearing `loadingIDs` then lets the
        // fresh loads (re-triggered by the `loadGeneration` bump) run for the
        // on-screen rows. Re-using the search guard keeps the windowing intact;
        // the id list/order is unchanged, so no re-search is needed.
        searchSeq += 1
        loadingIDs.removeAll()
        rowsByID = [:]
        loadGeneration += 1
    }

    /// Applies a sort column (from the sort menu): tapping the current column
    /// flips its direction; tapping a different column switches to it in its
    /// natural default direction — matching desktop/AnkiDroid header-tap
    /// behavior. Persists the choice and re-runs the search (ids must be
    /// re-resolved in the new order), preserving the windowing + out-of-order
    /// guard inside `runSearch`.
    func applySort(columnKey: String) {
        if sort.column == columnKey {
            sort = BrowserSort(column: columnKey, reverse: !sort.reverse)
        } else {
            let reverse = availableColumns.first { $0.key == columnKey }?.defaultReverse ?? false
            sort = BrowserSort(column: columnKey, reverse: reverse)
        }
        persistSort()
        runSearch()
    }

    private func persistColumns() {
        UserDefaults.standard.set(activeColumnKeys, forKey: Self.columnsDefaultsKey)
    }

    private func persistSort() {
        UserDefaults.standard.set(sort.column, forKey: Self.sortColumnDefaultsKey)
        UserDefaults.standard.set(sort.reverse, forKey: Self.sortReverseDefaultsKey)
    }

    // MARK: Notes / Cards mode

    /// Switches the browser between Cards and Notes mode (AnkiDroid/desktop's
    /// browser toggle). The id space changes (cards ↔ notes), so this drops the
    /// selection and cached rows and re-runs the search to re-resolve the id
    /// list in the new mode; the engine's notes-mode config is written to match
    /// on the next row fetch. No-op when already in `newMode`.
    func setMode(_ newMode: BrowserMode) {
        guard newMode != mode else { return }
        mode = newMode
        UserDefaults.standard.set(newMode.rawValue, forKey: Self.modeDefaultsKey)
        // The selection is keyed to the old id space; clear it (and any select
        // mode) rather than carry stale ids across the switch.
        selection.removeAll()
        rowsByID = [:]
        runSearch()
    }

    /// The singular noun for the current mode ("card"/"note"), used in the
    /// row-count header and empty/selection copy so they read correctly in both
    /// modes.
    var itemNoun: String { mode == .notes ? "note" : "card" }

    // MARK: Mode-aware id resolution
    //
    // A row's `id` is a card id in cards mode and a note id in notes mode. The
    // helpers below map a row id (or the selection) to the id kind a given
    // backend op needs, so the per-row and bulk actions work identically in both
    // modes: card-level ops (suspend/flag/deck/bury) resolve to card ids;
    // note-level targets (editor / change-notetype) resolve to a note id.

    /// The note id for a row — the row id itself in notes mode, else resolved
    /// from the card. Used to open the editor / Change Note Type.
    func resolveNoteID(forRow rowID: Int64) async -> Int64? {
        mode == .notes ? rowID : await store.noteID(forCard: rowID)
    }

    /// A concrete card id for a row — the row id itself in cards mode, else the
    /// note's first card. Used for Preview and Card Info.
    func resolveCardID(forRow rowID: Int64) async -> Int64? {
        mode == .cards ? rowID : await store.firstCardID(ofNote: rowID)
    }

    /// The card ids for a set of row ids — the ids themselves in cards mode, else
    /// every card of the selected notes. Used by the card-level bulk/per-row ops.
    /// (Named `resolveCardIDs` to avoid colliding with the `cardIDs` property.)
    private func resolveCardIDs(forRows rowIDs: [Int64]) async -> [Int64] {
        mode == .cards ? rowIDs : await store.cardIDs(forNotes: rowIDs)
    }

    // MARK: Filter sidebar

    /// Loads the sidebar's data sources (tags, decks, saved searches) the first
    /// time the Filters panel is opened, then keeps them for the session. Each is
    /// best-effort, so a slow/failed source just shows an empty section.
    func loadSidebarIfNeeded() {
        if tags.isEmpty { Task { tags = await store.allTags() } }
        if sidebarDeckTree.isEmpty { Task { sidebarDeckTree = await store.browserDeckTree() } }
        Task { savedSearches = await store.savedSearches() }
    }

    /// Applies a sidebar search term (e.g. `deck:"Biology"`, `tag:"hard"`,
    /// `flag:1`, `is:suspended`) by replacing the query and searching — matching
    /// Anki's default sidebar click, which sets the search to the clicked item.
    func applySearch(_ term: String) {
        debounceTask?.cancel()
        query = term
        runSearch()
    }

    /// Saves the current search under `name` (Anki's "Save Current Search"),
    /// then refreshes the saved-search list. Surfaces a failure via
    /// `saveSearchError`.
    func saveCurrentSearch(name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let currentQuery = query
        Task {
            do {
                try await store.saveSearch(name: trimmed, query: currentQuery)
                savedSearches = await store.savedSearches()
            } catch {
                saveSearchError = describeBrowserError(error)
            }
        }
    }

    /// Turns a camelCase column key into a readable label ("cardDue" → "Card
    /// Due") as a fallback before the engine's localized labels load.
    private static func humanize(_ key: String) -> String {
        guard !key.isEmpty else { return key }
        var out = ""
        for (i, ch) in key.enumerated() {
            if i == 0 {
                out.append(Character(ch.uppercased()))
            } else if ch.isUppercase {
                out.append(" ")
                out.append(ch)
            } else {
                out.append(ch)
            }
        }
        return out
    }

    // MARK: Find & Replace

    /// Runs Find & Replace, resolving the note scope from the current selection
    /// (when `onlySelected` and a selection exists) or the whole current search
    /// (all matching notes), off-main. On success, refreshes the list so changed
    /// fields — and any re-ordering under a field-based sort — appear, and reports
    /// the number of notes changed.
    func runFindReplace(
        find: String, replacement: String, regex: Bool, matchCase: Bool,
        fieldName: String?, onlySelected: Bool
    ) {
        guard !find.isEmpty else { return }
        let currentQuery = query
        let selectionIDs = Array(selection)
        let currentMode = mode
        Task {
            do {
                let noteIDs: [Int64]
                if onlySelected, !selectionIDs.isEmpty {
                    // Selection rows are note ids in notes mode, card ids in cards
                    // mode; resolve to the note ids Find & Replace operates on.
                    noteIDs = currentMode == .notes
                        ? selectionIDs
                        : await store.noteIDs(forCards: selectionIDs)
                } else {
                    noteIDs = try await store.searchNotes(query: currentQuery)
                }
                guard !noteIDs.isEmpty else {
                    findReplaceResult = "No notes in scope."
                    return
                }
                let changed = try await store.findAndReplace(
                    noteIDs: noteIDs, search: find, replacement: replacement,
                    regex: regex, matchCase: matchCase, fieldName: fieldName
                )
                // Plain runtime string (shown via Text(String)), so pluralize
                // manually rather than with ^[…](inflect:) markup, which only the
                // LocalizedStringKey initializer would interpret.
                findReplaceResult = "Updated \(changed) note\(changed == 1 ? "" : "s")."
                refresh()
            } catch {
                actionError = describeBrowserError(error)
            }
        }
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
        let currentSort = sort
        let currentMode = mode
        loadingIDs.removeAll()
        if cardIDs.isEmpty { phase = .loading }
        Task {
            do {
                let ids = try await store.browserItemIDs(query: currentQuery, sort: currentSort, mode: currentMode)
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
        let columns = activeColumnKeys
        let currentMode = mode
        Task {
            let fetched = await store.browserRows(forIDs: pageIDs, columns: columns, mode: currentMode)
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

    /// Suspends/unsuspends a row's card(s), then reloads just that one row in
    /// place. In notes mode this toggles every card of the note (matching
    /// desktop, whose notes-mode row action applies to all the note's cards).
    func toggleSuspend(_ row: CardBrowserRow) {
        let rowID = row.id
        let suspended = row.suspended
        Task {
            do {
                let cardIDs = await resolveCardIDs(forRows: [rowID])
                try await store.setCardsSuspended(cardIDs, suspended: !suspended)
                reloadRow(cardID: rowID)
            } catch {
                actionError = describeBrowserError(error)
            }
        }
    }

    /// Sets/clears the flag on a row's card(s), then reloads just that one row in
    /// place. In notes mode this flags every card of the note.
    func setFlag(_ rowID: Int64, flag: Int) {
        Task {
            do {
                let cardIDs = await resolveCardIDs(forRows: [rowID])
                try await store.setFlag(cardIDs, flag: flag)
                reloadRow(cardID: rowID)
            } catch {
                actionError = describeBrowserError(error)
            }
        }
    }

    /// Deletes the note(s) behind a row and removes the affected rows in place —
    /// no re-search. In cards mode it removes the deleted note's cards (incl.
    /// siblings); in notes mode it removes exactly the deleted note row.
    func delete(_ row: CardBrowserRow) {
        let rowID = row.id
        let currentMode = mode
        Task {
            do {
                if currentMode == .notes {
                    _ = try await store.deleteNotes(noteIDs: [rowID])
                    removeCards([rowID])
                } else {
                    let removed = try await store.deleteNotes(forCards: [rowID])
                    removeCards(removed.isEmpty ? [rowID] : removed)
                }
            } catch {
                actionError = describeBrowserError(error)
            }
        }
    }

    /// Re-fetches a single row's data after a per-row mutation, updating just
    /// that row in place (or dropping it if the card vanished).
    private func reloadRow(cardID: Int64) {
        let seq = searchSeq
        let columns = activeColumnKeys
        let currentMode = mode
        Task {
            let fetched = await store.browserRows(forIDs: [cardID], columns: columns, mode: currentMode)
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
    /// Screenshot/automation hook: wait until the initial id list has loaded (so
    /// a screenshot of a mode/preview/sidebar demo has real rows behind it).
    func demoWaitForIDsForScreenshot() async {
        for _ in 0..<60 {
            if !cardIDs.isEmpty { break }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    /// Screenshot/automation hook: wait for the initial id list to load, then
    /// enter multi-select with the first few rows selected so a screenshot
    /// captures the selection UI and the bottom action bar. Debug-only.
    func demoEnterSelectionForScreenshot() async {
        await demoWaitForIDsForScreenshot()
        isSelecting = true
        selection = Set(cardIDs.prefix(3))
    }

    /// Screenshot/automation hook: switch to Notes mode once rows have loaded.
    func demoEnterNotesModeForScreenshot() async {
        await demoWaitForIDsForScreenshot()
        setMode(.notes)
        await demoWaitForIDsForScreenshot()
    }

    /// Screenshot/automation hook: load the sidebar's data sources and wait
    /// briefly so the presented Filters panel shows real decks/tags/saved.
    func demoLoadSidebarForScreenshot() async {
        loadSidebarIfNeeded()
        tags = await store.allTags()
        sidebarDeckTree = await store.browserDeckTree()
        savedSearches = await store.savedSearches()
    }

    /// Screenshot/automation hook: wait until the engine's column list (and the
    /// F&R field names) have loaded, so the column picker / Find & Replace sheet
    /// captures real content.
    func demoWaitForMetadataForScreenshot() async {
        for _ in 0..<60 {
            if !availableColumns.isEmpty { break }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        if fieldNames.isEmpty { fieldNames = await store.browserFieldNames() }
    }

    /// Screenshot/automation hook: configure a richer column set so the row
    /// layout shows its N-column (labeled-line) form. Prefers columns (by their
    /// localized label) that have visible content for fresh cards, falling back
    /// to appending any extra columns.
    func demoApplyRichColumnsForScreenshot() async {
        await demoWaitForMetadataForScreenshot()
        let preferredLabels = ["Question", "Answer", "Deck", "Due", "Note Type", "Created", "Tags"]
        var keys: [String] = []
        for label in preferredLabels {
            if let column = availableColumns.first(where: { $0.label == label }),
               !keys.contains(column.key) {
                keys.append(column.key)
            }
            if keys.count >= 5 { break }
        }
        if keys.count < 3 {
            keys = activeColumnKeys
            for column in availableColumns where !keys.contains(column.key) {
                keys.append(column.key)
                if keys.count >= 5 { break }
            }
        }
        setActiveColumns(Array(keys.prefix(5)))
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
        let currentMode = mode
        Task {
            do {
                if currentMode == .notes {
                    // Rows are note ids: delete them and drop exactly those rows.
                    _ = try await store.deleteNotes(noteIDs: ids)
                    removeCards(ids)
                } else {
                    let removed = try await store.deleteNotes(forCards: ids)
                    removeCards(removed.isEmpty ? ids : removed)
                }
                exitSelection()
            } catch {
                actionError = describeBrowserError(error)
            }
        }
    }

    /// Shared driver for the non-destructive bulk ops: resolve the selection to
    /// the card ids each op needs (in notes mode the selected note rows expand to
    /// their cards), run `op`, then reload the affected *rows* in place so their
    /// badges update, keeping the selection and select mode. Note-level ops
    /// (tags/marked) take card ids too and re-collapse to notes internally, so a
    /// single card-id resolution covers every bulk op.
    private func runBulk(_ op: @escaping ([Int64]) async throws -> Void) {
        let rowIDs = Array(selection)
        guard !rowIDs.isEmpty else { return }
        Task {
            do {
                let cardIDs = await resolveCardIDs(forRows: rowIDs)
                try await op(cardIDs)
                reloadRows(Set(rowIDs))
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

/// One results row, rendering the user's configured columns. The first column is
/// the prominent headline (the question by default, keeping question/answer
/// primary); the second renders unlabeled beneath it (the answer by default);
/// any further columns render as compact "LABEL value" lines so the extra data
/// stays scannable on a phone. Flag + suspended indicators are always shown
/// regardless of the column set. Mirrors AnkiDroid's browser row content.
private struct CardBrowserRowView: View {
    let row: CardBrowserRow
    /// The active columns (label + order), aligned 1:1 with `row.cells`.
    let columns: [BrowserColumn]

    var body: some View {
        HStack(spacing: DS.Spacing.m) {
            VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                // Primary line: first column, prominent, with the suspended badge.
                HStack(spacing: DS.Spacing.s) {
                    Text(primaryText)
                        .font(DS.Typography.body.weight(.semibold))
                        .foregroundStyle(DS.textPrimary)
                        .lineLimit(2)
                        .truncationMode(.tail)
                    if row.suspended {
                        suspendedBadge
                    }
                }

                // Second column: unlabeled secondary line (the answer by default).
                if columns.count > 1, !row.cell(1).isEmpty {
                    Text(row.cell(1))
                        .font(DS.Typography.caption)
                        .foregroundStyle(DS.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                // Remaining columns: compact labeled lines, skipping empties.
                ForEach(extraColumnIndices, id: \.self) { index in
                    if !row.cell(index).isEmpty {
                        HStack(spacing: DS.Spacing.xs) {
                            Text(columns[index].label.uppercased())
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(DS.textSecondary)
                            Text(row.cell(index))
                                .font(DS.Typography.caption)
                                .foregroundStyle(DS.textSecondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
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

    /// The headline (first column) text, or a placeholder when empty.
    private var primaryText: String {
        let first = row.cell(0)
        return first.isEmpty ? "(empty)" : first
    }

    /// Column indices rendered as labeled lines (everything past the first two).
    private var extraColumnIndices: [Int] {
        guard columns.count > 2 else { return [] }
        return Array(2..<columns.count)
    }

    private var suspendedBadge: some View {
        Text(Loc.tr("browsing-suspended"))
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
        var parts: [String] = []
        for (index, column) in columns.enumerated() {
            let value = row.cell(index)
            guard !value.isEmpty else { continue }
            parts.append(index == 0 ? value : "\(column.label) \(value)")
        }
        if parts.isEmpty { parts.append("(empty)") }
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
