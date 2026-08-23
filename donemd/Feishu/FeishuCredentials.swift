import Foundation

/// OAuth credentials returned by Feishu after a successful authorization
/// exchange — held in `KeychainCredentialStore` between launches.
///
/// Field shape mirrors the JSON Feishu's `/open-apis/authen/v1/access_token`
/// endpoint returns; we keep field names in Swift `lowerCamelCase` and rely
/// on `Codable` keyed by `CodingKeys` to bridge to the wire `snake_case`.
///
/// `expiresAt` is stored as an absolute `Date` (computed at exchange time
/// from `expires_in` seconds) rather than a duration, so a stale read after
/// a long sleep doesn't accidentally treat the token as still valid.
public struct FeishuCredentials: Equatable, Codable {

    /// Short-lived bearer token presented on every API call.
    public var accessToken: String
    /// Long-lived token used to mint a fresh `accessToken` without
    /// re-prompting the user. Feishu issues a new refresh token on every
    /// refresh exchange — the latest must be persisted.
    public var refreshToken: String
    /// Absolute expiry of `accessToken`. `refreshIfNeeded` (v2-2B) compares
    /// against `Date()` with a small skew margin.
    public var expiresAt: Date
    /// Tenant key — Feishu uses this to scope API calls when the user
    /// belongs to multiple tenants. Optional because some self-built apps
    /// run in a single tenant and Feishu omits it.
    public var tenantKey: String?

    public init(
        accessToken: String,
        refreshToken: String,
        expiresAt: Date,
        tenantKey: String? = nil
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.tenantKey = tenantKey
    }

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresAt = "expires_at"
        case tenantKey = "tenant_key"
    }

    /// `true` when `accessToken` is past expiry (with a 60s skew so a token
    /// that expires while a request is mid-flight is treated as expired,
    /// not borderline-valid).
    public func isExpired(now: Date = Date(), skew: TimeInterval = 60) -> Bool {
        now.addingTimeInterval(skew) >= expiresAt
    }
}
