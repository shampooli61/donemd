import UIKit
import Combine
import UniformTypeIdentifiers

/// Keeps the original bytes until an actual edit, including metadata unknown to this client.
final class MobileDocument: UIDocument, ObservableObject {
    @Published private(set) var source = ""
    @Published private(set) var revision = 0
    @Published var message: String?
    @Published private(set) var needsNormalization = false
    @Published var outgoing: (id: UUID, type: String, payload: [String: String])?
    @Published var previewURL: URL?
    @Published var importing = false
    func importMedia(_ url: URL, removeTemporary: Bool = false) async {
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
            let manager = assets
            let imported = try await Task.detached {
                try manager.importFile(at: url, mimeType: type.preferredMIMEType ?? "application/octet-stream")
            }.value
            outgoing = (UUID(), type.conforms(to: .movie) ? "insertVideo" : "insertImage", ["src": imported.assetURL.absoluteString])
            message = "附件已写入，正在插入正文"
        } catch { message = "附件导入失败：\(error.localizedDescription)。请重试，正文未插入引用。" }
    }
    private var original = ""
    private var parsed = MarkdownEngine.parseDocument(source: "")
    private var normalizationAccepted = false
    private var saveTask: Task<Void, Never>?
    var body: TiptapNode { parsed.body }
    lazy var assets = AssetsManager(documentDirectoryProvider: { [weak self] in self?.fileURL.deletingLastPathComponent() })

    override func load(fromContents contents: Any, ofType typeName: String?) throws {
        guard let data = contents as? Data, let text = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        original = text
        parsed = MarkdownEngine.parseDocument(source: text)
        source = text
        normalizationAccepted = false
        needsNormalization = false
        revision += 1
    }

    override func contents(forType typeName: String) throws -> Any {
        guard !needsNormalization else { throw CocoaError(.userCancelled) }
        return Data(source.utf8)
    }

    func acceptNormalization() {
        normalizationAccepted = true
        needsNormalization = false
    }

    func replaceBody(_ body: TiptapNode) {
        guard body != parsed.body else { return }
        if !normalizationAccepted && MarkdownEngine.serialize(document: parsed) != original {
            needsNormalization = true
        }
        parsed.body = body
        source = MarkdownEngine.serialize(document: parsed)
        updateChangeCount(.done)
        message = needsNormalization ? "保存前需确认 Markdown 格式规范化" : "有未保存修改"
        saveTask?.cancel()
        saveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled, let self, !self.needsNormalization else { return }
            _ = await self.saveNow()
        }
    }

    func saveNow() async -> Bool {
        guard !needsNormalization else { return false }
        guard !documentState.contains(.inConflict) else {
            message = "存在冲突版本，请先保留并处理"
            return false
        }
        guard hasUnsavedChanges else { return true }
        let success = await save(to: fileURL, for: .forOverwriting)
        message = success ? "已保存到本机 · iCloud 由系统同步" : "保存失败，可重试"
        return success
    }

    override func autosave(completionHandler: ((Bool) -> Void)? = nil) {
        guard !needsNormalization, !documentState.contains(.inConflict) else {
            completionHandler?(false); return
        }
        super.autosave(completionHandler: completionHandler)
    }

    override func handleError(_ error: Error, userInteractionPermitted: Bool) {
        DispatchQueue.main.async { self.message = "文件操作失败：\(error.localizedDescription)" }
    }
}
