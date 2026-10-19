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
}
