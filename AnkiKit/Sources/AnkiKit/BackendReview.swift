import Foundation
import SwiftProtobuf

/// Review-loop convenience methods. Service/method indices come from the
/// generated `_backend_generated.py` reference.
public extension Backend {
    /// NotetypesService.getNotetypeNames (23, 8).
    func notetypeNames() throws -> [(id: Int64, name: String)] {
        let resp = try run(service: 23, method: 8, Anki_Generic_Empty(), returning: Anki_Notetypes_NotetypeNames.self)
        return resp.entries.map { (id: $0.id, name: $0.name) }
    }

    /// NotesService.addNote (25, 1). Returns the new note id.
    @discardableResult
    func addNote(notetypeID: Int64, fields: [String], deckID: Int64, tags: [String] = []) throws -> Int64 {
        var note = Anki_Notes_Note()
        note.notetypeID = notetypeID
        note.fields = fields
        note.tags = tags
        var req = Anki_Notes_AddNoteRequest()
        req.note = note
        req.deckID = deckID
        return try run(service: 25, method: 1, req, returning: Anki_Notes_AddNoteResponse.self).noteID
    }

    /// SchedulerService.getQueuedCards (13, 3).
    func queuedCards() throws -> Anki_Scheduler_QueuedCards {
        var req = Anki_Scheduler_GetQueuedCardsRequest()
        req.fetchLimit = 50
        req.intradayLearningOnly = false
        return try run(service: 13, method: 3, req, returning: Anki_Scheduler_QueuedCards.self)
    }

    /// CardRenderingService.renderExistingCard (27, 6). Returns the final
    /// question/answer HTML plus the card's CSS.
    ///
    /// `css` is the notetype's styling: the core sets it to
    /// `notetype.config.css` (see rslib `notetype/render.rs`), so it is
    /// identical to `notetypeCSS(notetypeID:)` but comes back for free with the
    /// render, avoiding an extra round-trip per card.
    func renderCard(cardID: Int64) throws -> (question: String, answer: String, css: String) {
        var req = Anki_CardRendering_RenderExistingCardRequest()
        req.cardID = cardID
        req.browser = false
        req.partialRender = false
        let resp = try run(service: 27, method: 6, req, returning: Anki_CardRendering_RenderCardResponse.self)
        return (Backend.joinNodes(resp.questionNodes), Backend.joinNodes(resp.answerNodes), resp.css)
    }

    /// SchedulerService.describeNextStates (13, 24).
    ///
    /// Given a queued card's precomputed `states`, returns one human-readable
    /// interval label per answer button, in order `[again, hard, good, easy]`
    /// (e.g. `["<1m", "<10m", "1d", "4d"]`). Mirrors AnkiDroid's
    /// `AnswerButtonsNextTime.from`, which destructures the same four strings.
    func describeNextStates(_ states: Anki_Scheduler_SchedulingStates) throws -> [String] {
        let resp = try run(service: 13, method: 24, states, returning: Anki_Generic_StringList.self)
        return resp.vals
    }

    /// SchedulerService.answerCard (13, 4), using a queued card's precomputed states.
    func answer(card: Anki_Scheduler_QueuedCards.QueuedCard,
                rating: Anki_Scheduler_CardAnswer.Rating,
                millisecondsTaken: UInt32) throws {
        var ans = Anki_Scheduler_CardAnswer()
        ans.cardID = card.card.id
        ans.currentState = card.states.current
        switch rating {
        case .again: ans.newState = card.states.again
        case .hard: ans.newState = card.states.hard
        case .good: ans.newState = card.states.good
        case .easy: ans.newState = card.states.easy
        default: ans.newState = card.states.good
        }
        ans.rating = rating
        ans.answeredAtMillis = Int64(Date().timeIntervalSince1970 * 1000)
        ans.millisecondsTaken = millisecondsTaken
        _ = try run(service: 13, method: 4, input: try ans.serializedData())
    }

    private static func joinNodes(_ nodes: [Anki_CardRendering_RenderedTemplateNode]) -> String {
        nodes.map { node -> String in
            if case .text(let s)? = node.value { return s }
            if case .replacement(let r)? = node.value { return r.currentText }
            return ""
        }.joined()
    }
}
