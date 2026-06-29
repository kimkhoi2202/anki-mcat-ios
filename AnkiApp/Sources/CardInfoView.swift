import SwiftUI
import AnkiKit

/// Card Info — a read-only native clone of AnkiDroid's "Card Info" screen.
///
/// Shows the per-card statistics the engine assembles via `StatsService.card_stats`:
/// identity (deck, note type, card template), scheduling (added, due, interval,
/// ease), and review history (reviews, lapses, average / total time). The data is
/// real, straight from the Rust core; only the rendering is native.
///
/// Scope (T3.3): read-only summary. No revlog list, FSRS detail panel, or
/// editing (out of scope). Presented as a sheet from the Card Browser and the
/// Reviewer.
@MainActor
struct CardInfoView: View {
    @ObservedObject var store: AnkiStore
    let cardID: Int64

    @Environment(\.dismiss) private var dismiss
    @State private var info: CardInfo?
    @State private var phase: Phase = .loading

    private enum Phase: Equatable {
        case loading
        case loaded
        case failed(String)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                DS.background.ignoresSafeArea()
                content
            }
            .navigationTitle("Card Info")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task { await load() }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .loading:
            VStack(spacing: DS.Spacing.m) {
                ProgressView()
                Text("Loading card info…")
                    .font(DS.Typography.caption)
                    .foregroundStyle(DS.textSecondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            failed(message)
        case .loaded:
            if let info {
                ScrollView {
                    VStack(spacing: DS.Spacing.l) {
                        identityCard(info)
                        schedulingCard(info)
                        historyCard(info)
                    }
                    .padding(DS.Spacing.l)
                }
            }
        }
    }

    // MARK: - Cards

    private func identityCard(_ info: CardInfo) -> some View {
        InfoCard(title: "Identity") {
            DSStatRow("Deck", value: info.deck)
            DSStatRow("Note type", value: info.notetype)
            DSStatRow("Card", value: info.cardType.isEmpty ? "—" : info.cardType)
        }
    }

    private func schedulingCard(_ info: CardInfo) -> some View {
        InfoCard(title: "Scheduling") {
            DSStatRow("Added", value: CardInfoFormat.date(info.added))
            DSStatRow("Due", value: dueValue(info))
            DSStatRow("Interval", value: CardInfoFormat.interval(info.intervalDays))
            DSStatRow("Ease", value: CardInfoFormat.ease(info.easePermille))
            if let retr = info.retrievability {
                DSStatRow("Retrievability", value: CardInfoFormat.percent(Double(retr) * 100))
            }
        }
    }

    private func historyCard(_ info: CardInfo) -> some View {
        InfoCard(title: "Review history") {
            DSStatRow("Reviews", value: "\(info.reviews)")
            DSStatRow("Lapses", value: "\(info.lapses)")
            DSStatRow("First review", value: CardInfoFormat.optionalDate(info.firstReview))
            DSStatRow("Latest review", value: CardInfoFormat.optionalDate(info.latestReview))
            DSStatRow("Average time", value: CardInfoFormat.duration(Double(info.averageSecs)))
            DSStatRow("Total time", value: CardInfoFormat.duration(Double(info.totalSecs)))
        }
    }

    /// "Due" is a date for review cards and a queue position for new cards.
    private func dueValue(_ info: CardInfo) -> String {
        if let due = info.dueDate { return CardInfoFormat.date(due) }
        if let pos = info.duePosition { return "New #\(pos)" }
        return "—"
    }

    private func failed(_ message: String) -> some View {
        VStack(spacing: DS.Spacing.m) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 40))
                .foregroundStyle(DS.again)
            Text("Couldn’t load card info")
                .font(DS.Typography.headline)
                .foregroundStyle(DS.textPrimary)
            Text(message)
                .font(DS.Typography.caption)
                .foregroundStyle(DS.textSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(DS.Spacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func load() async {
        phase = .loading
        do {
            info = try await store.cardInfo(cardID: cardID)
            phase = .loaded
        } catch {
            phase = .failed(describe(error))
        }
    }

    private func describe(_ error: Error) -> String {
        if case let AnkiError.backendError(data) = error,
           let backendError = try? Anki_Backend_BackendError(serializedBytes: data),
           !backendError.message.isEmpty {
            return backendError.message
        }
        return error.localizedDescription
    }
}

/// Identifiable wrapper so a Card Info sheet can be driven by `.sheet(item:)`
/// from an optional card id (used by the Reviewer and the screenshot hook).
struct CardInfoTarget: Identifiable {
    let id: Int64
}

/// A titled card grouping `DSStatRow`s, matching the app's surface tokens.
private struct InfoCard<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.m) {
            Text(title)
                .font(DS.Typography.headline)
                .foregroundStyle(DS.textPrimary)
            VStack(spacing: DS.Spacing.s) {
                content
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .dsCard()
    }
}

/// Formatting helpers for the Card Info screen (timestamps, intervals, ease,
/// durations), kept local so the view stays declarative.
private enum CardInfoFormat {
    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()

    /// A Unix-seconds timestamp as a medium date (e.g. "Jun 29, 2026").
    static func date(_ unixSeconds: Int64) -> String {
        guard unixSeconds > 0 else { return "—" }
        return dateFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(unixSeconds)))
    }

    static func optionalDate(_ unixSeconds: Int64?) -> String {
        guard let unixSeconds else { return "Never" }
        return date(unixSeconds)
    }

    /// Interval in days as "N days" (or "—" for new/learning cards).
    static func interval(_ days: UInt32) -> String {
        guard days > 0 else { return "—" }
        return days == 1 ? "1 day" : "\(days) days"
    }

    /// Ease factor in permille shown as a percentage (e.g. 2500 → "250%").
    static func ease(_ permille: UInt32) -> String {
        guard permille > 0 else { return "—" }
        return String(format: "%.0f%%", Double(permille) / 10)
    }

    static func percent(_ value: Double) -> String {
        String(format: "%.0f%%", value)
    }

    /// Seconds as "45s" / "2m" / "1h 4m"; "—" when there's no recorded time.
    static func duration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        guard total > 0 else { return "—" }
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
