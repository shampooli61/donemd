import UIKit
import Combine
import UniformTypeIdentifiers

/// Keeps the original bytes until an actual edit, including metadata unknown to this client.
final class MobileDocument: UIDocument, ObservableObject {
    let editor = MobileEditorController()
    @Published private(set) var source = ""
    @Published private(set) var revision = 0
    @Published var message: String?
    @Published private(set) var needsNormalization = false
    @Published var outgoing: (id: UUID, type: String, payload: [String: String])?
    @Published var previewURL: URL?
    @Published var importing = false
    @Published var isReadOnly = false
    var composing = false
    var flushEditor: (() async -> Bool)?
    /// A Web-acknowledged transaction lock with a final body snapshot, held until finish ACK.
    var beginEditorProtection: (() async -> Bool)?
    var finishEditorProtection: (() async -> Bool)?
    /// Narrow seam for exercising the suspended UIDocument revert window in tests.
    var reloadProtectedDocument: (() async -> Bool)?
    /// Narrow failure-injection seam; production reads the existing recovery store unchanged.
    var loadRecoveryVersions: (() throws -> [DocumentRecoveryStore.Version])?
    private var saving = false
    private var writtenSnapshot: String?
    func applyEditorSnapshot(_ body: TiptapNode, revision: Int) -> Bool {
        guard revision == self.revision else { return false }
        replaceBody(body)
        return true
    }
    /// A current model snapshot for the read-only source panel; never invokes saveNow.
    /// A flush that first discovers a real edit retains the ordinary debounced autosave.
    /// An unchanged source-only read cannot schedule one because replaceBody is a no-op.
    @MainActor
    func currentEditorSource() async -> String? {
        let intendedRevision = revision
        guard !composing, !saving, let flushEditor else { return nil }
        guard await flushEditor(), !composing, revision == intendedRevision else { return nil }
        return source
    }

    @MainActor
    func importMedia(_ url: URL, removeTemporary: Bool = false, selectionToken: String? = nil, expectedType: String? = nil) async {
        guard !importing, !isReadOnly else { return }
        let intendedRevision = revision
        let intendedIdentity = fileURL.path
        let granted = url.startAccessingSecurityScopedResource()
        importing = true
        defer {
            importing = false
            if granted { url.stopAccessingSecurityScopedResource() }
            if removeTemporary { try? FileManager.default.removeItem(at: url) }
        }
        do {
            let type = UTType(filenameExtension: url.pathExtension)
            guard let type, type.conforms(to: .image) || type.conforms(to: .movie) else { throw CocoaError(.fileReadUnsupportedScheme) }
            let kind = type.conforms(to: .movie) ? "video" : "image"
            if let expectedType, expectedType != kind {
                message = "附件类型不匹配，请选择与原引用相同类型的图片或视频；正文未更改，也未写入新附件。"
                return
            }
            // Reject replacement-kind mismatches before capturing a selection or touching assets.
            var insertionToken = selectionToken
            if editor.usesCommandTransport, insertionToken == nil {
                insertionToken = await editor.captureSelection()
                guard insertionToken != nil else { message = "无法保留附件插入位置，请重新选择。"; return }
            }
            let manager = assets
            let imported = try await Task.detached {
                try manager.importFile(at: url, mimeType: type.preferredMIMEType ?? "application/octet-stream")
            }.value
            try Task.checkCancellation()
            guard revision == intendedRevision, fileURL.path == intendedIdentity, !isReadOnly else { message = "文档已收到新版本或已只读，附件已保留，请重新选择插入位置。"; return }
            if editor.usesCommandTransport || insertionToken != nil {
                let result = await editor.perform(type.conforms(to: .movie) ? "insert.video" : "insert.image",
                                                  args: ["src": imported.assetURL.absoluteString], selectionToken: insertionToken)
                message = result.success ? "附件已插入正文" : "附件已保留，但未插入引用：\(result.message ?? "请重新选择插入位置")"
                return
            }
            // Compatibility for legacy callers/bundles that have no acknowledged command bridge.
            outgoing = (UUID(), type.conforms(to: .movie) ? "insertVideo" : "insertImage", ["src": imported.assetURL.absoluteString])
            message = "附件已写入，正在插入正文"
        } catch { message = "附件导入失败：\(error.localizedDescription)。请重试，正文未插入引用。" }
    }
    @Published private(set) var conflict = false
    @Published private(set) var recoveryVersions: [DocumentRecoveryStore.Version] = []
    private var stateObserver: NSObjectProtocol?
    override init(fileURL url: URL) {
        super.init(fileURL: url)
        stateObserver = NotificationCenter.default.addObserver(forName: UIDocument.stateChangedNotification, object: self, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.conflict = self.conflict || self.documentState.contains(.inConflict)
            if self.conflict { self.message = "存在多个版本，请先保留并处理冲突。" }
        }
    }
    deinit {
        if let stateObserver { NotificationCenter.default.removeObserver(stateObserver) }
        saveTask?.cancel()
    }
    @discardableResult
    func refreshRecovery() -> Bool {
        do {
            if let loadRecoveryVersions {
                recoveryVersions = try loadRecoveryVersions()
                return true
            }
            let directory = try DocumentRecoveryStore.directory(for: fileURL)
            let entries = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            var validVersions: [DocumentRecoveryStore.Version] = []
            var failures = 0
            var firstFailure: String?
            for entry in entries where entry.pathExtension == "json" {
                do {
                    let version = try JSONDecoder().decode(DocumentRecoveryStore.Version.self, from: Data(contentsOf: entry))
                    // Match the store's visibility window, but a read never deletes/repairs
                    // either healthy, expired, or unreadable recovery files.
                    if Date().timeIntervalSince(version.date) <= 30 * 86400 { validVersions.append(version) }
                } catch {
                    failures += 1
                    if firstFailure == nil { firstFailure = error.localizedDescription }
                }
            }
            recoveryVersions = validVersions.sorted { $0.date > $1.date }
            if failures > 0 {
                message = "部分恢复版本无法读取（\(failures) 项）：\(firstFailure ?? "未知错误")。可用版本仍可查看，请检查文件访问权限后重试。"
                return false
            }
            return true
        } catch {
            // A top-level directory/access failure has no trustworthy current listing.
            recoveryVersions = []
            message = "恢复版本读取失败：\(error.localizedDescription)。请检查文件访问权限后重试。"
            return false
        }
    }
    @MainActor
    func restore(_ version: DocumentRecoveryStore.Version) async throws {
        do {
            try await withProtectedEditor {
                try DocumentRecoveryStore.save(source, for: fileURL, reason: "恢复前的正文")
                parsed = MarkdownEngine.parseDocument(source: version.markdown)
                source = version.markdown
                acceptNormalization()
                updateChangeCount(.done)
                revision += 1
                editor.prepare(identity: fileURL.path, revision: revision)
                refreshRecovery()
                message = "已载入恢复版本，请保存"
            }
        } catch {
            message = "恢复处理未完整完成，请核对正文后重试：\(error.localizedDescription)"
            throw error
        }
    }
    /// Preserve every participant before resolving system versions. Copies share the original assets directory.
    @MainActor
    func preserveConflictsAndReload() async throws {
        do {
            try await withProtectedEditor {
                let versions = NSFileVersion.unresolvedConflictVersionsOfItem(at: fileURL) ?? []
                let disk = try String(contentsOf: fileURL, encoding: .utf8)
                var sources = [source, disk]
                for version in versions { sources.append(try String(contentsOf: version.url, encoding: .utf8)) }
                for content in Set(sources) {
                    try DocumentRecoveryStore.save(content, for: fileURL, reason: "冲突保护")
                    let copy = fileURL.deletingLastPathComponent().appendingPathComponent(fileURL.deletingPathExtension().lastPathComponent + " 冲突 " + UUID().uuidString.prefix(8) + ".md")
                    try Data(content.utf8).write(to: copy, options: .withoutOverwriting)
                }
                for version in versions { version.isResolved = true }
                let success: Bool
                if let reloadProtectedDocument { success = await reloadProtectedDocument() }
                else {
                    success = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                        revert(toContentsOf: fileURL) { success in
                            continuation.resume(returning: success)
                        }
                    }
                }
                conflict = !success
                message = success ? "已加载磁盘版本；各版本均保留为同目录冲突副本" : "重载失败；副本已保留，请重试"
                refreshRecovery()
                if !success { throw CocoaError(.fileReadUnknown) }
            }
        } catch {
            message = "保留冲突或重载失败：\(error.localizedDescription)。未完成加载，已生成的副本仍保留，请重试。"
            throw error
        }
    }

    /// Keep the acknowledged Web transaction lock across backup AND awaited revert.
    /// A flush alone cannot protect characters entered after its snapshot.
    @MainActor
    private func withProtectedEditor(_ operation: @MainActor () async throws -> Void) async throws {
        guard !saving, !composing else { throw CocoaError(.userCancelled) }
        saving = true
        saveTask?.cancel()
        defer { saveTask?.cancel(); saving = false }
        let intendedRevision = revision
        let finish = finishEditorProtection
        var attemptedLock = false
        do {
            if let beginEditorProtection {
                guard finish != nil else { throw CocoaError(.userCancelled) }
                attemptedLock = true
                guard await beginEditorProtection() else { throw CocoaError(.userCancelled) }
            } else if let flushEditor, !(await flushEditor()) {
                throw CocoaError(.userCancelled)
            }
            try Task.checkCancellation()
            guard !composing, revision == intendedRevision else { throw CocoaError(.userCancelled) }
            try await operation()
        } catch {
            // Release even when acquisition failed after JS already locked (e.g. stale ACK).
            if attemptedLock, let finish { _ = await finish() }
            throw error
        }
        if attemptedLock, let finish, !(await finish()) {
            throw CocoaError(.fileReadUnknown)
        }
    }
    private var original = ""
    private var originalCanonical = ""
    private var parsed = MarkdownEngine.parseDocument(source: "")
    private var normalizationAccepted = false
    private var saveTask: Task<Void, Never>?
    var body: TiptapNode { parsed.body }
    lazy var assets = AssetsManager(documentDirectoryProvider: { [weak self] in self?.fileURL.deletingLastPathComponent() })

    override func load(fromContents contents: Any, ofType typeName: String?) throws {
        guard let data = contents as? Data, let text = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        guard !composing else {
            conflict = true
            message = "输入中收到外部版本，请结束输入后处理冲突。"
            throw CocoaError(.userCancelled)
        }
        saveTask?.cancel()
        if hasUnsavedChanges && source != text {
            try DocumentRecoveryStore.save(source, for: fileURL, reason: "外部更新前的未保存内容")
            message = "收到外部更新；原有修改已保留，可在恢复版本中找回。"
        }
        original = text
        conflict = false
        parsed = MarkdownEngine.parseDocument(source: text)
        originalCanonical = MarkdownEngine.serialize(document: parsed)
        source = text
        normalizationAccepted = false
        needsNormalization = false
        revision += 1
        prepareEditorForLoadedRevision()
        refreshRecovery()
    }

    /// UIDocument may deliver load on a non-main queue. Never block that queue
    /// waiting for the main actor, which may itself be awaiting a document operation.
    private func prepareEditorForLoadedRevision() {
        let intendedIdentity = fileURL.path
        let intendedRevision = revision
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                editor.prepare(identity: intendedIdentity, revision: intendedRevision)
            }
        } else {
            Task { @MainActor [weak self] in
                guard let self, self.fileURL.path == intendedIdentity,
                      self.revision == intendedRevision else { return }
                self.editor.prepare(identity: intendedIdentity, revision: intendedRevision)
            }
        }
    }

    override func contents(forType typeName: String) throws -> Any {
        guard !needsNormalization, !conflict else { throw CocoaError(.userCancelled) }
        writtenSnapshot = source
        return Data(source.utf8)
    }

    func acceptNormalization() {
        normalizationAccepted = true
        needsNormalization = false
    }

    func replaceBody(_ body: TiptapNode) {
        guard body != parsed.body else { return }
        let previousCanonical = MarkdownEngine.serialize(document: parsed)
        var next = parsed
        next.body = body
        let nextCanonical = MarkdownEngine.serialize(document: next)
        // Tiptap adds default attributes on load. These aren't user edits and must
        // never normalize an opened file merely because we flushed the WebView.
        guard nextCanonical != previousCanonical else { parsed = next; return }
        if nextCanonical == originalCanonical {
            saveTask?.cancel()
            parsed = next
            source = original
            needsNormalization = false
            updateChangeCount(saving ? .done : .cleared)
            message = "与已保存版本一致"
            return
        }
        if !normalizationAccepted && originalCanonical != original {
            needsNormalization = true
        }
        parsed = next
        source = nextCanonical
        updateChangeCount(.done)
        do {
            try DocumentRecoveryStore.save(source, for: fileURL, reason: "最近编辑草稿", draft: true)
        } catch {
            message = "恢复草稿写入失败：\(error.localizedDescription)，请立即保存"
            return
        }
        message = needsNormalization ? "保存前需确认 Markdown 格式规范化" : "有未保存修改"
        saveTask?.cancel()
        saveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled, let self, !self.needsNormalization else { return }
            _ = await self.saveNow()
        }
    }

    func saveNow() async -> Bool {
        guard !saving else { return false }
        saving = true
        defer { saving = false }
        if let flushEditor, !(await flushEditor()) { message = "正在输入或编辑器尚未就绪，请稍后保存"; return false }
        guard !composing else { message = "请先完成当前输入，再保存"; return false }
        guard !needsNormalization else { return false }
        guard !conflict, !documentState.contains(.inConflict) else {
            message = "存在冲突版本，请先保留并处理"
            return false
        }
        guard hasUnsavedChanges else { return true }
        // UIDocument coordinates the actual write. Detect a disk change not yet delivered to its presenter.
        do {
            var disk: String?, readError: Error?, coordinationError: NSError?
            NSFileCoordinator(filePresenter: self).coordinate(readingItemAt: fileURL, options: [], error: &coordinationError) { url in
                do { disk = try String(contentsOf: url, encoding: .utf8) } catch { readError = error }
            }
            if let error = readError ?? coordinationError { throw error }
            if let disk, disk != original, disk != source {
                try DocumentRecoveryStore.save(source, for: fileURL, reason: "保存时发现外部更新")
                conflict = true
                message = "磁盘有新版本，已暂停保存。请保留并处理冲突。"
                refreshRecovery()
                return false
            }
        } catch { message = "无法核对磁盘版本，未覆盖原文件：\(error.localizedDescription)"; return false }
        let snapshot = source
        do { try DocumentRecoveryStore.save(original, for: fileURL, reason: "保存前版本") }
        catch { message = "备份失败，未覆盖原文件：\(error.localizedDescription)"; return false }
        writtenSnapshot = nil
        let success = await save(to: fileURL, for: .forOverwriting)
        if success {
            let written = writtenSnapshot ?? snapshot
            original = written
            originalCanonical = MarkdownEngine.serialize(document: MarkdownEngine.parseDocument(source: written))
            if source != written {
                updateChangeCount(.done)
                saveTask?.cancel()
                saveTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .milliseconds(700))
                    guard !Task.isCancelled, let self else { return }
                    _ = await self.saveNow()
                }
            }
        }
        message = success ? (hasUnsavedChanges ? "有新的未保存修改" : "已保存到本机 · iCloud 由系统同步") : "保存失败，可重试"
        return success && !hasUnsavedChanges
    }

    override func autosave(completionHandler: ((Bool) -> Void)? = nil) {
        guard !needsNormalization, !conflict, !documentState.contains(.inConflict) else {
            completionHandler?(false); return
        }
        Task { @MainActor in completionHandler?(await saveNow()) }
    }

    override func handleError(_ error: Error, userInteractionPermitted: Bool) {
        DispatchQueue.main.async { self.message = "文件操作失败：\(error.localizedDescription)" }
    }
}
