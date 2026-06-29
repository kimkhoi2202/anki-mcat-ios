import SwiftUI
import Charts
import AnkiKit

/// Statistics screen — a native SwiftUI/Swift Charts rendering of Anki's stats.
///
/// Approach (T3.1): rather than embedding Anki's Svelte graphs in a WebView
/// (AnkiDroid bundles those prebuilt web assets and serves them from a local
/// HTTP server — assets we don't ship), this reads the same backend data through
/// `StatsService.graphs` and draws it natively. The data is real, straight from
/// the Rust core; only the rendering is native.
///
/// Shows the four graphs in scope — Today's answer/retention summary, Future
/// Due, Reviews (by card type), and Card Counts (by state) — with a
/// month / year / all period switch. No custom date range or per-graph settings
/// (out of scope).
struct StatsView: View {
    @ObservedObject var store: AnkiStore

    @State private var period: StatsPeriod = .month
    @State private var summary: StatsSummary?
    @State private var phase: Phase = .loading

    private enum Phase: Equatable {
        case loading
        case loaded
        case failed(String)
    }

    var body: some View {
        ZStack {
            DS.background.ignoresSafeArea()
            ScrollView {
                VStack(spacing: DS.Spacing.l) {
                    periodPicker
                    content
                }
                .padding(DS.Spacing.l)
            }
        }
        .navigationTitle("Statistics")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: period) { await load() }
    }

    // MARK: - Period switch

    private var periodPicker: some View {
        Picker("Period", selection: $period) {
            Text("Month").tag(StatsPeriod.month)
            Text("Year").tag(StatsPeriod.year)
            Text("All").tag(StatsPeriod.allTime)
        }
        .pickerStyle(.segmented)
        .accessibilityLabel("Statistics period")
    }

    // MARK: - Content states

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .loading:
            loadingCard
        case .failed(let message):
            failedCard(message)
        case .loaded:
            if let summary {
                TodayCard(today: summary.today)
                FutureDueCard(data: summary.futureDue)
                ReviewsCard(data: summary.reviews)
                CardCountsCard(counts: summary.cardCounts, total: summary.totalCards)
            }
        }
    }

    private var loadingCard: some View {
        VStack(spacing: DS.Spacing.m) {
            ProgressView()
            Text("Crunching your reviews…")
                .font(DS.Typography.caption)
                .foregroundStyle(DS.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, DS.Spacing.xl)
        .dsCard()
    }

    private func failedCard(_ message: String) -> some View {
        VStack(spacing: DS.Spacing.m) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 36))
                .foregroundStyle(DS.again)
            Text("Couldn’t load statistics")
                .font(DS.Typography.headline)
                .foregroundStyle(DS.textPrimary)
            Text(message)
                .font(DS.Typography.caption)
                .foregroundStyle(DS.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, DS.Spacing.xl)
        .dsCard()
    }

    // MARK: - Loading

    private func load() async {
        if summary == nil { phase = .loading }
        do {
            let result = try await store.statsSummary(period: period)
            summary = result
            phase = .loaded
        } catch {
            phase = .failed(describe(error))
        }
    }

    /// Extracts a human-readable message from a thrown error, decoding the
    /// engine's protobuf `BackendError` when present.
    private func describe(_ error: Error) -> String {
        if case let AnkiError.backendError(data) = error,
           let backendError = try? Anki_Backend_BackendError(serializedBytes: data),
           !backendError.message.isEmpty {
            return backendError.message
        }
        return error.localizedDescription
    }
}

// MARK: - Today

/// Today's answer/retention summary, mirroring desktop Anki's Today block
/// (`ts/routes/graphs/today.ts`): cards studied + time, the again count and
/// percentage, the per-type breakdown, and mature retention.
private struct TodayCard: View {
    let today: StatsSummary.Today

    var body: some View {
        StatsCard(title: "Today") {
            if today.answerCount == 0 {
                Text("No cards studied today.")
                    .font(DS.Typography.body)
                    .foregroundStyle(DS.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(spacing: DS.Spacing.s) {
                    DSStatRow("Studied", value: studied)
                    if let retention = today.retentionPercent {
                        DSStatRow("Correct", value: percent(retention))
                    }
                    DSStatRow("Again", value: again)
                    DSStatRow("Mature", value: mature)
                    Text(typeBreakdown)
                        .font(DS.Typography.caption)
                        .foregroundStyle(DS.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, DS.Spacing.xs)
                }
            }
        }
    }

    private var studied: String {
        let noun = today.answerCount == 1 ? "card" : "cards"
        return "\(today.answerCount) \(noun) in \(StatsFormat.duration(today.secondsStudied))"
    }

    private var again: String {
        guard today.answerCount > 0 else { return "—" }
        let pct = Double(today.againCount) / Double(today.answerCount) * 100
        return "\(today.againCount) (\(percent(pct)))"
    }

    private var mature: String {
        guard today.matureCount > 0 else { return "No mature cards" }
        guard let pct = today.matureRetentionPercent else { return "—" }
        return "\(today.matureCorrect)/\(today.matureCount) (\(percent(pct)))"
    }

    private var typeBreakdown: String {
        "Learn \(today.learnCount) · Review \(today.reviewCount) · Relearn \(today.relearnCount) · Filtered \(today.earlyReviewCount)"
    }

    private func percent(_ value: Double) -> String {
        String(format: "%.0f%%", value)
    }
}

// MARK: - Future Due

/// Future Due — how many review cards come due over the coming days
/// (`ts/routes/graphs/future-due.ts`). A simple green column per day.
private struct FutureDueCard: View {
    let data: [StatsSummary.DayCount]

    private var total: Int { data.reduce(0) { $0 + $1.count } }
    private var dueTomorrow: Int { data.first { $0.day == 1 }?.count ?? 0 }

    var body: some View {
        StatsCard(title: "Future Due") {
            if total == 0 {
                EmptyChart(message: "No cards due in this period.")
            } else {
                Chart(data) { bucket in
                    BarMark(
                        x: .value("In days", bucket.day),
                        y: .value("Cards", bucket.count)
                    )
                    .foregroundStyle(StatPalette.young)
                    .cornerRadius(2)
                }
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 5)) { value in
                        AxisGridLine()
                        AxisTick()
                        AxisValueLabel {
                            if let day = value.as(Int.self) {
                                Text(day == 0 ? "now" : "\(day)d")
                            }
                        }
                    }
                }
                .chartYAxis { AxisMarks(position: .leading) }
                .frame(height: 180)
                .accessibilityLabel("Future due cards by day")

                HStack {
                    Text("Total: \(total)")
                    Spacer()
                    Text("Due tomorrow: \(dueTomorrow)")
                }
                .font(DS.Typography.caption)
                .foregroundStyle(DS.textSecondary)
                .padding(.top, DS.Spacing.xs)
            }
        }
    }
}

// MARK: - Reviews

/// Reviews — reviews answered per past day, split by card type and stacked, like
/// desktop Anki's Reviews graph (`ts/routes/graphs/reviews.ts`).
private struct ReviewsCard: View {
    let data: [StatsSummary.ReviewDay]

    /// Flattened (day, type, count) rows for the stacked bar chart.
    private struct Entry: Identifiable {
        let id = UUID()
        let day: Int
        let type: ReviewType
        let count: Int
    }

    private var entries: [Entry] {
        data.flatMap { day -> [Entry] in
            ReviewType.allCases.compactMap { type in
                let count = type.count(in: day)
                return count > 0 ? Entry(day: day.day, type: type, count: count) : nil
            }
        }
    }

    private var total: Int { data.reduce(0) { $0 + $1.total } }

    var body: some View {
        StatsCard(title: "Reviews") {
            if total == 0 {
                EmptyChart(message: "No reviews in this period.")
            } else {
                Chart(entries) { entry in
                    BarMark(
                        x: .value("Days ago", entry.day),
                        y: .value("Reviews", entry.count)
                    )
                    .foregroundStyle(by: .value("Type", entry.type.label))
                }
                .chartForegroundStyleScale(
                    domain: ReviewType.allCases.map(\.label),
                    range: ReviewType.allCases.map(\.color)
                )
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 5)) { value in
                        AxisGridLine()
                        AxisTick()
                        AxisValueLabel {
                            if let day = value.as(Int.self) {
                                Text(day == 0 ? "today" : "\(day)")
                            }
                        }
                    }
                }
                .chartYAxis { AxisMarks(position: .leading) }
                .chartLegend(position: .bottom, spacing: DS.Spacing.s)
                .frame(height: 200)
                .accessibilityLabel("Reviews per day by card type")

                Text("Total: ^[\(total) review](inflect: true)")
                    .font(DS.Typography.caption)
                    .foregroundStyle(DS.textSecondary)
                    .padding(.top, DS.Spacing.xs)
            }
        }
    }
}

/// The five review card types Anki splits reviews into, in stacking order
/// (mature at the bottom), with the engine's colour conventions.
private enum ReviewType: CaseIterable {
    case mature, young, learn, relearn, filtered

    var label: String {
        switch self {
        case .mature: return "Mature"
        case .young: return "Young"
        case .learn: return "Learn"
        case .relearn: return "Relearn"
        case .filtered: return "Filtered"
        }
    }

    var color: Color {
        switch self {
        case .mature: return StatPalette.mature
        case .young: return StatPalette.young
        case .learn: return StatPalette.learn
        case .relearn: return StatPalette.relearn
        case .filtered: return StatPalette.filtered
        }
    }

    func count(in day: StatsSummary.ReviewDay) -> Int {
        switch self {
        case .mature: return day.mature
        case .young: return day.young
        case .learn: return day.learn
        case .relearn: return day.relearn
        case .filtered: return day.filtered
        }
    }
}

// MARK: - Card Counts

/// Card Counts — every card in the collection by state, as a single stacked bar
/// plus a legend with counts and percentages. Mirrors desktop Anki's Card Counts
/// graph (`ts/routes/graphs/card-counts.ts`); rendered as a stacked bar instead
/// of a pie because `SectorMark` requires iOS 17 and the app targets iOS 16.
private struct CardCountsCard: View {
    let counts: StatsSummary.CardCounts
    let total: Int

    private struct Slice: Identifiable {
        let id = UUID()
        let label: String
        let count: Int
        let color: Color
    }

    private var slices: [Slice] {
        [
            Slice(label: "New", count: counts.new, color: StatPalette.new),
            Slice(label: "Learning", count: counts.learn, color: StatPalette.learn),
            Slice(label: "Relearning", count: counts.relearn, color: StatPalette.relearn),
            Slice(label: "Young", count: counts.young, color: StatPalette.young),
            Slice(label: "Mature", count: counts.mature, color: StatPalette.mature),
            Slice(label: "Suspended", count: counts.suspended, color: StatPalette.suspended),
            Slice(label: "Buried", count: counts.buried, color: StatPalette.buried),
        ]
    }

    var body: some View {
        StatsCard(title: "Card Counts") {
            if total == 0 {
                EmptyChart(message: "This collection has no cards yet.")
            } else {
                Chart(slices) { slice in
                    BarMark(
                        x: .value("Count", slice.count),
                        y: .value("Cards", "All"),
                        height: .fixed(26)
                    )
                    .foregroundStyle(slice.color)
                }
                .chartXAxis(.hidden)
                .chartYAxis(.hidden)
                .chartLegend(.hidden)
                .frame(height: 34)
                .clipShape(RoundedRectangle(cornerRadius: DS.Radius.small, style: .continuous))
                .accessibilityLabel("Card counts by state")

                DSStatRow("Total", value: "\(total)")
                    .padding(.top, DS.Spacing.xs)

                VStack(spacing: DS.Spacing.s) {
                    ForEach(slices.filter { $0.count > 0 }) { slice in
                        legendRow(slice)
                    }
                }
                .padding(.top, DS.Spacing.xs)
            }
        }
    }

    private func legendRow(_ slice: Slice) -> some View {
        let pct = total > 0 ? Double(slice.count) / Double(total) * 100 : 0
        return HStack(spacing: DS.Spacing.s) {
            Circle()
                .fill(slice.color)
                .frame(width: 10, height: 10)
            Text(slice.label)
                .font(DS.Typography.body)
                .foregroundStyle(DS.textPrimary)
            Spacer(minLength: DS.Spacing.s)
            Text("\(slice.count)")
                .font(DS.Typography.body)
                .monospacedDigit()
                .foregroundStyle(DS.textPrimary)
            Text(String(format: "%.0f%%", pct))
                .font(DS.Typography.caption)
                .monospacedDigit()
                .foregroundStyle(DS.textSecondary)
                .frame(minWidth: 40, alignment: .trailing)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(slice.label): \(slice.count), \(String(format: "%.0f", pct)) percent")
    }
}

// MARK: - Shared building blocks

/// A titled stats card following the app's surface/typography tokens.
private struct StatsCard<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.m) {
            Text(title)
                .font(DS.Typography.headline)
                .foregroundStyle(DS.textPrimary)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .dsCard()
    }
}

/// Placeholder shown in place of a chart when a graph has no data for the
/// selected period (real, just empty — common on a fresh collection).
private struct EmptyChart: View {
    let message: String

    var body: some View {
        Text(message)
            .font(DS.Typography.body)
            .foregroundStyle(DS.textSecondary)
            .frame(maxWidth: .infinity, minHeight: 80)
            .multilineTextAlignment(.center)
    }
}

/// Anki's stats colour palette (`card-counts.ts` / `reviews.ts`): blue new,
/// orange learning, red relearning, green young, darker green mature, yellow
/// suspended, grey buried, purple filtered.
private enum StatPalette {
    static let new = Color(rgb: 0x6BAED6)
    static let learn = Color(rgb: 0xFD8D3C)
    static let relearn = Color(rgb: 0xFB6A4A)
    static let young = Color(rgb: 0x74C476)
    static let mature = Color(rgb: 0x2E8B57)
    static let suspended = Color(rgb: 0xFFDC41)
    static let buried = Color(rgb: 0x9E9E9E)
    static let filtered = Color(rgb: 0x9E9AC8)
}

/// Duration formatting for the Today summary (seconds → "45s" / "2m" / "1h 4m").
private enum StatsFormat {
    static func duration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total)s" }
        let minutes = total / 60
        if minutes < 60 {
            let secs = total % 60
            return secs == 0 ? "\(minutes)m" : "\(minutes)m \(secs)s"
        }
        let hours = minutes / 60
        let mins = minutes % 60
        return mins == 0 ? "\(hours)h" : "\(hours)h \(mins)m"
    }
}

private extension Color {
    /// Builds a color from a `0xRRGGBB` integer in the sRGB space.
    init(rgb: UInt32) {
        self.init(
            .sRGB,
            red: Double((rgb >> 16) & 0xFF) / 255,
            green: Double((rgb >> 8) & 0xFF) / 255,
            blue: Double(rgb & 0xFF) / 255
        )
    }
}
