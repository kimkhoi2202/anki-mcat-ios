import SwiftUI
import AnkiKit

/// Fields editor — a native clone of AnkiDroid's `ModelFieldEditor`.
///
/// Lists a note type's fields and lets the user Add, Rename, Reposition
/// (drag in Edit mode), and Delete them, plus pick the Sort Field (the field
/// shown in the browser's Sort Field column). Each action persists immediately
/// through the engine (`update_notetype`), which keeps every note's stored values
/// aligned by ordinal, so there is nothing to "save" — Back simply returns.
/// A note type must keep at least one field, so the last field can't be deleted.
@MainActor
struct NotetypeFieldsEditorView: View {
    @ObservedObject var store: AnkiStore
    let notetypeID: Int64
    let notetypeName: String
    /// Invoked after any change so the parent list can refresh.
    var onChange: () -> Void = {}

    @State private var fields: [String] = []
    @State private var sortFieldIndex = 0
    @State private var didLoad = false
    @State private var busy = false

    @State private var showAdd = false
    @State private var addText = ""
    /// The field index being renamed (drives the rename alert) + its text.
    @State private var renameIndex: Int?
    @State private var renameText = ""
    @State private var errorMessage: String?

    var body: some View {
        List {
            Section {
                if fields.isEmpty {
                    Text("This note type has no fields.")
                        .font(DS.Typography.body)
                        .foregroundStyle(DS.textSecondary)
                } else {
                    ForEach(Array(fields.enumerated()), id: \.offset) { index, name in
                        fieldRow(index: index, name: name)
                    }
                    .onMove(perform: moveFields)
                    .onDelete(perform: deleteFields)
                }
            } header: {
                sectionHeader(Loc.tr("notetypes-fields"))
            } footer: {
                sectionFooter("Drag in Edit mode to reorder. The sort field (★) is shown in the browser’s Sort Field column. A note type needs at least one field.")
            }
        }
        .scrollContentBackground(.hidden)
        .background(DS.background.ignoresSafeArea())
        .tint(DS.accent)
        .navigationTitle(Loc.tr("notetypes-fields"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { addText = ""; showAdd = true } label: {
                    Label(Loc.tr("fields-add-field"), systemImage: "plus")
                }
                .accessibilityIdentifier("addField")
                .disabled(busy)
            }
            ToolbarItem(placement: .topBarTrailing) { EditButton() }
        }
        .overlay { if busy { progressOverlay } }
        .alert(Loc.tr("fields-add-field"), isPresented: $showAdd) {
            TextField("Field name", text: $addText).autocorrectionDisabled()
            Button(Loc.tr("actions-cancel"), role: .cancel) {}
            Button(Loc.tr("actions-add")) { addField() }
        }
        .alert("Rename field", isPresented: renamePresented) {
            TextField("Field name", text: $renameText).autocorrectionDisabled()
            Button(Loc.tr("actions-cancel"), role: .cancel) { renameIndex = nil }
            Button(Loc.tr("actions-rename")) { commitRename() }
        }
        .alert(
            "Couldn’t update fields",
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
        }
    }

    // MARK: - Row

    private func fieldRow(index: Int, name: String) -> some View {
        HStack(spacing: DS.Spacing.s) {
            Text(name)
                .font(DS.Typography.body)
                .foregroundStyle(DS.textPrimary)
            Spacer(minLength: 0)
            if index == sortFieldIndex {
                Label("Sort field", systemImage: "star.fill")
                    .labelStyle(.iconOnly)
                    .font(DS.Typography.caption)
                    .foregroundStyle(DS.accent)
                    .accessibilityLabel("Sort field")
            }
        }
        .contentShape(Rectangle())
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if fields.count > 1 {
                Button(role: .destructive) { removeField(at: index) } label: {
                    Label(Loc.tr("actions-delete"), systemImage: "trash")
                }
            }
            Button { beginRename(index) } label: {
                Label(Loc.tr("actions-rename"), systemImage: "pencil")
            }
            .tint(DS.accent)
        }
        .contextMenu {
            Button { beginRename(index) } label: { Label(Loc.tr("actions-rename"), systemImage: "pencil") }
            if index != sortFieldIndex {
                Button { setSortField(index) } label: { Label("Make sort field", systemImage: "star") }
            }
            if fields.count > 1 {
                Button(role: .destructive) { removeField(at: index) } label: { Label(Loc.tr("actions-delete"), systemImage: "trash") }
            }
        }
    }

    private var progressOverlay: some View {
        ZStack {
            Color.black.opacity(0.1).ignoresSafeArea()
            ProgressView()
                .padding(DS.Spacing.l)
                .background(RoundedRectangle(cornerRadius: DS.Radius.medium).fill(DS.surface))
        }
        .allowsHitTesting(true)
    }

    // MARK: - Actions

    private func reload() async {
        guard let notetype = await store.loadNotetype(id: notetypeID) else {
            errorMessage = "This note type could no longer be loaded."
            return
        }
        fields = notetype.fieldNames
        sortFieldIndex = Int(notetype.config.sortFieldIdx)
    }

    private var renamePresented: Binding<Bool> {
        Binding(get: { renameIndex != nil }, set: { if !$0 { renameIndex = nil } })
    }

    private func beginRename(_ index: Int) {
        renameIndex = index
        renameText = fields.indices.contains(index) ? fields[index] : ""
    }

    private func addField() {
        let name = addText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        run { try await store.addNotetypeField(notetypeID: notetypeID, name: name) }
    }

    private func commitRename() {
        guard let index = renameIndex else { return }
        renameIndex = nil
        let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, fields.indices.contains(index), name != fields[index] else { return }
        run { try await store.renameNotetypeField(notetypeID: notetypeID, at: index, to: name) }
    }

    private func moveFields(from source: IndexSet, to destination: Int) {
        guard let from = source.first else { return }
        // SwiftUI's destination is the index to insert *before*; convert to a
        // final position the engine's reposition expects.
        let to = from < destination ? destination - 1 : destination
        guard from != to else { return }
        run { try await store.moveNotetypeField(notetypeID: notetypeID, from: from, to: to) }
    }

    private func deleteFields(at offsets: IndexSet) {
        guard let index = offsets.first else { return }
        removeField(at: index)
    }

    private func removeField(at index: Int) {
        guard fields.count > 1 else {
            errorMessage = "A note type must have at least one field."
            return
        }
        run { try await store.removeNotetypeField(notetypeID: notetypeID, at: index) }
    }

    private func setSortField(_ index: Int) {
        run { try await store.setNotetypeSortField(notetypeID: notetypeID, at: index) }
    }

    /// Runs an engine field op off the main actor, then reloads and notifies the
    /// parent. Serializes via `busy` so rapid taps don't overlap.
    private func run(_ work: @escaping () async throws -> Void) {
        guard !busy else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                try await work()
                await reload()
                onChange()
            } catch {
                errorMessage = describe(error)
                await reload()
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

    private func sectionHeader(_ text: String) -> some View {
        Text(text).font(DS.Typography.caption.weight(.semibold)).foregroundStyle(DS.textSecondary)
    }

    private func sectionFooter(_ text: String) -> some View {
        Text(text).font(DS.Typography.caption).foregroundStyle(DS.textSecondary)
    }
}
