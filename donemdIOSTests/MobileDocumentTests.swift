import XCTest
@testable import donemdIOS

@MainActor
final class MobileDocumentTests: XCTestCase {
    func testEditingAndReopeningPreservesMetadataAndBody() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("note.md")
        try "---\ntitle: 我的文档\n---\n\n# 初稿\n".write(to: url, atomically: true, encoding: .utf8)
        let document = MobileDocument(fileURL: url)
        let opened = await document.open()
        XCTAssertTrue(opened)
        document.acceptNormalization()
        document.replaceBody(MarkdownEngine.parse(markdown: "# 修改\n\n- [x] 完成\n"))
        let saved = await document.saveNow()
        XCTAssertTrue(saved)
        _ = await document.close()
        let reopened = MobileDocument(fileURL: url)
        let reopenedOK = await reopened.open()
        XCTAssertTrue(reopenedOK)
        XCTAssertTrue(reopened.source.contains("title: 我的文档"))
        XCTAssertTrue(reopened.source.contains("# 修改"))
        XCTAssertTrue(reopened.source.contains("- [x] 完成"))
        _ = await reopened.close()
    }
    func testAttachmentReaderRejectsPathsOutsideAssets() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("assets"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data("private".utf8).write(to: folder.appendingPathComponent("outside.txt"))
        let manager = AssetsManager(documentDirectoryProvider: { folder })
        XCTAssertNil(manager.storedFileURL(forFilename: "../outside.txt"))
    }

    func testExternalReloadPreservesUnsavedDraftForRecovery() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".md")
        let document = MobileDocument(fileURL: url)
        try document.load(fromContents: Data("# Original\n".utf8), ofType: nil)
        document.acceptNormalization()
        document.replaceBody(MarkdownEngine.parse(markdown: "# Local edit\n"))
        try document.load(fromContents: Data("# External edit\n".utf8), ofType: nil)
        XCTAssertTrue(document.source.contains("External edit"))
        XCTAssertTrue(document.recoveryVersions.contains { $0.markdown.contains("Local edit") })
    }

    func testReadOnlyOpenNeverNormalizesAndEditRequiresConsent() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".md")
        let original = "# Heading\n\ntext   \n\n\n"
        try original.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        let document = MobileDocument(fileURL: url)
        _ = await document.open()
        _ = await document.saveNow()
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), original)
        document.replaceBody(MarkdownEngine.parse(markdown: "# Changed\n"))
        XCTAssertTrue(document.needsNormalization)
        let saved = await document.saveNow()
        XCTAssertFalse(saved)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), original)
        document.acceptNormalization()
        _ = await document.saveNow()
        _ = await document.close()
    }

    func testUnobservedDiskEditStopsOverwrite() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".md")
        try "# Original\n".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        let document = MobileDocument(fileURL: url)
        _ = await document.open()
        document.acceptNormalization()
        document.replaceBody(MarkdownEngine.parse(markdown: "# Local\n"))
        try "# External\n".write(to: url, atomically: true, encoding: .utf8)
        let saved = await document.saveNow()
        XCTAssertFalse(saved)
        XCTAssertTrue(document.conflict)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "# External\n")
        await document.preserveConflictsAndReload()
        XCTAssertFalse(document.conflict)
        _ = await document.close()
    }

    func testStaleEditorMessageCannotOverwriteReloadedDocument() throws {
        let document = MobileDocument(fileURL: URL(fileURLWithPath: "/tmp/stale-test.md"))
        try document.load(fromContents: Data("# Old\n".utf8), ofType: nil)
        let oldRevision = document.revision
        try document.load(fromContents: Data("# New remote version\n".utf8), ofType: nil)
        let accepted = document.applyEditorSnapshot(MarkdownEngine.parse(markdown: "# Stale local message\n"), revision: oldRevision)
        XCTAssertFalse(accepted)
        XCTAssertEqual(document.source, "# New remote version\n")
    }

}
