import Foundation
import SwiftProtobuf

/// When importing a `.apkg`, how to treat notes / note types that already exist
/// in the collection — a UI-neutral mirror of the engine's
/// `ImportAnkiPackageUpdateCondition` (Anki's "Update" dropdown in the import
/// options: *If newer* / *Always* / *Never*). Kept in `AnkiKit` (rather than the
/// app) so the proto mapping is unit-testable without the UI layer.
public enum ApkgImportUpdateCondition: Sendable, CaseIterable, Hashable {
    /// Overwrite the existing note/note type only when the imported one is newer
    /// (the engine default).
    case ifNewer
    /// Always overwrite with the imported version.
    case always
    /// Never overwrite; keep the existing version.
    case never

    /// The generated proto enum this maps to for the import request.
    public var proto: Anki_ImportExport_ImportAnkiPackageUpdateCondition {
        switch self {
        case .ifNewer: return .ifNewer
        case .always: return .always
        case .never: return .never
        }
    }

    /// Maps a proto update-condition back to the UI enum, falling back to
    /// `.ifNewer` (the engine default) for the unrecognised case so presets read
    /// from an unknown future engine can't produce an invalid selection.
    public init(_ proto: Anki_ImportExport_ImportAnkiPackageUpdateCondition) {
        switch proto {
        case .ifNewer: self = .ifNewer
        case .always: self = .always
        case .never: self = .never
        case .UNRECOGNIZED: self = .ifNewer
        }
    }
}

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
/// | getCsvMetadata          | 5     | CsvMetadataRequest               | CsvMetadata          |
/// | importCsv               | 6     | ImportCsvRequest                 | ImportResponse       |
/// | exportNoteCsv           | 7     | ExportNoteCsvRequest             | generic.UInt32       |
/// | exportCardCsv           | 8     | ExportCardCsvRequest             | generic.UInt32       |
///
/// `.apkg` import/export and CSV/text import/export act on the open collection.
/// `.colpkg` import/export change the collection file itself, so the app must
/// manage the open/close lifecycle around them (see `AnkiStore`).
public extension Backend {
    private enum ImportExportMethod {
        static let importCollectionPackage: UInt32 = 0
        static let exportCollectionPackage: UInt32 = 1
        static let importAnkiPackage: UInt32 = 2
        static let getImportAnkiPackagePresets: UInt32 = 3
        static let exportAnkiPackage: UInt32 = 4
        static let getCsvMetadata: UInt32 = 5
        static let importCsv: UInt32 = 6
        static let exportNoteCsv: UInt32 = 7
        static let exportCardCsv: UInt32 = 8
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

    /// Builds an `ImportAnkiPackageOptions` from the individual toggles shown in
    /// the import options UI. Pure/`static` so it's unit-testable without a live
    /// collection: it's what turns the sheet's selections into the proto the
    /// import request carries (Anki's `ImportAnkiPackageOptions`: whether to
    /// update existing notes / note types, merge note types, and keep scheduling
    /// / deck presets).
    static func importAnkiPackageOptions(
        updateNotes: ApkgImportUpdateCondition,
        updateNotetypes: ApkgImportUpdateCondition,
        mergeNotetypes: Bool,
        withScheduling: Bool,
        withDeckConfigs: Bool
    ) -> Anki_ImportExport_ImportAnkiPackageOptions {
        var options = Anki_ImportExport_ImportAnkiPackageOptions()
        options.updateNotes = updateNotes.proto
        options.updateNotetypes = updateNotetypes.proto
        options.mergeNotetypes = mergeNotetypes
        options.withScheduling = withScheduling
        options.withDeckConfigs = withDeckConfigs
        return options
    }

    /// Builds the `ImportAnkiPackageRequest` for a package at `path`, attaching
    /// `options` only when provided (leaving it unset uses the backend defaults).
    /// Pure/`static` so the request assembly is unit-testable.
    static func importAnkiPackageRequest(
        path: String, options: Anki_ImportExport_ImportAnkiPackageOptions? = nil
    ) -> Anki_ImportExport_ImportAnkiPackageRequest {
        var req = Anki_ImportExport_ImportAnkiPackageRequest()
        req.packagePath = path
        if let options { req.options = options }
        return req
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
        let req = Self.importAnkiPackageRequest(path: path, options: options)
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

    // MARK: - CSV / text import

    /// ImportExportService.getCsvMetadata (39, 5). Inspects a `.csv`/`.tsv`/`.txt`
    /// file and returns the engine's detected/derived `CsvMetadata`: the
    /// delimiter, whether the contents are HTML, the column labels (which also
    /// give the column count), a few preview rows, and a default note-type + deck
    /// + field→column mapping the user can then adjust — the data behind Anki's
    /// CSV import wizard.
    ///
    /// Pass `notetypeID`/`deckID` to ask the engine to recompute the default
    /// mapping for a chosen note type / deck (what the desktop does when the user
    /// changes either), and `delimiter`/`isHtml` to override auto-detection
    /// (leaving them `nil` lets the engine detect them). Optional fields are only
    /// set when provided, matching the proto's "unset = auto" convention.
    func getCsvMetadata(
        path: String,
        delimiter: Anki_ImportExport_CsvMetadata.Delimiter? = nil,
        notetypeID: Int64? = nil,
        deckID: Int64? = nil,
        isHtml: Bool? = nil
    ) throws -> Anki_ImportExport_CsvMetadata {
        var req = Anki_ImportExport_CsvMetadataRequest()
        req.path = path
        if let delimiter { req.delimiter = delimiter }
        if let notetypeID { req.notetypeID = notetypeID }
        if let deckID { req.deckID = deckID }
        if let isHtml { req.isHtml = isHtml }
        return try run(
            service: Self.importExportService, method: ImportExportMethod.getCsvMetadata,
            req, returning: Anki_ImportExport_CsvMetadata.self
        )
    }

    /// ImportExportService.importCsv (39, 6). Imports the rows of the file at
    /// `path` into the open collection using the chosen `metadata` (note type,
    /// deck, per-field column mapping, tags column, delimiter, is-HTML, duplicate
    /// handling, …). Returns the same `ImportResult` summary as an `.apkg` import
    /// (found / added / updated / duplicate). The change is undoable.
    @discardableResult
    func importCsv(
        path: String, metadata: Anki_ImportExport_CsvMetadata
    ) throws -> ImportResult {
        var req = Anki_ImportExport_ImportCsvRequest()
        req.path = path
        req.metadata = metadata
        let resp = try run(
            service: Self.importExportService, method: ImportExportMethod.importCsv,
            req, returning: Anki_ImportExport_ImportResponse.self
        )
        return ImportResult(resp.log)
    }

    // MARK: - Notes / cards text (CSV) export

    /// ImportExportService.exportNoteCsv (39, 7). Writes the notes selected by
    /// `limit` to a tab-separated text file at `outPath`, returning the number of
    /// notes exported. The `with*` toggles add optional columns (matching Anki's
    /// text-export dialog): `withHtml` keeps field HTML (off strips it to plain
    /// text), and `withTags`/`withDeck`/`withNotetype`/`withGuid` prepend the
    /// corresponding columns.
    @discardableResult
    func exportNoteCsv(
        outPath: String,
        limit: Anki_ImportExport_ExportLimit,
        withHtml: Bool = false,
        withTags: Bool = true,
        withDeck: Bool = false,
        withNotetype: Bool = false,
        withGuid: Bool = false
    ) throws -> Int {
        var req = Anki_ImportExport_ExportNoteCsvRequest()
        req.outPath = outPath
        req.withHtml = withHtml
        req.withTags = withTags
        req.withDeck = withDeck
        req.withNotetype = withNotetype
        req.withGuid = withGuid
        req.limit = limit
        let resp = try run(
            service: Self.importExportService, method: ImportExportMethod.exportNoteCsv,
            req, returning: Anki_Generic_UInt32.self
        )
        return Int(resp.val)
    }

    /// ImportExportService.exportCardCsv (39, 8). Writes the cards selected by
    /// `limit` to a tab-separated text file at `outPath` (each card's rendered
    /// question/answer), returning the number of cards exported. `withHtml` keeps
    /// the rendered HTML; off strips it to plain text.
    @discardableResult
    func exportCardCsv(
        outPath: String,
        limit: Anki_ImportExport_ExportLimit,
        withHtml: Bool = false
    ) throws -> Int {
        var req = Anki_ImportExport_ExportCardCsvRequest()
        req.outPath = outPath
        req.withHtml = withHtml
        req.limit = limit
        let resp = try run(
            service: Self.importExportService, method: ImportExportMethod.exportCardCsv,
            req, returning: Anki_Generic_UInt32.self
        )
        return Int(resp.val)
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
