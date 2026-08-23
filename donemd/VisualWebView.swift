import SwiftUI
import WebKit

enum VisualBridgeError: Error {
    case webViewUnavailable
    case editorNotReady
}

/// SwiftUI wrapper around the Visual 视图 WKWebView.
///
/// Hosts:
///   - the bundled `visual.html` (Tiptap inside)
///   - a `WebViewBridge` plumbed to a `WKScriptMessageHandler` for inbound
///     messages from JS, and `evaluateJavaScript` for outbound
///   - a `WKNavigationDelegate` so we can react to load completion
///
/// Slice 2 wires one inbound type (`editorReady`) and one outbound type
/// (`loadDocument`). Slice 4+ extends the protocol; the envelope shape stays.
struct VisualWebView: NSViewRepresentable {
    /// The document owning this WebView. Read by the bridge to push content
    /// once the JS editor signals it is ready.
    let document: DonemdDocument

    /// Active writing theme's `data-theme` value (#80 S8), or nil for `.system`
    /// (CSS falls back to prefers-color-scheme). Drives the Visual code-block
    /// (hljs) + prose palette. SwiftUI re-invokes `updateNSView` on change.
    let webDataTheme: String?

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.userContentController.add(context.coordinator, name: Coordinator.scriptHandlerName)

        // Register donemd-asset:// so <img src="donemd-asset://..."> resolves
        // to bytes from the document's AssetsManager. Must be set before the
        // WKWebView is constructed; can't be added after.
        let assetHandler = AssetURLSchemeHandler()
        assetHandler.assetsManager = document.assetsManager
        config.setURLSchemeHandler(assetHandler, forURLScheme: AssetURLSchemeHandler.scheme)
        context.coordinator.assetHandler = assetHandler

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = false
        // Transparent so the tinted native canvas behind it shows through and
        // the frosted chrome / 大纲 sidebar have a color to refract (Phase 5
        // polish). The body background is also set to `transparent` in
        // visual.css; both are needed — this stops WebKit painting its own
        // white page backing, the CSS stops the document painting white.
        webView.setValue(false, forKey: "drawsBackground")
        #if DEBUG
        // macOS 14+ requires opt-in for Safari Web Inspector to attach.
        if #available(macOS 14.0, *) {
            webView.isInspectable = true
        }
        #endif
        context.coordinator.webView = webView

        loadVisualBundle(into: webView)
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        // Push the writing theme so switching from the 写作背景 menu re-tints
        // the Visual code blocks / prose live (#80 S8). Re-applied on
        // navigation didFinish for the initial load.
        context.coordinator.desiredDataTheme = webDataTheme
        context.coordinator.applyDataThemeIfLoaded()
    }

    func makeCoordinator() -> Coordinator {
        let c = Coordinator(document: document)
        c.desiredDataTheme = webDataTheme
        return c
    }

    private func loadVisualBundle(into webView: WKWebView) {
        guard let htmlURL = Bundle.main.url(
            forResource: "visual",
            withExtension: "html",
            subdirectory: "Web"
        ) else {
            assertionFailure(
                "visual.html not found at Contents/Resources/Web/visual.html. "
                + "Did the Build Web Bundle pre-build script run?"
            )
            return
        }
        webView.loadFileURL(
            htmlURL,
            allowingReadAccessTo: htmlURL.deletingLastPathComponent()
        )
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate {
        static let scriptHandlerName = "donemd"

        let bridge = WebViewBridge()
        let document: DonemdDocument
        weak var webView: WKWebView?
        // Held strongly here so the handler outlives makeNSView. WKWebView's
        // configuration also retains it, but tying ownership to the
        // Coordinator keeps the lifetime consistent with the bridge.
        var assetHandler: AssetURLSchemeHandler?

        /// Writing theme's `data-theme` value the SwiftUI layer wants applied
        /// (#80 S8). nil = `.system` → remove attribute, CSS uses
        /// prefers-color-scheme.
        var desiredDataTheme: String?
        private var pageLoaded = false

        init(document: DonemdDocument) {
            self.document = document
            super.init()
            registerBridgeHandlers()
        }

        /// Write `desiredDataTheme` onto `<html data-theme="…">` (or remove it)
        /// so visual.css switches the code-block (hljs) + prose palette. No-op
        /// until the page loads; `didFinish` re-applies after load.
        func applyDataThemeIfLoaded() {
            guard pageLoaded, let webView else { return }
            let setAttr: String
            if let theme = desiredDataTheme {
                setAttr = "document.documentElement.dataset.theme = '\(theme)';"
            } else {
                setAttr = "delete document.documentElement.dataset.theme;"
            }
            // Repaint already-rendered mermaid diagrams — mermaid bakes theme
            // colors into the SVG at render time, so a theme switch needs an
            // explicit re-render (#80 S8).
            let js = setAttr + " window.__donemdRerenderMermaid && window.__donemdRerenderMermaid();"
            webView.evaluateJavaScript(js, completionHandler: nil)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            pageLoaded = true
            applyDataThemeIfLoaded()
        }

        private func registerBridgeHandlers() {
            // When the JS-side editor finishes initializing, push the parsed
            // Tiptap document to it.
            bridge.register(type: "editorReady") { [weak self] _ in
                guard let self else { return }
                self.sendCurrentDocument()
                // Re-apply any fold state after the (re)load repopulates the
                // doc, so a reloaded Visual pane catches up to Swift's set.
                self.document.resendFoldStateIfNeeded()
            }
            // JS-initiated image paste / drop. Bytes come in as base64;
            // reply with the donemd-asset:// URL or an error string.
            bridge.register(type: "importImage") { [weak self] envelope in
                self?.handleImportImage(envelope.payload)
            }
            // #77: click a document image → native QuickLook full-screen
            // preview. JS sends the image's `donemd-asset://` src; we resolve
            // it to a disk file and hand it to QLPreviewPanel.
            bridge.register(type: "previewImage") { [weak self] envelope in
                self?.handlePreviewImage(envelope.payload)
            }
            // Single-click a link in the Visual editor → open it natively.
            // JS forwards the raw href; we classify (web URL vs local file) and
            // hand it to NSWorkspace. See LinkTarget + handleOpenLink.
            bridge.register(type: "openLink") { [weak self] envelope in
                self?.handleOpenLink(envelope.payload)
            }

            // JS edit happened. Two responsibilities:
            //   1. Mark the NSDocument dirty so Cmd+S actually proceeds
            //      through save(to:) instead of being short-circuited by
            //      NSDocument's "nothing to save" check.
            //   2. Pull current state, serialize, and push to the
            //      Markdown 源 pane so the right side mirrors edits in
            //      real time. JS already coalesces 'update' events to
            //      one rAF tick, so this fires at most ~60Hz.
            bridge.register(type: "documentChanged") { [weak self] _ in
                guard let self else { return }
                DispatchQueue.main.async {
                    self.document.updateChangeCount(.changeDone)
                    self.document.syncFromVisualToSource()
                }
            }

            // #78 大纲 sidebar: JS re-extracts the heading tree on every edit
            // (~300ms debounce) and on document open, and ships it here. Parse
            // into OutlineHeading and hand to the document's OutlineStore.
            bridge.register(type: "outlineChanged") { [weak self] envelope in
                self?.handleOutlineChanged(envelope.payload)
            }

            // #79 scrollspy: as the user scrolls the Visual pane, JS reports the
            // ordinal of the heading currently at the top of the viewport so the
            // 大纲 sidebar auto-highlights it. Payload: `{ index: int | null }`.
            bridge.register(type: "activeHeadingChanged") { [weak self] envelope in
                self?.handleActiveHeadingChanged(envelope.payload)
            }

            // S9 M2: the Visual pane knows which formulas KaTeX can't render
            // (its math NodeViews already ran renderMath). It ships the raw
            // LaTeX of the broken ones here; we forward them to the source pane
            // so it can red-flag the matching text (see DonemdDocument).
            bridge.register(type: "badMathFormulas") { [weak self] envelope in
                self?.handleBadMathFormulas(envelope.payload)
            }

            // 标题折叠 (heading fold): the user clicked a chevron in the Visual
            // pane. Report the desired next state to the document (single source
            // of truth), which re-broadcasts `applyFold` to both panes. This
            // coordinator never folds locally — it waits for that echo.
            bridge.register(type: "foldToggled") { [weak self] envelope in
                self?.handleFoldToggled(envelope.payload)
            }

            // Block drag handle: dragging a FOLDED heading moved its whole
            // section, renumbering heading ordinals. JS ships the recomputed
            // collapsed set; we replace the authoritative set wholesale and
            // re-broadcast so the source pane is renumbered to match.
            bridge.register(type: "foldReplace") { [weak self] envelope in
                self?.handleFoldReplace(envelope.payload)
            }

            // Phase 3 #63: JS bubble-menu "AI ▾" → 润色. The payload carries
            // the selection + surrounding paragraph text the JS side extracted
            // from the live ProseMirror selection (Swift has no selection
            // accessor). We build the prompt, stream from the Provider, and
            // forward tokens / the final parsed node back to JS.
            bridge.register(type: "aiCommand") { [weak self] envelope in
                self?.handleAICommand(envelope.payload)
            }
            // ESC / click-outside in JS → cancel the in-flight stream silently.
            bridge.register(type: "aiCancel") { [weak self] _ in
                guard let self else { return }
                DispatchQueue.main.async { self.streamCoordinator?.cancel() }
            }
            // Failure toast 「重试」 → re-issue the same prompt + selection.
            bridge.register(type: "aiRetry") { [weak self] envelope in
                self?.handleAIRetry(envelope.payload)
            }
            // Failure toast 「打开 Provider 设置」(401/403) → open Settings.
            bridge.register(type: "aiOpenSettings") { _ in
                DispatchQueue.main.async {
                    debugLog("[ai] aiOpenSettings received → opening Settings")
                    Self.openSettings()
                }
            }
            // S6 free-prompt provider dropdown: JS asks which providers are
            // configured (have a usable key / are intrinsically reachable).
            // Reply lists only those + marks the default, so the dropdown never
            // offers an unusable entry.
            bridge.register(type: "aiProvidersQuery") { [weak self] envelope in
                self?.handleProvidersQuery(envelope.payload)
            }

            // Hand this coordinator to the document so app-level commands
            // (Cmd+Shift+I → InsertImageCommand) can route insertions back
            // into the right WebView.
            document.attachVisualCoordinator(self)
        }

        // MARK: Inbound: AI command (Phase 3 #63)

        /// Lazily-built M4 coordinator. Its sink pushes bridge envelopes to the
        /// JS decoration layer (M5). Built on first use so it captures `self`
        /// after init completes.
        private var streamCoordinator: StreamCoordinator?

        @MainActor
        private func makeStreamCoordinator() -> StreamCoordinator {
            StreamCoordinator(sink: .init(
                onStart: { [weak self] streamId in
                    self?.send(envelopeOfType: "aiStreamStart", payload: .object(["streamId": .string(streamId)]))
                    AppDelegate.aiProviderManager.setInFlight(true)
                },
                onToken: { [weak self] streamId, text in
                    self?.send(envelopeOfType: "aiStreamToken",
                               payload: .object(["streamId": .string(streamId), "text": .string(text)]))
                },
                onComplete: { [weak self] streamId, nodeJSON in
                    self?.send(envelopeOfType: "aiStreamComplete",
                               payload: .object(["streamId": .string(streamId), "node": nodeJSON]))
                    AppDelegate.aiProviderManager.setInFlight(false)
                },
                onError: { [weak self] streamId, error in
                    self?.send(envelopeOfType: "aiStreamError",
                               payload: .object([
                                   "streamId": .string(streamId),
                                   "message": .string(error.message),
                                   "canOpenSettings": .bool(error.canOpenSettings),
                               ]))
                    AppDelegate.aiProviderManager.setInFlight(false)
                },
                onBusy: { [weak self] in
                    // A concurrent request while one is in flight — flash the
                    // existing spinner / "正在进行中" hint (PRD 27).
                    self?.send(envelopeOfType: "aiStreamBusy", payload: .object([:]))
                },
                onDegrade: { [weak self] streamId in
                    // 8K guard rebuilt the prompt selection-only (PRD 60).
                    self?.send(envelopeOfType: "aiStreamDegrade",
                               payload: .object(["streamId": .string(streamId)]))
                },
                onNotApplicable: { [weak self] streamId, message in
                    // Command declined (转表格 不适合) — keep the selection,
                    // just toast (real-machine feedback #2).
                    self?.send(envelopeOfType: "aiStreamNotApplicable",
                               payload: .object(["streamId": .string(streamId),
                                                 "message": .string(message)]))
                    AppDelegate.aiProviderManager.setInFlight(false)
                }
            ))
        }

        /// Open the Settings window. This app has no `WindowGroup` — only a
        /// `Settings {}` scene + NSDocument windows. `sendAction(to: nil)`
        /// fails here, and the SwiftUI-injected Settings menu item isn't
        /// findable by action *name* (an earlier search missed it). But ⌘,
        /// works (user-confirmed), so we find that exact menu item by its key
        /// equivalent (",", Command) — language- and action-name-independent —
        /// and trigger it the way a click would. Used by the AI failure toast
        /// 「打开 Provider 设置」 and the status badge.
        @MainActor
        static func openSettings() {
            NSApp.activate(ignoringOtherApps: true)
            DispatchQueue.main.async {
                if let item = findSettingsMenuItem(), let menu = item.menu {
                    debugLog("[ai] openSettings: triggering '\(item.title)' via ⌘, menu item")
                    menu.performActionForItem(at: menu.index(of: item))
                    return
                }
                let handled = NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                debugLog("[ai] openSettings: no ⌘, menu item; sendAction handled=\(handled)")
            }
        }

        /// Find the Settings menu item by its ⌘, key equivalent — robust to
        /// localization and to whatever action SwiftUI wires it to. Recurses
        /// into submenus.
        @MainActor
        private static func findSettingsMenuItem() -> NSMenuItem? {
            func search(_ menu: NSMenu) -> NSMenuItem? {
                for item in menu.items {
                    if item.keyEquivalent == ","
                        && item.keyEquivalentModifierMask.contains(.command) {
                        return item
                    }
                    if let sub = item.submenu, let found = search(sub) { return found }
                }
                return nil
            }
            guard let mainMenu = NSApp.mainMenu else {
                debugLog("[ai] openSettings: NSApp.mainMenu is nil")
                return nil
            }
            return search(mainMenu)
        }

        @MainActor
        private func handleAICommand(_ payload: JSONValue) {
            guard
                case .object(let dict) = payload,
                case .string(let streamId) = dict["streamId"] ?? .null
            else {
                debugLog("[ai] aiCommand: missing streamId")
                return
            }
            func str(_ key: String) -> String? {
                if case .string(let v) = dict[key] ?? .null, !v.isEmpty { return v }
                return nil
            }
            // Block arrays the JS side extracted (document order). S4: up to 3
            // each side; the builder slices to the active contextRange.
            func strArray(_ key: String) -> [String] {
                if case .array(let items) = dict[key] ?? .null {
                    return items.compactMap { if case .string(let v) = $0 { return v } else { return nil } }
                }
                return []
            }

            // Map dict["command"] (+ optional arg) to the AICommand. Unknown
            // kinds fall back to polish so a stale JS bundle never dead-ends.
            let kind = str("command") ?? "polish"
            let arg = str("arg")
            guard let command = Self.aiCommand(kind: kind, arg: arg) else {
                debugLog("[ai] aiCommand: unknown command kind '\(kind)'")
                return
            }

            // 生成类 (inputOnly, S6): no text selection — the typed topic /
            // prompt arrives in `arg` and becomes the builder's `selection`.
            // Everything else transforms an actual selection, which must exist.
            let selection: String
            if command.contextScope == .inputOnly {
                selection = arg ?? ""
            } else {
                guard let sel = str("selection") else {
                    debugLog("[ai] aiCommand: missing selection for \(kind)")
                    return
                }
                selection = sel
            }
            guard !selection.isEmpty else {
                debugLog("[ai] aiCommand: empty input for \(kind)")
                return
            }

            // 续写 needs the whole document; serialize the current doc lazily.
            let fullDocument = command.contextScope == .wholeDocument
                ? document.currentBodyMarkdown()
                : nil

            let context = SelectionContext(
                selection: selection,
                paragraph: str("paragraph") ?? selection,
                beforeBlocks: strArray("before"),
                afterBlocks: strArray("after"),
                fullDocument: fullDocument
            )

            let manager = AppDelegate.aiProviderManager
            // Free-prompt's slash entry can override the provider (PRD: only
            // that entry exposes a Provider dropdown). Falls back to default.
            let provider: AIProvider = {
                if let raw = str("provider"), let p = AIProvider(rawValue: raw) { return p }
                return manager.registry.defaultProvider
            }()
            // Not configured → tell JS to surface onboarding (S2: just error;
            // S8 wires the real onboarding sheet trigger).
            guard manager.registry.isConfigured(provider) else {
                send(envelopeOfType: "aiStreamError",
                     payload: .object(["streamId": .string(streamId),
                                       "message": .string("尚未配置 AI Provider，请在设置中配置")]))
                return
            }

            let coordinator = streamCoordinator ?? makeStreamCoordinator()
            streamCoordinator = coordinator
            coordinator.start(
                command: command,
                context: context,
                contextRange: manager.registry.contextRange,
                client: manager.registry.client(for: provider),
                model: manager.registry.selectedModel(for: provider),
                provider: provider,
                streamId: streamId
            )
        }

        /// Map a JS command kind (+ optional arg for parameterized commands)
        /// to the Swift `AICommand`. Kept in one place so the bridge contract
        /// is auditable. Returns nil for unrecognized kinds.
        private static func aiCommand(kind: String, arg: String?) -> AICommand? {
            switch kind {
            case "polish": return .polish
            case "formal": return .formal
            case "colloquial": return .colloquial
            case "simplify": return .simplify
            case "customRewrite": return .customRewrite(intent: arg ?? "")
            case "translateToEnglish": return .translateToEnglish
            case "translateToChinese": return .translateToChinese
            case "translateTo": return .translateTo(language: arg ?? "英文")
            case "summarize": return .summarize
            case "expand": return .expand
            case "outline": return .outline
            case "toTable": return .toTable
            case "continueWriting": return .continueWriting
            case "writeOutline": return .writeOutline(topic: arg ?? "")
            case "expandTopic": return .expandTopic(topic: arg ?? "")
            case "freePrompt": return .freePrompt(prompt: arg ?? "")
            default: return nil
            }
        }

        /// Reply to the S6 free-prompt provider dropdown query with the list of
        /// configured providers (raw id + display name) + which is default, so
        /// JS only ever offers usable entries.
        @MainActor
        private func handleProvidersQuery(_ payload: JSONValue) {
            guard
                case .object(let dict) = payload,
                case .string(let requestId) = dict["requestId"] ?? .null
            else {
                debugLog("[ai] aiProvidersQuery: missing requestId")
                return
            }
            let registry = AppDelegate.aiProviderManager.registry
            let configured = AIProvider.allCases.filter { registry.isConfigured($0) }
            let items: [JSONValue] = configured.map {
                .object(["id": .string($0.rawValue), "name": .string($0.displayName)])
            }
            send(envelopeOfType: "aiProvidersReply", payload: .object([
                "requestId": .string(requestId),
                "providers": .array(items),
                "default": .string(registry.defaultProvider.rawValue),
            ]))
        }

        @MainActor
        private func handleAIRetry(_ payload: JSONValue) {
            guard
                case .object(let dict) = payload,
                case .string(let streamId) = dict["streamId"] ?? .null
            else {
                debugLog("[ai] aiRetry: missing streamId")
                return
            }
            // Re-issue the last request verbatim (PRD 26) — coordinator holds
            // the retained command + selection + client + model.
            streamCoordinator?.retry(streamId: streamId)
        }

        // MARK: Inbound: outline (#78)

        /// Parse an `outlineChanged` payload (`{ headings: [{level,text,index,id}] }`)
        /// into `[OutlineHeading]` and update the document's OutlineStore. The
        /// store publishes on the main thread itself, so no hop needed here.
        private func handleOutlineChanged(_ payload: JSONValue) {
            guard
                case .object(let dict) = payload,
                case .array(let items) = dict["headings"] ?? .null
            else {
                document.outlineStore.update([])
                return
            }
            let headings: [OutlineHeading] = items.compactMap { item in
                guard case .object(let h) = item else { return nil }
                let level: Int
                if case .integer(let l) = h["level"] ?? .null { level = l }
                else if case .double(let l) = h["level"] ?? .null { level = Int(l) }
                else { level = 1 }
                let index: Int
                if case .integer(let i) = h["index"] ?? .null { index = i }
                else if case .double(let i) = h["index"] ?? .null { index = Int(i) }
                else { return nil }
                let text: String
                if case .string(let t) = h["text"] ?? .null { text = t } else { text = "" }
                return OutlineHeading(index: index, level: level, text: text)
            }
            document.outlineStore.update(headings)
        }

        /// Parse a `badMathFormulas` payload (`{ latex: [string] }`) and forward
        /// the list to the document, which relays it to the source pane for
        /// red-flagging (S9 M2). Empty / missing → clear all flags.
        private func handleBadMathFormulas(_ payload: JSONValue) {
            var latexes: [String] = []
            if case .object(let dict) = payload,
               case .array(let items) = dict["latex"] ?? .null {
                latexes = items.compactMap {
                    if case .string(let s) = $0 { return s }
                    return nil
                }
            }
            DispatchQueue.main.async { [weak self] in
                self?.document.setBadMathFormulas(latexes)
            }
        }

        /// Parse a `foldToggled` payload (`{ ordinal: int, collapse: bool }`)
        /// and hand it to the document. The document updates its authoritative
        /// collapsed set and re-broadcasts `applyFold` to both panes — this pane
        /// folds only when that echo arrives (anti-loop). Same shape the source
        /// pane sends.
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

        /// Parse a `foldReplace` payload (`{ collapsed: [int] }`) — the full
        /// recomputed collapsed-ordinal set after a folded-heading section drag
        /// renumbered the headings. Replace the document's set wholesale; it
        /// re-broadcasts `applyFold` so both panes land on the new numbering.
        private func handleFoldReplace(_ payload: JSONValue) {
            guard case .object(let dict) = payload,
                  case .array(let items)? = dict["collapsed"] else { return }
            let ordinals: [Int] = items.compactMap { value in
                switch value {
                case .integer(let i): return i
                case .double(let d): return Int(d)
                default: return nil
                }
            }
            DispatchQueue.main.async { [weak self] in
                self?.document.setFoldSet(ordinals: ordinals)
            }
        }

        /// Parse an `activeHeadingChanged` payload (`{ index: int | null }`) and
        /// update the store's scrollspy highlight (#79). A `null` / missing
        /// index means the viewport is above the first heading → no highlight.
        private func handleActiveHeadingChanged(_ payload: JSONValue) {
            guard case .object(let dict) = payload else {
                document.outlineStore.setActive(nil)
                return
            }
            switch dict["index"] ?? .null {
            case .integer(let i): document.outlineStore.setActive(i)
            case .double(let d): document.outlineStore.setActive(Int(d))
            default: document.outlineStore.setActive(nil)
            }
        }

        // MARK: Inbound: importImage

        private func handleImportImage(_ payload: JSONValue) {
            guard
                case .object(let dict) = payload,
                case .string(let requestId) = dict["requestId"] ?? .null
            else {
                debugLog("[image] importImage: missing requestId in payload")
                return
            }
            guard
                case .string(let mime) = dict["mime"] ?? .null,
                case .string(let base64) = dict["base64"] ?? .null,
                let bytes = Data(base64Encoded: base64)
            else {
                sendImageImportedReply(
                    requestId: requestId,
                    success: false,
                    error: "invalid importImage payload"
                )
                return
            }

            do {
                let imported = try document.assetsManager.importImage(data: bytes, mimeType: mime)
                sendImageImportedReply(
                    requestId: requestId,
                    success: true,
                    assetURL: imported.assetURL.absoluteString,
                    markdownPath: imported.markdownPath
                )
            } catch {
                sendImageImportedReply(
                    requestId: requestId,
                    success: false,
                    error: String(describing: error)
                )
            }
        }

        /// #77: resolve the clicked image's `donemd-asset://<file>` src to a
        /// disk URL and open it in the native QuickLook panel. Non-asset srcs
        /// (e.g. remote http images, should they ever appear) are ignored —
        /// QuickLook previews local files, and Done.md images are always local
        /// assets.
        private func handlePreviewImage(_ payload: JSONValue) {
            guard
                case .object(let dict) = payload,
                case .string(let src) = dict["src"] ?? .null
            else {
                debugLog("[image] previewImage: missing src")
                return
            }
            guard let url = URL(string: src),
                  let filename = AssetURLSchemeHandler.filename(from: url) else {
                debugLog("[image] previewImage: not a donemd-asset src: \(src)")
                return
            }
            guard let fileURL = document.assetsManager.storedFileURL(forFilename: filename) else {
                debugLog("[image] previewImage: no stored asset \(filename)")
                return
            }
            DispatchQueue.main.async {
                ImagePreviewController.shared.preview(url: fileURL)
            }
        }

        /// Open a link the user single-clicked in the Visual editor. Web URLs
        /// (http/https/mailto) go to the system default handler; local file
        /// paths are resolved against the document's directory and opened by
        /// their default app. Dangerous schemes (javascript:/data:/…) and
        /// in-page anchors are ignored. `.app` bundles and executable scripts
        /// are revealed in Finder rather than launched, so a link inside an
        /// untrusted document can't run a program on a single click.
        private func handleOpenLink(_ payload: JSONValue) {
            guard
                case .object(let dict) = payload,
                case .string(let href) = dict["href"] ?? .null
            else {
                debugLog("[link] openLink: missing href")
                return
            }

            // Feishu placeholder cards (video / board / bitable / sheet /
            // mindnote / attachment) carry an internal `feishu://<type>/<token>`
            // reference, not a navigable web URL — `LinkTarget.classify` rejects
            // it. The referenced object lives *inside* the bound Feishu doc, so
            // "在飞书中编辑" opens that parent document, where the user finds the
            // block in context. This is display-only: the on-disk magic-comment
            // `url` stays the stable internal reference (round-trip intact).
            if href.hasPrefix("feishu://") {
                if let docURL = document.parsedDocument.frontmatter.feishu?.docURL {
                    DispatchQueue.main.async {
                        NSWorkspace.shared.open(docURL)
                    }
                } else {
                    debugLog("[link] openLink: feishu placeholder click but document has no bound doc URL")
                    NSSound.beep()
                }
                return
            }

            switch LinkTarget.classify(href) {
            case .reject:
                debugLog("[link] openLink: rejected href: \(href)")

            case .web(let url):
                DispatchQueue.main.async {
                    NSWorkspace.shared.open(url)
                }

            case .localPath(let path, let mayFallBackToWeb):
                guard let fileURL = resolveLocalPath(path) else {
                    // Relative path but the document has never been saved, so
                    // there's no base directory to resolve against.
                    debugLog("[link] openLink: cannot resolve relative path (unsaved doc): \(path)")
                    NSSound.beep()
                    return
                }
                if FileManager.default.fileExists(atPath: fileURL.path) {
                    DispatchQueue.main.async {
                        if Self.shouldRevealRatherThanLaunch(fileURL) {
                            NSWorkspace.shared.activateFileViewerSelecting([fileURL])
                        } else {
                            NSWorkspace.shared.open(fileURL)
                        }
                    }
                } else if mayFallBackToWeb, let webURL = URL(string: "https://\(path)") {
                    // Ambiguous schemeless token (e.g. `example.com`) that names
                    // no local file → treat it as a web address.
                    DispatchQueue.main.async {
                        NSWorkspace.shared.open(webURL)
                    }
                } else {
                    debugLog("[link] openLink: local file not found: \(fileURL.path)")
                    NSSound.beep()
                }
            }
        }

        /// Resolve a (possibly `~`-prefixed or relative) path from a link into
        /// an absolute file URL. Relative paths are joined onto the document's
        /// directory; if the document has no `fileURL` (never saved) a relative
        /// path can't be resolved and this returns nil.
        private func resolveLocalPath(_ path: String) -> URL? {
            if path.hasPrefix("/") {
                return URL(fileURLWithPath: path)
            }
            if path.hasPrefix("~") {
                return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            }
            guard let baseDir = document.fileURL?.deletingLastPathComponent() else {
                return nil
            }
            return URL(fileURLWithPath: path, relativeTo: baseDir).standardizedFileURL
        }

        /// True when a file should be revealed in Finder instead of launched:
        /// `.app` bundles and executable scripts. Opening these on a single
        /// click would let an untrusted document run code, so we surface them
        /// to the user instead of executing.
        private static func shouldRevealRatherThanLaunch(_ url: URL) -> Bool {
            let ext = url.pathExtension.lowercased()
            let dangerousExtensions: Set<String> = [
                "app", "command", "sh", "bash", "zsh",
                "scpt", "applescript", "workflow", "action",
                "shortcut", "terminal", "tool", "pkg",
            ]
            if dangerousExtensions.contains(ext) { return true }
            // Extension-less files that are marked executable (e.g. a Unix
            // script with a shebang and +x) — reveal rather than run.
            if ext.isEmpty, FileManager.default.isExecutableFile(atPath: url.path) {
                return true
            }
            return false
        }

        private func sendImageImportedReply(
            requestId: String,
            success: Bool,
            assetURL: String? = nil,
            markdownPath: String? = nil,
            error: String? = nil
        ) {
            var payload: [String: JSONValue] = [
                "requestId": .string(requestId),
                "success": .bool(success),
            ]
            if let assetURL { payload["assetURL"] = .string(assetURL) }
            if let markdownPath { payload["markdownPath"] = .string(markdownPath) }
            if let error { payload["error"] = .string(error) }
            send(envelopeOfType: "imageImported", payload: .object(payload))
        }

        // MARK: Outbound: send a single envelope

        /// Encode an envelope and push it to JS via `evaluateJavaScript`.
        /// JSON is a syntactic subset of JS object literals, so splicing the
        /// encoded envelope directly into the call site is safe.
        func send(envelopeOfType type: String, payload: JSONValue) {
            let envelope = BridgeEnvelope(type: type, payload: payload)
            let json: String
            do {
                json = try bridge.encode(envelope)
            } catch {
                debugLog("[bridge] failed to encode \(type): \(error)")
                return
            }
            webView?.evaluateJavaScript("window.donemdBridge.receive(\(json));") { _, error in
                if let error = error {
                    debugLog("[bridge] evaluateJavaScript \(type) failed: \(error)")
                }
            }
        }

        private func sendCurrentDocument() {
            // TiptapNode → JSONValue (round-trip through JSON encoder).
            let payload: JSONValue
            do {
                let docData = try JSONEncoder().encode(document.tiptapDocument)
                payload = try JSONDecoder().decode(JSONValue.self, from: docData)
            } catch {
                debugLog("[bridge] failed to encode document: \(error)")
                return
            }
            send(envelopeOfType: "loadDocument", payload: payload)
        }

        // MARK: Inbound pull: fetch current Tiptap state from JS

        /// Push the document's current Tiptap state to the JS-side editor.
        /// Used after an external-modification revert so the WebView reflects
        /// the freshly-read disk contents instead of the stale in-memory doc.
        func pushDocumentFromSwift() {
            sendCurrentDocument()
        }

        /// Ask the JS side for its current Tiptap document JSON. Used by
        /// `DonemdDocument.save(to:...)` to grab the latest in-editor state
        /// before serializing to disk.
        func fetchCurrentDocumentState(completion: @escaping (Result<TiptapNode, Error>) -> Void) {
            guard let webView = webView else {
                completion(.failure(VisualBridgeError.webViewUnavailable))
                return
            }
            // window.donemdEditor.getJSON() returns the ProseMirror doc JSON.
            // We stringify on the JS side so evaluateJavaScript ships back a
            // String we can decode directly.
            let js = """
                (function() {
                  if (window.donemdEditor && typeof window.donemdEditor.getJSON === 'function') {
                    return JSON.stringify(window.donemdEditor.getJSON());
                  }
                  return null;
                })()
                """
            webView.evaluateJavaScript(js) { result, error in
                if let error = error {
                    completion(.failure(error))
                    return
                }
                guard let json = result as? String else {
                    completion(.failure(VisualBridgeError.editorNotReady))
                    return
                }
                do {
                    let doc = try JSONDecoder().decode(TiptapNode.self, from: Data(json.utf8))
                    completion(.success(doc))
                } catch {
                    completion(.failure(error))
                }
            }
        }

        // MARK: WKUIDelegate
        // WKWebView ignores window.alert / confirm / prompt by default; these
        // forward them to native NSAlert dialogs so JS-side prompts (e.g. the
        // Cmd+K link input) actually appear.

        func webView(
            _ webView: WKWebView,
            runJavaScriptAlertPanelWithMessage message: String,
            initiatedByFrame frame: WKFrameInfo,
            completionHandler: @escaping () -> Void
        ) {
            let alert = NSAlert()
            alert.messageText = message
            alert.addButton(withTitle: "好的")
            alert.runModal()
            completionHandler()
        }

        func webView(
            _ webView: WKWebView,
            runJavaScriptConfirmPanelWithMessage message: String,
            initiatedByFrame frame: WKFrameInfo,
            completionHandler: @escaping (Bool) -> Void
        ) {
            let alert = NSAlert()
            alert.messageText = message
            alert.addButton(withTitle: "好的")
            alert.addButton(withTitle: "取消")
            completionHandler(alert.runModal() == .alertFirstButtonReturn)
        }

        func webView(
            _ webView: WKWebView,
            runJavaScriptTextInputPanelWithPrompt prompt: String,
            defaultText: String?,
            initiatedByFrame frame: WKFrameInfo,
            completionHandler: @escaping (String?) -> Void
        ) {
            let alert = NSAlert()
            alert.messageText = prompt
            alert.addButton(withTitle: "好的")
            alert.addButton(withTitle: "取消")

            let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
            textField.stringValue = defaultText ?? ""
            alert.accessoryView = textField
            alert.window.initialFirstResponder = textField

            let response = alert.runModal()
            completionHandler(response == .alertFirstButtonReturn ? textField.stringValue : nil)
        }

        // MARK: WKScriptMessageHandler

        func userContentController(
            _ controller: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            // JS posts: window.webkit.messageHandlers.donemd.postMessage(jsonString)
            guard let body = message.body as? String,
                  let data = body.data(using: .utf8) else {
                debugLog("[donemd-bridge] ignoring non-string body: \(message.body)")
                return
            }
            do {
                try bridge.dispatch(rawJSON: data)
            } catch {
                debugLog("[donemd-bridge] dispatch error: \(error)")
            }
        }
    }
}
