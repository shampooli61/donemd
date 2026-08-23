import Foundation

/// `URLSession`-backed client for the Google Gemini generative API. The only
/// provider in the `.google` protocol family. Construct with baseURL + apiKey.
///
/// Mirrors `OpenAIClient` / `AnthropicClient` (injectable `session`, pure
/// `parseSSELine` / `throwIfErrorStatus` for unit tests) so the three clients
/// stay parallel.
///
/// Wire differences from the other two families:
///   - Auth is the `x-goog-api-key` header.
///   - Streaming endpoint embeds the model + an `alt=sse` query:
///     `POST /v1beta/models/{model}:streamGenerateContent?alt=sse`.
///   - Request shape is `contents[]` with `parts[].text`; the assistant role is
///     spelled `model`, and the system prompt is a top-level `systemInstruction`.
///   - SSE payload is `candidates[].content.parts[].text`; there's no done
///     sentinel — the stream finishes on natural EOF.
///   - Model list is `GET /v1beta/models` → `{ "models": [ { "name": "models/..." } ] }`;
///     the `models/` prefix is stripped to match the id users pick.
public final class GoogleClient: AIProviderClient {

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
        // Gemini: GET {base}/v1beta/models → { "models": [ { "name": "models/gemini-2.5-flash" } ] }
        let url = baseURL.appendingPathComponent("v1beta/models")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")

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
            // Names come back as "models/gemini-2.5-flash"; strip the prefix so
            // the dropdown shows the bare id the request needs.
            return decoded.models.map { Self.stripModelsPrefix($0.name) }
        } catch {
            throw AIProviderError.decodeFailed("\(error)")
        }
    }

    // MARK: - Streaming

    /// Stream a generation over SSE (`alt=sse`). Gemini's wire format:
    ///
    ///   data: {"candidates":[{"content":{"parts":[{"text":"Hello"}],"role":"model"}}]}
    ///   data: {"candidates":[{"content":{"parts":[{"text":" world"}]}}]}
    ///
    /// Each non-empty text part is yielded as an `AITokenChunk`. There's no
    /// done sentinel — the stream finishes on natural EOF. Throws a typed
    /// `AIProviderError` on transport / status / decode failure. Cancelling the
    /// consuming task tears down the byte stream.
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

    /// Build the POST request for a streaming generation. Maps the AIMessage
    /// list onto Gemini's `contents[]` (assistant → `model` role) and lifts the
    /// system message into the top-level `systemInstruction`.
    func makeStreamRequest(messages: [AIMessage], model: String) -> URLRequest {
        // Endpoint embeds the model id + the SSE flag.
        let url = baseURL
            .appendingPathComponent("v1beta/models/\(model):streamGenerateContent")
            .appending(queryItems: [URLQueryItem(name: "alt", value: "sse")])
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")

        let systemText = messages
            .filter { $0.role == .system }
            .map(\.content)
            .joined(separator: "\n\n")
        let contents = messages
            .filter { $0.role != .system }
            .map { msg in
                [
                    "role": Self.googleRole(for: msg.role),
                    "parts": [["text": msg.content]],
                ] as [String: Any]
            }

        var body: [String: Any] = ["contents": contents]
        if !systemText.isEmpty {
            body["systemInstruction"] = ["parts": [["text": systemText]]]
        }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return request
    }

    /// Gemini spells the assistant role `model`; user stays `user`. System
    /// messages are lifted into `systemInstruction` and never hit this path.
    static func googleRole(for role: AIMessage.Role) -> String {
        switch role {
        case .assistant: return "model"
        case .user, .system: return "user"
        }
    }

    static func stripModelsPrefix(_ name: String) -> String {
        name.hasPrefix("models/") ? String(name.dropFirst("models/".count)) : name
    }

    /// Outcome of parsing one SSE line. Gemini has no done sentinel, so there's
    /// no `.done` case — EOF ends the stream.
    enum SSELineResult: Equatable {
        case token(String)   // a text part to yield
        case ignore          // blank line, non-text payload
    }

    /// Parse a single SSE line into a token / ignore. Pulls every text part out
    /// of `candidates[].content.parts[]` and joins them (a chunk can carry more
    /// than one part).
    static func parseSSELine(_ line: String) -> SSELineResult {
        guard line.hasPrefix("data:") else { return .ignore }
        let payload = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
        if payload.isEmpty { return .ignore }
        guard
            let data = payload.data(using: .utf8),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let candidates = obj["candidates"] as? [[String: Any]],
            let first = candidates.first,
            let content = first["content"] as? [String: Any],
            let parts = content["parts"] as? [[String: Any]]
        else {
            return .ignore
        }
        let text = parts.compactMap { $0["text"] as? String }.joined()
        return text.isEmpty ? .ignore : .token(text)
    }

    private static func collect(_ bytes: URLSession.AsyncBytes) async throws -> Data {
        var data = Data()
        for try await byte in bytes { data.append(byte) }
        return data
    }

    // MARK: - Status mapping

    /// Map an HTTP status to the right `AIProviderError`. Gemini surfaces errors
    /// as `{ "error": { "message": ... } }`.
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
        let models: [Model]
        struct Model: Decodable { let name: String }
    }
}
