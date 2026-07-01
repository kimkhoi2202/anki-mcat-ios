import Foundation
import UserNotifications
import AnkiKit

/// Schedules the daily review reminder — a repeating local notification cloning
/// AnkiDroid's review reminder ("Notify at a set time each day"). The pure
/// date/body logic lives in `AnkiKit.ReviewReminderSchedule`; this actor-hopping
/// wrapper owns the `UNUserNotificationCenter` glue (authorization + scheduling)
/// and is deliberately crash-proof: every notification-center call is guarded so
/// a permission or scheduling failure can never block or crash Settings.
///
/// Persistence keys are shared with `SettingsView` (`@AppStorage`) and read by
/// `AnkiStore` when it reschedules with a fresh due count, so the enable/time
/// live in one place.
@MainActor
final class ReviewReminders {
    /// `UserDefaults`/`@AppStorage` keys for the enable flag and daily time.
    static let enabledKey = "reviewReminderEnabled"
    static let hourKey = "reviewReminderHour"
    static let minuteKey = "reviewReminderMinute"

    /// Stable identifier for the single repeating request, so rescheduling
    /// replaces (rather than stacks) the pending reminder.
    static let requestIdentifier = "com.khoilam.ankispeedrun.reviewReminder"

    private let center: UNUserNotificationCenter

    /// `.current()` is unavailable in unit tests / previews (no bundle), so the
    /// center is injectable and the initializer degrades gracefully.
    init(center: UNUserNotificationCenter? = nil) {
        self.center = center ?? .current()
    }

    /// Requests alert+sound+badge authorization, returning whether it was
    /// granted. A thrown error (e.g. no notification entitlement) is treated as
    /// "not granted" rather than propagating.
    func requestAuthorization() async -> Bool {
        do {
            return try await center.requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            return false
        }
    }

    /// The current system authorization status (used on appear to reconcile the
    /// toggle if the user revoked permission in iOS Settings).
    func authorizationStatus() async -> UNAuthorizationStatus {
        await center.notificationSettings().authorizationStatus
    }

    /// (Re)schedules the repeating daily reminder at `hour:minute`, replacing any
    /// existing one. `dueCount`, when known, personalizes the body ("You have N
    /// cards due"); nil falls back to a generic prompt. Never throws.
    func schedule(hour: Int, minute: Int, dueCount: Int?) async {
        cancel()
        let content = UNMutableNotificationContent()
        content.title = "Anki Speedrun"
        content.body = ReviewReminderSchedule.body(dueCount: dueCount)
        content.sound = .default

        let trigger = UNCalendarNotificationTrigger(
            dateMatching: ReviewReminderSchedule.dateComponents(hour: hour, minute: minute),
            repeats: true
        )
        let request = UNNotificationRequest(
            identifier: Self.requestIdentifier, content: content, trigger: trigger
        )
        // Swallow scheduling failures: a reminder that can't be scheduled must
        // never surface as an error in Settings.
        try? await center.add(request)
    }

    /// Removes the pending daily reminder (on disable).
    func cancel() {
        center.removePendingNotificationRequests(withIdentifiers: [Self.requestIdentifier])
    }
}
