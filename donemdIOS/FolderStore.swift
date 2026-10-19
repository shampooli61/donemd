import Foundation
import Combine
import UniformTypeIdentifiers

@MainActor
final class FolderStore: ObservableObject {
    @Published var root: URL?
    @Published var error: String?
    private var accessing = false
    private let key = "document-folder-bookmark"

    init() {
        guard let data = UserDefaults.standard.data(forKey: key) else { return }
        do {
            var stale = false
            let url = try URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
            try select(url)
        } catch { self.error = "请重新选择文档文件夹：\(error.localizedDescription)" }
    }
    func select(_ url: URL) throws {
        let granted = url.startAccessingSecurityScopedResource()
        do {
            let data = try url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
            _ = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
            if accessing { root?.stopAccessingSecurityScopedResource() }
            root = url; accessing = granted
            UserDefaults.standard.set(data, forKey: key)
            error = nil
        } catch {
            if granted { url.stopAccessingSecurityScopedResource() }
            throw error
        }
    }
    func entries(in folder: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
            .filter { $0.lastPathComponent != "assets" && ((try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true || ["md", "markdown"].contains($0.pathExtension.lowercased())) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }
    func newDocument(in folder: URL) throws -> URL {
        var url = folder.appendingPathComponent("未命名.md")
        var index = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("未命名 \(index).md"); index += 1
        }
        try Data("# 未命名\n".utf8).write(to: url, options: .withoutOverwriting)
        return url
    }
}
