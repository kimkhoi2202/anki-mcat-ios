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

/// A note type for the "Manage note types" list: its id, name, and how many
/// notes use it. Decoupled from the generated `NotetypeNameIdUseCount` protobuf,
/// mirroring AnkiDroid's `NoteTypeItemState`.
public struct NotetypeUseCount: Sendable, Identifiable, Equatable {
    public let id: Int64
    public let name: String
    /// Number of notes using this note type (from `get_notetype_names_and_counts`).
    public let useCount: Int

    public init(id: Int64, name: String, useCount: Int) {
        self.id = id
        self.name = name
        self.useCount = useCount
    }
}

/// Note-type management RPCs — the engine indices behind AnkiDroid's "Manage note
/// types", Fields editor, and Card Template editor. All `(service, method)`
/// indices are NotetypesService entries confirmed in `AnkiWebMethods` /
/// `_backend_generated.py`; request/response shapes from `proto/anki/notetypes.proto`.
public extension Backend {
    /// NotetypesService.getNotetype (23, 6).
    ///
    /// The full note type — fields, templates, styling CSS, and config — used as
    /// the editable model for the Fields / Card Template editors (mirrors
    /// AnkiDroid's `Collection.getNotetype`).
    func notetype(id: Int64) throws -> Anki_Notetypes_Notetype {
        var req = Anki_Notetypes_NotetypeId()
        req.ntid = id
        return try run(service: 23, method: 6, req, returning: Anki_Notetypes_Notetype.self)
    }

    /// NotetypesService.getNotetypeNamesAndCounts (23, 9).
    ///
    /// Every note type with its note count — the "Manage note types" list
    /// (AnkiDroid's `getNotetypeNameIdUseCount`).
    func notetypeNamesAndCounts() throws -> [NotetypeUseCount] {
        let resp = try run(service: 23, method: 9, Anki_Generic_Empty(),
                           returning: Anki_Notetypes_NotetypeUseCounts.self)
        return resp.entries.map { NotetypeUseCount(id: $0.id, name: $0.name, useCount: Int($0.useCount)) }
    }

    /// NotetypesService.addNotetype (23, 0). Returns the new note type's id.
    ///
    /// Takes a full `Notetype` proto (id 0 for a new one). Used to clone an
    /// existing note type (AnkiDroid's `addNotetype`).
    @discardableResult
    func addNotetype(_ notetype: Anki_Notetypes_Notetype) throws -> Int64 {
        try run(service: 23, method: 0, notetype, returning: Anki_Collection_OpChangesWithId.self).id
    }

    /// NotetypesService.updateNotetype (23, 1).
    ///
    /// Persists edits to an existing note type (fields, templates, CSS). The
    /// engine validates the templates and field set and throws on problems (e.g.
    /// a template with no field replacement), which the UI surfaces. Records an
    /// undo entry. Mirrors AnkiDroid's `Collection.updateNotetype`.
    func updateNotetype(_ notetype: Anki_Notetypes_Notetype) throws {
        _ = try run(service: 23, method: 1, notetype, returning: Anki_Collection_OpChanges.self)
    }

    /// NotetypesService.addNotetypeLegacy (23, 2). Returns the new note type's id.
    ///
    /// Adds a note type from its legacy JSON dict (the form
    /// `get_stock_notetype_legacy` returns). Used to add a fresh note type from a
    /// stock kind (AnkiDroid's `addNotetypeLegacy`).
    @discardableResult
    func addNotetypeLegacy(json: Data) throws -> Int64 {
        var req = Anki_Generic_Json()
        req.json = json
        return try run(service: 23, method: 2, req, returning: Anki_Collection_OpChangesWithId.self).id
    }

    /// NotetypesService.getStockNotetypeLegacy (23, 5).
    ///
    /// The legacy JSON for one of Anki's built-in note types (Basic, Cloze, …),
    /// the template AnkiDroid clones when adding a standard note type.
    func stockNotetypeJSON(kind: Anki_Notetypes_StockNotetype.Kind) throws -> Data {
        var req = Anki_Notetypes_StockNotetype()
        req.kind = kind
        return try run(service: 23, method: 5, req, returning: Anki_Generic_Json.self).json
    }

    /// The display name of a stock note type (e.g. "Basic", "Cloze"), read from
    /// its legacy JSON — the labels for the "Add note type" base picker.
    func stockNotetypeName(kind: Anki_Notetypes_StockNotetype.Kind) throws -> String {
        let data = try stockNotetypeJSON(kind: kind)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return (object?["name"] as? String) ?? ""
    }

    /// NotetypesService.removeNotetype (23, 11).
    ///
    /// Deletes a note type and every note/card that uses it (undoable). The
    /// "can't delete the last note type" guard lives in the UI, matching
    /// AnkiDroid's `ManageNoteTypesViewModel.delete`.
    func removeNotetype(id: Int64) throws {
        var req = Anki_Notetypes_NotetypeId()
        req.ntid = id
        _ = try run(service: 23, method: 11, req, returning: Anki_Collection_OpChanges.self)
    }

    // MARK: - Semantic helpers (load-mutate-save, clones of libanki)

    /// Adds a new note type from a stock kind under `name` — clone of AnkiDroid's
    /// `addStandardNotetype`: fetch the stock JSON, set its name, add it.
    @discardableResult
    func addStockNotetype(kind: Anki_Notetypes_StockNotetype.Kind, name: String) throws -> Int64 {
        let data = try stockNotetypeJSON(kind: kind)
        var object = (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        object["name"] = name
        let updated = try JSONSerialization.data(withJSONObject: object)
        return try addNotetypeLegacy(json: updated)
    }

    /// Clones an existing note type under a new name — clone of AnkiDroid's
    /// `cloneStandardNotetype` (`getNotetype` → id 0 + new name → `addNotetype`).
    @discardableResult
    func cloneNotetype(id: Int64, name: String) throws -> Int64 {
        var clone = try notetype(id: id)
        clone.id = 0
        clone.name = name
        return try addNotetype(clone)
    }

    /// Renames a note type in place — clone of AnkiDroid's `safeRenameNoteType`
    /// (`getNotetype` → set name → `updateNotetype`).
    func renameNotetype(id: Int64, name: String) throws {
        var renamed = try notetype(id: id)
        renamed.name = name
        try updateNotetype(renamed)
    }

    // MARK: - Field operations (atomic load-mutate-save)
    //
    // Each mirrors AnkiDroid's `ModelFieldEditor`: load the note type, apply one
    // field change (which keeps every field's `ord` so the engine remaps notes),
    // then save via `updateNotetype`. Reposition/remove keep the sort field valid.

    /// Appends a new field named `name` (added to every note of the type on save).
    func addNotetypeField(notetypeID: Int64, name: String) throws {
        var nt = try notetype(id: notetypeID)
        nt.addField(named: name)
        try updateNotetype(nt)
    }

    /// Renames the field at `index`.
    func renameNotetypeField(notetypeID: Int64, at index: Int, to name: String) throws {
        var nt = try notetype(id: notetypeID)
        nt.renameField(at: index, to: name)
        try updateNotetype(nt)
    }

    /// Moves the field at `from` to position `to` (the engine keeps note contents
    /// aligned by `ord`).
    func moveNotetypeField(notetypeID: Int64, from: Int, to: Int) throws {
        var nt = try notetype(id: notetypeID)
        nt.moveField(from: from, to: to)
        try updateNotetype(nt)
    }

    /// Removes the field at `index` (refused when only one field remains).
    func removeNotetypeField(notetypeID: Int64, at index: Int) throws {
        var nt = try notetype(id: notetypeID)
        nt.removeField(at: index)
        try updateNotetype(nt)
    }

    /// Sets the sort field (the field shown in the browser's Sort Field column).
    func setNotetypeSortField(notetypeID: Int64, at index: Int) throws {
        var nt = try notetype(id: notetypeID)
        nt.setSortField(at: index)
        try updateNotetype(nt)
    }

    // MARK: - Card-template preview

    /// CardRenderingService.renderUncommittedCard (27, 7).
    ///
    /// Renders an *uncommitted* note against a (possibly unsaved) template,
    /// returning the question/answer HTML — the live preview behind the Card
    /// Template editor (the backend equivalent of desktop's
    /// `note.ephemeral_card`). `fillEmpty` shows empty fields as their name so a
    /// blank sample still previews. The CSS is taken from the edited note type in
    /// the UI (so styling edits show without saving), not from the response.
    func renderUncommittedCard(
        note: Anki_Notes_Note, cardOrd: Int,
        template: Anki_Notetypes_Notetype.Template, fillEmpty: Bool = true
    ) throws -> (question: String, answer: String) {
        var req = Anki_CardRendering_RenderUncommittedCardRequest()
        req.note = note
        req.cardOrd = UInt32(max(0, cardOrd))
        req.template = template
        req.fillEmpty = fillEmpty
        let resp = try run(service: 27, method: 7, req, returning: Anki_CardRendering_RenderCardResponse.self)
        return (Backend.joinNodes(resp.questionNodes), Backend.joinNodes(resp.answerNodes))
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
