import Foundation
import SwiftProtobuf

/// MCAT coverage map (PRD 7c) — the engine-backed half of "list every MCAT
/// outline topic, mark deck coverage, show % on the dashboard; below the line,
/// abstain."
///
/// These value types are deliberately taxonomy-agnostic: AnkiKit is the engine
/// bridge and knows nothing about the AAMC outline. The caller (AnkiApp's
/// `MCATOutline`) supplies the topics to check as `CoverageTopic`s and the engine
/// reports, per topic, how many cards carry that topic's tag. The report is
/// structured so the upcoming Memory / Performance / Readiness scores can consume
/// `fractionCovered` directly as the PRD's "% of exam covered" confidence input
/// and `meetsCoverageThreshold` as the coverage half of the give-up rule.

/// One outline topic to check coverage for: a stable `id`, the `section` it rolls
/// up under (a display label, e.g. "Chem/Phys"), a human-readable `name`, and the
/// `tag` that identifies its cards (e.g. `MCAT::ChemPhys::Kinematics`).
public struct CoverageTopic: Sendable, Equatable {
    public let id: String
    public let section: String
    public let name: String
    public let tag: String

    public init(id: String, section: String, name: String, tag: String) {
        self.id = id
        self.section = section
        self.name = name
        self.tag = tag
    }
}

/// Coverage of a single topic: how many cards in the collection carry its tag,
/// and therefore whether the topic is "covered" (>= 1 card).
public struct TopicCoverage: Identifiable, Sendable, Equatable {
    public let id: String
    public let section: String
    public let name: String
    public let tag: String
    /// Cards matching the topic's tag (the exact tag or any descendant subtag).
    public let cardCount: Int

    /// A topic is covered once at least one card exists for it.
    public var isCovered: Bool { cardCount > 0 }

    public init(id: String, section: String, name: String, tag: String, cardCount: Int) {
        self.id = id
        self.section = section
        self.name = name
        self.tag = tag
        self.cardCount = cardCount
    }
}

/// Coverage of one outline section: its topics plus covered/total rollups.
public struct SectionCoverage: Identifiable, Sendable, Equatable {
    /// The section's display label, which is also its identity.
    public var id: String { section }
    public let section: String
    public let topics: [TopicCoverage]

    /// Topics with at least one card.
    public var coveredCount: Int { topics.lazy.filter(\.isCovered).count }
    /// Total topics in the section.
    public var totalCount: Int { topics.count }
    /// Fraction of the section's topics that are covered, in `0...1`.
    public var fractionCovered: Double {
        totalCount == 0 ? 0 : Double(coveredCount) / Double(totalCount)
    }
    /// `fractionCovered` as a rounded whole percentage.
    public var percentCovered: Int { Int((fractionCovered * 100).rounded()) }

    public init(section: String, topics: [TopicCoverage]) {
        self.section = section
        self.topics = topics
    }
}

/// The whole coverage map: per-section coverage plus overall rollups and the
/// scoring-threshold helpers the (future) scores and the abstain banner read.
public struct CoverageReport: Sendable, Equatable {
    public let sections: [SectionCoverage]

    public init(sections: [SectionCoverage]) {
        self.sections = sections
    }

    /// Topics covered across every section.
    public var coveredTopics: Int { sections.reduce(0) { $0 + $1.coveredCount } }
    /// Total topics across every section.
    public var totalTopics: Int { sections.reduce(0) { $0 + $1.totalCount } }
    /// Fraction of all outline topics that are covered, in `0...1` — the PRD's
    /// "% of exam covered" signal.
    public var fractionCovered: Double {
        totalTopics == 0 ? 0 : Double(coveredTopics) / Double(totalTopics)
    }
    /// `fractionCovered` as a rounded whole percentage.
    public var percentCovered: Int { Int((fractionCovered * 100).rounded()) }

    /// The coverage half of the PRD give-up rule (example: "No score until …
    /// >= 50% topic coverage"). Documented and reused so the abstain banner and
    /// the future Readiness score apply one threshold, not two drifting copies.
    public static let scoringThreshold = 0.5

    /// True once coverage clears `scoringThreshold`. When false, the app must
    /// abstain from showing a score.
    public var meetsCoverageThreshold: Bool { fractionCovered >= Self.scoringThreshold }
}

public extension Backend {
    /// Computes the MCAT coverage map for `topics`.
    ///
    /// For each topic it runs a tag search through the same engine search the
    /// Card Browser uses (`SearchService.searchCards`, 29/1) and counts the
    /// matches; a topic with >= 1 card is covered. Results are grouped by section
    /// (in first-seen order, so passing topics in outline order yields sections
    /// in outline order) and rolled up into a `CoverageReport`.
    ///
    /// The per-topic query matches the topic's tag exactly *or any descendant
    /// subtag* (`tag:X OR tag:X::*`). That counts cards filed under a deeper tag
    /// hierarchy — as real decks like AnKing's do — toward the topic, while not
    /// matching a sibling tag that merely shares a name prefix. It expresses the
    /// same intent as the PRD's `tag:MCAT::Section::Topic*` example, boundary-safe.
    func coverage(forTopics topics: [CoverageTopic]) throws -> CoverageReport {
        var sectionOrder: [String] = []
        var topicsBySection: [String: [TopicCoverage]] = [:]

        for topic in topics {
            let count = try searchCards(query: Backend.coverageQuery(forTag: topic.tag)).count
            let coverage = TopicCoverage(
                id: topic.id, section: topic.section, name: topic.name,
                tag: topic.tag, cardCount: count
            )
            if topicsBySection[topic.section] == nil {
                topicsBySection[topic.section] = []
                sectionOrder.append(topic.section)
            }
            topicsBySection[topic.section]?.append(coverage)
        }

        let sections = sectionOrder.map { section in
            SectionCoverage(section: section, topics: topicsBySection[section] ?? [])
        }
        return CoverageReport(sections: sections)
    }

    /// Builds the tag search for a topic: its exact tag plus any descendant
    /// subtag, so hierarchical decks still count toward the topic without a
    /// shared-prefix sibling leaking in.
    internal static func coverageQuery(forTag tag: String) -> String {
        "tag:\(tag) OR tag:\(tag)::*"
    }
}
