import SwiftUI
import WebKit

/// Nonmutating rendered output. Native draft inputs and the persistent body web view
/// remain independent; a late preview ACK can never replace a newer draft preview.
struct MobileEditorRichPreview: View {
    @ObservedObject var editor: MobileEditorController
    let type: String
    let text: String
    let language: String
    let display: Bool
    @State private var html = ""
    @State private var error: String?
    @State private var loading = false
    @State private var generation = UUID()

    private struct Request: Hashable {
        let type: String
        let text: String
        let language: String
        let display: Bool
        let identity: String
        let revision: Int
    }
    private var request: Request {
        Request(type: type, text: text, language: language, display: display,
                identity: editor.state.identity, revision: editor.state.revision)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if loading { ProgressView("正在生成预览…") }
            if let error { Text(error).font(.footnote).foregroundStyle(.secondary) }
            if !html.isEmpty {
                MobileEditorPreviewWebView(html: html)
                    .frame(minHeight: 220, idealHeight: 280)
                    .accessibilityLabel("只读内容预览")
                    .accessibilityIdentifier("native-content-preview")
            }
        }
        .task(id: request) {
            let expected = request
            guard ["code", "math", "raw"].contains(expected.type) else { return }
            let currentGeneration = UUID()
            generation = currentGeneration
            loading = true; html = ""; error = nil
            defer { if generation == currentGeneration { loading = false } }
            do { try await Task.sleep(nanoseconds: 300_000_000) }
            catch { return }
            guard !Task.isCancelled else { return }
            // SwiftUI cancels this view task on each changed draft or dismissal.
            // Never propagate that cancellation into an already-submitted bridge command:
            // an active command cancellation correctly quarantines the controller transport.
            let operation = Task { @MainActor in
                await editor.perform("preview.render", args: [
                    "type": expected.type, "text": expected.text,
                    "language": expected.language, "display": String(expected.display)
                ])
            }
            let result = await operation.value
            guard !Task.isCancelled, generation == currentGeneration, request == expected else { return }
            html = result.data?["html"] ?? ""
            error = result.data?["error"]
            if !result.success || html.isEmpty {
                error = error ?? result.message ?? "预览暂不可用，原文会保留。"
            }
        }
    }
}

/// Deliberately has no bridge, script execution, remote resources, asset handler,
/// navigation, or persistent cookies. The body editor is never recreated here.
private struct MobileEditorPreviewWebView: UIViewRepresentable {
    let html: String
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.isOpaque = false
        view.backgroundColor = .clear
        view.scrollView.backgroundColor = .clear
        return view
    }
    func updateUIView(_ view: WKWebView, context: Context) {
        guard context.coordinator.lastHTML != html else { return }
        context.coordinator.lastHTML = html
        let base = Bundle.main.url(forResource: "mobile", withExtension: "html", subdirectory: "Web")?.deletingLastPathComponent()
        context.coordinator.bundleRoot = base?.path
        let styles: String
        if let base, let files = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil, options: .skipsHiddenFiles) {
            styles = files.compactMap { $0 as? URL }.filter { $0.pathExtension == "css" }.map { "<link rel=\"stylesheet\" href=\"\($0.absoluteString)\">" }.joined()
        } else { styles = "" }
        let securedHead = """
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'none'; connect-src 'none'; style-src 'self' 'unsafe-inline' file:; font-src file: data:; img-src data:; media-src 'none'; frame-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'">
        <meta name="viewport" content="width=device-width,initial-scale=1">
        \(styles)
        <style>:root{color-scheme:light dark}body{margin:12px;font:17px -apple-system;background:transparent;color:CanvasText}pre{overflow:auto}svg,img{max-width:100%;height:auto}a{pointer-events:none}</style>
        """
        let page: String
        if let head = html.range(of: "<head(?:\\s[^>]*)?>", options: [.regularExpression, .caseInsensitive]) {
            // preview.render returns a full document: preserve it and insert the policy
            // before any of its styles/resources, rather than nesting another document.
            page = html.replacingCharacters(in: head, with: String(html[head]) + securedHead)
        } else if let root = html.range(of: "<html(?:\\s[^>]*)?>", options: [.regularExpression, .caseInsensitive]) {
            page = html.replacingCharacters(in: root, with: String(html[root]) + "<head>" + securedHead + "</head>")
        } else {
            page = "<!doctype html><html><head>" + securedHead + "</head><body>" + html + "</body></html>"
        }
        view.loadHTMLString(page, baseURL: base)
    }
    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) {
        view.stopLoading()
        view.navigationDelegate = nil
    }
    final class Coordinator: NSObject, WKNavigationDelegate {
        var lastHTML: String?
        var bundleRoot: String?
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard action.navigationType == .other, action.targetFrame?.isMainFrame != false,
                  let url = action.request.url,
                  url.absoluteString == "about:blank" || (url.isFileURL && bundleRoot.map { url.path == $0 || url.path.hasPrefix($0 + "/") } == true) else { decisionHandler(.cancel); return }
            decisionHandler(.allow)
        }
    }
}
