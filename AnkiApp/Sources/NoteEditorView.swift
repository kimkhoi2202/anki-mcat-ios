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

    /// Sticky / pinned field indices (ADD mode): a pinned field keeps its value
    /// for the *next* note instead of being cleared, mirroring AnkiDroid's sticky
    /// fields (its pin/`toggleSticky` button). Session-scoped to this editor and
    /// reset when the notetype changes (a different field set); AnkiDroid persists
    /// per-notetype, which the task allows simplifying to session level.
    @State private var pinnedFields: Set<Int> = []

    /// Drives the "attach media" source chooser once a field's toolbar image/audio
    /// button is tapped (carries which field + caret to insert at).
    @State private var mediaSourceChoice: MediaSourceChoice?
    /// The concrete media picker currently presented as a sheet.
    @State private var activeMediaPicker: ActiveMediaPicker?
    /// True while picked/recorded bytes are being written into the collection.
    @State private var isStoringMedia = false
    /// A non-blocking media error (separate from the save-validation alert).
    @State private var mediaErrorMessage: String?

    /// Transient "note added" confirmation shown after an ADD-mode save while the
    /// editor stays open for the next note. Cleared after a short delay.
    @State private var addConfirmation: String?
    /// Guards the auto-dismiss of `addConfirmation` so rapid successive adds don't
    /// let an earlier timer clear a newer banner.
    @State private var addConfirmationToken = UUID()

    /// True when the selected note type is Image Occlusion, which swaps the raw
    /// field editors for the image-occlusion flow (pick an image → web editor to
    /// add, or "Edit Occlusions" → web editor to edit), mirroring AnkiDroid's
    /// NoteEditor. Recomputed whenever the note type is (re)loaded.
    @State private var isIONotetype = false
    /// Drives the image source chooser (Photo Library / Take Photo) for a new IO note.
    @State private var ioImageSourceShown = false
    /// The concrete IO image picker currently presented as a sheet.
    @State private var ioImageSource: IOImageSource?
    /// Presents the web image-occlusion editor (add on a picked image, or edit).
    @State private var imageOcclusionPresentation: ImageOcclusionPresentation?

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
                    // ADD mode keeps the editor open across saves, so the leading
                    // button is the explicit "finish" (Done); EDIT mode keeps the
                    // familiar discard-and-dismiss "Cancel".
                    Button(isEditing ? "Cancel" : "Done") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    // Image Occlusion notes are saved inside the web editor (its own
                    // Add/Save), so the note editor hides its save action for them.
                    if !isIONotetype {
                        Button(isEditing ? "Save" : "Add") { save() }
                            .fontWeight(.semibold)
                            .disabled(!didLoad || fieldNames.isEmpty)
                    }
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
            .alert(
                "Couldn’t attach media",
                isPresented: Binding(
                    get: { mediaErrorMessage != nil },
                    set: { if !$0 { mediaErrorMessage = nil } }
                )
            ) {
                Button("OK", role: .cancel) { mediaErrorMessage = nil }
            } message: {
                Text(mediaErrorMessage ?? "")
            }
            .confirmationDialog(
                mediaSourceChoice?.kind == .audio ? "Add Audio" : "Add Image",
                isPresented: Binding(
                    get: { mediaSourceChoice != nil },
                    set: { if !$0 { mediaSourceChoice = nil } }
                ),
                titleVisibility: .visible,
                presenting: mediaSourceChoice
            ) { choice in
                mediaSourceButtons(for: choice)
            }
            .sheet(item: $activeMediaPicker) { picker in
                mediaPickerView(for: picker)
            }
            // Image Occlusion add flow: choose an image source, then pick, then
            // open the web editor pointed at the picked image (mirrors AnkiDroid's
            // NoteEditor image-selection buttons → ImageOcclusion activity).
            .confirmationDialog(
                "Add Image Occlusion",
                isPresented: $ioImageSourceShown,
                titleVisibility: .visible
            ) {
                Button("Photo Library") { presentIOImagePicker(.photoLibrary) }
                if CameraPicker.isAvailable {
                    Button("Take Photo") { presentIOImagePicker(.camera) }
                }
                Button("Cancel", role: .cancel) {}
            }
            .sheet(item: $ioImageSource) { source in
                ioImagePickerView(for: source)
            }
            .sheet(item: $imageOcclusionPresentation) { presentation in
                imageOcclusionEditor(for: presentation)
            }
            .overlay(alignment: .top) { addConfirmationBanner }
            .animation(.easeInOut(duration: 0.2), value: addConfirmation)
            .overlay { if isStoringMedia { mediaProgressOverlay } }
            .task {
                loadIfNeeded()
                #if DEBUG
                runScreenshotHookIfRequested()
                #endif
            }
            // Refresh the note-type options when returning from the manager (a new
            // type may have been added). Only after the initial load, so it never
            // races `loadIfNeeded` on first appear.
            .onAppear {
                if didLoad { refreshNotetypeOptions() }
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
            // Jump to the note-type manager (add/clone/rename/delete, edit fields
            // and card templates). On return the picker's options are refreshed so
            // a newly added type is selectable.
            NavigationLink {
                ManageNotetypesView(store: store)
            } label: {
                Label("Manage note types…", systemImage: "square.stack.3d.up")
                    .font(DS.Typography.caption)
                    .foregroundStyle(DS.accent)
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
            if isIONotetype {
                imageOcclusionCTA
            } else if fieldNames.isEmpty {
                Text("This note type has no fields.")
                    .font(DS.Typography.body)
                    .foregroundStyle(DS.textSecondary)
            } else {
                ForEach(Array(fieldNames.enumerated()), id: \.offset) { index, name in
                    VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                        fieldHeader(name: name, index: index)
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
                            },
                            onRequestMedia: { kind, caret in
                                mediaSourceChoice = MediaSourceChoice(
                                    fieldIndex: index, caret: caret, kind: kind
                                )
                            }
                        )
                        .frame(height: fieldHeights[index] ?? RichFieldView.minHeight)
                    }
                    .padding(.vertical, DS.Spacing.xs)
                }
            }
        } header: {
            sectionHeader(isIONotetype ? "Image Occlusion" : "Fields")
        } footer: {
            if isIONotetype {
                sectionFooter(isEditing
                    ? "Edit the occlusion masks and note fields in the editor."
                    : "Pick an image, then draw occlusion masks in the editor.")
            } else {
                sectionFooter(isEditing
                    ? "The first field can’t be empty."
                    : "The first field can’t be empty. Pin a field to keep its value for the next note.")
            }
        }
    }

    /// A field's label row: its name plus, in ADD mode, a pin toggle that keeps
    /// the field's value for the next note (AnkiDroid's sticky field button).
    private func fieldHeader(name: String, index: Int) -> some View {
        HStack(spacing: DS.Spacing.s) {
            Text(name)
                .font(DS.Typography.caption.weight(.semibold))
                .foregroundStyle(DS.textSecondary)
            Spacer(minLength: 0)
            if !isEditing {
                let pinned = pinnedFields.contains(index)
                Button {
                    togglePin(index)
                } label: {
                    Image(systemName: pinned ? "pin.fill" : "pin")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(pinned ? DS.accent : DS.textSecondary)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(pinned ? "Unpin \(name)" : "Pin \(name)")
                .accessibilityAddTraits(pinned ? [.isSelected] : [])
            }
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

    // MARK: - Media UI

    /// Source options for the attach-media chooser: image → photo library /
    /// camera (camera only when present); audio → record / pick a file. Mirrors
    /// AnkiDroid's multimedia source choices.
    @ViewBuilder
    private func mediaSourceButtons(for choice: MediaSourceChoice) -> some View {
        switch choice.kind {
        case .image:
            Button("Photo Library") {
                presentPicker(.photoLibrary(fieldIndex: choice.fieldIndex, caret: choice.caret))
            }
            if CameraPicker.isAvailable {
                Button("Take Photo") {
                    presentPicker(.camera(fieldIndex: choice.fieldIndex, caret: choice.caret))
                }
            }
        case .audio:
            Button("Record Audio") {
                presentPicker(.audioRecorder(fieldIndex: choice.fieldIndex, caret: choice.caret))
            }
            Button("Choose File") {
                presentPicker(.audioFile(fieldIndex: choice.fieldIndex, caret: choice.caret))
            }
        }
        Button("Cancel", role: .cancel) {}
    }

    /// Presents the chosen picker just after the source dialog has dismissed —
    /// presenting a sheet straight from a confirmationDialog button can otherwise
    /// drop the sheet, so we defer briefly.
    private func presentPicker(_ picker: ActiveMediaPicker) {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 60_000_000)
            activeMediaPicker = picker
        }
    }

    /// Builds the concrete picker for the active media sheet, routing its result
    /// through `finishMedia`.
    @ViewBuilder
    private func mediaPickerView(for picker: ActiveMediaPicker) -> some View {
        switch picker {
        case let .photoLibrary(index, caret):
            PhotoLibraryPicker { media in
                finishMedia(media, kind: .image, fieldIndex: index, caret: caret)
            }
            .ignoresSafeArea()
        case let .camera(index, caret):
            CameraPicker { media in
                finishMedia(media, kind: .image, fieldIndex: index, caret: caret)
            }
            .ignoresSafeArea()
        case let .audioRecorder(index, caret):
            AudioRecorderView { media in
                finishMedia(media, kind: .audio, fieldIndex: index, caret: caret)
            }
        case let .audioFile(index, caret):
            AudioDocumentPicker { media in
                finishMedia(media, kind: .audio, fieldIndex: index, caret: caret)
            }
            .ignoresSafeArea()
        }
    }

    // MARK: - Image Occlusion UI

    /// Shown in place of the raw fields when an Image Occlusion note type is
    /// selected: an explanation plus the entry action — "Select Image" (add) or
    /// "Edit Occlusions" (edit) — that opens the web mask editor.
    @ViewBuilder
    private var imageOcclusionCTA: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.m) {
            Text("Image Occlusion hides parts of an image, revealed on the back.")
                .font(DS.Typography.body)
                .foregroundStyle(DS.textSecondary)
            if case .edit(let noteID) = mode {
                Button {
                    imageOcclusionPresentation = .edit(noteID: noteID)
                } label: {
                    Label("Edit Occlusions", systemImage: "rectangle.dashed")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            } else {
                Button {
                    ioImageSourceShown = true
                } label: {
                    Label("Select Image", systemImage: "photo.on.rectangle.angled")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(.vertical, DS.Spacing.xs)
    }

    /// Presents the chosen IO image picker just after the source dialog dismisses
    /// (same defer as `presentPicker`, so the sheet isn't dropped).
    private func presentIOImagePicker(_ source: IOImageSource) {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 60_000_000)
            ioImageSource = source
        }
    }

    /// Builds the concrete IO image picker; its result opens the web editor.
    @ViewBuilder
    private func ioImagePickerView(for source: IOImageSource) -> some View {
        switch source {
        case .photoLibrary:
            PhotoLibraryPicker { media in startImageOcclusionAdd(media) }
                .ignoresSafeArea()
        case .camera:
            CameraPicker { media in startImageOcclusionAdd(media) }
                .ignoresSafeArea()
        }
    }

    /// Builds the web image-occlusion editor for the active add/edit target.
    /// After a successful save the editor refreshes the presenting screen; for
    /// edit it also closes the note editor (back to wherever it was opened from).
    @ViewBuilder
    private func imageOcclusionEditor(for presentation: ImageOcclusionPresentation) -> some View {
        switch presentation {
        case .add(let url):
            ImageOcclusionView(
                store: store,
                mode: .add(imagePath: url.path),
                temporaryImageURL: url,
                onSaved: { onSaved() }
            )
        case .edit(let noteID):
            ImageOcclusionView(
                store: store,
                mode: .edit(noteID: noteID),
                onSaved: {
                    onSaved()
                    dismiss()
                }
            )
        }
    }

    /// Handles the IO image pick: dismiss the picker, write the bytes to a temp
    /// file, point the collection's current deck at the chosen deck (the engine
    /// adds IO notes to the current deck), then open the web editor on the image.
    private func startImageOcclusionAdd(_ media: PickedMedia?) {
        ioImageSource = nil
        guard let media else { return }
        guard let url = ImageOcclusionView.writeTemporaryImage(media) else {
            mediaErrorMessage = "Couldn’t prepare the image for occlusion."
            return
        }
        store.setCurrentDeck(selectedDeckID)
        // Let the picker sheet finish dismissing before presenting the editor
        // sheet, so the transition isn't dropped.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 350_000_000)
            imageOcclusionPresentation = .add(imageURL: url)
        }
    }

    /// The transient "note added" banner shown after an ADD-mode save, anchored
    /// at the top so it stays visible above the keyboard while the editor stays
    /// open for the next note.
    @ViewBuilder
    private var addConfirmationBanner: some View {
        if let addConfirmation {
            Label(addConfirmation, systemImage: "checkmark.circle.fill")
                .font(DS.Typography.body.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, DS.Spacing.l)
                .padding(.vertical, DS.Spacing.s)
                .background(Capsule().fill(DS.easy))
                .shadow(color: .black.opacity(0.15), radius: 6, y: 3)
                .padding(.top, DS.Spacing.s)
                .transition(.move(edge: .top).combined(with: .opacity))
                .allowsHitTesting(false)
        }
    }

    /// A lightweight modal spinner shown while picked media bytes are written
    /// into the collection (a large photo/clip can take a beat).
    private var mediaProgressOverlay: some View {
        ZStack {
            Color.black.opacity(0.2).ignoresSafeArea()
            ProgressView("Adding media…")
                .padding(DS.Spacing.l)
                .background(
                    RoundedRectangle(cornerRadius: DS.Radius.medium)
                        .fill(DS.surface)
                )
        }
        .allowsHitTesting(true)
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
            // An Image Occlusion note edits its masks/fields in the web editor
            // ("Edit Occlusions") rather than through the raw field inputs.
            isIONotetype = store.isImageOcclusionNotetype(note.notetypeID)
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

    /// Re-reads the available note types after returning from the manager, so a
    /// newly added/cloned type is selectable. Keeps the current selection when it
    /// still exists; if the selected type was deleted (ADD mode), falls back to
    /// the first available type and reloads its fields. EDIT mode keeps its fixed
    /// (possibly synthesized) type entry untouched.
    private func refreshNotetypeOptions() {
        guard !isEditing else { return }
        let latest = store.availableNotetypes().map { NotetypeOption(id: $0.id, name: $0.name) }
        guard !latest.isEmpty else { return }
        notetypes = latest
        if !latest.contains(where: { $0.id == selectedNotetypeID }) {
            selectedNotetypeID = latest.first?.id ?? selectedNotetypeID
            reloadFields(preservingValues: false)
        }
    }

    /// Loads the selected notetype's field labels, resetting (ADD) or preserving
    /// (defensive) the current values to match the new field count.
    private func reloadFields(preservingValues: Bool) {
        // An Image Occlusion type swaps the raw fields for the IO add flow.
        isIONotetype = store.isImageOcclusionNotetype(selectedNotetypeID)
        let names = store.fieldNames(forNotetype: selectedNotetypeID)
        fieldNames = names
        fieldValues = preservingValues
            ? aligned(fieldValues, toCount: names.count)
            : Array(repeating: "", count: names.count)
        fieldHeights = [:]
        // A reset means a new/changed notetype, so the old field indices no longer
        // map to the same fields — drop any sticky pins (AnkiDroid tracks sticky
        // per-notetype; clearing on switch keeps the session-level set coherent).
        if !preservingValues {
            pinnedFields = []
        }
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
    /// the field's coordinator then scripts a bold + cloze on appear. With
    /// `-demoEditorExtras` it seeds inserted media references, pins the first
    /// field, and shows the "note added" banner so the media/sticky/add-another
    /// additions are visible in one shot. Mirrors the app's other `-startIn…`
    /// verification hooks; compiled out of release.
    private func runScreenshotHookIfRequested() {
        let arguments = ProcessInfo.processInfo.arguments
        let demo = arguments.contains("-demoFormatting")
        let extras = arguments.contains("-demoEditorExtras")
        let mediaSource = arguments.contains("-demoMediaSource")
        let realMedia = arguments.contains("-demoInsertRealMedia")
        guard demo || extras || mediaSource || realMedia
            || arguments.contains("-focusFirstField") else { return }
        Task { @MainActor in
            // Let the sheet finish presenting (and the note-type onChange settle)
            // before seeding text / grabbing keyboard focus.
            try? await Task.sleep(nanoseconds: 400_000_000)
            if realMedia {
                // Exercise the *real* app-side media path end-to-end: store bytes
                // via the engine and insert the engine-returned name. The shown
                // `<img src="…">` proves store.addMediaFile + insertReference work
                // against the live collection (not just the AnkiKit unit test).
                let png = Data(base64Encoded:
                    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="
                )!
                await storeAndInsert(
                    PickedMedia(data: png, desiredName: "demo.png"),
                    kind: .image, fieldIndex: 0, caret: NSRange(location: 0, length: 0)
                )
                return
            }
            if mediaSource {
                // Surface the image source chooser (Photo Library / Take Photo)
                // for a screenshot of the media-attach affordance.
                mediaSourceChoice = MediaSourceChoice(
                    fieldIndex: 0, caret: NSRange(location: 0, length: 0), kind: .image
                )
                return
            }
            if extras {
                // Show media references in the fields, a pinned first field, and
                // the post-add confirmation banner together.
                if !fieldValues.isEmpty {
                    fieldValues[0] = "Bonjour <img src=\"hello.png\">"
                    pinnedFields.insert(0)
                }
                if fieldValues.count > 1 {
                    fieldValues[1] = "Hello [sound:hello.m4a]"
                }
                showAddConfirmation()
            } else if !demo, !fieldValues.isEmpty {
                // The plain focus variant prefills here so the toolbar shows over
                // content; the `-demoFormatting` variant seeds in the coordinator.
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
                onSaved()
                // Keep the editor open for rapid successive entry (AnkiDroid keeps
                // NoteEditor open on add): retain pinned fields + tags + notetype +
                // deck, clear the rest, refocus, and confirm.
                prepareForNextNote()
            case .edit(let noteID):
                try store.updateNote(noteID: noteID, fields: fieldValues, tags: tags)
                onSaved()
                dismiss()
            }
        } catch {
            errorMessage = describe(error)
        }
    }

    // MARK: - Sticky fields & add-another

    /// Toggles a field's sticky pin (ADD mode): pinned fields keep their value
    /// for the next note. Clone of AnkiDroid's per-field sticky toggle.
    private func togglePin(_ index: Int) {
        if pinnedFields.contains(index) {
            pinnedFields.remove(index)
        } else {
            pinnedFields.insert(index)
        }
    }

    /// After a successful ADD, resets the form for the next note while keeping the
    /// chosen notetype, deck, tags, and any pinned field values; refocuses the
    /// first field and shows a brief confirmation. Clone of AnkiDroid's
    /// `onNoteAdded` (refresh + restore sticky + "cards added" snackbar).
    private func prepareForNextNote() {
        for index in fieldValues.indices where !pinnedFields.contains(index) {
            fieldValues[index] = ""
        }
        fieldHeights = [:]
        showAddConfirmation()
        // Force a focus change even if the first field was already "focused"
        // (tapping Add resigned the keyboard), so it re-takes first responder.
        focusedField = nil
        Task { @MainActor in focusedField = 0 }
    }

    /// Shows the transient "note added" banner, auto-dismissing it after a beat.
    /// A per-show token means a newer add's banner isn't cleared by an older
    /// add's timer.
    private func showAddConfirmation() {
        addConfirmation = "Note added"
        let token = UUID()
        addConfirmationToken = token
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            if addConfirmationToken == token { addConfirmation = nil }
        }
    }

    // MARK: - Media insertion

    /// Handles a picker's result: dismiss the sheet, then (if media was produced)
    /// store it and insert the reference. Nil means the user cancelled.
    private func finishMedia(
        _ media: PickedMedia?, kind: RichFieldMediaKind, fieldIndex: Int, caret: NSRange
    ) {
        activeMediaPicker = nil
        guard let media else { return }
        Task { await storeAndInsert(media, kind: kind, fieldIndex: fieldIndex, caret: caret) }
    }

    /// Stores the bytes in the collection (engine-managed name + dedup), then
    /// inserts the resulting `<img>`/`[sound:]` reference at the saved caret.
    @MainActor
    private func storeAndInsert(
        _ media: PickedMedia, kind: RichFieldMediaKind, fieldIndex: Int, caret: NSRange
    ) async {
        isStoringMedia = true
        defer { isStoringMedia = false }
        do {
            let storedName = try await store.addMediaFile(
                data: media.data, desiredName: media.desiredName
            )
            insertReference(forStoredName: storedName, kind: kind, fieldIndex: fieldIndex, caret: caret)
        } catch {
            mediaErrorMessage = describe(error)
        }
    }

    /// Inserts the stored media reference into `fieldIndex` at `caret`, replacing
    /// any selected range. Images use `<img src="NAME">`, audio `[sound:NAME]` —
    /// the raw HTML/Anki markup fields store, matching the reviewer's renderer.
    private func insertReference(
        forStoredName name: String, kind: RichFieldMediaKind, fieldIndex: Int, caret: NSRange
    ) {
        guard fieldIndex < fieldValues.count else { return }
        let reference: String
        switch kind {
        case .image: reference = "<img src=\"\(htmlAttributeEscaped(name))\">"
        case .audio: reference = "[sound:\(name)]"
        }
        let current = fieldValues[fieldIndex] as NSString
        let safe = clampedRange(caret, to: current.length)
        fieldValues[fieldIndex] = current.replacingCharacters(in: safe, with: reference)
        // Let the field re-measure with the new content, then refocus it.
        fieldHeights[fieldIndex] = nil
        focusedField = fieldIndex
    }

    /// Escapes a filename for safe use inside an `src="…"` attribute. Engine names
    /// are already filesystem-sanitized; this is defensive against `&"<>`.
    private func htmlAttributeEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    /// Clamps an NSRange into `[0, length]` so a stale caret can't read out of
    /// bounds when inserting media into a field whose text changed.
    private func clampedRange(_ range: NSRange, to length: Int) -> NSRange {
        let location = min(max(range.location, 0), length)
        let extent = min(max(range.length, 0), length - location)
        return NSRange(location: location, length: extent)
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

/// A pending media attach request: which field and caret/selection the toolbar
/// button targeted, plus the kind of media, so the source chooser can route to
/// the right picker and the result is inserted back at the same spot.
private struct MediaSourceChoice: Identifiable {
    let id = UUID()
    let fieldIndex: Int
    let caret: NSRange
    let kind: RichFieldMediaKind
}

/// The image source for a new Image Occlusion note (drives its picker sheet).
private enum IOImageSource: Identifiable {
    case photoLibrary
    case camera
    var id: String { self == .photoLibrary ? "io-photo" : "io-camera" }
}

/// What the web image-occlusion editor is being opened for (drives its sheet):
/// a new note from a just-picked temporary image, or editing an existing note.
private enum ImageOcclusionPresentation: Identifiable {
    case add(imageURL: URL)
    case edit(noteID: Int64)

    var id: String {
        switch self {
        case .add(let url): return "io-add-\(url.path)"
        case .edit(let noteID): return "io-edit-\(noteID)"
        }
    }
}

/// The concrete media picker presented as a sheet, carrying the field + caret to
/// insert the stored reference at once the user finishes.
private enum ActiveMediaPicker: Identifiable {
    case photoLibrary(fieldIndex: Int, caret: NSRange)
    case camera(fieldIndex: Int, caret: NSRange)
    case audioRecorder(fieldIndex: Int, caret: NSRange)
    case audioFile(fieldIndex: Int, caret: NSRange)

    /// Stable identity for `.sheet(item:)` (case + target field + caret start).
    var id: String {
        switch self {
        case let .photoLibrary(index, caret): return "photo-\(index)-\(caret.location)"
        case let .camera(index, caret): return "camera-\(index)-\(caret.location)"
        case let .audioRecorder(index, caret): return "rec-\(index)-\(caret.location)"
        case let .audioFile(index, caret): return "audiofile-\(index)-\(caret.location)"
        }
    }
}
