import Foundation

/// Pull-side counterpart of `FeishuImageUploadStage` — walks a
/// freshly-converted Tiptap body, finds every `feishu://image/<token>`
/// reference, downloads the bytes from Feishu's drive media endpoint,
/// hands them to an `ImageWriter` (production wires `AssetsManager`),
/// and rewrites the `src` to `donemd-asset://<filename>`.
///
/// Without this stage, pulled documents render with broken images:
/// the WebView can't resolve `feishu://image/...`, so each Feishu
/// image becomes a missing-asset placeholder on screen.
///
/// Pure-ish async transform: input body in, rewritten body + report
/// out. Per-pull dedup so the same image_token appearing twice in a
/// doc only hits the network once. Cross-pull dedup is the
/// `ImageWriter`'s job (AssetsManager hashes the bytes).
public final class FeishuImageDownloadStage {

    /// Writes downloaded image bytes to the per-document assets store
    /// and returns a stable filename the body can reference via
    /// `donemd-asset://<filename>`. Production wires AssetsManager;
    /// tests wire an in-memory dict.
    public protocol ImageWriter: AnyObject {
        /// Persist `data` (with the given MIME) and return the
        /// `donemd-asset://<filename>` URL the body should reference.
        /// Throws on disk write failure — the stage soft-skips that
        /// node so a single bad write doesn't blow up the whole pull.
        func writeDownloadedImage(data: Data, mimeType: String) throws -> URL
    }

    public struct Report: Equatable {
        public var downloadedCount: Int
        /// Tokens we couldn't fetch (network / 404 / disk write
        /// failure). The body for those nodes keeps the
        /// `feishu://image/<token>` src so the user can re-pull
        /// later instead of losing the reference forever.
        public var failedTokens: [String]

        public init(
            downloadedCount: Int = 0,
            failedTokens: [String] = []
        ) {
            self.downloadedCount = downloadedCount
            self.failedTokens = failedTokens
        }
    }

    private let api: FeishuAPIClient
    private let writer: ImageWriter

    public init(api: FeishuAPIClient, writer: ImageWriter) {
        self.api = api
        self.writer = writer
    }

    public typealias DownloadProgressCallback = (_ index: Int, _ total: Int) -> Void

    /// Walk `body`, download each unique `feishu://image/<token>`
    /// once, and return a body with every such `src` rewritten to
    /// `donemd-asset://<filename>`. Failures are reported (not
    /// thrown) so a single bad image doesn't lose the whole pull —
    /// the body still surfaces, with broken refs left as-is for the
    /// user to retry.
    public func process(
        body: TiptapNode,
        onProgress: DownloadProgressCallback? = nil
    ) async -> (TiptapNode, Report) {
        var report = Report()
        var resolvedURLByToken: [String: String] = [:]

        // Pre-scan to know the upper-bound download total.
        let total = countUniqueFeishuImageTokens(in: body)
        var downloadedSoFar = 0

        let rewritten = await rewrite(
            node: body,
            resolved: &resolvedURLByToken,
            downloadedSoFar: &downloadedSoFar,
            downloadTotal: total,
            onProgress: onProgress,
            report: &report
        )
        return (rewritten, report)
    }

    // MARK: - private

    private func countUniqueFeishuImageTokens(in node: TiptapNode) -> Int {
        var seen: Set<String> = []
        collectFeishuImageTokens(node: node, into: &seen)
        return seen.count
    }

    private func collectFeishuImageTokens(node: TiptapNode, into seen: inout Set<String>) {
        if node.type == "image",
           case .string(let src)? = node.attrs?["src"],
           let token = feishuImageToken(from: src) {
            seen.insert(token)
        }
        for child in node.content ?? [] {
            collectFeishuImageTokens(node: child, into: &seen)
        }
    }

    private func rewrite(
        node: TiptapNode,
        resolved: inout [String: String],
        downloadedSoFar: inout Int,
        downloadTotal: Int,
        onProgress: DownloadProgressCallback?,
        report: inout Report
    ) async -> TiptapNode {
        var copy = node

        if copy.type == "image" {
            await rewriteImageNode(
                &copy,
                resolved: &resolved,
                downloadedSoFar: &downloadedSoFar,
                downloadTotal: downloadTotal,
                onProgress: onProgress,
                report: &report
            )
        }

        if let children = copy.content {
            var newChildren: [TiptapNode] = []
            newChildren.reserveCapacity(children.count)
            for child in children {
                newChildren.append(
                    await rewrite(
                        node: child,
                        resolved: &resolved,
                        downloadedSoFar: &downloadedSoFar,
                        downloadTotal: downloadTotal,
                        onProgress: onProgress,
                        report: &report
                    )
                )
            }
            copy.content = newChildren
        }

        return copy
    }

    private func rewriteImageNode(
        _ node: inout TiptapNode,
        resolved: inout [String: String],
        downloadedSoFar: inout Int,
        downloadTotal: Int,
        onProgress: DownloadProgressCallback?,
        report: inout Report
    ) async {
        guard case .string(let src)? = node.attrs?["src"],
              let token = feishuImageToken(from: src) else {
            // Not a feishu:// image — leave as-is (could be a remote
            // https:// or a donemd-asset:// from a prior round-trip).
            return
        }

        // Per-pull dedup.
        if let cachedURL = resolved[token] {
            var attrs = node.attrs ?? [:]
            attrs["src"] = .string(cachedURL)
            node.attrs = attrs
            return
        }

        let downloaded: (data: Data, mimeType: String)
        do {
            downloaded = try await api.downloadImage(token: token)
        } catch {
            report.failedTokens.append(token)
            debugLog("[pull] image download failed token=\(token): \(error)")
            return  // leave src as-is so the user can retry later
        }

        let assetURL: URL
        do {
            assetURL = try writer.writeDownloadedImage(
                data: downloaded.data, mimeType: downloaded.mimeType
            )
        } catch {
            report.failedTokens.append(token)
            debugLog("[pull] image write failed token=\(token): \(error)")
            return
        }

        downloadedSoFar += 1
        report.downloadedCount += 1
        onProgress?(downloadedSoFar, downloadTotal)
        resolved[token] = assetURL.absoluteString

        var attrs = node.attrs ?? [:]
        attrs["src"] = .string(assetURL.absoluteString)
        node.attrs = attrs
    }

    /// Extract `<token>` from `feishu://image/<token>`. Returns nil for
    /// any other src form.
    private func feishuImageToken(from src: String) -> String? {
        let prefix = "feishu://image/"
        guard src.hasPrefix(prefix) else { return nil }
        let token = String(src.dropFirst(prefix.count))
        return token.isEmpty ? nil : token
    }
}

/// AssetsManager adopts `ImageWriter` by routing every download through
/// `importImage`, which already SHA-hashes the bytes for cross-pull
/// dedup. The stage just hands data + mime in and uses the resulting
/// `assetURL` (`donemd-asset://<sha>.<ext>`).
extension AssetsManager: FeishuImageDownloadStage.ImageWriter {
    public func writeDownloadedImage(data: Data, mimeType: String) throws -> URL {
        let imported = try importImage(data: data, mimeType: mimeType)
        return imported.assetURL
    }
}
