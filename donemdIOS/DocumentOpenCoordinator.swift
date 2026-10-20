import Foundation
import Combine

/// Keeps each incoming URL's access alive until its document closes or its request is cancelled.
private final class ScopedDocumentURL {
    let url: URL
    private let accessing: Bool
    init(_ url: URL) {
        self.url = url
        accessing = url.startAccessingSecurityScopedResource()
    }
    deinit { if accessing { url.stopAccessingSecurityScopedResource() } }
}

@MainActor
final class DocumentOpenCoordinator: ObservableObject {
    @Published var opened: MobileDocument?
    @Published private(set) var loading = false
    @Published var error: String?
    @Published private(set) var pendingURL: URL?
    private var pendingAccess: ScopedDocumentURL?
    let folders: FolderStore
    private var activeAccess: ScopedDocumentURL?
    private var activeDocument: MobileDocument?
    private var openingURL: URL?
    init(folders: FolderStore) { self.folders = folders }

    func receiveExternal(_ url: URL) async {
        guard url.isFileURL, ["md", "markdown"].contains(url.pathExtension.lowercased()) else {
            error = "请选择 Markdown 文档（.md 或 .markdown）。"
            return
        }
        if let active = activeDocument, sameFile(active.fileURL, url) { return }
        if let openingURL, sameFile(openingURL, url) { return }
        if let pendingURL {
            if sameFile(pendingURL, url) { await openPending() }
            else { error = "已有待打开文档，请先完成或取消该请求，再打开其他文档。" }
            return
        }
        let access = ScopedDocumentURL(url)
        if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            error = "请选择 Markdown 文件，而不是文件夹。"
            return
        }
        pendingAccess = access
        pendingURL = url
        await openPending()
    }

    private func sameFile(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.resolvingSymlinksInPath().standardizedFileURL == rhs.resolvingSymlinksInPath().standardizedFileURL
    }

    var needsFolderAuthorization: Bool {
        guard let pendingURL else { return false }
        return !hasFolderAccess(to: pendingURL)
    }

    private func hasFolderAccess(to url: URL) -> Bool {
        guard let root = folders.root else { return false }
        let base = root.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        let path = url.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        return path.count > base.count && path.starts(with: base)
    }

    func openPending() async {
        guard let url = pendingURL, !needsFolderAuthorization, activeDocument == nil, opened == nil, !loading else { return }
        await open(url)
        if opened != nil { cancelPending() }
    }

    func didDismiss() async {
        if let current = activeDocument, !current.documentState.contains(.closed) {
            guard !current.hasUnsavedChanges else {
                error = "当前文档尚未保存，请先保存并返回。"
                opened = current
                return
            }
            guard await current.close() else {
                error = "关闭文档失败，请重试。"
                opened = current
                return
            }
        }
        opened = nil
        activeDocument = nil
        activeAccess = nil
        await openPending()
    }

    func cancelPending() {
        guard !loading else { return }
        pendingURL = nil
        pendingAccess = nil
        error = nil
    }

    func authorizePendingFolder(_ folder: URL) async {
        guard let file = pendingURL, activeDocument == nil, opened == nil, !loading else { return }
        guard folder.resolvingSymlinksInPath().standardizedFileURL == file.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL else {
            error = "请选择该文档所在的文件夹。"
            return
        }
        do { try folders.select(folder); await openPending() }
        catch { self.error = "文件夹授权失败：\(error.localizedDescription)" }
    }

    func open(_ url: URL) async {
        guard activeDocument == nil, opened == nil, !loading else { return }
        loading = true
        openingURL = url
        defer { loading = false; openingURL = nil }
        // Transfer the original external scope, rather than assuming a second start grants access.
        let access = (pendingAccess?.url == url ? pendingAccess : nil) ?? ScopedDocumentURL(url)
        let document = MobileDocument(fileURL: url)
        if await document.open() {
            activeAccess = access
            activeDocument = document
            opened = document
            error = nil
        } else {
            error = "无法打开文档，请确认文件已下载且仍有访问权限，然后重试。"
        }
    }
}
