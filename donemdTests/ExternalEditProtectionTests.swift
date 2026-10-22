import XCTest
@testable import donemd

final class ExternalEditProtectionTests: XCTestCase {
    func testBothVersionsArePreservedWithoutChangingOriginal() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("note.md")
        try "disk edit".write(to: url, atomically: true, encoding: .utf8)
        let copies = try DocumentRecoveryStore.protectExternalEdit(local: "local edit", for: url)
        XCTAssertEqual(try Set(copies.map { try String(contentsOf: $0, encoding: .utf8) }), Set(["local edit", "disk edit"]))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "disk edit")
        XCTAssertTrue(copies.allSatisfy { $0.deletingLastPathComponent().standardizedFileURL.path == folder.standardizedFileURL.path })
    }
}
