import Foundation
import SwiftProtobuf

/// Collection preferences convenience methods. Service/method indices come from
/// the generated `_backend_generated.py` reference: `GetPreferences` /
/// `SetPreferences` live on `ConfigService` (its empty backend twin
/// `BackendConfigService {}` delegates every method), which resolves to backend
/// service index 9. Within `ConfigService` they are the 10th and 11th methods,
/// i.e. method indices 9 and 10.
public extension Backend {
    /// ConfigService.getPreferences (service 9, method 9).
    ///
    /// Returns the collection's preferences (scheduling / reviewing / editing /
    /// backups), the same message AnkiDroid reads via `col.getPreferences()`.
    func getPreferences() throws -> Anki_Config_Preferences {
        try run(service: 9, method: 9, Anki_Generic_Empty(), returning: Anki_Config_Preferences.self)
    }

    /// ConfigService.setPreferences (service 9, method 10).
    ///
    /// Persists a (typically read-modify-write) `Preferences` message. Returns
    /// the resulting `OpChanges` so callers can react to what changed, mirroring
    /// AnkiDroid's `undoableOp { setPreferences(newPrefs) }`.
    @discardableResult
    func setPreferences(_ preferences: Anki_Config_Preferences) throws -> Anki_Collection_OpChanges {
        try run(service: 9, method: 10, preferences, returning: Anki_Collection_OpChanges.self)
    }
}
