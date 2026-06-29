import SwiftUI
import WebKit
import AnkiKit

/// Renders engine-produced card HTML in a WKWebView.
struct CardWebView: UIViewRepresentable {
    let html: String

    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView()
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        let document = """
        <!doctype html><html><head>
        <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1">
        <style>
          :root { color-scheme: light dark; }
          body { font-family: -apple-system, system-ui, sans-serif; font-size: 22px;
                 line-height: 1.4; margin: 0; padding: 28px; text-align: center;
                 display: flex; min-height: 100vh; align-items: center; justify-content: center; }
          .card { width: 100%; }
        </style>
        </head><body><div class="card">\(html)</div></body></html>
        """
        webView.loadHTMLString(document, baseURL: nil)
    }
}

struct ReviewerView: View {
    @ObservedObject var store: AnkiStore

    var body: some View {
        VStack(spacing: 0) {
            if store.reviewDone {
                VStack(spacing: 12) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 56)).foregroundStyle(.green)
                    Text("All caught up").font(.title2.bold())
                    Text("No more cards due in this deck.").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                CardWebView(html: store.showingAnswer ? store.currentAnswer : store.currentQuestion)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                if store.showingAnswer {
                    HStack(spacing: 8) {
                        rateButton("Again", .again, .red)
                        rateButton("Hard", .hard, .orange)
                        rateButton("Good", .good, .blue)
                        rateButton("Easy", .easy, .green)
                    }
                    .padding()
                } else {
                    Button(action: store.reveal) {
                        Text("Show Answer").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .padding()
                }
            }
        }
        .navigationTitle("Review")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { store.startReview() }
    }

    private func rateButton(_ label: String,
                            _ rating: Anki_Scheduler_CardAnswer.Rating,
                            _ color: Color) -> some View {
        Button { store.rate(rating) } label: {
            Text(label).frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .tint(color)
    }
}
