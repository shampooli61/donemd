import XCTest
@testable import donemd

/// 启动会话恢复 (story 47 revision) — OpenSessionStore + the pure decision
/// helpers. Runs against a temp-dir store URL (same pattern as
/// SyncRootStoreTests) so nothing touches the real session file.
final class OpenSessionStoreTests: XCTestCase {

    private var tempDir: URL!
    private var storeURL: URL!

    override func setUpWithError() throws {
        tempDir = try makeTempDir()
        storeURL = tempDir.appendingPathComponent("open-session.json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - store roundtrip

    func testEmptyOnFreshStore() {
        let store = OpenSessionStore(storeURL: storeURL)
        XCTAssertEqual(store.recordedURLs(), [])
    }

    func testNoteOpenedPersistsAndReloads() {
        let a = URL(fileURLWithPath: "/tmp/a.md")
        let b = URL(fileURLWithPath: "/tmp/b.md")
        let store1 = OpenSessionStore(storeURL: storeURL)
        store1.note(opened: a)
        store1.note(opened: b)
        XCTAssertEqual(store1.recordedURLs().map(\.path), ["/tmp/a.md", "/tmp/b.md"])

        // A fresh instance over the same file sees the persisted order.
        let store2 = OpenSessionStore(storeURL: storeURL)
        XCTAssertEqual(store2.recordedURLs().map(\.path), ["/tmp/a.md", "/tmp/b.md"])
    }

    func testNoteOpenedIsIdempotent() {
        let a = URL(fileURLWithPath: "/tmp/a.md")
        let store = OpenSessionStore(storeURL: storeURL)
        store.note(opened: a)
        store.note(opened: a)
        XCTAssertEqual(store.recordedURLs().map(\.path), ["/tmp/a.md"])
    }

    func testNoteOpenedStandardizesPath() {
        let store = OpenSessionStore(storeURL: storeURL)
        store.note(opened: URL(fileURLWithPath: "/tmp/sub/../a.md"))
        // Standardized form collapses the `..`.
        XCTAssertEqual(store.recordedURLs().map(\.path), ["/tmp/a.md"])
    }

    func testNoteClosedRemoves() {
        let a = URL(fileURLWithPath: "/tmp/a.md")
        let b = URL(fileURLWithPath: "/tmp/b.md")
        let store = OpenSessionStore(storeURL: storeURL)
        store.note(opened: a)
        store.note(opened: b)
        store.note(closed: a)
        XCTAssertEqual(store.recordedURLs().map(\.path), ["/tmp/b.md"])
    }

    func testNoteClosedNonMemberIsNoop() {
        let a = URL(fileURLWithPath: "/tmp/a.md")
        let store = OpenSessionStore(storeURL: storeURL)
        store.note(opened: a)
        store.note(closed: URL(fileURLWithPath: "/tmp/other.md"))
        XCTAssertEqual(store.recordedURLs().map(\.path), ["/tmp/a.md"])
    }

    func testReplaceDedupsAndPreservesOrder() {
        let store = OpenSessionStore(storeURL: storeURL)
        store.replace(with: [
            URL(fileURLWithPath: "/tmp/a.md"),
            URL(fileURLWithPath: "/tmp/b.md"),
            URL(fileURLWithPath: "/tmp/a.md"),   // dup
        ])
        XCTAssertEqual(store.recordedURLs().map(\.path), ["/tmp/a.md", "/tmp/b.md"])
    }

    func testCorruptJSONLoadsEmpty() throws {
        try Data("{ not valid json".utf8).write(to: storeURL)
        let store = OpenSessionStore(storeURL: storeURL)
        XCTAssertEqual(store.recordedURLs(), [])
    }

    // MARK: - existingURLs (pure filter)

    func testExistingURLsFiltersMissingPreservingOrder() throws {
        let present1 = try makeFile("keep1.md")
        let present2 = try makeFile("keep2.md")
        let missing = tempDir.appendingPathComponent("gone.md")
        let result = OpenSessionStore.existingURLs(from: [present1, missing, present2])
        XCTAssertEqual(result.map(\.path), [present1.path, present2.path])
    }

    func testExistingURLsAllMissingReturnsEmpty() {
        let m1 = tempDir.appendingPathComponent("gone1.md")
        let m2 = tempDir.appendingPathComponent("gone2.md")
        XCTAssertEqual(OpenSessionStore.existingURLs(from: [m1, m2]), [])
    }

    // MARK: - SessionRestorePlan.decide (pure branch)

    func testDecideEmptyRecordedOpensBlank() {
        XCTAssertEqual(SessionRestorePlan.decide(recorded: [], existing: []), .openBlank)
    }

    func testDecideAllMissingOpensBlank() {
        // Recorded had entries but none exist any more.
        let recorded = [URL(fileURLWithPath: "/tmp/gone.md")]
        XCTAssertEqual(SessionRestorePlan.decide(recorded: recorded, existing: []), .openBlank)
    }

    func testDecideSomeValidRestoresExistingOnly() {
        let a = URL(fileURLWithPath: "/tmp/a.md")
        let recorded = [a, URL(fileURLWithPath: "/tmp/gone.md")]
        XCTAssertEqual(
            SessionRestorePlan.decide(recorded: recorded, existing: [a]),
            .restore([a])
        )
    }

    // MARK: - helpers

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenSessionStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeFile(_ name: String) throws -> URL {
        let url = tempDir.appendingPathComponent(name)
        try Data("# test".utf8).write(to: url)
        return url
    }
}
