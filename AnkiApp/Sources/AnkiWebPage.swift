import SwiftUI
import WebKit
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

    static let scheme = "ankipage"
    static let host = "app"

    func makeCoordinator() -> Coordinator { Coordinator(backend: backend) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let shim = WKUserScript(
            source: Self.fetchShimJS,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true,
            in: .page
        )
        config.userContentController.addUserScript(shim)
        config.userContentController.addScriptMessageHandler(
            context.coordinator, contentWorld: .page, name: "ankiPost"
        )
        config.setURLSchemeHandler(context.coordinator, forURLScheme: Self.scheme)

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        load(into: webView)
        context.coordinator.loadedKey = loadKey
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
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
    final class Coordinator: NSObject, WKURLSchemeHandler, WKScriptMessageHandlerWithReply {
        let backend: Backend
        var loadedKey: String = ""

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
            guard let dict = message.body as? [String: Any],
                  let method = dict["method"] as? String
            else { return (nil, "bad _anki request") }

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
                catch { return (nil, "backend error: \(error)") }
            }.value
            if let data = outcome.data {
                return (data.base64EncodedString(), nil)
            }
            return (nil, outcome.error ?? "backend error")
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
            return new Response(String(e), { status: 500, statusText: String(e) });
          }
        }
        return original(input, init);
      };
    })();
    """
}
