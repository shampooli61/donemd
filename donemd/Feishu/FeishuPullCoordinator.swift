import Foundation

/// v2 Slice 8 / "v2-9b" step1 (#49) — minimal happy-path Pull.
///
/// Orchestrates "pull a Feishu doc into a local Done.md document":
///   1. read blocks + revision from `apiClient.pullDocument(documentId:)`
///   2. convert `[FeishuBlock]` → markdown via
///      `FeishuStructuralConverter.toMarkdownWithWarnings`
///   3. parse the converted markdown body so the caller gets a well-formed
///      `MarkdownEngine.ParsedDocument` rather than a raw string
///   4. merge the body with `existing` frontmatter (preserve user fields,
///      stamp `feishu.docToken` + `feishu.lastPulledRevision`)
///   5. surface converter warnings on `PullResult` so the caller can show
///      e.g. "nested content dropped from placeholder block" badges
///
/// Out of scope for step1 (deferred):
///   - unsaved-changes dialog (UI layer wraps the clean overwrite primitive
///     this coordinator returns)
///   - OAuth re-routing on `.unauthorized` (UI layer)
///   - progress / cancellation events (UI slice)
///   - placeholder index frontmatter sync (separate concern)
///   - revision conflict detection — that's the whole point of v2-9b #51,
///     not step1
///
/// Symmetric to `FeishuPushCoordinator` deliberately: same shape, same
/// error-mapping pattern, same `now()` injection so tests pin timestamps.
public final class FeishuPullCoordinator {

    public enum PullError: Error, Equatable {
        /// `apiClient.pullDocument` failed. Carries the underlying API
        /// error so the UI layer can route 401 → re-login, 404 → "doc
        /// disappeared", etc. Mirrors `FeishuPushCoordinator.PushError.apiFailed`.
        case apiFailed(FeishuAPIError)
        /// User pressed Cancel (#57 step5). Pull is read-only on the
        /// Feishu side, so cancelling is always safe — no partial
        /// state to recover. The local document is also untouched
        /// (we throw before applyUpdatedDocumentAndSave).
        case cancelled
    }

    /// Coarse-grained pull progress events. Mirrors push's vocabulary:
    /// the UI stays uniform across both directions.
    public enum Progress: Equatable {
        /// About to call `pullDocument` to read the doc tree.
        case pullingDocument
        /// Image download stage starting. `total = 0` means no
        /// feishu:// images in the body — UI can skip the line.
        case imageStageStarted(total: Int)
        /// One image successfully downloaded. `index` is 1-based.
        case imageDownloaded(index: Int, total: Int)
        case imageStageFinished
        /// All conversion + download finished, just before
        /// `PullResult` returns.
        case done
    }

    public typealias ProgressCallback = (Progress) -> Void

    public struct PullResult: Equatable {
        public let updatedDocument: MarkdownEngine.ParsedDocument
        public let warnings: [FeishuStructuralConverter.ConversionWarning]
        /// nil when no image-download stage was wired (tests that don't
        /// care about images, or pull paths where AssetsManager isn't
        /// available yet). Surfaces download counts to the result
        /// dialog ("downloaded N, failed M").
        public let imageReport: FeishuImageDownloadStage.Report?

        public init(
            updatedDocument: MarkdownEngine.ParsedDocument,
            warnings: [FeishuStructuralConverter.ConversionWarning] = [],
            imageReport: FeishuImageDownloadStage.Report? = nil
        ) {
            self.updatedDocument = updatedDocument
            self.warnings = warnings
            self.imageReport = imageReport
        }
    }

    private let apiClient: FeishuAPIClient
    private let imageDownloadStage: FeishuImageDownloadStage?
    private let now: () -> Date

    public init(
        apiClient: FeishuAPIClient,
        imageDownloadStage: FeishuImageDownloadStage? = nil,
        now: @escaping () -> Date = Date.init
    ) {
        self.apiClient = apiClient
        self.imageDownloadStage = imageDownloadStage
        self.now = now
    }

    /// Pull `token`'s current state from Feishu and merge it into a local
    /// `ParsedDocument`. When `existing` is `nil` the coordinator builds
    /// a fresh document; when provided, user frontmatter fields and any
    /// `feishu.unknown` keys round-trip untouched.
    ///
    /// `now` is currently unused on the pull side — `lastPulledRevision`
    /// is the canonical timestamp, not wall time — but kept on the init
    /// to mirror the push coordinator's surface and stay future-proof.
    public func pull(
        token: DocToken,
        into existing: MarkdownEngine.ParsedDocument? = nil,
        docURL: URL? = nil,
        signal: FeishuSyncCancellationSignal? = nil,
        onProgress: ProgressCallback? = nil
    ) async throws -> PullResult {
        if signal?.isCancelled == true { throw PullError.cancelled }
        onProgress?(.pullingDocument)
        let pulled: (blocks: [FeishuBlock], revisionId: Int)
        do {
            pulled = try await apiClient.pullDocument(documentId: token.rawValue)
        } catch let apiError as FeishuAPIError {
            throw PullError.apiFailed(apiError)
        }

        if signal?.isCancelled == true { throw PullError.cancelled }
        let conversion = FeishuStructuralConverter.toMarkdownWithWarnings(pulled.blocks)
        let initialBody = MarkdownEngine.parseDocument(source: conversion.value).body

        // If wired, route every `feishu://image/<token>` through the
        // download stage so the WebView can actually render the image
        // off disk. Without the stage, srcs stay as-is and the user
        // gets broken-image placeholders — see #21 for the bug report.
        let parsedBody: TiptapNode
        let imageReport: FeishuImageDownloadStage.Report?
        if let stage = imageDownloadStage {
            var startReported = false
            let (rewritten, report) = await stage.process(body: initialBody) { index, total in
                if !startReported {
                    onProgress?(.imageStageStarted(total: total))
                    startReported = true
                }
                onProgress?(.imageDownloaded(index: index, total: total))
            }
            if !startReported {
                onProgress?(.imageStageStarted(total: 0))
            }
            onProgress?(.imageStageFinished)
            // Cancel observed during the download walk shows up as
            // partially-rewritten body + .failedTokens covering the
            // not-yet-attempted ones. We honor the signal AFTER the
            // stage returns rather than mid-walk because a half-
            // applied stage state would lose track of what was
            // downloaded vs. what wasn't.
            if signal?.isCancelled == true { throw PullError.cancelled }
            parsedBody = rewritten
            imageReport = report
        } else {
            parsedBody = initialBody
            imageReport = nil
        }

        let placeholderRefs = collectPlaceholderRefs(in: parsedBody)
        let mergedFrontmatter = mergeFrontmatter(
            existing: existing?.frontmatter,
            token: token,
            revisionId: pulled.revisionId,
            placeholderRefs: placeholderRefs,
            docURL: docURL
        )

        let updated = MarkdownEngine.ParsedDocument(
            frontmatter: mergedFrontmatter, body: parsedBody
        )
        onProgress?(.done)
        return PullResult(
            updatedDocument: updated,
            warnings: conversion.warnings,
            imageReport: imageReport
        )
    }

    // MARK: - frontmatter merge

    /// Preserve existing user fields + unrecognized `feishu.*` keys; stamp
    /// `docToken` and `lastPulledRevision`; rewrite `placeholderBlocks` to
    /// reflect the actual placeholder set in the freshly-pulled body. The
    /// existing `placeholderBlocks` from before the pull is irrelevant —
    /// the body itself has been replaced, and the index must mirror what
    /// the user's editor will actually see after this returns. This is
    /// the symmetric counterpart of push's step3.1 integrity check
    /// (FeishuPushCoordinator.collectPlaceholderBlockIds): both sides
    /// agree the frontmatter index is the truth source for "which blocks
    /// are placeholders" and must always match the body.
    ///
    /// `lastPushedAt` carries forward (it's still the last push
    /// timestamp on this side). `docURL`, `unknownFields` carry forward
    /// unchanged.
    ///
    /// `hasFence = true` whenever there's any feishu metadata, so the
    /// serializer always emits the leading `---` block — pulling without
    /// frontmatter shouldn't produce a fenceless file (the next save
    /// would lose the binding).
    private func mergeFrontmatter(
        existing: Frontmatter?,
        token: DocToken,
        revisionId: Int,
        placeholderRefs: [PlaceholderBlockRef],
        docURL: URL?
    ) -> Frontmatter {
        let userFields: [UserField] = existing?.userFields ?? []
        var feishuOriginalIndex = existing?.feishuOriginalIndex

        var feishu = existing?.feishu ?? FeishuFrontmatter()
        feishu.docToken = token
        feishu.lastPulledRevision = revisionId
        feishu.placeholderBlocks = placeholderRefs
        // Stamp the human-navigable doc URL when the caller supplies one
        // (URL-import path). Feishu doc URLs live on a tenant subdomain that
        // can't be reconstructed from the token alone, so this is the only
        // moment we learn it. When nil (plain token pull), carry forward the
        // prior value untouched — never clobber a known URL back to nil.
        if let docURL { feishu.docURL = docURL }
        // lastPushedAt, unknownFields all round-trip from priorFeishu untouched.

        if feishuOriginalIndex == nil {
            feishuOriginalIndex = userFields.count
        }

        return Frontmatter(
            userFields: userFields,
            feishu: feishu,
            feishuOriginalIndex: feishuOriginalIndex,
            hasFence: true
        )
    }

    // MARK: - placeholder index extraction

    /// Walk the freshly-pulled body and collect every
    /// `feishu_placeholder_block` node into a `PlaceholderBlockRef` —
    /// matches the field set FrontmatterEngine writes back into YAML
    /// (block_id / type / title). The push side's
    /// `collectPlaceholderBlockIds` only needs ids; pull writes the full
    /// ref because the frontmatter must round-trip without losing the
    /// human-readable type/title hints the converter set.
    ///
    /// Returns refs in document order; deduped by block_id (the body in
    /// theory could carry the same id twice if a foreign tool wrote it,
    /// the index should still be a set).
    private func collectPlaceholderRefs(in body: TiptapNode) -> [PlaceholderBlockRef] {
        var refs: [PlaceholderBlockRef] = []
        var seen: Set<String> = []
        walkForPlaceholders(node: body, refs: &refs, seen: &seen)
        return refs
    }

    private func walkForPlaceholders(
        node: TiptapNode,
        refs: inout [PlaceholderBlockRef],
        seen: inout Set<String>
    ) {
        if node.type == "feishu_placeholder_block" {
            guard case .string(let id)? = node.attrs?["block_id"], !id.isEmpty,
                  !seen.contains(id) else { return }
            seen.insert(id)
            let type: String
            if case .string(let t)? = node.attrs?["type"] { type = t } else { type = "" }
            var title: String?
            if case .string(let t)? = node.attrs?["title"], !t.isEmpty { title = t }
            refs.append(PlaceholderBlockRef(blockId: id, type: type, title: title))
            return
        }
        for child in node.content ?? [] {
            walkForPlaceholders(node: child, refs: &refs, seen: &seen)
        }
    }
}
