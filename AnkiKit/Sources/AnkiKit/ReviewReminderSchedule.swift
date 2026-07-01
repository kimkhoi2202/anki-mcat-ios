import Foundation

/// Pure scheduling logic for the daily review reminder (AnkiDroid's "Notify
/// when new cards/reviews are due" / review reminder). Kept dependency-free and
/// separate from the `UNUserNotificationCenter` glue (in the app's
/// `ReviewReminders`) so the date/body computation is unit-testable without the
/// notification framework or a device.
public enum ReviewReminderSchedule {
    /// The daily reminder hour Anki defaults to when none is set (8 PM), matching
    /// AnkiDroid's default reminder time.
    public static let defaultHour = 20
    public static let defaultMinute = 0

    /// The hour/minute `DateComponents` that drive a repeating daily
    /// `UNCalendarNotificationTrigger`. The values are clamped to valid ranges so
    /// a bad stored value can never produce an invalid trigger.
    public static func dateComponents(hour: Int, minute: Int) -> DateComponents {
        var components = DateComponents()
        components.hour = clamp(hour, 0, 23)
        components.minute = clamp(minute, 0, 59)
        return components
    }

    /// The next wall-clock time the reminder would fire at or after `date`, for
    /// the given hour/minute. Used to preview the schedule and to unit-test the
    /// "next reminder" computation. Returns nil only if the calendar can't
    /// resolve a match (never in practice).
    public static func nextFireDate(
        after date: Date, hour: Int, minute: Int, calendar: Calendar = .current
    ) -> Date? {
        calendar.nextDate(
            after: date,
            matching: dateComponents(hour: hour, minute: minute),
            matchingPolicy: .nextTime
        )
    }

    /// The notification body. With a known due count it reads like AnkiDroid's
    /// reminder ("You have N cards due"); otherwise it falls back to a generic
    /// prompt so a missing/zero count never shows "0 cards due".
    public static func body(dueCount: Int?) -> String {
        guard let count = dueCount, count > 0 else { return "Time to study!" }
        return count == 1 ? "You have 1 card due" : "You have \(count) cards due"
    }

    private static func clamp(_ value: Int, _ low: Int, _ high: Int) -> Int {
        min(max(value, low), high)
    }
}
