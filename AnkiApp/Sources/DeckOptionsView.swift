import SwiftUI
import AnkiKit

/// Deck Options — Anki's real `deck-options` web page in a WebView, exactly as
/// AnkiDroid/desktop render it: presets, daily limits, new-cards, lapses, display
/// order, FSRS, burying, timer, auto-advance, advanced — the full page, backed by
/// our engine through ``AnkiWebPage``.
///
/// The page hosts its own Save button, which calls `updateDeckConfigs` (a backend
/// RPC that performs the save) and then `deckOptionsRequireClose`; we map the
/// latter to `onClose` to refresh and dismiss.
@MainActor
struct DeckOptionsView: View {
    @ObservedObject var store: AnkiStore
    let deck: DeckTreeEntry
    /// Invoked after the page saves so the presenting screen can refresh.
    var onSaved: () -> Void = {}

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        NavigationStack {
            Group {
                if let backend = store.sharedBackend {
                    AnkiWebPage(
                        pagePath: "deck-options/\(deck.id)",
                        backend: backend,
                        nightMode: colorScheme == .dark,
                        onClose: {
                            onSaved()
                            dismiss()
                        }
                    )
                    .ignoresSafeArea(edges: .bottom)
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(DS.background)
                }
            }
            .navigationTitle(deck.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }
}
