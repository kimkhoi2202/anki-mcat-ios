import Foundation
import SwiftProtobuf

/// Notetype convenience methods. Service/method indices come from the generated
/// `_backend_generated.py` reference.
public extension Backend {
    /// NotetypesService.getNotetype (23, 6).
    ///
    /// Returns the notetype's CSS (`Notetype.config.css`) — the styling Anki
    /// applies to the `.card` element. This is the same string the card renderer
    /// emits in `RenderCardResponse.css` (rslib sets it to `notetype.config.css`),
    /// exposed here as the explicit `get_notetype`-based accessor.
    func notetypeCSS(notetypeID: Int64) throws -> String {
        var req = Anki_Notetypes_NotetypeId()
        req.ntid = notetypeID
        let notetype = try run(service: 23, method: 6, req, returning: Anki_Notetypes_Notetype.self)
        return notetype.config.css
    }
}
