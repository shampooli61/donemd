import Foundation
import Combine

/// Keeps each incoming URL's access alive until its document closes or its request is cancelled.
private final class ScopedDocumentURL {
    let url: URL
    private let accessing: Bool
    private let stop: (URL) -> Void
    init(_ url: URL, start: (URL) -> Bool, stop: @escaping (URL) -> Void) {
        self.url = url
        self.stop = stop
        accessing = start(url)
    }
    deinit { if accessing { stop(url) } }
}

@MainActor
final class DocumentOpenCoordinator: ObservableObject {
    @Published var opened: MobileDocument?
    @Published private(set) var loading = false
    @Published var error: String?
    @Published private(set) var pendingURL: URL?
    @Published private(set) var canReauthorizePending = false
    private var pendingAccess: ScopedDocumentURL?
    let folders: FolderStore
    private var activeAccess: ScopedDocumentURL?
    private var activeDocument: MobileDocument?
    private var openingURL: URL?
    private let openDocument: (MobileDocument) async -> Bool
    private let startAccess: (URL) -> Bool
    private let stopAccess: (URL) -> Void
    init(
        folders: FolderStore,
        openDocument: @escaping (MobileDocument) async -> Bool = { await $0.open() },
        startAccess: @escaping (URL) -> Bool = { $0.startAccessingSecurityScopedResource() },
        stopAccess: @escaping (URL) -> Void = { $0.stopAccessingSecurityScopedResource() }
    ) {
        self.folders = folders
        self.openDocument = openDocument
        self.startAccess = startAccess
        self.stopAccess = stopAccess
    }

    private func scoped(_ url: URL) -> ScopedDocumentURL {
        ScopedDocumentURL(url, start: startAccess, stop: stopAccess)
    }

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
        let access = scoped(url)
        if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            error = "请选择 Markdown 文件，而不是文件夹。"
            return
        }
        pendingAccess = access
        pendingURL = url
        canReauthorizePending = false
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
        canReauthorizePending = false
        error = nil
    }

    /// Every folder picker must resume an incoming document instead of only changing the list.
    func selectFolder(_ folder: URL) async {
        // Validate the delivered URL, not just the picker's requested content type.
        // External file delivery must never attempt to enumerate a Markdown file as a directory.
        let access = scoped(folder)
        defer { withExtendedLifetime(access) {} }
        if folder.isFileURL,
           ["md", "markdown"].contains(folder.pathExtension.lowercased()),
           (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true {
            await receiveExternal(folder)
            return
        }
        if pendingURL != nil {
            await authorizePendingFolder(folder)
            return
        }
        do { try folders.select(folder); error = nil }
        catch { self.error = "文件夹授权失败：\(error.localizedDescription)" }
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
        let access = (pendingAccess?.url == url ? pendingAccess : nil) ?? scoped(url)
        let document = MobileDocument(fileURL: url)
        if await openDocument(document) {
            activeAccess = access
            activeDocument = document
            opened = document
            error = nil
        } else {
            // Membership beneath root is not proof that the provider still grants access.
            // Keep retry AND explicit reauthorization available, without discarding a
            // different request that may have arrived while UIDocument.open suspended.
            if pendingURL == nil {
                pendingURL = url
                pendingAccess = access
            }
            if let pendingURL, sameFile(pendingURL, url) {
                canReauthorizePending = true
                error = "无法打开文档，请确认文件已下载且仍有访问权限；可重试或重新授权文档所在文件夹。"
            }
        }
    }
}
