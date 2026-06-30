import SwiftUI
import WebKit
import UniformTypeIdentifiers
import AnkiKit

/// Serves `<img src="...">` (and other media) from the collection's media
/// folder over a custom URL scheme, mirroring how AnkiDroid serves card assets
/// from `file:///android_asset`. A custom scheme handler is the robust option on
/// iOS 16: `loadHTMLString` cannot grant a WebView file-read access to an
/// arbitrary directory, but a registered scheme handler can stream any file.
final class MediaSchemeHandler: NSObject, WKURLSchemeHandler {
    /// Custom scheme (must not be a built-in like `file`/`http`).
    static let scheme = "ankimedia"
    /// Document base; relative media URLs resolve against this and route here.
    static let baseURL = URL(string: "\(scheme)://card/")!

    private let mediaFolder: URL

    init(mediaFolder: URL) {
        self.mediaFolder = mediaFolder.standardizedFileURL
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url else {
            urlSchemeTask.didFailWithError(URLError(.badURL))
            return
        }

        // Map the request path to a file inside the media folder. `url.path` is
        // percent-decoded, turning the engine's `foo%20bar.jpg` back into the
        // real filename. Reject anything that escapes the media folder.
        let relativePath = url.path.hasPrefix("/") ? String(url.path.dropFirst()) : url.path
        let fileURL = mediaFolder.appendingPathComponent(relativePath).standardizedFileURL
        guard fileURL.path == mediaFolder.path || fileURL.path.hasPrefix(mediaFolder.path + "/"),
              let data = try? Data(contentsOf: fileURL) else {
            urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
            return
        }

        let mimeType = Self.mimeType(forExtension: fileURL.pathExtension)
        let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": mimeType, "Content-Length": "\(data.count)"]
        )!
        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(data)
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}

    private static func mimeType(forExtension ext: String) -> String {
        if let type = UTType(filenameExtension: ext), let mime = type.preferredMIMEType {
            return mime
        }
        return "application/octet-stream"
    }
}

/// Renders engine-produced card HTML in a WKWebView, styled with the card's
/// notetype CSS so it looks like a real Anki card.
struct CardWebView: UIViewRepresentable {
    /// Rendered question or answer HTML.
    let html: String
    /// Notetype CSS (`RenderCardResponse.css` == `notetype.config.css`).
    let css: String
    /// Card template ordinal, for the `cardN` class (matches Anki's `card card1`).
    let ordinal: Int
    /// Whether to apply Anki's night-mode classes.
    let isDark: Bool
    /// Media folder for `<img>` resolution.
    let mediaFolder: URL

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(
            MediaSchemeHandler(mediaFolder: mediaFolder),
            forURLScheme: MediaSchemeHandler.scheme
        )
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        let document = Self.makeDocument(html: html, css: css, ordinal: ordinal, isDark: isDark)
        // Only reload when the rendered document actually changes; SwiftUI calls
        // this on unrelated state updates (e.g. the undo button) and reloading
        // every time would flicker the card.
        guard context.coordinator.lastDocument != document else { return }
        context.coordinator.lastDocument = document
        webView.loadHTMLString(document, baseURL: MediaSchemeHandler.baseURL)
    }

    final class Coordinator {
        var lastDocument: String?
    }

    /// Wraps the rendered HTML in `<div class="card cardN">` and injects the
    /// notetype CSS, mirroring Anki's reviewer (desktop builds the body class
    /// `card card{ord+1} nightMode`; AnkiDroid does the same via `getCardClass`).
    static func makeDocument(html: String, css: String, ordinal: Int, isDark: Bool) -> String {
        // Anki applies both `nightMode` (desktop) and `night_mode` (AnkiDroid).
        let nightClasses = isDark ? " nightMode night_mode" : ""
        let cardClasses = "card card\(ordinal + 1)\(nightClasses)"
        return """
        <!doctype html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no">
        <style>
          html, body { margin: 0; padding: 0; }
          body {
            -webkit-text-size-adjust: 100%;
            min-height: 100vh;
            display: flex;
            flex-direction: column;
            justify-content: center;
            overflow-wrap: break-word;
          }
          .card { padding: 28px; }
          /* Keep media within the viewport (cf. AnkiDroid flashcard.css). */
          img, video { max-width: 100%; height: auto; }
          /* Night-mode fallback so default notetypes stay legible in the dark.
             Mirrors desktop reviewer.scss overriding the default `.card`; placed
             before the notetype CSS so a notetype's own night styling wins. */
          .card.nightMode { color: #f3f4f6; background-color: transparent; }
        </style>
        <style>
        \(css)
        </style>
        </head>
        <body class="\(isDark ? "nightMode night_mode" : "")">
        <div class="\(cardClasses)">\(html)</div>
        </body>
        </html>
        """
    }
}

struct ReviewerView: View {
    @ObservedObject var store: AnkiStore
    @Environment(\.colorScheme) private var colorScheme
    @State private var infoCardID: Int64?

    var body: some View {
        VStack(spacing: 0) {
            if store.weakTopicsMode {
                WeakTopicsReviewBanner(topic: store.currentCardTopic)
            }
            if store.reviewDone {
                VStack(spacing: 12) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 56)).foregroundStyle(.green)
                    Text("All caught up").font(.title2.bold())
                    Text("No more cards due in this deck.").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                CardWebView(
                    html: store.showingAnswer ? store.currentAnswer : store.currentQuestion,
                    css: store.currentCSS,
                    ordinal: store.currentOrdinal,
                    isDark: colorScheme == .dark,
                    mediaFolder: store.mediaFolderURL
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                if store.showingAnswer {
                    HStack(spacing: DS.Spacing.s) {
                        rateButton("Again", index: 0, rating: .again, color: DS.again)
                        rateButton("Hard", index: 1, rating: .hard, color: DS.hard)
                        rateButton("Good", index: 2, rating: .good, color: DS.good)
                        rateButton("Easy", index: 3, rating: .easy, color: DS.easy)
                    }
                    .padding()
                } else {
                    Button(action: store.reveal) {
                        Text("Show Answer").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.dsPrimary)
                    .padding()
                }
            }
        }
        .navigationTitle(store.weakTopicsMode ? "Weak Topics" : "Review")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    infoCardID = store.currentCardID
                } label: {
                    Label("Card Info", systemImage: "info.circle")
                }
                .disabled(store.currentCardID == nil || store.reviewDone)
                .accessibilityLabel("Card info")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: store.undo) {
                    Label("Undo", systemImage: "arrow.uturn.backward")
                }
                .disabled(!store.canUndo)
                .accessibilityLabel(store.undoName.isEmpty ? "Undo" : "Undo \(store.undoName)")
            }
        }
        .sheet(item: infoSheetBinding) { target in
            CardInfoView(store: store, cardID: target.id)
        }
        .onAppear { store.startReview() }
    }

    /// Drives the Card Info sheet from the optional card id (wrapped so
    /// `.sheet(item:)` can present it).
    private var infoSheetBinding: Binding<CardInfoTarget?> {
        Binding(
            get: { infoCardID.map(CardInfoTarget.init) },
            set: { if $0 == nil { infoCardID = nil } }
        )
    }

    /// One answer button: the projected interval (smaller) above the ease name,
    /// matching AnkiDroid's `AnswerButton` (interval at 0.8× over the label).
    private func rateButton(_ label: String,
                            index: Int,
                            rating: Anki_Scheduler_CardAnswer.Rating,
                            color: Color) -> some View {
        Button { store.rate(rating) } label: {
            VStack(spacing: 2) {
                if index < store.currentIntervals.count, !store.currentIntervals[index].isEmpty {
                    Text(store.currentIntervals[index])
                        .font(DS.Typography.caption)
                        .monospacedDigit()
                        .opacity(0.9)
                }
                Text(label)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.dsRating(color))
        .accessibilityLabel(intervalAccessibilityLabel(label, index: index))
    }

    /// "Good, interval 1d" so the projected interval is announced too.
    private func intervalAccessibilityLabel(_ label: String, index: Int) -> String {
        guard index < store.currentIntervals.count, !store.currentIntervals[index].isEmpty else {
            return label
        }
        return "\(label), interval \(store.currentIntervals[index])"
    }
}

/// A slim header shown while studying in "Focus weak topics" mode, making the
/// points-at-stake ordering visible: it names the mode and the current card's
/// topic so the weakest-first progression is legible during review.
private struct WeakTopicsReviewBanner: View {
    let topic: String?

    var body: some View {
        HStack(spacing: DS.Spacing.s) {
            Image(systemName: "scope")
                .font(.caption.weight(.semibold))
                .foregroundStyle(DS.accent)
            Text("Weak topics first")
                .font(DS.Typography.caption.weight(.semibold))
                .foregroundStyle(DS.textPrimary)
            if let topic, !topic.isEmpty {
                Text("·")
                    .font(DS.Typography.caption)
                    .foregroundStyle(DS.textSecondary)
                Text(topic)
                    .font(DS.Typography.caption.weight(.semibold))
                    .foregroundStyle(DS.accent)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, DS.Spacing.l)
        .padding(.vertical, DS.Spacing.s)
        .frame(maxWidth: .infinity)
        .background(DS.accent.opacity(0.12))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(topic.map { "Weak topics first, current topic \($0)" } ?? "Weak topics first")
    }
}
