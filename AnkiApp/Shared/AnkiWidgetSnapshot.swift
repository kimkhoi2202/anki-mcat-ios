import Foundation

/// Constants shared by the app and its WidgetKit extension. Both targets declare
/// the matching `com.apple.security.application-groups` entitlement (see
/// `AnkiSpeedrun.entitlements` / `AnkiWidget/AnkiWidget.entitlements`) so they
/// read and write the same `UserDefaults` suite. This is the same mechanism
/// AnkiDroid uses to feed its home-screen due-count widget from the collection.
enum AnkiWidgetShared {
    /// App Group identifier. MUST match the entitlement in both targets and is
    /// derived from the app bundle id `com.khoilam.ankispeedrun`.
    static let appGroupID = "group.com.khoilam.ankispeedrun"

    /// Key under which the encoded `AnkiWidgetSnapshot` lives in the shared suite.
    static let snapshotKey = "ankiDueSnapshot"

    /// Custom URL scheme the widget deep-links into (registered in the app's
    /// Info.plist `CFBundleURLTypes`). Tapping the widget opens the app to study.
    static let urlScheme = "ankispeedrun"

    /// The widget's tap target: open the app and start studying.
    static let studyURL = URL(string: "\(urlScheme)://study")!

    /// The shared defaults suite, or nil if the App Group is unavailable (e.g.
    /// the entitlement is missing because the build has no provisioning). Callers
    /// treat nil as "no shared storage" and degrade gracefully rather than crash.
    ///
    /// We gate on the App Group *container* actually existing rather than blindly
    /// constructing `UserDefaults(suiteName:)`. On a physical device whose
    /// provisioning profile doesn't include the App Group entitlement (common
    /// with manual/free signing that never registered the group), the container
    /// is absent; touching the suite anyway makes `cfprefsd` log "Using
    /// kCFPreferencesAnyUser with a container is only allowed for System
    /// Containers, detaching from cfprefsd" and can destabilize the app's *other*
    /// UserDefaults reads (e.g. the sync-server preference read moments later at
    /// boot). Returning nil keeps the app off that broken suite entirely.
    static var sharedDefaults: UserDefaults? {
        guard FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupID) != nil
        else { return nil }
        return UserDefaults(suiteName: appGroupID)
    }
}

/// One top-level deck's due breakdown, mirroring the new/learning/review numbers
/// AnkiDroid's DeckPicker widget shows per deck.
struct AnkiWidgetDeckDue: Codable, Hashable {
    let name: String
    let new: Int
    let learn: Int
    let review: Int

    var total: Int { new + learn + review }
}

/// A tiny snapshot of today's study load. The app writes it after every deck
/// refresh; the widget's timeline provider reads it. Kept deliberately small (a
/// few Ints, short strings, one date) so it fits comfortably in the shared
/// `UserDefaults` suite.
struct AnkiWidgetSnapshot: Codable, Hashable {
    /// Aggregate counts across all top-level decks (Anki folds subdeck counts
    /// into their top-level parent already).
    let totalNew: Int
    let totalLearn: Int
    let totalReview: Int

    /// A handful of top-level decks with cards ready to study, most-loaded
    /// first, for the medium widget's per-deck rows.
    let decks: [AnkiWidgetDeckDue]

    /// When the app last wrote this snapshot (shown as a relative "updated"
    /// stamp so a stale widget is visibly stale rather than silently wrong).
    let updatedAt: Date

    /// Total cards ready to study right now.
    var totalDue: Int { totalNew + totalLearn + totalReview }

    /// Placeholder used before the app has ever written a snapshot, and as the
    /// safe fallback when the shared suite is missing or the data won't decode.
    static let empty = AnkiWidgetSnapshot(
        totalNew: 0, totalLearn: 0, totalReview: 0, decks: [], updatedAt: .distantPast
    )

    /// A representative sample for the widget gallery / Xcode previews.
    static let sample = AnkiWidgetSnapshot(
        totalNew: 12,
        totalLearn: 3,
        totalReview: 47,
        decks: [
            AnkiWidgetDeckDue(name: "Spanish", new: 8, learn: 2, review: 30),
            AnkiWidgetDeckDue(name: "Chemistry", new: 4, learn: 1, review: 12),
            AnkiWidgetDeckDue(name: "Capitals", new: 0, learn: 0, review: 5),
        ],
        updatedAt: Date()
    )
}

extension AnkiWidgetSnapshot {
    /// The most recent snapshot the app wrote, or `.empty` if none exists / the
    /// App Group suite is unavailable / the stored data can't be decoded.
    static func load() -> AnkiWidgetSnapshot {
        guard let defaults = AnkiWidgetShared.sharedDefaults,
              let data = defaults.data(forKey: AnkiWidgetShared.snapshotKey),
              let snapshot = try? JSONDecoder().decode(AnkiWidgetSnapshot.self, from: data)
        else { return .empty }
        return snapshot
    }

    /// Persist this snapshot to the shared suite. A no-op when the App Group is
    /// unavailable, so the app never crashes if the entitlement is absent.
    func save() {
        guard let defaults = AnkiWidgetShared.sharedDefaults,
              let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: AnkiWidgetShared.snapshotKey)
    }
}
