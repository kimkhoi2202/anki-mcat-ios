import SwiftUI
import AnkiKit

/// Statistics screen — Anki's real graphs page (`graphs`) rendered in a WebView,
/// exactly as AnkiDroid and desktop Anki do. The SvelteKit page is bundled and
/// served locally, and its `/_anki` calls run against our Rust engine, so all 14
/// graphs, the deck/search scope, and per-graph controls come for free and stay
/// in lockstep with the engine (see ``AnkiWebPage``).
struct StatsView: View {
    @ObservedObject var store: AnkiStore
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Group {
            if let backend = store.sharedBackend {
                AnkiWebPage(pagePath: "graphs", backend: backend, nightMode: colorScheme == .dark)
                    .ignoresSafeArea(edges: .bottom)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(DS.background)
            }
        }
        .navigationTitle(Loc.tr("statistics-title"))
        .navigationBarTitleDisplayMode(.inline)
    }
}
