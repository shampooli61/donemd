import Foundation
import Security

/// Keychain-backed persistence for the static `FeishuAppConfig`
/// (client_id / client_secret / redirect_uri) — the *application* OAuth
/// credentials, distinct from per-user `FeishuCredentials` (access /
/// refresh token) which `KeychainCredentialStore` owns.
///
/// Why a separate store class with its own service name:
///   - the two payloads have different semantics (app-wide vs.
///     per-user), different rotation cadences (rotate App Secret in
///     Feishu console → app config refresh; user logout → user
///     credentials wipe), and different UI surfaces. Reusing one store
///     blurs that.
///   - the two share the same kSecClassGenericPassword backend; only
///     the `kSecAttrService` value differs, so the storage cost is
///     identical to a second account on one service but cleaner.
///
/// Resolution chain (`FeishuAppConfig.load`) treats this store as the
/// highest-priority source — anything saved through Settings UI wins
/// over env / plist / bundle. The fallback chain still works, so users
/// running with the env-var workflow don't have to re-enter anything.
public protocol AppConfigStore: AnyObject {
    func save(_ config: FeishuAppConfig) throws
    func load() throws -> FeishuAppConfig?
    func clear() throws
}

public final class FeishuKeychainAppConfigStore: AppConfigStore {

    public enum StoreError: Error, Equatable {
        case keychainStatus(OSStatus)
        case decodeFailed(String)
    }

    public static var defaultService: String {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.shampoo.donemd"
        return "\(bundleID).feishu-app-config"
    }

    private let service: String
    private let account: String

    public init(
        service: String = FeishuKeychainAppConfigStore.defaultService,
        account: String = "default"
    ) {
        self.service = service
        self.account = account
    }

    public func save(_ config: FeishuAppConfig) throws {
        let payload: [String: String] = [
            "client_id": config.clientID,
            "client_secret": config.clientSecret,
            "redirect_uri": config.redirectURI,
        ]
        let data = try JSONEncoder().encode(payload)
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(baseQuery as CFDictionary)
        var addQuery = baseQuery
        addQuery[kSecValueData as String] = data
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw StoreError.keychainStatus(status)
        }
    }

    public func load() throws -> FeishuAppConfig? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw StoreError.keychainStatus(status)
        }
        guard let data = item as? Data else {
            throw StoreError.decodeFailed("expected Data payload")
        }
        do {
            let payload = try JSONDecoder().decode([String: String].self, from: data)
            guard
                let id = payload["client_id"]?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty,
                let secret = payload["client_secret"]?.trimmingCharacters(in: .whitespacesAndNewlines), !secret.isEmpty,
                let redirect = payload["redirect_uri"]?.trimmingCharacters(in: .whitespacesAndNewlines), !redirect.isEmpty
            else { return nil }
            return FeishuAppConfig(clientID: id, clientSecret: secret, redirectURI: redirect)
        } catch {
            throw StoreError.decodeFailed("\(error)")
        }
    }

    public func clear() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw StoreError.keychainStatus(status)
        }
    }
}
