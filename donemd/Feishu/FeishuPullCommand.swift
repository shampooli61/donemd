import Foundation
import AppKit

/// User-facing entry point for "pull the bound Feishu doc into the current
/// document" — wired into the 飞书 command menu in `donemdApp.swift` next
/// to "同步到飞书…". Symmetric to `FeishuPushCommand`: same OAuth + HTTP
/// client construction, same NSAlert error surface, but flows the other
/// way (Feishu → local file).
///
/// Scope (v2-8 / #49):
///   - Current document is bound (`frontmatter.feishu.docToken` present)
///   - Current document is on disk (has fileURL) — the createNew path
///     for "paste a Feishu URL → make a new local file" is split off as
///     #58, blocked by v2-10 Settings panel
///
/// Unsaved-changes handling: if the document is dirty, present a
/// three-option Chinese dialog [覆盖丢弃 / 保存为副本 / 取消]. The "副本"
/// branch writes the current in-memory state to `~filename.local.md`
/// next to the bound file, so the user never loses their unsaved work.
///
/// Progress / cancellation parity with push: events go to debugLog only.
/// The full modal progress dialog with cancellation lands with #57
/// (segmented push gives "cancel" a defined semantic).
enum FeishuPullCommand {

    @MainActor
    static func run() {
        guard let document = NSDocumentController.shared.currentDocument as? DonemdDocument else {
            presentAlert(
                title: "没有可拉取的文档",
                message: "请先打开一个 .md 文件。"
            )
            return
        }

        guard let token = document.parsedDocument.frontmatter.feishu?.docToken else {
            presentAlert(
                title: "当前文档未绑定飞书",
                message: """
                这份文档的 frontmatter 没有 `feishu.doc_token` 字段，无法识别要从飞书哪份文档拉取。

                如果想新建一份本地副本（粘贴飞书 URL → 拉到本地新文件），等 v2-10 设置面板上线后从那里走（issue #58）。
                """
            )
            return
        }

        guard document.fileURL != nil else {
            presentAlert(
                title: "请先保存当前文档",
                message: "拉取会覆盖磁盘文件，所以当前文档需要先有一个保存路径（按 Cmd+S 保存）。"
            )
            return
        }

        guard let config = FeishuAppConfig.load() else {
            presentAlert(
                title: "未配置飞书应用凭证",
                message: """
                请把 client_id / client_secret / redirect_uri 填到：
                ~/Library/Application Support/Done.md/feishu-config.plist
                或设置 DONEMD_FEISHU_APP_ID 等环境变量后重启。
                """
            )
            return
        }

        // Unsaved-changes gate: ask user how to handle in-memory edits
        // before the pull blasts the body. Branches end at one of:
        //   - .proceed: keep going, in-memory state is OK to lose
        //   - .saveCopy(URL): wrote ~filename.local.md, OK to overwrite
        //   - .cancel: user backed out, return without touching anything
        switch unsavedChangesGate(document: document) {
        case .cancel:
            return
        case .proceed, .saveCopy:
            break
        }

        let oauth = FeishuOAuthClient(
            config: config,
            store: KeychainCredentialStore(),
            receiver: FeishuOAuthLoopbackReceiver(),
            opener: NSWorkspaceURLOpener()
        )
        let api = FeishuHTTPAPIClient(
            tokenProvider: {
                // Same login-on-empty-Keychain fallback as Push — see
                // FeishuPushCommand for the rationale.
                do {
                    return try await oauth.refreshIfNeeded().accessToken
                } catch FeishuOAuthClient.OAuthError.notAuthenticated {
                    return try await oauth.login().accessToken
                }
            },
            onUnauthorized: {
                try await oauth.login().accessToken
            }
        )
        let imageStage = FeishuImageDownloadStage(
            api: api, writer: document.assetsManager
        )
        let coordinator = FeishuPullCoordinator(
            apiClient: api, imageDownloadStage: imageStage
        )
        let existing = document.parsedDocument

        Task { @MainActor in
            debugLog("[pull] start: token=\(token.rawValue)")
            // #57 step5: bottom progress bar + cancel signal.
            let progressModel = document.syncProgress.start(direction: .pull)
            do {
                let result = try await coordinator.pull(
                    token: token, into: existing,
                    signal: progressModel.signal
                ) { event in
                    debugLog("[pull] progress: \(event)")
                    Task { @MainActor in progressModel.apply(pull: event) }
                }
                document.syncProgress.stop()
                let newRevision = result.updatedDocument.frontmatter.feishu?
                    .lastPulledRevision
                let oldRevision = existing.frontmatter.feishu?.lastPulledRevision
                debugLog(
                    "[pull] coordinator returned: revision="
                    + "\(newRevision.map(String.init) ?? "?"),"
                    + " warnings=\(result.warnings.count)"
                )

                // No-op pull: revision_id matches what we already have
                // on disk → Feishu side hasn't moved since the last
                // pull. Skip applyUpdatedDocumentAndSave so we don't
                // touch the dirty flag, retrigger the WebView reload,
                // or risk clobbering in-memory edits the user has
                // started since the last save. Tell the user the
                // truth: nothing changed.
                if let oldRev = oldRevision,
                   let newRev = newRevision,
                   oldRev == newRev {
                    var lines: [String] = []
                    lines.append("飞书暂无更新——文档保持原样。")
                    lines.append(
                        "飞书绑定：doxc \(token.rawValue)（revision \(newRev)）"
                    )
                    if document.isDocumentEdited {
                        lines.append("ℹ️ 你本地正在编辑的版本未受影响。")
                    }
                    presentAlert(
                        title: "飞书暂无更新",
                        message: lines.joined(separator: "\n\n")
                    )
                    return
                }

                // Layer 3 — shrink guard: pull is "remote wins", so if the
                // remote body is drastically smaller than what's on disk
                // (the #84 case: remote lost its body, only the title
                // survived), stop and make the user confirm with the real
                // numbers in front of them. Normal small edits pass
                // silently; only a would-be-disaster interrupts. A clean
                // (non-dirty) document goes through this gate too — the
                // old dirty-only gate is what let #84 through unchecked.
                let oldBlocks = existing.body.content?.count ?? 0
                let newBlocks = result.updatedDocument.body.content?.count ?? 0
                if shrinkGateTriggers(old: oldBlocks, new: newBlocks) {
                    switch shrinkGate(
                        oldBlocks: oldBlocks,
                        newBlocks: newBlocks,
                        oldDocument: existing,
                        newDocument: result.updatedDocument,
                        token: token
                    ) {
                    case .cancel:
                        debugLog("[pull] shrink gate: user cancelled (old=\(oldBlocks) new=\(newBlocks))")
                        return
                    case .proceed:
                        break
                    }
                }

                // Layer 2 — snapshot before overwrite so the pull is
                // reversible for FeishuPullSnapshotStore.undoWindow. Best
                // effort: a snapshot-save failure never blocks the pull,
                // but we won't advertise "可撤销" if it didn't land.
                var snapshotSaved = false
                if let url = document.fileURL {
                    let priorMarkdown = MarkdownEngine.serialize(document: existing)
                    snapshotSaved = FeishuPullSnapshotStore.save(
                        markdown: priorMarkdown, for: url, blockCount: oldBlocks
                    )
                }

                document.applyUpdatedDocumentAndSave(result.updatedDocument) { persistError in
                    var lines: [String] = []
                    let revision = newRevision.map(String.init) ?? "?"
                    lines.append("飞书文档已拉取到本地。")
                    lines.append("飞书绑定：doxc \(token.rawValue)（revision \(revision)）")
                    if let imageLine = imageReportSummary(result.imageReport) {
                        lines.append(imageLine)
                    }
                    if !result.warnings.isEmpty {
                        lines.append(warningSummary(result.warnings))
                    }
                    switch persistError {
                    case nil:
                        if snapshotSaved {
                            lines.append("↩️ 覆盖前已备份本地旧版本。10 分钟内可在「飞书」菜单 →「撤销上次拉取」还原。")
                        }
                    case .untitled:
                        lines.append("⚠️ 当前文档没有保存路径，正文已写入内存但未落盘。请按 Cmd+S 保存。")
                    case .saveFailed(let error):
                        lines.append("⚠️ 写盘失败：\(error.localizedDescription)\n请手动按 Cmd+S 重试。")
                    }
                    presentAlert(
                        title: "已从飞书拉取",
                        message: lines.joined(separator: "\n\n")
                    )
                }
            } catch let error as FeishuPullCoordinator.PullError {
                document.syncProgress.stop()
                debugLog("[pull] error: \(error)")
                switch error {
                case .apiFailed(let underlying):
                    presentAlert(
                        title: pullErrorTitle(underlying),
                        message: humanReadable(underlying, token: token)
                    )
                case .cancelled:
                    presentAlert(
                        title: "已取消",
                        message: "已取消拉取。本地文档未改动。"
                    )
                }
            } catch {
                document.syncProgress.stop()
                presentAlert(title: "拉取失败", message: "\(error)")
            }
        }
    }

    // MARK: - shrink gate (Layer 3, GH #85)

    /// Fraction of body blocks that may disappear in a single pull before
    /// we interrupt with a confirmation. 0.5 = "pull would delete more
    /// than half the local content" triggers the guard. Tuned as a
    /// constant so it's one place to adjust.
    private static let shrinkThreshold = 0.5

    /// Minimum local body size for the shrink gate to even consider
    /// firing. Below this, "lost 2 of 3 blocks" is noise, not a disaster
    /// — don't nag on tiny docs.
    private static let shrinkMinBlocks = 4

    /// True when a pull would shrink a non-trivial local document by more
    /// than `shrinkThreshold`. Growing or roughly-equal pulls never
    /// trigger. The #84 case (old=many, new≈1 title-only) always does.
    static func shrinkGateTriggers(old: Int, new: Int) -> Bool {
        guard old >= shrinkMinBlocks else { return false }
        guard new < old else { return false }
        let lost = Double(old - new) / Double(old)
        return lost > shrinkThreshold
    }

    private enum ShrinkOutcome {
        case proceed
        case cancel
    }

    /// The band-plays-loudest dialog: show the actual numbers, default to
    /// the safe choice (取消), and offer a diff-preview escape hatch.
    @MainActor
    private static func shrinkGate(
        oldBlocks: Int,
        newBlocks: Int,
        oldDocument: MarkdownEngine.ParsedDocument,
        newDocument: MarkdownEngine.ParsedDocument,
        token: DocToken
    ) -> ShrinkOutcome {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "拉取会大幅删减本地内容"
        alert.informativeText = """
        飞书侧这份文档只有 \(newBlocks) 个内容块，而本地有 \(oldBlocks) 个。继续拉取会用飞书版本覆盖本地，**丢掉约 \(oldBlocks - newBlocks) 个内容块**。

        这通常意味着飞书那份文档不完整（例如上次同步只上传了标题、正文没推上去）。如果不确定，先「取消」，去飞书网页确认那份文档是否完整。

        飞书绑定：doxc \(token.rawValue)
        """
        // Default (rightmost, first-added) = 取消, the safe choice.
        alert.addButton(withTitle: "取消")
        alert.addButton(withTitle: "先看看差异")
        alert.addButton(withTitle: "仍用飞书覆盖")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return .cancel
        case .alertSecondButtonReturn:
            // Show a quick text diff summary, then re-ask.
            presentDiffPreview(old: oldDocument, new: newDocument)
            return shrinkGate(
                oldBlocks: oldBlocks, newBlocks: newBlocks,
                oldDocument: oldDocument, newDocument: newDocument,
                token: token
            )
        case .alertThirdButtonReturn:
            return .proceed
        default:
            return .cancel
        }
    }

    /// Minimal "what would change" preview: first lines of local vs
    /// remote body so the user can eyeball whether the remote is real
    /// content or a broken stub. Kept text-only (no diff view dependency)
    /// — this is a safety confirmation, not the #20 diff viewer.
    @MainActor
    private static func presentDiffPreview(
        old: MarkdownEngine.ParsedDocument,
        new: MarkdownEngine.ParsedDocument
    ) {
        let oldText = MarkdownEngine.serialize(document: old)
        let newText = MarkdownEngine.serialize(document: new)
        func preview(_ s: String, _ label: String) -> String {
            let lines = s.split(separator: "\n", omittingEmptySubsequences: false)
            let head = lines.prefix(12).joined(separator: "\n")
            let more = lines.count > 12 ? "\n…（共 \(lines.count) 行）" : ""
            return "【\(label)】\n\(head)\(more)"
        }
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "本地 ↔ 飞书 内容对比"
        alert.informativeText =
            preview(oldText, "本地当前") + "\n\n" + preview(newText, "飞书版本")
        alert.addButton(withTitle: "返回")
        alert.runModal()
    }

    // MARK: - unsaved changes gate

    private enum GateOutcome {
        case proceed
        case saveCopy(URL)
        case cancel
    }

    @MainActor
    private static func unsavedChangesGate(document: DonemdDocument) -> GateOutcome {
        guard document.isDocumentEdited else { return .proceed }

        // First-pull-prompt suppression: once the user has accepted the
        // overwrite-on-pull semantics for this file (副本 or 丢弃), skip
        // the dialog on every subsequent ⌘⌥O for the same path. Default
        // becomes "discard local changes and pull" — equivalent to the
        // 丢弃并拉取 button they implicitly chose by acknowledging the
        // semantics earlier. Symmetric to FirstSavePromptCoordinator.
        if !FirstPullPromptCoordinator.shared.shouldPrompt(forFileAt: document.fileURL) {
            return .proceed
        }

        let alert = NSAlert()
        alert.messageText = "第一次从飞书拉取这份文档"
        alert.informativeText = """
        从飞书拉取会用飞书侧的内容替换本地正文。当前还有未保存的改动，要怎么处理？

        以后再拉取这份文档不再弹这个确认——除非你选「取消」。

        • 「保存为副本」把当前正在编辑的版本写到同目录的 ~filename.local.md，然后继续拉取。
        • 「丢弃并拉取」直接覆盖本地正文。
        """
        // NSAlert button order: first-added is rightmost (default).
        // We want default = 取消 (least destructive); then 保存为副本; then 丢弃并拉取.
        alert.addButton(withTitle: "取消")
        alert.addButton(withTitle: "保存为副本，再拉取")
        alert.addButton(withTitle: "丢弃并拉取")

        let outcome: GateOutcome
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            outcome = .cancel
        case .alertSecondButtonReturn:
            outcome = saveCopy(document: document)
        case .alertThirdButtonReturn:
            outcome = .proceed
        default:
            outcome = .cancel
        }

        // Mark prompted only when the user actually consented. 取消 means
        // they backed out — the next ⌘⌥O should still ask. saveCopy
        // failure (file write error) returns .cancel too; same logic
        // applies — we never told the user "OK to overwrite from now on".
        switch outcome {
        case .proceed, .saveCopy:
            FirstPullPromptCoordinator.shared.markPrompted(forFileAt: document.fileURL)
        case .cancel:
            break
        }
        return outcome
    }

    @MainActor
    private static func saveCopy(document: DonemdDocument) -> GateOutcome {
        guard let url = document.fileURL else {
            // Already gated upstream — defensive.
            return .cancel
        }
        let copyURL = copyURL(forBound: url)
        let markdown = MarkdownEngine.serialize(document: document.parsedDocument)
        do {
            try markdown.data(using: .utf8)?.write(to: copyURL, options: .atomic)
            debugLog("[pull] saved local copy → \(copyURL.path)")
            return .saveCopy(copyURL)
        } catch {
            presentAlert(
                title: "保存副本失败",
                message: "无法写入 \(copyURL.lastPathComponent)：\(error.localizedDescription)\n\n拉取已取消。"
            )
            return .cancel
        }
    }

    /// Build the `~filename.local.md` sibling URL. If that name is taken
    /// (the user already saved a copy from a previous pull), suffix with
    /// `(2)`, `(3)`, … so we never silently overwrite an old copy.
    private static func copyURL(forBound url: URL) -> URL {
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        let dir = url.deletingLastPathComponent()

        var attempt = 1
        while true {
            let suffix = attempt == 1 ? "" : " (\(attempt))"
            let name = "~\(base).local\(suffix)"
            let candidate = dir.appendingPathComponent(name)
                .appendingPathExtension(ext.isEmpty ? "md" : ext)
            if !FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            attempt += 1
        }
    }

    // MARK: - error mapping

    /// Localized title to put in the dialog's bold messageText. Stronger
    /// than push's single-title approach because the user-action-routing
    /// matters more here (404 = "you should consider unbinding"; 401 =
    /// "you'll be re-prompted to log in").
    private static func pullErrorTitle(_ error: FeishuAPIError) -> String {
        switch error {
        case .notFound: return "飞书侧找不到这份文档"
        case .unauthorized: return "飞书登录态已失效"
        case .forbidden: return "飞书拒绝访问"
        case .scopeInsufficient: return "飞书应用 OAuth 权限不足"
        case .rateLimited: return "飞书 API 限流"
        case .networkUnreachable: return "网络不可达"
        case .badRequest, .serverError, .decodeFailed: return "拉取失败"
        }
    }

    private static func humanReadable(_ error: FeishuAPIError, token: DocToken) -> String {
        switch error {
        case .unauthorized:
            return "请重新「从飞书同步」触发登录后重试。"
        case .forbidden(let message):
            let detail = message.flatMap { $0.isEmpty ? nil : "（\($0)）" } ?? ""
            return "可能需要管理员授权或重新登录扩充权限\(detail)。"
        case .scopeInsufficient(let detail):
            // Verbose Feishu message lists every scope name; we don't
            // need to repeat that — the dialog points the user at the
            // single scope they actually need for the failing call.
            // Pull is the only call site that hits this today, so
            // dropping the verbose detail in favor of a clean
            // instruction is fine. Triage detail still in debugLog.
            _ = detail
            return """
            飞书应用没有调用此接口的 OAuth 权限（错误码 99991679）。

            处理方法：到飞书开放平台 → 你的自建应用 → 「权限管理」勾选 docs:document.media:download（图片下载需要这条），重新发布版本，再点这里的「重新登录」让用户授权一次。

            完整错误细节见 `cat /tmp/donemd-debug.log`。
            """
        case .notFound:
            return """
            飞书侧找不到 doxc \(token.rawValue)。它可能已被删除，或被移到了你没权限访问的位置。

            如果想保留本地文件、解除绑定，请到 frontmatter 里删除 feishu.doc_token 字段。
            """
        case .rateLimited:
            return "请稍等几分钟再试。"
        case .badRequest(let status, let code, let msg):
            let codeStr = code.map { "code \($0)" } ?? ""
            let msgStr = msg.flatMap { $0.isEmpty ? nil : $0 } ?? ""
            let detail = [codeStr, msgStr].filter { !$0.isEmpty }.joined(separator: "，")
            return "飞书拒绝了拉取请求（HTTP \(status)\(detail.isEmpty ? "" : "，" + detail)）。重试不会修复。终端运行 `cat /tmp/donemd-debug.log` 能看到完整原始报错。"
        case .serverError(let status, _, let msg):
            let extra = msg.flatMap { $0.isEmpty ? nil : "：\($0)" } ?? ""
            return "飞书服务暂时出错（HTTP \(status)\(extra)）。稍后重试。"
        case .networkUnreachable(let detail):
            return "网络不可达：\(detail)\n\n稍后重试。"
        case .decodeFailed(let detail):
            return "飞书返回的数据无法识别：\n\(detail)"
        }
    }

    /// Human-readable summary of the image-download stage results.
    /// Returns nil when there's nothing to say (no images at all, or
    /// stage wasn't wired). Mirrors PushCommand's imageReportSummary.
    private static func imageReportSummary(_ report: FeishuImageDownloadStage.Report?) -> String? {
        guard let report else { return nil }
        let touched = report.downloadedCount > 0 || !report.failedTokens.isEmpty
        guard touched else { return nil }
        var parts: [String] = []
        if report.downloadedCount > 0 {
            parts.append("已下载 \(report.downloadedCount) 张飞书图片到本地")
        }
        if !report.failedTokens.isEmpty {
            parts.append("⚠️ \(report.failedTokens.count) 张图片下载失败，src 仍指向飞书 token——再次拉取可重试")
        }
        return parts.joined(separator: "，")
    }

    private static func warningSummary(_ warnings: [FeishuStructuralConverter.ConversionWarning]) -> String {
        let lines = warnings.map(humanReadable)
        return "拉取过程中遇到这些信息没能完整保留：\n" + lines.map { "• \($0)" }.joined(separator: "\n")
    }

    private static func humanReadable(_ warning: FeishuStructuralConverter.ConversionWarning) -> String {
        switch warning {
        case .nestedContentDroppedInPlaceholder(let blockId, let count):
            return "占位块 \(blockId) 内嵌的 \(count) 项内容被丢弃（飞书占位块在本地不可承载子内容）。"
        case .feishuInlineColorStripped(let runCount):
            return "\(runCount) 段文字带有飞书侧的字色 / 背景色，本地暂不支持文字着色（追踪：GH #59 Phase 5），文字本身已保留，颜色丢失。"
        case .tableCellBlockContentDropped(let cellCount):
            return "\(cellCount) 处表格单元格里含飞书的高亮块 / 列表 / 标题等块级内容，被压平为单元格里第一段文字（GFM 表格不支持单元格内嵌块，是架构边界——见 ADR-0007 § 已知限制）。"
        }
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
