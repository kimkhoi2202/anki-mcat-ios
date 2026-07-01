import Foundation
import SwiftProtobuf

/// A note loaded for editing: its identity and notetype plus the current field
/// values and tags. Decouples the SwiftUI layer from the generated `Note`
/// protobuf (the same way `ReviewingPrefs` shields it from `Preferences`).
public struct NoteForEditing: Sendable {
    public let id: Int64
    public let notetypeID: Int64
    /// Field values in field-ordinal order, aligning index-for-index with
    /// `notetypeFields(notetypeID:)`.
    public let fields: [String]
    public let tags: [String]
}

/// Note add/edit convenience methods. Service/method indices come from the
/// generated `_backend_generated.py` reference.
public extension Backend {
    /// NotesService.getNote (25, 6).
    ///
    /// Loads an existing note's notetype, field values, and tags so the editor
    /// can populate its inputs — mirrors AnkiDroid's NoteEditor reading
    /// `currentEditedCard.note(col)` when opening a note for editing.
    func getNote(noteID: Int64) throws -> NoteForEditing {
        var req = Anki_Notes_NoteId()
        req.nid = noteID
        let note = try run(service: 25, method: 6, req, returning: Anki_Notes_Note.self)
        return NoteForEditing(
            id: note.id,
            notetypeID: note.notetypeID,
            fields: note.fields,
            tags: note.tags
        )
    }

    /// NotesService.updateNotes (25, 5). There is no singular `update_note` RPC;
    /// the backend takes a batch, so a single edited note is wrapped in a
    /// one-element list.
    ///
    /// Read-modify-write: the note is re-fetched (25, 6) and only its `fields`
    /// and `tags` are replaced, so its guid / mtime / usn / notetype are
    /// preserved — matching `updateNote(note)` in AnkiDroid's `saveNote()`.
    /// `skipUndoEntry` is false so the edit is undoable, as in AnkiDroid.
    func updateNote(noteID: Int64, fields: [String], tags: [String]) throws {
        var idReq = Anki_Notes_NoteId()
        idReq.nid = noteID
        var note = try run(service: 25, method: 6, idReq, returning: Anki_Notes_Note.self)
        note.fields = fields
        note.tags = tags
        var req = Anki_Notes_UpdateNotesRequest()
        req.notes = [note]
        req.skipUndoEntry = false
        _ = try run(service: 25, method: 5, input: try req.serializedData())
    }

    /// NotetypesService.getFieldNames (23, 16).
    ///
    /// Returns the notetype's field names in field-ordinal order — the core runs
    /// `SELECT name FROM fields WHERE ntid = ? ORDER BY ord` — so the result
    /// aligns index-for-index with a note's `fields` (also ord-ordered). Used to
    /// label the editor's per-field inputs, as AnkiDroid builds its field rows
    /// from the notetype's fields.
    func notetypeFields(notetypeID: Int64) throws -> [String] {
        var req = Anki_Notetypes_NotetypeId()
        req.ntid = notetypeID
        return try run(service: 23, method: 16, req, returning: Anki_Generic_StringList.self).vals
    }

    /// NotesService.noteFieldsCheck (25, 11).
    ///
    /// Validates an *uncommitted* note's fields against the collection and returns
    /// the engine's state:
    /// - `NORMAL` — nothing wrong.
    /// - `EMPTY` — the first field is empty.
    /// - `DUPLICATE` — the first field matches an existing note of the same type.
    /// - `MISSING_CLOZE` / `NOTETYPE_NOT_CLOZE` / `FIELD_NOT_CLOZE` — cloze issues.
    ///
    /// The note carries the notetype id + field values, plus (in EDIT mode) the
    /// note's own id so the engine's duplicate check excludes the note being
    /// edited (`is_duplicate` skips `nid == note.id`). Pass `noteID: 0` for a new
    /// (unsaved) note. Drives the editor's live duplicate / empty / cloze
    /// warnings, mirroring AnkiDroid's `note.fieldsCheck(col)` in
    /// `setDuplicateFieldStyles`.
    func noteFieldsCheck(
        notetypeID: Int64, fields: [String], noteID: Int64 = 0
    ) throws -> Anki_Notes_NoteFieldsCheckResponse.State {
        var note = Anki_Notes_Note()
        note.id = noteID
        note.notetypeID = notetypeID
        note.fields = fields
        return try run(service: 25, method: 11, note,
                       returning: Anki_Notes_NoteFieldsCheckResponse.self).state
    }

    /// NotesService.clozeNumbersInNote (25, 8).
    ///
    /// The distinct cloze numbers (`{{cN::…}}`) used across an uncommitted note's
    /// fields, in ascending order. A cloze note generates one card per number, so
    /// the editor's preview uses these to enumerate the cards to render (each card
    /// ord = number − 1). Empty for a note with no cloze deletions. The engine
    /// returns them as an unordered set, so they're sorted here for a deterministic
    /// Cloze 1, 2, … ordering.
    func clozeNumbersInNote(notetypeID: Int64, fields: [String]) throws -> [Int] {
        var note = Anki_Notes_Note()
        note.notetypeID = notetypeID
        note.fields = fields
        let resp = try run(service: 25, method: 8, note,
                           returning: Anki_Notes_ClozeNumbersInNoteResponse.self)
        return resp.numbers.map(Int.init).sorted()
    }
}
