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
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--uitest-fixture") {
            let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("UI Test")
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let url = folder.appendingPathComponent("测试文档.md")
                try "# 测试文档\n\n这里是手机写作测试。\n".write(to: url, atomically: true, encoding: .utf8)
                root = folder
            } catch { self.error = error.localizedDescription }
            return
        }
        #endif
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
        try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles])
            .filter { (try? $0.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true && $0.lastPathComponent != "assets" && ((try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true || ["md", "markdown"].contains($0.pathExtension.lowercased())) }
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
    func rename(_ source: URL, to name: String) throws -> URL {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != ".", trimmed != "..", !trimmed.contains("/"), !trimmed.contains("\\"), !trimmed.hasPrefix(".") else { throw CocoaError(.fileWriteInvalidFileName) }
        let filename = ["md", "markdown"].contains((trimmed as NSString).pathExtension.lowercased()) ? trimmed : trimmed + ".md"
        let target = source.deletingLastPathComponent().appendingPathComponent(filename)
        if source == target { return source }
        var coordinationError: NSError?, operationError: Error?
        let coordinator = NSFileCoordinator()
        coordinator.coordinate(writingItemAt: source, options: .forMoving, writingItemAt: target, options: [], error: &coordinationError) { old, new in
            do {
                guard !FileManager.default.fileExists(atPath: new.path) else { throw CocoaError(.fileWriteFileExists) }
                coordinator.item(at: old, willMoveTo: new)
                try FileManager.default.moveItem(at: old, to: new)
                coordinator.item(at: old, didMoveTo: new)
            } catch { operationError = error }
        }
        if let error = operationError ?? coordinationError { throw error }
        return target
    }
    func duplicate(_ source: URL) throws -> URL {
        let target = source.deletingLastPathComponent().appendingPathComponent(source.deletingPathExtension().lastPathComponent + " 副本 " + UUID().uuidString.prefix(6) + ".md")
        var coordinationError: NSError?, operationError: Error?
        NSFileCoordinator().coordinate(readingItemAt: source, options: [], writingItemAt: target, options: [], error: &coordinationError) { old, new in
            do { try FileManager.default.copyItem(at: old, to: new) } catch { operationError = error }
        }
        if let error = operationError ?? coordinationError { throw error }
        return target
    }

    func requestOfflineDownload(in folder: URL) throws {
        let keys: [URLResourceKey] = [.isUbiquitousItemKey, .isSymbolicLinkKey]
        guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { throw CocoaError(.fileReadUnknown) }
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: Set(keys))
            if values.isSymbolicLink == true { enumerator.skipDescendants(); continue }
            if values.isUbiquitousItem == true { try FileManager.default.startDownloadingUbiquitousItem(at: url) }
        }
    }

}
