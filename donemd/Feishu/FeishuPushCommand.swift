import Foundation
import AppKit

/// User-facing entry point for "push the current document to Feishu" —
/// wired into the 飞书 command menu in `donemdApp.swift`. Constructs the
/// real OAuth client + HTTP API client + image stage and runs the
/// PushCoordinator pipeline, surfacing every PushError case as a
/// localized NSAlert.
///
/// Step4 lite progress events arrive via the coordinator's onProgress
/// callback and currently land in `debugLog` only — the modal progress
/// dialog with cancellation lands with #57 (segmented push). For now
/// the UX is: user clicks the menu → OAuth (if needed) → push runs
/// (Task on main actor, blocks the menu via NSAlert at the end) → result
/// dialog appears.
///
/// Until v2-10 ships the real Settings → 飞书 panel for login state
/// management, the OAuth login is triggered implicitly here on the first
/// API call that needs an access_token; the user sees the system browser
/// open without an explicit "log in first" step.
enum FeishuPushCommand {

    @MainActor
    static func run() {
        guard let document = NSDocumentController.shared.currentDocument as? DonemdDocument else {
            presentAlert(
                title: "没有可推送的文档",
                message: "请先打开一个 .md 文件。"
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

        let oauth = FeishuOAuthClient(
            config: config,
            store: KeychainCredentialStore(),
            receiver: FeishuOAuthLoopbackReceiver(),
            opener: NSWorkspaceURLOpener()
        )

        let api = FeishuHTTPAPIClient(
            tokenProvider: {
                // Try the cached refresh path first. If we've never logged
                // in (Keychain is empty — fresh install, after 调试 →
                // 飞书登出, or after rotating the App Secret on the Feishu
                // backend) refreshIfNeeded throws notAuthenticated; fall
                // through to a real login() so the very first push goes
                // straight through OAuth instead of bouncing through
                // sendWithRetry's misleading "网络不可达" error path.
                do {
                    return try await oauth.refreshIfNeeded().accessToken
                } catch FeishuOAuthClient.OAuthError.notAuthenticated {
                    return try await oauth.login().accessToken
                }
            },
            onUnauthorized: {
                // Server returned 401 on a previously-valid token (revoked,
                // expired beyond refresh window). Force a fresh login.
                try await oauth.login().accessToken
            }
        )

        let imageStage = FeishuImageUploadStage(
            api: api,
            reader: AssetsManagerAssetReader(manager: document.assetsManager)
        )
        let coordinator = FeishuPushCoordinator(
            apiClient: api,
            imageUploadStage: imageStage
        )
        let snapshot = document.parsedDocument
        let title = document.fileURL?
            .deletingPathExtension().lastPathComponent ?? "Untitled"

        Task { @MainActor in
            await runPushWithSkipRetry(
                document: document,
                coordinator: coordinator,
                title: title,
                attempt: 1
            )
        }
    }

    /// One push attempt + the placeholderMissingOnFeishu skip-and-retry
    /// branch. `attempt == 1` is the user-initiated push; `attempt == 2`
    /// is the automatic retry that runs after the user clicked 「跳过 →
    /// 继续推送」 and we removed the missing placeholders locally. We
    /// cap at 2 — if the retry hits the same case again (Feishu
    /// independently deleted yet another placeholder between the two
    /// attempts) the user gets a normal error dialog and can decide
    /// what to do next, rather than us looping silently.
    @MainActor
    private static func runPushWithSkipRetry(
        document: DonemdDocument,
        coordinator: FeishuPushCoordinator,
        title: String,
        attempt: Int,
        forceOverwrite: Bool = false
    ) async {
        let snapshot = document.parsedDocument
        // #57 step5 progress bar: spin up a model for this attempt
        // (the skip-and-retry recursion creates a fresh one for the
        // retry attempt — its lifecycle is per-call). Cleared in
        // every exit path below so the bar disappears whether we
        // succeed, fail, or cancel.
        let progressModel = document.syncProgress.start(direction: .push)
        do {
            let result = try await coordinator.push(
                snapshot, title: title, parentToken: nil,
                signal: progressModel.signal,
                forceOverwrite: forceOverwrite
            ) { event in
                debugLog("[push] progress: \(event)")
                Task { @MainActor in progressModel.apply(push: event) }
            }
            document.syncProgress.stop()
            let wasNewDoc = snapshot.frontmatter.feishu?.docToken == nil
            let token = result.updatedDocument.frontmatter.feishu?.docToken?.rawValue ?? "(?)"
            let imageLine = imageReportSummary(result.imageReport)

            // Persist the updated frontmatter (now carrying the
            // doc_token + last_pushed_at) immediately so the next
            // sync can recognize the binding. Otherwise we'd have to
            // ask the user to Cmd+S, and any window-close / app-quit
            // before that would lose the token, causing a duplicate
            // Feishu doc on the next push.
            document.applyUpdatedFrontmatterAndSave(
                result.updatedDocument.frontmatter
            ) { persistError in
                let alertTitle = wasNewDoc ? "已创建飞书文档" : "已同步到飞书"
                var lines: [String] = []
                if wasNewDoc {
                    lines.append("飞书侧已创建新文档：\(title)")
                } else {
                    lines.append("文档「\(title)」的正文已更新到飞书。")
                    // #57 step4 title sync re-enabled. If the PATCH
                    // succeeded, no extra line. If it failed, surface
                    // a soft warning so the user knows the title on
                    // Feishu is stale.
                    if let failure = result.titleSyncFailure {
                        lines.append("ℹ️ 文档标题同步飞书时被拒（\(humanReadable(failure))）。正文已成功同步——飞书侧的标题保持原样。")
                    }
                }
                if !imageLine.isEmpty {
                    lines.append(imageLine)
                }
                lines.append("文档绑定：doxc \(token)")
                if attempt > 1 {
                    lines.append("ℹ️ 上一次推送时检测到飞书侧已删除部分占位块，已按你的选择从本地剔除并继续推送。")
                }
                switch persistError {
                case nil:
                    lines.append("飞书绑定信息已写入本地文件 frontmatter。")
                case .untitled:
                    lines.append("⚠️ 当前文档还没保存到磁盘，请按 Cmd+S 保存以记住飞书绑定。")
                case .saveFailed(let error):
                    lines.append("⚠️ 自动保存失败：\(error.localizedDescription)\n请手动按 Cmd+S 保存，否则下次同步会重复创建飞书文档。")
                }
                presentAlert(
                    title: alertTitle,
                    message: lines.joined(separator: "\n\n")
                )
            }
        } catch let error as FeishuPushCoordinator.PushError {
            document.syncProgress.stop()
            // Always log the raw error to Console — every PushError
            // case carries strictly more detail than the dialog shows.
            // When users report "sync failed" the Console log is the
            // first thing to ask for.
            debugLog("[push] error: \(error)")
            switch error {
            case .partialSuccess(let orphan, let underlying):
                // The doc exists on Feishu but never received content.
                // Persist the token immediately so the next retry
                // doesn't double-create — this is the most dangerous
                // path to lose the binding.
                var frontmatter = document.parsedDocument.frontmatter
                var feishu = frontmatter.feishu ?? FeishuFrontmatter()
                feishu.docToken = orphan
                frontmatter.feishu = feishu
                if frontmatter.feishuOriginalIndex == nil {
                    frontmatter.feishuOriginalIndex = frontmatter.userFields.count
                }
                frontmatter.hasFence = true
                document.applyUpdatedFrontmatterAndSave(frontmatter) { persistError in
                    var msg = """
                    飞书侧已创建文档，但内容写入失败：
                    \(humanReadable(underlying))


                    """
                    switch persistError {
                    case nil:
                        msg += "飞书绑定已写入本地文件。再次「同步到飞书」会接着完成内容写入，不会重复创建文档。"
                    case .untitled:
                        msg += "⚠️ 当前文档还没保存到磁盘。请立刻按 Cmd+S 保存，否则下次同步会重复创建飞书文档。"
                    case .saveFailed(let error):
                        msg += "⚠️ 飞书绑定保存失败：\(error.localizedDescription)\n请手动按 Cmd+S，否则下次同步会重复创建文档。"
                    }
                    presentAlert(title: "同步未完成", message: msg)
                }
            case .apiFailed(let underlying):
                presentAlert(
                    title: "同步失败",
                    message: humanReadable(underlying)
                )
            case .placeholderIndexMismatch(let missingFromBody, let missingFromIndex):
                // step3.1: frontmatter index ↔ body actual placeholder
                // sets diverge. The frontmatter side is authoritative,
                // so "missing from body" is the dangerous direction —
                // pushing as-is would silently delete those Feishu-side
                // blocks along with their realtime data.
                var lines: [String] = []
                if !missingFromBody.isEmpty {
                    lines.append(
                        "frontmatter 索引提到但正文找不到（\(missingFromBody.count) 个）："
                        + missingFromBody.prefix(3).joined(separator: ", ")
                        + (missingFromBody.count > 3 ? "…" : "")
                    )
                    lines.append("→ 推送会从飞书侧删除这些块（含其实时协作数据）。已中止。")
                }
                if !missingFromIndex.isEmpty {
                    lines.append(
                        "正文有但 frontmatter 索引缺失（\(missingFromIndex.count) 个）："
                        + missingFromIndex.prefix(3).joined(separator: ", ")
                        + (missingFromIndex.count > 3 ? "…" : "")
                    )
                }
                presentAlert(
                    title: "占位块结构损坏：frontmatter 与正文不一致",
                    message: """
                    \(lines.joined(separator: "\n\n"))

                    建议：从飞书重新拉取（pull）覆盖本地，或撤销手动改动。修复后再推送。
                    """
                )
            case .containsPlaceholderBlocks(let blockIds):
                // Legacy stop-ship dialog — now only reachable for
                // unbound docs containing placeholders (segmented push
                // requires a Feishu-side preflight, which an unbound
                // doc has no counterpart for). #58 createNew lifts this.
                let count = blockIds.count
                let preview = blockIds.prefix(3).joined(separator: ", ")
                let suffix = count > 3 ? "（共 \(count) 个）" : ""
                presentAlert(
                    title: "暂不能推送：未绑定文档含飞书独有块",
                    message: """
                    检测到 \(count) 个飞书独有块（电子表格 / 画板 / 思维笔记 / 多维表格 / 嵌入资源）：
                    \(preview)\(suffix)

                    这些块只能从飞书拉取下来才有意义——本地新建的「占位块 magic comment」没有对应的飞书侧实体。先到飞书创建文档 + 这些块，再粘贴 URL 到 Done.md（issue #58）。
                    """
                )
            case .placeholderMissingOnFeishu(let blockIds):
                await handleMissingOnFeishu(
                    blockIds: blockIds,
                    document: document,
                    coordinator: coordinator,
                    title: title,
                    attempt: attempt
                )
            case .placeholderRemovedLocally(let blockIds):
                let preview = blockIds.prefix(3).joined(separator: ", ")
                let suffix = blockIds.count > 3 ? "（共 \(blockIds.count) 个）" : ""
                presentAlert(
                    title: "本地已删除部分占位块（飞书侧仍存在）",
                    message: """
                    飞书侧引用但本地正文找不到的占位块：
                    \(preview)\(suffix)

                    建议：从飞书重新拉取（⌘⌥O）覆盖本地，或在本地恢复占位块的 magic comment。修复后再推送。
                    """
                )
            case .placeholderOrderMismatch(let local, let remote):
                presentAlert(
                    title: "占位块顺序与飞书不一致",
                    message: """
                    本地占位块顺序与飞书侧不同——飞书 API 没有「移动块」接口，无法直接重排。

                    本地顺序：\(local.prefix(5).joined(separator: " → "))\(local.count > 5 ? " …" : "")
                    飞书顺序：\(remote.prefix(5).joined(separator: " → "))\(remote.count > 5 ? " …" : "")

                    建议：从飞书重新拉取（⌘⌥O），让本地顺序跟飞书对齐后再推送。
                    """
                )
            case .feishuRevisionConflict(let localRev, let remoteRev):
                // #51 v2-9b: Feishu side moved between our last pull
                // and now. Three-button dialog — see helper for the
                // full copy. The "拉取最新版" branch routes through
                // FeishuPullCommand.run() so the user gets the same
                // unsaved-changes gate as ⌘⌥O.
                await handleRevisionConflict(
                    document: document,
                    coordinator: coordinator,
                    title: title,
                    localRevision: localRev,
                    remoteRevision: remoteRev
                )
            case .bodyVerificationFailed(let intended, let remote, let createdToken):
                // Layer 1 (GH #84 / #85): push reported success but a
                // re-read found the remote body (near-)empty. The doc is
                // NOT marked synced. If this push minted a fresh doc,
                // persist its token first (same double-create hazard as
                // partialSuccess), THEN show the critical alert.
                if let createdToken {
                    var frontmatter = document.parsedDocument.frontmatter
                    var feishu = frontmatter.feishu ?? FeishuFrontmatter()
                    feishu.docToken = createdToken
                    frontmatter.feishu = feishu
                    if frontmatter.feishuOriginalIndex == nil {
                        frontmatter.feishuOriginalIndex = frontmatter.userFields.count
                    }
                    frontmatter.hasFence = true
                    await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                        document.applyUpdatedFrontmatterAndSave(frontmatter) { _ in
                            cont.resume()
                        }
                    }
                }
                presentBodyVerificationFailedAlert(
                    document: document,
                    token: createdToken ?? document.parsedDocument.frontmatter.feishu?.docToken,
                    intendedBlocks: intended,
                    remoteBlocks: remote
                )
            case .cancelled(let completed, let total):
                // #57 step5 user cancellation. The doc may be in a
                // partial state on Feishu side — segmented push
                // can't roll back, so we tell the user honestly.
                let msg: String
                if total == 0 {
                    msg = "已取消推送。飞书侧未发生改动。"
                } else if completed == 0 {
                    msg = "已取消推送。飞书侧未发生改动（在第一段开始前取消）。"
                } else if completed >= total {
                    msg = "已取消推送，但所有 \(total) 段实际都已完成 — 飞书侧已是最新版本。"
                } else {
                    msg = """
                    已取消推送。已完成 \(completed) / \(total) 段，飞书侧处于半完成状态——再次「同步到飞书」会从飞书的当前状态出发完成剩余段。
                    """
                }
                presentAlert(title: "已取消", message: msg)
            case .segmentFailed(let completedBefore, let totalSegments,
                                let attempted, let underlying):
                // The dangerous case: by the time this fires, Feishu
                // side has been mutated and is in an inconsistent
                // state. Surface as a *critical* alert (red icon) so
                // the user immediately knows this isn't a routine
                // "try again later" — they need to either retry now
                // (the next push restarts from Feishu's current state)
                // or restore from Feishu's document history.
                presentSegmentFailedAlert(
                    document: document,
                    token: document.parsedDocument.frontmatter.feishu?.docToken,
                    completedBefore: completedBefore,
                    totalSegments: totalSegments,
                    attemptedSegmentIndex: attempted,
                    underlying: underlying
                )
            }
        } catch {
            document.syncProgress.stop()
            presentAlert(title: "推送失败", message: "\(error)")
        }
    }

    /// Drive the placeholderMissingOnFeishu recovery flow. Show a
    /// three-button dialog [取消 / 跳过并继续推送 / 重试推送]; on 「跳过」
    /// strip the missing placeholders from the local body + frontmatter
    /// index, persist, and run push once more (capped at attempt == 2
    /// so we don't loop if Feishu deletes another placeholder
    /// concurrently). On 「重试推送」 just re-enter the push pipeline
    /// without local changes — useful if the user thinks they can fix
    /// the Feishu side themselves before retrying.
    /// #51 v2-9b: handle PushError.feishuRevisionConflict.
    ///
    /// Three-option dialog. Per user direction (downgraded path), we
    /// don't pull "last editor + time" metadata — that would need a
    /// new `drive:drive` scope and force every existing user to
    /// re-login. The dialog tells the user enough to decide:
    ///
    ///   - 「拉取最新版到本地」 → FeishuPullCommand.run() runs the
    ///     same flow as ⌘⌥O, including the unsaved-changes gate.
    ///     User can then merge their edits manually + re-push.
    ///   - 「仍然覆盖」 → re-enter push with forceOverwrite=true so
    ///     the revision check is skipped on this attempt. Feishu
    ///     side gets clobbered with whatever local has — caller
    ///     accepted that consequence.
    ///   - 「取消」 → close dialog, push aborts, frontmatter unchanged.
    ///
    /// localRevision / remoteRevision are debug-log-only (we don't
    /// surface them to the user — they're "工程逻辑" the user
    /// dismissed in the design conversation).
    @MainActor
    private static func handleRevisionConflict(
        document: DonemdDocument,
        coordinator: FeishuPushCoordinator,
        title: String,
        localRevision: Int,
        remoteRevision: Int
    ) async {
        debugLog("[push] revision conflict: local=\(localRevision) remote=\(remoteRevision)")

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "飞书侧自上次同步后被改过"
        alert.informativeText = """
        如果继续推送，飞书侧的最新改动会被覆盖。建议先点「拉取最新版到本地」，看完飞书侧的改动后，再决定是合并还是覆盖。
        """
        // NSAlert button order: first-added is rightmost (default).
        // Default = least destructive: 拉取最新版.
        alert.addButton(withTitle: "拉取最新版到本地")
        alert.addButton(withTitle: "仍然覆盖")
        alert.addButton(withTitle: "取消")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            // Same entry point as ⌘⌥O — runs the unsaved-changes
            // gate, the pull pipeline, and surfaces its own result
            // dialog. We don't auto-retry the push afterwards;
            // the user picks ⌘⌥S again when they're ready.
            FeishuPullCommand.run()
        case .alertSecondButtonReturn:
            // User explicitly accepted the consequence. Retry the
            // push with revision check disabled.
            await runPushWithSkipRetry(
                document: document,
                coordinator: coordinator,
                title: title,
                attempt: 1,
                forceOverwrite: true
            )
        default:
            // Cancel — push aborted, no Feishu side changes, no
            // local frontmatter changes.
            break
        }
    }

    @MainActor
    private static func handleMissingOnFeishu(
        blockIds: [String],
        document: DonemdDocument,
        coordinator: FeishuPushCoordinator,
        title: String,
        attempt: Int
    ) async {
        let count = blockIds.count
        let preview = blockIds.prefix(3).joined(separator: ", ")
        let suffix = count > 3 ? "（共 \(count) 个）" : ""

        let alert = NSAlert()
        alert.messageText = "飞书侧已删除 \(count) 个占位块"
        alert.informativeText = """
        本地引用但飞书侧已不存在的占位块：
        \(preview)\(suffix)

        • 「跳过并继续推送」会先在本地删掉这些占位块的 magic comment + frontmatter 索引，再推送一次（其余正文照常更新）。这一步不可撤销。
        • 「取消」保持本地原样不动。
        """
        alert.alertStyle = .warning
        // NSAlert button order: first-added is rightmost (default).
        // Default = 取消 (least destructive); then 跳过并继续推送.
        alert.addButton(withTitle: "取消")
        alert.addButton(withTitle: "跳过并继续推送")

        if attempt > 1 {
            // We've already retried once; don't offer a second skip
            // (would loop). Just inform the user and bail.
            presentAlert(
                title: "跳过后仍有占位块在飞书侧消失",
                message: """
                上一次跳过后又检测到 \(count) 个占位块在飞书侧不存在：
                \(preview)\(suffix)

                建议：手动从飞书重新拉取（⌘⌥O）刷新本地状态，再决定如何推送。
                """
            )
            return
        }

        switch alert.runModal() {
        case .alertSecondButtonReturn:
            // 跳过并继续推送
            let stripped = FeishuPushCoordinator.removePlaceholderBlocks(
                from: document.parsedDocument,
                blockIdsToRemove: Set(blockIds)
            )
            // Persist the stripped state to disk before we re-enter
            // push — if the retry crashes mid-flight, the user's
            // file already reflects the deletion they consented to.
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                document.applyUpdatedDocumentAndSave(stripped) { _ in
                    cont.resume()
                }
            }
            await runPushWithSkipRetry(
                document: document,
                coordinator: coordinator,
                title: title,
                attempt: attempt + 1
            )
        default:
            // 取消 — leave local state untouched, don't retry.
            return
        }
    }


    /// Translate a Feishu API error into user-facing Chinese — short
    /// enough to fit a dialog body, specific enough to give the user
    /// something to act on. The dev-friendly `\(error)` form is kept in
    /// `debugLog` for triage.
    private static func humanReadable(_ error: FeishuAPIError) -> String {
        switch error {
        case .unauthorized:
            return "飞书登录态已失效，请重新「同步到飞书」触发登录。"
        case .forbidden(let message):
            let detail = message.flatMap { $0.isEmpty ? nil : "（\($0)）" } ?? ""
            return "飞书权限不足\(detail)。可能需要管理员授权或重新登录扩充权限。"
        case .scopeInsufficient:
            // Push side shouldn't normally hit this (ADR-0007 §
            // Required scopes covers what's needed), but list the
            // bucket so the message stays honest if it does fire.
            return """
            飞书应用没有调用此接口的 OAuth 权限（错误码 99991679）。

            处理方法：到飞书开放平台 → 你的自建应用 → 「权限管理」检查并勾选缺失的 scope，重新发布版本，再让用户重新登录。完整错误细节见 `cat /tmp/donemd-debug.log`。
            """
        case .notFound(let resource):
            return "飞书侧找不到这份文档（\(resource)）。它可能已被删除。如果你想重新创建，请先在 frontmatter 里清除 feishu.doc_token，然后再同步。"
        case .rateLimited:
            return "飞书 API 限流。请稍等几分钟再试。"
        case .badRequest(let status, let code, let msg):
            // Surface the Feishu code + message verbatim — these are the
            // only signals the user (or a bug report) has to figure out
            // *which* parameter the request body got wrong. "Try again
            // later" is wrong here: this won't get better on retry.
            let codeStr = code.map { "code \($0)" } ?? ""
            let msgStr = msg.flatMap { $0.isEmpty ? nil : $0 } ?? ""
            let detail = [codeStr, msgStr].filter { !$0.isEmpty }.joined(separator: "，")
            return "飞书拒绝了同步请求（HTTP \(status)\(detail.isEmpty ? "" : "，" + detail)）。这通常是参数格式问题，重试不会修复。请把当前文档发给开发者排查；终端运行 `cat /tmp/donemd-debug.log` 能看到完整原始报错。"
        case .serverError(let status, _, let msg):
            let extra = msg.flatMap { $0.isEmpty ? nil : "：\($0)" } ?? ""
            return "飞书服务暂时出错（HTTP \(status)\(extra)）。稍后重试。"
        case .networkUnreachable(let detail):
            return "网络不可达：\(detail)"
        case .decodeFailed(let detail):
            return "飞书返回的数据无法识别（请将下面的文本提交反馈）：\n\(detail)"
        }
    }

    /// Build a human-readable image-stage summary, or empty string when
    /// nothing image-related happened (image stage not wired, or wired but
    /// the doc had no images at all). Empty result lets the caller decide
    /// whether to omit the line entirely.
    private static func imageReportSummary(_ report: FeishuImageUploadStage.Report?) -> String {
        guard let report else { return "" }
        let touched = report.uploadedCount > 0
            || report.skippedRemote > 0
            || !report.skippedMissing.isEmpty
            || !report.skippedVideos.isEmpty
        guard touched else { return "" }

        var parts: [String] = []
        if report.uploadedCount > 0 {
            parts.append("已上传 \(report.uploadedCount) 张图片")
        }
        if report.skippedRemote > 0 {
            parts.append("跳过外链 \(report.skippedRemote) 张")
        }
        if !report.skippedMissing.isEmpty {
            parts.append(
                "丢失本地文件 \(report.skippedMissing.count) 张："
                + report.skippedMissing.joined(separator: ", ")
            )
        }
        // Local video (#88): soft warning — the push skipped these, but the
        // local files and disk `<video>` lines are kept. Never blocks the push.
        if !report.skippedVideos.isEmpty {
            parts.append(
                "跳过本地视频 \(report.skippedVideos.count) 个（飞书暂不支持，本地已保留）"
            )
        }
        return parts.joined(separator: "，")
    }

    @MainActor
    private static func presentAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.runModal()
    }

    /// Critical-style alert for `.bodyVerificationFailed` (Layer 1, GH #84
    /// / #85). The push reported success, but a re-read found the remote
    /// body (near-)empty — the body silently didn't land. The single most
    /// important thing to tell the user: your local copy is intact, and
    /// DO NOT pull, because pulling would copy the empty remote back over
    /// your content (that's exactly how #84 lost the document).
    ///
    /// Buttons:
    ///   - 「打开飞书文档查看」 → open the bound docx so the user can see
    ///     for themselves that the body is missing on Feishu.
    ///   - 「知道了」 → dismiss. (No "pull" affordance anywhere — pulling
    ///     is the trap we're warning against.)
    @MainActor
    private static func presentBodyVerificationFailedAlert(
        document: DonemdDocument,
        token: DocToken?,
        intendedBlocks: Int,
        remoteBlocks: Int
    ) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "⚠️ 正文没有成功同步到飞书"
        alert.informativeText = """
        推送请求没有报错，但 Done.md 回读飞书文档时发现：正文没有真正写上去（本地有 \(intendedBlocks) 个内容块，飞书侧只回读到 \(remoteBlocks) 个）。飞书侧这份文档目前可能只有标题、没有正文。

        ✅ 你本地的文档完好无损，没有任何改动。

        ❌ 【千万不要点「从飞书同步」（拉取）】——现在拉取会把飞书侧的空文档覆盖到本地，你的正文就会丢失（这正是需要避免的情况）。

        【建议】
        1. 先打开飞书文档确认一下正文是不是真的没上去。
        2. 稍等片刻，重新「同步到飞书」（⌘⌥S）再推一次——多为临时问题，重推通常就好了。
        3. 若反复推不上去，把文档发给开发者，终端 `cat /tmp/donemd-debug.log` 可看完整日志。
        """

        // NSAlert button order: first-added is rightmost (default).
        alert.addButton(withTitle: "打开飞书文档查看")
        alert.addButton(withTitle: "知道了")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            if let token = token,
               let url = URL(string: "https://feishu.cn/docx/\(token.rawValue)") {
                NSWorkspace.shared.open(url)
            }
        default:
            break
        }
    }

    /// Critical-style alert for `.segmentFailed`. By the time this
    /// runs, the Feishu side has been partially mutated — at least
    /// one earlier segment got delete-then-create'd successfully, and
    /// the failing segment may have been half-applied (delete done,
    /// insert failed). The user needs to act, not just be informed.
    ///
    /// Buttons:
    ///   - 「打开飞书文档查看」 → opens the bound docx URL in the
    ///     default browser, so the user can immediately see what the
    ///     doc looks like right now and trigger Feishu's history
    ///     restore (clock icon top-right of the docx page).
    ///   - 「复制日志路径」 → copies `/tmp/donemd-debug.log` to the
    ///     clipboard so they can `cat` it for postmortem.
    ///   - 「关闭」 → dismiss.
    @MainActor
    private static func presentSegmentFailedAlert(
        document: DonemdDocument,
        token: DocToken?,
        completedBefore: Int,
        totalSegments: Int,
        attemptedSegmentIndex: Int,
        underlying: FeishuAPIError
    ) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "⚠️ 飞书文档可能已被部分破坏"

        var lines: [String] = []
        lines.append("""
        推送过程中飞书侧已删除部分内容，但新内容写入失败。这意味着此刻飞书上这份文档处于不一致状态——本应替换的内容没有到位。
        """)
        lines.append("失败位置：第 \(attemptedSegmentIndex) / \(totalSegments) 段（在此之前已完成 \(completedBefore) 段）")
        lines.append("失败原因：\(humanReadable(underlying))")
        lines.append("""
        【立即操作建议】
        1. 打开飞书文档 → 右上角时钟图标 → 历史版本，把推送前的版本恢复回来（这是最稳妥的做法，飞书的历史版本保留时间足够）
        2. 恢复后再回到 Done.md 重新「同步到飞书」（⌘⌥S）。重新推送会从飞书的当前状态重新开始，不会跳过已删除的部分。
        3. 如果原因看起来是临时网络问题（HTTP 5xx / 限流），也可以**先**重新推送试试——push 是幂等的，二次推送会再做一遍 delete + create，把上一轮没写完的部分补上。
        """)
        lines.append("完整原始错误已写入 /tmp/donemd-debug.log。")

        alert.informativeText = lines.joined(separator: "\n\n")

        // NSAlert button order: first-added is rightmost (default).
        // Default = 打开飞书文档（最常用动作）；then 复制日志路径; then 关闭.
        alert.addButton(withTitle: "打开飞书文档查看")
        alert.addButton(withTitle: "复制日志路径")
        alert.addButton(withTitle: "关闭")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            if let token = token {
                let urlStr = "https://feishu.cn/docx/\(token.rawValue)"
                if let url = URL(string: urlStr) {
                    NSWorkspace.shared.open(url)
                }
            }
        case .alertSecondButtonReturn:
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString("/tmp/donemd-debug.log", forType: .string)
        default:
            break
        }
    }
}
