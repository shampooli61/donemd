import Foundation

/// Abstraction over the UserDefaults the registry reads/writes, so tests run
/// against an isolated suite instead of `.standard`. `UserDefaults` already
/// satisfies this shape.
public protocol KeyValueStore: AnyObject {
    func string(forKey key: String) -> String?
    func set(_ value: Any?, forKey key: String)
    func array(forKey key: String) -> [Any]?
    func object(forKey key: String) -> Any?
    func removeObject(forKey key: String)
}

extension UserDefaults: KeyValueStore {}

/// M2 — the [[Provider]] registration table + persistence layer.
///
/// Owns four concerns (PRD § M2):
///   1. the six-provider table + fallback [[默认模型]] (delegated to `AIProvider`)
///   2. API key read/write via an injected `AIProviderKeyStore` (Keychain)
///   3. user config (default provider / per-provider model id / endpoint
///      override / cached model lists) via an injected `KeyValueStore`
///   4. runtime [[Model 列表]] fetch with fallback-on-failure
///
/// Deliberately *not* `@MainActor` and *not* an `ObservableObject` — it's the
/// pure persistence/coordination core so it's trivially unit-testable.
/// `AIProviderManager` (M2's UI-facing half) wraps it for SwiftUI.
public final class ProviderRegistry {

    // MARK: UserDefaults keys (PRD § Schema 变更)

    private enum Keys {
        static let defaultProvider = "ai.defaultProvider"
        static let contextRange = "ai.contextRange"
        static func modelId(_ p: AIProvider) -> String { "ai.providers.\(p.rawValue).modelId" }
        static func endpoint(_ p: AIProvider) -> String { "ai.providers.\(p.rawValue).endpoint" }
        static func modelList(_ p: AIProvider) -> String { "ai.modelLists.\(p.rawValue)" }
        /// Non-secret presence mirror: `true` once a key has been stored for
        /// this provider. Lets `isConfigured` answer without a Keychain read
        /// (and its access prompt) at launch. Never holds the key itself —
        /// the "no plaintext key on disk" invariant stands.
        static func configured(_ p: AIProvider) -> String { "ai.providers.\(p.rawValue).configured" }
    }

    private let keyStore: AIProviderKeyStore
    private let defaults: KeyValueStore
    /// Builds a client for a provider given its resolved endpoint + key.
    /// Injected so tests substitute a fake returning canned model lists /
    /// errors without real HTTP.
    private let clientFactory: (AIProvider, URL, String?) -> AIProviderClient

    public init(
        keyStore: AIProviderKeyStore,
        defaults: KeyValueStore,
        clientFactory: @escaping (AIProvider, URL, String?) -> AIProviderClient = ProviderRegistry.defaultClientFactory
    ) {
        self.keyStore = keyStore
        self.defaults = defaults
        self.clientFactory = clientFactory
    }

    // MARK: - Default provider

    /// The provider every [[AI 助手]] call routes to. Defaults to the
    /// recommended provider (DeepSeek) until the user picks one.
    public var defaultProvider: AIProvider {
        get {
            guard
                let raw = defaults.string(forKey: Keys.defaultProvider),
                let provider = AIProvider(rawValue: raw)
            else {
                return AIProvider.allCases.first(where: \.isRecommendedDefault) ?? .deepseek
            }
            return provider
        }
        set { defaults.set(newValue.rawValue, forKey: Keys.defaultProvider) }
    }

    // MARK: - Context range

    /// How many paragraphs before/after the selection travel with a
    /// `.surroundingParagraphs` command ([[Context 窗口]], PRD § Settings 可调).
    /// 0 / 1 (default) / 2 / 3. Out-of-range values clamp to [0, 3].
    public var contextRange: Int {
        get {
            // `object(forKey:)` distinguishes "unset" (→ default 1) from a
            // stored 0 (which `integer(forKey:)` can't).
            guard let stored = defaults.object(forKey: Keys.contextRange) as? Int else { return 1 }
            return min(3, max(0, stored))
        }
        set { defaults.set(min(3, max(0, newValue)), forKey: Keys.contextRange) }
    }

    // MARK: - API key

    public func apiKey(for provider: AIProvider) throws -> String? {
        try keyStore.loadKey(for: provider)
    }

    public func saveAPIKey(_ key: String, for provider: AIProvider) throws {
        try keyStore.saveKey(key, for: provider)
        // Update the non-secret presence mirror so `isConfigured` (and thus the
        // badge / Settings dots / onboarding gate) can render at launch without
        // a Keychain read. Only ever a boolean — the key stays in Keychain.
        defaults.set(true, forKey: Keys.configured(provider))
    }

    public func clearAPIKey(for provider: AIProvider) throws {
        try keyStore.clearKey(for: provider)
        defaults.set(false, forKey: Keys.configured(provider))
    }

    /// `true` once the provider is usable: it needs a stored key.
    ///
    /// Reads the non-secret UserDefaults presence mirror rather than the
    /// Keychain, so a launch-time sweep of every provider costs zero Keychain
    /// access prompts. On first run after this mirror was introduced the flag
    /// is absent for a provider whose key predates it — we then fall back to a
    /// single lazy Keychain read and seed the flag, so the prompt happens at
    /// most once per provider, ever (and folds into the Part A re-entry).
    public func isConfigured(_ provider: AIProvider) -> Bool {
        guard provider.requiresAPIKey else { return true }
        if let flag = defaults.object(forKey: Keys.configured(provider)) as? Bool {
            return flag
        }
        // Unseeded: read once, seed the mirror, then trust it forever after.
        let present = (try? keyStore.loadKey(for: provider))?.isEmpty == false
        defaults.set(present, forKey: Keys.configured(provider))
        return present
    }

    /// Whether *any* provider is configured — drives the [[AI 状态徽标]]
    /// "未配置" vs "已配置" split and the onboarding-sheet gate.
    public var hasAnyConfiguredProvider: Bool {
        AIProvider.allCases.contains(where: isConfigured)
    }

    // MARK: - Endpoint override

    /// Resolved endpoint: the user's override if set + non-empty, else the
    /// provider's official default.
    public func endpoint(for provider: AIProvider) -> URL {
        if
            let override = defaults.string(forKey: Keys.endpoint(provider))?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            !override.isEmpty,
            let url = URL(string: override)
        {
            return url
        }
        return URL(string: provider.defaultEndpoint)!
    }

    /// Persist an endpoint override. Passing nil / empty clears it (reverts
    /// to the official default).
    public func setEndpointOverride(_ endpoint: String?, for provider: AIProvider) {
        let trimmed = endpoint?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmed, !trimmed.isEmpty {
            defaults.set(trimmed, forKey: Keys.endpoint(provider))
        } else {
            defaults.removeObject(forKey: Keys.endpoint(provider))
        }
    }

    // MARK: - Selected model

    /// The model id for a provider: the user's saved choice if present, else
    /// the hard-coded fallback [[默认模型]].
    public func selectedModel(for provider: AIProvider) -> String {
        if
            let saved = defaults.string(forKey: Keys.modelId(provider))?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            !saved.isEmpty
        {
            return saved
        }
        return provider.fallbackModel
    }

    public func setSelectedModel(_ model: String, for provider: AIProvider) {
        defaults.set(model, forKey: Keys.modelId(provider))
    }

    // MARK: - Cached model list

    /// Last successfully-fetched model list for a provider's dropdown.
    /// Empty until a fetch succeeds.
    public func cachedModelList(for provider: AIProvider) -> [String] {
        (defaults.array(forKey: Keys.modelList(provider)) as? [String]) ?? []
    }

    private func cacheModelList(_ models: [String], for provider: AIProvider) {
        defaults.set(models, forKey: Keys.modelList(provider))
    }

    // MARK: - Model list fetch (Model 列表 rule 3)

    /// Outcome of a runtime model-list fetch, so the UI can distinguish
    /// "got the real list" from "degraded to fallback" for the 小灰提示.
    public enum ModelListResult: Equatable {
        /// Live `/v1/models` succeeded; `models` is the real list (default
        /// selection pinned to the fallback model if present, else first).
        case fetched([String])
        /// Fetch failed; degraded to the single fallback model. Carries the
        /// error so the UI can show "无法拉模型列表，使用默认 model".
        case degraded(fallback: String, error: AIProviderError)
    }

    /// The "filled key + 点保存 → 拉真列表" chain (Model 列表 rule 3):
    /// build a client, GET the model list, cache + return on success;
    /// degrade to the fallback model on any failure — never throws, because
    /// a failed fetch must not block the user from saving their config.
    ///
    /// Also pins the selected model: on success, to the fallback if the live
    /// list contains it (else the first listed); on failure, to the fallback.
    public func refreshModelList(for provider: AIProvider) async -> ModelListResult {
        let key = try? keyStore.loadKey(for: provider)
        // A provider with no key can't fetch — degrade immediately.
        if provider.requiresAPIKey, (key?.isEmpty ?? true) {
            return .degraded(fallback: provider.fallbackModel, error: .unauthorized)
        }
        let client = clientFactory(provider, endpoint(for: provider), key)
        do {
            let models = try await client.listModels()
            guard !models.isEmpty else {
                return .degraded(fallback: provider.fallbackModel, error: .decodeFailed("empty model list"))
            }
            cacheModelList(models, for: provider)
            let pick = models.contains(provider.fallbackModel) ? provider.fallbackModel : models[0]
            setSelectedModel(pick, for: provider)
            return .fetched(models)
        } catch let error as AIProviderError {
            return .degraded(fallback: provider.fallbackModel, error: error)
        } catch {
            return .degraded(fallback: provider.fallbackModel, error: .networkUnreachable(error.localizedDescription))
        }
    }

    // MARK: - Client construction

    /// Build a ready-to-use client for the provider's current config (resolved
    /// endpoint + stored key). Used by M4 (S2+) to make calls.
    public func client(for provider: AIProvider) -> AIProviderClient {
        let key = try? keyStore.loadKey(for: provider)
        return clientFactory(provider, endpoint(for: provider), key)
    }

    /// Default factory: maps a provider's protocol family to a concrete client.
    /// All three families are wired as of S7 (#68): OpenAI-compatible
    /// (DeepSeek / OpenAI / MiMo), Anthropic (Claude), Google (Gemini).
    public static func defaultClientFactory(
        _ provider: AIProvider,
        _ endpoint: URL,
        _ key: String?
    ) -> AIProviderClient {
        switch provider.family {
        case .openAICompatible:
            return OpenAIClient(baseURL: endpoint, apiKey: key ?? "")
        case .anthropic:
            return AnthropicClient(baseURL: endpoint, apiKey: key ?? "")
        case .google:
            return GoogleClient(baseURL: endpoint, apiKey: key ?? "")
        }
    }
}
