import SwiftUI
import WebKit

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
        if let url = Bundle.main.url(forResource: "mobile", withExtension: "html", subdirectory: "Web") {
            view.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else { document.message = "编辑器资源缺失，请重新构建" }
        return view
    }
    func updateUIView(_ view: WKWebView, context: Context) {
        if context.coordinator.revision != document.revision { context.coordinator.load() }
    }
    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        uiView.configuration.userContentController.removeScriptMessageHandler(forName: "donemd")
        uiView.stopLoading()
    }
    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        let document: MobileDocument
        weak var webView: WKWebView?
        var ready = false
        var revision = -1
        init(_ document: MobileDocument) { self.document = document }
        func send(_ type: String, _ payload: Any) {
            guard let data = try? JSONSerialization.data(withJSONObject: ["version": 1, "type": type, "payload": payload]),
                  let json = String(data: data, encoding: .utf8) else { return }
            webView?.evaluateJavaScript("window.donemdBridge.receive(\(json))")
        }
        func load() {
            guard ready, let data = try? JSONEncoder().encode(document.body),
                  let payload = try? JSONSerialization.jsonObject(with: data) else { return }
            revision = document.revision
            send("loadDocument", payload)
        }
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.frameInfo.isMainFrame, let text = message.body as? String,
                  let data = text.data(using: .utf8),
                  let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  envelope["version"] as? Int == 1, let type = envelope["type"] as? String else { return }
            if type == "editorReady" { ready = true; load() }
            if type == "documentChanged", let payload = envelope["payload"],
               let bodyData = try? JSONSerialization.data(withJSONObject: payload),
               let body = try? JSONDecoder().decode(TiptapNode.self, from: bodyData) { document.replaceBody(body) }
        }
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if navigationAction.navigationType == .linkActivated {
                if let url = navigationAction.request.url, ["https", "http", "mailto"].contains(url.scheme ?? "") { UIApplication.shared.open(url) }
                decisionHandler(.cancel)
            } else { decisionHandler(navigationAction.request.url?.isFileURL == true ? .allow : .cancel) }
        }
    }
}
