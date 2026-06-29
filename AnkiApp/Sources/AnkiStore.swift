import Foundation
import AnkiKit

@MainActor
final class AnkiStore: ObservableObject {
    @Published var buildHash = ""
    @Published var status = "Starting…"
    @Published var deckNames: [String] = []
    @Published var newCount = 0
    @Published var learningCount = 0
    @Published var reviewCount = 0

    @Published var currentQuestion = ""
    @Published var currentAnswer = ""
    @Published var showingAnswer = false
    @Published var reviewDone = false

    private var backend: Backend?
    private var currentCard: Anki_Scheduler_QueuedCards.QueuedCard?
    private var cardShownAt = Date()

    func boot() {
        guard backend == nil else { return }
        buildHash = Backend.buildHash()
        do {
            let backend = try Backend()
            self.backend = backend
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let mediaFolder = docs.appendingPathComponent("collection.media")
            try? FileManager.default.createDirectory(at: mediaFolder, withIntermediateDirectories: true)
            try backend.openCollection(
                path: docs.appendingPathComponent("collection.anki2").path,
                mediaFolder: mediaFolder.path,
                mediaDB: docs.appendingPathComponent("collection.media.db2").path
            )
            deckNames = try backend.deckNames().map(\.name)
            try seedIfNeeded(backend)
            refreshCounts()
            status = "Engine OK"
        } catch {
            status = "Error: \(error)"
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

    private func refreshCounts() {
        guard let backend, let q = try? backend.queuedCards() else { return }
        newCount = Int(q.newCount)
        learningCount = Int(q.learningCount)
        reviewCount = Int(q.reviewCount)
    }

    func startReview() {
        if currentQuestion.isEmpty && !reviewDone { loadNext() }
    }

    func loadNext() {
        guard let backend else { return }
        showingAnswer = false
        do {
            let q = try backend.queuedCards()
            newCount = Int(q.newCount)
            learningCount = Int(q.learningCount)
            reviewCount = Int(q.reviewCount)
            guard let first = q.cards.first else {
                currentCard = nil
                reviewDone = true
                currentQuestion = ""
                currentAnswer = ""
                return
            }
            reviewDone = false
            currentCard = first
            let rendered = try backend.renderCard(cardID: first.card.id)
            currentQuestion = rendered.question
            currentAnswer = rendered.answer
            cardShownAt = Date()
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
}
