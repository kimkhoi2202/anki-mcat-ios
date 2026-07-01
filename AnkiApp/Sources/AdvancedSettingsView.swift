import SwiftUI
import AnkiKit

/// Anki's Advanced / database-maintenance tools, cloning AnkiDroid's "Advanced"
/// settings category as a native pushed screen:
///
/// - **Check database** (`CollectionService.check_database`) — a full
///   integrity/repair pass, showing the problems it found and fixed.
/// - **Empty cards** (`CardRenderingService.get_empty_cards` +
///   `CardsService.remove_cards`) — find cards that render to nothing and delete
///   them after confirmation.
/// - **Force full sync** (schema modification, AnkiDroid's "one-way sync") —
///   arm a full up/down sync for the next sync without syncing now.
/// - **Restore from backup** — replace the whole collection with a `.colpkg`
///   snapshot from the backup folder (reuses the `.colpkg` import flow).
///
/// Every backend action runs through the store's off-main dispatch and is
/// disabled while another exclusive backend op is in flight.
struct AdvancedSettingsView: View {
    @ObservedObject var store: AnkiStore

    // Check database
    @State private var checkRunning = false
    @State private var checkResult: DatabaseCheckSummary?
    @State private var checkError: String?

    // Empty cards
    @State private var emptyCardsRunning = false
    @State private var emptyCards: EmptyCardsSummary?
    @State private var emptyCardsError: String?
    @State private var emptyCardsResult: String?
    @State private var showEmptyCardsConfirm = false

    // Force full sync
    @State private var fullSyncArmed = false
    @State private var showFullSyncConfirm = false
    @State private var fullSyncMessage: String?

    // Restore from backup
    @State private var backups: [BackupFile] = []
    @State private var restoreTarget: BackupFile?
    @State private var restoreRunning = false
    @State private var restoreMessage: String?

    var body: some View {
        Form {
            checkDatabaseSection
            emptyCardsSection
            fullSyncSection
            restoreSection
        }
        .scrollContentBackground(.hidden)
        .background(DS.background.ignoresSafeArea())
        .tint(DS.accent)
        .navigationTitle("Advanced")
        .navigationBarTitleDisplayMode(.inline)
        .disabled(store.isBackendBusy)
        .task {
            backups = store.backupFiles()
            fullSyncArmed = await store.isFullSyncArmed()
            // Screenshot/automation hooks: auto-run a maintenance action so the
            // result is visible for a screenshot.
            if ProcessInfo.processInfo.arguments.contains("-demoCheckDatabase") {
                await performCheckDatabase()
            } else if ProcessInfo.processInfo.arguments.contains("-demoEmptyCards") {
                await performFindEmptyCards()
            }
        }
        .confirmationDialog(
            "Delete empty cards?",
            isPresented: $showEmptyCardsConfirm,
            titleVisibility: .visible,
            presenting: emptyCards
        ) { summary in
            Button("Delete \(summary.cardCount) Cards", role: .destructive) {
                Task { await performDeleteEmptyCards(summary) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { summary in
            Text(summary.headline)
        }
        .alert("Force full sync?", isPresented: $showFullSyncConfirm) {
            Button("Force Full Sync") { Task { await performArmFullSync() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("On your next sync your entire collection will be uploaded or downloaded in one direction, rather than the usual quick sync. Use this to resolve a sync conflict. It won't sync now.")
        }
        .confirmationDialog(
            "Restore this backup?",
            isPresented: Binding(
                get: { restoreTarget != nil },
                set: { if !$0 { restoreTarget = nil } }
            ),
            titleVisibility: .visible,
            presenting: restoreTarget
        ) { file in
            Button("Restore & Replace Collection", role: .destructive) {
                Task { await performRestore(file) }
            }
            Button("Cancel", role: .cancel) { restoreTarget = nil }
        } message: { file in
            Text("This replaces your entire collection with “\(file.name)”. Your current cards, decks, and study progress will be lost. This can't be undone.")
        }
    }

    // MARK: - Check database

    private var checkDatabaseSection: some View {
        Section {
            Button {
                Task { await performCheckDatabase() }
            } label: {
                HStack {
                    Label("Check database", systemImage: "stethoscope")
                        .foregroundStyle(DS.accent)
                    if checkRunning {
                        Spacer()
                        ProgressView()
                    }
                }
            }
            .disabled(checkRunning)
            .accessibilityIdentifier("checkDatabase")

            if let checkError {
                Text(checkError)
                    .font(DS.Typography.caption)
                    .foregroundStyle(DS.again)
            } else if let checkResult {
                Text(checkResult.headline)
                    .font(DS.Typography.caption)
                    .foregroundStyle(checkResult.isHealthy ? DS.easy : DS.textSecondary)
                    .accessibilityIdentifier("checkDatabaseResult")
                ForEach(Array(checkResult.problems.enumerated()), id: \.offset) { _, problem in
                    Text("• \(problem)")
                        .font(DS.Typography.caption)
                        .foregroundStyle(DS.textSecondary)
                }
            }
        } header: {
            sectionHeader("Check database")
        } footer: {
            sectionFooter("Runs a full integrity check and repair of your collection, then optimizes it. Fixes problems from crashes or bad imports.")
        }
        .font(DS.Typography.body)
        .foregroundStyle(DS.textPrimary)
    }

    // MARK: - Empty cards

    private var emptyCardsSection: some View {
        Section {
            Button {
                Task { await performFindEmptyCards() }
            } label: {
                HStack {
                    Label("Find empty cards", systemImage: "rectangle.dashed")
                        .foregroundStyle(DS.accent)
                    if emptyCardsRunning {
                        Spacer()
                        ProgressView()
                    }
                }
            }
            .disabled(emptyCardsRunning)
            .accessibilityIdentifier("findEmptyCards")

            if let emptyCardsError {
                Text(emptyCardsError)
                    .font(DS.Typography.caption)
                    .foregroundStyle(DS.again)
            } else if let emptyCards {
                Text(emptyCards.headline)
                    .font(DS.Typography.caption)
                    .foregroundStyle(DS.textSecondary)
                    .accessibilityIdentifier("emptyCardsResult")
                if !emptyCards.isEmpty {
                    Button(role: .destructive) {
                        showEmptyCardsConfirm = true
                    } label: {
                        Label("Delete empty cards", systemImage: "trash")
                    }
                }
            }
            if let emptyCardsResult {
                Text(emptyCardsResult)
                    .font(DS.Typography.caption)
                    .foregroundStyle(DS.easy)
            }
        } header: {
            sectionHeader("Empty cards")
        } footer: {
            sectionFooter("Finds cards whose template produces no content (often from cloze notes or template edits). Deleting them removes any note left with no cards.")
        }
        .font(DS.Typography.body)
        .foregroundStyle(DS.textPrimary)
    }

    // MARK: - Force full sync

    private var fullSyncSection: some View {
        Section {
            Button {
                showFullSyncConfirm = true
            } label: {
                Label("Force full sync", systemImage: "arrow.triangle.2.circlepath")
                    .foregroundStyle(DS.accent)
            }
            .accessibilityIdentifier("forceFullSync")

            if fullSyncArmed {
                Label("A full sync is scheduled for your next sync.", systemImage: "checkmark.circle")
                    .font(DS.Typography.caption)
                    .foregroundStyle(DS.easy)
                    .accessibilityIdentifier("fullSyncArmed")
            }
            if let fullSyncMessage {
                Text(fullSyncMessage)
                    .font(DS.Typography.caption)
                    .foregroundStyle(DS.textSecondary)
            }
        } header: {
            sectionHeader("Sync")
        } footer: {
            sectionFooter("Forces the next sync to upload or download your whole collection in one direction. Use this to recover from a sync conflict. It doesn't sync right now.")
        }
        .font(DS.Typography.body)
        .foregroundStyle(DS.textPrimary)
    }

    // MARK: - Restore from backup

    private var restoreSection: some View {
        Section {
            if backups.isEmpty {
                Text("No backups found.")
                    .font(DS.Typography.body)
                    .foregroundStyle(DS.textSecondary)
            } else {
                ForEach(backups) { file in
                    Button {
                        restoreTarget = file
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(file.modified.formatted(date: .abbreviated, time: .shortened))
                                .font(DS.Typography.body)
                                .foregroundStyle(DS.textPrimary)
                            Text("\(file.name) • \(byteString(file.size))")
                                .font(DS.Typography.caption)
                                .foregroundStyle(DS.textSecondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    .disabled(restoreRunning)
                }
            }
            if restoreRunning {
                HStack {
                    ProgressView()
                    Text("Restoring…")
                        .font(DS.Typography.caption)
                        .foregroundStyle(DS.textSecondary)
                }
            }
            if let restoreMessage {
                Text(restoreMessage)
                    .font(DS.Typography.caption)
                    .foregroundStyle(DS.textSecondary)
            }
        } header: {
            sectionHeader("Restore from backup")
        } footer: {
            sectionFooter("Replaces your whole collection with a backup snapshot (newest first). Anki writes these automatically and from “Create backup now”.")
        }
        .accessibilityIdentifier("restoreFromBackup")
    }

    // MARK: - Actions

    private func performCheckDatabase() async {
        checkRunning = true
        checkError = nil
        checkResult = nil
        defer { checkRunning = false }
        do {
            checkResult = try await store.checkDatabase()
        } catch {
            checkError = "Check failed: \(error.localizedDescription)"
        }
    }

    private func performFindEmptyCards() async {
        emptyCardsRunning = true
        emptyCardsError = nil
        emptyCards = nil
        emptyCardsResult = nil
        defer { emptyCardsRunning = false }
        do {
            emptyCards = try await store.emptyCardsSummary()
        } catch {
            emptyCardsError = "Couldn't check for empty cards: \(error.localizedDescription)"
        }
    }

    private func performDeleteEmptyCards(_ summary: EmptyCardsSummary) async {
        do {
            let removed = try await store.deleteEmptyCards(summary.cardIDsToDelete)
            emptyCards = nil
            emptyCardsResult = removed == 1 ? "Deleted 1 empty card." : "Deleted \(removed) empty cards."
        } catch {
            emptyCardsError = "Delete failed: \(error.localizedDescription)"
        }
    }

    private func performArmFullSync() async {
        do {
            try await store.armFullSync()
            fullSyncArmed = true
            fullSyncMessage = "Full sync scheduled. It will run on your next sync."
        } catch {
            fullSyncMessage = "Couldn't schedule a full sync: \(error.localizedDescription)"
        }
    }

    private func performRestore(_ file: BackupFile) async {
        restoreTarget = nil
        restoreRunning = true
        restoreMessage = nil
        defer { restoreRunning = false }
        do {
            _ = try await store.restoreBackup(file)
            restoreMessage = "Collection restored from \(file.name)."
            backups = store.backupFiles()
        } catch {
            restoreMessage = "Restore failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Helpers

    private func byteString(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
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
