import SwiftUI
import WebKit

@MainActor
struct MobileWebView: UIViewRepresentable {
    @ObservedObject var document: MobileDocument
    func makeCoordinator() -> Coordinator { Coordinator(document) }
    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.add(context.coordinator, name: "donemd")
        let assets = AssetURLSchemeHandler()
        assets.assetsManager = document.assets
        config.setURLSchemeHandler(assets, forURLScheme: AssetURLSchemeHandler.scheme)
        config.allowsInlineMediaPlayback = true
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        view.scrollView.keyboardDismissMode = .interactive
        context.coordinator.webView = view
        // Attached is not the same as no editor: fail closed until editorReady installs ACK hooks.
        context.coordinator.installNotReadyProtection()
        if let url = Bundle.main.url(forResource: "mobile", withExtension: "html", subdirectory: "Web") {
            view.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else { document.message = "编辑器资源缺失，请重新构建" }
        return view
    }
    func updateUIView(_ view: WKWebView, context: Context) {
        if let command = document.outgoing, command.id != context.coordinator.lastCommand, context.coordinator.ready {
            context.coordinator.lastCommand = command.id
            context.coordinator.send(command.type, command.payload)
        }
        if context.coordinator.revision != document.revision { context.coordinator.load() }
        if context.coordinator.ready, context.coordinator.revision == document.revision { context.coordinator.sendDocumentInfo() }
    }
    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        uiView.configuration.userContentController.removeScriptMessageHandler(forName: "donemd")
        coordinator.document.editor.disconnect()
        coordinator.document.flushEditor = nil
        coordinator.document.beginEditorProtection = nil
        coordinator.document.finishEditorProtection = nil
        uiView.stopLoading()
    }
    @MainActor
    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        let document: MobileDocument
        weak var webView: WKWebView?
        var lastCommand: UUID?
        var ready = false
        var revision = -1
        private var protectionToken: String?
        private var finishingProtection = false
        private var latestSnapshotSequence = -1
        private var mayReplaceProtectedBody = false
        private var needsReconciliation = false
        private var editorBaselineSource: String?
        var protectionEvaluator: ((String) async -> Any?)?
        /// Narrow transport seam for envelope-order/dedup tests, not arbitrary JS evaluation.
        var messageSender: ((String, Any) -> Bool)?
        private var lastDocumentInfo: (source: String, identity: String)?
        func installNotReadyProtection() {
            document.editor.installTransport({ [weak self] command in
                guard let self, let data = try? JSONEncoder().encode(command),
                      let payload = try? JSONSerialization.jsonObject(with: data) else { return }
                self.send("editorCommand", payload)
            }, currentSource: { [weak document] in
                await document?.currentEditorSource()
            })
            document.editor.prepare(identity: document.fileURL.path, revision: document.revision)
            document.beginEditorProtection = { false }
            document.finishEditorProtection = { true }
        }
        init(_ document: MobileDocument) { self.document = document }
        func send(_ type: String, _ payload: Any, completion: ((Bool) -> Void)? = nil) {
            if let messageSender {
                let success = messageSender(type, payload)
                completion?(success)
                return
            }
            guard let data = try? JSONSerialization.data(withJSONObject: ["version": 1, "type": type, "payload": payload]),
                  let json = String(data: data, encoding: .utf8) else { completion?(false); return }
            guard let webView else { completion?(false); return }
            webView.evaluateJavaScript("window.donemdBridge.receive(\(json))") { _, error in
                completion?(error == nil)
            }
        }
        func sendDocumentInfo(completion: ((Bool) -> Void)? = nil) {
            let source = document.source
            let identity = document.fileURL.path
            guard lastDocumentInfo?.source != source || lastDocumentInfo?.identity != identity else {
                completion?(true)
                return
            }
            // Cache before evaluation: unrelated SwiftUI refreshes can arrive before its callback.
            lastDocumentInfo = (source, identity)
            send("documentInfo", ["source": source, "identity": identity]) { [weak self] success in
                if !success, self?.lastDocumentInfo?.source == source, self?.lastDocumentInfo?.identity == identity {
                    self?.lastDocumentInfo = nil
                }
                completion?(success)
            }
        }
        private func updateDocumentMode(from state: MobileEditorState) {
            let readOnly = !state.editable
            if document.isReadOnly != readOnly { document.isReadOnly = readOnly }
            document.composing = state.composing
        }
        func load() {
            guard ready, protectionToken == nil, !needsReconciliation, let data = try? JSONEncoder().encode(document.body),
                  let payload = try? JSONSerialization.jsonObject(with: data) else { return }
            revision = document.revision
            editorBaselineSource = document.source
            document.editor.prepare(identity: document.fileURL.path, revision: document.revision)
            // Establish identity BEFORE loadDocument emits its first state. Activate only
            // after both synchronous bridge handlers have completed successfully.
            sendDocumentInfo()
            let intendedRevision = document.revision
            send("loadDocument", ["document": payload, "revision": intendedRevision]) { [weak self] success in
                guard success, let self, self.document.revision == intendedRevision else { return }
                self.activateNativeSurfaces()
            }
        }
        private func activateNativeSurfaces() {
            let intendedRevision = document.revision
            let intendedIdentity = document.fileURL.path
            document.editor.prepare(identity: intendedIdentity, revision: intendedRevision)
            sendDocumentInfo { [weak self] success in
                guard success, let self, self.ready, self.document.revision == intendedRevision,
                      self.document.fileURL.path == intendedIdentity else { return }
                Task { @MainActor [weak self] in
                    guard let self, self.document.revision == intendedRevision else { return }
                    _ = await self.document.editor.perform("native.activate")
                }
            }
        }
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.frameInfo.isMainFrame, let text = message.body as? String,
                  let data = text.data(using: .utf8),
                  let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  envelope["version"] as? Int == 1, let type = envelope["type"] as? String else { return }
            if type == "editorState", let payload = envelope["payload"],
               let stateData = try? JSONSerialization.data(withJSONObject: payload),
               let state = try? JSONDecoder().decode(MobileEditorState.self, from: stateData) {
                let accepted = document.editor.receive(state: state)
                if accepted, state.identity == document.fileURL.path, state.revision == document.revision {
                    updateDocumentMode(from: state)
                }
            }
            if type == "editorCommandResult", let payload = envelope["payload"],
               let resultData = try? JSONSerialization.data(withJSONObject: payload),
               let result = try? JSONDecoder().decode(MobileEditorResult.self, from: resultData) {
                let accepted = document.editor.receive(result: result)
                if accepted, let state = result.state, state.identity == document.fileURL.path, state.revision == document.revision {
                    updateDocumentMode(from: state)
                }
            }
            if type == "previewImage", let payload = envelope["payload"] as? [String: String],
               let src = payload["src"], let url = URL(string: src), let name = AssetURLSchemeHandler.filename(from: url) {
                if let file = document.assets.storedFileURL(forFilename: name) { document.previewURL = file }
                else { document.message = "附件尚未下载或已丢失，请在文件 App 下载后重试。" }
            }
            if type == "compositionState" { document.composing = envelope["payload"] as? Bool ?? false }
            if type == "editingMode", let payload = envelope["payload"] as? [String: Bool] {
                let readOnly = !(payload["editable"] ?? true)
                if document.isReadOnly != readOnly { document.isReadOnly = readOnly }
            }
            if type == "editorReady" {
                ready = true; load()
                document.beginEditorProtection = { [weak self] in
                    guard let self else { return false }
                    return await self.beginProtection()
                }
                document.finishEditorProtection = { [weak self] in
                    guard let self else { return false }
                    return await self.finishProtection()
                }
                document.flushEditor = { [weak self] in
                    guard let self, let webView = self.webView else { return false }
                    return await withCheckedContinuation { continuation in
                        webView.evaluateJavaScript("window.donemdMobileSnapshot()") { value, error in
                            guard error == nil, let value = value as? [String: Any], value["composing"] as? Bool != true else { continuation.resume(returning: false); return }
                            continuation.resume(returning: self.applySnapshot(value))
                        }
                    }
                }
            }
            // Ignore queued pre-lock messages. The acquisition ACK is the authoritative final body.
            if type == "documentChanged", protectionToken == nil || finishingProtection, let payload = envelope["payload"] as? [String: Any] { _ = applySnapshot(payload) }
        }
        @MainActor
        private func evaluate(_ script: String) async -> Any? {
            if let protectionEvaluator { return await protectionEvaluator(script) }
            guard let webView else { return nil }
            return await withCheckedContinuation { continuation in
                webView.evaluateJavaScript(script) { value, error in
                    continuation.resume(returning: error == nil ? value : nil)
                }
            }
        }
        @MainActor
        func beginProtection() async -> Bool {
            guard ready, protectionToken == nil else { return false }
            let token = UUID().uuidString
            protectionToken = token
            mayReplaceProtectedBody = false
            guard let ack = await evaluate("window.donemdMobileProtection.begin('\(token)')") as? [String: Any],
                  ack["token"] as? String == token, ack["locked"] as? Bool == true,
                  ack["composing"] as? Bool == false else { return false }
            if ack["revision"] as? Int != document.revision {
                needsReconciliation = true
                mayReplaceProtectedBody = preserveMismatchedAck(ack, baseline: editorBaselineSource ?? document.source)
                return false
            }
            mayReplaceProtectedBody = applySnapshot(ack)
            return mayReplaceProtectedBody
        }
        private func preserveMismatchedAck(_ ack: [String: Any], baseline: String) -> Bool {
            guard let value = ack["body"], let data = try? JSONSerialization.data(withJSONObject: value),
                  let body = try? JSONDecoder().decode(TiptapNode.self, from: data) else { return false }
            var snapshot = MarkdownEngine.parseDocument(source: baseline)
            snapshot.body = body
            do {
                try DocumentRecoveryStore.save(MarkdownEngine.serialize(document: snapshot), for: document.fileURL, reason: "重载追赶前的编辑器正文")
                document.refreshRecovery()
                if let sequence = ack["sequence"] as? Int { latestSnapshotSequence = max(latestSnapshotSequence, sequence) }
                return true
            } catch {
                document.message = "新输入保护失败，请保留编辑器正文后重试：\(error.localizedDescription)"
                return false
            }
        }
        @MainActor
        private func pauseForSafeRetry(_ token: String) async {
            _ = await evaluate("window.donemdMobileProtection.abort('\(token)')")
            if needsReconciliation {
                _ = await evaluate("window.donemdMobileProtection.pauseUntilRetry()")
                document.message = "版本已变化，请完成当前输入后重试；编辑器草稿尚未被替换。"
            }
        }
        @MainActor
        func finishProtection() async -> Bool {
            guard let token = protectionToken else { return true }
            finishingProtection = true
            defer { protectionToken = nil; finishingProtection = false }
            guard mayReplaceProtectedBody else {
                await pauseForSafeRetry(token)
                return false
            }
            while true {
                let installedSource = document.source
                let installedBody = document.body
                let intendedRevision = document.revision
                guard let data = try? JSONEncoder().encode(installedBody),
                      let body = String(data: data, encoding: .utf8) else {
                    _ = await evaluate("window.donemdMobileProtection.abort('\(token)')")
                    return false
                }
                // Accept edits emitted after JS unlock, while sequence rejects pre-ACK messages.
                let success = await evaluate("window.donemdMobileProtection.finish('\(token)', \(body), \(intendedRevision))") as? Bool == true
                guard success else {
                    _ = await evaluate("window.donemdMobileProtection.abort('\(token)')")
                    return false
                }
                editorBaselineSource = installedSource
                if document.revision == intendedRevision {
                    revision = intendedRevision
                    needsReconciliation = false
                    activateNativeSurfaces()
                    return true
                }
                needsReconciliation = true
                mayReplaceProtectedBody = false
                // UIDocument loaded again while the finish ACK was in flight. Reacquire
                // atomically before catching up; preserve any characters typed after unlock.
                guard let ack = await evaluate("window.donemdMobileProtection.begin('\(token)')") as? [String: Any],
                      ack["token"] as? String == token, ack["locked"] as? Bool == true else {
                    await pauseForSafeRetry(token)
                    return false
                }
                // Every mismatched ACK is protected, including retry/cleanup paths.
                guard preserveMismatchedAck(ack, baseline: installedSource) else {
                    await pauseForSafeRetry(token)
                    return false
                }
                mayReplaceProtectedBody = true
                // Read the current native body on each iteration, never a cached R snapshot.
            }
        }
        @discardableResult
        func applySnapshot(_ payload: [String: Any]) -> Bool {
            guard let revision = payload["revision"] as? Int,
                  let sequence = payload["sequence"] as? Int, sequence > latestSnapshotSequence,
                  let bodyValue = payload["body"],
                  let data = try? JSONSerialization.data(withJSONObject: bodyValue),
                  let body = try? JSONDecoder().decode(TiptapNode.self, from: data) else { return false }
            guard document.applyEditorSnapshot(body, revision: revision) else { return false }
            latestSnapshotSequence = sequence
            return true
        }
        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            ready = false
            revision = -1
            lastDocumentInfo = nil
            // Snapshot sequences restart with a new JS world, not an ordinary body reload.
            latestSnapshotSequence = -1
            document.flushEditor = nil
            installNotReadyProtection()
        }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            ready = false
            document.editor.disconnect()
        }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            ready = false
            document.editor.disconnect()
        }
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            ready = false
            document.flushEditor = nil
            document.editor.disconnect()
            webView.reload()
        }
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if navigationAction.navigationType == .linkActivated {
                if let url = navigationAction.request.url, ["https", "http", "mailto"].contains(url.scheme ?? "") { UIApplication.shared.open(url) }
                decisionHandler(.cancel)
            } else { decisionHandler(navigationAction.request.url?.isFileURL == true ? .allow : .cancel) }
        }
    }
}
