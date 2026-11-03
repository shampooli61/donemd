import Foundation
import CryptoKit

/// Local recovery is independent of iCloud and never claims remote delivery.
enum DocumentRecoveryStore {
    struct Version: Codable, Identifiable {
        let id: UUID
        let date: Date
        let markdown: String
        let reason: String
    }
    /// Returns normal Markdown siblings so attachments remain valid and recovery is visible in Finder/Files.
    static func protectExternalEdit(local: String, for url: URL) throws -> [URL] {
        var disk: String?, operationError: Error?, coordinationError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { coordinated in
            do { disk = try String(contentsOf: coordinated, encoding: .utf8) } catch { operationError = error }
        }
        if let error = operationError ?? coordinationError { throw error }
        guard let disk else { throw CocoaError(.fileReadUnknown) }
        var result: [URL] = []
        for (label, text) in [("本机", local), ("磁盘", disk)] {
            try save(text, for: url, reason: "外部修改：" + label)
            let target = url.deletingLastPathComponent().appendingPathComponent(url.deletingPathExtension().lastPathComponent + " 冲突-" + label + "-" + UUID().uuidString.prefix(8) + ".md")
            try Data(text.utf8).write(to: target, options: .withoutOverwriting)
            result.append(target)
        }
        return result
    }
    static func directory(for url: URL) throws -> URL {
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let key = SHA256.hash(data: Data(url.standardizedFileURL.path.utf8)).map { String(format: "%02x", $0) }.joined()
        let directory = support.appendingPathComponent("Done.md/document-recovery/" + key)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
    @discardableResult
    static func save(_ markdown: String, for url: URL, reason: String, draft: Bool = false) throws -> Version {
        let directory = try directory(for: url)
        let version = Version(id: UUID(), date: Date(), markdown: markdown, reason: reason)
        let name = draft ? "draft.json" : version.id.uuidString + ".json"
        try JSONEncoder().encode(version).write(to: directory.appendingPathComponent(name), options: .atomic)
        if !draft {
            let history = try versions(for: url)
            for old in history.dropFirst(20) { try? FileManager.default.removeItem(at: directory.appendingPathComponent(old.id.uuidString + ".json")) }
        }
        return version
    }
    static func versions(for url: URL) throws -> [Version] {
        let directory = try directory(for: url)
        let entries = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        return entries.filter { $0.pathExtension == "json" }.compactMap { file in
            guard let data = try? Data(contentsOf: file), let version = try? JSONDecoder().decode(Version.self, from: data) else { return nil }
            if Date().timeIntervalSince(version.date) > 30 * 86400 {
                try? FileManager.default.removeItem(at: file); return nil
            }
            return version
        }.sorted { $0.date > $1.date }
    }
}
