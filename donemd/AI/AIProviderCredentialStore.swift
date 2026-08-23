import Foundation
import Security

/// Persistence contract for [[Provider]] API keys. Splitting the protocol
/// from the concrete Keychain store lets `ProviderRegistry` be unit-tested
/// with an in-memory fake while the real app gets system Keychain durability
/// — the same split the Feishu subsystem uses (`CredentialStore`).
///
/// One entry per `AIProvider`. The key is a bearer credential, so it lives
/// in the Keychain (encrypted at rest, login-session unlocked, namespaced
/// by bundle id), never in UserDefaults / plist — the Phase 3 security
/// invariant: no plaintext key on disk.
public protocol AIProviderKeyStore: AnyObject {
    func saveKey(_ key: String, for provider: AIProvider) throws
    func loadKey(for provider: AIProvider) throws -> String?
    func clearKey(for provider: AIProvider) throws
}

/// macOS Keychain-backed `AIProviderKeyStore`. Each provider gets its own
/// service name (`<bundleID>.<provider>`, e.g. `com.shampoo.donemd.deepseek`)
/// so keys never collide and clearing one provider leaves the others intact.
public final class AIProviderKeychainStore: AIProviderKeyStore {

    public enum StoreError: Error, Equatable {
        case keychainStatus(OSStatus)
        case decodeFailed(String)
        /// Caller tried to store a key for a provider that takes none.
        case providerTakesNoKey(AIProvider)
    }

    private let bundleID: String
    private let account: String

    /// - Parameters:
    ///   - bundleID: namespace for the service names. Tests pass a unique
    ///     value (UUID-suffixed) to isolate from the user's real entries.
    ///   - account: fixed `"default"` today; the parameter exists for
    ///     forward-compat (e.g. multiple keys per provider).
    public init(
        bundleID: String = Bundle.main.bundleIdentifier ?? "com.shampoo.donemd",
        account: String = "default"
    ) {
        self.bundleID = bundleID
        self.account = account
    }

    public func saveKey(_ key: String, for provider: AIProvider) throws {
        guard provider.requiresAPIKey else {
            throw StoreError.providerTakesNoKey(provider)
        }
        let data = Data(key.utf8)
        let baseQuery = self.baseQuery(for: provider)
        // Delete-then-add — same single-writer atomicity the Feishu stores use.
        SecItemDelete(baseQuery as CFDictionary)
        var addQuery = baseQuery
        addQuery[kSecValueData as String] = data
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw StoreError.keychainStatus(status)
        }
    }

    public func loadKey(for provider: AIProvider) throws -> String? {
        guard provider.requiresAPIKey else { return nil }
        var query = baseQuery(for: provider)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw StoreError.keychainStatus(status)
        }
        guard let data = item as? Data else {
            throw StoreError.decodeFailed("expected Data payload")
        }
        guard let key = String(data: data, encoding: .utf8) else {
            throw StoreError.decodeFailed("key data is not valid UTF-8")
        }
        return key
    }

    public func clearKey(for provider: AIProvider) throws {
        let status = SecItemDelete(baseQuery(for: provider) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw StoreError.keychainStatus(status)
        }
    }

    private func baseQuery(for provider: AIProvider) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: provider.keychainService(bundleID: bundleID),
            kSecAttrAccount as String: account,
        ]
    }
}

/// In-memory `AIProviderKeyStore` for unit tests — no Keychain I/O, so
/// `ProviderRegistry` tests run fast and leave no system state behind.
public final class InMemoryAIProviderKeyStore: AIProviderKeyStore {
    private var keys: [AIProvider: String] = [:]
    private let lock = NSLock()

    public init() {}

    public func saveKey(_ key: String, for provider: AIProvider) throws {
        guard provider.requiresAPIKey else {
            throw AIProviderKeychainStore.StoreError.providerTakesNoKey(provider)
        }
        lock.lock(); defer { lock.unlock() }
        keys[provider] = key
    }

    public func loadKey(for provider: AIProvider) throws -> String? {
        guard provider.requiresAPIKey else { return nil }
        lock.lock(); defer { lock.unlock() }
        return keys[provider]
    }

    public func clearKey(for provider: AIProvider) throws {
        lock.lock(); defer { lock.unlock() }
        keys[provider] = nil
    }
}
