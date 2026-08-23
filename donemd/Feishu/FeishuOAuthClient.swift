import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// Browser-launching abstraction so unit tests can stub `login()` without
/// kicking off Safari. The default impl in `FeishuOAuthClient.makeDefault`
/// uses `NSWorkspace.open(_:)`.
public protocol FeishuAuthorizeURLOpener {
    func open(_ url: URL) throws
}

/// High-level Feishu OAuth v2 client — owns the full login / refresh /
/// logout lifecycle and persists `FeishuCredentials` through an injected
/// `CredentialStore`.
///
/// Wire-format reference (verified from the open-platform docs the user
/// pulled on 2026-05-23):
///   - authorize: `https://accounts.feishu.cn/open-apis/authen/v1/authorize`
///     (GET, browser); query params `app_id`, `redirect_uri`, `state`,
///     `scope` (space-joined)
///   - token:     `https://open.feishu.cn/open-apis/authen/v2/oauth/token`
///     (POST `application/json; charset=utf-8`); response is FLAT — fields
///     live at the top level (`access_token`, `refresh_token`, `expires_in`,
///     `refresh_token_expires_in`, …) with a sentinel `code` field that's
///     `0` on success
///
/// CSRF: `state` is a random opaque token generated per `login()` and
/// validated inside `FeishuOAuthCallbackReceiver` before the URL is
/// surfaced — see [[receiver-state-mismatch]] error path.
public final class FeishuOAuthClient {

    public enum OAuthError: Error, Equatable {
        /// `FeishuAppConfig.load()` returned nil. UI should route to an
        /// onboarding screen ("paste your App ID / Secret") instead of
        /// trying to log in.
        case notConfigured
        /// `refreshIfNeeded` / `accessToken()` called before any successful
        /// login (or after `logout()`).
        case notAuthenticated
        /// HTTP status outside 2xx, OR Feishu's `code` field is non-zero.
        /// `code` and `msg` are surfaced verbatim so the UI can show
        /// Feishu's own error string.
        case tokenExchangeFailed(httpStatus: Int, code: Int?, message: String?)
        /// JSON body did not parse into the expected shape — usually means
        /// the wire format changed. Carries a short hint, not the body.
        case decodeFailed(String)
        /// Something went wrong opening the system browser (eg sandboxed
        /// build with no `com.apple.security.network.client`).
        case browserOpenFailed(String)
    }

    /// Exact scope strings sent to Feishu — these must be granted in the
    /// app's "权限管理" page on open.feishu.cn first or the authorize page
    /// will refuse the request.
    ///
    /// `offline_access` is the one that mints the refresh token; without
    /// it the user has to re-login every 2 hours.
    ///
    /// **The token's grants are a snapshot of what we requested here when
    /// the user authorized.** Adding a scope to the app's 权限管理 page
    /// alone does NOT grant it to existing tokens — the user has to
    /// re-authorize through this list. So whenever we start calling a
    /// new endpoint, the corresponding scope must show up here AND
    /// users must log out + log in. Real-device verification 2026-05-30:
    /// `docs:document.media:download` was checked in 权限管理 but
    /// missing from this list, so /drive/v1/medias/{token}/download
    /// kept failing with code 99991679 even after re-login.
    ///
    /// Coverage so far:
    /// - docx:document — push/pull docx blocks (v2-9 / v2-8)
    /// - wiki:wiki — wiki node CRUD (kept for compatibility, not
    ///   actively called yet)
    /// - docs:document.media:download — drive media download for
    ///   the pull-side image stage (#21, 2026-05-30)
    /// - docs:document.media:upload — drive media upload for the
    ///   push-side image stage (real-device #21 follow-up:
    ///   uploading to /drive/v1/medias/upload_all returned 99991679
    ///   when only the download scope was requested)
    /// - offline_access — refresh token issuance
    public static let defaultScopes: [String] = [
        "docx:document",
        "wiki:wiki",
        "docs:document.media:download",
        "docs:document.media:upload",
        "offline_access",
    ]

    public static let authorizeEndpoint = URL(string: "https://accounts.feishu.cn/open-apis/authen/v1/authorize")!
    public static let tokenEndpoint = URL(string: "https://open.feishu.cn/open-apis/authen/v2/oauth/token")!

    private let config: FeishuAppConfig
    private let store: CredentialStore
    private let receiver: FeishuOAuthCallbackReceiver
    private let urlSession: URLSession
    private let opener: FeishuAuthorizeURLOpener
    private let scopes: [String]
    private let now: () -> Date
    private let stateGenerator: () -> String

    /// Designated initializer — every dependency is injectable so the
    /// network layer can be exercised against a `URLProtocol` mock.
    public init(
        config: FeishuAppConfig,
        store: CredentialStore,
        receiver: FeishuOAuthCallbackReceiver,
        urlSession: URLSession = .shared,
        opener: FeishuAuthorizeURLOpener,
        scopes: [String] = FeishuOAuthClient.defaultScopes,
        now: @escaping () -> Date = Date.init,
        stateGenerator: @escaping () -> String = FeishuOAuthClient.makeRandomState
    ) {
        self.config = config
        self.store = store
        self.receiver = receiver
        self.urlSession = urlSession
        self.opener = opener
        self.scopes = scopes
        self.now = now
        self.stateGenerator = stateGenerator
    }

    /// Drive the full authorize-code flow:
    ///   1. mint random `state`
    ///   2. open the authorize URL in the user's default browser
    ///   3. await the loopback redirect (validates `state` internally)
    ///   4. POST the auth code to the token endpoint
    ///   5. persist the resulting `FeishuCredentials` to the store
    ///
    /// Returns the freshly minted credentials. The caller doesn't need to
    /// re-load them from the store — but they are persisted so the next
    /// app launch can pick them up.
    @discardableResult
    public func login(timeout: TimeInterval = 300) async throws -> FeishuCredentials {
        let state = stateGenerator()
        let authorizeURL = try buildAuthorizeURL(state: state)

        do {
            try opener.open(authorizeURL)
        } catch {
            throw OAuthError.browserOpenFailed("\(error)")
        }

        let callbackURL = try await receiver.awaitCallback(
            expectedState: state, timeout: timeout
        )

        guard let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false),
              let code = components.queryItems?.first(where: { $0.name == "code" })?.value,
              !code.isEmpty
        else {
            throw OAuthError.decodeFailed("authorization callback missing 'code'")
        }

        let credentials = try await exchange(code: code)
        try store.save(credentials)
        return credentials
    }

    /// Return a non-expired access token, refreshing once if needed. If
    /// the store has no credentials at all, throws `.notAuthenticated` —
    /// the caller should route to `login()`.
    @discardableResult
    public func refreshIfNeeded() async throws -> FeishuCredentials {
        guard let stored = try store.load() else {
            throw OAuthError.notAuthenticated
        }
        if !stored.isExpired(now: now()) {
            return stored
        }
        let refreshed = try await refresh(refreshToken: stored.refreshToken)
        try store.save(refreshed)
        return refreshed
    }

    /// Best-effort logout: clears the local store unconditionally so a
    /// follow-up `login()` starts clean. Feishu does expose a revoke
    /// endpoint but it requires a tenant access token Done.md doesn't
    /// have client-side, so we don't network-call it from here.
    public func logout() async throws {
        try store.clear()
    }

    // MARK: - URL building

    func buildAuthorizeURL(state: String) throws -> URL {
        var components = URLComponents(url: Self.authorizeEndpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "app_id", value: config.clientID),
            URLQueryItem(name: "redirect_uri", value: config.redirectURI),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "scope", value: scopes.joined(separator: " ")),
        ]
        guard let url = components.url else {
            throw OAuthError.decodeFailed("could not build authorize URL")
        }
        return url
    }

    // MARK: - token endpoint

    private func exchange(code: String) async throws -> FeishuCredentials {
        let body: [String: String] = [
            "grant_type": "authorization_code",
            "client_id": config.clientID,
            "client_secret": config.clientSecret,
            "code": code,
            "redirect_uri": config.redirectURI,
        ]
        return try await postToken(body: body)
    }

    private func refresh(refreshToken: String) async throws -> FeishuCredentials {
        let body: [String: String] = [
            "grant_type": "refresh_token",
            "client_id": config.clientID,
            "client_secret": config.clientSecret,
            "refresh_token": refreshToken,
            // Re-asserting scope on refresh keeps the refreshed token
            // narrowed to the same set the user originally consented to.
            "scope": scopes.joined(separator: " "),
        ]
        return try await postToken(body: body)
    }

    private func postToken(body: [String: String]) async throws -> FeishuCredentials {
        var request = URLRequest(url: Self.tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])

        let (data, response) = try await urlSession.data(for: request)
        let httpStatus = (response as? HTTPURLResponse)?.statusCode ?? -1

        let payload: TokenResponse
        do {
            payload = try JSONDecoder().decode(TokenResponse.self, from: data)
        } catch {
            throw OAuthError.tokenExchangeFailed(
                httpStatus: httpStatus, code: nil, message: "non-JSON response"
            )
        }

        guard (200..<300).contains(httpStatus), payload.code == 0 else {
            throw OAuthError.tokenExchangeFailed(
                httpStatus: httpStatus, code: payload.code, message: payload.msg
            )
        }

        guard let accessToken = payload.access_token,
              let expiresIn = payload.expires_in
        else {
            throw OAuthError.decodeFailed("token response missing access_token / expires_in")
        }

        // refresh_token is only returned when `offline_access` was in the
        // granted scope. Missing it is not a hard failure — the user just
        // has to re-login when the access token expires (~2h). We persist
        // an empty string so the credential model stays simple; downstream
        // `refreshIfNeeded` will surface a clean tokenExchangeFailed when
        // it tries to use the empty refresh token.
        return FeishuCredentials(
            accessToken: accessToken,
            refreshToken: payload.refresh_token ?? "",
            expiresAt: now().addingTimeInterval(TimeInterval(expiresIn)),
            tenantKey: payload.tenant_key
        )
    }

    // MARK: - state generator

    /// 128 bits of randomness, hex-encoded. Plenty for a single-use CSRF
    /// token; keeping it short(-ish) means the redirect URL doesn't blow
    /// past common URL length limits.
    public static func makeRandomState() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - default opener

#if canImport(AppKit)
/// `NSWorkspace.open(_:)` wrapper — splits the side-effect out so tests
/// can swap it for a recording fake.
public struct NSWorkspaceURLOpener: FeishuAuthorizeURLOpener {
    public init() {}
    public func open(_ url: URL) throws {
        guard NSWorkspace.shared.open(url) else {
            throw FeishuOAuthClient.OAuthError.browserOpenFailed("NSWorkspace.open returned false")
        }
    }
}
#endif

// MARK: - wire shape

/// Internal mirror of the token endpoint's flat JSON body. Snake-case
/// names are kept verbatim (rather than mapped through `CodingKeys`) so
/// the decoder is small and the field list reads like the Feishu doc.
///
/// All fields except `code` are optional because the same struct decodes
/// both success bodies (full token set) and error bodies (just `code` /
/// `msg`).
private struct TokenResponse: Decodable {
    let code: Int
    let msg: String?
    let access_token: String?
    let refresh_token: String?
    let expires_in: Int?
    let refresh_token_expires_in: Int?
    let scope: String?
    let token_type: String?
    let tenant_key: String?
}
