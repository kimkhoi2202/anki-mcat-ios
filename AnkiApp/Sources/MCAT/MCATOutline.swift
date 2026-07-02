import Foundation
import AnkiKit

/// The MCAT content-outline taxonomy (PRD 7c "Coverage map").
///
/// Source: a **representative subset** of the AAMC MCAT content outline
/// ("What's on the MCAT Exam?", students-residents.aamc.org/whats-mcat-exam),
/// which organizes the exam into four sections and, beneath each, foundational
/// concepts and content categories. This file does NOT reproduce the AAMC's full
/// list (their detailed outline runs to hundreds of sub-items); it encodes the
/// four sections and a curated ~11-14 major foundational-concept topics per
/// section — enough granularity to make a coverage map meaningful without
/// claiming to be exhaustive.
///
/// Each topic carries a **stable id** (`<sectionToken>.<topicToken>`) and a
/// hierarchical Anki **tag** `MCAT::<SectionToken>::<TopicToken>`, the convention
/// the points-at-stake work established (`MCAT::<Section>::<Topic>`). Tag tokens
/// are space- and slash-free (Anki tags are whitespace-delimited); display names
/// carry the readable form.
///
/// CARS is intentionally included even though it "bans outside facts" and so is
/// structurally unservable by flashcards (AAMC CARS overview; brainlift POV 2).
/// Encoding its skills/passage-disciplines as topics lets the coverage map tell
/// that honest story: CARS will read as the least-covered section by design.
enum MCATOutline {
    /// Root tag namespace shared with the points-at-stake topic tags.
    static let tagRoot = "MCAT"

    /// One MCAT section (e.g. Chem/Phys) and its curated topics.
    struct Section: Identifiable {
        /// Tag-safe identifier and identity, e.g. `ChemPhys`.
        let id: String
        /// Short display label used as the coverage section key, e.g. `Chem/Phys`.
        let name: String
        /// Full AAMC section title.
        let fullName: String
        let topics: [Topic]
    }

    /// One curated outline topic under a section.
    struct Topic: Identifiable {
        /// Stable id `<sectionToken>.<topicToken>` (survives display-name edits).
        let id: String
        /// Tag-safe token, e.g. `Kinematics`.
        let token: String
        /// Human-readable name shown in the UI.
        let name: String
        /// The full hierarchical tag, e.g. `MCAT::ChemPhys::Kinematics`.
        let tag: String
    }

    /// The four sections in exam order, each with its curated topics.
    static let sections: [Section] = [
        section(
            id: "ChemPhys", name: "Chem/Phys",
            fullName: "Chemical & Physical Foundations of Biological Systems",
            topics: [
                ("Kinematics", "Kinematics & translational motion"),
                ("ForceAndEnergy", "Force, work & energy"),
                ("Fluids", "Fluids & hydrostatics"),
                ("Thermodynamics", "Thermodynamics"),
                ("ElectrostaticsAndCircuits", "Electrostatics & circuits"),
                ("Optics", "Light & optics"),
                ("SoundAndWaves", "Sound & waves"),
                ("AtomicAndNuclear", "Atomic & nuclear phenomena"),
                ("AcidsAndBases", "Acids & bases"),
                ("Solutions", "Solutions & solubility"),
                ("ReactionKinetics", "Reaction kinetics"),
                ("Electrochemistry", "Electrochemistry"),
            ]
        ),
        section(
            id: "CARS", name: "CARS",
            fullName: "Critical Analysis & Reasoning Skills",
            topics: [
                ("FoundationsOfComprehension", "Foundations of comprehension"),
                ("ReasoningWithinText", "Reasoning within the text"),
                ("ReasoningBeyondText", "Reasoning beyond the text"),
                ("Philosophy", "Humanities: philosophy"),
                ("Ethics", "Humanities: ethics"),
                ("Literature", "Humanities: literature"),
                ("ArtsAndCulture", "Humanities: arts & culture"),
                ("History", "Humanities: history"),
                ("Anthropology", "Social sciences: anthropology"),
                ("Economics", "Social sciences: economics"),
                ("PoliticalScience", "Social sciences: political science"),
            ]
        ),
        section(
            id: "BioBiochem", name: "Bio/Biochem",
            fullName: "Biological & Biochemical Foundations of Living Systems",
            topics: [
                ("AminoAcidsAndProteins", "Amino acids & proteins"),
                ("Enzymes", "Enzyme structure & kinetics"),
                ("Carbohydrates", "Carbohydrates"),
                ("LipidsAndMembranes", "Lipids & membranes"),
                ("NucleicAcids", "Nucleic acids"),
                ("DNAReplication", "DNA replication & repair"),
                ("GeneExpression", "Transcription & translation"),
                ("Genetics", "Genetics & inheritance"),
                ("Bioenergetics", "Bioenergetics"),
                ("CarbohydrateMetabolism", "Carbohydrate metabolism"),
                ("CellBiology", "Cell biology & organelles"),
                ("Microbiology", "Microbiology: prokaryotes & viruses"),
                ("NervousAndEndocrine", "Nervous & endocrine systems"),
                ("OrganSystems", "Organ systems physiology"),
            ]
        ),
        section(
            id: "PsychSoc", name: "Psych/Soc",
            fullName: "Psychological, Social & Biological Foundations of Behavior",
            topics: [
                ("SensationAndPerception", "Sensation & perception"),
                ("LearningAndConditioning", "Learning & conditioning"),
                ("MemoryAndCognition", "Memory & cognition"),
                ("Consciousness", "Consciousness & states"),
                ("MotivationAndEmotion", "Motivation & emotion"),
                ("Personality", "Personality"),
                ("PsychologicalDisorders", "Psychological disorders"),
                ("AttitudesAndBehaviorChange", "Attitudes & behavior change"),
                ("SocialInfluence", "Social influence & behavior"),
                ("SelfIdentity", "Self-identity"),
                ("SocialCognition", "Social cognition & attribution"),
                ("SocialStructure", "Social structure & institutions"),
                ("SocialStratification", "Social stratification & inequality"),
            ]
        ),
    ]

    /// Every topic flattened in outline order.
    static let allTopics: [Topic] = sections.flatMap(\.topics)

    /// Topic lookup by stable id (used by the seed deck to resolve a card's tag).
    static let topicsByID: [String: Topic] = Dictionary(
        uniqueKeysWithValues: allTopics.map { ($0.id, $0) }
    )

    static func topic(byID id: String) -> Topic? { topicsByID[id] }

    /// Section display name keyed by its tag token (e.g. `ChemPhys` → `Chem/Phys`).
    /// The points-at-stake queue reports a card's topic as the component below the
    /// `MCAT::` prefix — the section token — so this maps that back to a readable
    /// label for the Readiness dashboard's "best next thing to study".
    static let sectionNamesByToken: [String: String] = Dictionary(
        uniqueKeysWithValues: sections.map { ($0.id, $0.name) }
    )

    /// The outline as AnkiKit `CoverageTopic` descriptors for the engine query,
    /// in outline order (so the report's sections come back in exam order). The
    /// `section` key is the short display label, which the CoverageView maps back
    /// to the full section title for display.
    static var coverageTopics: [CoverageTopic] {
        sections.flatMap { section in
            section.topics.map { topic in
                CoverageTopic(id: topic.id, section: section.name, name: topic.name, tag: topic.tag)
            }
        }
    }

    /// Full section title for a coverage section's short label (e.g. "Chem/Phys"
    /// → "Chemical & Physical Foundations of Biological Systems").
    static func fullName(forSection name: String) -> String? {
        sections.first { $0.name == name }?.fullName
    }

    // MARK: - Builders

    /// Builds a `Section`, deriving each topic's stable id and `MCAT::Sec::Topic`
    /// tag from the section and topic tokens so the two never drift apart.
    private static func section(
        id: String, name: String, fullName: String, topics: [(token: String, name: String)]
    ) -> Section {
        Section(
            id: id, name: name, fullName: fullName,
            topics: topics.map { token, displayName in
                Topic(
                    id: "\(id).\(token)",
                    token: token,
                    name: displayName,
                    tag: "\(tagRoot)::\(id)::\(token)"
                )
            }
        )
    }
}
