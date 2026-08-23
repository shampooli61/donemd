import Foundation

/// Result of asking "the user pasted this Feishu URL — what should the UI
/// do?". Four cases — three local, one deferred to API.
public enum SyncBindingResolution: Equatable {
    /// Index hit, single match. UI default action: open this file.
    case openExisting(URL)

    /// Index hit, multiple matches across roots (token conflict per
    /// ADR-0006). UI must let the user pick one. URLs are in priority
    /// order — first entry is the current `lookup` winner.
    case ambiguous([URL])

    /// No local copy. UI default action: pull doc into the default sync
    /// root. `token` is the doc_token to feed the puller.
    case createNew(token: DocToken)

    /// Wiki / short link: the URL doesn't carry a docx token directly,
    /// so we can't resolve locally without an API round-trip. UI must
    /// either resolve via APIClient (v2-5) and re-call, or fall back to
    /// "fetch over API and pull". The `FeishuDocURL` is forwarded as-is
    /// so the caller has the original kind + token + URL string.
    case requiresAPIResolution(FeishuDocURL)
}

/// Pure resolver: a Feishu URL plus the scanner's index produces one of
/// four UI dispositions. Holds no state, owns no IO — `SyncRootScanner`
/// already encapsulates index access. This is just the policy layer.
public struct SyncBindingResolver {

    private let scanner: SyncRootScanner

    public init(scanner: SyncRootScanner) {
        self.scanner = scanner
    }

    public func resolve(_ url: FeishuDocURL) async -> SyncBindingResolution {
        switch url.kind {
        case .docx:
            let token = DocToken(url.token)
            let hits = await scanner.lookupAll(token)
            switch hits.count {
            case 0: return .createNew(token: token)
            case 1: return .openExisting(hits[0])
            default: return .ambiguous(hits)
            }
        case .wiki, .short:
            // No local lookup possible without first turning a node_token
            // / short token into a docx token. Caller decides whether to
            // hit the API (v2-5) or surface a "open in browser" fallback.
            return .requiresAPIResolution(url)
        }
    }
}
