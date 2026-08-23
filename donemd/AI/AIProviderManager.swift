import SwiftUI
import Combine

/// Process-wide UI-facing half of M2. Wraps the pure `ProviderRegistry`
/// (persistence/coordination core) and republishes the bits SwiftUI needs:
/// the [[AI 状态徽标]] state and per-provider Settings card state.
///
/// Lives as long as the app (mirrors `AppDelegate.feishuSyncManager`) so the
/// badge — shown in every document window — and the Settings panel share one
/// source of truth. `@MainActor` because it drives SwiftUI.
@MainActor
public final class AIProviderManager: ObservableObject {

    /// What the [[AI 状态徽标]] shows (PRD user stories 48 / 52 / 53).
    public enum BadgeState: Equatable {
        case unconfigured                 // "AI: 未配置" — no provider has a key
        case configured(providerName: String)  // "AI: DeepSeek"
        case inFlight                     // "AI: 调用中…" — a call is streaming (S2+)
    }

    @Published public private(set) var badgeState: BadgeState = .unconfigured
    /// Bumped on any config change so SwiftUI Settings rows re-read the
    /// registry (which isn't itself observable — it's the pure core).
    @Published public private(set) var configRevision: Int = 0

    public let registry: ProviderRegistry

    public init(registry: ProviderRegistry) {
        self.registry = registry
        recomputeBadge()
    }

    /// Convenience for the real app: Keychain-backed store + standard defaults.
    public static func makeDefault() -> AIProviderManager {
        AIProviderManager(
            registry: ProviderRegistry(
                keyStore: AIProviderKeychainStore(),
                defaults: UserDefaults.standard
            )
        )
    }

    // MARK: - Badge

    /// Whether any provider with a key is configured — gates the onboarding
    /// sheet. On a fresh install the badge says 未配置 until a key-bearing
    /// provider is set; this method only counts those.
    public var hasKeyBearingProvider: Bool {
        AIProvider.allCases.contains { $0.requiresAPIKey && registry.isConfigured($0) }
    }

    private func recomputeBadge() {
        // Badge names the default provider when it's usable; otherwise the
        // first configured key-bearing provider.
        let def = registry.defaultProvider
        if def.requiresAPIKey && registry.isConfigured(def) {
            badgeState = .configured(providerName: def.displayName)
        } else if let first = AIProvider.allCases.first(where: { $0.requiresAPIKey && registry.isConfigured($0) }) {
            badgeState = .configured(providerName: first.displayName)
        } else {
            badgeState = .unconfigured
        }
    }

    /// Call after any save/clear/default-switch so badge + Settings refresh.
    public func configDidChange() {
        recomputeBadge()
        configRevision += 1
    }

    /// Flip the badge to / from "AI: 调用中…" while a stream is in flight
    /// (PRD user story 53). Restores the configured-provider label when done.
    public func setInFlight(_ inFlight: Bool) {
        if inFlight {
            badgeState = .inFlight
        } else {
            recomputeBadge()
        }
    }

    // MARK: - Settings actions (thin pass-throughs that bump revision)

    public func setDefaultProvider(_ provider: AIProvider) {
        registry.defaultProvider = provider
        configDidChange()
    }

    /// The S1 "测试连接 + 保存" 4-step chain (PRD user story 41):
    /// save key → fetch model list → auto-pick default model → (test ping).
    /// Returns the model-list outcome so the card can show the 小灰提示 on
    /// degrade. Test-ping is folded into the list fetch for S1 (a successful
    /// `/v1/models` is the connectivity proof); a dedicated chat ping lands
    /// when streaming exists (S2).
    public func saveKeyAndRefresh(
        _ key: String,
        for provider: AIProvider
    ) async -> ProviderRegistry.ModelListResult {
        // All providers store an API key. The guard stays defensive in case
        // a future keyless provider appears.
        if provider.requiresAPIKey {
            do {
                try registry.saveAPIKey(key, for: provider)
            } catch {
                configDidChange()
                return .degraded(fallback: provider.fallbackModel, error: .unauthorized)
            }
        }
        let result = await registry.refreshModelList(for: provider)
        // First key configured → make this the default provider so the badge
        // and AI calls route somewhere usable without an extra step.
        if registry.defaultProvider == provider || !hasKeyBearingProviderExcluding(provider) {
            registry.defaultProvider = provider
        }
        configDidChange()
        return result
    }

    private func hasKeyBearingProviderExcluding(_ provider: AIProvider) -> Bool {
        AIProvider.allCases.contains { $0 != provider && $0.requiresAPIKey && registry.isConfigured($0) }
    }

    public func clearKey(for provider: AIProvider) {
        try? registry.clearAPIKey(for: provider)
        configDidChange()
    }

    public func refreshModelList(for provider: AIProvider) async -> ProviderRegistry.ModelListResult {
        let result = await registry.refreshModelList(for: provider)
        configDidChange()
        return result
    }
}
