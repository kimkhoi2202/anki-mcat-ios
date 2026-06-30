import SwiftUI
import UniformTypeIdentifiers
import AnkiKit

/// Import & Export screen, cloning AnkiDroid's import (`ImportFileSelection`) and
/// export (`ExportDialogFragment`) flows natively:
///
/// - **Import** — a `.fileImporter` accepting `.apkg`/`.colpkg`. A `.colpkg`
///   (or the conventional `collection.apkg`) replaces the whole collection; any
///   other `.apkg` imports its notes. The result is summarised in an alert.
/// - **Export** — pick a deck for a `.apkg`, or export the whole collection as a
///   `.colpkg`, with an include-media toggle. The produced file is handed to a
///   share sheet (`UIActivityViewController`).
struct ImportExportView: View {
    @ObservedObject var store: AnkiStore

    @State private var showImporter = false
    @State private var includeMedia = true
    @State private var selectedDeckID: Int64?
    /// Non-nil while a blocking import/export runs (drives the busy overlay).
    @State private var busyMessage: String?
    @State private var resultMessage: String?
    @State private var errorMessage: String?
    @State private var share: ShareItem?
    /// A picked whole-collection package awaiting the destructive-replace
    /// confirmation. Non-nil drives the confirm alert (clone of AnkiDroid's
    /// `DIALOG_IMPORT_REPLACE_CONFIRM`).
    @State private var pendingReplace: PendingReplace?

    /// `.apkg`/`.colpkg` are custom extensions Anki doesn't register a system
    /// UTI for, so resolve them to (dynamic) `UTType`s by filename extension.
    private static let packageTypes: [UTType] =
        ["apkg", "colpkg"].compactMap { UTType(filenameExtension: $0) }

    var body: some View {
        Form {
            importSection
            exportSection
        }
        .scrollContentBackground(.hidden)
        .background(DS.background.ignoresSafeArea())
        .tint(DS.accent)
        .navigationTitle("Import & Export")
        .navigationBarTitleDisplayMode(.inline)
        .disabled(busyMessage != nil)
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: Self.packageTypes,
            allowsMultipleSelection: false
        ) { handleImporterResult($0) }
        .sheet(item: $share) { item in
            ShareSheet(items: [item.url])
        }
        .overlay { busyOverlay }
        .alert("Import complete", isPresented: resultPresented) {
            Button("OK", role: .cancel) { resultMessage = nil }
        } message: {
            Text(resultMessage ?? "")
        }
        .alert("Something went wrong", isPresented: errorPresented) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        // Destructive whole-collection replace confirmation, cloning AnkiDroid's
        // DIALOG_IMPORT_REPLACE_CONFIRM: the import only runs on explicit confirm.
        .alert(
            "Replace collection?",
            isPresented: replaceConfirmPresented,
            presenting: pendingReplace
        ) { pending in
            Button("Replace", role: .destructive) { confirmReplace(pending) }
            Button("Cancel", role: .cancel) { pendingReplace = nil }
        } message: { pending in
            Text("This will delete your existing collection and replace it with the data of file “\(pending.displayName)”.")
        }
        .task {
            if selectedDeckID == nil { selectedDeckID = defaultExportDeckID }
            #if DEBUG
            // Screenshot/automation hook: show the destructive replace
            // confirmation with a sample collection file, without driving the
            // system file picker.
            if ProcessInfo.processInfo.arguments.contains("-startInImportReplaceConfirm") {
                pendingReplace = PendingReplace(url: URL(fileURLWithPath: "/tmp/collection.colpkg"))
            }
            #endif
        }
    }

    // MARK: - Import

    private var importSection: some View {
        Section {
            Button {
                showImporter = true
            } label: {
                Label("Import from file…", systemImage: "square.and.arrow.down")
                    .foregroundStyle(DS.accent)
            }
            .accessibilityIdentifier("importFromFile")
        } header: {
            sectionHeader("Import")
        } footer: {
            sectionFooter("Choose an .apkg deck to add its notes, or a .colpkg to replace your entire collection.")
        }
    }

    // MARK: - Export

    private var exportSection: some View {
        Section {
            Toggle("Include media", isOn: $includeMedia)
                .font(DS.Typography.body)
                .foregroundStyle(DS.textPrimary)

            Picker(selection: $selectedDeckID) {
                ForEach(store.decks, id: \.id) { deck in
                    Text(deck.fullName).tag(Optional(deck.id))
                }
            } label: {
                Text("Deck")
                    .font(DS.Typography.body)
                    .foregroundStyle(DS.textPrimary)
            }

            Button {
                exportDeck()
            } label: {
                Label("Export deck (.apkg)", systemImage: "square.and.arrow.up")
                    .foregroundStyle(selectedDeckID == nil ? DS.textSecondary : DS.accent)
            }
            .disabled(selectedDeckID == nil)
            .accessibilityIdentifier("exportDeck")

            Button {
                exportCollection()
            } label: {
                Label("Export entire collection (.colpkg)", systemImage: "tray.and.arrow.up")
                    .foregroundStyle(DS.accent)
            }
            .accessibilityIdentifier("exportCollection")
        } header: {
            sectionHeader("Export")
        } footer: {
            sectionFooter("A deck exports as a sharable .apkg. The whole collection exports as a .colpkg backup.")
        }
    }

    // MARK: - Busy overlay

    @ViewBuilder
    private var busyOverlay: some View {
        if let busyMessage {
            ZStack {
                Color.black.opacity(0.3).ignoresSafeArea()
                VStack(spacing: DS.Spacing.m) {
                    ProgressView()
                    Text(busyMessage)
                        .font(DS.Typography.body)
                        .foregroundStyle(DS.textPrimary)
                }
                .dsCard()
                .fixedSize()
            }
            .transition(.opacity)
        }
    }

    // MARK: - Actions

    private func handleImporterResult(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            // A .colpkg (or the conventional collection.apkg) replaces the WHOLE
            // collection — destructive and irreversible — so require an explicit
            // confirmation first, cloning AnkiDroid's DIALOG_IMPORT_REPLACE_CONFIRM.
            // Any other .apkg only adds its notes, so it imports straight away.
            if AnkiStore.isCollectionPackage(url.lastPathComponent) {
                pendingReplace = PendingReplace(url: url)
            } else {
                runImport(url)
            }
        case .failure(let error):
            errorMessage = describe(error)
        }
    }

    /// Proceeds with a whole-collection replace the user has explicitly confirmed.
    private func confirmReplace(_ pending: PendingReplace) {
        pendingReplace = nil
        runImport(pending.url)
    }

    private func runImport(_ url: URL) {
        busyMessage = "Importing…"
        Task { @MainActor in
            defer { busyMessage = nil }
            do {
                let outcome = try await store.importPackage(from: url)
                resultMessage = Self.message(for: outcome)
                // The deck list changed; re-default the export picker.
                selectedDeckID = defaultExportDeckID
            } catch {
                errorMessage = describe(error)
            }
        }
    }

    private func exportDeck() {
        guard let deckID = selectedDeckID else { return }
        let name = deckName(for: deckID) ?? "Deck"
        busyMessage = "Exporting deck…"
        Task { @MainActor in
            defer { busyMessage = nil }
            do {
                share = ShareItem(url: try await store.exportDeck(
                    id: deckID, name: name, includeMedia: includeMedia
                ))
            } catch {
                errorMessage = describe(error)
            }
        }
    }

    private func exportCollection() {
        busyMessage = "Exporting collection…"
        Task { @MainActor in
            defer { busyMessage = nil }
            do {
                share = ShareItem(url: try await store.exportWholeCollection(includeMedia: includeMedia))
            } catch {
                errorMessage = describe(error)
            }
        }
    }

    // MARK: - Helpers

    /// The deck pre-selected in the export picker: the current study deck if it
    /// still exists, else the first deck.
    private var defaultExportDeckID: Int64? {
        if store.decks.contains(where: { $0.id == store.currentDeckID }) {
            return store.currentDeckID
        }
        return store.decks.first?.id
    }

    private func deckName(for id: Int64) -> String? {
        store.decks.first(where: { $0.id == id })?.fullName
    }

    /// Builds the import-result summary shown in the confirmation alert.
    private static func message(for outcome: ImportOutcome) -> String {
        switch outcome {
        case .collectionReplaced:
            return "Your collection was replaced with the imported file."
        case .deckPackage(let result):
            var parts = ["\(result.found) note\(result.found == 1 ? "" : "s") found"]
            parts.append("\(result.imported) imported")
            if result.updated > 0 { parts.append("\(result.updated) updated") }
            if result.duplicate > 0 {
                parts.append("\(result.duplicate) duplicate\(result.duplicate == 1 ? "" : "s")")
            }
            return parts.joined(separator: ", ") + "."
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

    private var resultPresented: Binding<Bool> {
        Binding(get: { resultMessage != nil }, set: { if !$0 { resultMessage = nil } })
    }

    private var replaceConfirmPresented: Binding<Bool> {
        Binding(get: { pendingReplace != nil }, set: { if !$0 { pendingReplace = nil } })
    }

    private var errorPresented: Binding<Bool> {
        Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
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

/// An identifiable wrapper so a produced export file can drive `.sheet(item:)`.
private struct ShareItem: Identifiable {
    let id = UUID()
    let url: URL
}

/// A pending whole-collection replace awaiting confirmation: the picked package
/// URL plus the filename shown in the destructive-confirm prompt.
private struct PendingReplace: Identifiable {
    let id = UUID()
    let url: URL
    var displayName: String { url.lastPathComponent }
}

/// Minimal `UIActivityViewController` bridge for the system share sheet, used to
/// hand a produced `.apkg`/`.colpkg` file to AirDrop, Files, Mail, etc.
private struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
