import Foundation
import WebKit

/// Resolves `donemd-asset://<filename>` requests issued by the WebView when
/// the editor renders an `<img>` whose src is in our internal scheme.
///
/// Markdown source on disk stores `./assets/<filename>` (relative path,
/// stable, git-friendly). The runtime `<img src>` inside Tiptap uses
/// `donemd-asset://<filename>`. This handler bridges the two: when the
/// WebView fetches `donemd-asset://abc.png`, we ask `AssetsManager` for
/// the on-disk URL and stream the bytes back.
///
/// Each document gets its own handler instance; the handler is kept alive
/// by `WKWebViewConfiguration`'s strong reference.
final class AssetURLSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "donemd-asset"
    static let urlPrefix = "\(scheme)://"

    weak var assetsManager: AssetsManager?

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        let request = urlSchemeTask.request
        guard let url = request.url,
              let filename = Self.filename(from: url) else {
            urlSchemeTask.didFailWithError(error(.badRequest, "malformed asset URL"))
            return
        }
        guard let manager = assetsManager else {
            urlSchemeTask.didFailWithError(error(.notFound, "no AssetsManager attached"))
            return
        }
        guard let fileURL = manager.storedFileURL(forFilename: filename) else {
            urlSchemeTask.didFailWithError(error(.notFound, "no asset named \(filename)"))
            return
        }

        let mimeType = Self.mimeType(forFilename: filename)
        let rangeHeader = request.value(forHTTPHeaderField: "Range")

        do {
            let attrs = try FileManager.default.attributesOfItem(atPath: fileURL.path)
            let totalLength = (attrs[.size] as? Int) ?? 0

            // `<video>` playback (#88) issues HTTP Range requests to seek. When
            // one is present we answer 206 Partial Content and stream only the
            // requested slice via FileHandle — a multi-hundred-MB clip never
            // gets loaded into memory whole. Images have no Range header and
            // fall through to the plain 200 path (unchanged behavior, now with
            // Accept-Ranges advertised so media can seek).
            if let rangeHeader,
               let (start, end) = Self.parseByteRange(rangeHeader, totalLength: totalLength) {
                let handle = try FileHandle(forReadingFrom: fileURL)
                defer { try? handle.close() }
                try handle.seek(toOffset: UInt64(start))
                let data = handle.readData(ofLength: end - start + 1)
                let response = HTTPURLResponse(
                    url: url,
                    statusCode: 206,
                    httpVersion: "HTTP/1.1",
                    headerFields: [
                        "Content-Type": mimeType,
                        "Content-Length": "\(data.count)",
                        "Content-Range": "bytes \(start)-\(end)/\(totalLength)",
                        "Accept-Ranges": "bytes",
                    ]
                )!
                urlSchemeTask.didReceive(response)
                urlSchemeTask.didReceive(data)
                urlSchemeTask.didFinish()
            } else {
                let data = try Data(contentsOf: fileURL)
                let response = HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: [
                        "Content-Type": mimeType,
                        "Content-Length": "\(data.count)",
                        "Accept-Ranges": "bytes",
                    ]
                )!
                urlSchemeTask.didReceive(response)
                urlSchemeTask.didReceive(data)
                urlSchemeTask.didFinish()
            }
        } catch {
            urlSchemeTask.didFailWithError(self.error(.readFailed, "read \(filename): \(error)"))
            return
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        // Synchronous handler — there is no in-flight work to cancel.
    }

    // MARK: Static helpers (also used by tests)

    /// Parse a `donemd-asset://<filename>` URL into the filename component.
    /// Returns `nil` if the URL doesn't use our scheme.
    static func filename(from url: URL) -> String? {
        let absolute = url.absoluteString
        guard absolute.hasPrefix(urlPrefix) else { return nil }
        let after = String(absolute.dropFirst(urlPrefix.count))
        // Trim any query / fragment ProseMirror may append.
        let cleaned = after.split(separator: "?", maxSplits: 1).first.map(String.init) ?? after
        let trimmed = cleaned.split(separator: "#", maxSplits: 1).first.map(String.init) ?? cleaned
        // Remove any leading slashes (in case JS produces donemd-asset:///x).
        return trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    static func mimeType(forFilename filename: String) -> String {
        let ext = (filename as NSString).pathExtension.lowercased()
        switch ext {
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "heic", "heif": return "image/heic"
        case "svg": return "image/svg+xml"
        case "tiff": return "image/tiff"
        case "bmp": return "image/bmp"
        // Local video (#88, ADR-0009).
        case "mp4": return "video/mp4"
        case "mov", "qt": return "video/quicktime"
        case "m4v": return "video/x-m4v"
        case "webm": return "video/webm"
        default: return "application/octet-stream"
        }
    }

    /// Parse a single-range HTTP `Range` header (`bytes=START-END`,
    /// `bytes=START-`, or `bytes=-SUFFIX`) into a concrete, satisfiable
    /// `[start, end]` byte range clamped to `totalLength`. Returns `nil` for
    /// a malformed header, a multipart range (comma), or an unsatisfiable
    /// range — the caller then serves the full 200 response instead.
    static func parseByteRange(_ header: String, totalLength: Int) -> (start: Int, end: Int)? {
        guard totalLength > 0 else { return nil }
        let trimmed = header.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("bytes=") else { return nil }
        let spec = String(trimmed.dropFirst("bytes=".count))
        guard !spec.contains(",") else { return nil } // no multipart ranges
        let parts = spec.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let startStr = parts[0].trimmingCharacters(in: .whitespaces)
        let endStr = parts[1].trimmingCharacters(in: .whitespaces)

        let start: Int
        let end: Int
        if startStr.isEmpty {
            // Suffix form `bytes=-N` → the last N bytes.
            guard let suffix = Int(endStr), suffix > 0 else { return nil }
            start = max(0, totalLength - suffix)
            end = totalLength - 1
        } else {
            guard let s = Int(startStr), s < totalLength else { return nil }
            start = s
            if endStr.isEmpty {
                end = totalLength - 1
            } else {
                guard let e = Int(endStr) else { return nil }
                end = min(e, totalLength - 1)
            }
        }
        guard start <= end else { return nil }
        return (start, end)
    }

    // MARK: Errors

    private enum ErrorCode: Int {
        case badRequest = -1
        case notFound = -2
        case readFailed = -3
    }

    private func error(_ code: ErrorCode, _ message: String) -> NSError {
        NSError(
            domain: "com.shampoo.donemd.AssetURLSchemeHandler",
            code: code.rawValue,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}
