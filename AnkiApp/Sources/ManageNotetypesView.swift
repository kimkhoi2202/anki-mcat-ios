import SwiftUI
import AnkiKit

/// Manage Note Types — a native clone of AnkiDroid's "Manage note types" screen.
///
/// Lists every note type with its note count and offers the same actions: Add
/// (from a stock base or by cloning an existing type), Rename, and Delete (with
/// the can't-delete-the-last guard and a warning that deleting a type removes all
/// of its notes/cards). Tapping a note type opens its detail hub, from which the
/// Fields editor and Card Template editor are reached. Reached from Settings.
@MainActor
struct ManageNotetypesView: View {
    @ObservedObject var store: AnkiStore

    @State private var items: [NotetypeUseCount] = []
    @State private var didLoad = false
    @State private var showAdd = false

    /// The note type being renamed (drives the rename alert) + its in-progress name.
    @State private var renameTarget: NotetypeUseCount?
    @State private var renameText = ""
    /// The note type pending deletion (drives the confirm dialog).
    @State private var deleteTarget: NotetypeUseCount?
    @State private var errorMessage: String?

    var body: some View {
        List {
            Section {
                if items.isEmpty {
                    Text("No note types.")
                        .font(DS.Typography.body)
                        .foregroundStyle(DS.textSecondary)
                } else {
                    ForEach(items) { item in
                        NavigationLink {
                            NotetypeDetailView(store: store, notetypeID: item.id, name: item.name) {
                                Task { await reload() }
                            }
                        } label: {
                            row(item)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) { deleteTarget = item } label: {
                                Label("Delete", systemImage: "trash")
                            }
                            Button { beginRename(item) } label: {
                                Label("Rename", systemImage: "pencil")
                            }
                            .tint(DS.accent)
                        }
                    }
                }
            } header: {
                sectionHeader("Note types")
            } footer: {
                sectionFooter("Tap a note type to edit its fields and card templates. Swipe a row to rename or delete it.")
            }
        }
        .scrollContentBackground(.hidden)
        .background(DS.background.ignoresSafeArea())
        .tint(DS.accent)
        .navigationTitle("Manage Note Types")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showAdd = true } label: {
                    Label("Add note type", systemImage: "plus")
                }
                .accessibilityIdentifier("addNotetype")
            }
        }
        .sheet(isPresented: $showAdd) {
            AddNotetypeView(store: store, existingNames: items.map(\.name)) {
                Task { await reload() }
            }
        }
        .alert("Rename note type", isPresented: renamePresented) {
            TextField("Name", text: $renameText)
                .autocorrectionDisabled()
            Button("Cancel", role: .cancel) { renameTarget = nil }
            Button("Rename") { commitRename() }
        }
        .confirmationDialog(
            deleteTarget.map { "Delete “\($0.name)”?" } ?? "Delete note type?",
            isPresented: deletePresented,
            titleVisibility: .visible,
            presenting: deleteTarget
        ) { target in
            Button("Delete note type", role: .destructive) { commitDelete(target) }
            Button("Cancel", role: .cancel) { deleteTarget = nil }
        } message: { target in
            Text(deleteMessage(for: target))
        }
        .alert(
            "Couldn’t update note types",
            isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
        ) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .task {
            guard !didLoad else { return }
            didLoad = true
            await reload()
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-startInAddNotetype") {
                showAdd = true
            }
            #endif
        }
    }

    // MARK: - Row

    private func row(_ item: NotetypeUseCount) -> some View {
        HStack {
            Text(item.name)
                .font(DS.Typography.body)
                .foregroundStyle(DS.textPrimary)
            Spacer(minLength: DS.Spacing.s)
            Text(noteCountLabel(item.useCount))
                .font(DS.Typography.caption)
                .foregroundStyle(DS.textSecondary)
                .monospacedDigit()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.name), \(noteCountLabel(item.useCount))")
    }

    private func noteCountLabel(_ count: Int) -> String {
        count == 1 ? "1 note" : "\(count) notes"
    }

    // MARK: - Actions

    private func reload() async {
        items = await store.notetypeUseCounts().sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func beginRename(_ item: NotetypeUseCount) {
        renameTarget = item
        renameText = item.name
    }

    private var renamePresented: Binding<Bool> {
        Binding(get: { renameTarget != nil }, set: { if !$0 { renameTarget = nil } })
    }

    private var deletePresented: Binding<Bool> {
        Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } })
    }

    private func commitRename() {
        guard let target = renameTarget else { return }
        let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        renameTarget = nil
        guard !name.isEmpty, name != target.name else { return }
        Task {
            do {
                try await store.renameNotetype(id: target.id, name: name)
                await reload()
            } catch {
                errorMessage = describe(error)
            }
        }
    }

    /// AnkiDroid's guard: the collection must keep at least one note type.
    private func commitDelete(_ target: NotetypeUseCount) {
        deleteTarget = nil
        guard items.count > 1 else {
            errorMessage = "You can’t delete the last note type."
            return
        }
        Task {
            do {
                try await store.deleteNotetype(id: target.id)
                await reload()
            } catch {
                errorMessage = describe(error)
            }
        }
    }

    private func deleteMessage(for target: NotetypeUseCount) -> String {
        if items.count <= 1 {
            return "This is the last note type and can’t be deleted."
        }
        if target.useCount > 0 {
            let noun = target.useCount == 1 ? "note and its card(s)" : "\(target.useCount) notes and their cards"
            return "This permanently deletes the note type and its \(noun). You can undo it afterwards."
        }
        return "This permanently deletes the note type. You can undo it afterwards."
    }

    private func describe(_ error: Error) -> String {
        if case let AnkiError.backendError(data) = error,
           let backendError = try? Anki_Backend_BackendError(serializedBytes: data),
           !backendError.message.isEmpty {
            return backendError.message
        }
        return error.localizedDescription
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

/// A note type's detail hub: links to its Fields editor and Card Template editor,
/// mirroring how AnkiDroid's note-type screen branches into the field list and
/// the card-template editor. Pushed from the Manage list.
@MainActor
struct NotetypeDetailView: View {
    @ObservedObject var store: AnkiStore
    let notetypeID: Int64
    let name: String
    /// Invoked when an edit here may have changed the list (so it can refresh).
    var onChange: () -> Void = {}

    @State private var showTemplateEditor = false

    var body: some View {
        List {
            Section {
                NavigationLink {
                    NotetypeFieldsEditorView(store: store, notetypeID: notetypeID, notetypeName: name) {
                        onChange()
                    }
                } label: {
                    Label("Fields", systemImage: "list.bullet.indent")
                        .font(DS.Typography.body)
                        .foregroundStyle(DS.textPrimary)
                }
                Button {
                    showTemplateEditor = true
                } label: {
                    Label("Cards", systemImage: "rectangle.on.rectangle.angled")
                        .font(DS.Typography.body)
                        .foregroundStyle(DS.textPrimary)
                }
            } header: {
                sectionHeader("Edit")
            } footer: {
                sectionFooter("“Fields” adds, renames, reorders, and removes fields. “Cards” edits the question / answer templates and styling, with a live preview.")
            }
        }
        .scrollContentBackground(.hidden)
        .background(DS.background.ignoresSafeArea())
        .tint(DS.accent)
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showTemplateEditor) {
            CardTemplateEditorView(store: store, notetypeID: notetypeID, notetypeName: name) {
                onChange()
            }
        }
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

/// Add Note Type — a native clone of AnkiDroid's `AddNewNotesType` dialog: pick a
/// base (a stock type to "Add", or an existing type to "Clone"), give it a name,
/// and create it. The name is validated for emptiness and duplicates inline, like
/// AnkiDroid's name field. Presented as a sheet from the Manage list.
@MainActor
struct AddNotetypeView: View {
    @ObservedObject var store: AnkiStore
    /// Existing note-type names, for the duplicate-name check.
    let existingNames: [String]
    var onAdded: () -> Void = {}

    @Environment(\.dismiss) private var dismiss

    @State private var options: [AddOption] = []
    @State private var selectedOptionID = 0
    @State private var name = ""
    @State private var didLoad = false
    @State private var saving = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker(selection: $selectedOptionID) {
                        ForEach(options) { option in
                            Text(option.label).tag(option.id)
                        }
                    } label: {
                        rowLabel("Base type")
                    }
                    .onChange(of: selectedOptionID) { _ in seedName() }
                } header: {
                    sectionHeader("Type")
                } footer: {
                    sectionFooter("“Add” starts from one of Anki’s built-in types; “Clone” copies an existing note type’s fields and cards.")
                }

                Section {
                    TextField("Name", text: $name)
                        .autocorrectionDisabled()
                        .font(DS.Typography.body)
                    if let nameError {
                        Text(nameError)
                            .font(DS.Typography.caption)
                            .foregroundStyle(DS.again)
                    }
                } header: {
                    sectionHeader("Name")
                }
            }
            .scrollContentBackground(.hidden)
            .background(DS.background.ignoresSafeArea())
            .tint(DS.accent)
            .navigationTitle("Add Note Type")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { add() }
                        .fontWeight(.semibold)
                        .disabled(saving || nameError != nil || selectedOption == nil)
                }
            }
            .alert(
                "Couldn’t add note type",
                isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
            ) {
                Button("OK", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
            .task {
                guard !didLoad else { return }
                didLoad = true
                await loadOptions()
            }
        }
    }

    // MARK: - Derived

    private var selectedOption: AddOption? {
        options.first { $0.id == selectedOptionID }
    }

    /// Inline name validation, mirroring AnkiDroid's "name exists" / empty checks.
    private var nameError: String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return options.isEmpty ? nil : "Enter a name." }
        if existingNames.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            return "A note type with that name already exists."
        }
        return nil
    }

    // MARK: - Loading

    private func loadOptions() async {
        let bases = await store.addNotetypeBases()
        var built: [AddOption] = []
        var id = 0
        for stock in bases.stock {
            built.append(AddOption(id: id, label: "Add: \(stock.name)", baseName: stock.name,
                                   kind: stock.kind, cloneID: nil))
            id += 1
        }
        for existing in bases.existing {
            built.append(AddOption(id: id, label: "Clone: \(existing.name)", baseName: existing.name,
                                   kind: nil, cloneID: existing.id))
            id += 1
        }
        options = built
        selectedOptionID = built.first?.id ?? 0
        seedName()
    }

    /// Prefills a de-duplicated name from the selected base (AnkiDroid prefills a
    /// suggested name, then lets the user adjust). Since the stock names already
    /// exist as note types, a bare base name would always collide, so we append
    /// the smallest free " N" suffix to start from a valid, addable name.
    private func seedName() {
        name = uniqueName(base: selectedOption?.baseName ?? "")
    }

    private func uniqueName(base: String) -> String {
        guard !base.isEmpty else { return "" }
        let taken = Set(existingNames.map { $0.lowercased() })
        if !taken.contains(base.lowercased()) { return base }
        var suffix = 2
        while taken.contains("\(base) \(suffix)".lowercased()) { suffix += 1 }
        return "\(base) \(suffix)"
    }

    // MARK: - Add

    private func add() {
        guard let option = selectedOption, nameError == nil else { return }
        let finalName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        saving = true
        Task {
            defer { saving = false }
            do {
                if let kind = option.kind {
                    try await store.addStockNotetype(kind: kind, name: finalName)
                } else if let cloneID = option.cloneID {
                    try await store.cloneNotetype(id: cloneID, name: finalName)
                }
                onAdded()
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

    private func rowLabel(_ text: String) -> some View {
        Text(text).font(DS.Typography.body).foregroundStyle(DS.textPrimary)
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text).font(DS.Typography.caption.weight(.semibold)).foregroundStyle(DS.textSecondary)
    }

    private func sectionFooter(_ text: String) -> some View {
        Text(text).font(DS.Typography.caption).foregroundStyle(DS.textSecondary)
    }
}

/// One base option in the Add dialog: a stock kind to add, or an existing note
/// type to clone.
private struct AddOption: Identifiable, Hashable {
    let id: Int
    let label: String
    let baseName: String
    /// Set when this option adds a stock type.
    let kind: Anki_Notetypes_StockNotetype.Kind?
    /// Set when this option clones an existing note type.
    let cloneID: Int64?
}
