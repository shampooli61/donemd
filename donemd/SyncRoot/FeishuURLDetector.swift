import Foundation

/// Parsed result of a recognized Feishu / Lark document URL.
///
/// `kind` distinguishes the three URL shapes we accept. Only `.docx` carries
/// a doc_token directly usable by the index; `.wiki` and `.short` need an
/// API round-trip to resolve, which `SyncBindingResolver` defers to the
/// caller via `.requiresAPIResolution`.
public struct FeishuDocURL: Equatable {
    public enum Kind: Equatable {
        /// `https://<host>/docx/<token>` — direct docx URL. `token` is the
        /// real `doc_token` and can be looked up in the scanner index.
        case docx
        /// `https://<host>/wiki/<node_token>` — wiki node URL. `token` is a
        /// node_token that must be exchanged for a docx token via API.
        case wiki
        /// `https://<host>/<short>` — short link. Token is opaque and must
        /// be expanded via API before any local lookup.
        case short
    }

    public let kind: Kind
    public let token: String
    public let originalURL: String

    public init(kind: Kind, token: String, originalURL: String) {
        self.kind = kind
        self.token = token
        self.originalURL = originalURL
    }
}

/// Detect Feishu / Lark / Mioffice document URLs in arbitrary pasted text.
///
/// The detector is deliberately permissive on host (any subdomain of
/// `feishu.cn`, `larksuite.com`, `f.mioffice.cn`) and strict on path —
/// only `/docx/<token>`, `/wiki/<token>`, or `/<short>` shapes match.
/// Anything else (github, notion, plain https, schemeless) returns nil.
public enum FeishuURLDetector {

    /// Hosts we accept. Match on suffix so `bytedance.feishu.cn`,
    /// `xxx.larksuite.com`, etc. all qualify.
    private static let acceptedHostSuffixes = [
        "feishu.cn",
        "larksuite.com",
        "f.mioffice.cn",
    ]

    /// Token shape — same guard `SyncRootScanner` applies to frontmatter
    /// values. Keeps junk URLs (`/docx/.`, `/wiki/`) from creating bogus
    /// resolutions downstream.
    private static let tokenPattern = try! NSRegularExpression(
        pattern: #"^[A-Za-z][A-Za-z0-9_-]{5,}$"#
    )

    /// First Feishu URL found in the input, or nil. Callers paste plain
    /// text (a single URL), markdown links, or messy clipboards — the
    /// detector handles all three by scanning for the first http(s) token.
    public static func extract(_ input: String) -> FeishuDocURL? {
        for raw in candidateURLStrings(in: input) {
            if let parsed = parse(raw) {
                return parsed
            }
        }
        return nil
    }

    /// Parse one already-isolated URL string. Public for callers that
    /// already have a URL and want to skip the text scan.
    public static func parse(_ raw: String) -> FeishuDocURL? {
        guard let url = URL(string: raw) else { return nil }
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return nil }
        guard let host = url.host?.lowercased(),
              acceptedHostSuffixes.contains(where: { host == $0 || host.hasSuffix(".\($0)") }) else {
            return nil
        }
        let segments = url.path
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        guard let first = segments.first else { return nil }

        if first == "docx", segments.count >= 2 {
            let token = segments[1]
            guard isValidToken(token) else { return nil }
            return FeishuDocURL(kind: .docx, token: token, originalURL: raw)
        }
        if first == "wiki", segments.count >= 2 {
            let token = segments[1]
            guard isValidToken(token) else { return nil }
            return FeishuDocURL(kind: .wiki, token: token, originalURL: raw)
        }
        // Short link: single-segment path on a Feishu host, e.g.
        // https://feishu.cn/X3kAbCdEfG. Reject reserved app paths so we
        // don't mistake `https://feishu.cn/login` for a doc.
        if segments.count == 1, !reservedShortLinkPrefixes.contains(first) {
            guard isValidToken(first) else { return nil }
            return FeishuDocURL(kind: .short, token: first, originalURL: raw)
        }
        return nil
    }

    private static let reservedShortLinkPrefixes: Set<String> = [
        "login", "logout", "signin", "signup", "auth",
        "home", "settings", "help", "about", "download",
        "drive", "sheets", "base", "minutes", "mail", "calendar",
        "wiki", "docx", "doc", "sheet", "bitable",
        "api", "open-apis", "anycross",
    ]

    private static func isValidToken(_ token: String) -> Bool {
        let range = NSRange(token.startIndex..<token.endIndex, in: token)
        return tokenPattern.firstMatch(in: token, options: [], range: range) != nil
    }

    /// Pull URL-shaped substrings out of arbitrary text. Cheap and
    /// permissive — the real validation happens in `parse`.
    private static func candidateURLStrings(in input: String) -> [String] {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return [input]
        }
        let range = NSRange(input.startIndex..<input.endIndex, in: input)
        let matches = detector.matches(in: input, options: [], range: range)
        if matches.isEmpty {
            // No link match — fall back to treating the trimmed input as a
            // candidate so callers passing a bare URL still resolve.
            let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? [] : [trimmed]
        }
        return matches.compactMap { match -> String? in
            guard let r = Range(match.range, in: input) else { return nil }
            return String(input[r])
        }
    }
}
