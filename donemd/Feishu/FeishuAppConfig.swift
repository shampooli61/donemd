import Foundation

/// Static configuration the OAuth flow needs from the Feishu open
/// platform — App ID, App Secret, and the redirect URI registered in
/// the app's security settings. Distinct from `FeishuCredentials`
/// (which is per-user and lives in the keychain after login).
///
/// Resolution precedence at runtime (`load(...)`):
///   1. macOS Keychain (`FeishuKeychainAppConfigStore`) — what the v2-10
///      Settings → 飞书同步 panel writes when the user types credentials
///      into the UI. Highest priority so a user's deliberate Settings
///      edit always wins over leftover env / plist values.
///   2. environment variables `DONEMD_FEISHU_APP_ID` /
///      `DONEMD_FEISHU_APP_SECRET` / `DONEMD_FEISHU_REDIRECT_URI`
///   3. `~/Library/Application Support/Done.md/feishu-config.plist`
///   4. `feishu-config.plist` inside the app bundle (built-in fallback;
///      empty in distributed builds — Done.md's public release ships
///      no embedded credentials, every user provisions their own)
///
/// Returns `nil` (rather than throwing) when no source provides all
/// three required fields — the caller surfaces a "未配置应用凭证"
/// onboarding state to the user. ADR-0007 § 飞书侧前置条件 lists what
/// still needs to be set up by hand on the open platform.
public struct FeishuAppConfig: Equatable {

    public static let envAppID = "DONEMD_FEISHU_APP_ID"
    public static let envAppSecret = "DONEMD_FEISHU_APP_SECRET"
    public static let envRedirectURI = "DONEMD_FEISHU_REDIRECT_URI"

    public var clientID: String
    public var clientSecret: String
    public var redirectURI: String

    public init(clientID: String, clientSecret: String, redirectURI: String) {
        self.clientID = clientID
        self.clientSecret = clientSecret
        self.redirectURI = redirectURI
    }

    /// Default location of the user-managed plist (the path used by both
    /// the dev workflow and — after v2-10 — the in-app Settings UI).
    public static var defaultPlistURL: URL {
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return appSupport
            .appendingPathComponent("Done.md", isDirectory: true)
            .appendingPathComponent("feishu-config.plist", isDirectory: false)
    }

    /// Resolve from the standard precedence chain. Each source is opt-in
    /// — if any required field is missing or blank the source is treated
    /// as "not configured" and the next source is tried. Returns `nil`
    /// when no source provides a complete triple.
    ///
    /// Parameters allow tests to inject custom keychain / env / plist
    /// URL / bundle. Production callers pass nothing — `keychainStore`
    /// defaults to a real `FeishuKeychainAppConfigStore`.
    public static func load(
        keychainStore: AppConfigStore? = FeishuKeychainAppConfigStore(),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        plistURL: URL = FeishuAppConfig.defaultPlistURL,
        bundle: Bundle = .main
    ) -> FeishuAppConfig? {
        if let store = keychainStore,
           let fromKeychain = (try? store.load()) ?? nil {
            return fromKeychain
        }
        if let fromEnv = loadFromEnvironment(environment) {
            return fromEnv
        }
        if let fromPlist = loadFromPlist(at: plistURL) {
            return fromPlist
        }
        if let fromBundle = loadFromBundle(bundle) {
            return fromBundle
        }
        return nil
    }

    static func loadFromEnvironment(_ env: [String: String]) -> FeishuAppConfig? {
        guard
            let id = env[envAppID]?.trimmed, !id.isEmpty,
            let secret = env[envAppSecret]?.trimmed, !secret.isEmpty,
            let redirect = env[envRedirectURI]?.trimmed, !redirect.isEmpty
        else { return nil }
        return FeishuAppConfig(clientID: id, clientSecret: secret, redirectURI: redirect)
    }

    static func loadFromPlist(at url: URL) -> FeishuAppConfig? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return decodePlist(data)
    }

    static func loadFromBundle(_ bundle: Bundle) -> FeishuAppConfig? {
        guard let url = bundle.url(forResource: "feishu-config", withExtension: "plist") else {
            return nil
        }
        return loadFromPlist(at: url)
    }

    /// Internal shape decoder — public-ish so tests can feed raw plist
    /// data without touching the filesystem. Three required keys; missing
    /// any => `nil`, no partial config.
    static func decodePlist(_ data: Data) -> FeishuAppConfig? {
        guard let raw = try? PropertyListSerialization.propertyList(
            from: data, options: [], format: nil
        ) as? [String: Any] else { return nil }
        guard
            let id = (raw["client_id"] as? String)?.trimmed, !id.isEmpty,
            let secret = (raw["client_secret"] as? String)?.trimmed, !secret.isEmpty,
            let redirect = (raw["redirect_uri"] as? String)?.trimmed, !redirect.isEmpty
        else { return nil }
        return FeishuAppConfig(clientID: id, clientSecret: secret, redirectURI: redirect)
    }
}

private extension String {
    var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
