import Foundation
import SwiftProtobuf

/// AnkiWeb-compatible sync convenience methods.
///
/// These wrap Anki's `BackendSyncService` (service index 1). Service/method
/// indices are taken from the generated `_backend_generated.py` reference and
/// match `proto/anki/sync.proto`:
///
/// | method | index | request                       | response                  |
/// |--------|-------|-------------------------------|---------------------------|
/// | syncMedia            | 0 | SyncAuth                | Empty (starts background) |
/// | abortMediaSync       | 1 | Empty                   | Empty                     |
/// | mediaSyncStatus      | 2 | Empty                   | MediaSyncStatusResponse   |
/// | syncLogin            | 3 | SyncLoginRequest        | SyncAuth                  |
/// | syncStatus           | 4 | SyncAuth                | SyncStatusResponse        |
/// | syncCollection       | 5 | SyncCollectionRequest   | SyncCollectionResponse    |
/// | fullUploadOrDownload | 6 | FullUploadOrDownload…   | Empty                     |
/// | abortSync            | 7 | Empty                   | Empty                     |
///
/// The orchestration (normal sync, full-sync conflict, media polling) mirrors
/// AnkiDroid's `Sync.kt` (`handleNormalSync` / `handleDownload` / `handleUpload`
/// / `monitorMediaSync`); see `AnkiStore` in the app for the cloned flow.
public extension Backend {
    private enum SyncMethod {
        static let media: UInt32 = 0
        static let abortMedia: UInt32 = 1
        static let mediaStatus: UInt32 = 2
        static let login: UInt32 = 3
        static let status: UInt32 = 4
        static let collection: UInt32 = 5
        static let fullUploadOrDownload: UInt32 = 6
        static let abort: UInt32 = 7
    }
    private static let syncService: UInt32 = 1

    /// Builds a `SyncAuth` from a stored host key and optional custom endpoint.
    ///
    /// A nil/empty `endpoint` means the default server (AnkiWeb). `ioTimeoutSecs`
    /// mirrors AnkiDroid's `Prefs.networkTimeoutSecs` when provided.
    static func syncAuth(
        hkey: String, endpoint: String? = nil, ioTimeoutSecs: UInt32? = nil
    ) -> Anki_Sync_SyncAuth {
        var auth = Anki_Sync_SyncAuth()
        auth.hkey = hkey
        if let endpoint, !endpoint.isEmpty { auth.endpoint = endpoint }
        if let ioTimeoutSecs { auth.ioTimeoutSecs = ioTimeoutSecs }
        return auth
    }

    /// SyncService.syncLogin (1, 3). Exchanges username/password for a host key.
    ///
    /// `endpoint` is the custom server base URL (e.g. `http://localhost:8080/`);
    /// nil/empty uses the default AnkiWeb server. The returned `SyncAuth` carries
    /// the `hkey` and echoes back the `endpoint` that was supplied.
    func syncLogin(
        username: String, password: String, endpoint: String? = nil
    ) throws -> Anki_Sync_SyncAuth {
        var req = Anki_Sync_SyncLoginRequest()
        req.username = username
        req.password = password
        if let endpoint, !endpoint.isEmpty { req.endpoint = endpoint }
        return try run(
            service: Self.syncService, method: SyncMethod.login,
            req, returning: Anki_Sync_SyncAuth.self
        )
    }

    /// SyncService.syncStatus (1, 4). Lightweight check of what kind of sync is
    /// needed. Returns offline (no network round-trip) when the local collection
    /// already has unsynced changes.
    func syncStatus(auth: Anki_Sync_SyncAuth) throws -> Anki_Sync_SyncStatusResponse {
        try run(
            service: Self.syncService, method: SyncMethod.status,
            auth, returning: Anki_Sync_SyncStatusResponse.self
        )
    }

    /// SyncService.syncCollection (1, 5). Performs a normal (incremental) sync.
    ///
    /// AnkiDroid passes `syncMedia = false` here and syncs media separately via
    /// `syncMedia`/`mediaSyncStatus`; the response's `required` field reports
    /// whether a full sync (or a forced upload/download) is needed instead.
    func syncCollection(
        auth: Anki_Sync_SyncAuth, syncMedia: Bool
    ) throws -> Anki_Sync_SyncCollectionResponse {
        var req = Anki_Sync_SyncCollectionRequest()
        req.auth = auth
        req.syncMedia = syncMedia
        return try run(
            service: Self.syncService, method: SyncMethod.collection,
            req, returning: Anki_Sync_SyncCollectionResponse.self
        )
    }

    /// SyncService.fullUploadOrDownload (1, 6). Replaces the whole collection in
    /// one direction (upload = local → server, download = server → local).
    ///
    /// The core requires the collection to be **open**, then takes, replaces and
    /// re-opens it internally regardless of outcome (`full_sync_inner` in
    /// `rslib/src/backend/sync.rs`). This is why — unlike AnkiDroid, which calls
    /// `close(forFullSync)`/`reopen(afterFullSync)` to drop its own Kotlin-side DB
    /// handle and model cache — this thin Swift wrapper does **not** close first.
    ///
    /// When `serverUsn` is supplied the core also kicks off a background media
    /// sync after a successful full sync; poll `mediaSyncStatus()` to monitor it.
    func fullUploadOrDownload(
        auth: Anki_Sync_SyncAuth, upload: Bool, serverUsn: Int32? = nil
    ) throws {
        var req = Anki_Sync_FullUploadOrDownloadRequest()
        req.auth = auth
        req.upload = upload
        if let serverUsn { req.serverUsn = serverUsn }
        _ = try run(
            service: Self.syncService, method: SyncMethod.fullUploadOrDownload,
            input: try req.serializedData()
        )
    }

    /// Full upload: replace the server's collection with this device's.
    func fullUpload(auth: Anki_Sync_SyncAuth, serverUsn: Int32? = nil) throws {
        try fullUploadOrDownload(auth: auth, upload: true, serverUsn: serverUsn)
    }

    /// Full download: replace this device's collection with the server's.
    func fullDownload(auth: Anki_Sync_SyncAuth, serverUsn: Int32? = nil) throws {
        try fullUploadOrDownload(auth: auth, upload: false, serverUsn: serverUsn)
    }

    /// SyncService.syncMedia (1, 0). Starts a media sync on a background thread
    /// and returns immediately; poll `mediaSyncStatus()` for progress/completion.
    func syncMedia(auth: Anki_Sync_SyncAuth) throws {
        _ = try run(
            service: Self.syncService, method: SyncMethod.media,
            input: try auth.serializedData()
        )
    }

    /// SyncService.mediaSyncStatus (1, 2). Returns the current media-sync
    /// progress and whether it is still `active`. Throws if the background media
    /// sync terminated with an error (the error surfaces on the next poll).
    func mediaSyncStatus() throws -> Anki_Sync_MediaSyncStatusResponse {
        try run(
            service: Self.syncService, method: SyncMethod.mediaStatus,
            Anki_Generic_Empty(), returning: Anki_Sync_MediaSyncStatusResponse.self
        )
    }

    /// SyncService.abortSync (1, 7). Requests cancellation of an in-progress
    /// collection sync.
    func abortSync() throws {
        _ = try run(
            service: Self.syncService, method: SyncMethod.abort,
            input: try Anki_Generic_Empty().serializedData()
        )
    }

    /// SyncService.abortMediaSync (1, 1). Requests cancellation of an in-progress
    /// media sync (does not wait for it to stop).
    func abortMediaSync() throws {
        _ = try run(
            service: Self.syncService, method: SyncMethod.abortMedia,
            input: try Anki_Generic_Empty().serializedData()
        )
    }
}

/// A sync failure classified for UI handling, decoded from the protobuf
/// `BackendError` carried by `AnkiError.backendError`.
///
/// Mirrors the cases AnkiDroid reacts to: `BackendSyncAuthFailedException`
/// (clear the saved key and force re-login), network errors, server messages,
/// and user-initiated interruption.
public struct SyncError: Error, Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        /// Bad username/password, or an expired/invalid host key.
        case authFailed
        /// Offline, connection refused, TLS failure, or timeout.
        case network
        /// The server asked the client to display a message (e.g. clock skew,
        /// account disabled, too-large collection).
        case serverMessage
        /// The sync was aborted by the user.
        case interrupted
        /// Any other backend error.
        case other
    }

    public let kind: Kind
    /// Localized, user-facing description from the core (may be empty).
    public let message: String

    /// Decodes an `Error` thrown by `Backend` into a `SyncError`, or returns nil
    /// if it is not a backend protobuf error.
    public init?(_ error: Error) {
        guard case let AnkiError.backendError(data) = error,
              let backendError = try? Anki_Backend_BackendError(serializedBytes: data)
        else { return nil }
        self.message = backendError.message
        switch backendError.kind {
        case .syncAuthError: self.kind = .authFailed
        case .networkError: self.kind = .network
        case .syncServerMessage: self.kind = .serverMessage
        case .interrupted: self.kind = .interrupted
        default: self.kind = .other
        }
    }
}
