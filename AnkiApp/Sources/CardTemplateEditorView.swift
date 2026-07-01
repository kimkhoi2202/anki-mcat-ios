import SwiftUI
import AnkiKit

/// A plain, multi-line `UITextView` for editing template/CSS source — monospaced,
/// no autocorrect/autocapitalisation/smart-quotes (so `{{Field}}` and CSS aren't
/// "corrected"), and internally scrollable. Used for the Front / Back / Styling
/// editors in the Card Template editor (the task's "plain UITextView wrapper"
/// alternative to the formatting-rich ``RichFieldView``).
struct PlainTextEditor: UIViewRepresentable {
    @Binding var text: String

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.delegate = context.coordinator
        textView.font = UIFont.monospacedSystemFont(ofSize: 15, weight: .regular)
        textView.adjustsFontForContentSizeCategory = true
        textView.textColor = UIColor(DS.textPrimary)
        textView.backgroundColor = .clear
        textView.autocorrectionType = .no
        textView.autocapitalizationType = .none
        textView.smartQuotesType = .no
        textView.smartDashesType = .no
        textView.spellCheckingType = .no
        textView.isScrollEnabled = true
        textView.textContainerInset = UIEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        textView.text = text
        return textView
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        context.coordinator.parent = self
        // Only overwrite when the bound value actually diverged (e.g. switching the
        // edited tab/template), so we don't fight the caret while typing.
        if uiView.text != text {
            uiView.text = text
        }
    }

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: PlainTextEditor
        init(_ parent: PlainTextEditor) { self.parent = parent }
        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text
        }
    }
}

/// Card Template editor — a native clone of AnkiDroid's `CardTemplateEditor`.
///
/// Edits a note type's card templates and shared styling on an in-memory copy
/// (like AnkiDroid's `tempNoteType`): pick a card, edit its **Front** / **Back**
/// templates and the note type's **Styling (CSS)**, and see a **live preview** of
/// a sample card rendered by the engine (`render_uncommitted_card`) so edits show
/// immediately. Card types can be added / renamed / reordered / removed for
/// normal note types (a normal type keeps ≥1 card); cloze note types generate
/// cards from `{{c1::…}}` deletions rather than per-card templates, so their
/// structure is left alone and only the single template + styling are editable.
/// Nothing is written until **Save**, which calls `update_notetype` (the engine
/// validates the templates and surfaces any error). Presented as a sheet.
@MainActor
struct CardTemplateEditorView: View {
    @ObservedObject var store: AnkiStore
    let notetypeID: Int64
    let notetypeName: String
    /// Invoked after a successful save so the presenting screen can refresh.
    var onSaved: () -> Void = {}

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    /// The in-memory note type being edited (AnkiDroid's `tempNoteType`).
    @State private var notetype: Anki_Notetypes_Notetype?
    @State private var ord = 0
    @State private var editTab: EditTab = .front
    @State private var previewSide: PreviewSide = .question

    @State private var previewQuestion = ""
    @State private var previewAnswer = ""
    /// Debounce guard so the preview re-renders when typing stops, not per keystroke.
    @State private var previewToken = 0

    @State private var didLoad = false
    @State private var saving = false
    @State private var errorMessage: String?

    // Template structural-edit dialogs.
    @State private var showAddCard = false
    @State private var addCardName = ""
    @State private var showRenameCard = false
    @State private var renameCardName = ""
    @State private var confirmDeleteCard = false

    enum EditTab: String, CaseIterable, Identifiable {
        case front = "Front", back = "Back", styling = "Styling"
        var id: String { rawValue }
    }
    enum PreviewSide: String, CaseIterable, Identifiable {
        case question = "Front", answer = "Back"
        var id: String { rawValue }
    }

    var body: some View {
        NavigationStack {
            Group {
                if let notetype {
                    editor(notetype)
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .background(DS.background.ignoresSafeArea())
            .navigationTitle(notetypeName)
            .navigationBarTitleDisplayMode(.inline)
            .tint(DS.accent)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(Loc.tr("actions-cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(Loc.tr("actions-save")) { save() }
                        .fontWeight(.semibold)
                        .disabled(notetype == nil || saving)
                }
            }
            .alert(Loc.tr("card-templates-add-card-type"), isPresented: $showAddCard) {
                TextField("Name", text: $addCardName).autocorrectionDisabled()
                Button(Loc.tr("actions-cancel"), role: .cancel) {}
                Button(Loc.tr("actions-add")) { addCard() }
            }
            .alert(Loc.tr("card-templates-rename-card-type"), isPresented: $showRenameCard) {
                TextField("Name", text: $renameCardName).autocorrectionDisabled()
                Button(Loc.tr("actions-cancel"), role: .cancel) {}
                Button(Loc.tr("actions-rename")) { renameCard() }
            }
            .confirmationDialog(
                "Delete this card type?",
                isPresented: $confirmDeleteCard,
                titleVisibility: .visible
            ) {
                Button("Delete card type", role: .destructive) { deleteCard() }
                Button(Loc.tr("actions-cancel"), role: .cancel) {}
            } message: {
                Text("Saving will remove this card and its cards from every note of this type.")
            }
            .alert(
                "Couldn’t save card templates",
                isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
            ) {
                Button("OK", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
            .task {
                guard !didLoad else { return }
                didLoad = true
                await load()
            }
        }
    }

    // MARK: - Editor

    @ViewBuilder
    private func editor(_ notetype: Anki_Notetypes_Notetype) -> some View {
        VStack(spacing: 0) {
            cardSelectorBar(notetype)
            Divider().overlay(DS.separator)

            Picker("Edit", selection: $editTab) {
                ForEach(EditTab.allCases) { tab in Text(editTabLabel(tab)).tag(tab) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, DS.Spacing.l)
            .padding(.vertical, DS.Spacing.s)

            PlainTextEditor(text: editorBinding)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(DS.surface)
                .overlay(alignment: .topLeading) { editorPlaceholder }

            Divider().overlay(DS.separator)

            previewPane(notetype)
        }
    }

    /// The card switcher (for multi-template note types) plus the card-management
    /// menu (add / rename / move / delete). Hidden for cloze note types, which
    /// don't have per-card templates.
    @ViewBuilder
    private func cardSelectorBar(_ notetype: Anki_Notetypes_Notetype) -> some View {
        HStack(spacing: DS.Spacing.s) {
            if notetype.isCloze {
                Label(Loc.tr("notetypes-cloze-name"), systemImage: "rectangle.dashed")
                    .font(DS.Typography.body.weight(.semibold))
                    .foregroundStyle(DS.textPrimary)
                Spacer(minLength: 0)
            } else {
                if notetype.templates.count > 1 {
                    Picker("Card", selection: $ord) {
                        ForEach(Array(notetype.templates.enumerated()), id: \.offset) { index, template in
                            Text(template.name.isEmpty ? "Card \(index + 1)" : template.name).tag(index)
                        }
                    }
                    .pickerStyle(.menu)
                    .tint(DS.accent)
                } else {
                    Text(currentCardName(notetype))
                        .font(DS.Typography.body.weight(.semibold))
                        .foregroundStyle(DS.textPrimary)
                }
                Spacer(minLength: 0)
                cardMenu(notetype)
            }
        }
        .padding(.horizontal, DS.Spacing.l)
        .padding(.vertical, DS.Spacing.s)
    }

    private func cardMenu(_ notetype: Anki_Notetypes_Notetype) -> some View {
        Menu {
            Button { addCardName = ""; showAddCard = true } label: {
                Label(Loc.tr("card-templates-add-card-type"), systemImage: "plus")
            }
            Button {
                renameCardName = currentCardName(notetype)
                showRenameCard = true
            } label: {
                Label(Loc.tr("card-templates-rename-card-type"), systemImage: "pencil")
            }
            if notetype.templates.count > 1 {
                Button { moveCard(by: -1) } label: { Label("Move up", systemImage: "arrow.up") }
                    .disabled(ord == 0)
                Button { moveCard(by: 1) } label: { Label("Move down", systemImage: "arrow.down") }
                    .disabled(ord >= notetype.templates.count - 1)
                Button(role: .destructive) { confirmDeleteCard = true } label: {
                    Label("Delete card type", systemImage: "trash")
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.title3)
                .foregroundStyle(DS.accent)
        }
        .accessibilityLabel("Card actions")
    }

    @ViewBuilder
    private var editorPlaceholder: some View {
        if editorBinding.wrappedValue.isEmpty {
            Text(placeholderText)
                .font(.system(size: 15, design: .monospaced))
                .foregroundStyle(DS.textSecondary)
                .padding(.top, 18)
                .padding(.leading, 16)
                .allowsHitTesting(false)
        }
    }

    private var placeholderText: String {
        switch editTab {
        case .front: return "Front template, e.g. {{Front}}"
        case .back: return "Back template, e.g. {{FrontSide}}<hr>{{Back}}"
        case .styling: return ".card { ... }"
        }
    }

    /// Localized segment label for the Front / Back / Styling editor tabs (the
    /// raw values stay English so they still serve as the picker's tag/id).
    private func editTabLabel(_ tab: EditTab) -> String {
        switch tab {
        case .front: return Loc.tr("notetypes-front-field")
        case .back: return Loc.tr("notetypes-back-field")
        case .styling: return Loc.tr("card-templates-template-styling")
        }
    }

    private func previewPane(_ notetype: Anki_Notetypes_Notetype) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(Loc.tr("actions-preview"))
                    .font(DS.Typography.caption.weight(.semibold))
                    .foregroundStyle(DS.textSecondary)
                Spacer(minLength: DS.Spacing.m)
                Picker("Side", selection: $previewSide) {
                    ForEach(PreviewSide.allCases) { side in
                        Text(Loc.tr(side == .question ? "notetypes-front-field" : "notetypes-back-field")).tag(side)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 180)
            }
            .padding(.horizontal, DS.Spacing.l)
            .padding(.vertical, DS.Spacing.s)

            CardWebView(
                html: previewSide == .question ? previewQuestion : previewAnswer,
                css: notetype.config.css,
                ordinal: ord,
                isDark: colorScheme == .dark,
                mediaFolder: store.mediaFolderURL
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Bindings

    /// The text for the active tab, reading/writing into the in-memory note type
    /// and re-rendering the preview on change.
    private var editorBinding: Binding<String> {
        Binding(
            get: {
                guard let notetype else { return "" }
                switch editTab {
                case .front:
                    return notetype.templates.indices.contains(ord) ? notetype.templates[ord].config.qFormat : ""
                case .back:
                    return notetype.templates.indices.contains(ord) ? notetype.templates[ord].config.aFormat : ""
                case .styling:
                    return notetype.config.css
                }
            },
            set: { newValue in
                guard var nt = notetype else { return }
                switch editTab {
                case .front:
                    if nt.templates.indices.contains(ord) { nt.templates[ord].config.qFormat = newValue }
                case .back:
                    if nt.templates.indices.contains(ord) { nt.templates[ord].config.aFormat = newValue }
                case .styling:
                    nt.setCSS(newValue)
                }
                notetype = nt
                schedulePreview()
            }
        )
    }

    // MARK: - Loading & preview

    private func load() async {
        guard let loaded = await store.loadNotetype(id: notetypeID) else {
            errorMessage = "This note type could no longer be loaded."
            return
        }
        notetype = loaded
        ord = 0
        await renderPreview()
    }

    private func schedulePreview() {
        previewToken &+= 1
        let token = previewToken
        Task {
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard token == previewToken else { return }
            await renderPreview()
        }
    }

    private func renderPreview() async {
        guard let notetype, notetype.templates.indices.contains(ord) else {
            previewQuestion = ""
            previewAnswer = ""
            return
        }
        let sample = notetype.sampleNote()
        let template = notetype.templates[ord]
        if let result = await store.renderNotetypePreview(note: sample, cardOrd: ord, template: template) {
            previewQuestion = result.question
            previewAnswer = result.answer
        } else {
            // A render failure (e.g. an unparsable template mid-edit) shows as an
            // empty preview rather than an error dialog while the user types.
            previewQuestion = ""
            previewAnswer = ""
        }
    }

    // MARK: - Template structure (in-memory; persisted on Save)

    private func currentCardName(_ notetype: Anki_Notetypes_Notetype) -> String {
        guard notetype.templates.indices.contains(ord) else { return "Card \(ord + 1)" }
        let name = notetype.templates[ord].name
        return name.isEmpty ? "Card \(ord + 1)" : name
    }

    private func addCard() {
        guard var nt = notetype else { return }
        let name = addCardName.trimmingCharacters(in: .whitespacesAndNewlines)
        nt.addTemplate(named: name.isEmpty ? uniqueCardName(in: nt) : name)
        notetype = nt
        ord = nt.templates.count - 1
        editTab = .front
        schedulePreview()
    }

    private func renameCard() {
        guard var nt = notetype, nt.templates.indices.contains(ord) else { return }
        let name = renameCardName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        nt.renameTemplate(at: ord, to: name)
        notetype = nt
    }

    private func moveCard(by delta: Int) {
        guard var nt = notetype else { return }
        let destination = ord + delta
        guard nt.templates.indices.contains(destination) else { return }
        nt.moveTemplate(from: ord, to: destination)
        notetype = nt
        ord = destination
        schedulePreview()
    }

    private func deleteCard() {
        guard var nt = notetype, nt.templates.count > 1 else { return }
        nt.removeTemplate(at: ord)
        notetype = nt
        ord = min(ord, nt.templates.count - 1)
        schedulePreview()
    }

    /// "Card N" with N chosen so it doesn't collide with an existing template name.
    private func uniqueCardName(in notetype: Anki_Notetypes_Notetype) -> String {
        let existing = Set(notetype.templateNames)
        var index = notetype.templates.count + 1
        while existing.contains("Card \(index)") { index += 1 }
        return "Card \(index)"
    }

    // MARK: - Save

    private func save() {
        guard let notetype else { return }
        saving = true
        Task {
            defer { saving = false }
            do {
                try await store.saveNotetype(notetype)
                onSaved()
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
}
