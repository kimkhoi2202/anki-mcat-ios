import Foundation
import SwiftProtobuf

/// Reviewer card-action convenience methods — bury, suspend, mark, and delete —
/// cloning AnkiDroid's `ReviewerViewModel` actions (`buryCard`/`buryNote`/
/// `suspendCard`/`suspendNote`/`toggleMark`/`deleteNote`).
///
/// Service/method indices come from the generated `_backend_generated.py`
/// reference; the bury/suspend `mode` values come from `scheduler.proto`
/// (`BuryOrSuspendCardsRequest.Mode`: SUSPEND = 0, BURY_SCHED = 1, BURY_USER = 2)
/// and the card-vs-note shapes mirror pylib `scheduler/base.py`
/// (`bury_cards(manual=True)` → BURY_USER on card ids, `bury_notes` → BURY_USER
/// on note ids, `suspend_cards`/`suspend_notes` → SUSPEND on card/note ids).
public extension Backend {
    /// SchedulerService.buryOrSuspendCards (13, 14), mode BURY_USER on card ids.
    /// Manual bury of the given cards (pylib `sched.bury_cards(ids, manual=True)`).
    /// Returns the number of cards affected.
    @discardableResult
    func buryCards(cardIDs: [Int64]) throws -> Int {
        var req = Anki_Scheduler_BuryOrSuspendCardsRequest()
        req.cardIds = cardIDs
        req.mode = .buryUser
        let resp = try run(service: 13, method: 14, req, returning: Anki_Collection_OpChangesWithCount.self)
        return Int(resp.count)
    }

    /// SchedulerService.buryOrSuspendCards (13, 14), mode BURY_USER on note ids.
    /// Buries every card of the given notes (pylib `sched.bury_notes(note_ids)`).
    @discardableResult
    func buryNotes(noteIDs: [Int64]) throws -> Int {
        var req = Anki_Scheduler_BuryOrSuspendCardsRequest()
        req.noteIds = noteIDs
        req.mode = .buryUser
        let resp = try run(service: 13, method: 14, req, returning: Anki_Collection_OpChangesWithCount.self)
        return Int(resp.count)
    }

    /// SchedulerService.buryOrSuspendCards (13, 14), mode SUSPEND on note ids.
    /// Suspends every card of the given notes (pylib `sched.suspend_notes(ids)`).
    /// (The card-level variant lives in `BackendBrowser.suspendCards`.)
    @discardableResult
    func suspendNotes(noteIDs: [Int64]) throws -> Int {
        var req = Anki_Scheduler_BuryOrSuspendCardsRequest()
        req.noteIds = noteIDs
        req.mode = .suspend
        let resp = try run(service: 13, method: 14, req, returning: Anki_Collection_OpChangesWithCount.self)
        return Int(resp.count)
    }

    /// NotesService.removeNotes (25, 7) by note ids. Deletes the given notes (and
    /// all of their cards). Mirrors AnkiDroid's reviewer Delete, which removes the
    /// current card's note. Returns the number of notes removed.
    @discardableResult
    func removeNotes(noteIDs: [Int64]) throws -> Int {
        var req = Anki_Notes_RemoveNotesRequest()
        req.noteIds = noteIDs
        let resp = try run(service: 25, method: 7, req, returning: Anki_Collection_OpChangesWithCount.self)
        return Int(resp.count)
    }

    /// TagsService.addNoteTags (45, 7). Adds the given space-separated tag(s) to
    /// the notes. Returns the number of notes changed.
    @discardableResult
    func addNoteTags(noteIDs: [Int64], tags: String) throws -> Int {
        var req = Anki_Tags_NoteIdsAndTagsRequest()
        req.noteIds = noteIDs
        req.tags = tags
        let resp = try run(service: 45, method: 7, req, returning: Anki_Collection_OpChangesWithCount.self)
        return Int(resp.count)
    }

    /// TagsService.removeNoteTags (45, 8). Removes the given space-separated
    /// tag(s) from the notes. Returns the number of notes changed.
    @discardableResult
    func removeNoteTags(noteIDs: [Int64], tags: String) throws -> Int {
        var req = Anki_Tags_NoteIdsAndTagsRequest()
        req.noteIds = noteIDs
        req.tags = tags
        let resp = try run(service: 45, method: 8, req, returning: Anki_Collection_OpChangesWithCount.self)
        return Int(resp.count)
    }

    /// Anki's "marked" convention: a note is marked iff it carries the `marked`
    /// tag (AnkiDroid `NoteService.isMarked`/`MARKED_TAG`). Tag matching is
    /// case-insensitive, matching the engine's `has_tag`.
    static var markedTag: String { "marked" }

    /// Whether the note is marked (carries the `marked` tag).
    func isNoteMarked(noteID: Int64) throws -> Bool {
        let note = try getNote(noteID: noteID)
        return note.tags.contains { $0.caseInsensitiveCompare(Backend.markedTag) == .orderedSame }
    }

    /// Toggles the note's `marked` tag (adds it if absent, removes it if present)
    /// and returns the resulting marked state. Clone of AnkiDroid's
    /// `NoteService.toggleMark`, which flips the tag and saves the note; the
    /// add/remove tag RPCs are themselves undoable.
    @discardableResult
    func toggleMark(noteID: Int64) throws -> Bool {
        if try isNoteMarked(noteID: noteID) {
            _ = try removeNoteTags(noteIDs: [noteID], tags: Backend.markedTag)
            return false
        }
        _ = try addNoteTags(noteIDs: [noteID], tags: Backend.markedTag)
        return true
    }
}
