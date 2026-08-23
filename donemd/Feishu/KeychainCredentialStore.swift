import Foundation
import Security

/// Persistence contract `FeishuOAuthClient` uses to hold tokens between
/// launches. Splitting the protocol from the concrete `KeychainCredentialStore`
/// lets the OAuth client be unit-tested with an in-memory fake while the real
/// app gets system keychain durability.
public protocol CredentialStore: AnyObject {
    func save(_ credentials: FeishuCredentials) throws
    func load() throws -> FeishuCredentials?
    func clear() throws
}

/// macOS Keychain-backed store for `FeishuCredentials` — single entry per
/// (service, account) pair, stored as a `kSecClassGenericPassword` item.
///
/// Why Keychain over plain UserDefaults / Application Support file:
///   - access tokens are bearer credentials; Keychain encrypts at rest
///     and unlocks with the user's login session
///   - other apps signed by other developers can't read the entry (the
///     `kSecAttrService` key is namespaced by bundle id by default)
///
/// Tests substitute a unique `service` name to avoid polluting the real
/// account; `InMemoryCredentialStore` (test target) handles the rest.
public final class KeychainCredentialStore: CredentialStore {

    public enum StoreError: Error, Equatable {
        /// Underlying `SecItemAdd` / `SecItemCopyMatching` / `SecItemDelete`
        /// failed with a non-success, non-`errSecItemNotFound` status. The
        /// raw OSStatus is included so callers can map to user-readable
        /// messages (Apple's `SecCopyErrorMessageString` is the best path).
        case keychainStatus(OSStatus)
        /// Entry exists in Keychain but its data didn't decode as
        /// `FeishuCredentials` — almost always means the schema changed.
        /// Caller should `clear()` and re-login.
        case decodeFailed(String)
    }

    /// Bundle-id-scoped default service name. Two installs of Done.md (e.g.
    /// release vs. dev build with a different bundle id) get separate
    /// entries; an unsigned dev build uses the bundle id from Info.plist.
    public static var defaultService: String {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.shampoo.donemd"
        return "\(bundleID).feishu-oauth"
    }

    private let service: String
    private let account: String

    /// - Parameters:
    ///   - service: Keychain service name. Tests pass a unique value to
    ///     isolate from the user's real entry.
    ///   - account: User-facing account label. Done.md only stores one
    ///     credential bundle per app install today, so a fixed `"default"`
    ///     is sufficient; the parameter exists for forward-compat (e.g.
    ///     multiple Feishu tenants on one machine).
    public init(
        service: String = KeychainCredentialStore.defaultService,
        account: String = "default"
    ) {
        self.service = service
        self.account = account
    }

    public func save(_ credentials: FeishuCredentials) throws {
        let data = try JSONEncoder().encode(credentials)
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        // Delete-then-add is simpler than SecItemUpdate's split add/update
        // codepaths and atomic enough for our single-writer use case.
        SecItemDelete(baseQuery as CFDictionary)
        var addQuery = baseQuery
        addQuery[kSecValueData as String] = data
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw StoreError.keychainStatus(status)
        }
    }

    public func load() throws -> FeishuCredentials? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw StoreError.keychainStatus(status)
        }
        guard let data = item as? Data else {
            throw StoreError.decodeFailed("expected Data payload")
        }
        do {
            return try JSONDecoder().decode(FeishuCredentials.self, from: data)
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
