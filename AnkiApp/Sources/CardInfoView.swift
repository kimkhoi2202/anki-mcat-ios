import SwiftUI
import AnkiKit

/// Card Info — Anki's real `card-info` web page in a WebView, exactly as
/// AnkiDroid/desktop render it (the full scalar table plus the revlog history
/// and, under FSRS, the forgetting-curve graph). Backed by our engine through
/// ``AnkiWebPage``. Presented as a sheet from the Card Browser and the Reviewer.
@MainActor
struct CardInfoView: View {
    @ObservedObject var store: AnkiStore
    let cardID: Int64

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        NavigationStack {
            Group {
                if let backend = store.sharedBackend {
                    AnkiWebPage(
                        pagePath: "card-info/\(cardID)",
                        backend: backend,
                        nightMode: colorScheme == .dark
                    )
                    .ignoresSafeArea(edges: .bottom)
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(DS.background)
                }
            }
            .navigationTitle(Loc.tr("actions-card-info"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

/// Identifiable wrapper so a Card Info sheet can be driven by `.sheet(item:)`
/// from an optional card id (used by the Reviewer and the screenshot hook).
struct CardInfoTarget: Identifiable {
    let id: Int64
}
