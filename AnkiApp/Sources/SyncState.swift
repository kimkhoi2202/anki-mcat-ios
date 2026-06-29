import Foundation

/// UI-facing phase of a sync run, driving the Home screen's progress banner.
///
/// Mirrors the user-visible states AnkiDroid surfaces during `handleNewSync`:
/// an indeterminate collection-sync spinner, a media-sync phase with live
/// added/removed/checked counts (`monitorMediaSync`), and terminal
/// success/error states.
enum SyncPhase: Equatable {
    case idle
    /// Normal collection sync in progress (indeterminate).
    case syncing(String)
    /// Media sync in progress, with a short progress description.
    case mediaSyncing(String)
    /// Sync finished successfully; carries a message to show briefly.
    case success(String)
    /// Sync failed; carries the classified failure for tailored handling.
    case failed(SyncFailure)

    /// Whether a sync is actively running (used to disable the Sync button and
    /// show a spinner).
    var isActive: Bool {
        switch self {
        case .syncing, .mediaSyncing: return true
        case .idle, .success, .failed: return false
        }
    }
}

/// A terminal sync failure, classified so the UI can react (e.g. re-prompt for
/// login on auth failure) and show an appropriate message.
struct SyncFailure: Equatable {
    enum Kind: Equatable {
        case auth
        case network
        case server
        case other
    }
    var kind: Kind
    var message: String
}
