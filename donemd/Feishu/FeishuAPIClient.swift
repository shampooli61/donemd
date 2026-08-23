import Foundation
import CryptoKit

/// High-level docx OpenAPI surface Done.md needs for the bidirectional
/// sync flow (issue #47). Four operations:
///
///   - `pullDocument`  — read every block in a docx, paginated
///   - `pushDocument`  — overwrite a docx's body with `[FeishuBlock]`
///   - `createDocument`— mint a new docx (under a parent folder/wiki)
///   - `uploadImage`   — upload a local image, return Feishu's
///                       `image_token`; deduped by SHA-256
///
/// `pushDocument` takes `[FeishuBlock]` rather than markdown because
/// Feishu has no markdown-overwrite endpoint — the only realistic write
/// path is the docx blocks API (delete-then-create the page's children).
/// The coordinator (v2 Slice 9) owns the markdown → `[FeishuBlock]`
/// conversion via `FeishuStructuralConverter`; the API client orchestrates
/// the multi-call delete-then-create dance internally.
///
/// `createDocument(parentToken:)` accepts either a folder token (drive)
/// or a wiki node token; the v1 endpoint disambiguates internally based
/// on the prefix.
public protocol FeishuAPIClient {
    /// Read every block in a docx + the document's current revision.
    ///
    /// `revisionId` is the monotonically-increasing version counter Feishu
    /// stamps on every successful write. The pull coordinator stores it as
    /// `feishu.last_pulled_revision` so v2-9b can later detect "Feishu side
    /// moved ahead of us" before a push. The number lives on
    /// `GET /open-apis/docx/v1/documents/{id}` (the blocks listing
    /// endpoint doesn't carry it).
    func pullDocument(documentId: String) async throws -> (blocks: [FeishuBlock], revisionId: Int)
    /// Replace the body of an existing docx with `blocks` (typically produced
    /// by `FeishuStructuralConverter.toFeishuBlocks(markdown)`).
    ///
    /// Implementation is "delete-then-create" against the docx blocks API:
    /// list the root page's existing children, range-delete them, then POST
    /// the new tree as a single descendants payload. v2-9a-step1' switched
    /// from `raw_content` (which is GET-only — read plaintext) to this
    /// blocks-orchestration design after the original assumption was proved
    /// wrong on real-line iteration (see commits leading up to this change).
    func pushDocument(documentId: String, blocks: [FeishuBlock]) async throws
    /// Range-delete children `[startIndex, endIndex)` under `parentBlockId`.
    /// Used by `FeishuPushCoordinator`'s segmented push (#57) to clear a
    /// single non-placeholder segment without nuking the placeholders
    /// flanking it. `pushDocument`'s monolithic delete-then-create wraps
    /// this internally for the no-placeholder case; segmented push calls
    /// it once per segment, back-to-front so earlier segments' indices
    /// don't shift.
    func deleteChildrenRange(
        documentId: String,
        parentBlockId: String,
        startIndex: Int,
        endIndex: Int
    ) async throws
    /// Insert `blocks` (with a synthetic page root from
    /// `FeishuStructuralConverter.toFeishuBlocks`) at `index` under
    /// `parentBlockId`. The page block isn't sent — only its descendants.
    /// `index = -1` means append. Used by segmented push to drop a
    /// freshly-encoded segment back into the right slot after the
    /// matching `deleteChildrenRange` cleared it.
    func insertChildrenAt(
        documentId: String,
        parentBlockId: String,
        index: Int,
        blocks: [FeishuBlock]
    ) async throws
    func createDocument(title: String, parentToken: String?) async throws -> String
    /// Replace the docx's title — i.e. the text of the page block. The page
    /// block's `block_id` equals `document_id` by Feishu convention, so the
    /// PATCH targets `/documents/{id}/blocks/{id}`. Used by `FeishuPushCoordinator`
    /// when the local first-line H1 changed but the doc is already bound
    /// (no `createDocument` to set the title at).
    func updateDocumentTitle(documentId: String, title: String) async throws
    /// Upload an image to Feishu's drive and return the resulting
    /// `image_token`. `documentId` is the docx that the image will be
    /// embedded into — Feishu's drive requires both `parent_node`
    /// (= documentId) and `extra.drive_route_token` (= documentId)
    /// for `docx_image` uploads, otherwise it 403s with 1061004
    /// "forbidden" even when the OAuth scope is correct. Real-device
    /// verification confirmed this on 2026-05-30.
    func uploadImage(
        data: Data,
        mimeType: String,
        fileName: String,
        documentId: String
    ) async throws -> String
    /// Download a Feishu drive media (image / file) by token. Pull side
    /// uses this to materialize bytes for `image` blocks the doc body
    /// references via `feishu://image/<token>` — without it, the
    /// WebView shows a broken image placeholder. Returns the raw bytes
    /// + the MIME type Feishu reports (used to pick the file extension
    /// when AssetsManager writes the blob to `assets/`).
    func downloadImage(token: String) async throws -> (data: Data, mimeType: String)

    /// Resolve a wiki node token (the thing that lives in a
    /// `https://*.feishu.cn/wiki/<token>` URL) to its underlying object —
    /// the wiki page is a wrapper that points at a docx / sheet / mindnote
    /// /etc. behind the scenes. We need the docx `obj_token` to drive any
    /// of the rest of the pull/push pipeline, since `pullDocument` only
    /// understands docx tokens.
    ///
    /// Endpoint: GET /open-apis/wiki/v2/spaces/get_node?token=<wiki_token>
    /// Required scope: `wiki:wiki`
    /// (already in `FeishuOAuthClient.defaultScopes`)
    ///
    /// Returns nil only when Feishu reports the node exists but has no
    /// `obj_token` (shouldn't happen in practice — wiki nodes always
    /// wrap something — but the API contract is permissive). Throws
    /// `.notFound` when the wiki node itself doesn't exist.
    func resolveWikiNode(token: String) async throws -> WikiNodeResolution

    /// Read just the docx's current `revision_id` — single GET, no
    /// pagination, no body. Used by the v2-9b push preflight to
    /// detect "Feishu side changed since our last pull": if local
    /// `frontmatter.feishu.lastPulledRevision != remote revision`,
    /// somebody (or a different Done.md instance) edited Feishu side
    /// between our pull and this push, and the user needs to decide
    /// pull-first vs overwrite.
    ///
    /// Endpoint: GET /open-apis/docx/v1/documents/{id}
    /// Required scope: `docx:document` (already in defaultScopes —
    /// same scope used for pullDocument's blocks listing).
    ///
    /// Returns the revision as Int. Some tenants serialize it as a
    /// String on the wire; the implementation tolerates both.
    func getDocumentRevision(documentId: String) async throws -> Int
}

/// What Feishu returns for `wiki/v2/spaces/get_node`. We carry only the
/// fields the import command actually uses; the full payload includes
/// space_id, parent_node_token, has_child, etc. — surface those via
/// new fields here when a use case justifies it.
public struct WikiNodeResolution: Equatable {
    /// The token of the wrapped object. For wiki pages backed by a
    /// docx (the common case), this is the `doxc_…` token usable by
    /// `pullDocument`.
    public let objToken: String
    /// `docx`, `sheet`, `bitable`, `mindnote`, `slides`, `file`, … —
    /// the raw string from Feishu's enum. Done.md only knows how to
    /// pull `docx`; other types should surface a "暂不支持" dialog.
    public let objType: String
    /// Page title from the wiki node (not always equal to the title
    /// inside the docx — wiki tree shows a separate display name).
    /// Optional because Feishu may legitimately return empty.
    public let title: String?

    public init(objToken: String, objType: String, title: String?) {
        self.objToken = objToken
        self.objType = objType
        self.title = title
    }
}

/// Domain errors the coordinators decode and surface — every Feishu HTTP
/// failure mode lands in one of these cases. Keeping the enum tight (no
/// `genericFailure(...)`) forces every new error path to think about
/// retry policy and user-facing copy.
public enum FeishuAPIError: Error, Equatable {
    /// 401 / Feishu code 99991663 (token invalid). Coordinator should
    /// route to login. The client already tries one silent refresh
    /// before surfacing this.
    case unauthorized
    /// 403 / Feishu code 99991664 (scope insufficient). User must
    /// re-authorize with broader scope, or admin must grant it.
    case forbidden(message: String?)
    /// Feishu code 99991679 — the access_token is valid but the app
    /// doesn't have the OAuth scope this endpoint requires. Comes
    /// back as HTTP 400 (not 403, which is what 99991664 surfaces),
    /// so it would otherwise fall into `.badRequest` and read like
    /// a malformed body. Distinguishing it lets the UI route the
    /// user to the Feishu open-platform console to grant the scope
    /// — the only path that actually unblocks them. Carries the
    /// human-readable detail line Feishu returns (often listing the
    /// required scopes) so the dialog can show specifics.
    case scopeInsufficient(detail: String?)
    /// 404 — the document/folder/wiki doesn't exist or the user has
    /// no permission to see it. Carries the resource id for logging.
    case notFound(resource: String)
    /// 429 — rate limited even after the client's automatic retries.
    case rateLimited
    /// 4xx other than 401/403/404 — typically 400 with a Feishu code
    /// describing which param the request body got wrong. Surfaces the
    /// raw status, code, and message verbatim so the user (or a bug
    /// report) has something to act on.
    case badRequest(httpStatus: Int, code: Int?, message: String?)
    /// 5xx — server-side error after retries.
    case serverError(httpStatus: Int, code: Int?, message: String?)
    /// `URLSession.data(for:)` threw — DNS / TLS / no-network. Carries
    /// `localizedDescription` so the UI can show something specific.
    case networkUnreachable(String)
    /// JSON we got back didn't match the shape we expected. Caller
    /// should report the bug; user can't recover.
    case decodeFailed(String)
}

/// In-memory hash → `image_token` cache so the same image isn't reuploaded
/// on a re-push. Persistent variants (Application Support file) can plug
/// in via the protocol; the v2 Slice 5 default is intentionally
/// in-memory because the typical Done.md image set is small (<100) and
/// process-lifetime cache hits are already a big win over no cache.
public protocol FeishuImageCache: AnyObject {
    func token(forSHA256 hash: String) -> String?
    func remember(_ token: String, forSHA256 hash: String)
}

public final class InMemoryFeishuImageCache: FeishuImageCache {
    private var map: [String: String] = [:]
    private let lock = NSLock()
    public init() {}
    public func token(forSHA256 hash: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return map[hash]
    }
    public func remember(_ token: String, forSHA256 hash: String) {
        lock.lock(); defer { lock.unlock() }
        map[hash] = token
    }
}

/// Backoff schedule for 429 / 5xx retries. Exposed as a struct so tests
/// can plug in a zero-delay schedule without rebuilding the client.
public struct FeishuBackoffPolicy: Equatable {
    public var initialDelay: TimeInterval
    public var multiplier: Double
    public var maxDelay: TimeInterval
    public var maxAttempts: Int
    public var jitter: TimeInterval

    public static let production = FeishuBackoffPolicy(
        initialDelay: 1.0, multiplier: 2.0,
        maxDelay: 8.0, maxAttempts: 4, jitter: 0.5
    )

    public static let immediate = FeishuBackoffPolicy(
        initialDelay: 0, multiplier: 1, maxDelay: 0,
        maxAttempts: 4, jitter: 0
    )

    public init(initialDelay: TimeInterval, multiplier: Double,
                maxDelay: TimeInterval, maxAttempts: Int, jitter: TimeInterval) {
        self.initialDelay = initialDelay
        self.multiplier = multiplier
        self.maxDelay = maxDelay
        self.maxAttempts = maxAttempts
        self.jitter = jitter
    }

    func delay(forAttempt attempt: Int) -> TimeInterval {
        // attempt is 0-indexed, attempt 0 = first retry after the initial
        // failure. Multiplier compounds; cap at maxDelay; add small
        // uniform jitter to avoid thundering-herd from coordinated retries.
        let raw = min(maxDelay, initialDelay * pow(multiplier, Double(attempt)))
        let noise = jitter > 0 ? Double.random(in: 0...jitter) : 0
        return raw + noise
    }
}

/// Concrete `URLSession`-backed client. Every external dependency is
/// injectable so unit tests can simulate 401/429/5xx, network outages,
/// and idempotent-image-upload short-circuits without real I/O.
public final class FeishuHTTPAPIClient: FeishuAPIClient {

    /// Token endpoint host — every docx + drive call lives under here.
    /// (Authorize URL is on `accounts.feishu.cn` but that's only used by
    /// the OAuth client.)
    public static let defaultBaseURL = URL(string: "https://open.feishu.cn")!

    private let baseURL: URL
    private let session: URLSession
    private let tokenProvider: () async throws -> String
    private let onUnauthorized: () async throws -> String
    private let imageCache: FeishuImageCache
    private let backoff: FeishuBackoffPolicy
    private let sleeper: (TimeInterval) async throws -> Void

    /// - Parameters:
    ///   - tokenProvider: invoked once per request to fetch the current
    ///     access token. The default impl wraps
    ///     `FeishuOAuthClient.refreshIfNeeded().accessToken`.
    ///   - onUnauthorized: invoked after a 401 to force a token refresh
    ///     and return a fresh token; the request is retried once. The
    ///     default impl is the same as `tokenProvider` — the OAuth
    ///     client already short-circuits when the token is fresh, so a
    ///     401 followed by `refreshIfNeeded` does the right thing.
    ///   - sleeper: backoff sleep, injected so tests run instantly.
    public init(
        baseURL: URL = FeishuHTTPAPIClient.defaultBaseURL,
        session: URLSession = .shared,
        tokenProvider: @escaping () async throws -> String,
        onUnauthorized: (() async throws -> String)? = nil,
        imageCache: FeishuImageCache = InMemoryFeishuImageCache(),
        backoff: FeishuBackoffPolicy = .production,
        sleeper: @escaping (TimeInterval) async throws -> Void = { try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) }
    ) {
        self.baseURL = baseURL
        self.session = session
        self.tokenProvider = tokenProvider
        self.onUnauthorized = onUnauthorized ?? tokenProvider
        self.imageCache = imageCache
        self.backoff = backoff
        self.sleeper = sleeper
    }

    // MARK: - public API

    public func pullDocument(documentId: String) async throws -> (blocks: [FeishuBlock], revisionId: Int) {
        // Block listing is paginated — 500 is Feishu's stated max page size.
        // We loop until `has_more` is false. Decoding routes through
        // `FeishuBlockEncoder.decodeBlockEnvelope` rather than a `Decodable`
        // shape because each block's payload is dynamic on `block_type`.
        var collected: [FeishuBlock] = []
        var pageToken: String? = nil
        repeat {
            var query: [URLQueryItem] = [URLQueryItem(name: "page_size", value: "500")]
            if let token = pageToken {
                query.append(URLQueryItem(name: "page_token", value: token))
            }
            let path = "/open-apis/docx/v1/documents/\(documentId)/blocks"
            let raw = try await sendWithRetryData(
                method: "GET", path: path, query: query,
                contentType: nil, body: nil, resource: documentId
            )
            let json: [String: Any]
            do {
                let parsed = try JSONSerialization.jsonObject(with: raw)
                guard let dict = parsed as? [String: Any] else {
                    throw FeishuAPIError.decodeFailed(
                        "blocks response root is not a JSON object"
                    )
                }
                json = dict
            } catch let apiError as FeishuAPIError {
                throw apiError
            } catch {
                throw FeishuAPIError.decodeFailed("\(error)")
            }
            let data = json["data"] as? [String: Any] ?? [:]
            let items = data["items"] as? [[String: Any]] ?? []
            for item in items {
                do {
                    let block = try FeishuBlockEncoder.decodeBlockEnvelope(item)
                    collected.append(block)
                } catch {
                    throw FeishuAPIError.decodeFailed("\(error)")
                }
            }
            pageToken = (data["has_more"] as? Bool == true) ? data["page_token"] as? String : nil
        } while pageToken != nil

        let revisionId = try await fetchDocumentRevision(documentId: documentId)
        return (collected, revisionId)
    }

    /// Single-shot `GET /open-apis/docx/v1/documents/{id}` — only used by
    /// `pullDocument` to pick up the doc's current `revision_id`. The blocks
    /// listing endpoint doesn't carry it. Runs after pagination so existing
    /// failure-mode tests (401/403/404/429/5xx mid-blocks) don't shift their
    /// recorded-request counts.
    public func getDocumentRevision(documentId: String) async throws -> Int {
        // Public protocol surface — delegates to the same private
        // helper pullDocument has been using since v2-8 to fetch the
        // doc-meta endpoint. Keeping the name `fetchDocumentRevision`
        // private so we don't accidentally call this from inside
        // pullDocument and double-fetch.
        try await fetchDocumentRevision(documentId: documentId)
    }

    private func fetchDocumentRevision(documentId: String) async throws -> Int {
        let path = "/open-apis/docx/v1/documents/\(documentId)"
        let raw = try await sendWithRetryData(
            method: "GET", path: path, query: [],
            contentType: nil, body: nil, resource: documentId
        )
        let json: [String: Any]
        do {
            let parsed = try JSONSerialization.jsonObject(with: raw)
            guard let dict = parsed as? [String: Any] else {
                throw FeishuAPIError.decodeFailed(
                    "document meta response root is not a JSON object"
                )
            }
            json = dict
        } catch let apiError as FeishuAPIError {
            throw apiError
        } catch {
            throw FeishuAPIError.decodeFailed("\(error)")
        }
        let data = json["data"] as? [String: Any] ?? [:]
        let document = data["document"] as? [String: Any] ?? [:]
        // Feishu wire shape: `data.document.revision_id` as an Int. Some
        // tenants have been spotted serializing it as a String; tolerate
        // both rather than break the round-trip on a single-call mismatch.
        if let asInt = document["revision_id"] as? Int {
            return asInt
        }
        if let asString = document["revision_id"] as? String, let parsed = Int(asString) {
            return parsed
        }
        throw FeishuAPIError.decodeFailed(
            "document meta response missing revision_id (\(documentId))"
        )
    }

    public func pushDocument(documentId: String, blocks: [FeishuBlock]) async throws {
        // Blocks-orchestration "delete-then-create": list the existing root
        // children, range-delete them, then POST the new tree as a single
        // descendants payload. v2-9a-step1' replaced the original
        // `raw_content` design (which was GET-only) after real-line iteration.
        // `pushDocument` only needs the existing block tree to find the
        // page block + its root children; the revision the pull side cares
        // about is irrelevant here, so we drop it.
        let existing = try await pullDocument(documentId: documentId).blocks
        guard let page = existing.first(where: {
            if case .page = $0.payload { return true } else { return false }
        }) else {
            throw FeishuAPIError.decodeFailed("pulled document has no page block")
        }
        let pageBlockId = page.blockId
        let rootChildIds = page.children ?? []

        if !rootChildIds.isEmpty {
            try await deleteChildren(
                documentId: documentId,
                parentBlockId: pageBlockId,
                startIndex: 0,
                endIndex: rootChildIds.count
            )
        }

        let body: [String: Any]
        do {
            body = try FeishuBlockEncoder.encodeDescendantBody(from: blocks, index: -1)
        } catch {
            throw FeishuAPIError.decodeFailed("\(error)")
        }
        try await createDescendants(
            documentId: documentId,
            parentBlockId: pageBlockId,
            body: body
        )
    }

    public func createDocument(title: String, parentToken: String?) async throws -> String {
        // POST /open-apis/docx/v1/documents { "title": ..., "folder_token": ... }
        var body: [String: Any] = ["title": title]
        if let parent = parentToken {
            body["folder_token"] = parent
        }
        let envelope: CreateDocumentEnvelope = try await postJSON(
            path: "/open-apis/docx/v1/documents", body: body, resource: title
        )
        guard let id = envelope.data.document?.document_id else {
            throw FeishuAPIError.decodeFailed("create response missing document_id")
        }
        return id
    }

    public func updateDocumentTitle(documentId: String, title: String) async throws {
        // The page block's block_id equals the document_id, so the PATCH
        // path collapses to /documents/{id}/blocks/{id}. Route #57 step4
        // real-device verification (2026-05-30): the Feishu validator on
        // the *page block* PATCH rejects `text_element_style` entirely
        // with code 1770001 — even when every required boolean is set
        // false, even when `link` is absent. Other block types (text /
        // heading / etc.) require the full style block (error 99992402
        // if any of bold/italic/inline_code/strikethrough/underline is
        // missing) on the same `update_text_elements` path. Different
        // validator on the page case.
        //
        // Cross-checked against feishu-mcp-pro's renameDoc, which omits
        // `text_element_style` from the textRun and works in the same
        // tenant — so we hand-build the minimal body here instead of
        // routing through `FeishuBlockEncoder.encodeElements`.
        let path = "/open-apis/docx/v1/documents/\(documentId)/blocks/\(documentId)"
        let body: [String: Any] = [
            "update_text_elements": [
                "elements": [
                    ["text_run": ["content": title]],
                ],
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: body, options: [])
        debugLog("[push] updateDocumentTitle PATCH \(path) body=\(String(data: data, encoding: .utf8) ?? "<bin>")")
        do {
            let _: EmptyEnvelope = try await sendWithRetry(
                method: "PATCH", path: path, query: [],
                contentType: "application/json; charset=utf-8",
                body: data, resource: documentId
            )
        } catch {
            debugLog("[push] updateDocumentTitle FAILED: \(error)")
            throw error
        }
    }

    public func uploadImage(
        data: Data,
        mimeType: String,
        fileName: String,
        documentId: String
    ) async throws -> String {
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        if let cached = imageCache.token(forSHA256: hash) {
            return cached
        }

        // multipart/form-data — the drive media endpoint takes a file
        // payload + a JSON-ish field set. We handcraft the body because
        // URLSession has no native multipart helper.
        let boundary = "Boundary-\(UUID().uuidString)"
        var body = Data()
        func appendField(_ name: String, value: String) {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(value)\r\n".data(using: .utf8)!)
        }
        appendField("file_name", value: fileName)
        appendField("parent_type", value: "docx_image")
        // `parent_node` and `extra.drive_route_token` together tell
        // Feishu's drive which docx the image is being embedded into.
        // Both required for parent_type=docx_image; without them the
        // server returns HTTP 403 / 1061004 "forbidden" even with the
        // correct OAuth scope. Verified on 2026-05-30 against the
        // feishu-mcp-pro reference implementation.
        appendField("parent_node", value: documentId)
        let extraJSON = "{\"drive_route_token\":\"\(documentId)\"}"
        appendField("extra", value: extraJSON)
        appendField("size", value: String(data.count))
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(fileName)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: \(mimeType)\r\n\r\n".data(using: .utf8)!)
        body.append(data)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        let envelope: UploadImageEnvelope = try await sendWithRetry(
            method: "POST",
            path: "/open-apis/drive/v1/medias/upload_all",
            query: [],
            contentType: "multipart/form-data; boundary=\(boundary)",
            body: body,
            resource: fileName
        )
        guard let token = envelope.data.file_token else {
            throw FeishuAPIError.decodeFailed("upload response missing file_token")
        }
        imageCache.remember(token, forSHA256: hash)
        return token
    }

    /// Download raw image bytes for a Feishu image_token. Returns the
    /// body + the `Content-Type` header so the caller can pick a file
    /// extension when writing to disk. The endpoint is documented at
    /// /drive/v1/medias/{token}/download — same drive-media surface as
    /// `uploadImage`, opposite direction.
    ///
    /// Doesn't go through `sendWithRetryData` because that helper hides
    /// response headers (we need Content-Type), and the binary body
    /// would confuse its envelope-decode probe on edge-case 4xx
    /// responses. Instead we re-implement the minimal retry / refresh
    /// pipeline inline — matches the upload's bespoke implementation
    /// (multipart writes also bypass the JSON helpers).
    public func downloadImage(token: String) async throws -> (data: Data, mimeType: String) {
        let path = "/open-apis/drive/v1/medias/\(token)/download"
        var didRefreshAfter401 = false
        var retryAttempt = 0

        while true {
            let bearer: String
            do {
                bearer = try await tokenProvider()
            } catch let urlError as URLError {
                throw FeishuAPIError.networkUnreachable(urlError.localizedDescription)
            } catch {
                throw FeishuAPIError.unauthorized
            }

            let request = try buildRequest(
                method: "GET", path: path, query: [],
                contentType: nil, body: nil, token: bearer
            )

            let pair: (Data, URLResponse)
            do {
                pair = try await session.data(for: request)
            } catch let urlError as URLError {
                throw FeishuAPIError.networkUnreachable(urlError.localizedDescription)
            } catch {
                throw FeishuAPIError.networkUnreachable("\(error)")
            }
            let (data, response) = pair
            let httpResponse = response as? HTTPURLResponse
            let httpStatus = httpResponse?.statusCode ?? -1

            if httpStatus == 401 {
                if didRefreshAfter401 {
                    throw FeishuAPIError.unauthorized
                }
                didRefreshAfter401 = true
                do {
                    _ = try await onUnauthorized()
                } catch {
                    throw FeishuAPIError.unauthorized
                }
                continue
            }

            if httpStatus == 403 {
                throw FeishuAPIError.forbidden(message: nil)
            }
            if httpStatus == 404 {
                throw FeishuAPIError.notFound(resource: token)
            }

            if httpStatus == 429 || (500...599).contains(httpStatus) {
                if retryAttempt >= backoff.maxAttempts {
                    if httpStatus == 429 { throw FeishuAPIError.rateLimited }
                    throw FeishuAPIError.serverError(
                        httpStatus: httpStatus, code: nil, message: nil
                    )
                }
                try? await sleeper(backoff.delay(forAttempt: retryAttempt))
                retryAttempt += 1
                continue
            }

            guard (200..<300).contains(httpStatus) else {
                if (400..<500).contains(httpStatus) {
                    let raw = String(data: data, encoding: .utf8) ?? "<binary>"
                    debugLog("[pull] image download \(httpStatus) on \(path) → \(raw)")
                    // Try to extract Feishu's `{code, msg}` envelope from
                    // the body so 99991679 (scope insufficient) lands in
                    // the dedicated bucket, not in the catch-all
                    // badRequest where it reads as a body shape error.
                    let envelope = decodeEnvelopeMetadata(data)
                    if envelope.code == 99991679 {
                        let detail = envelope.msg.flatMap { msg in
                            msg.count > 600 ? String(msg.prefix(600)) + "…" : msg
                        }
                        throw FeishuAPIError.scopeInsufficient(detail: detail)
                    }
                    throw FeishuAPIError.badRequest(
                        httpStatus: httpStatus, code: envelope.code, message: envelope.msg
                    )
                }
                throw FeishuAPIError.serverError(
                    httpStatus: httpStatus, code: nil, message: nil
                )
            }

            // Pull Content-Type out of headers (case-insensitive). Default
            // to image/png when missing — every drive media response
            // we've seen carries the header, but a defensive default
            // matches the upload-side filename heuristic in
            // AssetURLSchemeHandler.
            let mime = (httpResponse?.value(forHTTPHeaderField: "Content-Type"))
                ?? "image/png"
            return (data, mime)
        }
    }

    public func resolveWikiNode(token: String) async throws -> WikiNodeResolution {
        // Wiki get_node lives under the docs orchestration API and uses
        // `wiki:wiki` scope. Single GET, no pagination — wiki nodes
        // are atomic.
        let path = "/open-apis/wiki/v2/spaces/get_node"
        let raw = try await sendWithRetryData(
            method: "GET", path: path,
            query: [URLQueryItem(name: "token", value: token)],
            contentType: nil, body: nil, resource: token
        )
        let json: [String: Any]
        do {
            let parsed = try JSONSerialization.jsonObject(with: raw)
            guard let dict = parsed as? [String: Any] else {
                throw FeishuAPIError.decodeFailed(
                    "wiki get_node response root is not a JSON object"
                )
            }
            json = dict
        } catch let apiError as FeishuAPIError {
            throw apiError
        } catch {
            throw FeishuAPIError.decodeFailed("\(error)")
        }
        let data = json["data"] as? [String: Any] ?? [:]
        let node = data["node"] as? [String: Any] ?? [:]
        guard let objToken = node["obj_token"] as? String, !objToken.isEmpty,
              let objType = node["obj_type"] as? String, !objType.isEmpty else {
            throw FeishuAPIError.decodeFailed(
                "wiki get_node response missing obj_token / obj_type (\(token))"
            )
        }
        let title = node["title"] as? String
        return WikiNodeResolution(objToken: objToken, objType: objType, title: title)
    }

    // MARK: - internal HTTP helpers

    private func getJSON<T: Decodable>(
        path: String, query: [URLQueryItem], resource: String
    ) async throws -> T {
        try await sendWithRetry(
            method: "GET", path: path, query: query,
            contentType: nil, body: nil, resource: resource
        )
    }

    private func postJSON<T: Decodable>(
        path: String, body: [String: Any], resource: String
    ) async throws -> T {
        let data = try JSONSerialization.data(withJSONObject: body, options: [])
        return try await sendWithRetry(
            method: "POST", path: path, query: [],
            contentType: "application/json; charset=utf-8",
            body: data, resource: resource
        )
    }

    /// Public segmented-push entry: range-delete children. Coordinator
    /// owns the back-to-front sequencing — see ADR-0007 § 推送时如何还
    /// 原飞书侧原块.
    public func deleteChildrenRange(
        documentId: String,
        parentBlockId: String,
        startIndex: Int,
        endIndex: Int
    ) async throws {
        try await deleteChildren(
            documentId: documentId,
            parentBlockId: parentBlockId,
            startIndex: startIndex,
            endIndex: endIndex
        )
    }

    /// Public segmented-push entry: insert encoded blocks at `index`.
    /// Empty `blocks` is a no-op — happens when two placeholders are
    /// adjacent on Feishu side and the local body inserts no
    /// non-placeholder content between them.
    public func insertChildrenAt(
        documentId: String,
        parentBlockId: String,
        index: Int,
        blocks: [FeishuBlock]
    ) async throws {
        // The page block is the synthetic root the converter prepends
        // to the segment; check against `[1+ blocks]` rather than
        // `>0` because a page-only segment means "no descendants".
        let nonPageCount = blocks.filter {
            if case .page = $0.payload { return false } else { return true }
        }.count
        if nonPageCount == 0 { return }
        let body: [String: Any]
        do {
            body = try FeishuBlockEncoder.encodeDescendantBody(from: blocks, index: index)
        } catch {
            throw FeishuAPIError.decodeFailed("\(error)")
        }
        try await createDescendants(
            documentId: documentId,
            parentBlockId: parentBlockId,
            body: body
        )
    }

    /// `DELETE /open-apis/docx/v1/documents/{documentId}/blocks/{parentBlockId}/children/batch_delete`
    /// with a `{ start_index, end_index }` body. Used by `pushDocument`
    /// to clear the root page's existing children before re-creating
    /// the body from blocks.
    private func deleteChildren(
        documentId: String,
        parentBlockId: String,
        startIndex: Int,
        endIndex: Int
    ) async throws {
        let path = "/open-apis/docx/v1/documents/\(documentId)"
            + "/blocks/\(parentBlockId)/children/batch_delete"
        let body: [String: Any] = [
            "start_index": startIndex,
            "end_index": endIndex,
        ]
        let data = try JSONSerialization.data(withJSONObject: body, options: [])
        debugLog("[push] DELETE \(path) [\(startIndex), \(endIndex))")
        let _: EmptyEnvelope = try await sendWithRetry(
            method: "DELETE", path: path, query: [],
            contentType: "application/json; charset=utf-8",
            body: data, resource: documentId
        )
    }

    /// `POST /open-apis/docx/v1/documents/{documentId}/blocks/{parentBlockId}/descendant`
    /// with the `{ index, children_id, descendants }` body produced by
    /// `FeishuBlockEncoder.encodeDescendantBody`. Used by `pushDocument`
    /// to materialize the new block tree under the page block in one shot.
    private func createDescendants(
        documentId: String,
        parentBlockId: String,
        body: [String: Any]
    ) async throws {
        let path = "/open-apis/docx/v1/documents/\(documentId)"
            + "/blocks/\(parentBlockId)/descendant"
        let data = try JSONSerialization.data(withJSONObject: body, options: [])
        // Bodies hit the strict Feishu validator that returns 1770001
        // "invalid param" without telling you which field. We log the
        // exact JSON we sent so a user reporting the failure can hand
        // over /tmp/donemd-debug.log and we can spot the bad envelope.
        // Truncate to keep huge bodies (50+ blocks) from blowing the
        // log; the front of the payload is what the validator inspects
        // first anyway.
        if let raw = String(data: data, encoding: .utf8) {
            let truncated = raw.count > 4000 ? String(raw.prefix(4000)) + "…(truncated)" : raw
            debugLog("[push] POST \(path) body=\(truncated)")
        }
        let _: EmptyEnvelope = try await sendWithRetry(
            method: "POST", path: path, query: [],
            contentType: "application/json; charset=utf-8",
            body: data, resource: documentId
        )
    }

    /// Runs a request with the full Feishu reliability protocol:
    ///   - attaches `Authorization: Bearer <token>`
    ///   - on 401, refreshes the token and retries ONCE
    ///   - on 429 or 5xx, sleeps `backoff.delay(forAttempt:)` and retries
    ///     up to `backoff.maxAttempts` times
    ///   - on `URLError`, surfaces `.networkUnreachable`
    ///
    /// Generic wrapper — decodes `T` after the raw data path returns. Use
    /// `sendWithRetryData` directly when the response shape isn't a
    /// straightforward `Decodable` (e.g. the blocks listing, where the
    /// item payload is dynamic).
    private func sendWithRetry<T: Decodable>(
        method: String,
        path: String,
        query: [URLQueryItem],
        contentType: String?,
        body: Data?,
        resource: String
    ) async throws -> T {
        let data = try await sendWithRetryData(
            method: method, path: path, query: query,
            contentType: contentType, body: body, resource: resource
        )
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw FeishuAPIError.decodeFailed("\(error)")
        }
    }

    /// Same retry/refresh pipeline as `sendWithRetry<T>` but returns the
    /// raw response body so callers can route through `JSONSerialization`
    /// (used by the blocks-listing path, whose payload is type-tagged at
    /// runtime by `block_type` rather than by Swift's static `Decodable`).
    private func sendWithRetryData(
        method: String,
        path: String,
        query: [URLQueryItem],
        contentType: String?,
        body: Data?,
        resource: String
    ) async throws -> Data {
        var didRefreshAfter401 = false
        var retryAttempt = 0

        while true {
            let token: String
            do {
                token = try await tokenProvider()
            } catch let urlError as URLError {
                // Token endpoint is itself an HTTP call (OAuth token /
                // refresh exchange). Network failure there is the same
                // user-facing problem as a regular API call going dark —
                // route through one bucket so the dialog copy is honest.
                throw FeishuAPIError.networkUnreachable(urlError.localizedDescription)
            } catch {
                // OAuth login cancelled / Keychain inaccessible / decode
                // failure on the token exchange / OAuthError.notAuthenticated
                // bubbling up. None of these are network problems —
                // surfacing them as networkUnreachable misleads the user
                // ("token provider failed: notAuthenticated" was the bug
                // report). `unauthorized` routes the dialog copy to "请重新
                // 登录" via the existing PushCommand/PullCommand error map.
                throw FeishuAPIError.unauthorized
            }

            let request = try buildRequest(
                method: method, path: path, query: query,
                contentType: contentType, body: body, token: token
            )

            let pair: (Data, URLResponse)
            do {
                pair = try await session.data(for: request)
            } catch let urlError as URLError {
                throw FeishuAPIError.networkUnreachable(urlError.localizedDescription)
            } catch {
                throw FeishuAPIError.networkUnreachable("\(error)")
            }
            let (data, response) = pair
            let httpStatus = (response as? HTTPURLResponse)?.statusCode ?? -1
            let envelope = decodeEnvelopeMetadata(data)

            // Surface non-2xx responses verbatim so real-line debugging
            // sees Feishu's actual error string (e.g. "param X invalid")
            // before our enum mapping flattens it.
            if !(200..<300).contains(httpStatus) || (envelope.code ?? 0) != 0 {
                let rawBody = String(data: data, encoding: .utf8) ?? "<binary \(data.count)B>"
                debugLog("[push] http \(httpStatus) on \(path) → \(rawBody)")
            }

            // 401 / 401-equivalent Feishu code → one-shot refresh-and-retry.
            if httpStatus == 401 || envelope.code == 99991663 {
                if didRefreshAfter401 {
                    throw FeishuAPIError.unauthorized
                }
                didRefreshAfter401 = true
                do {
                    _ = try await onUnauthorized()
                } catch {
                    throw FeishuAPIError.unauthorized
                }
                continue
            }

            if envelope.code == 99991679 {
                // App OAuth scope insufficient. Distinct from 99991664
                // (forbidden — the user lacks permission on the resource);
                // here the *app* lacks the OAuth scope to call the
                // endpoint at all. Surfaces as 400 not 403, easy to
                // mis-bucket as a body shape error if we don't catch it
                // before the badRequest fallback. Truncate the verbose
                // Feishu message at 600 chars — it's a wall of scope
                // names the dialog summarizes more readably.
                let detail = envelope.msg.flatMap { msg in
                    msg.count > 600 ? String(msg.prefix(600)) + "…" : msg
                }
                throw FeishuAPIError.scopeInsufficient(detail: detail)
            }
            if httpStatus == 403 || envelope.code == 99991664 {
                throw FeishuAPIError.forbidden(message: envelope.msg)
            }
            if httpStatus == 404 {
                throw FeishuAPIError.notFound(resource: resource)
            }

            // 429 + 5xx → backoff loop. Bail when we've exhausted retries.
            if httpStatus == 429 || (500...599).contains(httpStatus) {
                if retryAttempt >= backoff.maxAttempts {
                    if httpStatus == 429 {
                        throw FeishuAPIError.rateLimited
                    }
                    throw FeishuAPIError.serverError(
                        httpStatus: httpStatus, code: envelope.code, message: envelope.msg
                    )
                }
                let delay = backoff.delay(forAttempt: retryAttempt)
                // Always invoke the sleeper, even with a 0 delay, so tests
                // can count retry events and so the production sleeper can
                // observe yields. `Task.sleep(nanoseconds: 0)` is a no-op.
                try? await sleeper(delay)
                retryAttempt += 1
                continue
            }

            guard (200..<300).contains(httpStatus), envelope.code == 0 || envelope.code == nil else {
                // Split 4xx (client-side: bad request body / bad param)
                // from 5xx (server-side). The default-clause used to fold
                // both into .serverError, which lied to users about whose
                // fault it was and made invalid-param errors look like
                // transient outages worth retrying.
                if (400..<500).contains(httpStatus) {
                    throw FeishuAPIError.badRequest(
                        httpStatus: httpStatus, code: envelope.code, message: envelope.msg
                    )
                }
                throw FeishuAPIError.serverError(
                    httpStatus: httpStatus, code: envelope.code, message: envelope.msg
                )
            }

            return data
        }
    }

    private func buildRequest(
        method: String, path: String, query: [URLQueryItem],
        contentType: String?, body: Data?, token: String
    ) throws -> URLRequest {
        var components = URLComponents(
            url: baseURL.appendingPathComponent(path),
            resolvingAgainstBaseURL: false
        )!
        // appendingPathComponent percent-encodes our literal `/` separators —
        // rebuild from baseURL + path string instead.
        components = URLComponents(string: baseURL.absoluteString + path)!
        if !query.isEmpty {
            components.queryItems = query
        }
        guard let url = components.url else {
            throw FeishuAPIError.decodeFailed("could not build URL for \(path)")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let ct = contentType {
            request.setValue(ct, forHTTPHeaderField: "Content-Type")
        }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = body
        return request
    }

    /// Pre-decode just the `{ code, msg }` envelope fields so error
    /// branches can read Feishu's verdict before the full payload is
    /// known to be valid.
    private func decodeEnvelopeMetadata(_ data: Data) -> EnvelopeMetadata {
        if let parsed = try? JSONDecoder().decode(EnvelopeMetadata.self, from: data) {
            return parsed
        }
        return EnvelopeMetadata(code: nil, msg: nil)
    }
}

// MARK: - wire shapes

private struct EnvelopeMetadata: Decodable {
    let code: Int?
    let msg: String?
}

private struct EmptyEnvelope: Decodable {
    let code: Int?
    let msg: String?
}

private struct CreateDocumentEnvelope: Decodable {
    let code: Int
    let msg: String?
    let data: CreateData
    struct CreateData: Decodable {
        let document: DocumentRef?
        struct DocumentRef: Decodable {
            let document_id: String?
        }
    }
}

private struct UploadImageEnvelope: Decodable {
    let code: Int
    let msg: String?
    let data: UploadData
    struct UploadData: Decodable {
        let file_token: String?
    }
}

