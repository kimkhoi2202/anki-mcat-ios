import Foundation
import SwiftProtobuf

/// A unit of card audio to play in order: a recorded media file (`[sound:…]`)
/// or text to synthesize via TTS (`{{tts}}`).
public enum CardAudio: Sendable, Equatable {
    case sound(String)
    case tts(text: String, lang: String)
}

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

    /// CardRenderingService.extractAvTags (27, 3). Splits a rendered card side
    /// into (display text, audio filenames): Anki renders the card, then extracts
    /// its `[sound:…]` / AV tags for playback, leaving `[anki:play:…]` markers in
    /// the text where they were. We strip those markers for native display and
    /// return the audio/video filenames (relative to the media folder) to play.
    /// TTS tags are skipped for now.
    func extractAudio(text: String, questionSide: Bool) throws -> (text: String, audio: [CardAudio]) {
        var req = Anki_CardRendering_ExtractAvTagsRequest()
        req.text = text
        req.questionSide = questionSide
        let resp = try run(service: 27, method: 3, req, returning: Anki_CardRendering_ExtractAvTagsResponse.self)
        let audio: [CardAudio] = resp.avTags.compactMap { tag in
            switch tag.value {
            case .soundOrVideo(let filename): return .sound(filename)
            case .tts(let tts): return tts.fieldText.isEmpty ? nil : .tts(text: tts.fieldText, lang: tts.lang)
            case .none: return nil
            }
        }
        let cleaned = resp.text.replacingOccurrences(
            of: "\\[anki:play:[^\\]]*\\]", with: "", options: .regularExpression
        )
        return (cleaned, audio)
    }

    /// CardRenderingService.compareAnswer (27, 15). Returns the type-in-the-answer
    /// diff HTML comparing the user's `typed` answer to the `expected` field value
    /// (Anki's `<code id=typeans>` with typeGood/typeBad/typeMissed spans).
    func compareAnswer(expected: String, typed: String, combining: Bool) throws -> String {
        var req = Anki_CardRendering_CompareAnswerRequest()
        req.expected = expected
        req.provided = typed
        req.combining = combining
        return try run(service: 27, method: 15, req, returning: Anki_Generic_String.self).val
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
