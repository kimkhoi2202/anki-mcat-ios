import Foundation
import SwiftProtobuf
import AnkiCoreFFI

/// Errors surfaced from the Anki Rust backend.
public enum AnkiError: Error {
    case openBackendFailed
    /// A protobuf-encoded `backend.proto` BackendError returned by the core.
    case backendError(Data)
}

/// Swift wrapper over Anki's Rust core (via the AnkiCore C-ABI).
///
/// Every backend call funnels through `run(service:method:input:)`, mirroring
/// `pylib/anki/_backend.py`. Service/method indices come from the generated
/// `_backend_generated.py` reference.
///
/// `@unchecked Sendable`: the wrapper holds only an opaque handle, and the Rust
/// core behind it is `Send + Sync` — it guards the collection with a mutex and
/// is explicitly designed for concurrent use (e.g. media sync runs on a
/// background thread while the foreground polls `media_sync_status`). This lets
/// callers offload the blocking sync calls onto a background task while keeping
/// the UI responsive.
public final class Backend: @unchecked Sendable {
    private let handle: UnsafeMutableRawPointer

    public init(preferredLangs: [String] = ["en"]) throws {
        var initMsg = Anki_Backend_BackendInit()
        initMsg.preferredLangs = preferredLangs
        let data = try initMsg.serializedData()
        let opened: UnsafeMutableRawPointer? = data.withUnsafeBytes { raw in
            anki_open_backend(raw.bindMemory(to: UInt8.self).baseAddress, raw.count)
        }
        guard let opened else { throw AnkiError.openBackendFailed }
        self.handle = opened
    }

    deinit {
        anki_close_backend(handle)
    }

    /// Build hash of the linked Anki core.
    public static func buildHash() -> String {
        guard let c = anki_buildhash() else { return "" }
        defer { anki_free_cstring(c) }
        return String(cString: c)
    }

    /// Raw protobuf service dispatch.
    public func run(service: UInt32, method: UInt32, input: Data) throws -> Data {
        let result = input.withUnsafeBytes { raw in
            anki_run_command(
                handle, service, method,
                raw.bindMemory(to: UInt8.self).baseAddress, raw.count
            )
        }
        defer { anki_free_bytes(result) }
        let bytes: Data
        if let ptr = result.ptr {
            bytes = Data(bytes: ptr, count: result.len)
        } else {
            bytes = Data()
        }
        if result.is_error {
            throw AnkiError.backendError(bytes)
        }
        return bytes
    }

    /// Typed protobuf dispatch helper.
    public func run<Req: SwiftProtobuf.Message, Resp: SwiftProtobuf.Message>(
        service: UInt32, method: UInt32, _ request: Req, returning: Resp.Type
    ) throws -> Resp {
        let out = try run(service: service, method: method, input: try request.serializedData())
        return try Resp(serializedBytes: out)
    }

    // MARK: - Typed convenience methods

    /// CollectionService.openCollection (service 3, method 0).
    @discardableResult
    public func openCollection(
        path: String, mediaFolder: String = "", mediaDB: String = ""
    ) throws -> Anki_Generic_Empty {
        var req = Anki_Collection_OpenCollectionRequest()
        req.collectionPath = path
        req.mediaFolderPath = mediaFolder
        req.mediaDbPath = mediaDB
        return try run(service: 3, method: 0, req, returning: Anki_Generic_Empty.self)
    }

    /// DecksService.getDeckNames (service 7, method 13).
    public func deckNames(
        skipEmptyDefault: Bool = false, includeFiltered: Bool = true
    ) throws -> [(id: Int64, name: String)] {
        var req = Anki_Decks_GetDeckNamesRequest()
        req.skipEmptyDefault = skipEmptyDefault
        req.includeFiltered = includeFiltered
        let resp = try run(service: 7, method: 13, req, returning: Anki_Decks_DeckNames.self)
        return resp.entries.map { (id: $0.id, name: $0.name) }
    }
}
