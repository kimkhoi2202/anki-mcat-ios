import SwiftUI
import AnkiKit

/// `.apkg` import options — a native clone of Anki's "Import" dialog options that
/// appear after choosing an Anki Deck Package. Seeded from the collection's saved
/// presets (`getImportAnkiPackagePresets`, service 39, method 3) and, on confirm,
/// runs `importAnkiPackage` (39, 2) with the chosen `ImportAnkiPackageOptions`:
///
/// - **Update notes** / **Update note types** (`updateNotes` / `updateNotetypes`):
///   when an imported note / note type already exists, overwrite it *If newer*,
///   *Always*, or *Never*.
/// - **Merge note types** (`mergeNotetypes`): reuse a matching existing note type
///   instead of importing a duplicate.
/// - **Include scheduling information** (`withScheduling`): import review history
///   and due dates rather than resetting the cards to new.
/// - **Include deck presets** (`withDeckConfigs`): import the package's deck
///   option presets.
///
/// The import holds the backend for the whole call, so it runs inside the store's
/// exclusive-op gate, off the main actor; the resulting note summary is handed
/// back via `onImported` for the caller to present.
@MainActor
struct ApkgImportOptionsView: View {
    @ObservedObject var store: AnkiStore
    /// The picked (security-scoped) `.apkg` to import. Copied into a temp path by
    /// the store at import time.
    let fileURL: URL
    /// The saved import options the sheet seeds its controls from.
    let presets: Anki_ImportExport_ImportAnkiPackageOptions
    /// Invoked with the import's note summary so the presenter can show it.
    var onImported: (ImportResult) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var updateNotes: ApkgImportUpdateCondition = .ifNewer
    @State private var updateNotetypes: ApkgImportUpdateCondition = .ifNewer
    @State private var mergeNotetypes = false
    @State private var withScheduling = false
    @State private var withDeckConfigs = false

    @State private var importing = false
    @State private var errorMessage: String?
    @State private var didLoad = false

    init(
        store: AnkiStore,
        fileURL: URL,
        presets: Anki_ImportExport_ImportAnkiPackageOptions,
        onImported: @escaping (ImportResult) -> Void
    ) {
        self.store = store
        self.fileURL = fileURL
        self.presets = presets
        self.onImported = onImported
    }

    var body: some View {
        NavigationStack {
            Form {
                packageSection
                updateSection
                includeSection
            }
            .scrollContentBackground(.hidden)
            .background(DS.background.ignoresSafeArea())
            .tint(DS.accent)
            .navigationTitle("Import Options")
            .navigationBarTitleDisplayMode(.inline)
            .disabled(importing)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Import") { runImport() }
                        .fontWeight(.semibold)
                        .disabled(importing)
                        .accessibilityIdentifier("apkgImportConfirm")
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
            .task {
                // Seed the controls from the saved presets once (a re-run of the
                // task on redraw mustn't clobber the user's in-progress edits).
                if !didLoad {
                    didLoad = true
                    updateNotes = ApkgImportUpdateCondition(presets.updateNotes)
                    updateNotetypes = ApkgImportUpdateCondition(presets.updateNotetypes)
                    mergeNotetypes = presets.mergeNotetypes
                    withScheduling = presets.withScheduling
                    withDeckConfigs = presets.withDeckConfigs
                }
            }
        }
    }

    // MARK: - Sections

    private var packageSection: some View {
        Section {
            HStack {
                rowLabel("File")
                Spacer()
                Text(fileURL.lastPathComponent)
                    .font(DS.Typography.body)
                    .foregroundStyle(DS.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        } header: {
            sectionHeader("Package")
        } footer: {
            sectionFooter("Imports the notes, cards, and any bundled media from this Anki Deck Package into your collection.")
        }
    }

    private var updateSection: some View {
        Section {
            Picker(selection: $updateNotes) {
                ForEach(ApkgImportUpdateCondition.allCases, id: \.self) { condition in
                    Text(Self.title(for: condition)).tag(condition)
                }
            } label: {
                rowLabel("Update notes")
            }

            Picker(selection: $updateNotetypes) {
                ForEach(ApkgImportUpdateCondition.allCases, id: \.self) { condition in
                    Text(Self.title(for: condition)).tag(condition)
                }
            } label: {
                rowLabel("Update note types")
            }

            Toggle("Merge note types", isOn: $mergeNotetypes)
                .font(DS.Typography.body)
                .foregroundStyle(DS.textPrimary)
        } header: {
            sectionHeader("Existing content")
        } footer: {
            sectionFooter("When an imported note or note type already exists, choose whether to overwrite it if the imported one is newer, always, or never. Merging reuses a matching note type instead of adding a duplicate.")
        }
    }

    private var includeSection: some View {
        Section {
            Toggle("Include scheduling information", isOn: $withScheduling)
                .font(DS.Typography.body)
                .foregroundStyle(DS.textPrimary)
            Toggle("Include deck presets", isOn: $withDeckConfigs)
                .font(DS.Typography.body)
                .foregroundStyle(DS.textPrimary)
        } header: {
            sectionHeader("Include")
        } footer: {
            sectionFooter("Scheduling imports review history and due dates; otherwise cards are added as new. Deck presets import the package's deck options.")
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

    // MARK: - Import

    private func runImport() {
        let options = Backend.importAnkiPackageOptions(
            updateNotes: updateNotes,
            updateNotetypes: updateNotetypes,
            mergeNotetypes: mergeNotetypes,
            withScheduling: withScheduling,
            withDeckConfigs: withDeckConfigs
        )
        importing = true
        Task { @MainActor in
            defer { importing = false }
            do {
                let outcome = try await store.importPackage(from: fileURL, apkgOptions: options)
                if case .deckPackage(let result) = outcome {
                    onImported(result)
                }
                dismiss()
            } catch {
                errorMessage = describe(error)
            }
        }
    }

    /// The display title for an update-condition choice (mirrors Anki's dropdown).
    private static func title(for condition: ApkgImportUpdateCondition) -> String {
        switch condition {
        case .ifNewer: return "If newer"
        case .always: return "Always"
        case .never: return "Never"
        }
    }

    /// Extracts a human-readable message, decoding the engine's protobuf
    /// `BackendError` when present (e.g. a corrupt or wrong-version package).
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
