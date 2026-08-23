import XCTest
@testable import donemd

/// Phase 3 Slice 1 (#62) — M2 ProviderRegistry.
///
/// Runs against an in-memory key store + an isolated UserDefaults suite, and
/// an injected client factory returning canned model lists / errors — no
/// Keychain, no network. Acceptance criteria (issue #62):
///   - default provider switch persists
///   - fallback model table surfaces when nothing fetched
///   - model-list fetch failure degrades to fallback (never throws)
///   - model-list fetch success caches + pins selection
///   - endpoint override persists / clears
final class ProviderRegistryTests: XCTestCase {

    private var keyStore: InMemoryAIProviderKeyStore!
    private var defaults: UserDefaults!
    private var suiteName: String = ""

    override func setUp() {
        super.setUp()
        keyStore = InMemoryAIProviderKeyStore()
        suiteName = "ai.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        addTeardownBlock { [suiteName] in
            UserDefaults().removePersistentDomain(forName: suiteName)
        }
    }

    /// Build a registry whose client returns a fixed listModels outcome.
    private func makeRegistry(
        listModels: @escaping () async throws -> [String] = { ["x"] }
    ) -> ProviderRegistry {
        ProviderRegistry(
            keyStore: keyStore,
            defaults: defaults,
            clientFactory: { _, _, _ in StubClient(listModelsResult: listModels) }
        )
    }

    // MARK: - default provider

    func testDefaultProviderIsRecommendedWhenUnset() {
        let registry = makeRegistry()
        XCTAssertEqual(registry.defaultProvider, .deepseek)
    }

    func testDefaultProviderSwitchPersists() {
        let registry = makeRegistry()
        registry.defaultProvider = .claude
        XCTAssertEqual(registry.defaultProvider, .claude)
        // A fresh registry over the same defaults sees the persisted value.
        let reborn = makeRegistry()
        XCTAssertEqual(reborn.defaultProvider, .claude)
    }

    // MARK: - selected model / fallback table

    func testSelectedModelFallsBackWhenUnset() {
        let registry = makeRegistry()
        XCTAssertEqual(registry.selectedModel(for: .deepseek), AIProvider.deepseek.fallbackModel)
    }

    func testSelectedModelPersists() {
        let registry = makeRegistry()
        registry.setSelectedModel("deepseek-reasoner", for: .deepseek)
        XCTAssertEqual(registry.selectedModel(for: .deepseek), "deepseek-reasoner")
    }

    // MARK: - endpoint override

    func testEndpointDefaultsToOfficial() {
        let registry = makeRegistry()
        XCTAssertEqual(registry.endpoint(for: .deepseek).absoluteString, AIProvider.deepseek.defaultEndpoint)
    }

    func testEndpointOverridePersists() {
        let registry = makeRegistry()
        registry.setEndpointOverride("https://proxy.example.com", for: .deepseek)
        XCTAssertEqual(registry.endpoint(for: .deepseek).absoluteString, "https://proxy.example.com")
    }

    func testEmptyEndpointOverrideRevertsToDefault() {
        let registry = makeRegistry()
        registry.setEndpointOverride("https://proxy.example.com", for: .deepseek)
        registry.setEndpointOverride("   ", for: .deepseek)
        XCTAssertEqual(registry.endpoint(for: .deepseek).absoluteString, AIProvider.deepseek.defaultEndpoint)
    }

    // MARK: - isConfigured / hasAnyConfiguredProvider

    func testIsConfiguredRequiresKey() throws {
        let registry = makeRegistry()
        XCTAssertFalse(registry.isConfigured(.deepseek))
        try registry.saveAPIKey("sk-x", for: .deepseek)
        XCTAssertTrue(registry.isConfigured(.deepseek))
    }

    func testHasAnyConfiguredProviderFalseOnFreshInstall() throws {
        // A fresh install has nothing configured — so the onboarding sheet
        // fires as intended.
        let registry = makeRegistry()
        XCTAssertFalse(registry.hasAnyConfiguredProvider)
    }

    // MARK: - presence mirror (launch-time Keychain-read avoidance)

    func testSaveSetsConfiguredMirrorFlag() throws {
        let registry = makeRegistry()
        try registry.saveAPIKey("sk-x", for: .deepseek)
        // The non-secret mirror is written, so a fresh registry reports
        // configured WITHOUT the key store being consulted.
        let spy = SpyKeyStore(seed: [:])  // empty: if consulted, would say false
        let reborn = ProviderRegistry(keyStore: spy, defaults: defaults,
                                      clientFactory: { _, _, _ in StubClient(listModelsResult: { [] }) })
        XCTAssertTrue(reborn.isConfigured(.deepseek))
        XCTAssertEqual(spy.loadCount, 0, "seeded mirror must answer without a key read")
    }

    func testClearResetsConfiguredMirrorFlag() throws {
        let registry = makeRegistry()
        try registry.saveAPIKey("sk-x", for: .deepseek)
        try registry.clearAPIKey(for: .deepseek)
        let spy = SpyKeyStore(seed: [:])
        let reborn = ProviderRegistry(keyStore: spy, defaults: defaults,
                                      clientFactory: { _, _, _ in StubClient(listModelsResult: { [] }) })
        XCTAssertFalse(reborn.isConfigured(.deepseek))
        XCTAssertEqual(spy.loadCount, 0, "cleared mirror must answer without a key read")
    }

    func testIsConfiguredLazilySeedsMirrorFromExistingKey() throws {
        // A key present in the store but with no mirror flag (upgrade from
        // before the mirror existed): the first isConfigured reads once to
        // seed, then never again.
        let spy = SpyKeyStore(seed: [.deepseek: "sk-legacy"])
        let registry = ProviderRegistry(keyStore: spy, defaults: defaults,
                                        clientFactory: { _, _, _ in StubClient(listModelsResult: { [] }) })
        XCTAssertTrue(registry.isConfigured(.deepseek))
        XCTAssertEqual(spy.loadCount, 1, "first read seeds the mirror")
        XCTAssertTrue(registry.isConfigured(.deepseek))
        XCTAssertEqual(spy.loadCount, 1, "subsequent reads use the mirror, no further key read")
    }

    // MARK: - model list fetch (rule 3)

    func testRefreshModelListSuccessCachesAndPins() async throws {
        try keyStore.saveKey("sk-x", for: .deepseek)
        // Live list contains the fallback model → selection pins to it.
        let registry = makeRegistry(listModels: { ["deepseek-chat", "deepseek-reasoner"] })
        let result = await registry.refreshModelList(for: .deepseek)
        XCTAssertEqual(result, .fetched(["deepseek-chat", "deepseek-reasoner"]))
        XCTAssertEqual(registry.cachedModelList(for: .deepseek), ["deepseek-chat", "deepseek-reasoner"])
        XCTAssertEqual(registry.selectedModel(for: .deepseek), "deepseek-chat")
    }

    func testRefreshModelListPinsFirstWhenFallbackAbsent() async throws {
        try keyStore.saveKey("sk-x", for: .deepseek)
        let registry = makeRegistry(listModels: { ["model-a", "model-b"] })
        _ = await registry.refreshModelList(for: .deepseek)
        XCTAssertEqual(registry.selectedModel(for: .deepseek), "model-a")
    }

    func testRefreshModelListDegradesOnError() async throws {
        try keyStore.saveKey("sk-x", for: .deepseek)
        let registry = makeRegistry(listModels: { throw AIProviderError.unauthorized })
        let result = await registry.refreshModelList(for: .deepseek)
        XCTAssertEqual(result, .degraded(fallback: AIProvider.deepseek.fallbackModel, error: .unauthorized))
        XCTAssertTrue(registry.cachedModelList(for: .deepseek).isEmpty, "failed fetch must not cache")
    }

    func testRefreshModelListDegradesWithoutKey() async {
        // No key saved for a key-requiring provider → degrade immediately,
        // don't even build a client / hit the network.
        let registry = makeRegistry(listModels: { XCTFail("should not fetch without key"); return [] })
        let result = await registry.refreshModelList(for: .openai)
        XCTAssertEqual(result, .degraded(fallback: AIProvider.openai.fallbackModel, error: .unauthorized))
    }

    func testRefreshModelListDegradesOnEmptyList() async throws {
        try keyStore.saveKey("sk-x", for: .deepseek)
        let registry = makeRegistry(listModels: { [] })
        let result = await registry.refreshModelList(for: .deepseek)
        guard case .degraded = result else {
            return XCTFail("empty list should degrade, got \(result)")
        }
    }
}

/// Canned `AIProviderClient` for registry tests — returns a fixed listModels
/// outcome, never touches the network.
private final class StubClient: AIProviderClient {
    private let listModelsResult: () async throws -> [String]
    init(listModelsResult: @escaping () async throws -> [String]) {
        self.listModelsResult = listModelsResult
    }
    func listModels() async throws -> [String] {
        try await listModelsResult()
    }
    func streamCompletion(messages: [AIMessage], model: String) -> AsyncThrowingStream<AITokenChunk, Error> {
        AsyncThrowingStream { $0.finish(throwing: AIProviderError.notImplemented("stub")) }
    }
}

/// `AIProviderKeyStore` that counts `loadKey` calls, so tests can assert the
/// registry answers `isConfigured` from the UserDefaults mirror without
/// touching the store (the whole point of the launch-time fix).
private final class SpyKeyStore: AIProviderKeyStore {
    private var keys: [AIProvider: String]
    private(set) var loadCount = 0
    init(seed: [AIProvider: String]) { self.keys = seed }
    func saveKey(_ key: String, for provider: AIProvider) throws { keys[provider] = key }
    func loadKey(for provider: AIProvider) throws -> String? {
        loadCount += 1
        return keys[provider]
    }
    func clearKey(for provider: AIProvider) throws { keys[provider] = nil }
}
