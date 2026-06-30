import Foundation
import SwiftProtobuf

/// Import/export of Anki packages (`.apkg` decks and `.colpkg` whole
/// collections), cloning AnkiDroid's `BackendImportExport.kt` plus the
/// `CollectionManager.importColpkg` / `BackendExporting.exportCollectionPackage`
/// lifecycles.
///
/// These wrap Anki's `BackendImportExportService` (service index **39**).
/// Service/method indices come from the generated `_backend_generated.py`
/// reference and match `proto/anki/import_export.proto`. The two methods defined
/// directly on the backend service come first; the rest are delegated from the
/// collection `ImportExportService`, offset by that count of two:
///
/// | method                  | index | request                          | response             |
/// |-------------------------|-------|----------------------------------|----------------------|
/// | importCollectionPackage | 0     | ImportCollectionPackageRequest   | Empty                |
/// | exportCollectionPackage | 1     | ExportCollectionPackageRequest   | Empty                |
/// | importAnkiPackage       | 2     | ImportAnkiPackageRequest         | ImportResponse       |
/// | getImportAnkiPackagePresets | 3 | Empty                            | ImportAnkiPackageOptions |
/// | exportAnkiPackage       | 4     | ExportAnkiPackageRequest         | generic.UInt32       |
///
/// `.apkg` import/export act on the open collection. `.colpkg` import/export
/// change the collection file itself, so the app must manage the open/close
/// lifecycle around them (see `AnkiStore`).
public extension Backend {
    private enum ImportExportMethod {
        static let importCollectionPackage: UInt32 = 0
        static let exportCollectionPackage: UInt32 = 1
        static let importAnkiPackage: UInt32 = 2
        static let getImportAnkiPackagePresets: UInt32 = 3
        static let exportAnkiPackage: UInt32 = 4
    }
    private static let importExportService: UInt32 = 39

    // MARK: - Anki package (.apkg)

    /// ImportExportService.getImportAnkiPackagePresets (39, 3). The user's saved
    /// import options (merge notetypes, update conditions, with-scheduling),
    /// read from the open collection's config — the defaults AnkiDroid's import
    /// screen starts from.
    func importAnkiPackagePresets() throws -> Anki_ImportExport_ImportAnkiPackageOptions {
        try run(
            service: Self.importExportService, method: ImportExportMethod.getImportAnkiPackagePresets,
            Anki_Generic_Empty(), returning: Anki_ImportExport_ImportAnkiPackageOptions.self
        )
    }

    /// ImportExportService.importAnkiPackage (39, 2). Imports the notes/cards (and
    /// any bundled media) from a `.apkg` into the open collection.
    ///
    /// Passing `nil` options uses the backend defaults (update existing notes if
    /// newer, don't merge notetypes, strip scheduling), matching a plain
    /// shared-deck import. The change is undoable via the returned op changes.
    @discardableResult
    func importAnkiPackage(
        path: String, options: Anki_ImportExport_ImportAnkiPackageOptions? = nil
    ) throws -> ImportResult {
        var req = Anki_ImportExport_ImportAnkiPackageRequest()
        req.packagePath = path
        if let options { req.options = options }
        let resp = try run(
            service: Self.importExportService, method: ImportExportMethod.importAnkiPackage,
            req, returning: Anki_ImportExport_ImportResponse.self
        )
        return ImportResult(resp.log)
    }

    /// ImportExportService.exportAnkiPackage (39, 4). Writes the notes selected by
    /// `limit` to a `.apkg` at `outPath`, returning the number of notes exported.
    ///
    /// `legacy: false` produces a modern (zstd) package that only recent Anki
    /// versions can open; pass `true` for an older-compatible file.
    @discardableResult
    func exportAnkiPackage(
        outPath: String,
        limit: Anki_ImportExport_ExportLimit,
        withScheduling: Bool = true,
        withDeckConfigs: Bool = true,
        withMedia: Bool = true,
        legacy: Bool = false
    ) throws -> Int {
        var options = Anki_ImportExport_ExportAnkiPackageOptions()
        options.withScheduling = withScheduling
        options.withDeckConfigs = withDeckConfigs
        options.withMedia = withMedia
        options.legacy = legacy

        var req = Anki_ImportExport_ExportAnkiPackageRequest()
        req.outPath = outPath
        req.options = options
        req.limit = limit

        let resp = try run(
            service: Self.importExportService, method: ImportExportMethod.exportAnkiPackage,
            req, returning: Anki_Generic_UInt32.self
        )
        return Int(resp.val)
    }

    /// Convenience: export a single deck (and its subdecks) to a `.apkg`.
    @discardableResult
    func exportAnkiPackage(
        deckID: Int64,
        outPath: String,
        withScheduling: Bool = true,
        withDeckConfigs: Bool = true,
        withMedia: Bool = true,
        legacy: Bool = false
    ) throws -> Int {
        try exportAnkiPackage(
            outPath: outPath, limit: Self.exportLimit(deckID: deckID),
            withScheduling: withScheduling, withDeckConfigs: withDeckConfigs,
            withMedia: withMedia, legacy: legacy
        )
    }

    /// An `ExportLimit` scoped to one deck (its id).
    static func exportLimit(deckID: Int64) -> Anki_ImportExport_ExportLimit {
        var limit = Anki_ImportExport_ExportLimit()
        limit.deckID = deckID
        return limit
    }

    /// An `ExportLimit` covering the whole collection.
    static func wholeCollectionExportLimit() -> Anki_ImportExport_ExportLimit {
        var limit = Anki_ImportExport_ExportLimit()
        limit.wholeCollection = Anki_Generic_Empty()
        return limit
    }

    // MARK: - Collection package (.colpkg)

    /// ImportExportService.importCollectionPackage (39, 0). Replaces the on-disk
    /// collection (and media) with the contents of a `.colpkg`.
    ///
    /// The collection **must be closed** before calling and reopened afterwards
    /// (clone of AnkiDroid's `importCollectionPackage` contract). `colPath`,
    /// `mediaFolder`, and `mediaDB` are the destination paths the collection will
    /// be reopened from; `backupPath` is the source `.colpkg`.
    func importCollectionPackage(
        colPath: String, backupPath: String, mediaFolder: String, mediaDB: String
    ) throws {
        var req = Anki_ImportExport_ImportCollectionPackageRequest()
        req.colPath = colPath
        req.backupPath = backupPath
        req.mediaFolder = mediaFolder
        req.mediaDb = mediaDB
        _ = try run(
            service: Self.importExportService, method: ImportExportMethod.importCollectionPackage,
            input: try req.serializedData()
        )
    }

    /// ImportExportService.exportCollectionPackage (39, 1). Writes the whole
    /// collection to a `.colpkg` at `outPath`.
    ///
    /// The core takes the open collection to export it, leaving it **closed**;
    /// the caller must reopen afterwards (clone of AnkiDroid's
    /// `exportCollectionPackage`, which wraps the backend call in
    /// `close(forFullSync)` / `reopen()`).
    func exportCollectionPackage(
        outPath: String, includeMedia: Bool, legacy: Bool = false
    ) throws {
        var req = Anki_ImportExport_ExportCollectionPackageRequest()
        req.outPath = outPath
        req.includeMedia = includeMedia
        req.legacy = legacy
        _ = try run(
            service: Self.importExportService, method: ImportExportMethod.exportCollectionPackage,
            input: try req.serializedData()
        )
    }
}

/// A view-facing summary of an `.apkg` import, decoded from the backend's
/// `ImportResponse.Log`. Mirrors the categories AnkiDroid's import-result page
/// reports; `imported` is the count of newly added notes.
public struct ImportResult: Sendable, Equatable {
    /// Total notes found in the package.
    public let found: Int
    /// Notes newly added to the collection.
    public let imported: Int
    /// Existing notes that were updated.
    public let updated: Int
    /// Notes skipped as exact duplicates.
    public let duplicate: Int
    /// Notes that conflicted with existing notes (same id, different content).
    public let conflicting: Int

    init(_ log: Anki_ImportExport_ImportResponse.Log) {
        found = Int(log.foundNotes)
        imported = log.new.count
        updated = log.updated.count
        duplicate = log.duplicate.count
        conflicting = log.conflicting.count
    }
}
