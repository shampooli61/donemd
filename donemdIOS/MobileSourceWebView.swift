import SwiftUI
import WebKit

/// A separate, persistent CodeMirror instance. Keep mounted when its pane is hidden.
@MainActor
struct MobileSourceWebView: UIViewRepresentable {
    let document: MobileDocument
    let theme: MobileWritingTheme
    let fontScale: Double
    func makeCoordinator() -> Coordinator { Coordinator(document: document, theme: theme.rawValue, fontScale: fontScale) }
    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(context.coordinator, name: "donemd")
        // Apply the persisted canvas before first paint; configureMobileSource owns subsequent changes.
        let themeJSON = String(data: try! JSONEncoder().encode(theme.rawValue), encoding: .utf8)!
        configuration.userContentController.addUserScript(WKUserScript(source: "document.documentElement.dataset.mobileSource='true'; const t=\(themeJSON); if(t==='system')document.documentElement.removeAttribute('data-theme');else document.documentElement.dataset.theme=t;", injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.isOpaque = false
        view.backgroundColor = .clear
        view.scrollView.backgroundColor = .clear
        view.navigationDelegate = context.coordinator
        view.accessibilityLabel = "Markdown 源，只读，可选择复制"
        view.accessibilityIdentifier = "native-source-web"
        context.coordinator.webView = view
        context.coordinator.attach()
        context.coordinator.load()
        return view
    }
    func updateUIView(_ view: WKWebView, context: Context) {
        context.coordinator.update(theme: theme.rawValue, fontScale: fontScale)
    }
    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) {
        coordinator.detach()
        view.configuration.userContentController.removeScriptMessageHandler(forName: "donemd")
        view.stopLoading()
    }
    @MainActor
    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        let document: MobileDocument
        weak var webView: WKWebView?
        var pageReady = false
        /// Typed transport seam for configuration ACK ordering regressions.
        var messageSender: ((String, [String: Any]) -> Bool)?
        var initialReadinessReconciler: (() async -> Void)?
        private var signaledInitialConfiguration = false
        private var pageGeneration = 0
        private var desiredTheme: String
        private var fontScale: Double
        private let participantID = UUID()
        private var configurationWaiters: [Int: CheckedContinuation<Bool, Never>] = [:]
        private var configurationSequence = 0
        private var configuredIdentity = ""
        private var configuredRevision = -1
        private var sourceTimeout: Task<Void, Never>?
        init(document: MobileDocument, theme: String, fontScale: Double) {
            self.document = document; self.desiredTheme = theme; self.fontScale = fontScale
        }
        func attach() {
            let mirror = document.sourceMirror
            mirror.retry = { [weak self] in
                guard let self else { return }
                if self.pageReady { self.document.sourceMirror.push() } else { self.load() }
            }
            mirror.toggleFold = { [weak self, weak mirror] ordinal, collapse in
                guard let self, let mirror else { return }
                let identity = mirror.identity, revision = mirror.revision, sequence = mirror.sequence
                Task { @MainActor [weak self] in
                    guard let self, mirror.matches(identity: identity, revision: revision, sequence: sequence),
                          !self.document.composing,
                          let heading = self.document.editor.state.headings.first(where: { $0.id == ordinal }) else { return }
                    if heading.collapsed != collapse {
                        _ = await self.document.editor.perform("outline.toggle", args: ["id": String(ordinal)])
                    } else { mirror.setFolded(mirror.folded) }
                }
            }
            MobileThemeStore.shared.attachSource(owner: participantID) { [weak self] theme in
                guard let self, self.pageReady else { return false }
                let success = await self.configure(theme: theme.rawValue)
                if success { self.desiredTheme = theme.rawValue }
                return success
            }
        }
        func detach() {
            pageReady = false
            pageGeneration += 1
            sourceTimeout?.cancel()
            MobileThemeStore.shared.detachSource(owner: participantID)
            document.sourceMirror.disconnected()
            document.sourceMirror.retry = nil
            document.sourceMirror.toggleFold = nil
            resolveConfigurationWaiters()
        }
        func load() {
            guard let url = Bundle.main.url(forResource: "markdown-source", withExtension: "html", subdirectory: "Web") else {
                document.sourceMirror.failed("Markdown 源资源缺失，请重新构建")
                return
            }
            webView?.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
        func update(theme: String, fontScale: Double) {
            guard desiredTheme != theme || self.fontScale != fontScale else { return }
            desiredTheme = theme; self.fontScale = fontScale
            guard pageReady else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                if !(await self.configure(theme: theme)) { self.document.sourceMirror.failed() }
            }
        }
        private func send(_ type: String, _ payload: [String: Any], completion: ((Bool) -> Void)? = nil) {
            if let messageSender { completion?(messageSender(type, payload)); return }
            guard let webView, let data = try? JSONSerialization.data(withJSONObject: ["version": 1, "type": type, "payload": payload]),
                  let json = String(data: data, encoding: .utf8) else { completion?(false); return }
            webView.evaluateJavaScript("window.donemdBridge.receive(\(json))") { _, error in completion?(error == nil) }
        }
        func configure(theme: String) async -> Bool {
            guard pageReady else { return false }
            configurationSequence += 1
            let sequence = configurationSequence
            let identity = document.sourceMirror.identity
            let revision = document.sourceMirror.revision
            return await withCheckedContinuation { continuation in
                configurationWaiters[sequence] = continuation
                send("configureMobileSource", ["theme": theme, "fontScale": fontScale, "identity": identity, "revision": revision, "sequence": sequence]) { [weak self] success in
                    if !success { self?.configurationWaiters.removeValue(forKey: sequence)?.resume(returning: false) }
                }
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(5))
                    self?.configurationWaiters.removeValue(forKey: sequence)?.resume(returning: false)
                }
            }
        }
        private func resolveConfigurationWaiters() {
            let pending = configurationWaiters.values
            configurationWaiters.removeAll()
            for waiter in pending { waiter.resume(returning: false) }
        }
        private func sendSource(_ type: String, payload: [String: Any]) {
            guard pageReady else { return }
            if type == "setMarkdownSource", (configuredIdentity != document.sourceMirror.identity || configuredRevision != document.sourceMirror.revision) {
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if !(await self.configure(theme: self.desiredTheme)), self.configurationWaiters.isEmpty,
                       self.configuredRevision != self.document.sourceMirror.revision { self.document.sourceMirror.failed() }
                }
                return
            }
            var payload = payload
            if type != "setMarkdownSource" {
                payload["identity"] = document.sourceMirror.identity
                payload["revision"] = document.sourceMirror.revision
            }
            let sentIdentity = document.sourceMirror.identity
            let sentRevision = document.sourceMirror.revision
            let sentSequence = document.sourceMirror.sequence
            send(type, payload) { [weak self] success in
                guard let self, !success,
                      self.document.sourceMirror.matches(identity: sentIdentity, revision: sentRevision, sequence: sentSequence) else { return }
                self.document.sourceMirror.failed()
            }
            guard type == "setMarkdownSource", let sequence = payload["sequence"] as? Int else { return }
            sourceTimeout?.cancel()
            sourceTimeout = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled, let self, self.document.sourceMirror.sequence == sequence else { return }
                self.document.sourceMirror.failed()
            }
        }
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.frameInfo.isMainFrame, let text = message.body as? String, let data = text.data(using: .utf8),
                  let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  envelope["version"] as? Int == 1, let type = envelope["type"] as? String else { return }
            let payload = envelope["payload"] as? [String: Any] ?? [:]
            let mirror = document.sourceMirror
            switch type {
            case "editorReady":
                pageReady = true
                mirror.send = { [weak self] type, payload in self?.sendSource(type, payload: payload) }
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    guard await self.configure(theme: self.desiredTheme) else {
                        // A newer theme configure owns initialization when this one is superseded.
                        if self.configurationWaiters.isEmpty && self.configuredRevision != mirror.revision { mirror.failed() }
                        return
                    }
                }
            case "markdownSourceApplied":
                if let identity = payload["identity"] as? String, let revision = payload["revision"] as? Int,
                   let sequence = payload["sequence"] as? Int,
                   payload["success"] as? Bool == true,
                   mirror.acknowledge(identity: identity, revision: revision, sequence: sequence) { sourceTimeout?.cancel() }
            case "mobileSourceConfigured":
                receiveConfigurationAck(payload)
            case "foldToggled":
                if let ordinal = payload["ordinal"] as? Int, let collapse = payload["collapse"] as? Bool,
                   let identity = payload["identity"] as? String, let revision = payload["revision"] as? Int,
                   let sequence = payload["sequence"] as? Int {
                    mirror.receiveFold(ordinal: ordinal, collapse: collapse, identity: identity, revision: revision, sequence: sequence)
                }
            default: break
            }
        }
        /// Whichever configuration wins initialization must hand off current content itself.
        /// A superseded bootstrap waiter must not be the only owner of that handoff.
        func receiveConfigurationAck(_ payload: [String: Any]) {
            guard let sequence = payload["sequence"] as? Int,
                  let waiter = configurationWaiters.removeValue(forKey: sequence) else { return }
            let mirror = document.sourceMirror
            let valid = payload["identity"] as? String == mirror.identity && payload["revision"] as? Int == mirror.revision
            let success = valid && sequence == configurationSequence && (payload["success"] as? Bool == true)
            if success {
                configuredIdentity = mirror.identity
                configuredRevision = mirror.revision
                // Also covers theme reconciliation winning over editorReady's initial configure.
                // Advance sequence: an earlier source ACK cannot masquerade as this handoff.
                mirror.push()
                if !signaledInitialConfiguration {
                    signaledInitialConfiguration = true
                    let generation = pageGeneration
                    Task { @MainActor [weak self] in
                        guard let self, self.pageReady, self.pageGeneration == generation else { return }
                        if let reconcile = self.initialReadinessReconciler { await reconcile() }
                        else { await MobileThemeStore.shared.reconcile(using: self.document.editor) }
                    }
                }
            }
            waiter.resume(returning: success)
        }
        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            pageReady = false
            pageGeneration += 1
            signaledInitialConfiguration = false
            configuredIdentity = ""
            configuredRevision = -1
            sourceTimeout?.cancel()
            resolveConfigurationWaiters()
            document.sourceMirror.disconnected()
        }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { fail() }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { fail() }
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { fail() }
        private func fail() {
            pageReady = false
            resolveConfigurationWaiters()
            document.sourceMirror.failed()
        }
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            decisionHandler(navigationAction.navigationType != .linkActivated && navigationAction.request.url?.isFileURL == true ? .allow : .cancel)
        }
    }
}
