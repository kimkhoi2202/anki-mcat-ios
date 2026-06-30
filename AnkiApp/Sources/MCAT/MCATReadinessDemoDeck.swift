import Foundation

/// A **clearly-marked demo deck** that crosses the give-up thresholds so the
/// Readiness dashboard can show its *scored* state (PRD: "also provide a
/// clearly-marked demo path that crosses the thresholds … to show the scored
/// state with ranges").
///
/// HONESTY NOTE. This deck does NOT fabricate any score. It seeds real MCAT
/// facts and then applies a **simulated study history** — a stored FSRS memory
/// state (stability + difficulty + a last-review date in the past) and a review
/// count — to each card. Every score the dashboard shows is then computed by the
/// engine from that real stored state:
///   • Memory ← the engine's own FSRS retrievability (`card_stats`).
///   • the graded-review count ← each card's `reps`.
/// Seeding memory state is exactly how the points-at-stake tests and the
/// `MCAT` weak-topics demo deck create realistic FSRS state; the retrievability
/// the engine returns is genuine, not a hand-written number. The deck is named,
/// banner-labelled, and seeded only on demand, so it can never be mistaken for
/// the real "MCAT Content" deck — which correctly abstains at ~48% coverage.
///
/// It covers 30 of the 50 `MCATOutline` topics (60%, clearing the ≥50% line) by
/// reusing the real `MCATSeedDeck` content (24 topics) plus a few extra-topic
/// cards, and seeds enough reviews to clear the ≥200-graded-review line.
enum MCATReadinessDemoDeck {
    /// The deck these cards are seeded into. Distinct from the real "MCAT
    /// Content" deck and the points-at-stake "MCAT" deck.
    static let deckName = "MCAT Readiness Demo"

    /// Extra cards for six topics not in `MCATSeedDeck`, lifting demo coverage
    /// from 24/50 (48%) to 30/50 (60%) — comfortably over the give-up line.
    static let extraCards: [MCATSeedDeck.SeedCard] = [
        MCATSeedDeck.SeedCard(topicID: "ChemPhys.Optics",
                              front: "Is the focal length of a converging (convex) lens positive or negative?",
                              back: "Positive (it forms a real focal point)."),
        MCATSeedDeck.SeedCard(topicID: "ChemPhys.ElectrostaticsAndCircuits",
                              front: "State Ohm's law.",
                              back: "V = IR — voltage equals current times resistance."),
        MCATSeedDeck.SeedCard(topicID: "BioBiochem.LipidsAndMembranes",
                              front: "What drives formation of a lipid bilayer in water?",
                              back: "The hydrophobic effect — nonpolar tails turn inward, polar heads face the water."),
        MCATSeedDeck.SeedCard(topicID: "BioBiochem.OrganSystems",
                              front: "Where does gas exchange occur in the lungs?",
                              back: "In the alveoli."),
        MCATSeedDeck.SeedCard(topicID: "PsychSoc.PsychologicalDisorders",
                              front: "What distinguishes bipolar I disorder from major depressive disorder?",
                              back: "Bipolar I requires at least one manic episode."),
        MCATSeedDeck.SeedCard(topicID: "CARS.ReasoningWithinText",
                              front: "In CARS, what is an inference?",
                              back: "A conclusion the passage supports but does not state outright."),
    ]

    /// All demo cards: the real seed content plus the extra-topic cards.
    static var cards: [MCATSeedDeck.SeedCard] { MCATSeedDeck.cards + extraCards }

    /// The simulated FSRS history applied to one demo card.
    struct SeededState {
        /// FSRS stability, in days (how durable the memory is).
        let stability: Float
        /// Days since the (simulated) last review — drives how much recall has
        /// decayed: more elapsed and/or lower stability → lower retrievability.
        let elapsedDays: Int
        /// Graded reviews recorded on the card (its `reps`).
        let reps: UInt32
    }

    /// A deterministic, varied simulated history per card index. Stability and
    /// elapsed days are paired so the ratio elapsed/stability ranges from well
    /// under 1 (recently reviewed, still strong) to several times 1 (overdue,
    /// decayed). That makes the engine's real FSRS retrievability span a wide,
    /// realistic range (roughly 0.5–0.97) so Memory shows a meaningful spread
    /// rather than a near-flat ~95%, while the reps sum to well over 200 graded
    /// reviews across the deck.
    static func seededState(forIndex i: Int) -> SeededState {
        SeededState(
            stability: Float(7 + (i * 23) % 60),      // 7…66 days
            elapsedDays: 4 + (i * 13) % 48,           // 4…51 days
            reps: UInt32(4 + (i * 3) % 7)             // 4…10 reviews/card
        )
    }
}
