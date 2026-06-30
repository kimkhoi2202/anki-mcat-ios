import Foundation
import SwiftProtobuf

/// Media convenience methods. Service/method indices come from the generated
/// `_backend_generated.py` reference (the `BackendMediaService` dispatch index).
public extension Backend {
    /// MediaService.addMediaFile (41, 1).
    ///
    /// Writes `data` into the open collection's `collection.media` folder under a
    /// safe, deduplicated name derived from `desiredName`, registers it in the
    /// media DB (so the next media sync uploads it), and returns the *stored*
    /// filename — which may differ from `desiredName` if the engine had to rename
    /// it to avoid a collision (e.g. `image.png` → `image_1.png`) or to sanitize
    /// it. Mirrors AnkiDroid's `col.backend.addMediaFile(desiredName:, data:)`
    /// (`Media.addFile`), so the stored name is the one to embed in a field as
    /// `<img src="NAME">` or `[sound:NAME]`.
    ///
    /// `BackendMediaService` is declared empty in `media.proto`, so every
    /// `MediaService` method is a *delegating* method whose index is its position
    /// within `MediaService` — `AddMediaFile` is the 2nd RPC, hence method 1.
    func addMediaFile(desiredName: String, data: Data) throws -> String {
        var req = Anki_Media_AddMediaFileRequest()
        req.desiredName = desiredName
        req.data = data
        return try run(service: 41, method: 1, req, returning: Anki_Generic_String.self).val
    }
}
