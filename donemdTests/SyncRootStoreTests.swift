import XCTest
@testable import donemd

final class SyncRootStoreTests: XCTestCase {

    private var tempDir: URL!
    private var storeURL: URL!

    override func setUpWithError() throws {
        tempDir = try makeTempDir()
        storeURL = tempDir.appendingPathComponent("sync-roots.json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: list

    func testListEmptyOnFreshStore() {
        let store = SyncRootStore(storeURL: storeURL)
        XCTAssertEqual(store.list(), [])
    }

    // MARK: add

    func testAddPersistsAndReloads() throws {
        let dir = try makeSubDir("FeishuArchive")

        let store1 = SyncRootStore(storeURL: storeURL)
        try store1.add(dir)
        XCTAssertEqual(store1.list().map(\.path), [dir.standardizedFileURL.path])

        let store2 = SyncRootStore(storeURL: storeURL)
        XCTAssertEqual(store2.list().map(\.path), [dir.standardizedFileURL.path])
    }

    func testAddRejectsNonDirectory() {
        let bogus = tempDir.appendingPathComponent("does-not-exist")
        let store = SyncRootStore(storeURL: storeURL)
        XCTAssertThrowsError(try store.add(bogus)) { error in
            guard let err = error as? SyncRootStore.StoreError else {
                XCTFail("Expected StoreError, got \(error)")
                return
            }
            XCTAssertEqual(err, .notADirectory(path: bogus.standardizedFileURL.path))
        }
    }

    func testAddIsIdempotent() throws {
        let dir = try makeSubDir("Work")
        let store = SyncRootStore(storeURL: storeURL)
        try store.add(dir)
        try store.add(dir) // second call should no-op
        XCTAssertEqual(store.list().count, 1)
    }

    func testAddCanonicalizesPaths() throws {
        let dir = try makeSubDir("Work")
        let trailingSlash = URL(fileURLWithPath: dir.path + "/")
        let store = SyncRootStore(storeURL: storeURL)
        try store.add(dir)
        try store.add(trailingSlash)
        XCTAssertEqual(store.list().count, 1)
    }

    // MARK: remove

    func testRemoveDropsAndPersists() throws {
        let dirA = try makeSubDir("A")
        let dirB = try makeSubDir("B")
        let store = SyncRootStore(storeURL: storeURL)
        try store.add(dirA)
        try store.add(dirB)
        store.remove(dirA)
        XCTAssertEqual(store.list().count, 1)
        XCTAssertEqual(store.list().first?.path, dirB.standardizedFileURL.path)

        let reload = SyncRootStore(storeURL: storeURL)
        XCTAssertEqual(reload.list().count, 1)
        XCTAssertEqual(reload.list().first?.path, dirB.standardizedFileURL.path)
    }

    func testRemoveNonMemberIsNoOp() throws {
        let dir = try makeSubDir("Real")
        let bogus = tempDir.appendingPathComponent("Phantom")
        let store = SyncRootStore(storeURL: storeURL)
        try store.add(dir)
        store.remove(bogus)
        XCTAssertEqual(store.list().count, 1)
    }

    // MARK: reorder

    func testReorderChangesPriority() throws {
        let dirA = try makeSubDir("A")
        let dirB = try makeSubDir("B")
        let dirC = try makeSubDir("C")
        let store = SyncRootStore(storeURL: storeURL)
        try store.add(dirA)
        try store.add(dirB)
        try store.add(dirC)

        let newOrder = [dirC, dirA, dirB]
        store.reorder(newOrder)
        XCTAssertEqual(
            store.list().map(\.path),
            newOrder.map { $0.standardizedFileURL.path }
        )
    }

    func testReorderRejectsNonPermutation() throws {
        let dirA = try makeSubDir("A")
        let dirB = try makeSubDir("B")
        let store = SyncRootStore(storeURL: storeURL)
        try store.add(dirA)
        try store.add(dirB)

        // Different set — silently ignored.
        store.reorder([dirA])
        XCTAssertEqual(store.list().count, 2)
    }

    // MARK: helpers

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default
            .temporaryDirectory
            .appendingPathComponent("SyncRootStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeSubDir(_ name: String) throws -> URL {
        let dir = tempDir.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
