import XCTest
@testable import donemd

/// v2-2A coverage for the credential persistence layer feeding
/// `FeishuOAuthClient` (issue #41).
///
/// Each test runs against a unique Keychain `service` name (UUID-suffixed)
/// so concurrent test runs and the user's real Done.md install can't collide.
/// `tearDown` clears the entry — failure inside a test still triggers cleanup
/// because `addTeardownBlock` runs even on assertion failure.
///
/// Acceptance criteria from the issue:
///   - save+load roundtrip preserves every field (including optional `tenantKey`)
///   - load() on an empty service returns nil rather than throwing
///   - clear() removes the entry; subsequent load() returns nil
///   - clear() on an already-empty service does NOT throw
///   - save() overwrites a previous entry (no duplicate-item error)
///   - load() on corrupted entry data throws (caller must clear() to recover)
final class KeychainCredentialStoreTests: XCTestCase {

    private var service: String = ""
    private var store: KeychainCredentialStore!

    override func setUp() {
        super.setUp()
        // Unique per test, so parallel xctest runs and the user's real
        // Done.md install share zero state.
        service = "com.shampoo.donemd.tests.\(UUID().uuidString)"
        store = KeychainCredentialStore(service: service, account: "default")
        addTeardownBlock { [service] in
            // Direct delete — bypasses the store API so a buggy clear()
            // doesn't leak entries into the user's keychain.
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
            ]
            SecItemDelete(query as CFDictionary)
        }
    }

    // MARK: - happy path

    func testSaveLoadRoundtripPreservesAllFields() throws {
        let now = Date()
        let original = FeishuCredentials(
            accessToken: "u-aaa.bbb.ccc",
            refreshToken: "ur-xxx.yyy.zzz",
            expiresAt: now.addingTimeInterval(7200),
            tenantKey: "t-123abc"
        )
        try store.save(original)
        let loaded = try store.load()
        XCTAssertEqual(loaded?.accessToken, original.accessToken)
        XCTAssertEqual(loaded?.refreshToken, original.refreshToken)
        XCTAssertEqual(loaded?.tenantKey, original.tenantKey)
        // Date round-trip via JSONEncoder default (Double seconds since
        // reference date) — sub-second precision survives but millisecond
        // jitter is fine, so compare by interval rather than ==.
        XCTAssertEqual(
            loaded?.expiresAt.timeIntervalSinceReferenceDate ?? 0,
            original.expiresAt.timeIntervalSinceReferenceDate,
            accuracy: 0.001
        )
    }

    func testSaveLoadRoundtripWithNilTenantKey() throws {
        let creds = FeishuCredentials(
            accessToken: "a",
            refreshToken: "r",
            expiresAt: Date().addingTimeInterval(3600),
            tenantKey: nil
        )
        try store.save(creds)
        let loaded = try store.load()
        XCTAssertNotNil(loaded)
        XCTAssertNil(loaded?.tenantKey)
    }

    // MARK: - empty / not-authorized state

    func testLoadOnEmptyServiceReturnsNil() throws {
        // Acceptance: 未授权状态下 load() 返回 nil（不抛）
        let loaded = try store.load()
        XCTAssertNil(loaded)
    }

    // MARK: - clear

    func testClearRemovesEntry() throws {
        let creds = FeishuCredentials(
            accessToken: "a", refreshToken: "r",
            expiresAt: Date().addingTimeInterval(3600), tenantKey: nil
        )
        try store.save(creds)
        XCTAssertNotNil(try store.load())
        try store.clear()
        XCTAssertNil(try store.load())
    }

    func testClearOnEmptyServiceDoesNotThrow() {
        // errSecItemNotFound from SecItemDelete must NOT propagate — clear()
        // is idempotent so logout flows can call it without first checking.
        XCTAssertNoThrow(try store.clear())
    }

    // MARK: - overwrite

    func testSaveOverwritesPreviousEntry() throws {
        let first = FeishuCredentials(
            accessToken: "old-token",
            refreshToken: "old-refresh",
            expiresAt: Date().addingTimeInterval(60),
            tenantKey: "t-old"
        )
        let second = FeishuCredentials(
            accessToken: "new-token",
            refreshToken: "new-refresh",
            expiresAt: Date().addingTimeInterval(7200),
            tenantKey: "t-new"
        )
        try store.save(first)
        try store.save(second)
        let loaded = try store.load()
        XCTAssertEqual(loaded?.accessToken, "new-token")
        XCTAssertEqual(loaded?.refreshToken, "new-refresh")
        XCTAssertEqual(loaded?.tenantKey, "t-new")
    }

    // MARK: - corrupt entry

    func testLoadOnCorruptEntryThrowsDecodeFailed() throws {
        // Plant raw garbage at the same (service, account) coords the store
        // looks at; load() must surface a typed error rather than silently
        // returning nil — silent nil would mask a schema-migration bug.
        let garbage = "not valid json".data(using: .utf8)!
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "default",
            kSecValueData as String: garbage,
        ]
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        XCTAssertEqual(status, errSecSuccess, "test setup failed to plant entry")

        XCTAssertThrowsError(try store.load()) { error in
            guard case KeychainCredentialStore.StoreError.decodeFailed = error else {
                return XCTFail("expected .decodeFailed, got \(error)")
            }
        }

        // After surfacing the error, a clear() must still recover.
        XCTAssertNoThrow(try store.clear())
        XCTAssertNil(try store.load())
    }

    // MARK: - service / account isolation

    func testTwoStoresWithDifferentServicesAreIsolated() throws {
        let otherService = "com.shampoo.donemd.tests.\(UUID().uuidString)"
        let other = KeychainCredentialStore(service: otherService, account: "default")
        defer {
            let q: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: otherService,
            ]
            SecItemDelete(q as CFDictionary)
        }

        let creds = FeishuCredentials(
            accessToken: "a", refreshToken: "r",
            expiresAt: Date().addingTimeInterval(3600), tenantKey: nil
        )
        try store.save(creds)
        XCTAssertNil(try other.load(), "the second service should not see the first's entry")
    }

    // MARK: - Credentials.isExpired

    func testIsExpiredFutureToken() {
        let creds = FeishuCredentials(
            accessToken: "x", refreshToken: "y",
            expiresAt: Date().addingTimeInterval(3600), tenantKey: nil
        )
        XCTAssertFalse(creds.isExpired())
    }

    func testIsExpiredPastToken() {
        let creds = FeishuCredentials(
            accessToken: "x", refreshToken: "y",
            expiresAt: Date().addingTimeInterval(-10), tenantKey: nil
        )
        XCTAssertTrue(creds.isExpired())
    }

    func testIsExpiredWithinSkewWindow() {
        // 30s left, default 60s skew → considered expired (proactive refresh).
        let creds = FeishuCredentials(
            accessToken: "x", refreshToken: "y",
            expiresAt: Date().addingTimeInterval(30), tenantKey: nil
        )
        XCTAssertTrue(creds.isExpired(), "skew should mark almost-expired tokens as expired")
    }
}
