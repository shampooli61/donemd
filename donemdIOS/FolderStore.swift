import Foundation
import Combine
import UniformTypeIdentifiers

/// A balanced scope is owned only after directory validation succeeds. Local URLs may
/// be readable even when startAccessingSecurityScopedResource returns false.
private final class FolderAccessScope {
    private let url: URL
    private let granted: Bool
    private let stop: (URL) -> Void
    init(_ url: URL, start: (URL) -> Bool, stop: @escaping (URL) -> Void) {
        self.url = url
        self.stop = stop
        granted = start(url)
    }
    deinit { if granted { stop(url) } }
}

private func coordinatedDirectoryContents(
    at folder: URL, keys: [URLResourceKey], options: FileManager.DirectoryEnumerationOptions
) throws -> [URL] {
    var coordinationError: NSError?
    var result: Result<[URL], Error>?
    NSFileCoordinator().coordinate(readingItemAt: folder, options: [], error: &coordinationError) { url in
        result = Result { try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: options) }
    }
    if let coordinationError { throw coordinationError }
    guard let result else { throw CocoaError(.fileReadUnknown) }
    return try result.get()
}

@MainActor
final class FolderStore: ObservableObject {
    @Published var root: URL?
    @Published var error: String?
    // Narrow I/O seams keep invalid bookmark/provider failures reproducible in tests.
    struct Access {
        var resolveBookmark: (Data) throws -> URL = { data in
            var stale = false
            return try URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
        }
        var makeBookmark: (URL) throws -> Data = {
            try $0.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
        }
        var readDirectory: (URL, [URLResourceKey], FileManager.DirectoryEnumerationOptions) throws -> [URL] = {
            try coordinatedDirectoryContents(at: $0, keys: $1, options: $2)
        }
        var start: (URL) -> Bool = { $0.startAccessingSecurityScopedResource() }
        var stop: (URL) -> Void = { $0.stopAccessingSecurityScopedResource() }
    }
    private let defaults: UserDefaults
    private let access: Access
    private var scope: FolderAccessScope?
    private let key = "document-folder-bookmark"

    init(defaults: UserDefaults = .standard, access: Access = Access()) {
        self.defaults = defaults
        self.access = access
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--uitest-fixture") {
            let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("UI Test")
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let url = folder.appendingPathComponent("测试文档.md")
                let fixture = ProcessInfo.processInfo.arguments.contains("--uitest-noncanonical")
                    ? "测试文档\n=======\n\n这里是手机写作测试。\n\n\n"
                    : "# 测试文档\n\n这里是手机写作测试。\n"
                try fixture.write(to: url, atomically: true, encoding: .utf8)
                root = folder
            } catch { self.error = error.localizedDescription }
            return
        }
        #endif
        guard let data = defaults.data(forKey: key) else { return }
        do {
            try select(access.resolveBookmark(data))
        } catch {
            // Remove only the unusable authorization record, never anything on disk.
            // A failed *new* selection below does not invalidate an existing working grant.
            defaults.removeObject(forKey: key)
            self.error = "请重新选择文档文件夹：\(error.localizedDescription)"
        }
    }
    func select(_ url: URL) throws {
        let candidate = FolderAccessScope(url, start: access.start, stop: access.stop)
        // Retain the candidate through validation, including all throwing exits.
        defer { withExtendedLifetime(candidate) {} }
        _ = try access.readDirectory(url, [], [])
        let data = try access.makeBookmark(url)
        defaults.set(data, forKey: key)
        scope = candidate
        root = url
        error = nil
    }
    func entries(in folder: URL) throws -> [URL] {
        try access.readDirectory(folder, [.isDirectoryKey, .isSymbolicLinkKey], [.skipsHiddenFiles])
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
