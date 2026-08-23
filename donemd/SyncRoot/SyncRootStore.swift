import Foundation

/// Persistent ordered list of user-declared sync root directories. Single
/// source of truth for *which* directories `SyncRootScanner` indexes and
/// in what priority order — sole consumer of that order is token-conflict
/// resolution (ADR-0006 § token 冲突解决).
///
/// Storage: `~/Library/Application Support/Done.md/sync-roots.json`. This
/// is **configuration**, not data — paths are machine-local (a user's
/// `~/Documents/Feishu` on machine A means nothing on machine B), so the
/// file is intentionally not iCloud-synced and not put under git.
///
/// All paths are stored standardized (`URL.standardizedFileURL`), so two
/// `add` calls with `~/Foo` and `~/Foo/` resolve to the same entry.
public final class SyncRootStore {

    public enum StoreError: Error, Equatable {
        case notADirectory(path: String)
        case writeFailed(underlying: String)
    }

    /// Default location: `~/Library/Application Support/Done.md/sync-roots.json`.
    /// Tests inject a temporary URL via `init(storeURL:)`.
    public static var defaultStoreURL: URL {
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return appSupport
            .appendingPathComponent("Done.md", isDirectory: true)
            .appendingPathComponent("sync-roots.json", isDirectory: false)
    }

    private let storeURL: URL
    private let fileManager: FileManager
    private var roots: [URL]

    public init(
        storeURL: URL = SyncRootStore.defaultStoreURL,
        fileManager: FileManager = .default
    ) {
        self.storeURL = storeURL
        self.fileManager = fileManager
        self.roots = Self.load(from: storeURL, fileManager: fileManager)
    }

    /// Roots in user-declared priority order. Returned by value — callers
    /// can't mutate the internal array.
    public func list() -> [URL] {
        roots
    }

    /// Append a new root. No-op if it's already in the list (post-canonicalization).
    /// Throws `notADirectory` when the path doesn't resolve to a directory.
    public func add(_ url: URL) throws {
        let canonical = url.standardizedFileURL
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: canonical.path, isDirectory: &isDir),
              isDir.boolValue else {
            throw StoreError.notADirectory(path: canonical.path)
        }
        if roots.contains(canonical) { return }
        roots.append(canonical)
        try persist()
    }

    /// Remove a root by path. Idempotent — removing a non-member is a no-op.
    public func remove(_ url: URL) {
        let canonical = url.standardizedFileURL
        guard let index = roots.firstIndex(of: canonical) else { return }
        roots.remove(at: index)
        try? persist()
    }

    /// Reorder existing roots. The new order must be a permutation of the
    /// current set; mismatched input is silently ignored (UI guards against
    /// supplying anything else).
    public func reorder(_ newOrder: [URL]) {
        let canonical = newOrder.map { $0.standardizedFileURL }
        guard Set(canonical) == Set(roots), canonical.count == roots.count else { return }
        roots = canonical
        try? persist()
    }

    // MARK: persistence

    private func persist() throws {
        let paths = roots.map(\.path)
        do {
            let data = try JSONEncoder().encode(paths)
            try fileManager.createDirectory(
                at: storeURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: storeURL, options: .atomic)
        } catch {
            throw StoreError.writeFailed(underlying: String(describing: error))
        }
    }

    private static func load(from url: URL, fileManager: FileManager) -> [URL] {
        guard fileManager.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let paths = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return paths.map { URL(fileURLWithPath: $0).standardizedFileURL }
    }
}
