// Copyright: Ankitects Pty Ltd and contributors
// License: GNU AGPL, version 3 or later; http://www.gnu.org/licenses/agpl.html

import Foundation

/// A single MCAT topic's weakness read-out for the "Focus Weak Topics" screen,
/// built from the engine's points-at-stake per-topic summary
/// (`SchedulerService.GetPointsAtStakeQueue`). Decouples the SwiftUI layer from
/// the generated protobuf type.
struct WeakTopic: Identifiable, Equatable {
    /// Topic name (the component below the `MCAT::` prefix), also the identity.
    var id: String { topic }
    let topic: String
    /// Due review cards in this topic.
    let cardCount: Int
    /// `1 − mean(FSRS retrievability)` in `0...1`; higher means weaker. Shown as
    /// a percentage and drives the ordering.
    let weakness: Double
    /// `topic_weight × weakness` — the score the engine sorts cards by.
    let pointsAtStake: Double
    /// Mean FSRS retrievability across the topic's memory-state cards, if any.
    let meanRetrievability: Double?
}
