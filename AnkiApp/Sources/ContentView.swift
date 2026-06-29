import SwiftUI
import AnkiKit

struct ContentView: View {
    @StateObject private var store = AnkiStore()
    @State private var goReview = false

    var body: some View {
        NavigationStack {
            List {
                Section("Shared Anki engine") {
                    LabeledContent("Build hash", value: store.buildHash.isEmpty ? "—" : store.buildHash)
                    LabeledContent("Status", value: store.status)
                }
                Section("Decks (from the Rust core)") {
                    if store.deckNames.isEmpty {
                        Text("No decks yet").foregroundStyle(.secondary)
                    } else {
                        ForEach(store.deckNames, id: \.self) { Text($0) }
                    }
                }
                Section("Today") {
                    LabeledContent("New", value: "\(store.newCount)")
                    LabeledContent("Learning", value: "\(store.learningCount)")
                    LabeledContent("Review", value: "\(store.reviewCount)")
                    Button { goReview = true } label: {
                        Label("Study", systemImage: "play.fill")
                    }
                }
            }
            .navigationTitle("Anki Speedrun")
            .navigationDestination(isPresented: $goReview) {
                ReviewerView(store: store)
            }
        }
        .task {
            store.boot()
            if ProcessInfo.processInfo.arguments.contains("-startInReview") {
                goReview = true
            }
        }
    }
}
