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

    // MARK: - Typed & JSON config keys
    //
    // The collection config store also holds a handful of known booleans (a
    // `ConfigKey.Bool` enum) and arbitrary JSON values keyed by string. The
    // Card Browser reads/writes two of these: the notes-vs-cards table mode (a
    // known bool) and the browser sidebar's saved searches (a JSON object). The
    // helpers below wrap the ConfigService RPCs the same way `getPreferences`
    // does.

    /// ConfigService.getConfigBool (service 9, method 5).
    ///
    /// Reads a known boolean collection config; the core returns the key's
    /// default when it has never been set, so this never throws for a valid key.
    func getConfigBool(_ key: Anki_Config_ConfigKey.BoolEnum) throws -> Bool {
        var req = Anki_Config_GetConfigBoolRequest()
        req.key = key
        return try run(service: 9, method: 5, req, returning: Anki_Generic_Bool.self).val
    }

    /// ConfigService.setConfigBool (service 9, method 6). Persists a known
    /// boolean config. `undoable` false (the default) keeps it off the undo
    /// stack — these are view-state toggles, not user-content edits.
    func setConfigBool(_ key: Anki_Config_ConfigKey.BoolEnum, value: Bool, undoable: Bool = false) throws {
        var req = Anki_Config_SetConfigBoolRequest()
        req.key = key
        req.value = value
        req.undoable = undoable
        _ = try run(service: 9, method: 6, input: try req.serializedData())
    }

    /// ConfigService.getConfigJson (service 9, method 0).
    ///
    /// Returns the raw JSON bytes stored under `key`. A key that was never set
    /// comes back as the JSON literal `null` (not an error), so callers decode
    /// defensively (an unparsable / null payload means "absent").
    func getConfigJson(key: String) throws -> Data {
        var req = Anki_Generic_String()
        req.val = key
        return try run(service: 9, method: 0, req, returning: Anki_Generic_Json.self).json
    }

    /// ConfigService.setConfigJson (service 9, method 1). Stores raw JSON bytes
    /// under `key`. `undoable` false (the default) mirrors pylib's
    /// `Collection.set_config`, which does not record an undo step by default.
    func setConfigJson(key: String, valueJSON: Data, undoable: Bool = false) throws {
        var req = Anki_Config_SetConfigJsonRequest()
        req.key = key
        req.valueJson = valueJSON
        req.undoable = undoable
        _ = try run(service: 9, method: 1, input: try req.serializedData())
    }
}
