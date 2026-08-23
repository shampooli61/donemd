import Foundation

/// The five user-facing [[Provider]] brands Done.md ships in Phase 3.
///
/// User mental model = five brand entries; the *internal* protocol surface
/// is only three client classes (see `AIProtocolFamily`). This enum is the
/// stable identity layer everything else keys off — Keychain service names,
/// UserDefaults keys, Settings cards, and the AI status badge label all
/// resolve from a `AIProvider` case.
///
/// Ordering matches the onboarding-friendliness order the Settings panel
/// renders cards in (DeepSeek first / recommended).
public enum AIProvider: String, CaseIterable, Codable, Equatable {
    case deepseek
    case gemini
    case openai
    case claude
    case mimo

    /// The three internal protocol families. Five providers collapse onto
    /// three HTTP client implementations — the deep-module abstraction that
    /// lets adding a new OpenAI-compatible provider be a one-line enum
    /// addition rather than a new client.
    public enum ProtocolFamily: Equatable {
        case openAICompatible   // DeepSeek / OpenAI / MiMo
        case anthropic          // Claude
        case google             // Gemini
    }

    public var family: ProtocolFamily {
        switch self {
        case .deepseek, .openai, .mimo: return .openAICompatible
        case .claude: return .anthropic
        case .gemini: return .google
        }
    }

    /// Brand label shown in Settings cards and the AI status badge
    /// ("AI: DeepSeek"). Not localized — these are proper nouns.
    public var displayName: String {
        switch self {
        case .deepseek: return "DeepSeek"
        case .gemini: return "Gemini"
        case .openai: return "OpenAI"
        case .claude: return "Claude"
        case .mimo: return "MiMo"
        }
    }

    /// Official default endpoint. Advanced users override this per-provider
    /// (Settings → 高级折叠区) to reach Azure / 国内代理 / 自建网关; the
    /// override lives in UserDefaults, this is just the fallback baseline.
    ///
    /// OpenAI-compatible families carry the full base; the client appends
    /// the path (`/chat/completions`, `/models`). Anthropic/Google likewise.
    public var defaultEndpoint: String {
        switch self {
        case .deepseek: return "https://api.deepseek.com"
        case .gemini:   return "https://generativelanguage.googleapis.com"
        case .openai:   return "https://api.openai.com"
        case .claude:   return "https://api.anthropic.com"
        // api. (not platform., which serves the portal SPA) — GET /v1/models
        // there returns 401 like the other OpenAI-compatible APIs.
        case .mimo:     return "https://api.xiaomimimo.com"
        }
    }

    /// Hard-coded fallback [[默认模型]]. Used when the user hasn't picked a
    /// model and the runtime `/v1/models` fetch hasn't succeeded (or failed).
    ///
    /// Selection rule (PRD § 默认 Model 表): speed tier > capability tier;
    /// current shipping stable (no deprecated / preview); free / low-cost.
    ///
    /// Three are marked TBD in the PRD and must be re-verified against the
    /// provider's pricing page at ship time (tracked in #72). The values
    /// here are the best current guess so the app is functional pre-ship.
    public var fallbackModel: String {
        switch self {
        case .deepseek: return "deepseek-v4-flash"      // verified 2026-07-01 (api-docs.deepseek.com/pricing); legacy deepseek-chat alias deprecates 2026-07-24
        case .gemini:   return "gemini-2.5-flash"        // 确定
        case .openai:   return "gpt-4o-mini"             // TBD: verify at ship (platform.openai.com)
        case .claude:   return "claude-haiku-4-5"        // 确定
        case .mimo:     return "MiMo-V2.5-Pro"           // the officially-recommended text model; MiMo has no separate speed tier, so the speed>capability rule yields the recommended model
        }
    }

    /// Whether the provider needs an API key. All providers do — each one
    /// authenticates requests with a key the user supplies (see PRD story
    /// 40/62/63).
    public var requiresAPIKey: Bool {
        true
    }

    /// `true` for the default-recommended provider — Settings tags its card
    /// "推荐" and onboarding highlights it.
    public var isRecommendedDefault: Bool {
        self == .deepseek
    }

    /// Keychain service name for this provider's API key, bundle-id-scoped
    /// the same way the Feishu stores are.
    public func keychainService(bundleID: String) -> String {
        "\(bundleID).\(rawValue)"
    }
}
