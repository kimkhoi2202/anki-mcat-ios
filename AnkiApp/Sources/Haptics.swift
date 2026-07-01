import UIKit

/// Central, deliberately restrained haptic feedback for the app.
///
/// Haptics are used as *confirmation of meaningful state changes*, not
/// decoration: a light tick for the high-frequency review loop (grading), a
/// gentler tap for the card flip, discrete selection ticks for mark/flag
/// toggles, and richer notification feedback for the rare rewarding or
/// attention-worthy moments (deck finished, save, delete, sync result, errors).
///
/// Everything routes through here so the feel stays consistent and is trivially
/// switched off. Respects the in-app "Haptic feedback" setting (default on) and,
/// underneath, the system Settings ▸ Sounds & Haptics toggle — `UIFeedbackGenerator`
/// no-ops when the user has disabled system haptics or the device has no Taptic
/// Engine. `@MainActor` because the generators are main-thread only.
@MainActor
enum Haptics {
    /// `UserDefaults`/`@AppStorage` key for the in-app toggle (default: on).
    static let enabledKey = "hapticsEnabled"

    /// Reads the in-app preference, defaulting to enabled when unset (so haptics
    /// are on out of the box).
    private static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }

    // Reused generators (Apple recommends keeping instances around; `prepare()`
    // warms the engine so the next tick has minimal latency).
    private static let lightGenerator = UIImpactFeedbackGenerator(style: .light)
    private static let softGenerator = UIImpactFeedbackGenerator(style: .soft)
    private static let selectionGenerator = UISelectionFeedbackGenerator()
    private static let notificationGenerator = UINotificationFeedbackGenerator()

    // MARK: - Semantic feedback

    /// The review loop's grade confirmation: a subtle, crisp tick. Kept light and
    /// slightly under full intensity because it fires hundreds of times a session.
    static func grade() { fire { lightGenerator.impactOccurred(intensity: 0.8) } }

    /// The card flip / reveal: a gentle, diffuse tap, distinct from the grade tick.
    static func flip() { fire { softGenerator.impactOccurred(intensity: 0.7) } }

    /// A generic light confirmation for reversible actions (undo, bury, suspend,
    /// applying a bulk change).
    static func tap() { fire { lightGenerator.impactOccurred() } }

    /// A discrete selection change (mark / flag toggles, segmented switches).
    static func selection() { fire { selectionGenerator.selectionChanged() } }

    /// A rewarding or completed moment: deck finished, note saved, sync complete.
    static func success() { fire { notificationGenerator.notificationOccurred(.success) } }

    /// A consequential action worth a beat of attention: delete.
    static func warning() { fire { notificationGenerator.notificationOccurred(.warning) } }

    /// Something went wrong: a failed answer, sync error, or bulk-action failure.
    static func error() { fire { notificationGenerator.notificationOccurred(.error) } }

    /// Warms up the impact engine (call when the reviewer/a card appears) so the
    /// first grade tick fires without the initial engine spin-up latency.
    static func prepare() {
        guard isEnabled else { return }
        lightGenerator.prepare()
        softGenerator.prepare()
    }

    private static func fire(_ action: () -> Void) {
        guard isEnabled else { return }
        action()
    }
}
