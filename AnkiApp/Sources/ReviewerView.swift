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

/// A swipe direction over the card, used by the reviewer's grading gestures.
enum SwipeDirection {
    case left, right, up, down
}

/// Lets the reviewer's tap/swipe recognizers fire alongside the WebView's own
/// scrolling and link handling, rather than the scroll view forcing them to
/// fail. Kept as a tiny standalone delegate so it stays free of actor isolation.
private final class CardGestureDelegate: NSObject, UIGestureRecognizerDelegate {
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool { true }
}

/// Renders engine-produced card HTML in a WKWebView, styled with the card's
/// notetype CSS so it looks like a real Anki card.
///
/// Tap and swipe recognizers are attached to the web view's scroll view (not an
/// overlay) so the card still scrolls and its links/buttons keep working, while
/// the reviewer can map taps and swipes to actions — the same separation
/// AnkiDroid uses (`ankidroid-reviewer.js` reporting gestures from inside the
/// WebView).
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
    /// Tap callback with the tap location normalized to 0...1 in the card's
    /// bounds (so the reviewer can tell apart center vs edge taps).
    var onTap: (@MainActor (CGPoint) -> Void)?
    /// Swipe callback with the recognized direction.
    var onSwipe: (@MainActor (SwipeDirection) -> Void)?
    /// Reloads the current side when this changes even if the document is
    /// identical, so "Replay audio" can restart embedded media.
    var reloadToken: Int = 0

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
        context.coordinator.attachGestures(to: webView)
        context.coordinator.onTap = onTap
        context.coordinator.onSwipe = onSwipe
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        // Keep the callbacks current (they capture the latest store state).
        context.coordinator.onTap = onTap
        context.coordinator.onSwipe = onSwipe

        let document = Self.makeDocument(html: html, css: css, ordinal: ordinal, isDark: isDark)
        // Only reload when the rendered document actually changes; SwiftUI calls
        // this on unrelated state updates (e.g. the undo button) and reloading
        // every time would flicker the card. A bumped `reloadToken` (Replay
        // audio) forces a reload even when the document is identical.
        let tokenChanged = context.coordinator.lastReloadToken != reloadToken
        context.coordinator.lastReloadToken = reloadToken
        guard context.coordinator.lastDocument != document || tokenChanged else { return }
        context.coordinator.lastDocument = document
        webView.loadHTMLString(document, baseURL: MediaSchemeHandler.baseURL)
    }

    @MainActor
    final class Coordinator: NSObject {
        var lastDocument: String?
        var lastReloadToken = 0
        var onTap: (@MainActor (CGPoint) -> Void)?
        var onSwipe: (@MainActor (SwipeDirection) -> Void)?
        private let gestureDelegate = CardGestureDelegate()

        /// Adds a tap recognizer and the four swipe recognizers to the scroll
        /// view. `cancelsTouchesInView = false` keeps card links/buttons working,
        /// and the shared delegate lets them recognize alongside scrolling.
        func attachGestures(to webView: WKWebView) {
            let scrollView = webView.scrollView

            let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
            tap.delegate = gestureDelegate
            tap.cancelsTouchesInView = false
            scrollView.addGestureRecognizer(tap)

            for direction in [UISwipeGestureRecognizer.Direction.left, .right, .up, .down] {
                let swipe = UISwipeGestureRecognizer(target: self, action: #selector(handleSwipe(_:)))
                swipe.direction = direction
                swipe.delegate = gestureDelegate
                swipe.cancelsTouchesInView = false
                scrollView.addGestureRecognizer(swipe)
            }
        }

        @objc func handleTap(_ recognizer: UITapGestureRecognizer) {
            guard let view = recognizer.view else { return }
            let width = view.bounds.width, height = view.bounds.height
            guard width > 0, height > 0 else { return }
            let point = recognizer.location(in: view)
            onTap?(CGPoint(x: point.x / width, y: point.y / height))
        }

        @objc func handleSwipe(_ recognizer: UISwipeGestureRecognizer) {
            switch recognizer.direction {
            case .left: onSwipe?(.left)
            case .right: onSwipe?(.right)
            case .up: onSwipe?(.up)
            case .down: onSwipe?(.down)
            default: break
            }
        }
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var infoCardID: Int64?
    @State private var editNoteTarget: ReviewerNoteTarget?
    @State private var showCardMenu = false
    @State private var confirmDelete = false

    var body: some View {
        VStack(spacing: 0) {
            if store.reviewDone {
                allCaughtUp
            } else {
                cardArea
                Divider()
                answerArea
            }
        }
        .navigationTitle("Review")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { store.stopReviewAudio() }
        .toolbar { reviewerToolbar }
        // The card-action menu is a self-presented overlay (rather than a
        // SwiftUI `Menu`) so it can show flag swatches + card/note variants like
        // AnkiDroid's reviewer overflow menu, and can be opened programmatically
        // for screenshots.
        .overlay {
            if showCardMenu {
                CardActionMenu(
                    store: store,
                    reduceMotion: reduceMotion,
                    onDismiss: { showCardMenu = false },
                    onEdit: { openEditor() },
                    onDelete: { confirmDelete = true },
                    onCardInfo: { infoCardID = store.currentCardID }
                )
            }
        }
        .sheet(item: infoSheetBinding) { target in
            CardInfoView(store: store, cardID: target.id)
        }
        .sheet(item: $editNoteTarget) { target in
            NoteEditorView(store: store, mode: .edit(noteID: target.id)) {
                // Re-render the (still-current) card so edited fields show.
                store.reloadCurrentCard()
            }
        }
        .confirmationDialog(
            "Delete note?",
            isPresented: $confirmDelete,
            titleVisibility: .visible
        ) {
            Button("Delete note", role: .destructive) { store.deleteCurrentNote() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently deletes the note and all of its cards. You can undo it from the toolbar.")
        }
        .onAppear {
            store.startReview()
            #if DEBUG
            // Screenshot/automation hook: flag + mark the current card and open
            // the card-action menu so the overflow menu can be captured.
            if ProcessInfo.processInfo.arguments.contains("-startInReviewMenu") {
                if store.currentCardID != nil {
                    if store.currentFlag == 0 { store.setReviewerFlag(1) }
                    if !store.isMarked { store.toggleMark() }
                    showCardMenu = true
                }
            }
            #endif
        }
    }

    // MARK: - Card + answer areas

    private var cardArea: some View {
        CardWebView(
            html: store.showingAnswer ? store.currentAnswer : store.currentQuestion,
            css: store.currentCSS,
            ordinal: store.currentOrdinal,
            isDark: colorScheme == .dark,
            mediaFolder: store.mediaFolderURL,
            onTap: handleCardTap,
            onSwipe: handleCardSwipe,
            reloadToken: store.replayToken
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Flag + marked indicators, overlaid on the card like AnkiDroid's
        // on-card flag ribbon and marked star.
        .overlay(alignment: .top) { indicatorBar }
    }

    @ViewBuilder
    private var indicatorBar: some View {
        if store.currentFlag != 0 || store.isMarked {
            HStack {
                if store.currentFlag != 0 {
                    Image(systemName: "flag.fill")
                        .foregroundStyle(ReviewerFlag.color(store.currentFlag))
                        .accessibilityLabel("Flagged \(ReviewerFlag.name(store.currentFlag))")
                }
                Spacer(minLength: 0)
                if store.isMarked {
                    Image(systemName: "star.fill")
                        .foregroundStyle(.yellow)
                        .accessibilityLabel("Marked")
                }
            }
            .font(.headline)
            .padding(.horizontal, DS.Spacing.l)
            .padding(.top, DS.Spacing.s)
        }
    }

    @ViewBuilder
    private var answerArea: some View {
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

    private var allCaughtUp: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 56)).foregroundStyle(.green)
            Text("All caught up").font(.title2.bold())
            Text("No more cards due in this deck.").foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var reviewerToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                showCardMenu = true
            } label: {
                Label("Card actions", systemImage: "ellipsis.circle")
            }
            .disabled(store.currentCardID == nil || store.reviewDone)
            .accessibilityLabel("Card actions")
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button(action: store.undo) {
                Label("Undo", systemImage: "arrow.uturn.backward")
            }
            .disabled(!store.canUndo)
            .accessibilityLabel(store.undoName.isEmpty ? "Undo" : "Undo \(store.undoName)")
        }
    }

    // MARK: - Gestures

    /// AnkiDroid-style tap mapping (respecting reduced motion — no animation is
    /// introduced): on the question, a tap anywhere shows the answer; on the
    /// answer, a tap in the center cell flips back to the question (so edge taps
    /// don't disrupt reading). On-screen buttons remain the primary path.
    private func handleCardTap(_ point: CGPoint) {
        guard !store.reviewDone, !showCardMenu else { return }
        if !store.showingAnswer {
            store.reveal()
        } else if isCenter(point) {
            store.flipBack()
        }
    }

    /// Once the answer is shown, swipes grade the card (the four directions map
    /// to the four ratings, mirroring the on-screen button order: left = Again,
    /// down = Hard, up = Good, right = Easy). AnkiDroid ships gestures unbound by
    /// default; this is a sensible default pending a gesture-settings screen.
    private func handleCardSwipe(_ direction: SwipeDirection) {
        guard store.showingAnswer, !store.reviewDone, !showCardMenu else { return }
        switch direction {
        case .left: store.rate(.again)
        case .down: store.rate(.hard)
        case .up: store.rate(.good)
        case .right: store.rate(.easy)
        }
    }

    /// The center cell of AnkiDroid's 3×3 (`NINE_POINT`) tap grid.
    private func isCenter(_ point: CGPoint) -> Bool {
        let third = 1.0 / 3.0
        return (third...(2 * third)).contains(point.x) && (third...(2 * third)).contains(point.y)
    }

    // MARK: - Actions

    private func openEditor() {
        guard let noteID = store.currentNoteID else { return }
        editNoteTarget = ReviewerNoteTarget(id: noteID)
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

/// Identifiable wrapper so the reviewer's Edit-note sheet can be driven by
/// `.sheet(item:)` from the current card's note id.
private struct ReviewerNoteTarget: Identifiable {
    let id: Int64
}

// MARK: - Card action menu

/// The reviewer's card-action menu — an overflow panel mirroring AnkiDroid's
/// `ReviewerMenu`: set/clear flag (none + 7 colors), Mark/Unmark, Edit, Bury
/// card/note, Suspend card/note, Delete note, Replay audio, and Card Info.
///
/// Flag and Mark update the card in place (the menu stays usable); Bury,
/// Suspend, and Delete advance to the next card via the store. Presented as a
/// custom overlay (not a `Menu`) so the flag swatches and card/note submenus can
/// be shown inline and the open menu can be screenshotted.
private struct CardActionMenu: View {
    @ObservedObject var store: AnkiStore
    let reduceMotion: Bool
    let onDismiss: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void
    let onCardInfo: () -> Void

    var body: some View {
        ZStack(alignment: .top) {
            // Scrim: tap outside to dismiss.
            Color.black.opacity(0.2)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture(perform: onDismiss)
                .accessibilityLabel("Close menu")
                .accessibilityAddTraits(.isButton)

            // Right-anchored dropdown that wraps its actions, with margins on
            // both sides so it always fits the screen (≥16pt left, 12pt right).
            HStack(spacing: 0) {
                Spacer(minLength: DS.Spacing.l)
                panel.frame(maxWidth: 320)
            }
            .padding(.trailing, DS.Spacing.m)
            .padding(.top, DS.Spacing.xs)
            .transition(reduceMotion ? .opacity : .scale(scale: 0.95, anchor: .topTrailing).combined(with: .opacity))
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: store.currentFlag)
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 0) {
            flagSection
            divider
            row("Edit note", systemImage: "pencil") { onDismiss(); onEdit() }
            row(store.isMarked ? "Unmark note" : "Mark note",
                systemImage: store.isMarked ? "star.fill" : "star") {
                store.toggleMark()
            }
            divider
            row("Bury card", systemImage: "rectangle.stack") { onDismiss(); store.buryCard() }
            row("Bury note", systemImage: "rectangle.stack.fill") { onDismiss(); store.buryNote() }
            row("Suspend card", systemImage: "pause.circle") { onDismiss(); store.suspendCard() }
            row("Suspend note", systemImage: "pause.circle.fill") { onDismiss(); store.suspendNote() }
            divider
            row("Replay audio", systemImage: "speaker.wave.2") { onDismiss(); store.replayAudio() }
            row("Card info", systemImage: "info.circle") { onDismiss(); onCardInfo() }
            divider
            row("Delete note", systemImage: "trash", role: .destructive) { onDismiss(); onDelete() }
        }
        .padding(.vertical, DS.Spacing.xs)
        .background(DS.surface, in: RoundedRectangle(cornerRadius: DS.Radius.large, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.large, style: .continuous)
                .strokeBorder(DS.separator, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.18), radius: 16, y: 8)
    }

    /// Flag row: the current flag plus a swatch per color (none + 7), like
    /// AnkiDroid's flag submenu. Tapping a swatch toggles that color.
    private var flagSection: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.s) {
            Text("Flag")
                .font(DS.Typography.caption.weight(.semibold))
                .foregroundStyle(DS.textSecondary)
            HStack(spacing: DS.Spacing.xs) {
                ForEach(0...7, id: \.self) { flag in
                    FlagSwatch(flag: flag, isSelected: store.currentFlag == flag) {
                        store.toggleReviewerFlag(flag)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .padding(.horizontal, DS.Spacing.l)
        .padding(.vertical, DS.Spacing.s)
    }

    private var divider: some View {
        Divider().overlay(DS.separator).padding(.vertical, DS.Spacing.xs)
    }

    private func row(
        _ title: String,
        systemImage: String,
        role: ButtonRole? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(role: role, action: action) {
            HStack(spacing: DS.Spacing.m) {
                Image(systemName: systemImage)
                    .frame(width: 24)
                    .foregroundStyle(role == .destructive ? DS.again : DS.accent)
                Text(title)
                    .font(DS.Typography.body)
                    .foregroundStyle(role == .destructive ? DS.again : DS.textPrimary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, DS.Spacing.l)
            .frame(minHeight: DS.minTapTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// A single flag color swatch in the flag row. `none` (0) is a slashed circle;
/// 1...7 are filled in their flag color. The active flag gets a ring.
private struct FlagSwatch: View {
    let flag: Int
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                if flag == 0 {
                    Image(systemName: "slash.circle")
                        .font(.system(size: 22))
                        .foregroundStyle(DS.textSecondary)
                } else {
                    Circle()
                        .fill(ReviewerFlag.color(flag))
                        .frame(width: 24, height: 24)
                }
                if isSelected {
                    Circle()
                        .strokeBorder(DS.textPrimary, lineWidth: 2)
                        .frame(width: 30, height: 30)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 34)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(flag == 0 ? "No flag" : "Flag \(ReviewerFlag.name(flag))")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

/// Flag color/name mapping, matching AnkiDroid's `Flag` order
/// (1 red, 2 orange, 3 green, 4 blue, 5 pink, 6 turquoise, 7 purple).
enum ReviewerFlag {
    static func color(_ flag: Int) -> Color {
        switch flag {
        case 1: return Color(red: 0.85, green: 0.20, blue: 0.18)   // red
        case 2: return Color(red: 0.95, green: 0.56, blue: 0.13)   // orange
        case 3: return Color(red: 0.18, green: 0.64, blue: 0.34)   // green
        case 4: return Color(red: 0.15, green: 0.45, blue: 0.90)   // blue
        case 5: return Color(red: 0.90, green: 0.35, blue: 0.62)   // pink
        case 6: return Color(red: 0.20, green: 0.70, blue: 0.74)   // turquoise
        case 7: return Color(red: 0.55, green: 0.35, blue: 0.78)   // purple
        default: return .clear
        }
    }

    static func name(_ flag: Int) -> String {
        switch flag {
        case 1: return "red"
        case 2: return "orange"
        case 3: return "green"
        case 4: return "blue"
        case 5: return "pink"
        case 6: return "turquoise"
        case 7: return "purple"
        default: return "none"
        }
    }
}
