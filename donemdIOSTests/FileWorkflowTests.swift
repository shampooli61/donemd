import XCTest
import ZIPFoundation
@testable import donemdIOS

@MainActor
final class FileWorkflowTests: XCTestCase {
    func testRenameDoesNotOverwriteAndCopyKeepsOriginal() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let a = folder.appendingPathComponent("a.md"), b = folder.appendingPathComponent("b.md")
        try Data("A".utf8).write(to: a); try Data("B".utf8).write(to: b)
        let store = FolderStore()
        XCTAssertThrowsError(try store.rename(a, to: "b"))
        XCTAssertThrowsError(try store.rename(a, to: "../escape"))
        XCTAssertEqual(try String(contentsOf: b, encoding: .utf8), "B")
        let copied = try store.duplicate(a)
        XCTAssertEqual(try Data(contentsOf: copied), try Data(contentsOf: a))
        XCTAssertNotEqual(copied, a)
    }
    func testBundledShareIncludesReferencedMediaAndRejectsMissingMedia() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let manager = AssetsManager(documentDirectoryProvider: { folder })
        let image = try manager.importImage(data: Data([1, 2, 3]), mimeType: "image/png")
        let source = "![图片](" + image.markdownPath + ")\n"
        let archiveURL = try DocumentShare.prepare(source: source, name: "note.md", assets: manager, bundled: true)
        defer { try? FileManager.default.removeItem(at: archiveURL.deletingLastPathComponent()) }
        let archive = try Archive(url: archiveURL, accessMode: .read)
        XCTAssertNotNil(archive["note.md"])
        XCTAssertNotNil(archive["assets/" + image.storageFilename])
        XCTAssertThrowsError(try DocumentShare.prepare(source: "![missing](./assets/missing.png)", name: "note.md", assets: manager, bundled: true))
    }

    func testStreamingMediaImportMatchesByteImport() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("test.mp4")
        let bytes = Data(repeating: 42, count: 2_100_000)
        try bytes.write(to: file)
        let manager = AssetsManager(documentDirectoryProvider: { folder })
        let stream = try manager.importFile(at: file, mimeType: "video/mp4")
        let memory = try manager.importVideo(data: bytes, mimeType: "video/mp4")
        XCTAssertEqual(stream, memory)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(manager.storedFileURL(forFilename: stream.storageFilename))), bytes)
    }

}
