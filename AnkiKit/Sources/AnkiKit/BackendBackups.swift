import Foundation
import SwiftProtobuf

/// Collection backup convenience methods. Service/method indices come from the
/// generated `_backend_generated.py` reference: `CreateBackup` and
/// `AwaitBackupCompletion` live on `CollectionService` (backend service index 3)
/// as its 3rd and 4th methods, i.e. method indices 2 and 3.
///
/// Mirrors AnkiDroid's `Collection.createBackup`/`awaitBackupCompletion` (see
/// `BackendBackups.kt`), which writes a `.colpkg` snapshot into a backup folder
/// and prunes old backups per the user's `Preferences.backups` limits.
public extension Backend {
    /// CollectionService.createBackup (3, 2).
    ///
    /// Writes a `.colpkg` backup into `backupFolder`. With `force` the configured
    /// minimum interval is ignored (used for an explicit "Create backup now").
    /// When `waitForCompletion` is false the call returns after the initial copy
    /// and the write finishes in the background — poll it with
    /// `awaitBackupCompletion()`. Returns whether a backup was actually created
    /// (the core may skip one if nothing changed and `force` is false).
    @discardableResult
    func createBackup(
        backupFolder: String, force: Bool, waitForCompletion: Bool
    ) throws -> Bool {
        var req = Anki_Collection_CreateBackupRequest()
        req.backupFolder = backupFolder
        req.force = force
        req.waitForCompletion = waitForCompletion
        return try run(
            service: 3, method: 2, req, returning: Anki_Generic_Bool.self
        ).val
    }

    /// CollectionService.awaitBackupCompletion (3, 3).
    ///
    /// Blocks until a backup started by `createBackup(waitForCompletion: false)`
    /// finishes, throwing if it failed (the error is reported once). A no-op when
    /// no backup is running. Call this off the main actor so the UI stays
    /// responsive while the snapshot is written.
    func awaitBackupCompletion() throws {
        _ = try run(
            service: 3, method: 3,
            Anki_Generic_Empty(), returning: Anki_Generic_Empty.self
        )
    }
}
