import SwiftUI
import WebKit
import UIKit
import AnkiKit

/// Hosts one of Anki's shared web pages (the same SvelteKit pages AnkiDroid and
/// desktop Anki use — Statistics, Card Info, Deck Options, …) in a `WKWebView`,
/// backed by our Rust engine.
///
/// This mirrors AnkiDroid's `PageFragment` chain:
/// - The compiled SvelteKit app is bundled under `sveltekit/` and served through
///   a custom URL scheme (`WKURLSchemeHandler`): page routes fall back to
///   `index.html`, and `/_app/*` assets stream from the bundle.
/// - The pages talk to the backend via `fetch("/_anki/<method>", POST <protobuf>)`.
///   A small injected `fetch` shim routes those calls through a
///   `WKScriptMessageHandlerWithReply` to ``Backend/run(service:method:input:)``
///   (method name → index via ``AnkiWebMethods``). We use the message bridge
///   instead of a localhost server because `WKURLSchemeHandler` drops POST bodies.
struct AnkiWebPage: UIViewRepresentable {
    /// SvelteKit route, e.g. `"graphs"`, `"card-info/123"`, `"deck-options/1"`.
    let pagePath: String
    /// The engine handle the page's `/_anki` calls dispatch to.
    let backend: Backend
    /// Render Anki's night theme (passed as the `#night` URL fragment).
    var nightMode: Bool = false
    /// Called when the page asks the host to close (e.g. Deck Options after save).
    var onClose: (() -> Void)? = nil

    static let scheme = "ankipage"
    static let host = "app"

    func makeCoordinator() -> Coordinator { Coordinator(backend: backend) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let controller = config.userContentController

        // /_anki backend bridge: protobuf POSTs route through the reply handler.
        controller.addUserScript(WKUserScript(
            source: Self.fetchShimJS,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true,
            in: .page
        ))
        // bridgeCommand bridge: define `window.bridgeCommand` (and a global alias)
        // so the pages' UI-side commands reach the host — mirrors AnkiDroid's
        // `PageFragment.setupBridgeCommand`. Used by the graphs page
        // (`browserSearch`) and the congrats page (`congratsLearnMore`); without it
        // those calls throw "window.bridgeCommand is not a function". It reuses the
        // existing `ankiPost` handler rather than adding a second channel.
        controller.addUserScript(WKUserScript(
            source: Self.bridgeShimJS,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true,
            in: .page
        ))
        controller.addScriptMessageHandler(
            context.coordinator, contentWorld: .page, name: "ankiPost"
        )
        config.setURLSchemeHandler(context.coordinator, forURLScheme: Self.scheme)

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        // Surface the pages' `alert()` / `confirm()` dialogs — without a UIDelegate
        // they are silent no-ops in a WKWebView, which hides backend errors.
        webView.uiDelegate = context.coordinator
        context.coordinator.onClose = onClose
        load(into: webView)
        context.coordinator.loadedKey = loadKey
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.onClose = onClose
        // Reload if the requested page or theme changed.
        if context.coordinator.loadedKey != loadKey {
            load(into: webView)
            context.coordinator.loadedKey = loadKey
        }
    }

    private var loadKey: String { "\(pagePath)|\(nightMode)" }

    private func load(into webView: WKWebView) {
        let fragment = nightMode ? "#night" : ""
        guard let url = URL(string: "\(Self.scheme)://\(Self.host)/\(pagePath)\(fragment)") else { return }
        webView.load(URLRequest(url: url))
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, WKURLSchemeHandler, WKScriptMessageHandlerWithReply, WKUIDelegate {
        let backend: Backend
        var loadedKey: String = ""
        var onClose: (() -> Void)?

        init(backend: Backend) { self.backend = backend }

        // MARK: Static asset serving (GET)

        func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
            guard let url = task.request.url else {
                task.didFailWithError(URLError(.badURL)); return
            }
            var path = url.path
            if path.hasPrefix("/") { path.removeFirst() }

            // favicon: respond empty so the page doesn't error.
            if path == "favicon.ico" || path == "favicon.png" {
                respond(task, url: url, data: Data(), mime: "image/x-icon")
                return
            }

            // SvelteKit SPA: assets stream from `_app/…`; every page route falls
            // back to index.html (same as AnkiDroid's PageWebViewClient).
            let relative = path.hasPrefix("_app/") ? path : "index.html"
            guard let base = Bundle.main.resourceURL?.appendingPathComponent("sveltekit"),
                  let data = try? Data(contentsOf: base.appendingPathComponent(relative))
            else {
                task.didFailWithError(URLError(.fileDoesNotExist)); return
            }
            respond(task, url: url, data: data, mime: Self.mime(for: relative))
        }

        func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}

        private func respond(_ task: WKURLSchemeTask, url: URL, data: Data, mime: String) {
            let headers = [
                "Content-Type": mime,
                "Content-Length": String(data.count),
                "Access-Control-Allow-Origin": "*",
            ]
            guard let response = HTTPURLResponse(
                url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers
            ) else { return }
            task.didReceive(response)
            task.didReceive(data)
            task.didFinish()
        }

        private static func mime(for path: String) -> String {
            switch true {
            case path.hasSuffix(".html"): return "text/html; charset=utf-8"
            case path.hasSuffix(".mjs"), path.hasSuffix(".js"): return "text/javascript; charset=utf-8"
            case path.hasSuffix(".css"): return "text/css; charset=utf-8"
            case path.hasSuffix(".json"): return "application/json; charset=utf-8"
            case path.hasSuffix(".wasm"): return "application/wasm"
            case path.hasSuffix(".svg"): return "image/svg+xml"
            case path.hasSuffix(".png"): return "image/png"
            case path.hasSuffix(".woff2"): return "font/woff2"
            case path.hasSuffix(".woff"): return "font/woff"
            case path.hasSuffix(".ico"): return "image/x-icon"
            default: return "application/octet-stream"
            }
        }

        // MARK: /_anki backend bridge (POST)

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) async -> (Any?, String?) {
            guard let dict = message.body as? [String: Any]
            else { return (nil, "bad _anki request") }

            // bridgeCommand(command, arg) from the injected shim (fire-and-forget),
            // mirroring AnkiDroid's `PageFragment.setupBridgeCommand`.
            if let command = dict["command"] as? String {
                routeUICommand(command)
                return ("", nil)
            }

            guard let method = dict["method"] as? String
            else { return (nil, "bad _anki request") }

            // UI-side frontend methods (not backend RPCs). The deck-options page
            // posts these over /_anki: `deckOptionsReady` on mount and
            // `deckOptionsRequireClose` from its close/discard flow. Routed to the
            // host the same way AnkiDroid's `PostRequestHandler.uiMethods` does.
            switch method {
            case "deckOptionsReady", "searchInBrowser", "congratsLearnMore", "deckOptionsRequireClose":
                routeUICommand(method)
                return ("", nil)
            default:
                break
            }

            let input = Data(base64Encoded: dict["body"] as? String ?? "") ?? Data()
            guard let idx = AnkiWebMethods.index[method] else {
                return (nil, "unknown method: \(method)")
            }
            let backend = self.backend
            let service = idx.service
            let methodIndex = idx.method
            // Run the (potentially slow) backend call off the main actor.
            let outcome: (data: Data?, error: String?) = await Task.detached {
                do { return (try backend.run(service: service, method: methodIndex, input: input), nil) }
                catch { return (nil, Self.describeBackendError(error)) }
            }.value
            if let data = outcome.data {
                // A successful deck-config save closes and refreshes the presenting
                // screen, mirroring AnkiDroid's `updateDeckConfigsRaw` (undoableOp +
                // finish()). The page doesn't send `deckOptionsRequireClose` after a
                // save — the host drives the close off this RPC. We're already on the
                // main actor and `dismiss()` defers teardown, so the page still
                // receives this reply.
                if method == "updateDeckConfigs" {
                    onClose?()
                }
                return (data.base64EncodedString(), nil)
            }
            return (nil, outcome.error ?? "backend error")
        }

        /// Routes a UI-side page command (AnkiDroid `bridgeCommand` / frontend UI
        /// methods) to the host. On the Statistics / Card Info / Deck Options
        /// screens the only actionable signal is the close request; the rest
        /// (`deckOptionsReady`, `searchInBrowser`, the graphs page's
        /// `browserSearch: …`, `congratsLearnMore`, …) have no host-side action
        /// here, matching the fragments that declare no handler for them.
        private func routeUICommand(_ command: String) {
            switch command {
            case "deckOptionsRequireClose":
                onClose?()
            default:
                break
            }
        }

        /// Turns a thrown `Backend` error into a human-readable message, decoding
        /// the engine's protobuf `BackendError` when present (same as the rest of
        /// the app). Returned to the page so its `alert(...)` shows something
        /// meaningful instead of `backend error: backendError(N bytes)`. Backend
        /// `Interrupted` errors keep their `"Interrupted"` text, which the frontend
        /// special-cases (as `"500: Interrupted"`) to skip the alert.
        nonisolated static func describeBackendError(_ error: Error) -> String {
            if case let AnkiError.backendError(data) = error,
               let backendError = try? Anki_Backend_BackendError(serializedBytes: data),
               !backendError.message.isEmpty {
                return backendError.message
            }
            return error.localizedDescription
        }

        // MARK: JS dialogs (WKUIDelegate)

        // A WKWebView ignores `alert()` / `confirm()` unless a UIDelegate handles
        // them. Without this, backend errors the pages report via `alert(...)` were
        // silently swallowed and `confirm(...)` prompts always read as "cancel".

        // The completion handlers carry WebKit's UI-actor (`@MainActor`) annotation,
        // and WebKit invokes these on the main thread; the methods are `nonisolated`
        // to match the imported requirement exactly, then hop onto the main actor.

        nonisolated func webView(
            _ webView: WKWebView,
            runJavaScriptAlertPanelWithMessage message: String,
            initiatedByFrame frame: WKFrameInfo,
            completionHandler: @escaping @MainActor () -> Void
        ) {
            MainActor.assumeIsolated {
                guard let presenter = topViewController(for: webView) else {
                    completionHandler(); return
                }
                let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler() })
                presenter.present(alert, animated: true)
            }
        }

        nonisolated func webView(
            _ webView: WKWebView,
            runJavaScriptConfirmPanelWithMessage message: String,
            initiatedByFrame frame: WKFrameInfo,
            completionHandler: @escaping @MainActor (Bool) -> Void
        ) {
            MainActor.assumeIsolated {
                guard let presenter = topViewController(for: webView) else {
                    completionHandler(false); return
                }
                let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in completionHandler(false) })
                alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler(true) })
                presenter.present(alert, animated: true)
            }
        }

        /// Topmost presented controller above the WebView's window, used to host the
        /// alert / confirm dialogs.
        private func topViewController(for webView: WKWebView) -> UIViewController? {
            var top = webView.window?.rootViewController
                ?? UIApplication.shared.connectedScenes
                    .compactMap { ($0 as? UIWindowScene)?.keyWindow }
                    .first?.rootViewController
            while let presented = top?.presentedViewController {
                top = presented
            }
            return top
        }
    }

    // MARK: - Injected fetch shim

    /// Overrides `window.fetch` for `/_anki/<method>` so protobuf POSTs route
    /// through the native reply bridge (base64 over the message channel) and come
    /// back as a normal `Response`. All other fetches pass through untouched.
    private static let fetchShimJS = """
    (function () {
      const original = window.fetch.bind(window);
      function encode(buffer) {
        let binary = "";
        const bytes = new Uint8Array(buffer);
        for (let i = 0; i < bytes.length; i++) binary += String.fromCharCode(bytes[i]);
        return btoa(binary);
      }
      function decode(b64) {
        const binary = atob(b64 || "");
        const bytes = new Uint8Array(binary.length);
        for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
        return bytes;
      }
      window.fetch = async function (input, init) {
        const url = typeof input === "string" ? input : (input && input.url) || "";
        const marker = "/_anki/";
        const at = url.indexOf(marker);
        if (at !== -1) {
          const method = url.substring(at + marker.length);
          let body = (init && init.body) || (typeof input !== "string" && input ? await input.arrayBuffer() : null);
          let bodyB64 = "";
          if (body) {
            if (body instanceof ArrayBuffer) bodyB64 = encode(body);
            else if (ArrayBuffer.isView(body)) bodyB64 = encode(body.buffer.slice(body.byteOffset, body.byteOffset + body.byteLength));
            else if (typeof body === "string") bodyB64 = btoa(unescape(encodeURIComponent(body)));
          }
          try {
            const reply = await window.webkit.messageHandlers.ankiPost.postMessage({ method: method, body: bodyB64 });
            return new Response(decode(reply), { status: 200, headers: { "Content-Type": "application/binary" } });
          } catch (e) {
            // The native handler rejects with an Error whose `message` is the
            // (decoded) backend message. Put it in the body so Anki's `postRequest`
            // wrapper throws "<status>: <text>" and shows it via alert() — e.g.
            // "500: Interrupted", which the frontend special-cases.
            const text = (e && e.message != null) ? String(e.message) : String(e);
            return new Response(text, { status: 500, statusText: "error" });
          }
        }
        return original(input, init);
      };
    })();
    """

    // MARK: - Injected bridgeCommand shim

    /// Defines `window.bridgeCommand` (and a global alias) so the pages' UI-side
    /// commands reach the host, mirroring AnkiDroid's injected
    /// `bridgeCommand = function(request){ … }`. Fire-and-forget: the command name
    /// and an optional primitive argument are posted to the reused `ankiPost`
    /// handler. Without this, `window.bridgeCommand(…)` throws on the graphs page
    /// (`browserSearch`) and the congrats page (`congratsLearnMore`).
    private static let bridgeShimJS = """
    (function () {
      function bridgeCommand(command, arg) {
        try {
          const safeArg = (typeof arg === "string" || typeof arg === "number" || typeof arg === "boolean") ? arg : null;
          const reply = window.webkit.messageHandlers.ankiPost.postMessage({ command: String(command), arg: safeArg });
          if (reply && reply.catch) reply.catch(function () {});
        } catch (e) {}
      }
      window.bridgeCommand = bridgeCommand;
      globalThis.bridgeCommand = bridgeCommand;
    })();
    """
}
