import Foundation
import CryptoKit

/// Safety net for the "pull overwrites local" hazard (GH #84 / #85).
///
/// A Feishu pull rebuilds the local body from the remote document. If the
/// remote is damaged (e.g. a push only landed the title, leaving the body
/// empty — the #84 incident), pull faithfully copies that damage back and
/// the user's local content is gone. A normal user has no git to recover.
///
/// This store takes a snapshot of the local markdown *before* pull applies
/// the remote content, so the pull is always reversible within a window.
/// The undo entry point is the 飞书 ▸「撤销上次拉取」menu item
/// (`FeishuUndoPullCommand`), which is valid for `undoWindow` after the
/// pull (10 minutes — the user asked for a generous window rather than a
/// few-second toast).
///
/// Storage lives in Application Support, keyed by a hash of the source
/// file's path — never as a sibling file in the user's folder (keeps their
/// directory clean and avoids the forbidden-commit sibling-file rule). One
/// snapshot per source file; a fresh pull overwrites the previous
/// snapshot for that file.
enum FeishuPullSnapshotStore {

    /// How long after a pull the snapshot stays restorable. The toast /
    /// dialog is transient, but the undo capability itself persists this
    /// long so a user who notices the damage minutes later can still
    /// recover.
    static let undoWindow: TimeInterval = 600 // 10 minutes

    struct Snapshot {
        /// The file the snapshot was taken from — undo writes back here.
        let originalFileURL: URL
        /// Serialized markdown of the pre-pull document (frontmatter + body).
        let markdown: String
        /// When the snapshot was captured.
        let capturedAt: Date
        /// Body block count at capture time — surfaced in the undo prompt
        /// so the user sees "restore N paragraphs".
        let blockCount: Int

        /// True while still inside the undo window relative to `now`.
        func isFresh(now: Date = Date()) -> Bool {
            now.timeIntervalSince(capturedAt) <= undoWindow
        }
    }

    // MARK: - public API

    /// Capture `markdown` as the pre-pull snapshot for `fileURL`. Best
    /// effort: a snapshot write failure must never block the pull itself
    /// (the pull is the user's explicit action; losing the safety net is
    /// worse UX than a failed save but not worth aborting the pull). Logs
    /// and returns false on failure.
    @discardableResult
    static func save(
        markdown: String,
        for fileURL: URL,
        blockCount: Int,
        now: Date = Date()
    ) -> Bool {
        do {
            let dir = try snapshotDirectory()
            let base = key(for: fileURL)
            let mdURL = dir.appendingPathComponent(base + ".md")
            let metaURL = dir.appendingPathComponent(base + ".json")

            try markdown.data(using: .utf8)?.write(to: mdURL, options: .atomic)

            let meta = Meta(
                originalPath: fileURL.path,
                capturedAt: now,
                blockCount: blockCount
            )
            let metaData = try JSONEncoder().encode(meta)
            try metaData.write(to: metaURL, options: .atomic)
            debugLog("[pull-snapshot] saved for \(fileURL.lastPathComponent) blocks=\(blockCount)")
            return true
        } catch {
            debugLog("[pull-snapshot] save FAILED for \(fileURL.lastPathComponent): \(error)")
            return false
        }
    }

    /// Return the snapshot for `fileURL` if one exists and is still within
    /// the undo window. Returns nil when there's no snapshot, it's stale,
    /// or it can't be read.
    static func latest(
        for fileURL: URL,
        now: Date = Date()
    ) -> Snapshot? {
        guard let dir = try? snapshotDirectory() else { return nil }
        let base = key(for: fileURL)
        let mdURL = dir.appendingPathComponent(base + ".md")
        let metaURL = dir.appendingPathComponent(base + ".json")

        guard let metaData = try? Data(contentsOf: metaURL),
              let meta = try? JSONDecoder().decode(Meta.self, from: metaData),
              let markdown = try? String(contentsOf: mdURL, encoding: .utf8) else {
            return nil
        }

        let snapshot = Snapshot(
            originalFileURL: URL(fileURLWithPath: meta.originalPath),
            markdown: markdown,
            capturedAt: meta.capturedAt,
            blockCount: meta.blockCount
        )
        guard snapshot.isFresh(now: now) else {
            // Stale — clean it up so it can't be restored by mistake later.
            clear(for: fileURL)
            return nil
        }
        return snapshot
    }

    /// Delete the snapshot for `fileURL` (called after a successful undo,
    /// or when a stale snapshot is detected). Idempotent.
    static func clear(for fileURL: URL) {
        guard let dir = try? snapshotDirectory() else { return }
        let base = key(for: fileURL)
        try? FileManager.default.removeItem(
            at: dir.appendingPathComponent(base + ".md"))
        try? FileManager.default.removeItem(
            at: dir.appendingPathComponent(base + ".json"))
    }

    // MARK: - internals

    private struct Meta: Codable {
        let originalPath: String
        let capturedAt: Date
        let blockCount: Int
    }

    /// `~/Library/Application Support/Done.md/pull-backups/`, created on demand.
    private static func snapshotDirectory() throws -> URL {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = support
            .appendingPathComponent("Done.md", isDirectory: true)
            .appendingPathComponent("pull-backups", isDirectory: true)
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true
        )
        return dir
    }

    /// Stable filename key for a source file path. SHA256 of the absolute
    /// path so two files with the same basename in different folders don't
    /// collide, and the key is filesystem-safe.
    private static func key(for fileURL: URL) -> String {
        let path = fileURL.standardizedFileURL.path
        let digest = SHA256.hash(data: Data(path.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
