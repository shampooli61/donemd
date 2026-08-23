import XCTest
@testable import donemd

/// v2-2B-2 coverage for `FeishuOAuthClient` (issue #41).
///
/// These tests hit the network layer through a `URLProtocol` mock and the
/// callback receiver / browser opener through small fakes. The real
/// `KeychainCredentialStore` is replaced with `InMemoryCredentialStore`
/// so nothing leaks into the user's login keychain during CI.
///
/// What's NOT covered here (and why):
///   - end-to-end browser → Feishu → loopback round trip — that's the
///     manual integration test the user runs once with real creds.
///   - `NSWorkspaceURLOpener` itself — it's a one-line shim around the
///     system framework; testing it would mean opening a browser tab on
///     every CI run.
final class FeishuOAuthClientTests: XCTestCase {

    // MARK: - fixtures

    private let testConfig = FeishuAppConfig(
        clientID: "cli_test123",
        clientSecret: "secret-test",
        redirectURI: "http://localhost:18127/oauth/callback"
    )

    override func tearDown() {
        super.tearDown()
        MockURLProtocol.handler = nil
    }

    // MARK: - login

    func testLoginExchangesCodeAndPersistsCredentials() async throws {
        let store = InMemoryCredentialStore()
        let opener = RecordingURLOpener()
        let receiver = StubReceiver(
            redirectURI: testConfig.redirectURI,
            callback: URL(string: "\(testConfig.redirectURI)?code=auth_code_xyz&state=STATE_FIXED")!
        )
        let session = mockSession { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url, FeishuOAuthClient.tokenEndpoint)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"),
                           "application/json; charset=utf-8")
            let body = try XCTUnwrap(request.bodyData())
            let parsed = try XCTUnwrap(
                JSONSerialization.jsonObject(with: body) as? [String: String]
            )
            XCTAssertEqual(parsed["grant_type"], "authorization_code")
            XCTAssertEqual(parsed["client_id"], "cli_test123")
            XCTAssertEqual(parsed["client_secret"], "secret-test")
            XCTAssertEqual(parsed["code"], "auth_code_xyz")
            XCTAssertEqual(parsed["redirect_uri"], "http://localhost:18127/oauth/callback")
            return Self.successTokenResponse()
        }
        let fixedNow = Date(timeIntervalSince1970: 1_700_000_000)
        let client = FeishuOAuthClient(
            config: testConfig,
            store: store,
            receiver: receiver,
            urlSession: session,
            opener: opener,
            now: { fixedNow },
            stateGenerator: { "STATE_FIXED" }
        )

        let credentials = try await client.login(timeout: 5)

        XCTAssertEqual(credentials.accessToken, "access-abc")
        XCTAssertEqual(credentials.refreshToken, "refresh-def")
        XCTAssertEqual(credentials.expiresAt, fixedNow.addingTimeInterval(7200))
        XCTAssertEqual(try store.load(), credentials,
            "successful login must persist to the store")

        XCTAssertEqual(opener.opened.count, 1)
        let openedURL = try XCTUnwrap(opener.opened.first)
        let queryItems = try XCTUnwrap(
            URLComponents(url: openedURL, resolvingAgainstBaseURL: false)?.queryItems
        )
        let queryDict = Dictionary(uniqueKeysWithValues: queryItems.map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(queryDict["app_id"], "cli_test123")
        XCTAssertEqual(queryDict["redirect_uri"], "http://localhost:18127/oauth/callback")
        XCTAssertEqual(queryDict["state"], "STATE_FIXED")
        XCTAssertEqual(queryDict["scope"], "docx:document wiki:wiki docs:document.media:download docs:document.media:upload offline_access")
        XCTAssertEqual(receiver.lastExpectedState, "STATE_FIXED",
            "client must hand its generated state to the receiver for CSRF check")
    }

    func testLoginPropagatesFeishuErrorCode() async throws {
        let store = InMemoryCredentialStore()
        let receiver = StubReceiver(
            redirectURI: testConfig.redirectURI,
            callback: URL(string: "\(testConfig.redirectURI)?code=bad&state=S")!
        )
        let session = mockSession { _ in
            // Feishu's error envelope: HTTP 200 but `code != 0`. We must
            // still treat this as failure, not silently surface a token-less
            // credentials object.
            (200, """
            {"code": 20007, "msg": "code invalid"}
            """.data(using: .utf8)!)
        }
        let client = FeishuOAuthClient(
            config: testConfig,
            store: store,
            receiver: receiver,
            urlSession: session,
            opener: RecordingURLOpener(),
            stateGenerator: { "S" }
        )

        do {
            _ = try await client.login(timeout: 1)
            XCTFail("expected tokenExchangeFailed")
        } catch FeishuOAuthClient.OAuthError.tokenExchangeFailed(let status, let code, let msg) {
            XCTAssertEqual(status, 200)
            XCTAssertEqual(code, 20007)
            XCTAssertEqual(msg, "code invalid")
        }
        XCTAssertNil(try store.load(), "failed login must not persist anything")
    }

    func testLoginRejectsCallbackMissingCode() async throws {
        let store = InMemoryCredentialStore()
        let receiver = StubReceiver(
            redirectURI: testConfig.redirectURI,
            // State matched (receiver-side check passed), but Feishu somehow
            // returned no `code` — probably a config-side error page that
            // still hit our redirect. Surface it cleanly.
            callback: URL(string: "\(testConfig.redirectURI)?state=S")!
        )
        let session = mockSession { _ in (200, Data()) }
        let client = FeishuOAuthClient(
            config: testConfig,
            store: store,
            receiver: receiver,
            urlSession: session,
            opener: RecordingURLOpener(),
            stateGenerator: { "S" }
        )

        do {
            _ = try await client.login(timeout: 1)
            XCTFail("expected decodeFailed")
        } catch FeishuOAuthClient.OAuthError.decodeFailed {
            // expected
        }
    }

    // MARK: - refreshIfNeeded

    func testRefreshIfNeededShortCircuitsWhenTokenFresh() async throws {
        let fixedNow = Date(timeIntervalSince1970: 1_700_000_000)
        let store = InMemoryCredentialStore()
        let fresh = FeishuCredentials(
            accessToken: "still-good",
            refreshToken: "rt",
            expiresAt: fixedNow.addingTimeInterval(3600)
        )
        try store.save(fresh)

        var hitNetwork = false
        let session = mockSession { _ in
            hitNetwork = true
            return (200, Data())
        }
        let client = FeishuOAuthClient(
            config: testConfig,
            store: store,
            receiver: NeverReceiver(redirectURI: testConfig.redirectURI),
            urlSession: session,
            opener: RecordingURLOpener(),
            now: { fixedNow }
        )

        let result = try await client.refreshIfNeeded()
        XCTAssertEqual(result, fresh)
        XCTAssertFalse(hitNetwork, "fresh token must not trigger a refresh request")
    }

    func testRefreshIfNeededExchangesAndPersistsWhenExpired() async throws {
        let fixedNow = Date(timeIntervalSince1970: 1_700_000_000)
        let store = InMemoryCredentialStore()
        let stale = FeishuCredentials(
            accessToken: "old-token",
            refreshToken: "old-refresh",
            // already past expiry
            expiresAt: fixedNow.addingTimeInterval(-10)
        )
        try store.save(stale)

        let session = mockSession { request in
            let body = try XCTUnwrap(request.bodyData())
            let parsed = try XCTUnwrap(
                JSONSerialization.jsonObject(with: body) as? [String: String]
            )
            XCTAssertEqual(parsed["grant_type"], "refresh_token")
            XCTAssertEqual(parsed["refresh_token"], "old-refresh")
            XCTAssertEqual(parsed["scope"], "docx:document wiki:wiki docs:document.media:download docs:document.media:upload offline_access")
            return Self.successTokenResponse(
                accessToken: "new-token", refreshToken: "new-refresh"
            )
        }
        let client = FeishuOAuthClient(
            config: testConfig,
            store: store,
            receiver: NeverReceiver(redirectURI: testConfig.redirectURI),
            urlSession: session,
            opener: RecordingURLOpener(),
            now: { fixedNow }
        )

        let refreshed = try await client.refreshIfNeeded()
        XCTAssertEqual(refreshed.accessToken, "new-token")
        XCTAssertEqual(refreshed.refreshToken, "new-refresh",
            "refreshed credentials must use Feishu's NEW refresh token")
        XCTAssertEqual(try store.load(), refreshed,
            "refreshed credentials must replace the stale ones in the store")
    }

    func testRefreshIfNeededWithEmptyStoreThrowsNotAuthenticated() async throws {
        let store = InMemoryCredentialStore()
        let client = FeishuOAuthClient(
            config: testConfig,
            store: store,
            receiver: NeverReceiver(redirectURI: testConfig.redirectURI),
            urlSession: mockSession { _ in (200, Data()) },
            opener: RecordingURLOpener()
        )
        do {
            _ = try await client.refreshIfNeeded()
            XCTFail("expected notAuthenticated")
        } catch FeishuOAuthClient.OAuthError.notAuthenticated {
            // expected
        }
    }

    // MARK: - logout

    func testLogoutClearsStore() async throws {
        let store = InMemoryCredentialStore()
        try store.save(FeishuCredentials(
            accessToken: "a", refreshToken: "r",
            expiresAt: Date().addingTimeInterval(3600)
        ))
        XCTAssertNotNil(try store.load())
        let client = FeishuOAuthClient(
            config: testConfig,
            store: store,
            receiver: NeverReceiver(redirectURI: testConfig.redirectURI),
            urlSession: mockSession { _ in (200, Data()) },
            opener: RecordingURLOpener()
        )
        try await client.logout()
        XCTAssertNil(try store.load())
    }

    // MARK: - URL building

    func testBuildAuthorizeURLEncodesQueryParams() throws {
        let client = FeishuOAuthClient(
            config: testConfig,
            store: InMemoryCredentialStore(),
            receiver: NeverReceiver(redirectURI: testConfig.redirectURI),
            opener: RecordingURLOpener()
        )
        let url = try client.buildAuthorizeURL(state: "abc")
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.host, "accounts.feishu.cn")
        XCTAssertEqual(components.path, "/open-apis/authen/v1/authorize")
        let items = try XCTUnwrap(components.queryItems)
        let dict = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(dict["app_id"], "cli_test123")
        XCTAssertEqual(dict["state"], "abc")
        XCTAssertTrue(dict["scope"]?.contains("offline_access") == true,
            "scopes must include offline_access for the refresh-token issuance")
    }

    func testRandomStateLooksRandom() {
        let a = FeishuOAuthClient.makeRandomState()
        let b = FeishuOAuthClient.makeRandomState()
        XCTAssertEqual(a.count, 32, "16 bytes of randomness => 32 hex chars")
        XCTAssertNotEqual(a, b, "state generator must not return constants")
    }

    // MARK: - helpers

    private func mockSession(handler: @escaping (URLRequest) throws -> (Int, Data)) -> URLSession {
        MockURLProtocol.handler = handler
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }

    private static func successTokenResponse(
        accessToken: String = "access-abc",
        refreshToken: String = "refresh-def",
        expiresIn: Int = 7200
    ) -> (Int, Data) {
        let json = """
        {
            "code": 0,
            "msg": "success",
            "access_token": "\(accessToken)",
            "refresh_token": "\(refreshToken)",
            "expires_in": \(expiresIn),
            "refresh_token_expires_in": 604800,
            "scope": "docx:document wiki:wiki offline_access",
            "token_type": "Bearer",
            "tenant_key": "ten_abc"
        }
        """
        return (200, json.data(using: .utf8)!)
    }
}

// MARK: - test doubles

/// Minimal in-memory `CredentialStore` — keychain isn't usable from
/// tests without polluting the user's login keychain.
final class InMemoryCredentialStore: CredentialStore {
    private var stored: FeishuCredentials?
    func save(_ credentials: FeishuCredentials) throws { stored = credentials }
    func load() throws -> FeishuCredentials? { stored }
    func clear() throws { stored = nil }
}

/// Returns the URL the test wired up immediately; never actually binds a
/// port.
private final class StubReceiver: FeishuOAuthCallbackReceiver {
    let redirectURI: String
    private let callback: URL
    private(set) var lastExpectedState: String?

    init(redirectURI: String, callback: URL) {
        self.redirectURI = redirectURI
        self.callback = callback
    }

    func awaitCallback(expectedState: String, timeout: TimeInterval) async throws -> URL {
        lastExpectedState = expectedState
        return callback
    }
}

/// Used for code paths that must NOT reach the receiver (refresh, logout,
/// URL building) — fails the test if invoked.
private final class NeverReceiver: FeishuOAuthCallbackReceiver {
    let redirectURI: String
    init(redirectURI: String) { self.redirectURI = redirectURI }
    func awaitCallback(expectedState: String, timeout: TimeInterval) async throws -> URL {
        XCTFail("receiver must not be invoked on this path")
        throw FeishuOAuthLoopbackReceiver.ReceiverError.cancelled
    }
}

private final class RecordingURLOpener: FeishuAuthorizeURLOpener {
    var opened: [URL] = []
    func open(_ url: URL) throws { opened.append(url) }
}

/// `URLProtocol` subclass that consults a closure for every request — the
/// closure decides the HTTP status and body. Lets the OAuth client be
/// driven through real `URLSession.data(for:)` codepaths without
/// hitting the network.
final class MockURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        do {
            // URLSession strips the body off `URLRequest` by the time it
            // reaches URLProtocol; recover it from `httpBodyStream` so
            // tests can assert on what we actually sent.
            let restored = restoreBody(of: request)
            let (status, data) = try handler(restored)
            let response = HTTPURLResponse(
                url: request.url!, statusCode: status,
                httpVersion: "HTTP/1.1", headerFields: nil
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    private func restoreBody(of request: URLRequest) -> URLRequest {
        var mutable = request
        if request.httpBody == nil, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var data = Data()
            let bufferSize = 4096
            var buffer = [UInt8](repeating: 0, count: bufferSize)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: bufferSize)
                if read <= 0 { break }
                data.append(buffer, count: read)
            }
            mutable.httpBody = data
        }
        return mutable
    }
}

private extension URLRequest {
    func bodyData() -> Data? {
        if let direct = httpBody { return direct }
        guard let stream = httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 4096
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: bufferSize)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}
