import SwiftUI
import AnkiKit

/// What the editor is doing.
enum NoteEditorMode: Equatable {
    /// Create a new note, defaulting the target deck to `defaultDeckID`.
    case add(defaultDeckID: Int64)
    /// Edit the existing note with the given id (loaded via `getNote`).
    case edit(noteID: Int64)
}

/// Note add/edit screen — a native SwiftUI clone of AnkiDroid's NoteEditor.
///
/// One reusable screen serves both flows so the future Card Browser (T2.2) can
/// present it in EDIT mode:
/// - **ADD** — pick a notetype and a (non-filtered) deck, fill the labeled
///   fields and tags, then save via `addNote`.
/// - **EDIT** — load the note's notetype / fields / tags via `getNote`, edit the
///   fields and tags, then save via `updateNote`. The notetype is shown but
///   fixed (changing it is out of scope), and the deck picker is omitted because
///   a note's deck is per-card — deck moves belong to the card browser (T2.2).
///
/// Validation mirrors Anki: the first field must not be empty.
@MainActor
struct NoteEditorView: View {
    @ObservedObject var store: AnkiStore
    let mode: NoteEditorMode
    /// Invoked after a successful save so the presenting screen can refresh.
    var onSaved: () -> Void = {}

    @Environment(\.dismiss) private var dismiss
    @FocusState private var focusedField: Int?

    @State private var notetypes: [NotetypeOption] = []
    @State private var selectedNotetypeID: Int64 = 0
    @State private var fieldNames: [String] = []
    @State private var fieldValues: [String] = []
    @State private var tagsText = ""
    @State private var selectedDeckID: Int64 = 1
    @State private var errorMessage: String?
    @State private var didLoad = false

    var body: some View {
        NavigationStack {
            Form {
                notetypeSection
                if !isEditing {
                    deckSection
                }
                fieldsSection
                tagsSection
            }
            .scrollContentBackground(.hidden)
            .background(DS.background.ignoresSafeArea())
            .tint(DS.accent)
            .navigationTitle(isEditing ? "Edit Note" : "Add Note")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .fontWeight(.semibold)
                        .disabled(!didLoad || fieldNames.isEmpty)
                }
            }
            .alert(
                "Can’t save note",
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

    private var notetypeSection: some View {
        Section {
            Picker(selection: $selectedNotetypeID) {
                ForEach(notetypes) { notetype in
                    Text(notetype.name).tag(notetype.id)
                }
            } label: {
                rowLabel("Type")
            }
            // Changing a note's type (re-mapping fields) is out of scope for
            // T2.1, so in EDIT mode the type is shown but fixed.
            .disabled(isEditing)
            .onChange(of: selectedNotetypeID) { _ in
                if !isEditing { reloadFields(preservingValues: false) }
            }
        } header: {
            sectionHeader("Note type")
        }
    }

    private var deckSection: some View {
        Section {
            Picker(selection: $selectedDeckID) {
                ForEach(addableDecks) { deck in
                    Text(deck.fullName).tag(deck.id)
                }
            } label: {
                rowLabel("Deck")
            }
        } header: {
            sectionHeader("Deck")
        }
    }

    private var fieldsSection: some View {
        Section {
            if fieldNames.isEmpty {
                Text("This note type has no fields.")
                    .font(DS.Typography.body)
                    .foregroundStyle(DS.textSecondary)
            } else {
                ForEach(Array(fieldNames.enumerated()), id: \.offset) { index, name in
                    VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                        Text(name)
                            .font(DS.Typography.caption.weight(.semibold))
                            .foregroundStyle(DS.textSecondary)
                        TextField(name, text: fieldBinding(index), axis: .vertical)
                            .font(DS.Typography.body)
                            .foregroundStyle(DS.textPrimary)
                            .lineLimit(1...6)
                            .focused($focusedField, equals: index)
                    }
                    .padding(.vertical, DS.Spacing.xs)
                }
            }
        } header: {
            sectionHeader("Fields")
        } footer: {
            sectionFooter("The first field can’t be empty.")
        }
    }

    private var tagsSection: some View {
        Section {
            TextField("space-separated tags", text: $tagsText)
                .font(DS.Typography.body)
                .foregroundStyle(DS.textPrimary)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
        } header: {
            sectionHeader("Tags")
        }
    }

    // MARK: - Derived state

    private var isEditing: Bool {
        if case .edit = mode { return true }
        return false
    }

    /// Decks a new note can be added to — filtered/dynamic decks can't hold notes
    /// (matching AnkiDroid excluding dynamic decks from the add spinner).
    private var addableDecks: [DeckTreeEntry] {
        store.decks.filter { !$0.filtered }
    }

    private var firstFieldTrimmed: String {
        (fieldValues.first ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func fieldBinding(_ index: Int) -> Binding<String> {
        Binding(
            get: { index < fieldValues.count ? fieldValues[index] : "" },
            set: { if index < fieldValues.count { fieldValues[index] = $0 } }
        )
    }

    // MARK: - Loading

    /// Populates the form once, from the engine, based on the mode.
    private func loadIfNeeded() {
        guard !didLoad else { return }
        didLoad = true
        notetypes = store.availableNotetypes().map { NotetypeOption(id: $0.id, name: $0.name) }

        switch mode {
        case .add(let defaultDeckID):
            // Default to a "Basic" notetype when present, else the first one.
            selectedNotetypeID = (notetypes.first(where: { $0.name.hasPrefix("Basic") })
                ?? notetypes.first)?.id ?? 0
            // Default to the requested deck if it can hold notes, else the first
            // addable deck (falling back to the Default deck, id 1).
            selectedDeckID = addableDecks.contains(where: { $0.id == defaultDeckID })
                ? defaultDeckID
                : (addableDecks.first?.id ?? 1)
            reloadFields(preservingValues: false)

        case .edit(let noteID):
            guard let note = store.note(forEditing: noteID) else {
                errorMessage = "This note could no longer be loaded."
                return
            }
            selectedNotetypeID = note.notetypeID
            // Ensure the (fixed) notetype is present so the picker shows its name.
            if !notetypes.contains(where: { $0.id == note.notetypeID }) {
                notetypes.append(NotetypeOption(id: note.notetypeID, name: "Note type"))
            }
            var names = store.fieldNames(forNotetype: note.notetypeID)
            // Defensive fallback: if labels couldn't be loaded, synthesize them
            // so every stored field value is still editable.
            if names.isEmpty {
                names = (0..<note.fields.count).map { "Field \($0 + 1)" }
            }
            fieldNames = names
            fieldValues = aligned(note.fields, toCount: names.count)
            tagsText = note.tags.joined(separator: " ")
        }
    }

    /// Loads the selected notetype's field labels, resetting (ADD) or preserving
    /// (defensive) the current values to match the new field count.
    private func reloadFields(preservingValues: Bool) {
        let names = store.fieldNames(forNotetype: selectedNotetypeID)
        fieldNames = names
        fieldValues = preservingValues
            ? aligned(fieldValues, toCount: names.count)
            : Array(repeating: "", count: names.count)
    }

    /// Pads or truncates `values` so it has exactly `count` entries.
    private func aligned(_ values: [String], toCount count: Int) -> [String] {
        if values.count == count { return values }
        if values.count > count { return Array(values.prefix(count)) }
        return values + Array(repeating: "", count: count - values.count)
    }

    // MARK: - Saving

    private func save() {
        // Anki tags are whitespace-separated tokens.
        let tags = tagsText.split(whereSeparator: \.isWhitespace).map(String.init)

        // Mirror Anki's rule: the first field must not be empty.
        guard !firstFieldTrimmed.isEmpty else {
            errorMessage = "The first field is empty."
            focusedField = 0
            return
        }

        do {
            switch mode {
            case .add:
                try store.addNote(
                    notetypeID: selectedNotetypeID,
                    fields: fieldValues,
                    tags: tags,
                    deckID: selectedDeckID
                )
            case .edit(let noteID):
                try store.updateNote(noteID: noteID, fields: fieldValues, tags: tags)
            }
            onSaved()
            dismiss()
        } catch {
            errorMessage = describe(error)
        }
    }

    /// Extracts a human-readable message from a thrown error, decoding the
    /// engine's protobuf `BackendError` when present.
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

/// One notetype option for the picker. A small `Identifiable`/`Hashable` wrapper
/// so the `(id, name)` pairs from the engine can drive a SwiftUI `Picker`.
private struct NotetypeOption: Identifiable, Hashable {
    let id: Int64
    let name: String
}
