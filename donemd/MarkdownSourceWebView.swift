import SwiftUI
import WebKit

/// SwiftUI wrapper around the right-pane CodeMirror WebView.
///
/// Phase 1 is read-only: it displays whatever Markdown source Swift pushes
/// at it via the `setMarkdownSource` bridge message. Phase 5 (#10 → bidi)
/// will flip the editor side back on and route reverse edits.
struct MarkdownSourceWebView: NSViewRepresentable {
    /// The document this pane belongs to. Read on `editorReady` to push the
    /// initial serialized markdown; subsequent updates come from the
    /// document's syncFromVisualToSource() pipeline.
    let document: DonemdDocument

    /// Active writing theme's `data-theme` value (#80 S8), or nil for `.system`
    /// (CSS then falls back to prefers-color-scheme). SwiftUI re-invokes
    /// `updateNSView` when this changes, so switching themes re-tints live.
    let webDataTheme: String?

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.userContentController.add(context.coordinator, name: Coordinator.scriptHandlerName)

        // The same donemd-asset:// scheme is registered here too so any
        // future image rendering on the source pane (Slice 11 already covered
        // the Visual side) doesn't fall over.
        let assetHandler = AssetURLSchemeHandler()
        assetHandler.assetsManager = document.assetsManager
        config.setURLSchemeHandler(assetHandler, forURLScheme: AssetURLSchemeHandler.scheme)
        context.coordinator.assetHandler = assetHandler

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = false
        // Transparent so the tinted native canvas shows through (Phase 5
        // polish) — matches VisualWebView. Body background set to transparent
        // in markdown-source.css.
        webView.setValue(false, forKey: "drawsBackground")
        context.coordinator.webView = webView

        loadBundle(into: webView)
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        // Push the current theme so switching from the 写作背景 menu re-tints
        // this pane live. Also re-applied on navigation didFinish for the
        // initial load (updateNSView may run before the page is ready).
        context.coordinator.desiredDataTheme = webDataTheme
        context.coordinator.applyDataThemeIfLoaded()
    }

    func makeCoordinator() -> Coordinator {
        let c = Coordinator(document: document)
        c.desiredDataTheme = webDataTheme
        return c
    }

    private func loadBundle(into webView: WKWebView) {
        guard let htmlURL = Bundle.main.url(
            forResource: "markdown-source",
            withExtension: "html",
            subdirectory: "Web"
        ) else {
            assertionFailure(
                "markdown-source.html not found at Contents/Resources/Web/markdown-source.html. "
                + "Did the Build Web Bundle pre-build script run both entries?"
            )
            return
        }
        webView.loadFileURL(
            htmlURL,
            allowingReadAccessTo: htmlURL.deletingLastPathComponent()
        )
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        static let scriptHandlerName = "donemd"

        let bridge = WebViewBridge()
        let document: DonemdDocument
        weak var webView: WKWebView?
        var assetHandler: AssetURLSchemeHandler?

        /// The `data-theme` value the SwiftUI layer wants applied (#80 S8).
        /// nil = `.system` → remove the attribute so CSS uses prefers-color-scheme.
        var desiredDataTheme: String?
        /// Set once the page's `didFinish` fires; guards `applyDataThemeIfLoaded`
        /// from evaluating JS against a not-yet-loaded document.
        private var pageLoaded = false

        init(document: DonemdDocument) {
            self.document = document
            super.init()
            registerBridgeHandlers()
        }

        /// Write `desiredDataTheme` onto `<html data-theme="…">` (or remove it),
        /// so the source-pane CSS switches syntax palettes. No-op until the page
        /// has loaded; `webView(_:didFinish:)` calls this after load.
        func applyDataThemeIfLoaded() {
            guard pageLoaded, let webView else { return }
            let js: String
            if let theme = desiredDataTheme {
                js = "document.documentElement.dataset.theme = '\(theme)';"
            } else {
                js = "delete document.documentElement.dataset.theme;"
            }
            webView.evaluateJavaScript(js, completionHandler: nil)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            pageLoaded = true
            applyDataThemeIfLoaded()
        }

        private func registerBridgeHandlers() {
            // Source pane is ready — give the document the handle and push
            // the current serialized markdown so the pane shows real content
            // immediately (not blank until the user starts typing).
            bridge.register(type: "editorReady") { [weak self] _ in
                guard let self else { return }
                self.document.attachMarkdownSourceCoordinator(self)
                DispatchQueue.main.async {
                    self.document.pushCurrentMarkdownToSource()
                    // Re-apply any fold state after the (re)load repopulates the
                    // doc, so a reloaded source pane catches up to Swift's set.
                    self.document.resendFoldStateIfNeeded()
                }
            }

            // 标题折叠 (heading fold): the user clicked a fold gutter marker in
            // the source pane. Report it to the document (single source of
            // truth); it re-broadcasts `applyFold` to both panes. This pane
            // folds only on that echo — the `fromSwift`-tagged apply on the JS
            // side is what actually collapses lines (anti-loop invariant).
            bridge.register(type: "foldToggled") { [weak self] envelope in
                self?.handleFoldToggled(envelope.payload)
            }
        }

        /// Parse a `foldToggled` payload (`{ ordinal: int, collapse: bool }`)
        /// from the source pane and forward to the document. Mirrors the Visual
        /// coordinator's handler — both panes speak the same message.
        private func handleFoldToggled(_ payload: JSONValue) {
            guard case .object(let dict) = payload else { return }
            let ordinal: Int
            switch dict["ordinal"] ?? .null {
            case .integer(let i): ordinal = i
            case .double(let d): ordinal = Int(d)
            default: return
            }
            let collapse: Bool
            if case .bool(let b) = dict["collapse"] ?? .null { collapse = b } else { return }
            DispatchQueue.main.async { [weak self] in
                self?.document.setFold(ordinal: ordinal, collapsed: collapse)
            }
        }

        /// Broadcast the authoritative collapsed-ordinal set into the source
        /// pane (#heading-fold). The JS side diffs it against what's currently
        /// folded and dispatches the minimal fold/unfold effects, tagged so it
        /// doesn't echo back. Empty list unfolds everything.
        func sendApplyFold(ordinals: [Int]) {
            let envelope = BridgeEnvelope(
                type: "applyFold",
                payload: .object(["collapsed": .array(ordinals.map { .integer($0) })])
            )
            let json: String
            do {
                json = try bridge.encode(envelope)
            } catch {
                debugLog("[source] failed to encode applyFold: \(error)")
                return
            }
            webView?.evaluateJavaScript("window.donemdBridge.receive(\(json));") { _, error in
                if let error = error {
                    debugLog("[source] evaluateJavaScript applyFold failed: \(error)")
                }
            }
        }

        /// Push a fresh serialized Markdown string into the CodeMirror view.
        /// JSON is a syntactic subset of JS object literals, so splicing the
        /// encoded envelope directly into the call site is safe.
        func sendMarkdownSource(_ markdown: String) {
            let envelope = BridgeEnvelope(
                type: "setMarkdownSource",
                payload: .object(["text": .string(markdown)])
            )
            let json: String
            do {
                json = try bridge.encode(envelope)
            } catch {
                debugLog("[source] failed to encode setMarkdownSource: \(error)")
                return
            }
            webView?.evaluateJavaScript("window.donemdBridge.receive(\(json));") { _, error in
                if let error = error {
                    debugLog("[source] evaluateJavaScript setMarkdownSource failed: \(error)")
                }
            }
        }

        /// Scroll the CodeMirror view to the Nth Markdown heading (#79). The
        /// source-side JS counts `#`-prefixed lines in document order to match
        /// HeadingExtractor's ordinal.
        func sendScrollToHeading(index: Int, smooth: Bool = true) {
            let envelope = BridgeEnvelope(
                type: "scrollToHeading",
                payload: .object(["index": .integer(index), "smooth": .bool(smooth)])
            )
            let json: String
            do {
                json = try bridge.encode(envelope)
            } catch {
                debugLog("[source] failed to encode scrollToHeading: \(error)")
                return
            }
            webView?.evaluateJavaScript("window.donemdBridge.receive(\(json));") { _, error in
                if let error = error {
                    debugLog("[source] evaluateJavaScript scrollToHeading failed: \(error)")
                }
            }
        }

        /// Send the list of broken-formula LaTeX strings (S9 M2). The source
        /// pane matches each verbatim against the document text and red-flags
        /// the ranges. Empty list clears all flags.
        func sendBadMathFormulas(_ latexes: [String]) {
            let envelope = BridgeEnvelope(
                type: "badMathFormulas",
                payload: .object(["latex": .array(latexes.map { .string($0) })])
            )
            let json: String
            do {
                json = try bridge.encode(envelope)
            } catch {
                debugLog("[source] failed to encode badMathFormulas: \(error)")
                return
            }
            webView?.evaluateJavaScript("window.donemdBridge.receive(\(json));") { _, error in
                if let error = error {
                    debugLog("[source] evaluateJavaScript badMathFormulas failed: \(error)")
                }
            }
        }

        // MARK: WKScriptMessageHandler

        func userContentController(
            _ controller: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard let body = message.body as? String,
                  let data = body.data(using: .utf8) else {
                return
            }
            do {
                try bridge.dispatch(rawJSON: data)
            } catch {
                debugLog("[source] bridge dispatch error: \(error)")
            }
        }
    }
}
