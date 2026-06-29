import Foundation
import AnkiKit

@MainActor
final class AnkiStore: ObservableObject {
    @Published var buildHash = ""
    @Published var status = "Starting…"
    /// Decks shown on the Home screen, flattened from the backend deck tree
    /// with per-deck new/learning/review counts.
    @Published var decks: [DeckTreeEntry] = []

    @Published var currentQuestion = ""
    @Published var currentAnswer = ""
    /// The current card's notetype CSS, injected into the reviewer WebView.
    @Published var currentCSS = ""
    /// Template ordinal of the current card (drives the `cardN` body class).
    @Published var currentOrdinal = 0
    /// Projected interval labels for the four answer buttons, in order
    /// `[again, hard, good, easy]`. Empty until a card is loaded.
    @Published var currentIntervals: [String] = []
    @Published var showingAnswer = false
    @Published var reviewDone = false

    /// Whether the backend has an action to undo (drives the Undo control).
    @Published var canUndo = false
    /// Localized name of the next undoable action (e.g. "Answer Card").
    @Published var undoName = ""

    private var backend: Backend?
    private var currentCard: Anki_Scheduler_QueuedCards.QueuedCard?
    private var cardShownAt = Date()

    /// Media folder backing `<img src="...">` resolution in the reviewer.
    /// Matches the folder passed to `openCollection` in `boot()`.
    var mediaFolderURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("collection.media")
    }

    func boot() {
        guard backend == nil else { return }
        buildHash = Backend.buildHash()
        do {
            let backend = try Backend()
            self.backend = backend
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let mediaFolder = mediaFolderURL
            try? FileManager.default.createDirectory(at: mediaFolder, withIntermediateDirectories: true)
            try backend.openCollection(
                path: docs.appendingPathComponent("collection.anki2").path,
                mediaFolder: mediaFolder.path,
                mediaDB: docs.appendingPathComponent("collection.media.db2").path
            )
            try seedIfNeeded(backend)
            refreshDecks()
            refreshUndo()
            status = "Engine OK"
        } catch {
            status = "Error: \(error)"
        }
    }

    /// Reload the deck list and its counts (e.g. after returning from review).
    func refreshDecks() {
        guard let backend else { return }
        do {
            decks = try backend.deckTree()
        } catch {
            status = "Deck list error: \(error)"
        }
    }

    /// Select `id` as the current deck (so the scheduler scopes study to it and
    /// its subdecks), reset reviewer state, and load the first queued card.
    func selectDeck(id: Int64) {
        guard let backend else { return }
        do {
            try backend.setCurrentDeck(id: id)
            reviewDone = false
            showingAnswer = false
            currentQuestion = ""
            currentAnswer = ""
            currentCSS = ""
            currentIntervals = []
            currentCard = nil
            loadNext()
        } catch {
            status = "Select error: \(error)"
        }
    }

    private func seedIfNeeded(_ backend: Backend) throws {
        let key = "seeded_v1"
        if UserDefaults.standard.bool(forKey: key) { return }
        guard let basic = try backend.notetypeNames().first(where: { $0.name.hasPrefix("Basic") }) else { return }
        let cards: [(String, String)] = [
            ("What is the powerhouse of the cell?", "The mitochondria"),
            ("Which ion's gradient drives ATP synthase?", "The proton (H⁺) gradient"),
            ("Normal resting membrane potential of a neuron?", "About −70 mV"),
            ("Enzyme that unwinds DNA at the replication fork?", "Helicase"),
            ("Henderson–Hasselbalch: pH = ?", "pKa + log([A⁻]/[HA])"),
        ]
        for (q, a) in cards {
            _ = try backend.addNote(notetypeID: basic.id, fields: [q, a], deckID: 1)
        }
        UserDefaults.standard.set(true, forKey: key)
    }

    func startReview() {
        if currentQuestion.isEmpty && !reviewDone { loadNext() }
    }

    func loadNext() {
        guard let backend else { return }
        showingAnswer = false
        do {
            let q = try backend.queuedCards()
            guard let first = q.cards.first else {
                currentCard = nil
                reviewDone = true
                currentQuestion = ""
                currentAnswer = ""
                currentCSS = ""
                currentIntervals = []
                refreshUndo()
                return
            }
            reviewDone = false
            currentCard = first
            currentOrdinal = Int(first.card.templateIdx)
            let rendered = try backend.renderCard(cardID: first.card.id)
            currentQuestion = rendered.question
            currentAnswer = rendered.answer
            currentCSS = rendered.css
            // One interval label per button: [again, hard, good, easy].
            // Ignore an unexpected shape rather than mislabeling buttons.
            let intervals = (try? backend.describeNextStates(first.states)) ?? []
            currentIntervals = intervals.count == 4 ? intervals : []
            cardShownAt = Date()
            refreshUndo()
        } catch {
            status = "Review error: \(error)"
        }
    }

    func reveal() { showingAnswer = true }

    func rate(_ rating: Anki_Scheduler_CardAnswer.Rating) {
        guard let backend, let card = currentCard else { return }
        let ms = UInt32(min(60_000, Date().timeIntervalSince(cardShownAt) * 1000))
        try? backend.answer(card: card, rating: rating, millisecondsTaken: ms)
        loadNext()
    }

    /// Reverts the last undoable action (e.g. the previous answer) and reloads
    /// the queue so the restored card is shown again.
    func undo() {
        guard let backend, canUndo else { return }
        do {
            _ = try backend.undo()
            loadNext()
        } catch {
            status = "Undo error: \(error)"
        }
    }

    /// Refreshes `canUndo`/`undoName` from the backend's undo status.
    private func refreshUndo() {
        guard let backend else { return }
        if let status = try? backend.undoStatus() {
            undoName = status.undo
            canUndo = !status.undo.isEmpty
        } else {
            undoName = ""
            canUndo = false
        }
    }
}
