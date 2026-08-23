import Foundation

/// Persistent, ordered list of file-backed document windows that were open
/// at last quit, so a cold launch can re-open them ([[会话恢复]], PRD story 47
/// revision). Deliberately records **only documents with a `fileURL`** —
/// untitled drafts are excluded, so we never have to touch `autosavesDrafts`
/// (which historically broke the open-panel path, see DonemdDocument.swift).
///
/// Storage: `~/Library/Application Support/Done.md/open-session.json`
/// (sibling of `sync-roots.json`). Like sync roots this is machine-local
/// **data** — paths mean nothing on another machine — so it is intentionally
/// not iCloud-synced and not under git.
///
/// Why self-managed instead of AppKit's automatic NSDocument State
/// Restoration: the OS mechanism is gated by the system preference "Close
/// windows when quitting an application" (`NSQuitAlwaysKeepsWindows`), so it
/// silently stops working when the user turns that on. Recording the session
/// ourselves makes restore behavior independent of that switch.
///
/// Why paths, not security-scoped bookmarks: Done.md is not sandboxed, so a
/// plain path is enough to `openDocument(withContentsOf:)`. Bookmarks would
/// survive file moves/renames, but a missing file is exactly the
/// "silently skip" case we want anyway. Revisit (upgrade to bookmark data)
/// only if Done.md ever ships sandboxed on the Mac App Store.
///
/// Pure logic + injectable `storeURL` — mirrors `SyncRootStore` so it's
/// trivially unit-testable against a temp directory.
public final class OpenSessionStore {

    /// Default location: `~/Library/Application Support/Done.md/open-session.json`.
    /// Tests inject a temporary URL via `init(storeURL:)`.
    public static var defaultStoreURL: URL {
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return appSupport
            .appendingPathComponent("Done.md", isDirectory: true)
            .appendingPathComponent("open-session.json", isDirectory: false)
    }

    private let storeURL: URL
    private let fileManager: FileManager
    private var urls: [URL]

    public init(
        storeURL: URL = OpenSessionStore.defaultStoreURL,
        fileManager: FileManager = .default
    ) {
        self.storeURL = storeURL
        self.fileManager = fileManager
        self.urls = Self.load(from: storeURL, fileManager: fileManager)
    }

    /// The file URLs recorded at last write, in insertion order. Returned by
    /// value — callers can't mutate the internal array.
    public func recordedURLs() -> [URL] {
        urls
    }

    /// Add a URL to the session if absent (post-standardization). Idempotent.
    public func note(opened url: URL) {
        let canonical = url.standardizedFileURL
        if urls.contains(canonical) { return }
        urls.append(canonical)
        try? persist()
    }

    /// Remove a URL from the session. Idempotent — removing a non-member is a
    /// no-op.
    public func note(closed url: URL) {
        let canonical = url.standardizedFileURL
        guard let index = urls.firstIndex(of: canonical) else { return }
        urls.remove(at: index)
        try? persist()
    }

    /// Replace the whole snapshot (whole-list rewrite, used as a safety-net
    /// on app termination over the incremental `note(opened:/closed:)` calls).
    /// Standardizes + de-dups while preserving first-seen order.
    public func replace(with newURLs: [URL]) {
        var seen = Set<URL>()
        var deduped: [URL] = []
        for url in newURLs {
            let canonical = url.standardizedFileURL
            if seen.insert(canonical).inserted {
                deduped.append(canonical)
            }
        }
        urls = deduped
        try? persist()
    }

    // MARK: - pure helpers (unit-testable without NSDocumentController)

    /// Filter a recorded list down to the URLs whose file still exists on
    /// disk, preserving order. Files that were deleted / moved / renamed
    /// since last quit drop out here so restore can silently skip them.
    public static func existingURLs(
        from recorded: [URL],
        fileManager: FileManager = .default
    ) -> [URL] {
        recorded.filter { fileManager.fileExists(atPath: $0.path) }
    }

    // MARK: - persistence (identical shape to SyncRootStore)

    private func persist() throws {
        let paths = urls.map(\.path)
        let data = try JSONEncoder().encode(paths)
        try fileManager.createDirectory(
            at: storeURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: storeURL, options: .atomic)
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

/// Pure decision for what a cold launch should do, given the recorded session
/// and which of those files still exist. Extracted so the branch logic is
/// unit-testable without driving `NSDocumentController`.
public enum SessionRestorePlan: Equatable {
    /// Re-open these (existing) document URLs, in order.
    case restore([URL])
    /// Nothing to restore — open a blank untitled window instead.
    case openBlank

    /// - Parameters:
    ///   - recorded: the raw recorded session (may include vanished files).
    ///   - existing: `recorded` filtered to files that still exist
    ///     (`OpenSessionStore.existingURLs`).
    public static func decide(recorded: [URL], existing: [URL]) -> SessionRestorePlan {
        existing.isEmpty ? .openBlank : .restore(existing)
    }
}
