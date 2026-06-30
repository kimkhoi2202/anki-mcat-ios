import SwiftUI
import AnkiKit

/// Card Browser — a native SwiftUI clone of AnkiDroid's CardBrowser.
///
/// A search field (Anki search syntax) over a results list; each row shows a
/// question/answer snippet, the deck, and flag / suspended indicators. Tapping a
/// row edits the card's note (reusing `NoteEditorView` in EDIT mode); swipe or
/// long-press expose Suspend/Unsuspend, Flag, and Delete actions, and the list
/// refreshes after any edit or action.
///
/// Scope (T2.2): search + results + tap-to-edit + suspend/flag/delete. No column
/// customization, saved searches, multi-select, or preview pane.
@MainActor
struct CardBrowserView: View {
    @ObservedObject var store: AnkiStore

    @State private var query: String
    @State private var rows: [CardBrowserRow] = []
    @State private var phase: LoadPhase = .loading
    @State private var editTarget: EditTarget?
    @State private var infoTarget: CardTarget?
    @State private var changeTypeTarget: NoteTarget?
    @State private var pendingDelete: CardBrowserRow?
    @State private var actionError: String?
    /// Guards against out-of-order results when searches overlap: only the most
    /// recent search's results are applied.
    @State private var searchSeq = 0

    /// Opens the browser with an initial query (empty = all cards, matching
    /// AnkiDroid's default "show everything" browse).
    init(store: AnkiStore, initialQuery: String = "") {
        self.store = store
        _query = State(initialValue: initialQuery)
    }

    private enum LoadPhase: Equatable {
        case loading
        case loaded
        case failed(String)
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
        .navigationTitle("Browse")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(
            text: $query,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: "Search (e.g. deck:Biology, tag:hard)"
        )
        .autocorrectionDisabled()
        .textInputAutocapitalization(.never)
        .onSubmit(of: .search) { runSearch() }
        .task {
            // Initial load (the view's `.task` runs once on appear).
            if rows.isEmpty, phase == .loading { runSearch() }
        }
        .sheet(item: $editTarget) { target in
            NoteEditorView(store: store, mode: .edit(noteID: target.id)) {
                runSearch()
            }
        }
        .sheet(item: $infoTarget) { target in
            CardInfoView(store: store, cardID: target.id)
        }
        .sheet(item: $changeTypeTarget) { target in
            ChangeNotetypeView(store: store, noteID: target.id) {
                runSearch()
            }
        }
        .confirmationDialog(
            "Delete note?",
            isPresented: deleteDialogPresented,
            titleVisibility: .visible,
            presenting: pendingDelete
        ) { row in
            Button("Delete", role: .destructive) {
                perform { try store.deleteNotes(forCards: [row.id]) }
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: { _ in
            // remove_notes deletes the note behind the card (and its siblings);
            // it records an undo entry, mirroring AnkiDroid's delete.
            Text("This deletes the note and all its cards. You can undo it from the reviewer.")
        }
        .alert("Action failed", isPresented: errorPresented) {
            Button("OK", role: .cancel) { actionError = nil }
        } message: {
            Text(actionError ?? "")
        }
    }

    // MARK: - Content states

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .loading:
            loadingState
        case .failed(let message):
            failedState(message)
        case .loaded:
            if rows.isEmpty {
                emptyState
            } else {
                resultsList
            }
        }
    }

    private var resultsList: some View {
        List {
            Section {
                ForEach(rows) { row in
                    Button {
                        editTarget = EditTarget(id: row.noteID)
                    } label: {
                        CardBrowserRowView(row: row)
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(DS.surface)
                    .listRowSeparatorTint(DS.separator)
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            pendingDelete = row
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                        Button {
                            toggleSuspend(row)
                        } label: {
                            Label(
                                row.suspended ? "Unsuspend" : "Suspend",
                                systemImage: row.suspended ? "play.fill" : "pause.fill"
                            )
                        }
                        .tint(DS.hard)
                    }
                    .contextMenu { rowMenu(row) }
                }
            } header: {
                Text("^[\(rows.count) card](inflect: true)")
                    .font(DS.Typography.caption)
                    .foregroundStyle(DS.textSecondary)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(DS.background)
    }

    /// The shared long-press menu: card info, change note type, suspend toggle, a
    /// flag submenu, and delete.
    @ViewBuilder
    private func rowMenu(_ row: CardBrowserRow) -> some View {
        Button {
            infoTarget = CardTarget(id: row.id)
        } label: {
            Label("Card Info", systemImage: "info.circle")
        }

        Button {
            changeTypeTarget = NoteTarget(id: row.noteID)
        } label: {
            Label("Change Note Type", systemImage: "arrow.triangle.2.circlepath")
        }

        Divider()

        Button {
            toggleSuspend(row)
        } label: {
            Label(
                row.suspended ? "Unsuspend" : "Suspend",
                systemImage: row.suspended ? "play.fill" : "pause.fill"
            )
        }

        Menu {
            ForEach(CardFlag.allCases) { flag in
                Button {
                    perform { try store.setFlag([row.id], flag: flag.rawValue) }
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
            Text(query.isEmpty
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

    // MARK: - Actions

    private func runSearch() {
        searchSeq += 1
        let seq = searchSeq
        let currentQuery = query
        // Keep showing existing rows during a refresh; only show the full-screen
        // spinner on the very first load.
        if rows.isEmpty { phase = .loading }
        Task {
            do {
                let result = try await store.browserRows(query: currentQuery)
                guard seq == searchSeq else { return }
                rows = result
                phase = .loaded
            } catch {
                guard seq == searchSeq else { return }
                rows = []
                phase = .failed(describe(error))
            }
        }
    }

    private func toggleSuspend(_ row: CardBrowserRow) {
        perform { try store.setCardsSuspended([row.id], suspended: !row.suspended) }
    }

    /// Runs a mutating action, refreshing the list on success and surfacing a
    /// readable message on failure. Clears any pending delete confirmation.
    private func perform(_ work: () throws -> Void) {
        do {
            try work()
            pendingDelete = nil
            runSearch()
        } catch {
            pendingDelete = nil
            actionError = describe(error)
        }
    }

    // MARK: - Bindings & helpers

    private var deleteDialogPresented: Binding<Bool> {
        Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })
    }

    private var errorPresented: Binding<Bool> {
        Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })
    }

    /// Extracts a human-readable message from a thrown error, decoding the
    /// engine's protobuf `BackendError` when present (e.g. an invalid search).
    private func describe(_ error: Error) -> String {
        if case let AnkiError.backendError(data) = error,
           let backendError = try? Anki_Backend_BackendError(serializedBytes: data),
           !backendError.message.isEmpty {
            return backendError.message
        }
        return error.localizedDescription
    }
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
