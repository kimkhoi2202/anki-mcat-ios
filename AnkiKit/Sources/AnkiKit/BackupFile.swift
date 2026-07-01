import Foundation

/// A `.colpkg` backup snapshot on disk, used by "Restore from backup" to list
/// the collection backups Anki writes into its backup folder (via
/// `createBackup`). Listing and newest-first sorting live here — pure and
/// testable — while the UI formats the date and drives the restore.
public struct BackupFile: Equatable, Sendable, Identifiable {
    /// The backup file's location on disk.
    public let url: URL
    /// The file's last-modified time, used to sort and to show "when".
    public let modified: Date
    /// The file's size in bytes (shown alongside the date).
    public let size: Int64

    public var id: URL { url }

    /// The filename shown to the user (e.g. `backup-2026-06-30-20.00.15.colpkg`).
    public var name: String { url.lastPathComponent }

    public init(url: URL, modified: Date, size: Int64) {
        self.url = url
        self.modified = modified
        self.size = size
    }

    /// Lists the `.colpkg` backups in `folder`, newest first. Non-`.colpkg`
    /// files are ignored, and a missing folder yields an empty list (never an
    /// error) so the restore screen simply shows "no backups". File attributes
    /// are read via `URLResourceValues`; entries whose attributes can't be read
    /// fall back to the distant past / zero size so they sort last rather than
    /// being dropped.
    public static func list(
        in folder: URL, fileManager: FileManager = .default
    ) -> [BackupFile] {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        let backups = entries
            .filter { $0.pathExtension.lowercased() == "colpkg" }
            .map { url -> BackupFile in
                let values = try? url.resourceValues(
                    forKeys: [.contentModificationDateKey, .fileSizeKey]
                )
                return BackupFile(
                    url: url,
                    modified: values?.contentModificationDate ?? .distantPast,
                    size: Int64(values?.fileSize ?? 0)
                )
            }
        return sortedNewestFirst(backups)
    }

    /// Orders backups newest first, breaking ties by name (descending) so the
    /// order is stable when two files share a timestamp. Pure so it's directly
    /// unit-testable without touching the filesystem.
    public static func sortedNewestFirst(_ files: [BackupFile]) -> [BackupFile] {
        files.sorted { lhs, rhs in
            if lhs.modified != rhs.modified { return lhs.modified > rhs.modified }
            return lhs.name > rhs.name
        }
    }
}
