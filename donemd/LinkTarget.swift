import Foundation

/// How Done.md should open a link's `href`. The Visual editor forwards the raw
/// href on a single click (see `web/src/link-open.ts` → bridge `openLink`);
/// `VisualWebView.handleOpenLink` calls `classify` to pick the action, then
/// resolves + opens it via `NSWorkspace`.
///
/// Kept pure and dependency-free so it's unit-testable in isolation (see
/// `LinkTargetTests`), mirroring `FeishuURLDetector`'s shape. Path *resolution*
/// (expanding `~`, joining a relative path onto the document directory) and the
/// existence / executable checks live in the caller, because they need the
/// document's location and the filesystem — this type only decides intent.
enum LinkTarget: Equatable {
    /// An absolute web / mail URL — open with the system default handler
    /// (browser for http(s), mail client for mailto).
    case web(URL)
    /// A filesystem path, possibly relative or `~`-prefixed. When
    /// `mayFallBackToWeb` is true the string was schemeless but dot-bearing
    /// (e.g. `example.com` or `notes.md`) and therefore ambiguous: the caller
    /// tries the local file first and, only if it doesn't exist, opens
    /// `https://<path>` instead.
    case localPath(String, mayFallBackToWeb: Bool)
    /// Empty, an in-page `#anchor`, or a dangerous / unknown scheme
    /// (javascript:, data:, vbscript:, …) — do nothing.
    case reject

    /// Leading `scheme:` of a string, lowercased, per RFC 3986's
    /// `ALPHA *( ALPHA / DIGIT / "+" / "-" / "." )`. Nil for paths (`/x`,
    /// `~/x`, `./x`), bare names (`notes.md`), and anchors (`#s`) — none of
    /// which carry a colon-terminated scheme.
    private static let schemeRegex = try! NSRegularExpression(
        pattern: #"^([a-zA-Z][a-zA-Z0-9+.\-]*):"#
    )

    private static func scheme(of s: String) -> String? {
        let range = NSRange(s.startIndex..<s.endIndex, in: s)
        guard let match = schemeRegex.firstMatch(in: s, options: [], range: range),
              let r = Range(match.range(at: 1), in: s) else {
            return nil
        }
        return String(s[r]).lowercased()
    }

    static func classify(_ rawHref: String) -> LinkTarget {
        let href = rawHref.trimmingCharacters(in: .whitespacesAndNewlines)
        if href.isEmpty { return .reject }
        // In-page anchors (`#section`) aren't a navigation target we support.
        if href.hasPrefix("#") { return .reject }

        if let scheme = scheme(of: href) {
            switch scheme {
            case "http", "https", "mailto":
                if let url = URL(string: href) { return .web(url) }
                return .reject
            case "file":
                // Normalize file:// to a plain path so the caller's file
                // handling (existence check, executable guard) applies.
                if let url = URL(string: href) {
                    return .localPath(url.path, mayFallBackToWeb: false)
                }
                return .reject
            default:
                // javascript:, data:, vbscript:, and any other unknown scheme.
                return .reject
            }
        }

        // Schemeless. Explicit path forms are unambiguously local files.
        if href.hasPrefix("/") || href.hasPrefix("~")
            || href.hasPrefix("./") || href.hasPrefix("../") {
            return .localPath(href, mayFallBackToWeb: false)
        }

        // A bare, schemeless token. If it carries a dot and no spaces it could
        // be either a domain (`example.com`) or a relative file with an
        // extension (`notes.md`) — indistinguishable without a TLD list, so let
        // the caller try the local file first and fall back to https. A
        // dot-less token (`README`) can only sensibly be a relative file.
        let mayFallBackToWeb = href.contains(".") && !href.contains(" ")
        return .localPath(href, mayFallBackToWeb: mayFallBackToWeb)
    }
}
