import Foundation
import SwiftProtobuf

/// Points-at-stake review ordering (PRD 7a) — the Rust-change RPC baked into
/// AnkiCore, running on-device. Service/method indices come from the generated
/// `_backend_generated.py` reference.
///
/// `SchedulerService.GetPointsAtStakeQueue` returns a *read-only* reordering of
/// the due review queue, surfacing the topics the student is weakest at first. A
/// card's score is `topic_weight x student_weakness`, where weakness is
/// `1 - mean(FSRS retrievability)` over the topic's due review cards. The backend
/// never mutates a card to produce this (it only reads existing FSRS memory
/// state), so it is safe to call before a study session and never affects
/// scheduling or undo.
public extension Backend {
    /// SchedulerService.getPointsAtStakeQueue (13, 39).
    ///
    /// - Parameters:
    ///   - topicPrefix: tag prefix identifying a card's topic tag. An empty
    ///     string falls back to the engine default (`MCAT::`). The first tag
    ///     under this prefix determines a card's topic — its top component (the
    ///     level immediately under the prefix). Notes with no matching tag bucket
    ///     into the engine's `untagged` topic.
    ///   - weightBySize: when false (the default), every topic weighs equally and
    ///     a card's `pointsAtStake == weakness`, so the weakest topics surface
    ///     first. When true, each topic is weighted by its share of the due
    ///     review queue (`card_count / total_due`), favouring larger weak topics.
    /// - Returns: the due review cards ordered by descending points-at-stake
    ///   (ties break by ascending card id) plus per-topic aggregates, in
    ///   first-seen queue order.
    func pointsAtStakeQueue(
        topicPrefix: String = "MCAT::",
        weightBySize: Bool = false
    ) throws -> Anki_Scheduler_PointsAtStakeQueue {
        var req = Anki_Scheduler_GetPointsAtStakeQueueRequest()
        req.topicTagPrefix = topicPrefix
        req.weightByTopicSize = weightBySize
        return try run(
            service: 13, method: 39, req,
            returning: Anki_Scheduler_PointsAtStakeQueue.self
        )
    }
}
