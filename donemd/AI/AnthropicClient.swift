import Foundation

/// `URLSession`-backed client for the Anthropic Messages-API protocol family —
/// used by Claude. Construct with baseURL + apiKey.
///
/// Mirrors `OpenAIClient`'s shape (injectable `session`, pure `parseSSELine` /
/// `throwIfErrorStatus` for unit tests) so the three clients stay parallel.
///
/// Wire differences from the OpenAI-compatible family:
///   - Auth header is `x-api-key` (not `Authorization: Bearer`), plus the
///     required `anthropic-version`. When `apiKey` is empty the header is
///     omitted.
///   - `system` is a top-level request field, not a `messages[]` entry, so the
///     builder splits the system message out of the AIMessage list.
///   - `max_tokens` is required by the API.
///   - SSE shape is `content_block_delta` → `delta.text_delta`, terminated by
///     a `message_stop` event (rather than OpenAI's `[DONE]` sentinel).
public final class AnthropicClient: AIProviderClient {

    /// API version pin (Anthropic requires this header on every request).
    static let anthropicVersion = "2023-06-01"
    /// Required by the Messages API; the AI 助手 transforms are short, so a
    /// generous-but-bounded ceiling avoids truncation without inviting runaway
    /// output. Matches the [[流式响应]] "轻量、快速" framing.
    static let maxTokens = 4096

    private let baseURL: URL
    private let apiKey: String
    private let session: URLSession

    public init(baseURL: URL, apiKey: String, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.session = session
    }

    // MARK: - Model list

    public func listModels() async throws -> [String] {
        // Anthropic: GET {base}/v1/models → { "data": [ { "id": ... } ] }
        let url = baseURL.appendingPathComponent("v1/models")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        Self.applyAuthHeaders(to: &request, apiKey: apiKey)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw AIProviderError.networkUnreachable(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw AIProviderError.decodeFailed("non-HTTP response")
        }
        try Self.throwIfErrorStatus(http.statusCode, data: data)

        do {
            let decoded = try JSONDecoder().decode(ModelListResponse.self, from: data)
            return decoded.data.map(\.id)
        } catch {
            throw AIProviderError.decodeFailed("\(error)")
        }
    }

    // MARK: - Streaming

    /// Stream a chat completion over SSE (`text/event-stream`). Claude speaks
    /// the Anthropic Messages streaming wire format:
    ///
    ///   event: content_block_delta
    ///   data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"Hello"}}
    ///   event: message_stop
    ///   data: {"type":"message_stop"}
    ///
    /// Each text delta is yielded as an `AITokenChunk`. The stream finishes on
    /// `message_stop` or natural EOF, and throws a typed `AIProviderError` on
    /// transport / status / decode failure. Cancelling the consuming task tears
    /// down the byte stream (cooperative cancellation) — S3's cancel/timeout UX
    /// layers on top.
    public func streamCompletion(
        messages: [AIMessage],
        model: String
    ) -> AsyncThrowingStream<AITokenChunk, Error> {
        let request = makeStreamRequest(messages: messages, model: model)
        let session = self.session
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, response) = try await session.bytes(for: request)
                    guard let http = response as? HTTPURLResponse else {
                        throw AIProviderError.decodeFailed("non-HTTP response")
                    }
                    // On an error status the body is a normal JSON error, not
                    // an SSE stream — read it and map to a typed error.
                    guard (200...299).contains(http.statusCode) else {
                        let body = try? await Self.collect(bytes)
                        try Self.throwIfErrorStatus(http.statusCode, data: body ?? Data())
                        return
                    }
                    for try await line in bytes.lines {
                        if Task.isCancelled { break }
                        switch Self.parseSSELine(line) {
                        case .token(let text):
                            continuation.yield(AITokenChunk(text: text))
                        case .done:
                            continuation.finish()
                            return
                        case .ignore:
                            continue
                        }
                    }
                    continuation.finish()
                } catch let error as AIProviderError {
                    continuation.finish(throwing: error)
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: AIProviderError.networkUnreachable(error.localizedDescription))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Build the POST request for a streaming Messages call. Splits the system
    /// message out into the top-level `system` field; everything else maps onto
    /// `messages[]` with Anthropic's user/assistant roles.
    func makeStreamRequest(messages: [AIMessage], model: String) -> URLRequest {
        let url = baseURL.appendingPathComponent("v1/messages")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        Self.applyAuthHeaders(to: &request, apiKey: apiKey)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")

        // Anthropic carries the system prompt as a top-level param, not a
        // messages[] entry. Concatenate any system messages (M3 emits one).
        let systemText = messages
            .filter { $0.role == .system }
            .map(\.content)
            .joined(separator: "\n\n")
        let wireMessages = messages
            .filter { $0.role != .system }
            .map { ["role": $0.role.rawValue, "content": $0.content] }

        var body: [String: Any] = [
            "model": model,
            "max_tokens": Self.maxTokens,
            "stream": true,
            "messages": wireMessages,
        ]
        if !systemText.isEmpty {
            body["system"] = systemText
        }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return request
    }

    /// Apply the auth + version headers. An empty key omits the `x-api-key`
    /// header rather than sending an empty one.
    static func applyAuthHeaders(to request: inout URLRequest, apiKey: String) {
        if !apiKey.isEmpty {
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        }
        request.setValue(anthropicVersion, forHTTPHeaderField: "anthropic-version")
    }

    /// Outcome of parsing one SSE line. Pure — unit-tested without network.
    enum SSELineResult: Equatable {
        case token(String)   // a text delta to yield
        case done            // the `message_stop` event
        case ignore          // blank line, event: line, non-text delta, ping
    }

    /// Parse a single SSE line into a token / done / ignore. Handles the
    /// `data:` prefix, the `message_stop` terminal event, and the Anthropic
    /// `content_block_delta` → `text_delta` shape. `event:` lines and other
    /// event types (message_start, content_block_start, ping, …) are ignored;
    /// the `type` inside the JSON payload is what drives the result.
    static func parseSSELine(_ line: String) -> SSELineResult {
        // SSE carries `event:` lines alongside `data:` lines; we key off the
        // JSON `type` in the data payload, so non-data lines are ignored.
        guard line.hasPrefix("data:") else { return .ignore }
        let payload = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
        if payload.isEmpty { return .ignore }
        guard
            let data = payload.data(using: .utf8),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let type = obj["type"] as? String
        else {
            return .ignore
        }
        switch type {
        case "message_stop":
            return .done
        case "content_block_delta":
            guard
                let delta = obj["delta"] as? [String: Any],
                delta["type"] as? String == "text_delta",
                let text = delta["text"] as? String,
                !text.isEmpty
            else {
                return .ignore
            }
            return .token(text)
        default:
            // message_start / content_block_start / content_block_stop /
            // message_delta / ping — nothing to yield.
            return .ignore
        }
    }

    /// Drain an async byte stream into Data — only used to read an error body
    /// when the response status is non-2xx (not on the hot streaming path).
    private static func collect(_ bytes: URLSession.AsyncBytes) async throws -> Data {
        var data = Data()
        for try await byte in bytes { data.append(byte) }
        return data
    }

    // MARK: - Status mapping

    /// Map an HTTP status to the right `AIProviderError`. Anthropic surfaces
    /// errors as `{ "error": { "message": ... } }`, so the shared extractor
    /// (below) handles both wire shapes.
    static func throwIfErrorStatus(_ status: Int, data: Data) throws {
        switch status {
        case 200...299:
            return
        case 401:
            throw AIProviderError.unauthorized
        case 402:
            throw AIProviderError.insufficientBalance
        case 403:
            throw AIProviderError.forbidden(message: Self.errorMessage(from: data))
        case 429:
            throw AIProviderError.rateLimited
        case 400...499:
            throw AIProviderError.badRequest(httpStatus: status, message: Self.errorMessage(from: data))
        default:
            throw AIProviderError.serverError(httpStatus: status, message: Self.errorMessage(from: data))
        }
    }

    /// Best-effort extraction of `{ "error": { "message": ... } }` (Anthropic's
    /// error shape) so the failure toast can show something specific.
    private static func errorMessage(from data: Data) -> String? {
        guard
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let error = obj["error"] as? [String: Any],
            let message = error["message"] as? String
        else { return nil }
        return message
    }

    // MARK: - Wire types

    private struct ModelListResponse: Decodable {
        let data: [Model]
        struct Model: Decodable { let id: String }
    }
}
