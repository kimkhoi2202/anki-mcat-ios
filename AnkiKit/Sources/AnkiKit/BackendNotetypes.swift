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

/// A view-facing description of changing a note's note type, decoupled from the
/// generated `ChangeNotetypeInfo`/`ChangeNotetypeRequest` protobufs.
///
/// Mirrors the data AnkiDroid's "Change Note Type" screen needs: the old and new
/// field/template names, plus the engine's *default* mapping (best-effort by
/// name) that the UI can show and let the user adjust. Each map entry is the
/// index of the OLD field/template that fills the corresponding NEW one, or `nil`
/// for "leave empty / discard" (the engine encodes `nil` as `-1`). The template
/// map is empty when a cloze note type is involved (cloze cards can't be
/// remapped, so the engine sets `is_cloze` and ignores the template map).
public struct ChangeNotetypeInfo: Sendable, Equatable {
    public let oldNotetypeID: Int64
    public let newNotetypeID: Int64
    public let oldNotetypeName: String
    /// The collection's schema timestamp at fetch time. Passed back unchanged in
    /// the apply call; the engine rejects the change if the schema moved since.
    public let currentSchema: Int64
    /// Whether the new (or old) note type is cloze, which disables template
    /// remapping.
    public let isCloze: Bool
    public let oldFieldNames: [String]
    public let newFieldNames: [String]
    public let oldTemplateNames: [String]
    public let newTemplateNames: [String]
    /// Default field mapping: `defaultFieldMap[newIndex]` = old field index, or
    /// `nil`. Length equals `newFieldNames.count`.
    public let defaultFieldMap: [Int?]
    /// Default template mapping (same shape as the field map); empty for cloze.
    public let defaultTemplateMap: [Int?]

    public init(
        oldNotetypeID: Int64, newNotetypeID: Int64, oldNotetypeName: String,
        currentSchema: Int64, isCloze: Bool,
        oldFieldNames: [String], newFieldNames: [String],
        oldTemplateNames: [String], newTemplateNames: [String],
        defaultFieldMap: [Int?], defaultTemplateMap: [Int?]
    ) {
        self.oldNotetypeID = oldNotetypeID
        self.newNotetypeID = newNotetypeID
        self.oldNotetypeName = oldNotetypeName
        self.currentSchema = currentSchema
        self.isCloze = isCloze
        self.oldFieldNames = oldFieldNames
        self.newFieldNames = newFieldNames
        self.oldTemplateNames = oldTemplateNames
        self.newTemplateNames = newTemplateNames
        self.defaultFieldMap = defaultFieldMap
        self.defaultTemplateMap = defaultTemplateMap
    }
}

/// Change-notetype convenience methods. `get_change_notetype_info` is service
/// 23, method 14 and `change_notetype` is service 23, method 15 (confirmed in
/// `_backend_generated.py`); shapes from `proto/anki/notetypes.proto`.
public extension Backend {
    /// NotetypesService.getChangeNotetypeInfo (23, 14).
    ///
    /// Asks the engine to compute a default field/template mapping for moving
    /// notes from `oldNotetypeID` to `newNotetypeID` (it matches fields/templates
    /// by name, then fills gaps with leftovers). Returns it as a `ChangeNotetypeInfo`.
    func changeNotetypeInfo(oldNotetypeID: Int64, newNotetypeID: Int64) throws -> ChangeNotetypeInfo {
        var req = Anki_Notetypes_GetChangeNotetypeInfoRequest()
        req.oldNotetypeID = oldNotetypeID
        req.newNotetypeID = newNotetypeID
        let info = try run(service: 23, method: 14, req, returning: Anki_Notetypes_ChangeNotetypeInfo.self)
        let input = info.input
        return ChangeNotetypeInfo(
            oldNotetypeID: input.oldNotetypeID,
            newNotetypeID: input.newNotetypeID,
            oldNotetypeName: info.oldNotetypeName,
            currentSchema: input.currentSchema,
            isCloze: input.isCloze,
            oldFieldNames: info.oldFieldNames,
            newFieldNames: info.newFieldNames,
            oldTemplateNames: info.oldTemplateNames,
            newTemplateNames: info.newTemplateNames,
            defaultFieldMap: input.newFields.map { $0 == -1 ? nil : Int($0) },
            defaultTemplateMap: input.newTemplates.map { $0 == -1 ? nil : Int($0) }
        )
    }

    /// NotetypesService.changeNotetype (23, 15).
    ///
    /// Applies a note-type change to `noteIDs` using the supplied field/template
    /// maps (each entry is the old index that fills the new slot, or `nil` to
    /// leave it empty). The identity fields (old/new id, schema, cloze flag) come
    /// from the `info` returned by `changeNotetypeInfo`, so the call stays
    /// consistent with what the engine computed. Mirrors AnkiDroid's
    /// `changeNotetype`. Records an undo entry.
    func changeNotetype(
        noteIDs: [Int64], info: ChangeNotetypeInfo,
        fieldMap: [Int?], templateMap: [Int?]
    ) throws {
        var req = Anki_Notetypes_ChangeNotetypeRequest()
        req.noteIds = noteIDs
        req.oldNotetypeID = info.oldNotetypeID
        req.newNotetypeID = info.newNotetypeID
        req.currentSchema = info.currentSchema
        req.oldNotetypeName = info.oldNotetypeName
        req.isCloze = info.isCloze
        // `nil` → -1, matching the engine's nullable-repeated convention.
        req.newFields = fieldMap.map { $0.map(Int32.init) ?? -1 }
        req.newTemplates = templateMap.map { $0.map(Int32.init) ?? -1 }
        _ = try run(service: 23, method: 15, req, returning: Anki_Collection_OpChanges.self)
    }
}
