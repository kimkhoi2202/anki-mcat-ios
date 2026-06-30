import Foundation
import SwiftProtobuf

/// The period a stats screen covers, mirroring desktop Anki's `GraphRange`
/// (`ts/routes/graphs/graph-helpers.ts`). T3.1's scope is a simple
/// month / year / all switch (no custom date range).
public enum StatsPeriod: Sendable, CaseIterable, Identifiable {
    case month
    case year
    case allTime

    public var id: Self { self }

    /// Days of revlog history to fetch from the backend. `0` means "all
    /// history" (`graph_data_for_search` treats `days == 0` as no cutoff). The
    /// reviews/added graphs only see this much history; future-due and card
    /// counts are computed from the cards regardless. Matches desktop's
    /// `RevlogRange` (year vs all) widened to also support a one-month view.
    public var requestDays: UInt32 {
        switch self {
        case .month: return 31
        case .year: return 365
        case .allTime: return 0
        }
    }

    /// Inclusive upper bound (in days from today) for the Future Due graph.
    /// `nil` = unbounded. Mirrors desktop capping `xMax` to 31 / 365 / ∞.
    var futureDueMaxDay: Int? {
        switch self {
        case .month: return 31
        case .year: return 365
        case .allTime: return nil
        }
    }

    /// Inclusive lower bound (in days from today, negative = past) for the
    /// Reviews graph. `nil` = unbounded. Mirrors desktop's `xMin` of
    /// -30 / -364 / earliest-review.
    var reviewsMinDay: Int? {
        switch self {
        case .month: return -30
        case .year: return -364
        case .allTime: return nil
        }
    }
}

/// A view-facing snapshot of the engine's `graphs` data, decoupled from the
/// generated protobuf (the same way `CardBrowserRow` / `DeckTreeEntry` are).
///
/// Covers the four graphs in T3.1's scope: Future Due, Reviews (by card type),
/// Card Counts (by state), and the Today answer/retention summary. All values
/// are real data straight from the Rust core's `StatsService.graphs`.
public struct StatsSummary: Sendable, Equatable {
    /// Card counts broken down by maturity/state, for the Card Counts graph.
    public let cardCounts: CardCounts
    /// Total number of cards (the sum of every `cardCounts` bucket).
    public let totalCards: Int
    /// Cards becoming due per day for the Future Due graph. Day 0 = today and
    /// negative days are the backlog (overdue cards), which is included to match
    /// desktop's default `future_due_show_backlog = true` (see
    /// `rslib/src/config/bool.rs`).
    public let futureDue: [DayCount]
    /// Reviews answered per past day (day 0 = today), split by card type, for
    /// the Reviews graph.
    public let reviews: [ReviewDay]
    /// Today's answer/retention summary.
    public let today: Today

    public init(
        cardCounts: CardCounts,
        totalCards: Int,
        futureDue: [DayCount],
        reviews: [ReviewDay],
        today: Today
    ) {
        self.cardCounts = cardCounts
        self.totalCards = totalCards
        self.futureDue = futureDue
        self.reviews = reviews
        self.today = today
    }

    /// Card counts by state, mirroring `GraphsResponse.CardCounts.Counts` and
    /// desktop's Card Counts categories (`ts/routes/graphs/card-counts.ts`).
    public struct CardCounts: Sendable, Equatable {
        public let new: Int
        public let learn: Int
        public let relearn: Int
        public let young: Int
        public let mature: Int
        public let suspended: Int
        public let buried: Int

        public init(
            new: Int, learn: Int, relearn: Int, young: Int,
            mature: Int, suspended: Int, buried: Int
        ) {
            self.new = new
            self.learn = learn
            self.relearn = relearn
            self.young = young
            self.mature = mature
            self.suspended = suspended
            self.buried = buried
        }
    }

    /// One bar of the Future Due graph: how many cards come due on `day` days
    /// from today (0 = today, 1 = tomorrow, …).
    public struct DayCount: Sendable, Equatable, Identifiable {
        public let day: Int
        public let count: Int
        public var id: Int { day }

        public init(day: Int, count: Int) {
            self.day = day
            self.count = count
        }
    }

    /// One day's reviews split by card type, mirroring
    /// `GraphsResponse.ReviewCountsAndTimes.Reviews`. `day` is relative to today
    /// (0 = today, -1 = yesterday, …).
    public struct ReviewDay: Sendable, Equatable, Identifiable {
        public let day: Int
        public let learn: Int
        public let relearn: Int
        public let young: Int
        public let mature: Int
        public let filtered: Int
        public var id: Int { day }

        /// Total reviews answered that day across all card types.
        public var total: Int { learn + relearn + young + mature + filtered }

        public init(
            day: Int, learn: Int, relearn: Int,
            young: Int, mature: Int, filtered: Int
        ) {
            self.day = day
            self.learn = learn
            self.relearn = relearn
            self.young = young
            self.mature = mature
            self.filtered = filtered
        }
    }

    /// Today's answer/retention summary, mirroring `GraphsResponse.Today` and
    /// desktop's Today block (`ts/routes/graphs/today.ts`).
    public struct Today: Sendable, Equatable {
        public let answerCount: Int
        public let answerMillis: Int
        public let correctCount: Int
        public let matureCount: Int
        public let matureCorrect: Int
        public let learnCount: Int
        public let reviewCount: Int
        public let relearnCount: Int
        public let earlyReviewCount: Int

        public init(
            answerCount: Int, answerMillis: Int, correctCount: Int,
            matureCount: Int, matureCorrect: Int, learnCount: Int,
            reviewCount: Int, relearnCount: Int, earlyReviewCount: Int
        ) {
            self.answerCount = answerCount
            self.answerMillis = answerMillis
            self.correctCount = correctCount
            self.matureCount = matureCount
            self.matureCorrect = matureCorrect
            self.learnCount = learnCount
            self.reviewCount = reviewCount
            self.relearnCount = relearnCount
            self.earlyReviewCount = earlyReviewCount
        }

        /// Cards answered "Again" today (answered minus passed).
        public var againCount: Int { max(0, answerCount - correctCount) }

        /// Overall pass rate today as a percentage (nil when nothing studied).
        public var retentionPercent: Double? {
            guard answerCount > 0 else { return nil }
            return Double(correctCount) / Double(answerCount) * 100
        }

        /// Mature-card pass rate today as a percentage (nil with no mature reviews).
        public var matureRetentionPercent: Double? {
            guard matureCount > 0 else { return nil }
            return Double(matureCorrect) / Double(matureCount) * 100
        }

        /// Total study time today, in seconds.
        public var secondsStudied: Double { Double(answerMillis) / 1000 }
    }
}

/// Statistics convenience methods. Service/method indices come from the
/// generated `_backend_generated.py` reference (`StatsService` is service 43);
/// message shapes from `proto/anki/stats.proto`.
public extension Backend {
    /// StatsService.graphs (43, 2).
    ///
    /// Returns the full `GraphsResponse` for the given Anki search (empty =
    /// whole collection) over the last `days` of review history (`0` = all
    /// history). This is the single RPC powering Anki's stats screen on every
    /// platform.
    func graphs(search: String = "", days: UInt32 = 0) throws -> Anki_Stats_GraphsResponse {
        var req = Anki_Stats_GraphsRequest()
        req.search = search
        req.days = days
        return try run(service: 43, method: 2, req, returning: Anki_Stats_GraphsResponse.self)
    }

    /// Fetches the engine graph data and maps it into a `StatsSummary` for the
    /// given period. Keeps the protobuf decoding in AnkiKit so the UI layer (and
    /// tests) work with plain Swift values.
    func statsSummary(search: String = "", period: StatsPeriod) throws -> StatsSummary {
        let resp = try graphs(search: search, days: period.requestDays)
        return Backend.makeStatsSummary(from: resp, period: period)
    }

    /// Pure mapping from the engine response to a `StatsSummary`, split out so it
    /// can be unit-tested without a backend. Faithful to desktop Anki's default
    /// graph preferences (both `true` — see `rslib/src/config/bool.rs`): card
    /// counts use the inactive-*excluding* bucket so Suspended/Buried are their
    /// own categories (`card_counts_separate_inactive`), and Future Due keeps the
    /// backlog (`future_due_show_backlog`). Each graph is still clipped to the
    /// selected period's day window.
    static func makeStatsSummary(
        from resp: Anki_Stats_GraphsResponse, period: StatsPeriod
    ) -> StatsSummary {
        let counts = resp.cardCounts.excludingInactive
        let cardCounts = StatsSummary.CardCounts(
            new: Int(counts.newCards),
            learn: Int(counts.learn),
            relearn: Int(counts.relearn),
            young: Int(counts.young),
            mature: Int(counts.mature),
            suspended: Int(counts.suspended),
            buried: Int(counts.buried)
        )
        let totalCards = cardCounts.new + cardCounts.learn + cardCounts.relearn
            + cardCounts.young + cardCounts.mature + cardCounts.suspended + cardCounts.buried

        // Future due: include the backlog (day < 0) like desktop's default, and
        // cap the forward end to the selected period.
        let maxDay = period.futureDueMaxDay
        let futureDue = resp.futureDue.futureDue
            .filter { day, _ in maxDay.map { Int(day) <= $0 } ?? true }
            .map { StatsSummary.DayCount(day: Int($0.key), count: Int($0.value)) }
            .sorted { $0.day < $1.day }

        // Reviews: past days (day <= 0), clipped to the period's lower bound.
        let minDay = period.reviewsMinDay
        let reviews = resp.reviews.count
            .filter { day, _ in day <= 0 && (minDay.map { Int(day) >= $0 } ?? true) }
            .map { entry -> StatsSummary.ReviewDay in
                let r = entry.value
                return StatsSummary.ReviewDay(
                    day: Int(entry.key),
                    learn: Int(r.learn),
                    relearn: Int(r.relearn),
                    young: Int(r.young),
                    mature: Int(r.mature),
                    filtered: Int(r.filtered)
                )
            }
            .sorted { $0.day < $1.day }

        let t = resp.today
        let today = StatsSummary.Today(
            answerCount: Int(t.answerCount),
            answerMillis: Int(t.answerMillis),
            correctCount: Int(t.correctCount),
            matureCount: Int(t.matureCount),
            matureCorrect: Int(t.matureCorrect),
            learnCount: Int(t.learnCount),
            reviewCount: Int(t.reviewCount),
            relearnCount: Int(t.relearnCount),
            earlyReviewCount: Int(t.earlyReviewCount)
        )

        return StatsSummary(
            cardCounts: cardCounts,
            totalCards: totalCards,
            futureDue: futureDue,
            reviews: reviews,
            today: today
        )
    }
}

/// A view-facing snapshot of a single card's statistics, decoupled from the
/// generated `CardStatsResponse` protobuf (the same way `StatsSummary` is).
///
/// Mirrors the data AnkiDroid's "Card Info" screen shows (`CardInfo` /
/// `card-info.ts`): identity (deck, note type, card template), scheduling
/// (added, due, interval, ease), and review history (reviews, lapses, time).
/// Optional fields are `nil` when the engine left them unset (e.g. a brand-new
/// card has no first/latest review).
public struct CardInfo: Sendable, Equatable {
    public let cardID: Int64
    public let noteID: Int64
    /// Human-readable deck name the card lives in.
    public let deck: String
    /// Note type (model) name.
    public let notetype: String
    /// Card template name, e.g. "Card 1".
    public let cardType: String
    /// When the card was created (Unix seconds).
    public let added: Int64
    /// First review timestamp (Unix seconds); `nil` if never reviewed.
    public let firstReview: Int64?
    /// Latest review timestamp (Unix seconds); `nil` if never reviewed.
    public let latestReview: Int64?
    /// Due date as a Unix timestamp for date-scheduled (review) cards; `nil`
    /// when the card's due value isn't a date (e.g. a new card).
    public let dueDate: Int64?
    /// New-card queue position; `nil` for cards past the new queue.
    public let duePosition: Int32?
    /// Current interval in days (`0` for new/learning cards).
    public let intervalDays: UInt32
    /// Ease factor in permille (e.g. `2500` = 250%); `0` when not applicable.
    public let easePermille: UInt32
    /// Total number of reviews answered.
    public let reviews: UInt32
    /// Number of lapses (times the card was forgotten).
    public let lapses: UInt32
    /// Average answer time, in seconds.
    public let averageSecs: Float
    /// Total answer time, in seconds.
    public let totalSecs: Float
    /// FSRS retrievability (0…1) when available; `nil` otherwise.
    public let retrievability: Float?

    public init(
        cardID: Int64, noteID: Int64, deck: String, notetype: String,
        cardType: String, added: Int64, firstReview: Int64?, latestReview: Int64?,
        dueDate: Int64?, duePosition: Int32?, intervalDays: UInt32,
        easePermille: UInt32, reviews: UInt32, lapses: UInt32,
        averageSecs: Float, totalSecs: Float, retrievability: Float?
    ) {
        self.cardID = cardID
        self.noteID = noteID
        self.deck = deck
        self.notetype = notetype
        self.cardType = cardType
        self.added = added
        self.firstReview = firstReview
        self.latestReview = latestReview
        self.dueDate = dueDate
        self.duePosition = duePosition
        self.intervalDays = intervalDays
        self.easePermille = easePermille
        self.reviews = reviews
        self.lapses = lapses
        self.averageSecs = averageSecs
        self.totalSecs = totalSecs
        self.retrievability = retrievability
    }
}

/// Card-info convenience methods. `StatsService.card_stats` is service 43,
/// method 0 (confirmed in `_backend_generated.py`); the request is a
/// `cards.CardId` and the response a `stats.CardStatsResponse`.
public extension Backend {
    /// StatsService.cardStats (43, 0).
    ///
    /// Returns the raw per-card statistics the engine assembles for the Card
    /// Info screen — the single RPC powering "Card Info" on every Anki platform.
    func cardStats(cardID: Int64) throws -> Anki_Stats_CardStatsResponse {
        var req = Anki_Cards_CardId()
        req.cid = cardID
        return try run(service: 43, method: 0, req, returning: Anki_Stats_CardStatsResponse.self)
    }

    /// Fetches a card's stats and maps them into a `CardInfo` for the UI, keeping
    /// the protobuf decoding in AnkiKit so the view layer (and tests) work with
    /// plain Swift values.
    func cardInfo(cardID: Int64) throws -> CardInfo {
        return Backend.makeCardInfo(from: try cardStats(cardID: cardID))
    }

    /// Pure mapping from the engine response to a `CardInfo`, split out so it can
    /// be unit-tested without a backend. Optional fields use the response's
    /// `has*` accessors so "unset" stays distinct from a real zero value.
    static func makeCardInfo(from r: Anki_Stats_CardStatsResponse) -> CardInfo {
        CardInfo(
            cardID: r.cardID,
            noteID: r.noteID,
            deck: r.deck,
            notetype: r.notetype,
            cardType: r.cardType,
            added: r.added,
            firstReview: r.hasFirstReview ? r.firstReview : nil,
            latestReview: r.hasLatestReview ? r.latestReview : nil,
            dueDate: r.hasDueDate ? r.dueDate : nil,
            duePosition: r.hasDuePosition ? r.duePosition : nil,
            intervalDays: r.interval,
            easePermille: r.ease,
            reviews: r.reviews,
            lapses: r.lapses,
            averageSecs: r.averageSecs,
            totalSecs: r.totalSecs,
            retrievability: r.hasFsrsRetrievability ? r.fsrsRetrievability : nil
        )
    }
}
