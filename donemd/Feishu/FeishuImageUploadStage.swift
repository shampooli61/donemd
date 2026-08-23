import Foundation

/// v2 Slice 9a-step2 (#50) — push pipeline stage that resolves local
/// `donemd-asset://<filename>` image refs to Feishu `image_token`s.
///
/// The Feishu wire side cannot resolve `donemd-asset://`, so an image whose
/// `src` is left as-is becomes a broken thumbnail in the rendered docx. This
/// stage walks the body once before block-conversion, hands every local-asset
/// `<img>` to `FeishuAPIClient.uploadImage`, and rewrites the `src` to
/// `feishu://image/<token>`. The downstream `FeishuStructuralConverter`
/// already special-cases that scheme (see `FeishuStructuralConverter.swift`
/// case "image") and emits an `ImagePayload(token:…)` for it.
///
/// Pure-ish async transform: input body in, rewritten body + report out.
/// Holds no per-push state across invocations beyond the dependencies — a
/// fresh stage per push is fine, but reusing one across pushes is also safe
/// and gets cross-push cache benefits via the underlying `FeishuAPIClient`'s
/// SHA-256 image cache.
public final class FeishuImageUploadStage {

    /// Resolves `donemd-asset://<filename>` to bytes + mime. The protocol
    /// keeps the stage testable — production wires `AssetsManager`, tests
    /// wire an in-memory dictionary.
    public protocol AssetReader: AnyObject {
        /// Return `nil` if the asset is missing on disk. The stage soft-skips
        /// that node so a missing image doesn't blow up the entire push.
        func readAsset(filename: String) -> (data: Data, mimeType: String)?
    }

    /// Counts the four outcomes per `process()` call. `uploadedCount` is
    /// "stage decided to call `uploadImage`", which is the user-visible number
    /// (the API client's internal SHA-256 cache may still short-circuit some
    /// of those — that's invisible to the stage and to this report).
    public struct Report: Equatable {
        public var uploadedCount: Int
        public var skippedRemote: Int
        public var skippedMissing: [String]
        /// Local video filenames (#88). Feishu has no local-video upload path
        /// in v1, so the push skips every `video` node: the local file and its
        /// disk `<video>` line are kept untouched, and this list surfaces a
        /// soft warning ("N 段本地视频未同步到飞书（本地已保留）") without
        /// blocking the rest of the push. Isolation is deliberate — see the
        /// 本地视频 CONTEXT entry and ADR-0009.
        public var skippedVideos: [String]

        public init(
            uploadedCount: Int = 0,
            skippedRemote: Int = 0,
            skippedMissing: [String] = [],
            skippedVideos: [String] = []
        ) {
            self.uploadedCount = uploadedCount
            self.skippedRemote = skippedRemote
            self.skippedMissing = skippedMissing
            self.skippedVideos = skippedVideos
        }
    }

    private let api: FeishuAPIClient
    private let reader: AssetReader

    public init(api: FeishuAPIClient, reader: AssetReader) {
        self.api = api
        self.reader = reader
    }

    /// Per-image upload progress callback. `index` is 1-based and counts
    /// only the images the stage actually decided to upload (i.e. excludes
    /// remote-skipped, missing-skipped, and dedup-cache hits). `total` is
    /// the upper bound: number of unique local filenames seen on the
    /// pre-scan. The two can disagree by the end if a unique filename
    /// becomes a missing-skip mid-walk; that's expected, the report carries
    /// the truth.
    public typealias UploadProgressCallback = (_ index: Int, _ total: Int) -> Void

    /// Walk the body, upload every `donemd-asset://<filename>` image once,
    /// and return a body with every such `src` rewritten to
    /// `feishu://image/<token>`. Any `FeishuAPIError` raised by `uploadImage`
    /// propagates — the caller (PushCoordinator) wraps it as `.apiFailed`.
    ///
    /// `onProgress` (optional) is called once per `uploadImage` API call
    /// with the running 1-based index + the pre-scanned total of unique
    /// local filenames. Used by step4 lite for the user-facing
    /// "uploaded N/M" status line.
    public func process(
        body: TiptapNode,
        documentId: String,
        onProgress: UploadProgressCallback? = nil
    ) async throws -> (TiptapNode, Report) {
        var report = Report()
        // Per-push dedup: if the same local filename appears N times in the
        // doc, upload it once and reuse the token. This is a stage-level
        // shortcut; the API client's SHA-256 cache handles the cross-push
        // case independently.
        var resolvedTokensByFilename: [String: String] = [:]

        // Pre-scan to know the upper-bound upload total; the running index
        // increments inside rewriteImageNode every time a network upload
        // actually happens.
        var uploadedSoFar = 0
        let total = countUniqueLocalAssetFilenames(in: body)

        let rewritten = try await rewrite(
            node: body,
            tokens: &resolvedTokensByFilename,
            uploadedSoFar: &uploadedSoFar,
            uploadTotal: total,
            onProgress: onProgress,
            report: &report,
            documentId: documentId
        )
        return (rewritten, report)
    }

    /// Pre-scan: walk the tree, collect every local-asset filename, return
    /// the deduped count. Out-of-scope srcs (https / feishu:// / unknown)
    /// don't count toward `total` — they're never uploaded.
    private func countUniqueLocalAssetFilenames(in node: TiptapNode) -> Int {
        var seen: Set<String> = []
        collectLocalAssetFilenames(node: node, into: &seen)
        return seen.count
    }

    private func collectLocalAssetFilenames(node: TiptapNode, into seen: inout Set<String>) {
        if node.type == "image",
           case .string(let src)? = node.attrs?["src"],
           src.hasPrefix(donemdAssetPrefix) {
            let filename = String(src.dropFirst(donemdAssetPrefix.count))
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if !filename.isEmpty {
                seen.insert(filename)
            }
        }
        for child in node.content ?? [] {
            collectLocalAssetFilenames(node: child, into: &seen)
        }
    }

    private func rewrite(
        node: TiptapNode,
        tokens: inout [String: String],
        uploadedSoFar: inout Int,
        uploadTotal: Int,
        onProgress: UploadProgressCallback?,
        report: inout Report,
        documentId: String
    ) async throws -> TiptapNode {
        var copy = node

        if copy.type == "image" {
            try await rewriteImageNode(
                &copy,
                tokens: &tokens,
                uploadedSoFar: &uploadedSoFar,
                uploadTotal: uploadTotal,
                onProgress: onProgress,
                report: &report,
                documentId: documentId
            )
        } else if copy.type == "video" {
            // Local video (#88): Feishu has no upload path, so skip it —
            // record the filename for the soft warning, leave the node's src
            // untouched (the downstream converter drops the node), and keep
            // the local asset. Never blocks the push.
            recordSkippedVideo(copy, into: &report)
        }

        if let children = copy.content {
            var newChildren: [TiptapNode] = []
            newChildren.reserveCapacity(children.count)
            for child in children {
                newChildren.append(
                    try await rewrite(
                        node: child,
                        tokens: &tokens,
                        uploadedSoFar: &uploadedSoFar,
                        uploadTotal: uploadTotal,
                        onProgress: onProgress,
                        report: &report,
                        documentId: documentId
                    )
                )
            }
            copy.content = newChildren
        }

        return copy
    }

    private func rewriteImageNode(
        _ node: inout TiptapNode,
        tokens: inout [String: String],
        uploadedSoFar: inout Int,
        uploadTotal: Int,
        onProgress: UploadProgressCallback?,
        report: inout Report,
        documentId: String
    ) async throws {
        guard case .string(let src)? = node.attrs?["src"] else {
            // Image node with no src — nothing to do, count as remote-skip
            // since we definitely can't upload it.
            report.skippedRemote += 1
            return
        }

        // Already a Feishu token — leave it alone. This happens on re-push of
        // a doc whose previous push already rewrote everything.
        if src.hasPrefix("feishu://image/") {
            report.skippedRemote += 1
            return
        }

        // External URL — Feishu renders these as remote refs; we don't
        // download + re-upload remote bytes from here. (A future stage could
        // mirror http(s) images into Feishu for offline reliability, but
        // that's a separate decision.)
        if src.hasPrefix("http://") || src.hasPrefix("https://") {
            report.skippedRemote += 1
            return
        }

        guard src.hasPrefix(donemdAssetPrefix) else {
            // Unknown scheme (bare path, file:// , data:...). Out of scope
            // for step2 — count as remote so the report still adds up.
            report.skippedRemote += 1
            return
        }

        let filename = String(src.dropFirst(donemdAssetPrefix.count))
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        if let cached = tokens[filename] {
            // Same filename appeared earlier in this push — reuse its token,
            // don't re-upload. Doesn't count as a fresh upload either (the
            // network call already counted the first time).
            assignFeishuToken(cached, to: &node)
            return
        }

        guard let payload = reader.readAsset(filename: filename) else {
            report.skippedMissing.append(filename)
            return
        }

        let token = try await api.uploadImage(
            data: payload.data,
            mimeType: payload.mimeType,
            fileName: filename,
            documentId: documentId
        )
        tokens[filename] = token
        report.uploadedCount += 1
        uploadedSoFar += 1
        onProgress?(uploadedSoFar, uploadTotal)
        assignFeishuToken(token, to: &node)
    }

    /// Record a skipped local video (#88). Prefer the asset filename for a
    /// legible warning; fall back to a generic label if the src is missing or
    /// isn't a `donemd-asset://` ref (shouldn't happen for a real video node,
    /// but the report should still count it).
    private func recordSkippedVideo(_ node: TiptapNode, into report: inout Report) {
        if case .string(let src)? = node.attrs?["src"], src.hasPrefix(donemdAssetPrefix) {
            let filename = String(src.dropFirst(donemdAssetPrefix.count))
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            report.skippedVideos.append(filename.isEmpty ? "(视频)" : filename)
        } else {
            report.skippedVideos.append("(视频)")
        }
    }

    private let donemdAssetPrefix = "donemd-asset://"

    private func assignFeishuToken(_ token: String, to node: inout TiptapNode) {
        var attrs = node.attrs ?? [:]
        attrs["src"] = .string("feishu://image/\(token)")
        node.attrs = attrs
    }
}
