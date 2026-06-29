import Foundation
import SwiftProtobuf

/// Undo convenience methods. Service/method indices come from the generated
/// `_backend_generated.py` reference (CollectionService).
public extension Backend {
    /// CollectionService.getUndoStatus (3, 7).
    ///
    /// `undo` is the localized name of the next undoable action (e.g.
    /// "Answer Card"), or the empty string when there is nothing to undo.
    func undoStatus() throws -> Anki_Collection_UndoStatus {
        try run(service: 3, method: 7, Anki_Generic_Empty(), returning: Anki_Collection_UndoStatus.self)
    }

    /// CollectionService.undo (3, 8).
    ///
    /// Reverts the most recent undoable operation and returns the resulting
    /// changes (including the refreshed `new_status`).
    @discardableResult
    func undo() throws -> Anki_Collection_OpChangesAfterUndo {
        try run(service: 3, method: 8, Anki_Generic_Empty(), returning: Anki_Collection_OpChangesAfterUndo.self)
    }
}
