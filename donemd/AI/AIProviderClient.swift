import Foundation

/// One streamed chunk of model output. Phase 3 only carries text deltas;
/// the struct exists (rather than a bare `String`) so finish-reason / usage
/// metadata can be added later without breaking the `streamCompletion`
/// signature.
public struct AITokenChunk: Equatable {
    public let text: String
    public init(text: String) { self.text = text }
}

/// A single chat message in the provider-agnostic shape M3 builds and M4
/// hands to the client. The client maps it onto each protocol family's wire
/// format (OpenAI `messages[]`, Anthropic `messages[]` + system, Google
/// `contents[]`).
public struct AIMessage: Equatable {
    public enum Role: String, Equatable { case system, user, assistant }
    public let role: Role
    public let content: String
    public init(role: Role, content: String) {
        self.role = role
        self.content = content
    }
}

/// Domain errors every provider HTTP failure lands in — kept tight (no
/// `genericFailure`) so each new path must decide retry policy + user copy,
/// the same discipline `FeishuAPIError` enforces. The UI maps these to the
/// [[失败]] toast copy in later slices.
public enum AIProviderError: Error, Equatable {
    /// 401 — API key missing / invalid. UI routes to Settings § AI Provider.
    case unauthorized
    /// 403 — key valid but lacks access (e.g. model not enabled for account).
    case forbidden(message: String?)
    /// 402 — account out of balance. DeepSeek / OpenAI-compatible return this
    /// when the key is valid but the account has no credit. Distinct from 401
    /// (bad key) — the fix is "top up", not "re-enter key".
    case insufficientBalance
    /// 429 — rate limited.
    case rateLimited
    /// 4xx other than 401/403/429.
    case badRequest(httpStatus: Int, message: String?)
    /// 5xx.
    case serverError(httpStatus: Int, message: String?)
    /// `URLSession` threw — DNS / TLS / no-network (user story 64).
    case networkUnreachable(String)
    /// Response body didn't match the expected shape.
    case decodeFailed(String)
    /// Functionality not wired in this slice (streaming lands in S2).
    case notImplemented(String)
}

/// The single interface M4 (StreamCoordinator) talks to, regardless of
/// provider. Three concrete clients implement it (`OpenAIClient` /
/// `AnthropicClient` / `GoogleClient`); six providers map onto the three.
///
/// `listModels` is the only method S1 exercises end-to-end — it backs the
/// [[Model 列表]] fetch on key-save. `streamCompletion` is defined here so
/// the abstraction is complete, but S1 ships only a stub; S2 wires the real
/// SSE stream.
public protocol AIProviderClient: AnyObject {
    /// Fetch the provider's available model ids. Backs the "filled key +
    /// save → 拉真列表" chain (Model 列表 rule 3). Throws `AIProviderError`
    /// on failure so the registry can degrade to the fallback model.
    func listModels() async throws -> [String]

    /// Stream a chat completion. Defined for the full abstraction; S1 ships
    /// a stub that throws `.notImplemented`. S2 replaces it with real SSE.
    func streamCompletion(
        messages: [AIMessage],
        model: String
    ) -> AsyncThrowingStream<AITokenChunk, Error>
}
