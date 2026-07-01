import SwiftUI
import UniformTypeIdentifiers
import AnkiKit

/// Import & Export screen, cloning AnkiDroid's import (`ImportFileSelection`) and
/// export (`ExportDialogFragment`) flows natively:
///
/// - **Import** — separate pickers for an Anki Deck Package (`.apkg`) and a
///   collection package (`.colpkg`), routed by extension. A `.apkg` opens a
///   native **import options** sheet (update conditions, merge note types,
///   scheduling, deck presets) before importing its notes; a `.colpkg` (or the
///   conventional `collection.apkg`) replaces the whole collection after a
///   destructive confirmation. Either result is summarised in an alert.
/// - **Export** — pick a deck for a `.apkg`, or export the whole collection as a
///   `.colpkg`, with an include-media toggle. The produced file is handed to a
///   share sheet (`UIActivityViewController`).
struct ImportExportView: View {
    @ObservedObject var store: AnkiStore

    /// Drives the Anki Deck Package (`.apkg`) picker.
    @State private var showApkgImporter = false
    /// Drives the collection package (`.colpkg`) restore picker.
    @State private var showColpkgImporter = false
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

    // .apkg import: the prepared options session (picked file + saved presets)
    // driving the options sheet, plus its summary deferred across the sheet's
    // dismissal so the result alert presents cleanly after the sheet is gone.
    @State private var apkgSession: ApkgImportSession?
    @State private var pendingApkgResult: ImportResult?

    // CSV / text import: a second picker (for .csv/.tsv/.txt), the prepared
    // wizard session, and the temp file backing it (removed on dismiss).
    @State private var showCSVImporter = false
    @State private var csvSession: CSVSession?
    @State private var csvTempURL: URL?
    /// Carries the CSV import summary across the wizard's dismissal so the result
    /// alert presents cleanly after the sheet is gone.
    @State private var pendingCSVResult: ImportResult?

    // Notes/cards text export: the options sheet, plus the produced file URL
    // deferred to the sheet's dismissal so the share sheet presents cleanly.
    @State private var showTextExport = false
    @State private var pendingShareURL: URL?

    /// `.apkg`/`.colpkg` are custom extensions Anki doesn't register a system
    /// UTI for, so resolve them to (dynamic) `UTType`s by filename extension. The
    /// Anki Deck Package picker also accepts `.colpkg` (and vice versa) so a
    /// mis-picked file is still routed correctly by extension rather than being
    /// unselectable.
    private static let apkgTypes: [UTType] =
        ["apkg", "colpkg"].compactMap { UTType(filenameExtension: $0) }
    private static let colpkgTypes: [UTType] =
        ["colpkg", "apkg"].compactMap { UTType(filenameExtension: $0) }

    /// Accepted types for the CSV/text import picker: the system CSV/TSV/plain-text
    /// UTIs plus the matching dynamic extensions, so `.csv`/`.tsv`/`.txt` files are
    /// all selectable.
    private static let textTypes: [UTType] =
        [.commaSeparatedText, .tabSeparatedText, .plainText]
        + ["csv", "tsv", "txt"].compactMap { UTType(filenameExtension: $0) }

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
        // Anki Deck Package (.apkg) picker → import-options flow.
        .fileImporter(
            isPresented: $showApkgImporter,
            allowedContentTypes: Self.apkgTypes,
            allowsMultipleSelection: false
        ) { handleImporterResult($0) }
        // Collection package (.colpkg) restore picker → destructive-replace flow.
        .fileImporter(
            isPresented: $showColpkgImporter,
            allowedContentTypes: Self.colpkgTypes,
            allowsMultipleSelection: false
        ) { handleImporterResult($0) }
        // Third picker for CSV/text import (.csv/.tsv/.txt).
        .fileImporter(
            isPresented: $showCSVImporter,
            allowedContentTypes: Self.textTypes,
            allowsMultipleSelection: false
        ) { handleCSVImporterResult($0) }
        .sheet(item: $share) { item in
            ShareSheet(items: [item.url])
        }
        // .apkg import options. On dismiss, if an import succeeded, its summary is
        // shown (deferred so the alert presents after the sheet is gone).
        .sheet(item: $apkgSession, onDismiss: finishApkgSession) { session in
            ApkgImportOptionsView(
                store: store, fileURL: session.url, presets: session.options
            ) { result in
                pendingApkgResult = result
            }
        }
        // CSV import wizard. On dismiss the temp file is removed and, if an
        // import succeeded, its summary is shown (deferred so the alert presents
        // after the sheet is gone).
        .sheet(item: $csvSession, onDismiss: finishCSVSession) { session in
            CSVImportView(
                store: store, fileURL: session.url, metadata: session.metadata
            ) { result in
                pendingCSVResult = result
            }
        }
        // Notes/cards text export options. The produced file URL is deferred to
        // dismissal so the share sheet presents after this sheet is gone.
        .sheet(isPresented: $showTextExport, onDismiss: presentPendingShare) {
            TextExportView(store: store, initialDeckID: selectedDeckID) { url in
                pendingShareURL = url
            }
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
            // Present the .apkg import-options sheet on a sample package (so the
            // options UI can be captured without driving the system file picker).
            if ProcessInfo.processInfo.arguments.contains("-startInApkgImportOptions") {
                await presentSampleApkgImportOptions()
            }
            // Present the text-export options sheet for its screenshot.
            if ProcessInfo.processInfo.arguments.contains("-startInTextExport") {
                showTextExport = true
            }
            // Present the CSV import wizard on a sample file (so the column-mapping
            // UI can be captured without driving the system file picker).
            if ProcessInfo.processInfo.arguments.contains("-startInCSVImport") {
                await presentSampleCSVImport()
            }
            #endif
        }
    }

    #if DEBUG
    /// Screenshot/automation hook: asks the engine for the saved import presets
    /// and opens the `.apkg` import-options sheet on a sample package path — so
    /// the options UI can be captured without the system file picker. (The path
    /// need not exist; the screenshot only inspects the form, not the import.)
    private func presentSampleApkgImportOptions() async {
        do {
            let presets = try await store.importAnkiPackagePresets()
            apkgSession = ApkgImportSession(
                url: URL(fileURLWithPath: "/tmp/SampleDeck.apkg"), options: presets
            )
        } catch {
            errorMessage = describe(error)
        }
    }

    /// Screenshot/automation hook: writes a small sample CSV to a temp file, asks
    /// the engine for its metadata, and opens the mapping wizard — so the
    /// column-mapping UI can be captured without the system file picker.
    private func presentSampleCSVImport() async {
        let sample = """
        Front,Back,Tags
        Bonjour,Hello,greeting
        Merci,Thank you,greeting
        Au revoir,Goodbye,greeting
        """
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sample-import.csv")
        do {
            try sample.write(to: url, atomically: true, encoding: .utf8)
            let prepared = try await store.prepareCsvImport(from: url)
            csvTempURL = prepared.localURL
            csvSession = CSVSession(url: prepared.localURL, metadata: prepared.metadata)
        } catch {
            errorMessage = describe(error)
        }
    }
    #endif

    // MARK: - Import

    private var importSection: some View {
        Section {
            Button {
                showApkgImporter = true
            } label: {
                Label("Import Anki Package (.apkg)…", systemImage: "square.and.arrow.down")
                    .foregroundStyle(DS.accent)
            }
            .accessibilityIdentifier("importApkg")

            Button {
                showColpkgImporter = true
            } label: {
                Label("Restore from collection package (.colpkg)…", systemImage: "arrow.clockwise.circle")
                    .foregroundStyle(DS.accent)
            }
            .accessibilityIdentifier("importColpkg")

            Button {
                showCSVImporter = true
            } label: {
                Label("Import CSV/text…", systemImage: "tablecells")
                    .foregroundStyle(DS.accent)
            }
            .accessibilityIdentifier("importCSV")
        } header: {
            sectionHeader("Import")
        } footer: {
            sectionFooter("An Anki Deck Package (.apkg) adds its notes with import options; a collection package (.colpkg) replaces your entire collection; a .csv/.tsv/.txt file maps its columns to fields.")
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

            Button {
                showTextExport = true
            } label: {
                Label("Export notes/cards (text)…", systemImage: "doc.plaintext")
                    .foregroundStyle(DS.accent)
            }
            .accessibilityIdentifier("exportText")
        } header: {
            sectionHeader("Export")
        } footer: {
            sectionFooter("A deck exports as a sharable .apkg. The whole collection exports as a .colpkg backup. Notes or cards can also export as plain text (.txt).")
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

    /// Routes a picked package by extension (shared by both package pickers, so a
    /// file picked from the "wrong" picker is still handled correctly):
    ///
    /// - A `.colpkg` (or the conventional `collection.apkg`) replaces the WHOLE
    ///   collection — destructive and irreversible — so it requires an explicit
    ///   confirmation first, cloning AnkiDroid's `DIALOG_IMPORT_REPLACE_CONFIRM`.
    /// - Any other `.apkg` only adds its notes, so it opens the import-options
    ///   sheet (seeded from the saved presets).
    private func handleImporterResult(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            if AnkiStore.isCollectionPackage(url.lastPathComponent) {
                pendingReplace = PendingReplace(url: url)
            } else {
                beginApkgImport(url)
            }
        case .failure(let error):
            errorMessage = describe(error)
        }
    }

    /// Fetches the saved import presets, then opens the `.apkg` import-options
    /// sheet seeded from them. Reading presets touches the backend, so it shows
    /// the busy overlay while it runs (it's quick — a config read).
    private func beginApkgImport(_ url: URL) {
        busyMessage = "Reading import options…"
        Task { @MainActor in
            defer { busyMessage = nil }
            do {
                let presets = try await store.importAnkiPackagePresets()
                apkgSession = ApkgImportSession(url: url, options: presets)
            } catch {
                errorMessage = describe(error)
            }
        }
    }

    /// Runs when the .apkg options sheet is dismissed: if an import succeeded,
    /// shows its summary and re-defaults the export picker (the deck list may have
    /// changed). Deferred so the alert presents after the sheet is gone.
    private func finishApkgSession() {
        if let result = pendingApkgResult {
            pendingApkgResult = nil
            resultMessage = Self.message(for: .deckPackage(result))
            selectedDeckID = defaultExportDeckID
        }
    }

    /// Proceeds with a whole-collection replace the user has explicitly confirmed.
    private func confirmReplace(_ pending: PendingReplace) {
        pendingReplace = nil
        runImport(pending.url)
    }

    /// Runs a confirmed whole-collection `.colpkg` restore (close → import →
    /// reopen), summarising the result. `.apkg` imports go through the options
    /// sheet instead (`beginApkgImport`).
    private func runImport(_ url: URL) {
        busyMessage = "Restoring collection…"
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

    // MARK: - CSV / text import

    /// Handles the CSV/text picker result: copies the file to a temp path and
    /// asks the engine for its metadata, then opens the mapping wizard. Reading
    /// metadata is quick but touches disk/the backend, so it shows the busy
    /// overlay while it runs.
    private func handleCSVImporterResult(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            busyMessage = "Reading file…"
            Task { @MainActor in
                defer { busyMessage = nil }
                do {
                    let prepared = try await store.prepareCsvImport(from: url)
                    csvTempURL = prepared.localURL
                    csvSession = CSVSession(url: prepared.localURL, metadata: prepared.metadata)
                } catch {
                    errorMessage = describe(error)
                }
            }
        case .failure(let error):
            errorMessage = describe(error)
        }
    }

    /// Runs when the CSV wizard sheet is dismissed: removes the temp file and, if
    /// an import succeeded, shows its summary and re-defaults the export picker
    /// (the deck list may have changed).
    private func finishCSVSession() {
        if let url = csvTempURL {
            try? FileManager.default.removeItem(at: url)
            csvTempURL = nil
        }
        if let result = pendingCSVResult {
            pendingCSVResult = nil
            resultMessage = Self.message(for: .deckPackage(result))
            selectedDeckID = defaultExportDeckID
        }
    }

    /// Runs when the text-export options sheet is dismissed: presents the share
    /// sheet for the produced file (deferred so it doesn't collide with the
    /// dismissing options sheet).
    private func presentPendingShare() {
        if let url = pendingShareURL {
            pendingShareURL = nil
            share = ShareItem(url: url)
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
            if result.conflicting > 0 {
                parts.append("\(result.conflicting) conflicting")
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

/// A prepared CSV/text import: the temp file plus the engine's detected metadata,
/// driving the mapping wizard via `.sheet(item:)`.
private struct CSVSession: Identifiable {
    let id = UUID()
    let url: URL
    let metadata: Anki_ImportExport_CsvMetadata
}

/// A prepared `.apkg` import: the picked file plus the saved presets the options
/// sheet seeds itself from, driving the options sheet via `.sheet(item:)`.
private struct ApkgImportSession: Identifiable {
    let id = UUID()
    let url: URL
    let options: Anki_ImportExport_ImportAnkiPackageOptions
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
