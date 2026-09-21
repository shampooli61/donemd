import Foundation
import CryptoKit

/// Atomic, versioned local recovery. At most 20 versions per file, for 30 days.
enum FeishuPullSnapshotStore {
    static let undoWindow: TimeInterval = 30 * 86400
    struct Snapshot: Codable {
        let originalFileURL: URL
        let markdown: String
        let capturedAt: Date
        let blockCount: Int
        var id: String = UUID().uuidString
        func isFresh(now: Date = Date()) -> Bool {
            now.timeIntervalSince(capturedAt) <= undoWindow
        }
    }
    @discardableResult
    static func save(markdown: String, for fileURL: URL, blockCount: Int, now: Date = Date()) -> Bool {
        do {
            let dir = try snapshotDirectory()
            let snapshot = Snapshot(originalFileURL: fileURL, markdown: markdown, capturedAt: now, blockCount: blockCount)
            let data = try JSONEncoder().encode(snapshot)
            try data.write(to: dir.appendingPathComponent(key(for: fileURL) + "-" + snapshot.id + ".json"), options: .atomic)
            let versions = history(for: fileURL, now: now)
            for old in versions.dropFirst(20) { remove(old) }
            return true
        } catch {
            debugLog("[pull-snapshot] save failed: \(error)")
            return false
        }
    }
    static func history(for fileURL: URL, now: Date = Date()) -> [Snapshot] {
        guard let dir = try? snapshotDirectory() else { return [] }
        migrateLegacy(for: fileURL, in: dir)
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return [] }
        let prefix = key(for: fileURL) + "-"
        return files.filter { $0.lastPathComponent.hasPrefix(prefix) && $0.pathExtension == "json" }
            .compactMap { url -> Snapshot? in
                guard let data = try? Data(contentsOf: url), let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) else { return nil }
                guard snapshot.isFresh(now: now) else { try? FileManager.default.removeItem(at: url); return nil }
                return snapshot
            }.sorted { $0.capturedAt > $1.capturedAt }
    }
    static func latest(for fileURL: URL, now: Date = Date()) -> Snapshot? {
        history(for: fileURL, now: now).first
    }
    static func clear(for fileURL: URL) {
        if let snapshot = latest(for: fileURL) { remove(snapshot) }
    }
    private struct LegacyMeta: Decodable {
        let originalPath: String
        let capturedAt: Date
        let blockCount: Int
    }
    private static func migrateLegacy(for fileURL: URL, in dir: URL) {
        let base = key(for: fileURL)
        let metaURL = dir.appendingPathComponent(base + ".json")
        let mdURL = dir.appendingPathComponent(base + ".md")
        guard let data = try? Data(contentsOf: metaURL),
              let meta = try? JSONDecoder().decode(LegacyMeta.self, from: data),
              let markdown = try? String(contentsOf: mdURL, encoding: .utf8) else { return }
        let snapshot = Snapshot(originalFileURL: URL(fileURLWithPath: meta.originalPath), markdown: markdown,
                                capturedAt: meta.capturedAt, blockCount: meta.blockCount, id: "legacy")
        do {
            try JSONEncoder().encode(snapshot).write(to: dir.appendingPathComponent(base + "-legacy.json"), options: .atomic)
            try? FileManager.default.removeItem(at: metaURL)
            try? FileManager.default.removeItem(at: mdURL)
        } catch { debugLog("[pull-snapshot] legacy migration failed: \(error)") }
    }
    private static func remove(_ snapshot: Snapshot) {
        guard let dir = try? snapshotDirectory() else { return }
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(key(for: snapshot.originalFileURL) + "-" + snapshot.id + ".json"))
    }
    private static func snapshotDirectory() throws -> URL {
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let dir = support.appendingPathComponent("Done.md/pull-backups", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    private static func key(for url: URL) -> String {
        SHA256.hash(data: Data(url.standardizedFileURL.path.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
