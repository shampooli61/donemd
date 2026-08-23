import Foundation

/// M4 — the [[AI 助手]] stream orchestrator (Swift side). Wires the pieces:
/// build prompt (M3) → resolve client (M2) → stream tokens (M1) → forward each
/// chunk to the JS decoration layer (M5) → on completion, parse the accumulated
/// raw markdown through the Phase 1 `MarkdownEngine` and hand the resulting
/// Tiptap node back to JS for the atomic [[直接替换]] commit.
///
/// S2 (#63): happy path + ESC cancel basics + single-in-flight mutex.
/// S3 (#64): full [[失败]] / [[取消]] UX — 60s timeout, retry (same prompt +
/// selection), structured error so the toast can route 401/403 to Settings,
/// and a busy signal so a concurrent request flashes "正在进行中" instead of
/// silently dropping.
///
/// The coordinator is transport-side only — it knows nothing about Tiptap /
/// ProseMirror. It speaks to the editor exclusively through the injected
/// `sink` closures, so it's unit-testable with a fake sink + fake client.
@MainActor
public final class StreamCoordinator {

    /// 60s no-response ceiling (PRD user story / CONTEXT.md [[失败]]). If no
    /// chunk and no terminal event arrives within this window, the stream is
    /// cancelled and surfaced as `.timeout`.
    public static let timeout: TimeInterval = 60

    /// A structured failure the toast layer can act on (PRD user stories
    /// 24-25). `message` is the ready-to-show Chinese copy; the flags tell
    /// the JS toast which buttons to render.
    public struct StreamError: Equatable {
        public let message: String
        /// 401/403 — offer a 「打开 Provider 设置」 button alongside 「重试」.
        public let canOpenSettings: Bool
        public init(message: String, canOpenSettings: Bool) {
            self.message = message
            self.canOpenSettings = canOpenSettings
        }
    }

    /// Where streamed output goes. The real app wires these to bridge sends;
    /// tests inject closures that record calls.
    public struct Sink {
        public var onStart: (_ streamId: String) -> Void
        public var onToken: (_ streamId: String, _ text: String) -> Void
        /// Final commit — carries the parsed Tiptap node JSON (a `doc` whose
        /// `content` replaces the selection).
        public var onComplete: (_ streamId: String, _ nodeJSON: JSONValue) -> Void
        /// Failure — carries the structured error so the toast renders the
        /// right copy + buttons. (Cancellation never calls this — it's silent.)
        public var onError: (_ streamId: String, _ error: StreamError) -> Void
        /// A concurrent request arrived while one was in flight — flash the
        /// existing spinner / "正在进行中" hint (PRD user story 27). No new stream.
        public var onBusy: () -> Void
        /// The 8K guard rebuilt the prompt as selection-only (PRD user story
        /// 60) — surface the「文档过长，已切换为仅选区调用」toast. Fires once,
        /// right after `onStart`, before any token.
        public var onDegrade: (_ streamId: String) -> Void
        /// The command declined to transform (e.g. 转表格 on content that
        /// doesn't suit a table → the model returns 不适合). The selection must
        /// be left **untouched** — surface `message` as a toast, don't replace
        /// (real-machine feedback #2). Distinct from `onComplete`, which always
        /// replaces, and `onError`, which is for failures.
        public var onNotApplicable: (_ streamId: String, _ message: String) -> Void

        public init(
            onStart: @escaping (String) -> Void,
            onToken: @escaping (String, String) -> Void,
            onComplete: @escaping (String, JSONValue) -> Void,
            onError: @escaping (String, StreamError) -> Void,
            onBusy: @escaping () -> Void = {},
            onDegrade: @escaping (String) -> Void = { _ in },
            onNotApplicable: @escaping (String, String) -> Void = { _, _ in }
        ) {
            self.onStart = onStart
            self.onToken = onToken
            self.onComplete = onComplete
            self.onError = onError
            self.onBusy = onBusy
            self.onDegrade = onDegrade
            self.onNotApplicable = onNotApplicable
        }
    }

    /// Everything needed to re-issue an identical call on 「重试」 (PRD 26):
    /// same prompt, same selection, same client + model.
    private struct PendingRequest {
        let command: AICommand
        let context: SelectionContext
        let contextRange: Int
        let client: AIProviderClient
        let model: String
        /// Which provider this call targets — used only to give network
        /// failures a provider-aware message (PRD 64). Optional so tests can
        /// drive the coordinator without a provider identity.
        let provider: AIProvider?
    }

    private let sink: Sink
    private let markdownToNodeJSON: (String) -> JSONValue?
    private let timeoutSeconds: TimeInterval

    private var activeStreamId: String?
    private var activeTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    /// The last request, retained so `retry()` can re-send after a failure.
    private var lastRequest: PendingRequest?

    public init(
        sink: Sink,
        markdownToNodeJSON: @escaping (String) -> JSONValue? = StreamCoordinator.defaultMarkdownToNodeJSON,
        timeoutSeconds: TimeInterval = StreamCoordinator.timeout
    ) {
        self.sink = sink
        self.markdownToNodeJSON = markdownToNodeJSON
        self.timeoutSeconds = timeoutSeconds
    }

    public var isStreaming: Bool { activeStreamId != nil }

    /// Run a command over a selection context. Returns the streamId, or nil if
    /// a stream is already in flight — in which case `onBusy` fires so the UI
    /// can flash the existing spinner (PRD 27).
    @discardableResult
    public func start(
        command: AICommand,
        context: SelectionContext,
        contextRange: Int = 1,
        client: AIProviderClient,
        model: String,
        provider: AIProvider? = nil,
        streamId: String
    ) -> String? {
        guard activeStreamId == nil else {
            sink.onBusy()
            return nil
        }
        let request = PendingRequest(command: command, context: context, contextRange: contextRange, client: client, model: model, provider: provider)
        lastRequest = request
        run(request, streamId: streamId)
        return streamId
    }

    /// Re-issue the last request after a failure (PRD 26) — same prompt + same
    /// selection, no confirmation. No-op if nothing to retry or already busy.
    @discardableResult
    public func retry(streamId: String) -> String? {
        guard activeStreamId == nil else { sink.onBusy(); return nil }
        guard let request = lastRequest else { return nil }
        run(request, streamId: streamId)
        return streamId
    }

    private func run(_ request: PendingRequest, streamId: String) {
        activeStreamId = streamId
        let result = CommandPromptBuilder.build(
            command: request.command,
            context: request.context,
            contextRange: request.contextRange
        )
        let messages = result.messages
        sink.onStart(streamId)
        if result.didDegrade { sink.onDegrade(streamId) }

        // 60s no-response ceiling. Any terminal path (complete / error /
        // cancel) cancels this; if it fires first, it cancels the stream and
        // surfaces a timeout error.
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64((self?.timeoutSeconds ?? 60) * 1_000_000_000))
            guard let self, !Task.isCancelled, self.activeStreamId == streamId else { return }
            self.activeTask?.cancel()
            self.sink.onError(streamId, StreamError(message: "AI 响应超时（60s 无响应）", canOpenSettings: false))
            self.finish(streamId)
        }

        activeTask = Task { [weak self] in
            guard let self else { return }
            var accumulated = ""
            do {
                for try await chunk in request.client.streamCompletion(messages: messages, model: request.model) {
                    if Task.isCancelled { break }
                    accumulated += chunk.text
                    self.sink.onToken(streamId, chunk.text)
                }
                if Task.isCancelled { self.finish(streamId); return }
                // 转表格 may decline (不适合) — never overwrite the selection
                // with the decline text (real-machine feedback #2).
                if let decline = Self.declineMessage(command: request.command, output: accumulated) {
                    self.sink.onNotApplicable(streamId, decline)
                } else if let node = self.markdownToNodeJSON(accumulated) {
                    self.sink.onComplete(streamId, node)
                } else {
                    self.sink.onError(streamId, StreamError(message: "无法解析 AI 输出", canOpenSettings: false))
                }
                self.finish(streamId)
            } catch let error as AIProviderError {
                self.sink.onError(streamId, Self.streamError(for: error, provider: request.provider))
                self.finish(streamId)
            } catch is CancellationError {
                self.finish(streamId)
            } catch {
                self.sink.onError(streamId, StreamError(message: "AI 调用失败：\(error.localizedDescription)", canOpenSettings: false))
                self.finish(streamId)
            }
        }
    }

    /// User cancelled (ESC / any key / clicked outside). Silent — no error
    /// surfaced (PRD 21). The JS side drops its decoration on its own; this
    /// tears down the Swift task + timeout. The provisional state never
    /// entered the document, so there's nothing to undo.
    public func cancel() {
        activeTask?.cancel()
        timeoutTask?.cancel()
        activeTask = nil
        timeoutTask = nil
        activeStreamId = nil
    }

    private func finish(_ streamId: String) {
        guard activeStreamId == streamId else { return }
        activeTask = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        activeStreamId = nil
    }

    // MARK: - Command decline detection

    /// Some commands are allowed to decline rather than transform. 转表格's
    /// prompt explicitly tells the model to reply 「不适合」 when the content
    /// doesn't suit a table; in that case the output carries no table markup
    /// and must not replace the selection. Returns a toast message when the
    /// command declined, or nil to proceed with a normal replace.
    static func declineMessage(command: AICommand, output: String) -> String? {
        guard command == .toTable else { return nil }
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        // A real markdown table always has a pipe-delimited row. If the model
        // produced no `|` at all, it declined (typically a bare 「不适合」).
        if !trimmed.contains("|") {
            return "该内容不适合转换为表格"
        }
        return nil
    }

    // MARK: - Error mapping (S3 full vocabulary)

    /// Map a provider error to a toast-ready structured error. 401/403 set
    /// `canOpenSettings` so the toast adds 「打开 Provider 设置」 (PRD 25).
    ///
    /// `provider` is accepted so network failures can be made provider-aware
    /// when a future provider needs a tailored message (PRD user story 64).
    static func streamError(for error: AIProviderError, provider: AIProvider? = nil) -> StreamError {
        switch error {
        case .unauthorized:
            return StreamError(message: "AI 调用失败：未授权，请检查 Provider 配置", canOpenSettings: true)
        case .forbidden:
            return StreamError(message: "AI 调用失败：无权限访问该模型", canOpenSettings: true)
        case .insufficientBalance:
            return StreamError(message: "AI 调用失败：账户余额不足，请到 Provider 官网充值", canOpenSettings: true)
        case .rateLimited:
            return StreamError(message: "AI 调用失败：请求过于频繁或已用尽额度，请稍后重试", canOpenSettings: false)
        case .badRequest(let status, let m):
            return StreamError(message: "AI 调用失败：请求错误 \(status)\(m.map { "：\($0)" } ?? "")", canOpenSettings: false)
        case .serverError(let status, _):
            return StreamError(message: "AI 调用失败：服务繁忙（\(status)），请稍后重试", canOpenSettings: false)
        case .networkUnreachable:
            return StreamError(message: "AI 调用失败：网络中断", canOpenSettings: false)
        case .decodeFailed:
            return StreamError(message: "AI 调用失败：响应解析失败", canOpenSettings: false)
        case .notImplemented:
            return StreamError(message: "该 Provider 尚未接入流式调用", canOpenSettings: false)
        }
    }

    // MARK: - Default markdown→node bridge

    /// Real app default: parse via MarkdownEngine and round-trip the TiptapNode
    /// to JSONValue (same encode/decode the document loader uses).
    public static func defaultMarkdownToNodeJSON(_ markdown: String) -> JSONValue? {
        let node = MarkdownEngine.parse(markdown: markdown)
        guard
            let data = try? JSONEncoder().encode(node),
            let json = try? JSONDecoder().decode(JSONValue.self, from: data)
        else { return nil }
        return json
    }
}
