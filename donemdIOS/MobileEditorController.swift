import Foundation
import Combine

struct MobileEditorHeading: Codable, Equatable, Identifiable {
    var id: Int
    var title: String
    var level: Int
    var collapsed: Bool
}

/// Missing fields from older web bundles deliberately decode to safe defaults.
struct MobileEditorState: Codable, Equatable {
    var identity: String = ""
    var revision: Int = 0
    var ready: Bool = false
    var editable: Bool = false
    var locked: Bool = false
    var composing: Bool = false
    var focused: Bool = false
    var canUndo: Bool = false
    var canRedo: Bool = false
    var block: String = ""
    var marks: [String] = []
    var mixedMarks: [String] = []
    var nodeType: String = ""
    var attributes: [String: String] = [:]
    var selectionToken: String? = nil
    var headings: [MobileEditorHeading] = []
    var searchQuery: String = ""
    var searchCount: Int = 0
    var searchCurrent: Int = 0
    var searchActive: Bool = false
    var theme: String = "system"
    var fontSize: Int = 17
    var characters: Int = 0
    var sourceBytes: Int = 0
    init() {}
    private enum CodingKeys: String, CodingKey {
        case identity, revision, ready, editable, locked, composing, focused, canUndo, canRedo, block, marks, mixedMarks, nodeType, attributes, selectionToken, headings, searchQuery, searchCount, searchCurrent, searchActive, theme, fontSize, characters, sourceBytes
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        identity = try values.decodeIfPresent(String.self, forKey: .identity) ?? ""
        revision = try values.decodeIfPresent(Int.self, forKey: .revision) ?? 0
        ready = try values.decodeIfPresent(Bool.self, forKey: .ready) ?? false
        editable = try values.decodeIfPresent(Bool.self, forKey: .editable) ?? false
        locked = try values.decodeIfPresent(Bool.self, forKey: .locked) ?? false
        composing = try values.decodeIfPresent(Bool.self, forKey: .composing) ?? false
        focused = try values.decodeIfPresent(Bool.self, forKey: .focused) ?? false
        canUndo = try values.decodeIfPresent(Bool.self, forKey: .canUndo) ?? false
        canRedo = try values.decodeIfPresent(Bool.self, forKey: .canRedo) ?? false
        block = try values.decodeIfPresent(String.self, forKey: .block) ?? ""
        marks = try values.decodeIfPresent([String].self, forKey: .marks) ?? []
        mixedMarks = try values.decodeIfPresent([String].self, forKey: .mixedMarks) ?? []
        nodeType = try values.decodeIfPresent(String.self, forKey: .nodeType) ?? ""
        attributes = try values.decodeIfPresent([String: String].self, forKey: .attributes) ?? [:]
        selectionToken = try values.decodeIfPresent(String.self, forKey: .selectionToken)
        headings = try values.decodeIfPresent([MobileEditorHeading].self, forKey: .headings) ?? []
        searchQuery = try values.decodeIfPresent(String.self, forKey: .searchQuery) ?? ""
        searchCount = try values.decodeIfPresent(Int.self, forKey: .searchCount) ?? 0
        searchCurrent = try values.decodeIfPresent(Int.self, forKey: .searchCurrent) ?? 0
        searchActive = try values.decodeIfPresent(Bool.self, forKey: .searchActive) ?? false
        theme = try values.decodeIfPresent(String.self, forKey: .theme) ?? "system"
        fontSize = try values.decodeIfPresent(Int.self, forKey: .fontSize) ?? 17
        characters = try values.decodeIfPresent(Int.self, forKey: .characters) ?? 0
        sourceBytes = try values.decodeIfPresent(Int.self, forKey: .sourceBytes) ?? 0
    }
}

struct MobileEditorResult: Codable, Equatable {
    var requestId: String = ""
    var success: Bool = false
    var message: String? = nil
    var selectionToken: String? = nil
    var data: [String: String]? = nil
    var state: MobileEditorState? = nil
}

struct MobileEditorCommand: Codable, Equatable {
    let requestId: String
    let identity: String
    let revision: Int
    let name: String
    let args: [String: String]
    let selectionToken: String?
}

/// One in-flight command, advanced only by the matching ACK. WK evaluation is not an ACK.
@MainActor
final class MobileEditorController: ObservableObject {
    @Published private(set) var state = MobileEditorState()
    @Published private(set) var busy = false
    @Published var error: String?

    /// A typed transport seam: production encodes the fixed editorCommand envelope.
    typealias Transport = (MobileEditorCommand) -> Void
    var usesCommandTransport: Bool { transport != nil }
    private var suspended = false
    private var transport: Transport?
    private var currentSource: (() async -> String?)?
    private var identity = ""
    private var revision = -1
    private var generation = UUID()
    private let timeoutNanoseconds: UInt64
    private struct Pending {
        let command: MobileEditorCommand
        let continuation: CheckedContinuation<MobileEditorResult, Never>
    }
    private var queue: [Pending] = []
    private var active: Pending?
    private var timeoutTask: Task<Void, Never>?
    private var sourceTask: Task<Void, Never>?

    // Construction only initializes inert value storage. UIDocument itself is not
    // main-actor isolated; all transport/publication operations remain MainActor.
    nonisolated init(timeoutNanoseconds: UInt64 = 8_000_000_000) {
        self.timeoutNanoseconds = timeoutNanoseconds
    }

    func installTransport(_ transport: @escaping Transport, currentSource: @escaping () async -> String?) {
        disconnect()
        suspended = false
        self.transport = transport
        self.currentSource = currentSource
    }

    /// Call before JS receives a new identity/body, not after its first state message.
    func prepare(identity: String, revision: Int) {
        guard self.identity != identity || self.revision != revision else { return }
        cancelAll("文档版本已变化，请重新选择操作位置")
        generation = UUID()
        suspended = false
        self.identity = identity
        self.revision = revision
        state = MobileEditorState()
        state.identity = identity
        state.revision = revision
    }

    func disconnect() {
        transport = nil
        currentSource = nil
        generation = UUID()
        cancelAll("编辑器已断开，请稍后重试")
        state.ready = false
        state.focused = false
    }

    @discardableResult
    func receive(state next: MobileEditorState) -> Bool {
        guard !suspended, next.identity == identity, next.revision == revision else { return false }
        if state != next { state = next }
        return true
    }

    @discardableResult
    func receive(result: MobileEditorResult) -> Bool {
        guard let pending = active, pending.command.requestId == result.requestId else { return false }
        guard pending.command.identity == identity, pending.command.revision == revision else {
            complete(.init(requestId: result.requestId, message: "文档版本已变化"))
            return false
        }
        if let next = result.state {
            guard next.identity == identity, next.revision == revision else {
                complete(.init(requestId: result.requestId, message: "编辑器返回了过期文档状态"))
                return false
            }
            receive(state: next)
        }
        complete(result)
        return true
    }

    func perform(_ name: String, args: [String: String] = [:], selectionToken: String? = nil) async -> MobileEditorResult {
        let id = UUID().uuidString
        return await withTaskCancellationHandler {
            guard !Task.isCancelled else { return .init(requestId: id, message: "操作已取消") }
            return await withCheckedContinuation { continuation in
                let command = MobileEditorCommand(requestId: id, identity: identity, revision: revision,
                                                  name: name, args: args, selectionToken: selectionToken)
                queue.append(Pending(command: command, continuation: continuation))
                busy = true
                advance()
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel(requestId: id) }
        }
    }

    func captureSelection() async -> String? {
        let result = await perform("selection.capture")
        return result.success ? result.selectionToken : nil
    }

    private func advance() {
        guard active == nil else { return }
        guard !queue.isEmpty else { busy = false; return }
        active = queue.removeFirst()
        guard let command = active?.command else { return }
        guard !suspended, transport != nil, command.identity == identity, command.revision == revision,
              command.name == "native.activate" || state.ready else {
            complete(.init(requestId: command.requestId, message: "编辑器尚未就绪或文档版本已变化"))
            return
        }
        let requestId = command.requestId
        timeoutTask = Task { [weak self] in
            guard let self else { return }
            do { try await Task.sleep(nanoseconds: self.timeoutNanoseconds) } catch { return }
            guard self.active?.command.requestId == requestId else { return }
            // A timed-out command may still execute in JS. Fail closed instead of dispatching
            // dependent mutations before the unknown operation has actually acknowledged.
            self.suspended = true
            self.cancelAll("编辑器操作超时，请重新打开文档后重试")
            self.state.ready = false
        }
        if command.name == "source.get" {
            let epoch = generation
            sourceTask = Task { [weak self] in
                guard let self else { return }
                let source = await self.currentSource?()
                guard !Task.isCancelled, self.generation == epoch,
                      self.active?.command.requestId == requestId else { return }
                guard let source else {
                    self.complete(.init(requestId: requestId, message: "无法获取当前正文，请完成输入后重试"))
                    return
                }
                self.complete(.init(requestId: requestId, success: true, data: ["source": source]))
            }
        } else {
            transport?(command)
        }
    }

    private func complete(_ result: MobileEditorResult) {
        guard let pending = active else { return }
        timeoutTask?.cancel(); timeoutTask = nil
        sourceTask?.cancel(); sourceTask = nil
        active = nil
        if !result.success { error = result.message ?? "操作未完成，请重试" }
        pending.continuation.resume(returning: result)
        advance()
    }

    private func cancel(requestId: String) {
        if active?.command.requestId == requestId {
            // Cancellation cannot undo a command already submitted to WebKit.
            suspended = true
            cancelAll("操作已取消，请重新打开文档后重试")
            state.ready = false
        } else if let index = queue.firstIndex(where: { $0.command.requestId == requestId }) {
            let pending = queue.remove(at: index)
            pending.continuation.resume(returning: .init(requestId: requestId, message: "操作已取消"))
            busy = active != nil || !queue.isEmpty
        }
    }

    private func cancelAll(_ message: String) {
        timeoutTask?.cancel(); timeoutTask = nil
        sourceTask?.cancel(); sourceTask = nil
        let pending = (active.map { [$0] } ?? []) + queue
        active = nil
        queue.removeAll()
        busy = false
        for item in pending {
            item.continuation.resume(returning: .init(requestId: item.command.requestId, message: message))
        }
        if !pending.isEmpty { error = message }
    }
}
