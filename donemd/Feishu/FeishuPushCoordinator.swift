import Foundation

/// v2 Slice 9a-step1 (#50) — minimal happy-path Push.
///
/// Orchestrates "push a local Done.md document to Feishu":
///   1. read frontmatter → if no `docToken`, mint one via `createDocument`
///   2. serialize body to markdown (no frontmatter mixed in)
///   3. convert markdown → `[FeishuBlock]` via `FeishuStructuralConverter`
///   4. delegate to `apiClient.pushDocument(documentId:blocks:)`, which
///      orchestrates the docx blocks delete-then-create dance internally
///   5. write `docToken` (if newly minted) and `lastPushedAt` back into the
///      returned `ParsedDocument` — caller persists via `MarkdownEngine.serialize`
///
/// Out of scope for step1 (deferred):
///   - image extraction + `uploadImage` + src rewrite (step2)
///   - placeholder `preserve_existing` structural push (step3 / 9b)
///   - progress / cancellation events (UI slice)
///   - revision-conflict detection (#51 v2-9b)
///
/// Partial-success contract: if `createDocument` succeeds but `pushDocument`
/// fails immediately after, the freshly-minted Feishu doc is orphaned —
/// the caller MUST surface `PushError.partialSuccess` and persist the
/// returned `docToken` to the local frontmatter before any retry, or the
/// next attempt will create *another* doc and double-orphan the first.
public final class FeishuPushCoordinator {

    public enum PushError: Error, Equatable {
        /// Either `createDocument` failed, or `pushDocument` failed against
        /// an already-bound docToken (no orphan to clean up).
        case apiFailed(FeishuAPIError)
        /// `createDocument` succeeded → `pushDocument` failed. The fresh
        /// `docToken` exists on Feishu but never received body content.
        /// Caller MUST persist it to frontmatter before retrying.
        case partialSuccess(orphanedDocToken: DocToken, underlyingError: FeishuAPIError)
        /// Body contains one or more `feishu_placeholder_block` nodes.
        /// Honest stop-ship in v2-9a-step3 lite: the current push pipeline
        /// is delete-then-create (v2-9a-step1'), which would re-create
        /// every block on the Feishu side — including the sheet / mindnote
        /// / board placeholders, destroying real-time collaboration data
        /// other users have on those blocks. ADR-0007's preserve_existing
        /// path is the cure, tracked as #57 (v2-9c) and pinned to the
        /// Phase 2 v2 ship gate (#55). Until #57 ships, the coordinator
        /// refuses to push placeholder-bearing documents and surfaces this
        /// error so the UI layer can render an actionable dialog.
        ///
        /// `blockIds` is the deduped list of placeholder block_ids found
        /// in document order — useful for the dialog's "this document has
        /// N Feishu-only blocks" copy and for log triage.
        case containsPlaceholderBlocks(blockIds: [String])
        /// Frontmatter `feishu.placeholder_blocks` index disagrees with the
        /// body's actual `feishu_placeholder_block` nodes. The dangerous
        /// case is `missingFromBody` — the index says the doc has a sheet,
        /// the body doesn't, and a delete-then-create push would silently
        /// nuke that sheet on the Feishu side along with any realtime
        /// collaboration data on it. The less dangerous direction
        /// (`missingFromIndex`) still indicates a desync the user should
        /// see, since `placeholder_blocks` is the authoritative manifest
        /// and a body that diverges from it has been hand-edited (or
        /// produced by a buggy older Done.md build).
        ///
        /// User story #38 in the v2 PRD pins this as a hard stop. Both
        /// directions block push; the dialog tells the user which side is
        /// out of sync so they can recover (re-pull, undo their edit, or
        /// repair the magic comments by hand).
        case placeholderIndexMismatch(
            missingFromBody: [String],
            missingFromIndex: [String]
        )
        /// #57 preflight: a placeholder block_id present locally is no
        /// longer in the Feishu-side document tree. Either someone in
        /// Feishu manually deleted the sheet / mindnote / board, or the
        /// doc was reverted to a revision that doesn't have it. Pushing
        /// as-is is impossible (the segmented push path needs the
        /// placeholder to exist on Feishu so it can stay untouched).
        ///
        /// `blockIds` is the deduped list missing on Feishu, document
        /// order. UI surfaces a "[跳过 / 取消]" dialog (#57 step3) —
        /// "跳过" means the user agrees to drop the placeholder from
        /// the local body too, so the next push has no expectation of
        /// it on Feishu side. "取消" leaves both sides as-is.
        case placeholderMissingOnFeishu(blockIds: [String])
        /// #57 preflight: a placeholder block_id present in the
        /// Feishu-side document tree is *not* in the local body. The
        /// local user removed the placeholder from their copy without
        /// committing the corresponding deletion to Feishu. Distinct
        /// from `placeholderMissingOnFeishu` because the resolution is
        /// reversed: here the local side is ahead.
        ///
        /// Pushing as-is would silently drop the placeholder on Feishu
        /// (segmented push only touches non-placeholder segments — but
        /// it needs both sides to share the same placeholder set, so
        /// the missing-locally case has no segment boundary to hold
        /// onto). Caller should pull-then-merge or re-add the
        /// placeholder locally.
        case placeholderRemovedLocally(blockIds: [String])
        /// #57 preflight: both sides have the same set of placeholder
        /// block_ids, but their *order* on the page is different. The
        /// segmented push path can't reconcile this — there's no
        /// `move_block` API on Feishu, so the only way to "fix" the
        /// order would be delete-then-create the placeholder (which
        /// would destroy real-time collaboration data). UI tells the
        /// user to pull first so the local body matches Feishu's order;
        /// the local edits the user wanted to push remain in memory
        /// after the pull (the pull dialog branch handles this).
        case placeholderOrderMismatch(
            local: [String],
            remote: [String]
        )
        /// User pressed Cancel (#57 step5). Already-applied segment
        /// writes are NOT rolled back — Feishu has no transactional
        /// API for descendants. The doc on the Feishu side is left
        /// in whatever partial state the segmented push had reached
        /// when the signal was checked. The dialog tells the user
        /// honestly: "已取消，飞书侧可能处于半完成状态".
        ///
        /// `completedSegmentCount` and `totalSegmentCount` let the UI
        /// surface "已完成 N / M 段" so the user knows the damage.
        case cancelled(
            completedSegmentCount: Int,
            totalSegmentCount: Int
        )
        /// A delete or insert call inside the segmented-push loop
        /// failed. By the time this fires, at least one earlier
        /// segment may already have been deleted-and-recreated on
        /// the Feishu side, AND the failing segment itself may have
        /// been half-applied (delete succeeded → insert failed). The
        /// document on Feishu is in an inconsistent state until the
        /// user either retries successfully or rolls back via Feishu's
        /// document history.
        ///
        /// Distinct from `.apiFailed` — that case fires when a wire
        /// call before segmented push fails (preflight pull / image
        /// stage / title sync), where Feishu side is untouched.
        ///
        /// `completedBefore` = number of segments that fully succeeded
        /// before this failure (back-to-front order, so these are the
        /// later-in-doc segments). `totalSegments` = total segment
        /// count. `attemptedSegmentIndex` (1-based, completion order)
        /// = which segment was being pushed when the failure hit —
        /// `completedBefore + 1`. Carried separately for log clarity.
        case segmentFailed(
            completedBefore: Int,
            totalSegments: Int,
            attemptedSegmentIndex: Int,
            underlying: FeishuAPIError
        )
        /// #51 v2-9b: preflight detected that Feishu side has been
        /// edited since our last pull. `localRevision` is what
        /// `frontmatter.feishu.lastPulledRevision` carried at push
        /// time; `remoteRevision` is what `getDocumentRevision`
        /// returned just now. By definition `remoteRevision >
        /// localRevision` (the counter only goes up).
        ///
        /// UI surfaces a three-option dialog [拉取最新版到本地 /
        /// 仍然覆盖 / 取消]. "仍然覆盖" re-enters push with revision
        /// check disabled; "拉取最新版" routes to FeishuPullCommand.
        ///
        /// Only ever raised on the bound-document branch. Unbound
        /// docs (createDocument path) skip the check — they're
        /// brand-new on Feishu side, no prior revision to conflict
        /// against.
        ///
        /// Local revision can be nil — that means the doc was bound
        /// without ever having been pulled (manual frontmatter edit
        /// or partialSuccess recovery). In that case we can't make a
        /// "since when" claim, so we don't raise this error and let
        /// push proceed.
        case feishuRevisionConflict(localRevision: Int, remoteRevision: Int)
        /// Layer 1 of the pull-data-loss defense (GH #84 / #85). After the
        /// body push returns *without error*, we re-read the remote document
        /// and count its top-level blocks. If the local body had real
        /// content (≥1 top-level block) but the remote came back nearly
        /// empty — only the page title, no body — the push silently failed
        /// to land the body even though the API calls reported success. This
        /// is the exact #84 signature: push "succeeded", revision stayed at
        /// 1, the doc had only a title, and the subsequent pull faithfully
        /// copied that emptiness back over the user's local content.
        ///
        /// Raising this instead of returning a normal `PushResult` means we
        /// do NOT write `lastPushedAt` / mark the doc synced — so the doc
        /// isn't presented as "safely on Feishu" when its body never made
        /// it. The UI surfaces a critical alert telling the user the body
        /// didn't land, their local copy is intact, and NOT to pull.
        ///
        /// `createdDocToken` is non-nil only when this push minted a fresh
        /// doc (unbound → createDocument). Like `partialSuccess`, the caller
        /// MUST persist it so a retry rebinds instead of double-creating.
        case bodyVerificationFailed(
            intendedBlocks: Int,
            remoteBlocks: Int,
            createdDocToken: DocToken?
        )
    }

    /// Layer 1 verdict: did the body fail to land on Feishu despite the
    /// push reporting success? `intended` is the local top-level block
    /// count we meant to push; `remote` is what a re-read found on Feishu.
    ///
    /// Tuned to catch the #84 disaster (remote came back with zero body
    /// blocks — only the page title) without false-positiving on the
    /// small conversion differences that are legitimate (a bulletList
    /// expands to N sibling items; Feishu may merge or reject an odd
    /// block). So: an empty document is never flagged; any non-empty body
    /// that lands as literally zero remote blocks always is; and only a
    /// *drastic* shrink (>half lost) trips the gate for larger docs.
    static func bodyLandedSuspiciouslyEmpty(intended: Int, remote: Int) -> Bool {
        guard intended >= 1 else { return false }   // empty local body — nothing to verify
        if remote == 0 { return true }               // #84: had content, remote is bare title only
        guard intended >= 4 else { return false }    // tiny docs: tolerate conversion count drift
        return Double(remote) < Double(intended) * 0.5
    }

    /// Coarse-grained progress events the coordinator emits as the push
    /// pipeline advances. Used by the debug menu (and eventually the
    /// toolbar button) to show "what's happening right now". Step4 lite —
    /// observation only, no cancellation; cancellation lands with #57's
    /// segmented push architecture (see #57 issue thread for the why).
    public enum Progress: Equatable {
        /// Image stage starting; `total` is the upper bound on uploads
        /// (unique local-asset filenames found by the stage's pre-scan).
        /// `total == 0` means no local assets — UI can skip the line.
        case imageStageStarted(total: Int)
        /// One image successfully uploaded. `index` is 1-based, matches
        /// the `total` from `.imageStageStarted`.
        case imageUploaded(index: Int, total: Int)
        /// Image stage finished. Emitted whether or not any image was
        /// uploaded, so the UI can transition off the image line.
        case imageStageFinished
        /// About to call `createDocument` (a fresh doc — no docToken in
        /// frontmatter yet). Emitted at most once per push.
        case creatingDocument
        /// About to call `updateDocumentTitle` on an already-bound doc
        /// because the body's leading H1 changed. Emitted at most once.
        case updatingTitle
        /// About to call `pushDocument` to write the body. Emitted exactly
        /// once per successful push, after `creating` / `updatingTitle`.
        case writingBody
        /// Segmented push: about to start segment `index` (1-based) of
        /// `total`. Used by the progress bar to show "段 2/5". Emitted
        /// only on the segmented path (bound doc + placeholder body);
        /// the legacy delete-then-create path emits only `writingBody`.
        case segmentStarted(index: Int, total: Int)
        /// Segmented push: segment `index` finished. UI can advance
        /// the progress fill.
        case segmentFinished(index: Int, total: Int)
        /// All API calls succeeded; just before `PushResult` is returned.
        case done
    }

    public typealias ProgressCallback = (Progress) -> Void

    public struct PushResult: Equatable {
        public let updatedDocument: MarkdownEngine.ParsedDocument
        /// nil when no image stage was wired in. Surfaces upload counts to
        /// the debug command (and, eventually, the progress UI) so the user
        /// sees "uploaded N, skipped M" feedback.
        public let imageReport: FeishuImageUploadStage.Report?
        /// Non-nil when the bound-doc title PATCH (#57 step4) failed.
        /// The body push still ran successfully; the title on Feishu
        /// stays whatever it was before this push. UI surfaces this as
        /// a soft warning in the success dialog rather than aborting
        /// the whole push — content sync is the higher-value channel.
        public let titleSyncFailure: FeishuAPIError?

        public init(
            updatedDocument: MarkdownEngine.ParsedDocument,
            imageReport: FeishuImageUploadStage.Report? = nil,
            titleSyncFailure: FeishuAPIError? = nil
        ) {
            self.updatedDocument = updatedDocument
            self.imageReport = imageReport
            self.titleSyncFailure = titleSyncFailure
        }
    }

    private let apiClient: FeishuAPIClient
    private let imageUploadStage: FeishuImageUploadStage?
    private let now: () -> Date

    public init(
        apiClient: FeishuAPIClient,
        imageUploadStage: FeishuImageUploadStage? = nil,
        now: @escaping () -> Date = Date.init
    ) {
        self.apiClient = apiClient
        self.imageUploadStage = imageUploadStage
        self.now = now
    }

    public func push(
        _ document: MarkdownEngine.ParsedDocument,
        title: String,
        parentToken: String? = nil,
        signal: FeishuSyncCancellationSignal? = nil,
        forceOverwrite: Bool = false,
        onProgress: ProgressCallback? = nil
    ) async throws -> PushResult {
        // Step3.1 integrity check: frontmatter `placeholder_blocks` is the
        // authoritative manifest of which Feishu-only blocks the doc owns.
        // If the body has been hand-edited so its actual
        // feishu_placeholder_block nodes no longer match the manifest,
        // pushing would silently destroy whichever side the body lost track
        // of (sheet realtime data, etc.). User story #38 — block push,
        // surface the mismatch, let the user reconcile.
        let bodyPlaceholderIds = collectPlaceholderBlockIds(in: document.body)
        let indexedPlaceholderIds = document.frontmatter.feishu?
            .placeholderBlocks.map(\.blockId) ?? []
        let bodySet = Set(bodyPlaceholderIds)
        let indexSet = Set(indexedPlaceholderIds)
        let missingFromBody = indexedPlaceholderIds.filter { !bodySet.contains($0) }
        let missingFromIndex = bodyPlaceholderIds.filter { !indexSet.contains($0) }
        if !missingFromBody.isEmpty || !missingFromIndex.isEmpty {
            throw PushError.placeholderIndexMismatch(
                missingFromBody: missingFromBody,
                missingFromIndex: missingFromIndex
            )
        }

        // #51 v2-9b revision-conflict preflight (bound + has localRev only).
        // If frontmatter says we last pulled at revision N and Feishu now
        // says revision M > N, somebody edited Feishu side between our
        // pull and this push. Pushing as-is would overwrite their work.
        // Throw PushError.feishuRevisionConflict and let the UI surface
        // the [拉取最新版 / 仍然覆盖 / 取消] dialog.
        //
        // Skipped when:
        //   - forceOverwrite == true: user already saw the dialog and
        //     explicitly chose to overwrite. Re-running the check would
        //     loop on the same conflict.
        //   - doc is unbound: createDocument path makes a brand-new doc
        //     on Feishu — there's nothing to conflict with.
        //   - localRevision is nil: the doc is bound but was never
        //     pulled (manual frontmatter edit / partialSuccess recovery).
        //     We can't claim "since when" without a baseline, so we
        //     don't block push on this.
        if !forceOverwrite,
           let boundToken = document.frontmatter.feishu?.docToken,
           let localRev = document.frontmatter.feishu?.lastPulledRevision {
            let remoteRev: Int
            do {
                remoteRev = try await apiClient.getDocumentRevision(
                    documentId: boundToken.rawValue
                )
            } catch let apiError as FeishuAPIError {
                throw PushError.apiFailed(apiError)
            }
            if remoteRev > localRev {
                throw PushError.feishuRevisionConflict(
                    localRevision: localRev,
                    remoteRevision: remoteRev
                )
            }
        }

        // #57 step1 preflight: when the local body has placeholder blocks
        // AND the document is already bound to Feishu, pull the remote
        // tree first and check that both sides agree on the placeholder
        // block_id set + order. Three failure modes (each a distinct
        // PushError case so the dialog can route to the right recovery):
        //
        //   - .placeholderMissingOnFeishu — local has ids Feishu-side
        //     doesn't (someone deleted on Feishu, or the doc was
        //     reverted). Recovery: [跳过 / 取消].
        //   - .placeholderRemovedLocally — Feishu has ids local doesn't
        //     (user removed the magic comment locally without pushing).
        //     Recovery: pull or re-add locally.
        //   - .placeholderOrderMismatch — same set, different document
        //     order. No move API → user must pull first.
        //
        // Skipped when the doc has no placeholders (pure body push —
        // segmented push isn't needed) or is unbound (createDocument
        // path — placeholders on a brand new doc would have no Feishu-
        // side counterpart to preserve, so the legacy stop-ship still
        // applies until #58 createNew). Bound docs without placeholders
        // also skip preflight — they go through the existing
        // delete-then-create.
        var preflight: PreflightResult? = nil
        if !bodyPlaceholderIds.isEmpty,
           let boundToken = document.frontmatter.feishu?.docToken {
            preflight = try await runPreflight(
                docToken: boundToken,
                localPlaceholderIds: bodyPlaceholderIds
            )
        }

        // Unbound + has placeholder = legacy stop-ship. The whole point
        // of preserve_existing is to keep Feishu-side data alive across
        // a push, but a brand-new (unbound) doc has nothing to preserve
        // — and createDocument's response doesn't honor pre-supplied
        // block_ids, so the placeholders couldn't be recreated faithfully
        // anyway. Until #58 (createNew) handles this, refuse the push.
        if !bodyPlaceholderIds.isEmpty && preflight == nil {
            throw PushError.containsPlaceholderBlocks(blockIds: bodyPlaceholderIds)
        }

        // Notion-style title binding (v2-9b step1.5): the body's leading H1,
        // if present, is the document's authoritative title. Extract it so
        // it lands as the page-block title on Feishu (not duplicated in the
        // body), and so the symmetric pull can prepend it back. When the
        // local body has no leading H1, fall back to the caller's `title:`
        // (typically the file name) — same as before.
        let extraction = extractLeadingH1(from: document.body)
        let effectiveTitle = extraction?.title ?? title
        let bodyForBlocks = extraction?.strippedBody ?? document.body

        // Pre-image-stage cancel checkpoint. Bailing here avoids the
        // multi-second image upload roundtrip + the createDocument
        // call, the most common "cancel why is it still running"
        // complaint coming from users pressing Cancel right after
        // ⌘⌥S.
        if signal?.isCancelled == true {
            throw PushError.cancelled(
                completedSegmentCount: 0,
                totalSegmentCount: 0
            )
        }

        // Resolve docToken FIRST — image upload needs it as parent_node
        // (Feishu drive's docx_image upload returns 1061004 forbidden
        // without the parent_node + extra.drive_route_token fields,
        // verified real-device 2026-05-30). For unbound docs that
        // means createDocument runs before any image upload; the
        // tradeoff is a fresh doc gets created even if the image
        // stage fails afterwards (orphan doc, surfaced via the
        // existing partialSuccess path).
        let docToken: DocToken
        let createdInThisCall: Bool
        if let existing = document.frontmatter.feishu?.docToken {
            docToken = existing
            createdInThisCall = false
        } else {
            onProgress?(.creatingDocument)
            do {
                let raw = try await apiClient.createDocument(
                    title: effectiveTitle, parentToken: parentToken
                )
                docToken = DocToken(raw)
                createdInThisCall = true
            } catch let apiError as FeishuAPIError {
                throw PushError.apiFailed(apiError)
            }
        }

        // Image stage runs *after* docToken resolution so each
        // upload's `parent_node` is the real document_id. The stage
        // rewrites `donemd-asset://` srcs to `feishu://image/<token>`,
        // which the structural converter below recognizes for the
        // image block payload.
        let imageReport: FeishuImageUploadStage.Report?
        let bodyAfterImages: TiptapNode
        if let stage = imageUploadStage {
            do {
                var startReported = false
                let (rewritten, report) = try await stage.process(
                    body: bodyForBlocks,
                    documentId: docToken.rawValue
                ) { index, total in
                    if !startReported {
                        onProgress?(.imageStageStarted(total: total))
                        startReported = true
                    }
                    onProgress?(.imageUploaded(index: index, total: total))
                }
                bodyAfterImages = rewritten
                imageReport = report
                if !startReported && report.uploadedCount == 0 {
                    // No uploads happened (no local assets, all skipped).
                    // Still emit start/finish so the UI's transition logic
                    // is uniform across docs with and without images.
                    onProgress?(.imageStageStarted(total: 0))
                }
                onProgress?(.imageStageFinished)
            } catch let apiError as FeishuAPIError {
                if createdInThisCall {
                    // Doc exists on Feishu but the image stage failed
                    // before any body push. Surface as partialSuccess
                    // so the next retry recognizes the binding instead
                    // of double-creating.
                    throw PushError.partialSuccess(
                        orphanedDocToken: docToken, underlyingError: apiError
                    )
                }
                throw PushError.apiFailed(apiError)
            }
        } else {
            bodyAfterImages = bodyForBlocks
            imageReport = nil
        }

        // Pre-API cancellation point — image stage just finished, but
        // we haven't patched the title or pushed the body yet. Bailing
        // here is cheap on bound docs (zero side effects); on a
        // fresh-created doc, the doc exists but is empty.
        if signal?.isCancelled == true {
            throw PushError.cancelled(
                completedSegmentCount: 0,
                totalSegmentCount: 0
            )
        }

        // The structural converter is the single source of truth for the
        // tree → block mapping (v2-4a/4b/4c). Going through TiptapNode
        // directly (instead of round-tripping markdown) preserves
        // block-level image nodes — the markdown parser would otherwise
        // re-flatten `![](feishu://image/…)` into an inline image inside a
        // paragraph, where the converter's "paragraph" case discards it.
        let blocks = FeishuStructuralConverter.toFeishuBlocks(tiptap: bodyAfterImages)

        // Title sync runs only on already-bound docs. Newly-created
        // docs already used `effectiveTitle` in createDocument above.
        var titleSyncFailure: FeishuAPIError? = nil
        if !createdInThisCall, extraction != nil {
            onProgress?(.updatingTitle)
            do {
                try await apiClient.updateDocumentTitle(
                    documentId: docToken.rawValue, title: effectiveTitle
                )
            } catch let apiError as FeishuAPIError {
                // Don't abort — capture and surface to UI after the
                // body push completes. The body sync is more
                // important than title sync.
                debugLog("[push] title sync failed (non-fatal): \(apiError)")
                titleSyncFailure = apiError
            }
        }

        onProgress?(.writingBody)
        if let preflight {
            // Segmented push path: preserve placeholder blocks on Feishu
            // by only deleting + re-creating non-placeholder segments.
            // preflight is non-nil iff the body has placeholders AND
            // the doc was bound — exactly the case where the legacy
            // pushDocument would nuke real-time collaboration data.
            let segments = sliceLocalBlocksByPlaceholder(
                blocks, placeholderIdsInOrder: bodyPlaceholderIds
            )
            let ranges = computeRemoteSegmentRanges(
                remoteRootChildIds: preflight.remoteRootChildIds,
                placeholderIdsInOrder: preflight.remotePlaceholderIds
            )
            try await runSegmentedPush(
                documentId: docToken.rawValue,
                pageBlockId: preflight.pageBlockId,
                localSegments: segments,
                remoteRanges: ranges,
                signal: signal,
                onProgress: onProgress
            )
        } else {
            // No-placeholder path: legacy delete-then-create. Faster
            // (one round-trip pull + one batch_delete + one descendant
            // create) and equivalent for docs without preserve-existing
            // concerns.
            do {
                try await apiClient.pushDocument(
                    documentId: docToken.rawValue, blocks: blocks
                )
            } catch let apiError as FeishuAPIError {
                if createdInThisCall {
                    throw PushError.partialSuccess(
                        orphanedDocToken: docToken, underlyingError: apiError
                    )
                }
                throw PushError.apiFailed(apiError)
            }
        }

        // Layer 1 body-landing verification (GH #84 / #85). The push calls
        // above returned without error, but "no error" is not "the body is
        // on Feishu" — the #84 incident had pushDocument report success
        // while the remote ended up with only a title and no body blocks.
        // Re-read the remote tree and count its top-level (page-child)
        // blocks against how many we meant to push. If we intended real
        // content but the remote came back (near-)empty, refuse to mark
        // this as a successful sync — otherwise the doc looks safely on
        // Feishu and a later pull will copy the emptiness back over the
        // user's local content.
        //
        // Best-effort: if the re-read itself fails (network blip), we do
        // NOT block the push — we can't prove the body is missing, and a
        // false alarm on every flaky re-read would be worse than the rare
        // miss. We only raise when the re-read succeeds AND shows the body
        // is suspiciously empty.
        let intendedTopLevelBlocks = (blocks.first {
            if case .page = $0.payload { return true } else { return false }
        }?.children?.count) ?? 0
        if intendedTopLevelBlocks >= 1 {
            if let remoteBlocks = try? await apiClient.pullDocument(
                documentId: docToken.rawValue
            ).blocks {
                let remoteTopLevel = remoteBlocks.first {
                    if case .page = $0.payload { return true } else { return false }
                }?.children?.count ?? 0
                if Self.bodyLandedSuspiciouslyEmpty(
                    intended: intendedTopLevelBlocks, remote: remoteTopLevel
                ) {
                    debugLog("[push] body verification FAILED: intended=\(intendedTopLevelBlocks) remote=\(remoteTopLevel)")
                    throw PushError.bodyVerificationFailed(
                        intendedBlocks: intendedTopLevelBlocks,
                        remoteBlocks: remoteTopLevel,
                        createdDocToken: createdInThisCall ? docToken : nil
                    )
                }
                debugLog("[push] body verification OK: intended=\(intendedTopLevelBlocks) remote=\(remoteTopLevel)")
            } else {
                debugLog("[push] body verification skipped: re-read failed (network?), not blocking push")
            }
        }

        var updatedFrontmatter = document.frontmatter
        var feishu = updatedFrontmatter.feishu ?? FeishuFrontmatter()
        feishu.docToken = docToken
        feishu.lastPushedAt = now()
        updatedFrontmatter.feishu = feishu
        if updatedFrontmatter.feishuOriginalIndex == nil {
            updatedFrontmatter.feishuOriginalIndex = updatedFrontmatter.userFields.count
        }
        updatedFrontmatter.hasFence = true

        let updated = MarkdownEngine.ParsedDocument(
            frontmatter: updatedFrontmatter, body: document.body
        )
        onProgress?(.done)
        return PushResult(
            updatedDocument: updated,
            imageReport: imageReport,
            titleSyncFailure: titleSyncFailure
        )
    }

    // MARK: - title extraction

    /// If `body`'s first child is a level-1 heading, peel it off and return
    /// `(plainTitle, bodyMinusH1)`. Otherwise return nil. Plain text only —
    /// inline marks (bold / italic / code) on the title are flattened, since
    /// the Feishu page-block title is plain text in practice.
    private func extractLeadingH1(from body: TiptapNode) -> (title: String, strippedBody: TiptapNode)? {
        guard
            var topLevel = body.content,
            let first = topLevel.first,
            first.type == "heading",
            case .int(let level) = first.attrs?["level"] ?? .int(0),
            level == 1
        else {
            return nil
        }

        let title = collectPlainText(from: first.content ?? [])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // Empty H1 (e.g. user typed `#` then deleted the text) — skip
        // extraction so we don't clobber the Feishu title with "".
        guard !title.isEmpty else { return nil }

        topLevel.removeFirst()
        var stripped = body
        stripped.content = topLevel
        return (title, stripped)
    }

    /// Walk a Tiptap inline-content array and concatenate every `text` node's
    /// content. Marks survive on the original H1 — they're only dropped from
    /// the title string we send to Feishu, where the title is plain text.
    private func collectPlainText(from inlines: [TiptapNode]) -> String {
        inlines.reduce(into: "") { acc, node in
            if let text = node.text { acc += text }
            if let children = node.content {
                acc += collectPlainText(from: children)
            }
        }
    }

    // MARK: - placeholder scan (step3 lite safety gate)

    /// Walk the body tree depth-first and collect every
    /// `feishu_placeholder_block` node's `block_id` attr. Placeholder blocks
    /// are atom nodes (ADR-0007), so this stops descending once it finds
    /// one — they have no children.
    ///
    /// Returns ids in document order, deduped (a malformed body could in
    /// theory carry the same id twice; the dialog and #57's eventual diff
    /// pass both want the unique set).
    private func collectPlaceholderBlockIds(in body: TiptapNode) -> [String] {
        var ids: [String] = []
        var seen: Set<String> = []
        walkForPlaceholders(node: body, ids: &ids, seen: &seen)
        return ids
    }

    private func walkForPlaceholders(
        node: TiptapNode,
        ids: inout [String],
        seen: inout Set<String>
    ) {
        if node.type == "feishu_placeholder_block" {
            if case .string(let id)? = node.attrs?["block_id"], !id.isEmpty,
               !seen.contains(id) {
                ids.append(id)
                seen.insert(id)
            }
            return
        }
        for child in node.content ?? [] {
            walkForPlaceholders(node: child, ids: &ids, seen: &seen)
        }
    }

    // MARK: - #57 step1 preflight + step2 segmented push

    /// What the preflight phase hands back to the main push loop.
    /// Carries enough context to do segmented push without re-pulling.
    private struct PreflightResult {
        let pageBlockId: String
        /// Root child id sequence on the Feishu side, document order.
        /// Mix of placeholder ids and non-placeholder ids — segmented
        /// push slices this against `pageBlockId`'s children to find
        /// the segment boundaries.
        let remoteRootChildIds: [String]
        /// Subset of `remoteRootChildIds` that are placeholders, in
        /// document order. Equal to `localPlaceholderIds` when
        /// preflight passes — we keep the remote view because it's
        /// also what segmented push uses to compute remote indices.
        let remotePlaceholderIds: [String]
    }

    /// Pull the Feishu-side document tree and validate that the
    /// placeholder block_ids on both sides agree as a *sequence*.
    /// Three failure modes mapped to distinct PushError cases.
    ///
    /// On success, returns the data segmented push needs (the page
    /// block id + the remote root children) so the caller doesn't
    /// re-pull.
    private func runPreflight(
        docToken: DocToken,
        localPlaceholderIds: [String]
    ) async throws -> PreflightResult {
        let pulled: (blocks: [FeishuBlock], revisionId: Int)
        do {
            pulled = try await apiClient.pullDocument(documentId: docToken.rawValue)
        } catch let apiError as FeishuAPIError {
            throw PushError.apiFailed(apiError)
        }

        guard let page = pulled.blocks.first(where: {
            if case .page = $0.payload { return true } else { return false }
        }) else {
            throw PushError.apiFailed(.decodeFailed("pulled document has no page block"))
        }
        let pageBlockId = page.blockId
        let remoteRootChildIds = page.children ?? []
        let remotePlaceholderIds = collectFeishuPlaceholderIds(in: pulled.blocks)

        let localSet = Set(localPlaceholderIds)
        let remoteSet = Set(remotePlaceholderIds)

        // Direction 1: local has ids Feishu-side doesn't.
        // Recovery via [跳过 / 取消] dialog at the UI layer.
        let missingOnRemote = localPlaceholderIds.filter { !remoteSet.contains($0) }
        if !missingOnRemote.isEmpty {
            throw PushError.placeholderMissingOnFeishu(blockIds: missingOnRemote)
        }

        // Direction 2: Feishu-side has ids the local body doesn't carry.
        // Recovery: pull or re-add the magic comment locally.
        let missingLocally = remotePlaceholderIds.filter { !localSet.contains($0) }
        if !missingLocally.isEmpty {
            throw PushError.placeholderRemovedLocally(blockIds: missingLocally)
        }

        // Direction 3: same set, different document order. With both
        // sets equal at this point, comparing the ordered arrays is the
        // direct sequence-equality check ADR-0007 requires.
        if localPlaceholderIds != remotePlaceholderIds {
            throw PushError.placeholderOrderMismatch(
                local: localPlaceholderIds,
                remote: remotePlaceholderIds
            )
        }

        return PreflightResult(
            pageBlockId: pageBlockId,
            remoteRootChildIds: remoteRootChildIds,
            remotePlaceholderIds: remotePlaceholderIds
        )
    }

    /// Walk the Feishu-side block list (root-level only — ADR-0007 §
    /// 已知限制 1 says nested placeholders are unsupported, so we don't
    /// recurse into children) and collect placeholder block_ids in
    /// document order. The first block payload is `.page`; its
    /// `children` array is the root child id sequence. We look up each
    /// child by id and emit it if it's a placeholder.
    private func collectFeishuPlaceholderIds(in blocks: [FeishuBlock]) -> [String] {
        let byId = Dictionary(uniqueKeysWithValues: blocks.map { ($0.blockId, $0) })
        guard let page = blocks.first(where: {
            if case .page = $0.payload { return true } else { return false }
        }) else {
            return []
        }
        let rootChildIds = page.children ?? []
        var ids: [String] = []
        for childId in rootChildIds {
            guard let block = byId[childId] else { continue }
            if case .placeholder = block.payload {
                ids.append(block.blockId)
            }
        }
        return ids
    }

    // MARK: - #57 step2 segmented push

    /// Slice the encoded `[FeishuBlock]` of a local body into segments
    /// bounded by placeholder ids. Returns `[Segment]` where each
    /// `Segment` is a contiguous run of *non-placeholder* blocks
    /// flanked by either a placeholder or a document edge. Segments
    /// can be empty (two placeholders adjacent locally).
    ///
    /// `placeholderIdsInOrder` must match the local body's actual
    /// document order — preflight guarantees this is also the remote
    /// order. The returned list has length `placeholderIds.count + 1`.
    private struct LocalSegment {
        /// Non-placeholder blocks that belong to this segment, in the
        /// shape `toFeishuBlocks` produced (with the synthetic page
        /// root as `[0]` so `encodeDescendantBody` accepts them).
        let blocks: [FeishuBlock]
    }

    private func sliceLocalBlocksByPlaceholder(
        _ blocks: [FeishuBlock],
        placeholderIdsInOrder: [String]
    ) -> [LocalSegment] {
        guard let page = blocks.first(where: {
            if case .page = $0.payload { return true } else { return false }
        }) else { return [] }
        let nonPageBlocks = blocks.filter {
            if case .page = $0.payload { return false } else { return true }
        }
        let nonPageById = Dictionary(uniqueKeysWithValues: nonPageBlocks.map { ($0.blockId, $0) })
        let topLevelIds = page.children ?? []

        // For each top-level id, decide if it's a placeholder boundary
        // or a non-placeholder content block. Walk and accumulate.
        var segments: [LocalSegment] = []
        var current: [FeishuBlock] = []

        // Helper: emit current as a segment with synthetic page root.
        func flush() {
            // Page-only synthetic root holds the segment's top-level
            // child ids in `children`; non-placeholder content blocks
            // (and their descendants) follow.
            let segmentTopIds = current.map(\.blockId)
            let syntheticPage = FeishuBlock(
                blockId: page.blockId,
                parentId: nil,
                children: segmentTopIds,
                payload: .page(.init())
            )
            // Include current top-level blocks plus any non-page
            // descendants reachable via their `children` fields. The
            // converter emits descendants flat in `nonPageBlocks`, so
            // we collect via BFS over child ids.
            var collected: [FeishuBlock] = [syntheticPage]
            var queue: [String] = current.map(\.blockId)
            var seen: Set<String> = []
            while let id = queue.first {
                queue.removeFirst()
                if seen.contains(id) { continue }
                seen.insert(id)
                guard let block = nonPageById[id] else { continue }
                collected.append(block)
                if let kids = block.children { queue.append(contentsOf: kids) }
            }
            segments.append(LocalSegment(blocks: collected))
            current = []
        }

        let placeholderSet = Set(placeholderIdsInOrder)
        for childId in topLevelIds {
            if placeholderSet.contains(childId) {
                flush()
                // Placeholder itself doesn't go into any segment —
                // segmented push leaves it untouched on Feishu side.
            } else if let block = nonPageById[childId] {
                current.append(block)
            }
        }
        flush()  // trailing segment

        return segments
    }

    /// Compute (startIndex, endIndex) of each non-placeholder segment
    /// in the *remote* root children list. Segments are ordered the
    /// same way as `sliceLocalBlocksByPlaceholder` returns them, so
    /// pairing by index works.
    private func computeRemoteSegmentRanges(
        remoteRootChildIds: [String],
        placeholderIdsInOrder: [String]
    ) -> [(start: Int, end: Int)] {
        var ranges: [(start: Int, end: Int)] = []
        var cursor = 0
        let placeholderSet = Set(placeholderIdsInOrder)
        var segmentStart = 0
        for (idx, childId) in remoteRootChildIds.enumerated() {
            if placeholderSet.contains(childId) {
                ranges.append((start: segmentStart, end: idx))
                segmentStart = idx + 1
            }
            cursor = idx + 1
        }
        ranges.append((start: segmentStart, end: cursor))
        return ranges
    }

    /// Run the segmented push: for each (segment, range) pair,
    /// back-to-front, delete the remote range and insert the local
    /// segment at the same start index.
    ///
    /// Why back-to-front: deleting `[start, end)` collapses everything
    /// after `end` left by `(end - start)`, and inserting `N` blocks
    /// at `start` shifts everything after `start` right by `N`. If we
    /// iterated front-to-back, computing each later segment's remote
    /// range would require tracking the running net shift. Going
    /// back-to-front, by the time we touch a segment all later
    /// segments have already had their writes applied — but those
    /// writes only affect indices *after* the current segment's
    /// `start`, which is exactly where we want to be.
    ///
    /// Failure during a segment leaves the document in a partial
    /// state: earlier (later-in-doc) segments updated, this one
    /// half-deleted, later (earlier-in-doc) segments untouched. We
    /// surface as `.apiFailed` for now — the user is told to pull and
    /// retry. A real recovery would need a transactional API Feishu
    /// doesn't provide.
    // MARK: - #57 step3 placeholder skip helper

    /// Strip every `feishu_placeholder_block` whose `block_id` is in
    /// `blockIdsToRemove` from the body, AND the matching entries from
    /// `frontmatter.feishu.placeholderBlocks`. Returns a new
    /// ParsedDocument; the input is not mutated.
    ///
    /// Used by the missingOnFeishu skip path (#57 step3) when the user
    /// agrees to drop placeholders that no longer exist on Feishu side.
    /// Walks the tree shallowly because placeholder blocks are atom
    /// nodes — they never have descendants — but recurses into other
    /// block containers (callout / quote / list-item / table-cell) so
    /// a future schema with nested placeholders still works.
    public static func removePlaceholderBlocks(
        from document: MarkdownEngine.ParsedDocument,
        blockIdsToRemove: Set<String>
    ) -> MarkdownEngine.ParsedDocument {
        let strippedBody = stripPlaceholders(
            in: document.body, idsToRemove: blockIdsToRemove
        )
        var feishu = document.frontmatter.feishu ?? FeishuFrontmatter()
        feishu.placeholderBlocks = feishu.placeholderBlocks.filter {
            !blockIdsToRemove.contains($0.blockId)
        }
        var newFrontmatter = document.frontmatter
        newFrontmatter.feishu = feishu
        return MarkdownEngine.ParsedDocument(
            frontmatter: newFrontmatter, body: strippedBody
        )
    }

    private static func stripPlaceholders(
        in node: TiptapNode, idsToRemove: Set<String>
    ) -> TiptapNode {
        var result = node
        if let children = node.content {
            let kept = children.compactMap { child -> TiptapNode? in
                if child.type == "feishu_placeholder_block",
                   case .string(let id)? = child.attrs?["block_id"],
                   idsToRemove.contains(id) {
                    return nil  // drop this child
                }
                return stripPlaceholders(in: child, idsToRemove: idsToRemove)
            }
            result.content = kept
        }
        return result
    }

    private func runSegmentedPush(
        documentId: String,
        pageBlockId: String,
        localSegments: [LocalSegment],
        remoteRanges: [(start: Int, end: Int)],
        signal: FeishuSyncCancellationSignal?,
        onProgress: ProgressCallback?
    ) async throws {
        precondition(localSegments.count == remoteRanges.count,
            "segment count mismatch — preflight guarantees equal count")

        let total = localSegments.count
        var completed = 0
        // Iterate back-to-front; "segment N of M" UI counts up by
        // completion order (1, 2, 3…), not by document order.
        for i in stride(from: localSegments.count - 1, through: 0, by: -1) {
            // Cancel before each segment — past this point we're going
            // to issue a delete + insert pair, and we can't safely
            // abort mid-pair without leaving a bigger hole.
            if signal?.isCancelled == true {
                throw PushError.cancelled(
                    completedSegmentCount: completed,
                    totalSegmentCount: total
                )
            }
            onProgress?(.segmentStarted(index: completed + 1, total: total))

            let segment = localSegments[i]
            let range = remoteRanges[i]

            if range.end > range.start {
                do {
                    try await apiClient.deleteChildrenRange(
                        documentId: documentId,
                        parentBlockId: pageBlockId,
                        startIndex: range.start,
                        endIndex: range.end
                    )
                } catch let apiError as FeishuAPIError {
                    // Failure inside segmented loop = Feishu side
                    // already has at least one segment deleted (this
                    // one's range, if delete itself failed mid-flight,
                    // PLUS every back-to-front segment that succeeded
                    // before us). Surface as `.segmentFailed` so the
                    // UI can route to a critical-style alert urging
                    // the user to restore from Feishu history.
                    throw PushError.segmentFailed(
                        completedBefore: completed,
                        totalSegments: total,
                        attemptedSegmentIndex: completed + 1,
                        underlying: apiError
                    )
                }
            }

            do {
                try await apiClient.insertChildrenAt(
                    documentId: documentId,
                    parentBlockId: pageBlockId,
                    index: range.start,
                    blocks: segment.blocks
                )
            } catch let apiError as FeishuAPIError {
                // Same recovery story as the delete-failure branch —
                // delete already succeeded for this segment, so
                // Feishu side is missing content this attempt was
                // meant to put back.
                throw PushError.segmentFailed(
                    completedBefore: completed,
                    totalSegments: total,
                    attemptedSegmentIndex: completed + 1,
                    underlying: apiError
                )
            }
            completed += 1
            onProgress?(.segmentFinished(index: completed, total: total))
        }
    }
}
