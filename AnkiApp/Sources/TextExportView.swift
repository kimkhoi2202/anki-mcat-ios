import SwiftUI
import AnkiKit

/// Notes / cards text (CSV) export options — a native clone of the text formats
/// in Anki's Export dialog ("Notes in Plain Text" / "Cards in Plain Text").
///
/// Pick what to export (notes or cards), the scope (whole collection or a single
/// deck), and the columns to include, then produce a tab-separated `.txt` handed
/// to the share sheet via `onExported`:
///
/// - **Notes** (`export_note_csv`): optional HTML, tags, deck, and note-type
///   columns.
/// - **Cards** (`export_card_csv`): each card's rendered question/answer, with an
///   optional HTML toggle.
///
/// The export holds the backend for the write, so it runs inside the store's
/// exclusive-op gate, off the main actor.
@MainActor
struct TextExportView: View {
    @ObservedObject var store: AnkiStore
    /// Pre-selected deck scope (the export screen's current deck), or `nil` for
    /// whole collection.
    let initialDeckID: Int64?
    /// Invoked with the produced file URL so the presenter can show the share sheet.
    var onExported: (URL) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var exportType: ExportType = .notes
    /// `nil` exports the whole collection; otherwise a specific deck.
    @State private var scopeDeckID: Int64?
    @State private var withHTML = false
    @State private var withTags = true
    @State private var withDeck = false
    @State private var withNotetype = false

    @State private var exporting = false
    @State private var errorMessage: String?
    @State private var didLoad = false

    /// What to export: notes (fields) or cards (rendered Q/A).
    private enum ExportType: Hashable {
        case notes
        case cards
    }

    init(store: AnkiStore, initialDeckID: Int64?, onExported: @escaping (URL) -> Void) {
        self.store = store
        self.initialDeckID = initialDeckID
        self.onExported = onExported
    }

    var body: some View {
        NavigationStack {
            Form {
                typeSection
                scopeSection
                includeSection
            }
            .scrollContentBackground(.hidden)
            .background(DS.background.ignoresSafeArea())
            .tint(DS.accent)
            .navigationTitle("Export Text")
            .navigationBarTitleDisplayMode(.inline)
            .disabled(exporting)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(Loc.tr("actions-cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(Loc.tr("actions-export")) { runExport() }
                        .fontWeight(.semibold)
                        .disabled(exporting)
                }
            }
            .overlay { busyOverlay }
            .alert(
                "Couldn’t export",
                isPresented: Binding(
                    get: { errorMessage != nil },
                    set: { if !$0 { errorMessage = nil } }
                )
            ) {
                Button("OK", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
            .task {
                if !didLoad {
                    didLoad = true
                    scopeDeckID = initialDeckID
                }
            }
        }
    }

    // MARK: - Sections

    private var typeSection: some View {
        Section {
            Picker(selection: $exportType) {
                Text(Loc.tr("browsing-notes")).tag(ExportType.notes)
                Text(Loc.tr("browsing-cards")).tag(ExportType.cards)
            } label: {
                rowLabel(Loc.tr("actions-export"))
            }
            .pickerStyle(.segmented)
        } header: {
            sectionHeader(Loc.tr("notetypes-type"))
        } footer: {
            sectionFooter(exportType == .notes
                ? "Exports each note's fields as a tab-separated row."
                : "Exports each card's rendered question and answer.")
        }
    }

    private var scopeSection: some View {
        Section {
            Picker(selection: $scopeDeckID) {
                Text("Whole collection").tag(Int64?.none)
                ForEach(store.decks, id: \.id) { deck in
                    Text(deck.fullName).tag(Optional(deck.id))
                }
            } label: {
                rowLabel("Scope")
            }
        } header: {
            sectionHeader("Scope")
        } footer: {
            sectionFooter("Choose the whole collection or limit the export to one deck.")
        }
    }

    @ViewBuilder
    private var includeSection: some View {
        Section {
            Toggle("Include HTML", isOn: $withHTML)
                .font(DS.Typography.body)
                .foregroundStyle(DS.textPrimary)

            if exportType == .notes {
                Toggle(Loc.tr("exporting-include-tags"), isOn: $withTags)
                    .font(DS.Typography.body)
                    .foregroundStyle(DS.textPrimary)
                Toggle("Include deck column", isOn: $withDeck)
                    .font(DS.Typography.body)
                    .foregroundStyle(DS.textPrimary)
                Toggle("Include note type column", isOn: $withNotetype)
                    .font(DS.Typography.body)
                    .foregroundStyle(DS.textPrimary)
            }
        } header: {
            sectionHeader("Include")
        } footer: {
            sectionFooter(exportType == .notes
                ? "HTML keeps field formatting; otherwise fields are plain text. Deck/note-type columns let the file be re-imported as the right type."
                : "HTML keeps the rendered card formatting; otherwise it's plain text.")
        }
    }

    @ViewBuilder
    private var busyOverlay: some View {
        if exporting {
            ZStack {
                Color.black.opacity(0.3).ignoresSafeArea()
                VStack(spacing: DS.Spacing.m) {
                    ProgressView()
                    Text("Exporting…")
                        .font(DS.Typography.body)
                        .foregroundStyle(DS.textPrimary)
                }
                .dsCard()
                .fixedSize()
            }
            .transition(.opacity)
        }
    }

    // MARK: - Export

    private func runExport() {
        let deckID = scopeDeckID
        let name = deckID.flatMap { id in store.decks.first(where: { $0.id == id })?.fullName } ?? "Export"
        let type = exportType
        let html = withHTML
        let tags = withTags
        let deck = withDeck
        let notetype = withNotetype
        exporting = true
        Task { @MainActor in
            defer { exporting = false }
            do {
                let url: URL
                switch type {
                case .notes:
                    url = try await store.exportNotesText(
                        deckID: deckID, name: name, withHTML: html,
                        withTags: tags, withDeck: deck, withNotetype: notetype
                    )
                case .cards:
                    url = try await store.exportCardsText(deckID: deckID, name: name, withHTML: html)
                }
                onExported(url)
                dismiss()
            } catch {
                errorMessage = describe(error)
            }
        }
    }

    private func describe(_ error: Error) -> String {
        if case let AnkiError.backendError(data) = error,
           let backendError = try? Anki_Backend_BackendError(serializedBytes: data),
           !backendError.message.isEmpty {
            return backendError.message
        }
        return error.localizedDescription
    }

    // MARK: - Small view helpers

    private func rowLabel(_ text: String) -> some View {
        Text(text)
            .font(DS.Typography.body)
            .foregroundStyle(DS.textPrimary)
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(DS.Typography.caption.weight(.semibold))
            .foregroundStyle(DS.textSecondary)
    }

    private func sectionFooter(_ text: String) -> some View {
        Text(text)
            .font(DS.Typography.caption)
            .foregroundStyle(DS.textSecondary)
    }
}
