import SwiftUI
import AnkiKit

/// CSV / text import wizard — a native clone of Anki's "Import CSV" screen.
///
/// After a `.csv`/`.tsv`/`.txt` file is picked and copied to a temp path, the
/// engine's `get_csv_metadata` detects the delimiter, columns, preview rows, and
/// a default note-type + deck + field mapping. This screen shows that mapping and
/// lets the user adjust it before running `import_csv`:
///
/// - **File**: delimiter + "Allow HTML in fields" (changing the delimiter
///   re-reads the columns via the engine).
/// - **Import options**: the note type, target deck, how existing notes are
///   handled (Update / Preserve / Duplicate) and the match scope.
/// - **Field mapping**: one row per CSV column, each mapped to a field of the
///   note type, to **Tags**, or **Ignore** — with a preview of the column's
///   first value.
///
/// The import mutates the collection, so it runs inside the store's exclusive-op
/// gate, off the main actor; the add/updated/duplicate summary is reported back
/// to the presenting screen via `onImported`.
@MainActor
struct CSVImportView: View {
    @ObservedObject var store: AnkiStore
    /// The temp copy of the picked file (owned by the presenter, which removes it
    /// when this sheet is dismissed).
    let fileURL: URL
    /// Invoked with the import summary after a successful import.
    var onImported: (ImportResult) -> Void

    @Environment(\.dismiss) private var dismiss

    /// The working metadata, re-derived from the engine when the delimiter or
    /// note type changes (so the default mapping stays sensible).
    @State private var metadata: Anki_ImportExport_CsvMetadata
    @State private var notetypes: [NotetypeChoice] = []
    @State private var selectedNotetypeID: Int64 = 0
    @State private var selectedDeckID: Int64 = 1
    @State private var dupeResolution: Anki_ImportExport_CsvMetadata.DupeResolution = .update
    @State private var matchScope: Anki_ImportExport_CsvMetadata.MatchScope = .notetype
    @State private var isHTML = false
    /// Per-column target, encoded as a tag: `ignoreTag`, `tagsTag`, or a field
    /// index `>= 0`. Length equals the column count.
    @State private var columnTargets: [Int] = []
    /// Field names of the selected note type (the mapping picker's options).
    @State private var fieldNames: [String] = []

    @State private var importing = false
    @State private var errorMessage: String?
    @State private var didLoad = false

    /// Sentinels for the non-field column targets (kept out of the `0...` field
    /// index range used by real fields).
    private let ignoreTag = -1
    private let tagsTag = -2

    init(
        store: AnkiStore,
        fileURL: URL,
        metadata: Anki_ImportExport_CsvMetadata,
        onImported: @escaping (ImportResult) -> Void
    ) {
        self.store = store
        self.fileURL = fileURL
        self.onImported = onImported
        _metadata = State(initialValue: metadata)
    }

    var body: some View {
        NavigationStack {
            Form {
                fileSection
                optionsSection
                mappingSection
            }
            .scrollContentBackground(.hidden)
            .background(DS.background.ignoresSafeArea())
            .tint(DS.accent)
            .navigationTitle("Import CSV/Text")
            .navigationBarTitleDisplayMode(.inline)
            .disabled(importing)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Import") { runImport() }
                        .fontWeight(.semibold)
                        .disabled(importing || columnCount == 0)
                }
            }
            .overlay { busyOverlay }
            .alert(
                "Couldn’t import",
                isPresented: Binding(
                    get: { errorMessage != nil },
                    set: { if !$0 { errorMessage = nil } }
                )
            ) {
                Button("OK", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
            .task { loadIfNeeded() }
        }
    }

    // MARK: - Sections

    private var fileSection: some View {
        Section {
            Picker(selection: delimiterBinding) {
                ForEach(Self.delimiterChoices, id: \.value) { choice in
                    Text(choice.label).tag(choice.value)
                }
            } label: {
                rowLabel("Delimiter")
            }

            Toggle("Allow HTML in fields", isOn: $isHTML)
                .font(DS.Typography.body)
                .foregroundStyle(DS.textPrimary)
        } header: {
            sectionHeader("File")
        } footer: {
            sectionFooter("\(columnCount) column\(columnCount == 1 ? "" : "s") detected. HTML keeps formatting and media tags in fields rather than escaping them.")
        }
    }

    private var optionsSection: some View {
        Section {
            Picker(selection: notetypeBinding) {
                ForEach(notetypes) { option in
                    Text(option.name).tag(option.id)
                }
            } label: {
                rowLabel("Note type")
            }

            Picker(selection: $selectedDeckID) {
                ForEach(store.decks, id: \.id) { deck in
                    Text(deck.fullName).tag(deck.id)
                }
            } label: {
                rowLabel("Deck")
            }

            Picker(selection: $dupeResolution) {
                Text("Update existing").tag(Anki_ImportExport_CsvMetadata.DupeResolution.update)
                Text("Preserve existing").tag(Anki_ImportExport_CsvMetadata.DupeResolution.preserve)
                Text("Import as new").tag(Anki_ImportExport_CsvMetadata.DupeResolution.duplicate)
            } label: {
                rowLabel("Existing notes")
            }

            Picker(selection: $matchScope) {
                Text("Note type").tag(Anki_ImportExport_CsvMetadata.MatchScope.notetype)
                Text("Note type and deck").tag(Anki_ImportExport_CsvMetadata.MatchScope.notetypeAndDeck)
            } label: {
                rowLabel("Match scope")
            }
        } header: {
            sectionHeader("Import options")
        } footer: {
            sectionFooter("Duplicates are matched on the first field, within the chosen scope.")
        }
    }

    private var mappingSection: some View {
        Section {
            ForEach(Array(0..<columnCount), id: \.self) { column in
                VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                    HStack {
                        Text(columnTitle(column))
                            .font(DS.Typography.body)
                            .foregroundStyle(DS.textPrimary)
                        Spacer()
                        Picker("", selection: targetBinding(column)) {
                            ForEach(Array(fieldNames.enumerated()), id: \.offset) { index, name in
                                Text(name).tag(index)
                            }
                            Text("Tags").tag(tagsTag)
                            Text("Ignore").tag(ignoreTag)
                        }
                        .labelsHidden()
                    }
                    if let sample = previewValue(column), !sample.isEmpty {
                        Text(sample)
                            .font(DS.Typography.caption)
                            .foregroundStyle(DS.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .accessibilityLabel("Sample: \(sample)")
                    }
                }
                .padding(.vertical, DS.Spacing.xs)
            }
        } header: {
            sectionHeader("Field mapping")
        } footer: {
            sectionFooter("Map each column to a field, to Tags, or Ignore it. The note type's first field must be mapped.")
        }
    }

    @ViewBuilder
    private var busyOverlay: some View {
        if importing {
            ZStack {
                Color.black.opacity(0.3).ignoresSafeArea()
                VStack(spacing: DS.Spacing.m) {
                    ProgressView()
                    Text("Importing…")
                        .font(DS.Typography.body)
                        .foregroundStyle(DS.textPrimary)
                }
                .dsCard()
                .fixedSize()
            }
            .transition(.opacity)
        }
    }

    // MARK: - Derived

    private var columnCount: Int { metadata.columnLabels.count }

    private func columnTitle(_ column: Int) -> String {
        let label = column < metadata.columnLabels.count ? metadata.columnLabels[column] : ""
        return label.isEmpty ? "Column \(column + 1)" : label
    }

    /// The first preview row's value for a column, shown as a sample under the
    /// mapping picker.
    private func previewValue(_ column: Int) -> String? {
        guard let firstRow = metadata.preview.first, column < firstRow.vals.count else { return nil }
        return firstRow.vals[column]
    }

    // MARK: - Bindings

    private var delimiterBinding: Binding<Anki_ImportExport_CsvMetadata.Delimiter> {
        Binding(
            get: { metadata.delimiter },
            set: { newValue in redrive(delimiter: newValue) }
        )
    }

    private var notetypeBinding: Binding<Int64> {
        Binding(
            get: { selectedNotetypeID },
            set: { newValue in
                selectedNotetypeID = newValue
                redrive(notetypeID: newValue)
            }
        )
    }

    private func targetBinding(_ column: Int) -> Binding<Int> {
        Binding(
            get: { column < columnTargets.count ? columnTargets[column] : ignoreTag },
            set: { if column < columnTargets.count { columnTargets[column] = $0 } }
        )
    }

    // MARK: - Loading & re-deriving

    private func loadIfNeeded() {
        guard !didLoad else { return }
        didLoad = true

        notetypes = store.availableNotetypes().map { NotetypeChoice(id: $0.id, name: $0.name) }
        isHTML = metadata.isHtml
        dupeResolution = metadata.dupeResolution
        matchScope = metadata.matchScope

        // Pick the note type: the engine's detected global note type if present,
        // else the first available.
        if case .globalNotetype(let mapped) = metadata.notetype, mapped.id != 0 {
            selectedNotetypeID = mapped.id
        } else {
            selectedNotetypeID = notetypes.first?.id ?? 0
        }
        // Pick the deck: the engine's detected deck id if present, else the
        // current study deck if it still exists, else the first deck.
        if case .deckID(let id) = metadata.deck, id != 0 {
            selectedDeckID = id
        } else if store.decks.contains(where: { $0.id == store.currentDeckID }) {
            selectedDeckID = store.currentDeckID
        } else {
            selectedDeckID = store.decks.first?.id ?? 1
        }

        refreshFieldsAndTargets()
    }

    /// Re-asks the engine for the default metadata/mapping when the delimiter or
    /// note type changes — Anki recomputes a sensible default field mapping in
    /// both cases. Preserves the user's other selections (deck, html).
    private func redrive(
        delimiter: Anki_ImportExport_CsvMetadata.Delimiter? = nil,
        notetypeID: Int64? = nil
    ) {
        let effectiveDelimiter = delimiter ?? metadata.delimiter
        let effectiveNotetype = notetypeID ?? selectedNotetypeID
        Task { @MainActor in
            do {
                let updated = try await store.recomputeCsvMetadata(
                    path: fileURL.path,
                    delimiter: effectiveDelimiter,
                    notetypeID: effectiveNotetype == 0 ? nil : effectiveNotetype,
                    deckID: selectedDeckID == 0 ? nil : selectedDeckID,
                    isHtml: isHTML
                )
                metadata = updated
                refreshFieldsAndTargets()
            } catch {
                errorMessage = describe(error)
            }
        }
    }

    /// Reloads the selected note type's field names and derives the per-column
    /// targets from the current metadata's default mapping.
    private func refreshFieldsAndTargets() {
        fieldNames = selectedNotetypeID == 0 ? [] : store.fieldNames(forNotetype: selectedNotetypeID)
        columnTargets = deriveTargets(from: metadata, fieldCount: fieldNames.count)
    }

    /// Builds the per-column targets from a metadata's `globalNotetype.fieldColumns`
    /// (field→column, one-based) and `tagsColumn`. Columns the engine didn't map
    /// default to Ignore.
    private func deriveTargets(
        from metadata: Anki_ImportExport_CsvMetadata, fieldCount: Int
    ) -> [Int] {
        let count = metadata.columnLabels.count
        var targets = Array(repeating: ignoreTag, count: count)
        if case .globalNotetype(let mapped) = metadata.notetype {
            for (fieldIndex, oneBasedColumn) in mapped.fieldColumns.enumerated()
            where fieldIndex < fieldCount {
                let column = Int(oneBasedColumn) - 1
                if column >= 0 && column < count { targets[column] = fieldIndex }
            }
        }
        let tagsColumn = Int(metadata.tagsColumn) - 1
        if tagsColumn >= 0 && tagsColumn < count { targets[tagsColumn] = tagsTag }
        return targets
    }

    // MARK: - Import

    /// Assembles the final `CsvMetadata` from the user's choices and runs the
    /// import. The column targets become the global note type's `fieldColumns`
    /// (field→column, one-based) plus the `tagsColumn`.
    private func runImport() {
        var toImport = metadata
        toImport.isHtml = isHTML
        toImport.dupeResolution = dupeResolution
        toImport.matchScope = matchScope
        toImport.deckID = selectedDeckID

        var mapped = Anki_ImportExport_CsvMetadata.MappedNotetype()
        mapped.id = selectedNotetypeID
        var fieldColumns = Array(repeating: UInt32(0), count: fieldNames.count)
        var tagsColumn: UInt32 = 0
        for (column, target) in columnTargets.enumerated() {
            if target >= 0 && target < fieldNames.count {
                fieldColumns[target] = UInt32(column + 1) // one-based
            } else if target == tagsTag {
                tagsColumn = UInt32(column + 1)
            }
        }
        mapped.fieldColumns = fieldColumns
        toImport.globalNotetype = mapped
        toImport.tagsColumn = tagsColumn

        importing = true
        Task { @MainActor in
            defer { importing = false }
            do {
                let result = try await store.importCsv(path: fileURL.path, metadata: toImport)
                onImported(result)
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

    /// The delimiters Anki's wizard offers, in the proto's order.
    private static let delimiterChoices: [(label: String, value: Anki_ImportExport_CsvMetadata.Delimiter)] = [
        ("Tab", .tab),
        ("Comma", .comma),
        ("Semicolon", .semicolon),
        ("Pipe", .pipe),
        ("Colon", .colon),
        ("Space", .space),
    ]
}

/// One note-type option for the wizard's picker (a small `Identifiable`/`Hashable`
/// wrapper over the engine's `(id, name)` pair).
private struct NotetypeChoice: Identifiable, Hashable {
    let id: Int64
    let name: String
}
