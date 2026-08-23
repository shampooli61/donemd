import XCTest
@testable import donemd

/// v2 Slice 5 (#47) coverage for `FeishuHTTPAPIClient`.
///
/// Scope of this suite:
///   - HTTP plumbing: auth header attached, 401 → silent refresh-and-
///     retry, 401-after-refresh → `.unauthorized`
///   - retry policy: 429 backs off then retries, exhausts to
///     `.rateLimited`; 5xx behaves the same; the sleeper is mocked so
///     the suite stays fast (no real waits)
///   - error mapping: 403, 404, network outage, malformed JSON
///   - method-specific: pullDocument paginates, uploadImage caches by
///     SHA-256, createDocument decodes document_id
///
/// Out of scope here:
///   - real-network integration (blocked on OAuth #41 — gets a separate
///     `@requires_real_feishu_token`-style harness once the OAuth flow
///     is unstuck)
///   - block-level payload decoding (v2 Slice 5 ships a thin wire
///     stub; full decoding lives in the structural-converter slices)
final class FeishuAPIClientTests: XCTestCase {

    override func tearDown() {
        super.tearDown()
        APIMockProtocol.responses = []
        APIMockProtocol.recordedRequests = []
    }

    // MARK: - auth header + token provider

    func testRequestsCarryAuthorizationBearerHeader() async throws {
        APIMockProtocol.responses = [
            .ok("""
            {"code":0,"data":{"items":[],"page_token":null,"has_more":false}}
            """),
            .ok(metaDocResponse(revisionId: 1)),
        ]
        let client = makeClient(token: "AAA111")
        _ = try await client.pullDocument(documentId: "doc_xyz")
        let recorded = APIMockProtocol.recordedRequests.first
        XCTAssertEqual(
            recorded?.value(forHTTPHeaderField: "Authorization"),
            "Bearer AAA111"
        )
    }

    // MARK: - 401 refresh-and-retry

    func test401TriggersOneRefreshAndRetries() async throws {
        APIMockProtocol.responses = [
            .raw(status: 401, body: """
            {"code":99991663,"msg":"token invalid"}
            """),
            .ok("""
            {"code":0,"data":{"items":[],"page_token":null,"has_more":false}}
            """),
            .ok(metaDocResponse(revisionId: 1)),
        ]
        var refreshCount = 0
        var refreshedToken = "OLD"
        let client = FeishuHTTPAPIClient(
            session: mockSession(),
            tokenProvider: { refreshedToken },
            onUnauthorized: {
                refreshCount += 1
                refreshedToken = "NEW"
                return refreshedToken
            },
            backoff: .immediate,
            sleeper: { _ in }
        )

        _ = try await client.pullDocument(documentId: "doc_xyz")

        XCTAssertEqual(refreshCount, 1)
        XCTAssertEqual(APIMockProtocol.recordedRequests.count, 3,
            "blocks 401 + retry + meta = 3 requests")
        XCTAssertEqual(
            APIMockProtocol.recordedRequests[0].value(forHTTPHeaderField: "Authorization"),
            "Bearer OLD"
        )
        XCTAssertEqual(
            APIMockProtocol.recordedRequests[1].value(forHTTPHeaderField: "Authorization"),
            "Bearer NEW"
        )
    }

    func test401AfterRefreshSurfacesUnauthorized() async throws {
        APIMockProtocol.responses = [
            .raw(status: 401, body: "{\"code\":99991663,\"msg\":\"token invalid\"}"),
            .raw(status: 401, body: "{\"code\":99991663,\"msg\":\"token still invalid\"}"),
        ]
        let client = makeClient(token: "T", backoff: .immediate)
        do {
            _ = try await client.pullDocument(documentId: "d")
            XCTFail("expected unauthorized")
        } catch FeishuAPIError.unauthorized {
            // expected
        }
    }

    // MARK: - 403 / 404

    func testForbiddenSurfacesScopeMessage() async throws {
        APIMockProtocol.responses = [
            .raw(status: 403, body: """
            {"code":99991664,"msg":"scope insufficient: docx:document"}
            """)
        ]
        let client = makeClient(token: "T", backoff: .immediate)
        do {
            _ = try await client.pullDocument(documentId: "d")
            XCTFail("expected forbidden")
        } catch FeishuAPIError.forbidden(let msg) {
            XCTAssertEqual(msg, "scope insufficient: docx:document")
        }
    }

    /// 99991679 (app OAuth scope insufficient) is a HTTP 400 in the
    /// Feishu wire protocol, but it must NOT bucket into the catch-all
    /// `.badRequest` (which reads as "your body is malformed" — wrong
    /// signal). The dedicated `.scopeInsufficient` case lets the UI
    /// route the user to the open-platform console.
    func testScopeInsufficientRoutesAwayFromBadRequest() async throws {
        APIMockProtocol.responses = [
            .raw(status: 400, body: """
            {"code":99991679,"msg":"Unauthorized. ... required: [docs:document.media:download]"}
            """)
        ]
        let client = makeClient(token: "T", backoff: .immediate)
        do {
            _ = try await client.pullDocument(documentId: "d")
            XCTFail("expected scopeInsufficient")
        } catch FeishuAPIError.scopeInsufficient(let detail) {
            // Detail carries the raw msg so triage can spot the
            // missing scope name(s).
            XCTAssertNotNil(detail)
            XCTAssertTrue(detail?.contains("docs:document.media:download") ?? false)
        } catch {
            XCTFail("unexpected error: \(error) — should be scopeInsufficient, not badRequest")
        }
    }

    /// downloadImage runs its own retry pipeline (no JSON envelope on
    /// success), so the 99991679 detection had to be added separately
    /// in the binary path. Lock it.
    func testDownloadImageScopeInsufficient() async throws {
        APIMockProtocol.responses = [
            .raw(status: 400, body: """
            {"code":99991679,"msg":"required: [docs:document.media:download]"}
            """)
        ]
        let client = makeClient(token: "T", backoff: .immediate)
        do {
            _ = try await client.downloadImage(token: "IMG_TOKEN")
            XCTFail("expected scopeInsufficient")
        } catch FeishuAPIError.scopeInsufficient(let detail) {
            XCTAssertNotNil(detail)
            XCTAssertTrue(detail?.contains("docs:document.media:download") ?? false)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testNotFoundCarriesResource() async throws {
        APIMockProtocol.responses = [.raw(status: 404, body: "{}")]
        let client = makeClient(token: "T", backoff: .immediate)
        do {
            _ = try await client.pullDocument(documentId: "missing-doc")
            XCTFail("expected notFound")
        } catch FeishuAPIError.notFound(let resource) {
            XCTAssertEqual(resource, "missing-doc")
        }
    }

    // MARK: - 429 backoff

    func test429BacksOffThenRetriesAndEventuallySucceeds() async throws {
        APIMockProtocol.responses = [
            .raw(status: 429, body: "{\"code\":99991400,\"msg\":\"rate limited\"}"),
            .raw(status: 429, body: "{\"code\":99991400,\"msg\":\"rate limited\"}"),
            .ok("""
            {"code":0,"data":{"items":[],"page_token":null,"has_more":false}}
            """),
            .ok(metaDocResponse(revisionId: 1)),
        ]
        var sleeps: [TimeInterval] = []
        let client = FeishuHTTPAPIClient(
            session: mockSession(),
            tokenProvider: { "T" },
            backoff: .immediate,
            sleeper: { sleeps.append($0) }
        )
        _ = try await client.pullDocument(documentId: "d")
        XCTAssertEqual(APIMockProtocol.recordedRequests.count, 4,
            "two retried blocks + success blocks + meta = 4 requests")
        XCTAssertEqual(sleeps.count, 2,
            "exactly one sleep per retry, no extra sleep on the success leg")
    }

    func test429ExhaustsRetriesAndThrowsRateLimited() async throws {
        APIMockProtocol.responses = (0...4).map { _ in
            .raw(status: 429, body: "{\"code\":99991400,\"msg\":\"rate limited\"}")
        }
        let client = makeClient(token: "T", backoff: .immediate)
        do {
            _ = try await client.pullDocument(documentId: "d")
            XCTFail("expected rateLimited")
        } catch FeishuAPIError.rateLimited {
            // expected
        }
        // initial + maxAttempts(4) retries = 5 calls total
        XCTAssertEqual(APIMockProtocol.recordedRequests.count, 5)
    }

    // MARK: - 5xx

    func test500RetriesAndEventuallyThrowsServerError() async throws {
        APIMockProtocol.responses = (0...4).map { _ in
            .raw(status: 503, body: "{\"code\":99991500,\"msg\":\"server overloaded\"}")
        }
        let client = makeClient(token: "T", backoff: .immediate)
        do {
            _ = try await client.pullDocument(documentId: "d")
            XCTFail("expected serverError")
        } catch FeishuAPIError.serverError(let status, _, let msg) {
            XCTAssertEqual(status, 503)
            XCTAssertEqual(msg, "server overloaded")
        }
    }

    // MARK: - 4xx (client-side: bad request body)

    func test400SurfacesAsBadRequestNotServerError() async throws {
        // Reported during real-device verification: a 400 from Feishu was
        // being mapped to .serverError, which mis-told users it was a
        // transient outage. 4xx is client-side (param-format problem) and
        // gets its own case so the dialog can say "retry won't fix this".
        APIMockProtocol.responses = [
            .raw(status: 400, body: "{\"code\":99991678,\"msg\":\"invalid param\"}")
        ]
        let client = makeClient(token: "T", backoff: .immediate)
        do {
            _ = try await client.pullDocument(documentId: "d")
            XCTFail("expected badRequest")
        } catch FeishuAPIError.badRequest(let status, let code, let msg) {
            XCTAssertEqual(status, 400)
            XCTAssertEqual(code, 99991678)
            XCTAssertEqual(msg, "invalid param")
        }
    }

    func test400DoesNotRetry() async throws {
        // 4xx isn't transient, so unlike 429 / 5xx the client must NOT
        // burn retries on it. One request goes out, error surfaces.
        APIMockProtocol.responses = [
            .raw(status: 400, body: "{\"code\":99991678,\"msg\":\"invalid param\"}")
        ]
        let client = makeClient(token: "T", backoff: .immediate)
        _ = try? await client.pullDocument(documentId: "d")
        XCTAssertEqual(APIMockProtocol.recordedRequests.count, 1,
            "4xx must not be retried — request count should be 1, not 5")
    }

    // MARK: - network outage

    func testURLErrorSurfacesAsNetworkUnreachable() async throws {
        APIMockProtocol.responses = [.failure(URLError(.notConnectedToInternet))]
        let client = makeClient(token: "T", backoff: .immediate)
        do {
            _ = try await client.pullDocument(documentId: "d")
            XCTFail("expected networkUnreachable")
        } catch FeishuAPIError.networkUnreachable {
            // expected
        }
    }

    // MARK: - decode failure

    func testMalformedJSONSurfacesAsDecodeFailed() async throws {
        APIMockProtocol.responses = [.ok("not valid json")]
        let client = makeClient(token: "T", backoff: .immediate)
        do {
            _ = try await client.pullDocument(documentId: "d")
            XCTFail("expected decodeFailed or serverError")
        } catch FeishuAPIError.decodeFailed {
            // expected — when envelope can't even be decoded the catch-all
            // serverError path triggers; but a body that does have code:0
            // and bad data structure surfaces as decodeFailed. We accept
            // either since the contract is "doesn't return junk to caller".
        } catch FeishuAPIError.serverError {
            // also acceptable
        }
    }

    // MARK: - pullDocument pagination

    func testPullDocumentFollowsPageToken() async throws {
        APIMockProtocol.responses = [
            .ok("""
            {"code":0,"data":{
              "items":[{"block_id":"b1","parent_id":null,"block_type":22}],
              "page_token":"PAGE2","has_more":true
            }}
            """),
            .ok("""
            {"code":0,"data":{
              "items":[{"block_id":"b2","parent_id":null,"block_type":22}],
              "page_token":null,"has_more":false
            }}
            """),
            .ok(metaDocResponse(revisionId: 1)),
        ]
        let client = makeClient(token: "T", backoff: .immediate)
        let pulled = try await client.pullDocument(documentId: "doc_paged")
        XCTAssertEqual(pulled.blocks.count, 2)
        XCTAssertEqual(pulled.blocks[0].blockId, "b1")
        XCTAssertEqual(pulled.blocks[1].blockId, "b2")

        // second call must have carried the page_token
        let secondQuery = APIMockProtocol.recordedRequests[1].url?.query ?? ""
        XCTAssertTrue(secondQuery.contains("page_token=PAGE2"))
    }

    func testPullDocumentReturnsRevisionFromMeta() async throws {
        APIMockProtocol.responses = [
            .ok("""
            {"code":0,"data":{
              "items":[{"block_id":"b1","parent_id":null,"block_type":22}],
              "page_token":null,"has_more":false
            }}
            """),
            .ok(metaDocResponse(revisionId: 7)),
        ]
        let client = makeClient(token: "T", backoff: .immediate)
        let pulled = try await client.pullDocument(documentId: "doc_rev")
        XCTAssertEqual(pulled.revisionId, 7,
            "revision_id from data.document.revision_id flows through")
        XCTAssertEqual(APIMockProtocol.recordedRequests[1].url?.path,
            "/open-apis/docx/v1/documents/doc_rev",
            "meta call hits the bare document endpoint")
    }

    // MARK: - createDocument

    func testCreateDocumentReturnsDocumentID() async throws {
        APIMockProtocol.responses = [.ok("""
        {"code":0,"data":{"document":{"document_id":"doxc_NEW"}}}
        """)]
        let client = makeClient(token: "T", backoff: .immediate)
        let id = try await client.createDocument(title: "Hello", parentToken: "fldr_PARENT")
        XCTAssertEqual(id, "doxc_NEW")

        // body should include both title and folder_token
        let body = APIMockProtocol.recordedRequests.first?.bodyData() ?? Data()
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(parsed["title"] as? String, "Hello")
        XCTAssertEqual(parsed["folder_token"] as? String, "fldr_PARENT")
    }

    func testCreateDocumentWithoutParentOmitsFolderToken() async throws {
        APIMockProtocol.responses = [.ok("""
        {"code":0,"data":{"document":{"document_id":"doxc_NEW"}}}
        """)]
        let client = makeClient(token: "T", backoff: .immediate)
        _ = try await client.createDocument(title: "Hello", parentToken: nil)
        let body = APIMockProtocol.recordedRequests.first?.bodyData() ?? Data()
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertNil(parsed["folder_token"], "folder_token must be omitted when caller passes nil")
    }

    // MARK: - updateDocumentTitle

    func testUpdateDocumentTitleHitsPageBlockPatchEndpoint() async throws {
        // Page block_id == document_id by Feishu convention, so the PATCH
        // path collapses to /documents/{id}/blocks/{id}. Body must carry
        // a single text_run element with the new title.
        APIMockProtocol.responses = [.ok("""
        {"code":0,"data":{}}
        """)]
        let client = makeClient(token: "T", backoff: .immediate)

        try await client.updateDocumentTitle(documentId: "doxc_X", title: "New Title")

        let recorded = try XCTUnwrap(APIMockProtocol.recordedRequests.first)
        XCTAssertEqual(recorded.httpMethod, "PATCH")
        let path = recorded.url?.path ?? ""
        XCTAssertEqual(path, "/open-apis/docx/v1/documents/doxc_X/blocks/doxc_X",
            "title PATCH must target the page block (block_id == document_id)")

        let bodyData = recorded.bodyData() ?? Data()
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
        let update = try XCTUnwrap(body["update_text_elements"] as? [String: Any])
        let elements = try XCTUnwrap(update["elements"] as? [[String: Any]])
        XCTAssertEqual(elements.count, 1, "title goes through as a single text_run")
        let run = try XCTUnwrap(elements.first?["text_run"] as? [String: Any])
        XCTAssertEqual(run["content"] as? String, "New Title")

        // Page-block PATCH must NOT carry text_element_style — flipped
        // exactly opposite of the rule for text/heading/etc. blocks.
        // Real-device verification (#57 step4, 2026-05-30) shows the
        // page-block validator returns 1770001 invalid_param when the
        // style block is present, even when every required boolean is
        // false. Cross-checked against feishu-mcp-pro's renameDoc
        // (omits text_element_style and works in the same tenant).
        // Other block types still need the full style object — the
        // 99992402 contract for those is locked in
        // testPushDocumentSendsStyleBooleansOnEveryTextRun, not here.
        XCTAssertNil(run["text_element_style"],
            "page-block PATCH rejects text_element_style with 1770001; omit it")
    }

    // MARK: - pushDocument (blocks delete-then-create orchestration)

    func testPushDocumentDeletesExistingThenPostsDescendant() async throws {
        // The page block_id == document_id by Feishu convention; with one
        // existing root child, push must fire pull → meta → batch_delete →
        // descendant in order. (Internal pull discards the revision but
        // the meta call still fires unconditionally.)
        APIMockProtocol.responses = [
            .ok("""
            {"code":0,"data":{
              "items":[
                {"block_id":"doc_target","block_type":1,"children":["bx_old"],
                 "page":{"elements":[]}}
              ],
              "page_token":null,"has_more":false
            }}
            """),
            .ok(metaDocResponse(revisionId: 1)),
            .ok("{\"code\":0}"),
            .ok("{\"code\":0}"),
        ]
        let client = makeClient(token: "T", backoff: .immediate)
        let blocks = FeishuStructuralConverter.toFeishuBlocks("# Hello\n")
        try await client.pushDocument(documentId: "doc_target", blocks: blocks)

        XCTAssertEqual(APIMockProtocol.recordedRequests.count, 4,
            "must call pull blocks → pull meta → batch_delete → descendant in order")
        XCTAssertEqual(APIMockProtocol.recordedRequests[0].url?.path,
            "/open-apis/docx/v1/documents/doc_target/blocks")
        XCTAssertEqual(APIMockProtocol.recordedRequests[0].httpMethod, "GET")
        XCTAssertEqual(APIMockProtocol.recordedRequests[1].url?.path,
            "/open-apis/docx/v1/documents/doc_target")
        XCTAssertEqual(APIMockProtocol.recordedRequests[1].httpMethod, "GET")
        XCTAssertEqual(APIMockProtocol.recordedRequests[2].url?.path,
            "/open-apis/docx/v1/documents/doc_target/blocks/doc_target/children/batch_delete")
        XCTAssertEqual(APIMockProtocol.recordedRequests[2].httpMethod, "DELETE")
        XCTAssertEqual(APIMockProtocol.recordedRequests[3].url?.path,
            "/open-apis/docx/v1/documents/doc_target/blocks/doc_target/descendant")
        XCTAssertEqual(APIMockProtocol.recordedRequests[3].httpMethod, "POST")

        let deleteBody = APIMockProtocol.recordedRequests[2].bodyData() ?? Data()
        let deleteParsed = try XCTUnwrap(
            JSONSerialization.jsonObject(with: deleteBody) as? [String: Any]
        )
        XCTAssertEqual(deleteParsed["start_index"] as? Int, 0)
        XCTAssertEqual(deleteParsed["end_index"] as? Int, 1,
            "end_index must equal the existing root child count")

        let descBody = APIMockProtocol.recordedRequests[3].bodyData() ?? Data()
        let descParsed = try XCTUnwrap(
            JSONSerialization.jsonObject(with: descBody) as? [String: Any]
        )
        XCTAssertEqual(descParsed["index"] as? Int, -1)
        XCTAssertNotNil(descParsed["children_id"] as? [String])
        XCTAssertNotNil(descParsed["descendants"] as? [[String: Any]])
    }

    func testPushDocumentSkipsDeleteWhenPageHasNoChildren() async throws {
        // Empty doc → nothing to delete, just pull blocks → pull meta →
        // POST descendants.
        APIMockProtocol.responses = [
            .ok("""
            {"code":0,"data":{
              "items":[
                {"block_id":"doc_target","block_type":1,"children":[],
                 "page":{"elements":[]}}
              ],
              "page_token":null,"has_more":false
            }}
            """),
            .ok(metaDocResponse(revisionId: 1)),
            .ok("{\"code\":0}"),
        ]
        let client = makeClient(token: "T", backoff: .immediate)
        let blocks = FeishuStructuralConverter.toFeishuBlocks("# Hello\n")
        try await client.pushDocument(documentId: "doc_target", blocks: blocks)

        XCTAssertEqual(APIMockProtocol.recordedRequests.count, 3,
            "no children means no batch_delete leg (blocks + meta + descendant)")
        XCTAssertEqual(APIMockProtocol.recordedRequests[2].url?.path,
            "/open-apis/docx/v1/documents/doc_target/blocks/doc_target/descendant")
    }

    // MARK: - uploadImage cache

    func testUploadImageReturnsTokenAndCachesBySHA256() async throws {
        APIMockProtocol.responses = [.ok("""
        {"code":0,"data":{"file_token":"img_AAA"}}
        """)]
        let cache = InMemoryFeishuImageCache()
        let client = FeishuHTTPAPIClient(
            session: mockSession(),
            tokenProvider: { "T" },
            imageCache: cache,
            backoff: .immediate,
            sleeper: { _ in }
        )
        let payload = "fake-png-bytes".data(using: .utf8)!
        let token = try await client.uploadImage(
            data: payload, mimeType: "image/png", fileName: "a.png",
            documentId: "doxc_TEST"
        )
        XCTAssertEqual(token, "img_AAA")
        XCTAssertEqual(APIMockProtocol.recordedRequests.count, 1)

        // Second call with same bytes must NOT hit the network — cache hit.
        APIMockProtocol.responses = []  // any HTTP call would crash the mock
        let cached = try await client.uploadImage(
            data: payload, mimeType: "image/png", fileName: "renamed.png",
            documentId: "doxc_TEST"
        )
        XCTAssertEqual(cached, "img_AAA",
            "cache must be keyed on content hash, not filename")
    }

    func testUploadImageDifferentBytesReuploads() async throws {
        APIMockProtocol.responses = [
            .ok("{\"code\":0,\"data\":{\"file_token\":\"img_AAA\"}}"),
            .ok("{\"code\":0,\"data\":{\"file_token\":\"img_BBB\"}}"),
        ]
        let client = makeClient(token: "T", backoff: .immediate)
        let t1 = try await client.uploadImage(
            data: Data([0x01]), mimeType: "image/png", fileName: "a.png",
            documentId: "doxc_TEST"
        )
        let t2 = try await client.uploadImage(
            data: Data([0x02]), mimeType: "image/png", fileName: "a.png",
            documentId: "doxc_TEST"
        )
        XCTAssertNotEqual(t1, t2)
    }

    // MARK: - backoff policy

    func testBackoffPolicyClampsToMaxDelay() {
        let policy = FeishuBackoffPolicy(
            initialDelay: 1, multiplier: 2, maxDelay: 8,
            maxAttempts: 10, jitter: 0
        )
        XCTAssertEqual(policy.delay(forAttempt: 0), 1)
        XCTAssertEqual(policy.delay(forAttempt: 1), 2)
        XCTAssertEqual(policy.delay(forAttempt: 3), 8)
        XCTAssertEqual(policy.delay(forAttempt: 100), 8,
            "high attempt counts must clamp at maxDelay")
    }

    // MARK: - helpers

    /// Stand-in for the `GET /open-apis/docx/v1/documents/{id}` envelope
    /// that `pullDocument` now fetches after the blocks pagination loop.
    /// Tests that exercise a successful pull queue this immediately after
    /// the final blocks page response.
    private func metaDocResponse(revisionId: Int) -> String {
        """
        {"code":0,"data":{"document":{"document_id":"d","revision_id":\(revisionId)}}}
        """
    }

    private func makeClient(
        token: String,
        backoff: FeishuBackoffPolicy = .immediate
    ) -> FeishuHTTPAPIClient {
        FeishuHTTPAPIClient(
            session: mockSession(),
            tokenProvider: { token },
            backoff: backoff,
            sleeper: { _ in }
        )
    }

    private func mockSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [APIMockProtocol.self]
        return URLSession(configuration: config)
    }
}

// MARK: - URLProtocol mock

enum APIMockResponse {
    case ok(String)
    case raw(status: Int, body: String)
    case failure(Error)
}

final class APIMockProtocol: URLProtocol {
    /// Each request consumes the next response in FIFO order — tests
    /// queue the exact response sequence they expect.
    static var responses: [APIMockResponse] = []
    static var recordedRequests: [URLRequest] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        // URLSession strips httpBody by the time it gets here; restore
        // it from `httpBodyStream` so test assertions on body work.
        var recorded = request
        if request.httpBody == nil, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                if read <= 0 { break }
                data.append(buffer, count: read)
            }
            recorded.httpBody = data
        }
        Self.recordedRequests.append(recorded)

        guard !Self.responses.isEmpty else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }
        let response = Self.responses.removeFirst()
        switch response {
        case .ok(let body):
            send(status: 200, body: body)
        case .raw(let status, let body):
            send(status: status, body: body)
        case .failure(let error):
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    private func send(status: Int, body: String) {
        let url = request.url!
        let resp = HTTPURLResponse(
            url: url, statusCode: status,
            httpVersion: "HTTP/1.1", headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body.data(using: .utf8) ?? Data())
        client?.urlProtocolDidFinishLoading(self)
    }
}

private extension URLRequest {
    func bodyData() -> Data? {
        if let direct = httpBody { return direct }
        guard let stream = httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}
