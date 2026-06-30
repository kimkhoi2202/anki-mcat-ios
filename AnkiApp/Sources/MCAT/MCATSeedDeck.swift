import Foundation

/// A representative, real-content MCAT deck for the coverage map (PRD 7c).
///
/// ~46 Basic cards of accurate MCAT facts spread across **many but deliberately
/// not all** outline topics, so coverage is partial and meaningful. By design it
/// covers 24 of the 50 `MCATOutline` topics (≈48% overall) — just under the 50%
/// give-up line — so the dashboard exercises both the per-topic covered/missing
/// breakdown and the abstain banner. CARS is intentionally left almost entirely
/// uncovered (1 of 11), reflecting that flashcards structurally cannot serve a
/// passage-reasoning section that bans outside facts (brainlift POV 2).
///
/// Each card names the `MCATOutline` topic id it teaches; the seeder resolves
/// that id to the topic's `MCAT::<Section>::<Topic>` tag, so the cards and the
/// taxonomy can never drift apart.
enum MCATSeedDeck {
    /// The deck these cards are seeded into. Kept separate from the points-at-stake
    /// "MCAT" demo deck so neither feature perturbs the other.
    static let deckName = "MCAT Content"

    /// One seed card: the outline topic it covers plus its front/back text.
    struct SeedCard {
        let topicID: String
        let front: String
        let back: String
    }

    /// The seed cards. Topic ids must exist in `MCATOutline`; the seeder skips any
    /// that don't (defensive against a future taxonomy rename).
    static let cards: [SeedCard] = [
        // MARK: Chem/Phys — 7 of 12 topics covered

        SeedCard(topicID: "ChemPhys.Kinematics",
                 front: "A projectile is launched horizontally. What is its initial vertical velocity?",
                 back: "Zero — horizontal and vertical motion are independent."),
        SeedCard(topicID: "ChemPhys.Kinematics",
                 front: "What does the area under a velocity–time graph represent?",
                 back: "Displacement."),
        SeedCard(topicID: "ChemPhys.ForceAndEnergy",
                 front: "State the work–energy theorem.",
                 back: "The net work done on an object equals its change in kinetic energy (W = ΔKE)."),
        SeedCard(topicID: "ChemPhys.ForceAndEnergy",
                 front: "Gravitational potential energy near Earth's surface?",
                 back: "U = mgh."),
        SeedCard(topicID: "ChemPhys.Fluids",
                 front: "State Bernoulli's principle qualitatively.",
                 back: "In ideal flow, where a fluid moves faster its pressure is lower."),
        SeedCard(topicID: "ChemPhys.Fluids",
                 front: "What is the buoyant force on a submerged object (Archimedes' principle)?",
                 back: "It equals the weight of the fluid the object displaces."),
        SeedCard(topicID: "ChemPhys.Thermodynamics",
                 front: "State the first law of thermodynamics.",
                 back: "ΔU = Q − W: internal-energy change equals heat added minus work done by the system."),
        SeedCard(topicID: "ChemPhys.Thermodynamics",
                 front: "For a spontaneous process, what is the sign of the entropy change of the universe?",
                 back: "Positive — total entropy increases (second law)."),
        SeedCard(topicID: "ChemPhys.AtomicAndNuclear",
                 front: "What particle is emitted in beta-minus (β⁻) decay?",
                 back: "An electron — a neutron converts to a proton."),
        SeedCard(topicID: "ChemPhys.AtomicAndNuclear",
                 front: "Define an atom's mass number (A).",
                 back: "The total number of protons plus neutrons."),
        SeedCard(topicID: "ChemPhys.AcidsAndBases",
                 front: "Write the Henderson–Hasselbalch equation.",
                 back: "pH = pKa + log([A⁻]/[HA])."),
        SeedCard(topicID: "ChemPhys.AcidsAndBases",
                 front: "At the half-equivalence point of a weak-acid titration, pH equals what?",
                 back: "The pKa of the acid (when [HA] = [A⁻])."),
        SeedCard(topicID: "ChemPhys.ReactionKinetics",
                 front: "How does a catalyst speed up a reaction?",
                 back: "It lowers the activation energy and is not consumed; it does not change ΔG or equilibrium."),
        SeedCard(topicID: "ChemPhys.ReactionKinetics",
                 front: "What are the units of a first-order rate constant?",
                 back: "s⁻¹ (inverse time)."),

        // MARK: CARS — 1 of 11 topics covered (flashcards can't serve CARS)

        SeedCard(topicID: "CARS.FoundationsOfComprehension",
                 front: "In CARS, what is a passage's 'main idea'?",
                 back: "The central thesis the author is arguing — not a single supporting detail or example."),

        // MARK: Bio/Biochem — 9 of 14 topics covered

        SeedCard(topicID: "BioBiochem.AminoAcidsAndProteins",
                 front: "How many standard (proteinogenic) amino acids are there?",
                 back: "20."),
        SeedCard(topicID: "BioBiochem.AminoAcidsAndProteins",
                 front: "Which standard amino acid is achiral?",
                 back: "Glycine — its side chain is a single hydrogen."),
        SeedCard(topicID: "BioBiochem.Enzymes",
                 front: "What does Vmax represent in Michaelis–Menten kinetics?",
                 back: "The maximum rate, reached when enzyme is saturated with substrate."),
        SeedCard(topicID: "BioBiochem.Enzymes",
                 front: "How does a competitive inhibitor affect apparent Km and Vmax?",
                 back: "It raises apparent Km; Vmax is unchanged (it can be overcome by more substrate)."),
        SeedCard(topicID: "BioBiochem.NucleicAcids",
                 front: "Which base pairs with adenine in DNA, and by how many hydrogen bonds?",
                 back: "Thymine, via two hydrogen bonds."),
        SeedCard(topicID: "BioBiochem.NucleicAcids",
                 front: "What sugar is found in RNA?",
                 back: "Ribose (DNA uses deoxyribose)."),
        SeedCard(topicID: "BioBiochem.DNAReplication",
                 front: "In which direction does DNA polymerase synthesize a new strand?",
                 back: "5′ → 3′."),
        SeedCard(topicID: "BioBiochem.DNAReplication",
                 front: "What enzyme joins Okazaki fragments on the lagging strand?",
                 back: "DNA ligase."),
        SeedCard(topicID: "BioBiochem.GeneExpression",
                 front: "Which enzyme transcribes protein-coding genes (mRNA) in eukaryotes?",
                 back: "RNA polymerase II."),
        SeedCard(topicID: "BioBiochem.GeneExpression",
                 front: "What is a codon?",
                 back: "A triplet of mRNA nucleotides specifying one amino acid (or a stop signal)."),
        SeedCard(topicID: "BioBiochem.Genetics",
                 front: "State Mendel's law of segregation.",
                 back: "An organism's two alleles for a gene separate so each gamete carries only one."),
        SeedCard(topicID: "BioBiochem.Genetics",
                 front: "What is the genotypic ratio of a monohybrid Aa × Aa cross?",
                 back: "1 AA : 2 Aa : 1 aa."),
        SeedCard(topicID: "BioBiochem.Bioenergetics",
                 front: "What is the cell's primary energy currency?",
                 back: "ATP (adenosine triphosphate)."),
        SeedCard(topicID: "BioBiochem.Bioenergetics",
                 front: "Is ATP hydrolysis exergonic or endergonic?",
                 back: "Exergonic — it releases energy (ΔG < 0)."),
        SeedCard(topicID: "BioBiochem.CarbohydrateMetabolism",
                 front: "What is the net ATP yield of glycolysis per glucose?",
                 back: "2 ATP (plus 2 NADH and 2 pyruvate)."),
        SeedCard(topicID: "BioBiochem.CarbohydrateMetabolism",
                 front: "What is the rate-limiting enzyme of glycolysis?",
                 back: "Phosphofructokinase-1 (PFK-1)."),
        SeedCard(topicID: "BioBiochem.CellBiology",
                 front: "Which organelle is the site of oxidative phosphorylation?",
                 back: "The mitochondrion (on the inner membrane)."),
        SeedCard(topicID: "BioBiochem.CellBiology",
                 front: "What is the role of the rough endoplasmic reticulum?",
                 back: "Synthesis and folding of secreted and membrane proteins — it is studded with ribosomes."),

        // MARK: Psych/Soc — 7 of 13 topics covered

        SeedCard(topicID: "PsychSoc.SensationAndPerception",
                 front: "Define the absolute threshold.",
                 back: "The minimum stimulus intensity detectable 50% of the time."),
        SeedCard(topicID: "PsychSoc.SensationAndPerception",
                 front: "What are retinal rods specialized for?",
                 back: "Vision in dim light (they do not encode color)."),
        SeedCard(topicID: "PsychSoc.LearningAndConditioning",
                 front: "In classical conditioning, what is the unconditioned stimulus (US)?",
                 back: "A stimulus that triggers a response naturally, without prior learning."),
        SeedCard(topicID: "PsychSoc.LearningAndConditioning",
                 front: "Define negative reinforcement.",
                 back: "Removing an aversive stimulus to increase a behavior (not punishment)."),
        SeedCard(topicID: "PsychSoc.MemoryAndCognition",
                 front: "Roughly how many items can short-term memory hold (Miller)?",
                 back: "About 7 ± 2."),
        SeedCard(topicID: "PsychSoc.MemoryAndCognition",
                 front: "What is proactive interference?",
                 back: "Older memories disrupting the recall of newer information."),
        SeedCard(topicID: "PsychSoc.MotivationAndEmotion",
                 front: "What does the Yerkes–Dodson law describe?",
                 back: "Performance peaks at a moderate level of arousal (an inverted-U)."),
        SeedCard(topicID: "PsychSoc.MotivationAndEmotion",
                 front: "What does the James–Lange theory of emotion claim?",
                 back: "Emotion is the interpretation of bodily/physiological arousal that follows a stimulus."),
        SeedCard(topicID: "PsychSoc.Personality",
                 front: "Name the 'Big Five' personality traits.",
                 back: "Openness, Conscientiousness, Extraversion, Agreeableness, Neuroticism (OCEAN)."),
        SeedCard(topicID: "PsychSoc.SocialInfluence",
                 front: "What did Milgram's classic experiment study?",
                 back: "Obedience to authority."),
        SeedCard(topicID: "PsychSoc.SocialInfluence",
                 front: "Define the bystander effect.",
                 back: "People are less likely to help when others are present (diffusion of responsibility)."),
        SeedCard(topicID: "PsychSoc.SocialStratification",
                 front: "Define social mobility.",
                 back: "The movement of individuals or groups between positions in a social hierarchy."),
        SeedCard(topicID: "PsychSoc.SocialStratification",
                 front: "What is meritocracy?",
                 back: "A system in which social status is allocated by ability and effort."),
    ]
}
