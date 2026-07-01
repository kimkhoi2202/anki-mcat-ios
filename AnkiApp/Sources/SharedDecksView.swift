import SwiftUI
import WebKit
import UIKit
import AnkiKit

/// "Get shared decks", cloning AnkiDroid's `SharedDecksActivity` /
/// `SharedDecksDownloadFragment`: a plain external `WKWebView` pointed at
/// AnkiWeb's shared-decks site that captures a deck download and hands it to the
/// existing import flow (`store.importPackage`).
///
/// This is a normal external web view — completely unrelated to `AnkiWebPage`
/// (Anki's own bundled SvelteKit pages served over the `/_anki` bridge). It only
/// talks to `ankiweb.net`.
///
/// **Download detection.** When the user taps "Download" on a deck's page, the
/// browser navigates to AnkiWeb's download endpoint
/// (`https://ankiweb.net/svc/shared/download-deck/<id>?t=…`), whose response is an
/// `.apkg` served as an attachment (`Content-Disposition: attachment`,
/// `application/octet-stream`). We detect that in the navigation-response policy
/// (endpoint path / MIME / filename / a non-displayable body), convert it to a
/// `WKDownload` (iOS 14.5+), save it to a temp file, and import it — the iOS
/// analogue of AnkiDroid keying off the `DownloadListener` for
/// `download-deck/…`. The download runs on the web view's own session, so the
/// user's AnkiWeb login cookies are carried automatically.
struct SharedDecksView: View {
    @ObservedObject var store: AnkiStore
    /// Called after a successful import so the deck list refreshes.
    var onImported: () -> Void = {}

    @Environment(\.dismiss) private var dismiss
    @StateObject private var browser = SharedDecksBrowser()

    /// True while `store.importPackage` runs on a freshly downloaded deck.
    @State private var importing = false
    @State private var resultMessage: String?
    @State private var errorMessage: String?

    /// AnkiWeb's shared-decks landing page (AnkiDroid `shared_decks_url`).
    static let sharedDecksURL = URL(string: "https://ankiweb.net/shared/decks/")!

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                addressBar
                Divider().overlay(DS.separator)
                webArea
            }
            .background(DS.background.ignoresSafeArea())
            .navigationTitle(browser.title.isEmpty ? "Get shared decks" : browser.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("sharedDecksDone")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        browser.reload()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .accessibilityLabel("Reload")
                    .disabled(importing)
                }
            }
            .alert("Import complete", isPresented: resultPresented) {
                Button("OK", role: .cancel) { resultMessage = nil }
            } message: {
                Text(resultMessage ?? "")
            }
            .alert("Something went wrong", isPresented: errorPresented) {
                Button("OK", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
        .onAppear {
            // Wire the coordinator's download callbacks into the import flow.
            browser.onPackageDownloaded = { url in runImport(url) }
            browser.onDownloadFailed = { message in errorMessage = message }
        }
    }

    // MARK: - Chrome

    /// A compact, read-only address bar: back, the current URL (with a lock for
    /// https), and a "home" button that returns to the shared-decks landing page
    /// (AnkiDroid's toolbar home action).
    private var addressBar: some View {
        HStack(spacing: DS.Spacing.m) {
            Button {
                browser.goBack()
            } label: {
                Image(systemName: "chevron.backward")
            }
            .disabled(!browser.canGoBack || importing)
            .accessibilityLabel("Back")

            HStack(spacing: DS.Spacing.xs) {
                Image(systemName: browser.isSecure ? "lock.fill" : "globe")
                    .font(.caption2)
                    .foregroundStyle(DS.textSecondary)
                Text(browser.displayURL)
                    .font(DS.Typography.caption)
                    .foregroundStyle(DS.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, DS.Spacing.m)
            .frame(height: 34)
            .background(DS.surface, in: Capsule())
            .overlay(Capsule().strokeBorder(DS.separator, lineWidth: 1))

            Button {
                browser.goHome()
            } label: {
                Image(systemName: "house")
            }
            .disabled(importing)
            .accessibilityLabel("Shared decks home")
        }
        .padding(.horizontal, DS.Spacing.l)
        .padding(.vertical, DS.Spacing.s)
        .tint(DS.accent)
    }

    private var webArea: some View {
        ZStack {
            SharedDecksWebView(browser: browser, initialURL: Self.sharedDecksURL)

            // Thin top loading bar while a page loads.
            if browser.isLoading {
                VStack {
                    ProgressView(value: max(0.05, browser.loadProgress))
                        .progressViewStyle(.linear)
                        .tint(DS.accent)
                    Spacer()
                }
            }

            // Download / import progress, mirroring AnkiDroid's download screen.
            if let progress = browser.downloadProgress {
                progressCard(title: "Downloading deck…", value: progress)
            } else if importing {
                progressCard(title: "Importing…", value: nil)
            }
        }
    }

    /// A centered card showing determinate download progress or an indeterminate
    /// import spinner (matching `ImportExportView`'s busy overlay style).
    private func progressCard(title: String, value: Double?) -> some View {
        ZStack {
            Color.black.opacity(0.3).ignoresSafeArea()
            VStack(spacing: DS.Spacing.m) {
                if let value {
                    ProgressView(value: value) {
                        Text(title).font(DS.Typography.body).foregroundStyle(DS.textPrimary)
                    }
                    .progressViewStyle(.linear)
                    .tint(DS.accent)
                    .frame(width: 220)
                } else {
                    ProgressView()
                    Text(title).font(DS.Typography.body).foregroundStyle(DS.textPrimary)
                }
            }
            .dsCard()
            .fixedSize()
        }
        .transition(.opacity)
    }

    // MARK: - Import

    /// Hands a freshly downloaded package to the existing import flow, reusing
    /// `store.importPackage` (no re-implementation), then surfaces the same
    /// summary `ImportExportView` shows. The temp download is removed afterwards.
    private func runImport(_ url: URL) {
        importing = true
        Task { @MainActor in
            defer {
                importing = false
                // Clean up the temp download folder created for this file.
                try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
            }
            do {
                let outcome = try await store.importPackage(from: url)
                resultMessage = Self.message(for: outcome)
                onImported()
            } catch {
                errorMessage = Self.describe(error)
            }
        }
    }

    /// Builds the import-result summary (identical wording to `ImportExportView`).
    private static func message(for outcome: ImportOutcome) -> String {
        switch outcome {
        case .collectionReplaced:
            return "Your collection was replaced with the imported file."
        case .deckPackage(let result):
            var parts = ["\(result.found) note\(result.found == 1 ? "" : "s") found"]
            parts.append("\(result.imported) imported")
            if result.updated > 0 { parts.append("\(result.updated) updated") }
            if result.duplicate > 0 {
                parts.append("\(result.duplicate) duplicate\(result.duplicate == 1 ? "" : "s")")
            }
            return parts.joined(separator: ", ") + "."
        }
    }

    /// Extracts a human-readable message, decoding the engine's protobuf
    /// `BackendError` when present (e.g. a corrupt or wrong-version package).
    private static func describe(_ error: Error) -> String {
        if case let AnkiError.backendError(data) = error,
           let backendError = try? Anki_Backend_BackendError(serializedBytes: data),
           !backendError.message.isEmpty {
            return backendError.message
        }
        return error.localizedDescription
    }

    private var resultPresented: Binding<Bool> {
        Binding(get: { resultMessage != nil }, set: { if !$0 { resultMessage = nil } })
    }

    private var errorPresented: Binding<Bool> {
        Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
    }
}

// MARK: - Browser state

/// Observable navigation state for the shared-decks web view plus imperative
/// controls (`goBack` / `reload` / `goHome`) and the download callbacks the host
/// wires to the import flow. Kept as a `@MainActor` reference type so the web
/// view's coordinator can push updates to the SwiftUI chrome.
@MainActor
final class SharedDecksBrowser: ObservableObject {
    @Published var title = ""
    @Published var urlString = ""
    @Published var canGoBack = false
    @Published var isLoading = false
    @Published var loadProgress: Double = 0
    /// 0...1 while a deck download is in progress, `nil` otherwise.
    @Published var downloadProgress: Double?

    /// Set by the coordinator; lets the chrome buttons drive the web view.
    fileprivate weak var webView: WKWebView?

    /// Called when a deck package finishes downloading (temp file URL).
    var onPackageDownloaded: ((URL) -> Void)?
    /// Called when a download fails, with a user-facing message.
    var onDownloadFailed: ((String) -> Void)?

    var isSecure: Bool { urlString.lowercased().hasPrefix("https") }

    /// A trimmed URL for the address bar (scheme dropped, like Safari).
    var displayURL: String {
        guard let url = URL(string: urlString), let host = url.host else { return urlString }
        let path = url.path
        return path.isEmpty || path == "/" ? host : host + path
    }

    func goBack() { webView?.goBack() }
    func reload() { webView?.reload() }
    func goHome() { webView?.load(URLRequest(url: SharedDecksView.sharedDecksURL)) }
}

// MARK: - Web view

/// Hosts a plain `WKWebView` for AnkiWeb's shared decks, with a coordinator that
/// enforces the AnkiWeb host allow-list, mirrors navigation state into
/// `SharedDecksBrowser`, and converts deck-download responses into `WKDownload`s
/// routed to the import flow.
private struct SharedDecksWebView: UIViewRepresentable {
    @ObservedObject var browser: SharedDecksBrowser
    let initialURL: URL

    func makeCoordinator() -> Coordinator { Coordinator(browser: browser) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default() // persist AnkiWeb login cookies

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        browser.webView = webView

        // Observe load progress for the thin top bar. The KVO change handler is
        // `@Sendable`, so read the new value from the change (not the main-actor
        // property) and hop to the main actor to update the model.
        let model = browser
        context.coordinator.progressObservation = webView.observe(
            \.estimatedProgress, options: [.new]
        ) { _, change in
            guard let value = change.newValue else { return }
            Task { @MainActor in model.loadProgress = value }
        }

        webView.load(URLRequest(url: initialURL))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        browser.webView = webView
    }

    // MARK: - Coordinator (navigation + download delegate)

    /// `@MainActor` to match WebKit's `@MainActor` delegate requirements (this
    /// SDK imports them with `@MainActor @Sendable` completion handlers). WebKit
    /// delivers these callbacks on the main thread, so the browser model is
    /// updated directly.
    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKDownloadDelegate {
        let browser: SharedDecksBrowser
        var progressObservation: NSKeyValueObservation?
        var downloadProgressObservation: NSKeyValueObservation?
        /// The temp file the active download is being written to.
        private var destinationURL: URL?

        init(browser: SharedDecksBrowser) { self.browser = browser }

        /// AnkiWeb host allow-list, mirroring AnkiDroid's `allowedHosts`
        /// (`ankiweb.net` + subdomains, `ankiuser.net`, `ankisrs.net`). Any other
        /// host opens in the system browser instead of this deck-import web view.
        private func isAllowedHost(_ host: String?) -> Bool {
            guard let host = host?.lowercased() else { return false }
            if host == "ankiweb.net" || host.hasSuffix(".ankiweb.net") { return true }
            return host == "ankiuser.net" || host == "ankisrs.net"
        }

        // MARK: Navigation state

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            browser.isLoading = true
            syncURL(webView)
        }

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            syncURL(webView)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            browser.isLoading = false
            browser.title = webView.title ?? ""
            syncURL(webView)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            browser.isLoading = false
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: Error
        ) {
            browser.isLoading = false
        }

        /// Copies the web view's current URL / back state into the browser model.
        private func syncURL(_ webView: WKWebView) {
            browser.urlString = webView.url?.absoluteString ?? ""
            browser.canGoBack = webView.canGoBack
        }

        // MARK: Host allow-list

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
        ) {
            guard let url = navigationAction.request.url, let host = url.host else {
                decisionHandler(.allow)
                return
            }
            if isAllowedHost(host) {
                decisionHandler(.allow)
            } else {
                // Non-AnkiWeb link: open in the system browser, like AnkiDroid
                // (prevents using this deck-import view as a general browser).
                UIApplication.shared.open(url)
                decisionHandler(.cancel)
            }
        }

        // MARK: Download detection

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationResponse: WKNavigationResponse,
            decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void
        ) {
            let response = navigationResponse.response
            let isDownloadable =
                Self.isPackageResponse(response)
                || (navigationResponse.isForMainFrame && !navigationResponse.canShowMIMEType)
            decisionHandler(isDownloadable ? .download : .allow)
        }

        func webView(
            _ webView: WKWebView,
            navigationResponse: WKNavigationResponse,
            didBecome download: WKDownload
        ) {
            beginDownload(download)
        }

        func webView(
            _ webView: WKWebView,
            navigationAction: WKNavigationAction,
            didBecome download: WKDownload
        ) {
            beginDownload(download)
        }

        private func beginDownload(_ download: WKDownload) {
            download.delegate = self
            browser.downloadProgress = 0
            // Capture the model (Sendable) — the KVO handler is `@Sendable`.
            // Progress KVO can fire off the main thread, so hop back for the UI.
            let model = browser
            downloadProgressObservation = download.progress.observe(
                \.fractionCompleted, options: [.new]
            ) { _, change in
                guard let value = change.newValue else { return }
                Task { @MainActor in model.downloadProgress = value }
            }
        }

        /// Heuristic for "this response is an Anki package to import", mirroring
        /// AnkiDroid keying off the `download-deck/…` endpoint plus the attachment
        /// MIME / filename. Kept generous so both the current `svc/shared/
        /// download-deck/<id>` endpoint and any `.apkg`/`.colpkg` attachment match.
        private static func isPackageResponse(_ response: URLResponse) -> Bool {
            if let url = response.url {
                let path = url.path.lowercased()
                if path.contains("/download-deck/") || path.contains("/shared/download") { return true }
                if path.hasSuffix(".apkg") || path.hasSuffix(".colpkg") { return true }
            }
            if let http = response as? HTTPURLResponse {
                let mime = (http.mimeType ?? "").lowercased()
                if mime.contains("apkg") || mime == "application/octet-stream" || mime == "application/zip" {
                    return true
                }
                if let disposition = http.value(forHTTPHeaderField: "Content-Disposition")?.lowercased(),
                   disposition.contains("attachment"),
                   disposition.contains(".apkg") || disposition.contains(".colpkg") {
                    return true
                }
            }
            if let name = response.suggestedFilename?.lowercased() {
                if name.hasSuffix(".apkg") || name.hasSuffix(".colpkg") { return true }
            }
            return false
        }

        // MARK: WKDownloadDelegate

        func download(
            _ download: WKDownload,
            decideDestinationUsing response: URLResponse,
            suggestedFilename: String,
            completionHandler: @escaping @MainActor @Sendable (URL?) -> Void
        ) {
            let filename = Self.packageFilename(from: suggestedFilename)
            // Unique temp folder so the destination doesn't pre-exist (a
            // WKDownload requirement) and cleanup is a single directory remove.
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("shared_decks", isDirectory: true)
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            } catch {
                completionHandler(nil)
                browser.downloadProgress = nil
                browser.onDownloadFailed?(error.localizedDescription)
                return
            }
            let dest = dir.appendingPathComponent(filename)
            destinationURL = dest
            completionHandler(dest)
        }

        func downloadDidFinish(_ download: WKDownload) {
            downloadProgressObservation = nil
            browser.downloadProgress = nil
            if let url = destinationURL {
                destinationURL = nil
                browser.onPackageDownloaded?(url)
            }
        }

        func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
            downloadProgressObservation = nil
            browser.downloadProgress = nil
            destinationURL = nil
            browser.onDownloadFailed?(error.localizedDescription)
        }

        /// Ensures the download is saved with a package extension. AnkiWeb serves
        /// `.apkg`; if a name arrives without a valid deck extension we force
        /// `.apkg` (AnkiDroid does the same, coercing the guessed name).
        private static func packageFilename(from suggested: String) -> String {
            let trimmed = suggested
                .replacingOccurrences(of: "/", with: "-")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let lower = trimmed.lowercased()
            if !trimmed.isEmpty, lower.hasSuffix(".apkg") || lower.hasSuffix(".colpkg") {
                return trimmed
            }
            let base = trimmed.isEmpty ? "shared-deck" : trimmed
            return base + ".apkg"
        }
    }
}
