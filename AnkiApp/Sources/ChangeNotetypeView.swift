import SwiftUI
import AnkiKit

/// Change Note Type — a native clone of AnkiDroid's "Change Note Type" screen.
///
/// Pick a target note type, then map each NEW field (and template) to one of the
/// OLD ones — or to "(Nothing)" to leave it empty. The engine pre-fills a
/// sensible default mapping (matched by name) via `get_change_notetype_info`;
/// applying it runs `change_notetype`.
///
/// Scope (T3.3): a single note, with a simple per-field / per-template mapping.
/// Template mapping is hidden when a cloze note type is involved (cloze cards
/// can't be remapped), matching the engine. Presented as a sheet from the Card
/// Browser.
@MainActor
struct ChangeNotetypeView: View {
    @ObservedObject var store: AnkiStore
    /// The note whose type is being changed.
    let noteID: Int64
    /// Invoked after a successful change so the presenting screen can refresh.
    var onChanged: () -> Void = {}

    @Environment(\.dismiss) private var dismiss

    @State private var notetypes: [NotetypeOption] = []
    @State private var oldNotetypeID: Int64 = 0
    @State private var selectedTargetID: Int64 = 0
    @State private var info: ChangeNotetypeInfo?
    /// Per-new-field selection: the old field index, or `noneTag` for empty.
    @State private var fieldMap: [Int] = []
    /// Per-new-template selection (empty when cloze).
    @State private var templateMap: [Int] = []
    @State private var errorMessage: String?
    @State private var didLoad = false

    /// Sentinel for "(Nothing)" in a mapping picker (the engine's `-1`).
    private let noneTag = -1

    var body: some View {
        NavigationStack {
            Form {
                targetSection
                if let info {
                    fieldSection(info)
                    if !info.isCloze, !info.newTemplateNames.isEmpty {
                        templateSection(info)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(DS.background.ignoresSafeArea())
            .tint(DS.accent)
            .navigationTitle("Change Note Type")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .fontWeight(.semibold)
                        .disabled(info == nil)
                }
            }
            .alert(
                "Can’t change note type",
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

    private var targetSection: some View {
        Section {
            Picker(selection: $selectedTargetID) {
                ForEach(notetypes) { option in
                    Text(option.name).tag(option.id)
                }
            } label: {
                rowLabel("New type")
            }
            .onChange(of: selectedTargetID) { _ in reloadInfo() }
        } header: {
            sectionHeader("Note type")
        } footer: {
            sectionFooter("Choose the note type to convert this note to, then map its fields below.")
        }
    }

    private func fieldSection(_ info: ChangeNotetypeInfo) -> some View {
        Section {
            ForEach(Array(info.newFieldNames.enumerated()), id: \.offset) { index, name in
                mappingPicker(
                    title: name,
                    selection: fieldBinding(index),
                    oldNames: info.oldFieldNames
                )
            }
        } header: {
            sectionHeader("Fields")
        } footer: {
            sectionFooter("Each new field is filled from the chosen old field, or left empty.")
        }
    }

    private func templateSection(_ info: ChangeNotetypeInfo) -> some View {
        Section {
            ForEach(Array(info.newTemplateNames.enumerated()), id: \.offset) { index, name in
                mappingPicker(
                    title: name,
                    selection: templateBinding(index),
                    oldNames: info.oldTemplateNames
                )
            }
        } header: {
            sectionHeader("Cards")
        } footer: {
            sectionFooter("Map each new card template to an old one, or discard it.")
        }
    }

    /// One mapping row: a labelled picker choosing an old field/template index
    /// (or "(Nothing)") for a given new slot.
    private func mappingPicker(
        title: String, selection: Binding<Int>, oldNames: [String]
    ) -> some View {
        Picker(selection: selection) {
            Text("(Nothing)").tag(noneTag)
            ForEach(Array(oldNames.enumerated()), id: \.offset) { oldIndex, oldName in
                Text(oldName).tag(oldIndex)
            }
        } label: {
            rowLabel(title)
        }
    }

    // MARK: - Bindings

    private func fieldBinding(_ index: Int) -> Binding<Int> {
        Binding(
            get: { index < fieldMap.count ? fieldMap[index] : noneTag },
            set: { if index < fieldMap.count { fieldMap[index] = $0 } }
        )
    }

    private func templateBinding(_ index: Int) -> Binding<Int> {
        Binding(
            get: { index < templateMap.count ? templateMap[index] : noneTag },
            set: { if index < templateMap.count { templateMap[index] = $0 } }
        )
    }

    // MARK: - Loading

    private func loadIfNeeded() {
        guard !didLoad else { return }
        didLoad = true

        guard let old = store.notetypeID(forNote: noteID) else {
            errorMessage = "This note could no longer be loaded."
            return
        }
        oldNotetypeID = old
        notetypes = store.availableNotetypes().map { NotetypeOption(id: $0.id, name: $0.name) }
        // Default the target to a *different* note type when one exists, so the
        // screen opens on a meaningful change.
        selectedTargetID = notetypes.first(where: { $0.id != old })?.id ?? old
        reloadInfo()
    }

    /// Fetches the default mapping for the current old→target pair and resets the
    /// pickers to it. `nil` (leave empty) is shown as the `noneTag` sentinel.
    private func reloadInfo() {
        do {
            let loaded = try store.changeNotetypeInfo(
                oldNotetypeID: oldNotetypeID, newNotetypeID: selectedTargetID
            )
            info = loaded
            fieldMap = loaded.defaultFieldMap.map { $0 ?? noneTag }
            templateMap = loaded.defaultTemplateMap.map { $0 ?? noneTag }
        } catch {
            info = nil
            errorMessage = describe(error)
        }
    }

    // MARK: - Saving

    private func save() {
        guard let info else { return }
        let fields = fieldMap.map { $0 == noneTag ? nil : $0 }
        // Cloze keeps an empty template map (the engine ignores it); otherwise
        // pass the chosen template mapping.
        let templates = info.isCloze ? [] : templateMap.map { $0 == noneTag ? nil : $0 }
        do {
            try store.changeNotetype(
                noteIDs: [noteID], info: info, fieldMap: fields, templateMap: templates
            )
            onChanged()
            dismiss()
        } catch {
            errorMessage = describe(error)
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

/// One note-type option for the picker. A small `Identifiable`/`Hashable`
/// wrapper so the engine's `(id, name)` pairs can drive a SwiftUI `Picker`.
private struct NotetypeOption: Identifiable, Hashable {
    let id: Int64
    let name: String
}
