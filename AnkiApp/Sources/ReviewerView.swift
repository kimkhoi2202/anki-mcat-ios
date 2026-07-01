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

/// A swipe direction over the card, used by the reviewer's gesture dispatcher.
enum SwipeDirection {
    case left, right, up, down

    /// The configurable `ReviewerGesture` this swipe maps to (for config lookup).
    var gesture: ReviewerGesture {
        switch self {
        case .left: return .swipeLeft
        case .right: return .swipeRight
        case .up: return .swipeUp
        case .down: return .swipeDown
        }
    }
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
    /// The reviewer's gesture configuration. Decides which recognizers are
    /// attached (double-tap and long-press are only wired when bound), so the
    /// common case keeps single taps snappy and text selection undisturbed.
    /// Defaults for static previews (Card Browser / template editor), which pass
    /// no gesture callbacks and so stay inert regardless.
    var config: GestureConfig = .defaults
    /// Tap callback with the tap location normalized to 0...1 in the card's
    /// bounds (so the reviewer can resolve which zone was tapped).
    var onTap: (@MainActor (CGPoint) -> Void)?
    /// Swipe callback with the recognized direction.
    var onSwipe: (@MainActor (SwipeDirection) -> Void)?
    /// Long-press callback (fired once, when the press is first recognized).
    var onLongPress: (@MainActor () -> Void)?
    /// Double-tap callback (only wired when double-tap is bound).
    var onDoubleTap: (@MainActor () -> Void)?
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
        context.coordinator.onTap = onTap
        context.coordinator.onSwipe = onSwipe
        context.coordinator.onLongPress = onLongPress
        context.coordinator.onDoubleTap = onDoubleTap
        context.coordinator.attachGestures(to: webView, config: config)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        // Keep the callbacks current (they capture the latest store state).
        context.coordinator.onTap = onTap
        context.coordinator.onSwipe = onSwipe
        context.coordinator.onLongPress = onLongPress
        context.coordinator.onDoubleTap = onDoubleTap
        // Re-attach recognizers if the bound set changed (e.g. double-tap/long
        // press became (un)bound). Zone/direction dispatch reads the live config
        // through the callbacks, so most binding edits need no re-attach.
        context.coordinator.updateGestureConfig(config)

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
        var onLongPress: (@MainActor () -> Void)?
        var onDoubleTap: (@MainActor () -> Void)?
        private let gestureDelegate = CardGestureDelegate()
        /// The web view's own scroll view — recognizers attach here (not an
        /// overlay) so the card still scrolls and its links/buttons keep working.
        private weak var scrollView: UIScrollView?
        /// Recognizers we added, so we can tear them down when the attached set
        /// changes.
        private var installedRecognizers: [UIGestureRecognizer] = []
        /// Signature of the currently-attached recognizer *set*. Only the
        /// optional double-tap / long-press recognizers change which recognizers
        /// exist; the single tap and four swipes are always present and dispatch
        /// by reading the live config through the callbacks.
        private var installedSignature: String?

        /// Attaches the gesture recognizers for `config` to the web view's scroll
        /// view. `cancelsTouchesInView = false` keeps card links/buttons working,
        /// and the shared delegate lets them recognize alongside scrolling.
        func attachGestures(to webView: WKWebView, config: GestureConfig) {
            scrollView = webView.scrollView
            rebuild(for: config)
        }

        /// Re-attaches recognizers only when the attached *set* changes
        /// (double-tap / long-press bound or not). The zone/direction dispatch
        /// always uses the live config via the callbacks, so a binding change
        /// that neither adds nor removes a recognizer needs no rebuild.
        func updateGestureConfig(_ config: GestureConfig) {
            rebuild(for: config)
        }

        private func rebuild(for config: GestureConfig) {
            guard let scrollView else { return }
            let doubleBound = config.command(for: .doubleTap) != .none
            let longBound = config.command(for: .longPress) != .none
            let signature = "\(doubleBound)-\(longBound)"
            guard signature != installedSignature else { return }
            installedSignature = signature

            for recognizer in installedRecognizers {
                scrollView.removeGestureRecognizer(recognizer)
            }
            installedRecognizers.removeAll()

            let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
            tap.delegate = gestureDelegate
            tap.cancelsTouchesInView = false

            // Double-tap is wired only when bound, so single taps stay snappy
            // (no require-to-fail delay) in the default (unbound) case. When it's
            // bound, the single tap waits for it to fail so both can coexist.
            if doubleBound {
                let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
                doubleTap.numberOfTapsRequired = 2
                doubleTap.delegate = gestureDelegate
                doubleTap.cancelsTouchesInView = false
                scrollView.addGestureRecognizer(doubleTap)
                installedRecognizers.append(doubleTap)
                tap.require(toFail: doubleTap)
            }
            scrollView.addGestureRecognizer(tap)
            installedRecognizers.append(tap)

            // The four swipes are always attached; `handleSwipe` dispatches by the
            // live config (unbound directions do nothing). The vertical (up/down)
            // swipes keep the scroll-vs-grade safety: they `require(toFail:)` the
            // scroll pan so a real scroll wins on a scrollable card, and only fire
            // when the card can't scroll — so scrolling can never trigger an
            // action. The horizontal swipes don't collide with vertical scrolling.
            for direction in [UISwipeGestureRecognizer.Direction.left, .right, .up, .down] {
                let swipe = UISwipeGestureRecognizer(target: self, action: #selector(handleSwipe(_:)))
                swipe.direction = direction
                swipe.delegate = gestureDelegate
                swipe.cancelsTouchesInView = false
                if direction == .up || direction == .down {
                    swipe.require(toFail: scrollView.panGestureRecognizer)
                }
                scrollView.addGestureRecognizer(swipe)
                installedRecognizers.append(swipe)
            }

            // Long-press only when bound, so it doesn't interfere with the web
            // view's own text selection / callout when the user hasn't asked for
            // a long-press action.
            if longBound {
                let longPress = UILongPressGestureRecognizer(
                    target: self, action: #selector(handleLongPress(_:))
                )
                longPress.delegate = gestureDelegate
                longPress.cancelsTouchesInView = false
                scrollView.addGestureRecognizer(longPress)
                installedRecognizers.append(longPress)
            }
        }

        @objc func handleTap(_ recognizer: UITapGestureRecognizer) {
            guard let view = recognizer.view else { return }
            let width = view.bounds.width, height = view.bounds.height
            guard width > 0, height > 0 else { return }
            let point = recognizer.location(in: view)
            onTap?(CGPoint(x: point.x / width, y: point.y / height))
        }

        @objc func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
            onDoubleTap?()
        }

        @objc func handleLongPress(_ recognizer: UILongPressGestureRecognizer) {
            // Fire once, when the press is first recognized (not on end/cancel).
            guard recognizer.state == .began else { return }
            onLongPress?()
        }

        @objc func handleSwipe(_ recognizer: UISwipeGestureRecognizer) {
            switch recognizer.direction {
            case .left: onSwipe?(.left)
            case .right: onSwipe?(.right)
            // Only forward a vertical swipe when the card can't scroll, so a
            // flick meant to scroll a long answer never triggers an action.
            // (Backs up the `require(toFail:)` on these recognizers above.)
            case .up where !isVerticallyScrollable(recognizer.view): onSwipe?(.up)
            case .down where !isVerticallyScrollable(recognizer.view): onSwipe?(.down)
            default: break
            }
        }

        /// Whether the card's scroll view has content taller than its bounds (so
        /// a vertical drag is a real scroll). The 1pt epsilon absorbs sub-pixel
        /// rounding in the measured content size.
        private func isVerticallyScrollable(_ view: UIView?) -> Bool {
            guard let scrollView = view as? UIScrollView else { return false }
            return scrollView.contentSize.height > scrollView.bounds.height + 1
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
          /* Type-in-the-answer diff styling (Anki reviewer.scss). */
          #typeans { width: 100%; box-sizing: border-box; line-height: 1.75; }
          code#typeans { white-space: pre-wrap; font-variant-ligatures: none; }
          .typeGood { background: #afa; color: black; }
          .typeBad { background: #faa; color: black; }
          .typeMissed { background: #ccc; color: black; }
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
    /// Pops the reviewer for the `exitReviewer` gesture command.
    @Environment(\.dismiss) private var dismiss
    /// "Full-screen reviewer" (Anki's Distractions ▸ hide bars during review):
    /// hides the status bar and home indicator for a distraction-free session.
    /// The in-app toolbar (Undo / back / card menu) stays, so the user can always
    /// act on or leave the card.
    @AppStorage(FullScreenReviewer.storageKey) private var fullScreenReviewer = false

    @State private var infoCardID: Int64?
    @State private var editNoteTarget: ReviewerNoteTarget?
    @State private var showCardMenu = false
    @State private var confirmDelete = false
    /// Drives the "Set due date" prompt and holds its in-progress text.
    @State private var showSetDueDate = false
    @State private var dueDateText = ""
    /// Drives the "Add note" editor sheet (the `addNote` gesture command).
    @State private var showAddNote = false

    /// Owns the whiteboard's tool/color/width state and undo history. Persists
    /// across cards so the pen selection is kept; its strokes are cleared per card
    /// (see the `currentCardID` change handler). Only rendered when the store's
    /// `whiteboardVisible` is on.
    @StateObject private var whiteboard = WhiteboardController()

    /// Whether any menu, sheet, or prompt is presented over the reviewer. Drives
    /// pausing auto-advance so a timer never reveals or grades behind a dialog.
    private var anyOverlayPresented: Bool {
        showCardMenu || confirmDelete || showSetDueDate || showAddNote
            || infoCardID != nil || editNoteTarget != nil
    }

    var body: some View {
        VStack(spacing: 0) {
            if store.reviewDone {
                allCaughtUp
            } else {
                cardArea
                // Per-segment audio replay buttons, shown for cards with audio
                // when "Show play buttons on cards with audio" is on (Anki's
                // hide_audio_play_buttons inverted), in addition to autoplay.
                if store.reviewingPrefs.showPlayButtonsOnAudio, !store.currentSideAudio.isEmpty {
                    audioPlayButtons
                }
                Divider()
                answerArea
            }
        }
        .navigationTitle("Review")
        .navigationBarTitleDisplayMode(.inline)
        // Full-screen reviewer: hide the status bar and home indicator for an
        // immersive, distraction-free session (the in-app toolbar stays).
        .statusBarHidden(fullScreenReviewer)
        .persistentSystemOverlays(fullScreenReviewer ? .hidden : .automatic)
        .onDisappear {
            store.stopReviewAudio()
            // Stop auto-advance so a pending timer can't fire after leaving.
            store.endAutoAdvanceSession()
        }
        // Pause auto-advance whenever a menu/sheet/prompt is up, and resume when
        // they're all dismissed (so it never grades behind a dialog).
        .onChange(of: anyOverlayPresented) { presented in
            store.setAutoAdvancePaused(presented)
        }
        // Fresh whiteboard canvas per card (default behavior: strokes don't carry
        // over when advancing to the next card).
        .onChange(of: store.currentCardID) { _ in
            whiteboard.resetForNewCard()
        }
        // Animate the transient auto-advance reminder in/out (respecting Reduce
        // Motion).
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: store.autoAdvanceReminder)
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
                    onCardInfo: { infoCardID = store.currentCardID },
                    onSetDueDate: { dueDateText = ""; showSetDueDate = true }
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
        // "Add note" during review (the `addNote` gesture command), defaulting to
        // the deck being studied. A new note doesn't change the current card, so
        // we only refresh the deck counts on save.
        .sheet(isPresented: $showAddNote) {
            NoteEditorView(store: store, mode: .add(defaultDeckID: store.currentDeckID)) {
                store.refreshDecks()
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
        // "Set due date" prompt: an Anki date spec applied to the current card,
        // mirroring AnkiDroid's set-due-date dialog (accepts a number of days or
        // a range). Applying advances/refreshes like the other card actions.
        .alert("Set due date", isPresented: $showSetDueDate) {
            TextField("e.g. 0, 3, or 7-14", text: $dueDateText)
                .keyboardType(.numbersAndPunctuation)
                .autocorrectionDisabled()
            Button("Set") {
                store.setReviewerDueDate(dueDateText)
                dueDateText = ""
            }
            Button("Cancel", role: .cancel) { dueDateText = "" }
        } message: {
            Text("Show this card again after a number of days (e.g. 3), a random day in a range (7-14), or 0 for today.")
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
            // Type-in-the-answer demo: type a near-miss answer and reveal so the
            // colored diff can be captured for verification.
            if ProcessInfo.processInfo.arguments.contains("-typeDemo"), store.typeAnswer != nil {
                store.typedAnswer = "Tokio"
                store.reveal()
            }
            // Set-due-date demo: open the prompt (pre-filled with a range) for the
            // set-due screenshot.
            if ProcessInfo.processInfo.arguments.contains("-demoSetDueDate"), store.currentCardID != nil {
                dueDateText = "7-14"
                showSetDueDate = true
            }
            // Gesture-dispatch demos: run a real gesture command through the
            // config-driven dispatcher so a screenshot shows the resulting action.
            // `-demoGestureReveal` fires the tap-center command (reveal / flip);
            // `-demoGestureLongPress` fires the long-press command (edit note),
            // proving a gesture dispatches through `store.gestureConfig`.
            if ProcessInfo.processInfo.arguments.contains("-demoGestureReveal") {
                dispatch(store.gestureConfig.command(for: .tapCenter))
            }
            if ProcessInfo.processInfo.arguments.contains("-demoGestureLongPress"),
               store.currentNoteID != nil {
                dispatch(store.gestureConfig.command(for: .longPress))
            }
            // Whiteboard demo: show the overlay and seed sample strokes (once the
            // canvas has mounted and the card's per-card reset has run) so the
            // reviewer screenshot shows the whiteboard rendering ink.
            if ProcessInfo.processInfo.arguments.contains("-demoWhiteboard") {
                store.whiteboardVisible = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    whiteboard.seedDemoStrokes()
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
            config: store.gestureConfig,
            onTap: handleCardTap,
            onSwipe: handleCardSwipe,
            onLongPress: handleLongPress,
            onDoubleTap: handleDoubleTap,
            reloadToken: store.replayToken
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Whiteboard drawing surface over the card, mounted only while enabled so
        // the card's own gestures/scrolling are untouched when it's off. When on,
        // it captures drawing touches; the answer/grade buttons and toolbar (which
        // sit outside the card) stay usable.
        .overlay {
            if store.whiteboardVisible {
                WhiteboardCanvas(controller: whiteboard)
            }
        }
        // Flag/auto-advance/marked indicators + remaining counts, overlaid on the
        // card like AnkiDroid's on-card flag ribbon, marked star, and count.
        // Purely informational, so it never intercepts drawing/tap touches.
        .overlay(alignment: .top) { topBar.allowsHitTesting(false) }
        // A transient "time elapsed" notice for the deck's "show reminder"
        // auto-advance action (non-grading); auto-dismisses.
        .overlay(alignment: .top) { autoAdvanceReminderToast }
        // The whiteboard's compact toolbar floats at the bottom of the card
        // (hide the whiteboard with the reviewer's on-screen toggle).
        .overlay(alignment: .bottom) {
            if store.whiteboardVisible {
                WhiteboardToolbar(controller: whiteboard)
                    .padding(.bottom, DS.Spacing.m)
            }
        }
    }

    /// The transient auto-advance reminder toast (the deck's "show reminder"
    /// action), sitting just below the on-card status bar.
    @ViewBuilder
    private var autoAdvanceReminderToast: some View {
        if let message = store.autoAdvanceReminder {
            Text(message)
                .font(DS.Typography.caption.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, DS.Spacing.m)
                .padding(.vertical, DS.Spacing.s)
                .background(Capsule(style: .continuous).fill(Color.black.opacity(0.82)))
                .padding(.top, DS.Spacing.xl + DS.Spacing.m)
                .transition(.opacity)
                .accessibilityLabel(message)
        }
    }

    /// Top-of-card status bar: the flag and an auto-advance indicator (leading),
    /// the remaining new/learning/review counts (center, when enabled), and the
    /// marked star (trailing) — overlaid on the card like AnkiDroid's reviewer.
    @ViewBuilder
    private var topBar: some View {
        let showCounts = store.reviewingPrefs.showRemainingDueCounts
        if store.currentFlag != 0 || store.isMarked || showCounts || store.autoAdvanceEnabled {
            ZStack {
                if showCounts { remainingCounts }
                HStack(spacing: DS.Spacing.s) {
                    if store.currentFlag != 0 {
                        Image(systemName: "flag.fill")
                            .foregroundStyle(ReviewerFlag.color(store.currentFlag))
                            .accessibilityLabel("Flagged \(ReviewerFlag.name(store.currentFlag))")
                    }
                    if store.autoAdvanceEnabled {
                        Image(systemName: "forward.circle")
                            .foregroundStyle(DS.textSecondary)
                            .accessibilityLabel("Auto advance on")
                    }
                    Spacer(minLength: 0)
                    if store.isMarked {
                        Image(systemName: "star.fill")
                            .foregroundStyle(.yellow)
                            .accessibilityLabel("Marked")
                    }
                }
            }
            .font(.headline)
            .padding(.horizontal, DS.Spacing.l)
            .padding(.top, DS.Spacing.s)
        }
    }

    /// AnkiDroid's colored remaining-count readout — new + learning + review — in
    /// the deck-list colors (new = accent/blue, learning = red, review = green);
    /// a zero count is muted, like the deck list's count labels.
    private var remainingCounts: some View {
        HStack(spacing: DS.Spacing.xs) {
            Text("\(store.newCount)").foregroundStyle(countColor(store.newCount, DS.accent))
            Text("+").foregroundStyle(DS.textSecondary)
            Text("\(store.learningCount)").foregroundStyle(countColor(store.learningCount, DS.again))
            Text("+").foregroundStyle(DS.textSecondary)
            Text("\(store.reviewCount)").foregroundStyle(countColor(store.reviewCount, DS.easy))
        }
        .font(DS.Typography.caption.weight(.semibold))
        .monospacedDigit()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(store.newCount) new, \(store.learningCount) learning, \(store.reviewCount) to review"
        )
    }

    private func countColor(_ count: Int, _ color: Color) -> Color {
        count == 0 ? DS.textSecondary : color
    }

    /// A compact row of replay buttons — one per audio segment on the side shown
    /// — so the user can replay a specific `[sound:]`/`{{tts}}` clip, in addition
    /// to autoplay. Clone of AnkiDroid's per-audio play buttons on cards with
    /// audio (shown only when "Show play buttons on cards with audio" is on).
    private var audioPlayButtons: some View {
        HStack(spacing: DS.Spacing.s) {
            ForEach(Array(store.currentSideAudio.enumerated()), id: \.offset) { index, segment in
                Button {
                    store.playAudioSegment(at: index)
                } label: {
                    HStack(spacing: DS.Spacing.xs) {
                        Image(systemName: audioIcon(segment))
                        if store.currentSideAudio.count > 1 {
                            Text("\(index + 1)").monospacedDigit()
                        }
                    }
                    .font(DS.Typography.caption.weight(.semibold))
                    .foregroundStyle(DS.accent)
                    .padding(.horizontal, DS.Spacing.m)
                    .frame(minHeight: 34)
                    .background(
                        RoundedRectangle(cornerRadius: DS.Radius.medium, style: .continuous)
                            .strokeBorder(DS.accent, lineWidth: 1)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(
                    store.currentSideAudio.count > 1 ? "Play audio \(index + 1)" : "Play audio"
                )
            }
        }
        .padding(.horizontal, DS.Spacing.l)
        .padding(.vertical, DS.Spacing.s)
        .frame(maxWidth: .infinity)
    }

    /// Icon for an audio segment's replay button: a play glyph for recorded
    /// `[sound:]` clips, a speaker glyph for synthesized `{{tts}}` text.
    private func audioIcon(_ segment: CardAudio) -> String {
        switch segment {
        case .sound: return "play.circle.fill"
        case .tts: return "speaker.wave.2.circle.fill"
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
            VStack(spacing: DS.Spacing.s) {
                if store.typeAnswer != nil {
                    TextField("Type the answer", text: $store.typedAnswer)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .submitLabel(.done)
                        .onSubmit { store.reveal() }
                        .accessibilityLabel("Type the answer")
                }
                Button(action: store.reveal) {
                    Text("Show Answer").frame(maxWidth: .infinity)
                }
                .buttonStyle(.dsPrimary)
            }
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
        // On-screen whiteboard toggle, so the whiteboard can be shown/hidden
        // without binding a gesture (the `toggleWhiteboard` gesture command drives
        // the same store hook). Tinted when active.
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                store.toggleWhiteboard()
            } label: {
                Label(
                    "Whiteboard",
                    systemImage: store.whiteboardVisible ? "scribble.variable" : "scribble"
                )
            }
            .tint(store.whiteboardVisible ? DS.accent : DS.textPrimary)
            .disabled(store.reviewDone)
            .accessibilityLabel(store.whiteboardVisible ? "Hide whiteboard" : "Show whiteboard")
            .accessibilityAddTraits(store.whiteboardVisible ? [.isButton, .isSelected] : .isButton)
        }
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

    // MARK: - Gestures (config-driven dispatch)
    //
    // Every recognized gesture is looked up in `store.gestureConfig` and the
    // mapped `ViewerCommand` dispatched, replacing the old hardcoded mapping.
    // Defaults reproduce the prior behavior (see `GestureConfig.defaults`).

    /// Resolves a tap to its zone (a pure, tested function of the normalized
    /// point) and dispatches the bound command.
    private func handleCardTap(_ point: CGPoint) {
        guard !store.reviewDone, !showCardMenu else { return }
        let zone = TapZone.from(x: point.x, y: point.y)
        dispatch(store.gestureConfig.command(for: zone.gesture))
    }

    /// Dispatches the command bound to a swipe direction. The swipe-vs-scroll
    /// safety (vertical swipes require the scroll pan to fail / only fire when the
    /// card can't scroll) is enforced in the recognizer, so a scroll never
    /// reaches here as an action.
    private func handleCardSwipe(_ direction: SwipeDirection) {
        guard !store.reviewDone, !showCardMenu else { return }
        dispatch(store.gestureConfig.command(for: direction.gesture))
    }

    /// Dispatches the long-press command (only wired when it's bound).
    private func handleLongPress() {
        guard !store.reviewDone, !showCardMenu else { return }
        dispatch(store.gestureConfig.command(for: .longPress))
    }

    /// Dispatches the double-tap command (only wired when it's bound).
    private func handleDoubleTap() {
        guard !store.reviewDone, !showCardMenu else { return }
        dispatch(store.gestureConfig.command(for: .doubleTap))
    }

    /// Central gesture → action dispatcher. Reuses the existing `AnkiStore`
    /// reviewer methods for card actions; view-level actions (edit/add/info
    /// sheets, delete confirmation, exit) are handled here.
    ///
    /// CRITICAL safety: grading commands only ever run while the answer is shown
    /// (`grade(_:)`), so a stray tap/swipe on a question can never grade it — the
    /// same "grade only when the answer is shown" rule the old code enforced.
    private func dispatch(_ command: ViewerCommand) {
        switch command {
        case .none:
            break
        case .showAnswer:
            // Reveal on the question; flip back when the answer is already shown
            // (preserves the prior "tap center reveals / flips back" behavior).
            if store.showingAnswer { store.flipBack() } else { store.reveal() }
        case .answerAgain: grade(.again)
        case .answerHard: grade(.hard)
        case .answerGood: grade(.good)
        case .answerEasy: grade(.easy)
        case .undo:
            if store.canUndo { store.undo() }
        case .editNote:
            openEditor()
        case .addNote:
            showAddNote = true
        case .markNote:
            store.toggleMark()
        case .buryCard:
            store.buryCard()
        case .buryNote:
            store.buryNote()
        case .suspendCard:
            store.suspendCard()
        case .suspendNote:
            store.suspendNote()
        case .deleteNote:
            // Route through the same confirmation as the menu — a gesture must
            // not silently delete a note (it's still undoable afterward).
            confirmDelete = true
        case .flagRed, .flagOrange, .flagGreen, .flagBlue,
             .flagPink, .flagTurquoise, .flagPurple:
            if let flag = command.flagNumber { store.toggleReviewerFlag(flag) }
        case .replayAudio:
            store.replayAudio()
        case .cardInfo:
            infoCardID = store.currentCardID
        case .toggleWhiteboard:
            // Show/hide the whiteboard drawing overlay (same hook as the on-screen
            // toggle button).
            store.toggleWhiteboard()
        case .exitReviewer:
            dismiss()
        }
    }

    /// Grades the card, but only while the answer is shown — the core safety rule
    /// that keeps a swipe/tap from grading a question.
    private func grade(_ rating: Anki_Scheduler_CardAnswer.Rating) {
        guard store.showingAnswer else { return }
        store.rate(rating)
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
                // Gated on "Show next review time above answer buttons"
                // (engine `show_intervals_on_buttons`), matching AnkiDroid.
                if store.reviewingPrefs.showIntervalsOnButtons,
                   index < store.currentIntervals.count, !store.currentIntervals[index].isEmpty {
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

    /// "Good, interval 1d" so the projected interval is announced too — but only
    /// when the interval is actually shown (the `show_intervals_on_buttons`
    /// preference is on), so VoiceOver matches the visible label.
    private func intervalAccessibilityLabel(_ label: String, index: Int) -> String {
        guard store.reviewingPrefs.showIntervalsOnButtons,
              index < store.currentIntervals.count, !store.currentIntervals[index].isEmpty else {
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
    let onSetDueDate: () -> Void

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
            row("Set due date", systemImage: "calendar") { onDismiss(); onSetDueDate() }
            divider
            // Auto Advance is a checkable toggle (kept open like Mark), mirroring
            // AnkiDroid's reviewer "Auto Advance" menu item.
            toggleRow("Auto advance", systemImage: "forward.circle", isOn: store.autoAdvanceEnabled) {
                store.autoAdvanceEnabled.toggle()
            }
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

    /// A checkable menu row (the Auto Advance toggle), with a trailing checkmark
    /// when `isOn`. Tapping flips the state without dismissing the menu, like the
    /// Mark/Unmark row.
    private func toggleRow(
        _ title: String,
        systemImage: String,
        isOn: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: DS.Spacing.m) {
                Image(systemName: systemImage)
                    .frame(width: 24)
                    .foregroundStyle(DS.accent)
                Text(title)
                    .font(DS.Typography.body)
                    .foregroundStyle(DS.textPrimary)
                Spacer(minLength: 0)
                if isOn {
                    Image(systemName: "checkmark")
                        .font(DS.Typography.body.weight(.semibold))
                        .foregroundStyle(DS.accent)
                }
            }
            .padding(.horizontal, DS.Spacing.l)
            .frame(minHeight: DS.minTapTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
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
