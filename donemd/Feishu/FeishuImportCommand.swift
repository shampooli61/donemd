import Foundation
import AppKit

/// User-facing entry point for "open a Feishu document I don't have
/// locally yet" — wired into the 飞书 menu next to ⌘⌥S / ⌘⌥O. Symmetric
/// to FeishuPullCommand but starts from a URL instead of an existing
/// bound document.
///
/// Flow (#58):
/// 1. Prompt for a Feishu URL (NSAlert + textField).
/// 2. FeishuURLDetector parses the URL into a FeishuDocURL.
/// 3. SyncBindingResolver decides what to do with it:
///    - openExisting(url) — already in a sync root → open that file.
///    - ambiguous(urls)   — multiple copies across roots → user picks.
///    - createNew(token)  — no local copy → create an untitled
///      DonemdDocument, pull body+frontmatter into it, leave it dirty
///      so Cmd+S goes through the standard NSDocument save flow.
///    - requiresAPIResolution(url) — wiki / short link, needs API
///      round-trip we don't do yet. Surface a "暂不支持" dialog.
///
/// Untitled-window mode (per user direction 2026-05-30): when
/// createNew fires we don't pre-pick a save location — the user gets
/// a normal untitled NSDocument that they can later Cmd+S anywhere.
/// SyncRootStore.list().first becomes the NSSavePanel default at
/// save time (NSDocument default-directory bridge), so users with
/// a configured sync root still get the convenient default without
/// us hard-coding it.
enum FeishuImportCommand {

    @MainActor
    static func run() {
        guard let config = FeishuAppConfig.load() else {
            presentAlert(
                title: "未配置飞书应用凭证",
                message: """
                请到「⌘, → 飞书同步 → 飞书应用凭证」填好 App ID / Secret / Redirect URI，再回来从 URL 导入。
                """
            )
            return
        }

        guard let urlString = promptForURL() else { return }

        guard let parsed = FeishuURLDetector.parse(urlString)
            ?? FeishuURLDetector.extract(urlString) else {
            presentAlert(
                title: "URL 不识别",
                message: """
                请粘贴飞书文档的 URL（如 https://*.feishu.cn/docx/doxc_…）。当前输入：

                \(urlString.prefix(120))
                """
            )
            return
        }

        Task { @MainActor in
            let resolver = AppDelegate.feishuSyncManager.bindingResolver()
            let resolution = await resolver.resolve(parsed)
            switch resolution {
            case .openExisting(let url):
                openExistingFile(at: url)
            case .ambiguous(let urls):
                presentAmbiguousPicker(urls: urls)
            case .createNew(let token):
                await runCreateNew(token: token, originalURL: parsed.originalURL, config: config)
            case .requiresAPIResolution(let url):
                await runAPIResolution(url: url, config: config)
            }
        }
    }

    // MARK: - wiki / short URL resolution

    /// `.wiki` and `.short` FeishuDocURL kinds carry a token that
    /// doesn't directly drive `pullDocument`. Wiki nodes wrap a
    /// docx/sheet/etc. behind the scenes; short links are server-side
    /// 302 redirects we'd have to follow. v1 of this slice handles
    /// `.wiki` (the common case — the user said "URL 格式有问题" because
    /// wiki URLs were rejected); `.short` still surfaces a "暂不支持"
    /// dialog because the short-link redirect needs follow-on work.
    @MainActor
    private static func runAPIResolution(
        url: FeishuDocURL, config: FeishuAppConfig
    ) async {
        switch url.kind {
        case .docx:
            // Detector wouldn't put a docx URL on this branch, but if
            // it ever did, route it through createNew.
            await runCreateNew(
                token: DocToken(url.token),
                originalURL: url.originalURL, config: config
            )
        case .short:
            presentAlert(
                title: "暂不支持的 URL 类型",
                message: """
                这是一条飞书短链（需要服务端 302 跳转才能解析），本切片暂不实现。请在浏览器里打开短链，跳转完成后从地址栏复制 docx 或 wiki URL（含 doxc_… 或 wiki 节点 token）再粘贴。
                """
            )
        case .wiki:
            await runResolveWikiThenPull(
                wikiToken: url.token, originalURL: url.originalURL,
                config: config
            )
        }
    }

    /// Resolve a wiki node to its underlying object → if it's a docx,
    /// fall through to `runCreateNew`. Other obj_types (sheet / bitable
    /// / mindnote / file / slides) surface a "暂不支持" alert because
    /// Done.md only knows how to render docx content.
    @MainActor
    private static func runResolveWikiThenPull(
        wikiToken: String, originalURL: String, config: FeishuAppConfig
    ) async {
        let oauth = FeishuOAuthClient(
            config: config,
            store: KeychainCredentialStore(),
            receiver: FeishuOAuthLoopbackReceiver(),
            opener: NSWorkspaceURLOpener()
        )
        let api = FeishuHTTPAPIClient(
            tokenProvider: {
                do { return try await oauth.refreshIfNeeded().accessToken }
                catch FeishuOAuthClient.OAuthError.notAuthenticated {
                    return try await oauth.login().accessToken
                }
            },
            onUnauthorized: {
                try await oauth.login().accessToken
            }
        )
        debugLog("[import] resolving wiki node: token=\(wikiToken)")
        let resolution: WikiNodeResolution
        do {
            resolution = try await api.resolveWikiNode(token: wikiToken)
        } catch let error as FeishuAPIError {
            debugLog("[import] wiki resolve failed: \(error)")
            presentAlert(
                title: "wiki 节点解析失败",
                message: humanReadableWikiError(error, wikiToken: wikiToken)
            )
            return
        } catch {
            presentAlert(title: "wiki 节点解析失败", message: "\(error)")
            return
        }
        debugLog("[import] wiki node resolved: obj_token=\(resolution.objToken) obj_type=\(resolution.objType)")
        guard resolution.objType == "docx" else {
            presentAlert(
                title: "wiki 页面类型暂不支持",
                message: """
                这条 wiki 链接背后是「\(humanWikiObjType(resolution.objType))」，Done.md 当前只能拉取 docx 类型的飞书文档。

                如果你需要处理这种类型，可以先在飞书侧新建一份普通的 docx 文档，把内容复制过去再用 Done.md 同步。
                """
            )
            return
        }
        // Re-route through createNew with the resolved docx token.
        await runCreateNew(
            token: DocToken(resolution.objToken),
            originalURL: originalURL, config: config
        )
    }

    private static func humanWikiObjType(_ type: String) -> String {
        switch type {
        case "sheet": return "电子表格"
        case "bitable": return "多维表格"
        case "mindnote": return "思维笔记"
        case "slides": return "幻灯片"
        case "file": return "文件"
        case "doc": return "旧版文档（doc）"
        default: return type
        }
    }

    private static func humanReadableWikiError(
        _ error: FeishuAPIError, wikiToken: String
    ) -> String {
        switch error {
        case .notFound:
            return """
            飞书侧找不到这个 wiki 节点（token: \(wikiToken)）。可能已被删除，或被移到了你没权限访问的位置。
            """
        case .unauthorized:
            return "飞书登录态已失效，请重新触发同步登录后重试。"
        case .forbidden(let detail):
            let extra = detail.flatMap { $0.isEmpty ? nil : "（\($0)）" } ?? ""
            return "没有访问该 wiki 节点的权限\(extra)。"
        case .scopeInsufficient:
            return """
            飞书应用没有调用 wiki 接口的 OAuth 权限（错误码 99991679）。请到飞书开放平台 → 你的自建应用 → 「权限管理」勾选 wiki:wiki，重新发布版本，再让用户授权一次。
            """
        case .rateLimited:
            return "飞书 API 限流，请稍后再试。"
        case .badRequest(let status, let code, let msg):
            let codeStr = code.map { "code \($0)" } ?? ""
            let msgStr = msg.flatMap { $0.isEmpty ? nil : $0 } ?? ""
            let detail = [codeStr, msgStr].filter { !$0.isEmpty }.joined(separator: "，")
            return "飞书拒绝了请求（HTTP \(status)\(detail.isEmpty ? "" : "，" + detail)）。完整原始错误见 cat /tmp/donemd-debug.log。"
        case .serverError(let status, _, let msg):
            let extra = msg.flatMap { $0.isEmpty ? nil : "：\($0)" } ?? ""
            return "飞书服务暂时出错（HTTP \(status)\(extra)）。稍后重试。"
        case .networkUnreachable(let detail):
            return "网络不可达：\(detail)"
        case .decodeFailed(let detail):
            return "飞书返回的 wiki 节点数据无法识别：\(detail)"
        }
    }

    // MARK: - URL prompt

    @MainActor
    private static func promptForURL() -> String? {
        let alert = NSAlert()
        alert.messageText = "从 URL 导入飞书文档"
        alert.informativeText = "粘贴飞书文档的 URL（必须含 /docx/ + doxc_ token）："
        alert.addButton(withTitle: "导入")
        alert.addButton(withTitle: "取消")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        field.placeholderString = "https://*.feishu.cn/docx/doxc_…"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let raw = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return raw.isEmpty ? nil : raw
    }

    // MARK: - resolution branches

    @MainActor
    private static func openExistingFile(at url: URL) {
        NSDocumentController.shared.openDocument(
            withContentsOf: url, display: true
        ) { _, _, error in
            if let error {
                presentAlert(
                    title: "打开本地副本失败",
                    message: "\(url.path)\n\n\(error.localizedDescription)"
                )
            }
        }
    }

    @MainActor
    private static func presentAmbiguousPicker(urls: [URL]) {
        // Multiple sync roots index the same docToken. ADR-0006 says
        // priority order wins by default, but we surface the choice
        // because divergence here is almost always user error
        // (accidentally exported the same Feishu doc to two folders).
        let alert = NSAlert()
        alert.messageText = "找到多份本地副本"
        alert.informativeText = """
        以下文件在不同的同步根目录中都绑定了这份飞书文档。点击对应路径会打开该副本（默认按同步根目录优先级排）：

        \(urls.enumerated().map { "\($0 + 1). \($1.path)" }.joined(separator: "\n"))
        """
        // Up to 3 buttons natively — show the first three. If there are
        // more, the user can re-paste and pick another via Recent.
        let visible = Array(urls.prefix(3))
        for url in visible {
            alert.addButton(withTitle: url.lastPathComponent)
        }
        alert.addButton(withTitle: "取消")
        let response = alert.runModal()
        let idx = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        guard idx >= 0, idx < visible.count else { return }
        openExistingFile(at: visible[idx])
    }

    @MainActor
    private static func runCreateNew(
        token: DocToken,
        originalURL: String,
        config: FeishuAppConfig
    ) async {
        // Untitled-window flow: spin up a fresh DonemdDocument, run the
        // pull pipeline against it, leave the result in memory so Cmd+S
        // takes the user through the normal save panel.
        let oauth = FeishuOAuthClient(
            config: config,
            store: KeychainCredentialStore(),
            receiver: FeishuOAuthLoopbackReceiver(),
            opener: NSWorkspaceURLOpener()
        )
        let api = FeishuHTTPAPIClient(
            tokenProvider: {
                do { return try await oauth.refreshIfNeeded().accessToken }
                catch FeishuOAuthClient.OAuthError.notAuthenticated {
                    return try await oauth.login().accessToken
                }
            },
            onUnauthorized: {
                try await oauth.login().accessToken
            }
        )

        // Create the untitled document FIRST. AssetsManager hangs off
        // the doc, and the image download stage needs that to write
        // bytes. The doc starts empty and the user sees an empty
        // window flash; the pull then fills it in. Acceptable
        // trade-off — the alternative is to hold the document offscreen
        // until the pull completes, but then a long pull + cancel
        // would leak a never-shown window.
        let document: DonemdDocument
        do {
            let doc = try NSDocumentController.shared
                .makeUntitledDocument(ofType: "net.daringfireball.markdown")
            guard let typed = doc as? DonemdDocument else {
                presentAlert(title: "创建文档失败", message: "无法实例化 DonemdDocument。")
                return
            }
            document = typed
            NSDocumentController.shared.addDocument(document)
            document.makeWindowControllers()
            document.showWindows()
        } catch {
            presentAlert(title: "创建文档失败", message: error.localizedDescription)
            return
        }

        let imageStage = FeishuImageDownloadStage(
            api: api, writer: document.assetsManager
        )
        let coordinator = FeishuPullCoordinator(
            apiClient: api, imageDownloadStage: imageStage
        )
        let progressModel = document.syncProgress.start(direction: .pull)
        debugLog("[import] start: token=\(token.rawValue) url=\(originalURL)")
        do {
            let result = try await coordinator.pull(
                token: token, into: nil,
                docURL: URL(string: originalURL),
                signal: progressModel.signal
            ) { event in
                debugLog("[import] progress: \(event)")
                Task { @MainActor in progressModel.apply(pull: event) }
            }
            document.syncProgress.stop()
            // Hand the rebuilt body+frontmatter to the doc *in
            // memory* — Cmd+S takes the user through NSSavePanel from
            // here, with SyncRootStore's first root as the default
            // location courtesy of NSDocument's stock default-directory
            // bridge.
            document.applyUpdatedDocumentInMemory(result.updatedDocument)

            var lines: [String] = []
            let revision = result.updatedDocument.frontmatter.feishu?
                .lastPulledRevision.map(String.init) ?? "?"
            lines.append("已从飞书拉取到新窗口（未保存）。")
            lines.append("飞书绑定：doxc \(token.rawValue)（revision \(revision)）")
            if let imageLine = imageReportLine(result.imageReport) {
                lines.append(imageLine)
            }
            if !result.warnings.isEmpty {
                lines.append(warningLine(result.warnings))
            }
            lines.append("👉 按 Cmd+S 保存到本地，建议放到「飞书同步」面板里配置过的同步根目录。")
            presentAlert(
                title: "已导入飞书文档",
                message: lines.joined(separator: "\n\n")
            )
        } catch let error as FeishuPullCoordinator.PullError {
            document.syncProgress.stop()
            // Untitled doc is already on screen; user can close it
            // freely — close-without-save won't prompt because we
            // never marked it dirty (applyUpdatedDocumentInMemory was
            // never called). NSDocumentController treats it as a
            // never-saved untitled and will close silently.
            debugLog("[import] error: \(error)")
            switch error {
            case .apiFailed(let underlying):
                presentAlert(
                    title: "导入失败",
                    message: "飞书拒绝了拉取请求：\(underlying)\n\n刚才打开的空白窗口可以直接关闭（不会提示保存）。"
                )
            case .cancelled:
                presentAlert(
                    title: "已取消",
                    message: "已取消导入。刚才打开的空白窗口可以直接关闭。"
                )
            }
        } catch {
            document.syncProgress.stop()
            presentAlert(title: "导入失败", message: "\(error)")
        }
    }

    // MARK: - alert helpers

    private static func imageReportLine(_ report: FeishuImageDownloadStage.Report?) -> String? {
        guard let report else { return nil }
        let touched = report.downloadedCount > 0 || !report.failedTokens.isEmpty
        guard touched else { return nil }
        var parts: [String] = []
        if report.downloadedCount > 0 {
            parts.append("已下载 \(report.downloadedCount) 张飞书图片")
        }
        if !report.failedTokens.isEmpty {
            parts.append("⚠️ \(report.failedTokens.count) 张图片下载失败")
        }
        return parts.joined(separator: "，")
    }

    private static func warningLine(_ warnings: [FeishuStructuralConverter.ConversionWarning]) -> String {
        return "拉取过程中遇到 \(warnings.count) 处提醒（详见 cat /tmp/donemd-debug.log）"
    }

    @MainActor
    private static func presentAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.runModal()
    }
}
