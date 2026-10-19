import XCTest
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
}
