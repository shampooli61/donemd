import Foundation
import CryptoKit

/// One image successfully imported by `AssetsManager`.
public struct ImportedImage: Equatable {
    /// Bare filename in the form `"<sha256-hex>.<ext>"` — no path prefix.
    public let storageFilename: String

    /// Runtime URL the WebView should use as the `<img src>` (Visual 视图).
    /// Always `donemd-asset://<storageFilename>`.
    public let assetURL: URL

    /// Disk-format relative path written into Markdown. Always `./assets/<storageFilename>`.
    public let markdownPath: String
}

public enum AssetsManagerError: Error, Equatable {
    case writeFailed(String)
    case migrationFailed(String)
}

/// Per-Document image asset store.
///
/// Layout for a saved document (named):
///   <doc-dir>/assets/<sha256-hex>.<ext>
///
/// Layout for an untitled document (no `fileURL` yet):
///   <Caches>/com.shampoo.donemd/Untitled-<UUID>/assets/<sha256-hex>.<ext>
///
/// `migrateAssets(to:)` moves the staged temp directory into the real
/// document directory once the user gives the document a path. Wired by
/// Slice 8 (#9) when Save As lands.
///
/// Naming uses sha256 of the bytes — same image inserted twice resolves to
/// the same filename and the file is written only once.
public final class AssetsManager {
    private let documentDirectoryProvider: () -> URL?
    private let temporaryDirectory: URL
    private let fileManager: FileManager

    public init(
        documentDirectoryProvider: @escaping () -> URL?,
        fileManager: FileManager = .default
    ) {
        self.documentDirectoryProvider = documentDirectoryProvider
        self.fileManager = fileManager

        let cachesDir =
            (fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
             ?? fileManager.temporaryDirectory)
            .appendingPathComponent("com.shampoo.donemd", isDirectory: true)
        self.temporaryDirectory =
            cachesDir.appendingPathComponent("Untitled-\(UUID().uuidString)", isDirectory: true)
    }

    /// Import an image from raw bytes. Idempotent on identical bytes.
    @discardableResult
    public func importImage(data: Data, mimeType: String) throws -> ImportedImage {
        try importAsset(data: data, mimeType: mimeType)
    }

    /// Import a local video from raw bytes. Same SHA256-dedup + `assets/`
    /// storage as images — the store is asset-type-agnostic; only the
    /// MIME→ext table below knows about video. See ADR-0009 (本地视频).
    @discardableResult
    public func importVideo(data: Data, mimeType: String) throws -> ImportedImage {
        try importAsset(data: data, mimeType: mimeType)
    }

    /// Shared import core for any asset kind. Idempotent on identical bytes.
    @discardableResult
    private func importAsset(data: Data, mimeType: String) throws -> ImportedImage {
        let hash = SHA256.hash(data: data).hexString
        let ext = Self.filenameExtension(forMimeType: mimeType)
        let filename = "\(hash).\(ext)"

        let assetsDir = currentAssetsDirectory()
        do {
            try fileManager.createDirectory(at: assetsDir, withIntermediateDirectories: true)
        } catch {
            throw AssetsManagerError.writeFailed("create assets dir: \(error)")
        }

        let target = assetsDir.appendingPathComponent(filename)
        if !fileManager.fileExists(atPath: target.path) {
            do {
                try data.write(to: target, options: .atomic)
            } catch {
                throw AssetsManagerError.writeFailed("write \(filename): \(error)")
            }
        }

        return ImportedImage(
            storageFilename: filename,
            assetURL: URL(string: "donemd-asset://\(filename)")!,
            markdownPath: "./assets/\(filename)"
        )
    }

    /// Stream media into the store so importing a video does not allocate the whole file.
    public func importFile(at url: URL, mimeType: String) throws -> ImportedImage {
        let directory = currentAssetsDirectory()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let staging = directory.appendingPathComponent(".import-" + UUID().uuidString)
        defer { try? fileManager.removeItem(at: staging) }
        let reader = try FileHandle(forReadingFrom: url)
        defer { try? reader.close() }
        guard fileManager.createFile(atPath: staging.path, contents: nil) else { throw AssetsManagerError.writeFailed("create staging file") }
        let writer = try FileHandle(forWritingTo: staging)
        defer { try? writer.close() }
        var hasher = SHA256()
        while let chunk = try reader.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            hasher.update(data: chunk)
            try writer.write(contentsOf: chunk)
        }
        try writer.synchronize()
        let name = hasher.finalize().hexString + "." + Self.filenameExtension(forMimeType: mimeType)
        let target = directory.appendingPathComponent(name)
        if !fileManager.fileExists(atPath: target.path) { try fileManager.moveItem(at: staging, to: target) }
        return ImportedImage(storageFilename: name, assetURL: URL(string: "donemd-asset://" + name)!, markdownPath: "./assets/" + name)
    }

    /// URL of the stored asset on disk for a given filename, or `nil` if
    /// nothing is stored under that name (yet). Used by the URL scheme
    /// handler to satisfy `donemd-asset://` requests.
    public func storedFileURL(forFilename filename: String) -> URL? {
        guard !filename.isEmpty, filename != ".", filename != "..",
              !filename.contains("/"), !filename.contains("\\"),
              !(filename.removingPercentEncoding ?? filename).contains("/") else { return nil }
        let candidates = [
            currentAssetsDirectory().appendingPathComponent(filename),
            // Fall back to temp in case the document just transitioned but
            // migration hasn't finished yet.
            temporaryDirectory.appendingPathComponent("assets", isDirectory: true)
                .appendingPathComponent(filename),
        ]
        return candidates.first {
            let root = $0.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL.path + "/"
            return $0.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(root)
                && fileManager.fileExists(atPath: $0.path)
        }
    }

    /// Migrate any temp-stored assets to the document's real directory.
    /// Called by Slice 8 (#9) right after the user picks a Save As path.
    public func migrateAssets(to newDocumentDirectory: URL) throws {
        let from = temporaryDirectory.appendingPathComponent("assets", isDirectory: true)
        guard fileManager.fileExists(atPath: from.path) else { return }
        let to = newDocumentDirectory.appendingPathComponent("assets", isDirectory: true)

        do {
            try fileManager.createDirectory(at: to, withIntermediateDirectories: true)
            let files = try fileManager.contentsOfDirectory(
                at: from, includingPropertiesForKeys: nil
            )
            for source in files {
                let dest = to.appendingPathComponent(source.lastPathComponent)
                if !fileManager.fileExists(atPath: dest.path) {
                    try fileManager.moveItem(at: source, to: dest)
                }
            }
            // Best-effort cleanup of the now-empty temp tree.
            try? fileManager.removeItem(at: temporaryDirectory)
        } catch {
            throw AssetsManagerError.migrationFailed(String(describing: error))
        }
    }

    /// Where assets live right now — the doc's adjacent `assets/` if the
    /// document has a fileURL, otherwise this manager's temp staging dir.
    private func currentAssetsDirectory() -> URL {
        if let docDir = documentDirectoryProvider() {
            return docDir.appendingPathComponent("assets", isDirectory: true)
        }
        return temporaryDirectory.appendingPathComponent("assets", isDirectory: true)
    }

    /// Best-guess extension for a MIME type. Defaults to `bin` for unknowns
    /// so the file at least gets stored — caller can still recover content.
    static func filenameExtension(forMimeType mimeType: String) -> String {
        switch mimeType.lowercased() {
        case "image/png": return "png"
        case "image/jpeg", "image/jpg": return "jpg"
        case "image/gif": return "gif"
        case "image/webp": return "webp"
        case "image/heic", "image/heif": return "heic"
        case "image/svg+xml", "image/svg": return "svg"
        case "image/tiff": return "tiff"
        case "image/bmp": return "bmp"
        // Local video (#88, ADR-0009). Only WebKit-inline-playable containers
        // reach here — NSOpenPanel filters the picker to these types.
        case "video/mp4": return "mp4"
        case "video/quicktime": return "mov"
        case "video/x-m4v": return "m4v"
        case "video/webm": return "webm"
        default: return "bin"
        }
    }
}

private extension SHA256.Digest {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
