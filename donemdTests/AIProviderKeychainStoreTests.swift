import XCTest
@testable import donemd

/// Phase 3 Slice 1 (#62) — coverage for the per-provider API key store.
///
/// Each test runs against a unique bundle-id namespace (UUID-suffixed) so
/// concurrent runs and the user's real Done.md install can't collide.
/// Teardown clears every provider's entry even on assertion failure.
///
/// Acceptance criteria (issue #62):
///   - save+load roundtrip per provider, isolated by service name
///   - load() on an unset provider returns nil rather than throwing
///   - clear() removes one provider's key, leaves others intact
final class AIProviderKeychainStoreTests: XCTestCase {

    private var bundleID: String = ""
    private var store: AIProviderKeychainStore!

    override func setUp() {
        super.setUp()
        bundleID = "com.shampoo.donemd.tests.\(UUID().uuidString)"
        store = AIProviderKeychainStore(bundleID: bundleID, account: "default")
        addTeardownBlock { [bundleID] in
            for provider in AIProvider.allCases where provider.requiresAPIKey {
                let query: [String: Any] = [
                    kSecClass as String: kSecClassGenericPassword,
                    kSecAttrService as String: provider.keychainService(bundleID: bundleID),
                ]
                SecItemDelete(query as CFDictionary)
            }
        }
    }

    // MARK: - happy path

    func testSaveLoadRoundtrip() throws {
        try store.saveKey("sk-deepseek-123", for: .deepseek)
        XCTAssertEqual(try store.loadKey(for: .deepseek), "sk-deepseek-123")
    }

    func testLoadOnUnsetProviderReturnsNil() throws {
        XCTAssertNil(try store.loadKey(for: .openai))
    }

    func testSaveOverwritesPreviousKey() throws {
        try store.saveKey("old", for: .deepseek)
        try store.saveKey("new", for: .deepseek)
        XCTAssertEqual(try store.loadKey(for: .deepseek), "new")
    }

    // MARK: - per-provider isolation

    func testProvidersAreIsolated() throws {
        try store.saveKey("key-deepseek", for: .deepseek)
        try store.saveKey("key-openai", for: .openai)
        XCTAssertEqual(try store.loadKey(for: .deepseek), "key-deepseek")
        XCTAssertEqual(try store.loadKey(for: .openai), "key-openai")
        XCTAssertNil(try store.loadKey(for: .claude))
    }

    func testClearRemovesOnlyOneProvider() throws {
        try store.saveKey("key-deepseek", for: .deepseek)
        try store.saveKey("key-openai", for: .openai)
        try store.clearKey(for: .deepseek)
        XCTAssertNil(try store.loadKey(for: .deepseek))
        XCTAssertEqual(try store.loadKey(for: .openai), "key-openai")
    }

    func testClearOnEmptyDoesNotThrow() {
        XCTAssertNoThrow(try store.clearKey(for: .gemini))
    }
}
