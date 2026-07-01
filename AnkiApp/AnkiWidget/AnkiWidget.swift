import WidgetKit
import SwiftUI
import UIKit

// MARK: - AnkiDroid due-count palette
//
// AnkiDroid (and Anki desktop) color the three deck counts consistently:
// new = blue, learning = red, review = green. The widget reuses that palette so
// the numbers read the same as in the app / on Android.

private enum DueColor {
    static let new = Color(red: 0x21 / 255, green: 0x96 / 255, blue: 0xF3 / 255)     // blue
    static let learn = Color(red: 0xF4 / 255, green: 0x43 / 255, blue: 0x36 / 255)   // red
    static let review = Color(red: 0x4C / 255, green: 0xAF / 255, blue: 0x50 / 255)   // green
}

// MARK: - Timeline

/// One rendered moment for the widget: the study snapshot the app last wrote.
struct AnkiDueEntry: TimelineEntry {
    let date: Date
    let snapshot: AnkiWidgetSnapshot
}

/// Feeds the widget from the shared App-Group snapshot. The app calls
/// `WidgetCenter.shared.reloadAllTimelines()` after every deck refresh, so this
/// provider mostly just reads the latest snapshot; the hourly refresh policy is
/// a safety net for when the app hasn't run in a while.
struct AnkiDueProvider: TimelineProvider {
    func placeholder(in context: Context) -> AnkiDueEntry {
        AnkiDueEntry(date: Date(), snapshot: .sample)
    }

    func getSnapshot(in context: Context, completion: @escaping (AnkiDueEntry) -> Void) {
        let snapshot = context.isPreview ? AnkiWidgetSnapshot.sample : AnkiWidgetSnapshot.load()
        completion(AnkiDueEntry(date: Date(), snapshot: snapshot))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<AnkiDueEntry>) -> Void) {
        let now = Date()
        let entry = AnkiDueEntry(date: now, snapshot: AnkiWidgetSnapshot.load())
        let next = Calendar.current.date(byAdding: .hour, value: 1, to: now)
            ?? now.addingTimeInterval(3600)
        completion(Timeline(entries: [entry], policy: .after(next)))
    }
}

// MARK: - Shared pieces

/// A single colored count "pill" (e.g. the blue new count). Hidden entirely
/// when the count is zero so the widget only shows what's actually due, matching
/// how AnkiDroid dims empty counts.
private struct CountPill: View {
    let value: Int
    let color: Color

    var body: some View {
        Text("\(value)")
            .font(.caption.weight(.bold))
            .monospacedDigit()
            .foregroundStyle(color)
    }
}

/// The new / learn / review triple, laid out horizontally. Zero counts are
/// omitted; if everything is zero a single muted "0" is shown.
private struct CountsRow: View {
    let new: Int
    let learn: Int
    let review: Int

    var body: some View {
        HStack(spacing: 6) {
            if new > 0 { CountPill(value: new, color: DueColor.new) }
            if learn > 0 { CountPill(value: learn, color: DueColor.learn) }
            if review > 0 { CountPill(value: review, color: DueColor.review) }
            if new == 0 && learn == 0 && review == 0 {
                Text("0").font(.caption.weight(.bold)).foregroundStyle(.secondary)
            }
        }
    }
}

private extension View {
    /// Applies the widget container background, falling back to a plain
    /// background on iOS 16 (which predates `containerBackground`).
    @ViewBuilder
    func dueWidgetBackground(_ style: some ShapeStyle) -> some View {
        if #available(iOS 17.0, *) {
            containerBackground(style, for: .widget)
        } else {
            background(style)
        }
    }
}

// MARK: - Small widget

/// Small family: the total due count front-and-center with a colored
/// new/learn/review breakdown beneath.
private struct SmallDueView: View {
    let snapshot: AnkiWidgetSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: "rectangle.on.rectangle.angled")
                    .font(.caption2)
                Text("Due today")
                    .font(.caption2.weight(.semibold))
            }
            .foregroundStyle(.secondary)

            Spacer(minLength: 0)

            Text("\(snapshot.totalDue)")
                .font(.system(size: 44, weight: .heavy, design: .rounded))
                .monospacedDigit()
                .minimumScaleFactor(0.5)
                .foregroundStyle(snapshot.totalDue > 0 ? .primary : Color.secondary)

            Text(snapshot.totalDue == 1 ? "card" : "cards")
                .font(.caption2)
                .foregroundStyle(.secondary)

            Spacer(minLength: 0)

            CountsRow(new: snapshot.totalNew, learn: snapshot.totalLearn, review: snapshot.totalReview)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .dueWidgetBackground(Color(.secondarySystemBackground))
    }
}

// MARK: - Medium widget

/// Medium family: the total on the left, per-top-deck rows on the right (or the
/// aggregate breakdown when no deck is ready). Mirrors AnkiDroid's DeckPicker
/// widget listing decks with their colored counts.
private struct MediumDueView: View {
    let snapshot: AnkiWidgetSnapshot

    private var hasData: Bool { snapshot.updatedAt != .distantPast }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            // Total block
            VStack(alignment: .leading, spacing: 2) {
                Text("Anki")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text("\(snapshot.totalDue)")
                    .font(.system(size: 46, weight: .heavy, design: .rounded))
                    .monospacedDigit()
                    .minimumScaleFactor(0.5)
                    .foregroundStyle(snapshot.totalDue > 0 ? .primary : Color.secondary)
                Text(snapshot.totalDue == 1 ? "card due" : "cards due")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                CountsRow(new: snapshot.totalNew, learn: snapshot.totalLearn, review: snapshot.totalReview)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Per-deck rows
            VStack(alignment: .leading, spacing: 6) {
                if snapshot.decks.isEmpty {
                    Spacer(minLength: 0)
                    Text(hasData ? "All caught up 🎉" : "Open Anki to sync")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                } else {
                    ForEach(snapshot.decks.prefix(4), id: \.name) { deck in
                        HStack(spacing: 6) {
                            Text(deck.name)
                                .font(.caption.weight(.medium))
                                .lineLimit(1)
                                .truncationMode(.tail)
                            Spacer(minLength: 4)
                            CountsRow(new: deck.new, learn: deck.learn, review: deck.review)
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .dueWidgetBackground(Color(.secondarySystemBackground))
    }
}

// MARK: - Entry view + widget

struct AnkiDueWidgetEntryView: View {
    @Environment(\.widgetFamily) private var family
    let entry: AnkiDueEntry

    var body: some View {
        switch family {
        case .systemSmall:
            SmallDueView(snapshot: entry.snapshot)
        default:
            MediumDueView(snapshot: entry.snapshot)
        }
    }
}

/// The due-count widget. Tapping it deep-links into the app via
/// `ankispeedrun://study` to start studying.
struct AnkiDueWidget: Widget {
    let kind = "AnkiDueWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: AnkiDueProvider()) { entry in
            AnkiDueWidgetEntryView(entry: entry)
                .widgetURL(AnkiWidgetShared.studyURL)
        }
        .configurationDisplayName("Anki Due")
        .description("Today's cards to study, by deck.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

@main
struct AnkiWidgetBundle: WidgetBundle {
    var body: some Widget {
        AnkiDueWidget()
    }
}
