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
    /// The field index that currently holds (or should take) keyboard focus.
    /// Backed by plain state, not `@FocusState`, because fields are now
    /// `UITextView`-backed (``RichFieldView``) rather than SwiftUI `TextField`s.
    @State private var focusedField: Int?

    @State private var notetypes: [NotetypeOption] = []
    @State private var selectedNotetypeID: Int64 = 0
    @State private var fieldNames: [String] = []
    @State private var fieldValues: [String] = []
    /// Self-sizing heights for each field's editor, keyed by field index.
    @State private var fieldHeights: [Int: CGFloat] = [:]
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
            .task {
                loadIfNeeded()
                #if DEBUG
                runScreenshotHookIfRequested()
                #endif
            }
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
                        RichFieldView(
                            placeholder: name,
                            text: fieldBinding(index),
                            height: heightBinding(index),
                            isFocused: focusedField == index,
                            allFieldValues: { fieldValues },
                            onFocusChange: { focused in
                                if focused {
                                    focusedField = index
                                } else if focusedField == index {
                                    focusedField = nil
                                }
                            }
                        )
                        .frame(height: fieldHeights[index] ?? RichFieldView.minHeight)
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

    /// Self-sizing height for a field's editor, defaulting to the collapsed
    /// single-line height until ``RichFieldView`` measures its content.
    private func heightBinding(_ index: Int) -> Binding<CGFloat> {
        Binding(
            get: { fieldHeights[index] ?? RichFieldView.minHeight },
            set: { fieldHeights[index] = $0 }
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
            fieldHeights = [:]
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
        fieldHeights = [:]
    }

    /// Pads or truncates `values` so it has exactly `count` entries.
    private func aligned(_ values: [String], toCount count: Int) -> [String] {
        if values.count == count { return values }
        if values.count > count { return Array(values.prefix(count)) }
        return values + Array(repeating: "", count: count - values.count)
    }

    #if DEBUG
    /// Debug screenshot/automation hook: prefill and focus the first field so the
    /// formatting toolbar is captured above the keyboard. With `-demoFormatting`
    /// the field's coordinator then scripts a bold + cloze on appear. Mirrors the
    /// app's other `-startIn…` verification hooks; compiled out of release.
    private func runScreenshotHookIfRequested() {
        let arguments = ProcessInfo.processInfo.arguments
        let demo = arguments.contains("-demoFormatting")
        guard demo || arguments.contains("-focusFirstField") else { return }
        Task { @MainActor in
            // Let the sheet finish presenting (and the note-type onChange settle)
            // before seeding text / grabbing keyboard focus.
            try? await Task.sleep(nanoseconds: 400_000_000)
            // The demo variant seeds its own text in the field coordinator; the
            // plain focus variant prefills here so the toolbar shows over content.
            if !demo, !fieldValues.isEmpty {
                fieldValues[0] = FieldFormattingDemo.sentence
            }
            focusedField = 0
        }
    }
    #endif

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
