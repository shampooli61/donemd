import Foundation

/// `URLSession`-backed client for the OpenAI-compatible protocol family —
/// shared by DeepSeek / OpenAI / MiMo. Construct with baseURL +
/// apiKey; the three providers differ only in those two values.
///
/// Every external dependency (`session`) is injectable so unit tests can
/// simulate `/v1/models` success, 401, 5xx, and network outages without
/// real I/O — the same testability discipline as `FeishuHTTPAPIClient`.
///
/// S1 scope: `listModels` is real (backs the Model 列表 fetch chain);
/// `streamCompletion` is a stub that throws `.notImplemented`. S2 (#63)
/// replaces the stub with real SSE.
public final class OpenAIClient: AIProviderClient {

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
        // OpenAI-compatible: GET {base}/v1/models → { "data": [ { "id": ... } ] }
        let url = baseURL.appendingPathComponent("v1/models")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

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

    // MARK: - Streaming (S2 #63)

    /// Stream a chat completion over SSE (`text/event-stream`). DeepSeek /
    /// OpenAI / MiMo all speak the OpenAI streaming wire format:
    ///
    ///   data: {"choices":[{"delta":{"content":"Hello"}}]}
    ///   data: {"choices":[{"delta":{"content":" world"}}]}
    ///   data: [DONE]
    ///
    /// Each non-empty content delta is yielded as an `AITokenChunk`. The
    /// stream finishes on `[DONE]` or natural EOF, and throws a typed
    /// `AIProviderError` on transport / status / decode failure. Cancelling
    /// the consuming task tears down the URLSession byte stream (cooperative
    /// cancellation) — S3 layers explicit cancel/timeout UX on top.
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

    /// Build the POST request for a streaming chat completion.
    func makeStreamRequest(messages: [AIMessage], model: String) -> URLRequest {
        let url = baseURL.appendingPathComponent("v1/chat/completions")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        let body: [String: Any] = [
            "model": model,
            "stream": true,
            "messages": messages.map { ["role": $0.role.rawValue, "content": $0.content] },
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return request
    }

    /// Outcome of parsing one SSE line. Pure — unit-tested without network.
    enum SSELineResult: Equatable {
        case token(String)   // a content delta to yield
        case done            // the `[DONE]` sentinel
        case ignore          // blank line, comment, non-content event, empty delta
    }

    /// Parse a single SSE line into a token / done / ignore. Handles the
    /// `data:` prefix, the `[DONE]` sentinel, and the OpenAI delta shape.
    static func parseSSELine(_ line: String) -> SSELineResult {
        let trimmed = line.hasPrefix("data:") ? String(line.dropFirst(5)) : line
        let payload = trimmed.trimmingCharacters(in: .whitespaces)
        if payload.isEmpty { return .ignore }
        if payload == "[DONE]" { return .done }
        guard
            let data = payload.data(using: .utf8),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let choices = obj["choices"] as? [[String: Any]],
            let first = choices.first,
            let delta = first["delta"] as? [String: Any],
            let content = delta["content"] as? String,
            !content.isEmpty
        else {
            return .ignore
        }
        return .token(content)
    }

    /// Drain an async byte stream into Data — only used to read an error body
    /// when the response status is non-2xx (not on the hot streaming path).
    private static func collect(_ bytes: URLSession.AsyncBytes) async throws -> Data {
        var data = Data()
        for try await byte in bytes { data.append(byte) }
        return data
    }

    // MARK: - Status mapping

    /// Map an HTTP status to the right `AIProviderError`. Shared shape with
    /// the Anthropic/Google clients when they arrive (S7).
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

    /// Best-effort extraction of `{ "error": { "message": ... } }` so the
    /// failure toast can show something specific. Nil if the body isn't that shape.
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
