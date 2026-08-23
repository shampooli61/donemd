import XCTest
@testable import donemd

final class AssetsManagerTests: XCTestCase {

    /// Each test gets its own temp working directory that simulates the
    /// containing document's folder when needed.
    private var sandbox: URL!

    override func setUpWithError() throws {
        sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("donemd-assets-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let sandbox = sandbox {
            try? FileManager.default.removeItem(at: sandbox)
        }
    }

    // MARK: importImage

    func testNamedDocImportWritesFileToAdjacentAssets() throws {
        let manager = AssetsManager(documentDirectoryProvider: { [sandbox] in sandbox })

        let bytes = sampleBytes("hello world")
        let imported = try manager.importImage(data: bytes, mimeType: "image/png")

        // Expect: <sandbox>/assets/<sha256>.png
        let assetsDir = sandbox.appendingPathComponent("assets")
        let target = assetsDir.appendingPathComponent(imported.storageFilename)
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
        XCTAssertEqual(imported.markdownPath, "./assets/\(imported.storageFilename)")
        XCTAssertEqual(imported.assetURL.absoluteString, "donemd-asset://\(imported.storageFilename)")
        XCTAssertTrue(imported.storageFilename.hasSuffix(".png"))
        XCTAssertEqual(imported.storageFilename.split(separator: ".").first?.count, 64) // 32-byte sha256 hex
    }

    func testIdenticalBytesReuseExistingFile() throws {
        let manager = AssetsManager(documentDirectoryProvider: { [sandbox] in sandbox })

        let bytes = sampleBytes("dedup me")
        let first = try manager.importImage(data: bytes, mimeType: "image/png")
        let writtenAt = sandbox.appendingPathComponent("assets/\(first.storageFilename)")
        let firstAttrs = try FileManager.default.attributesOfItem(atPath: writtenAt.path)

        // Sleep enough for mtime to differ if rewritten (HFS/APFS resolution).
        Thread.sleep(forTimeInterval: 0.05)

        let second = try manager.importImage(data: bytes, mimeType: "image/png")
        XCTAssertEqual(first.storageFilename, second.storageFilename)
        let secondAttrs = try FileManager.default.attributesOfItem(atPath: writtenAt.path)
        // Modification date unchanged → file was not rewritten.
        XCTAssertEqual(
            firstAttrs[.modificationDate] as? Date,
            secondAttrs[.modificationDate] as? Date
        )
    }

    func testCreatesAssetsDirectoryOnDemand() throws {
        let manager = AssetsManager(documentDirectoryProvider: { [sandbox] in sandbox })
        XCTAssertFalse(FileManager.default.fileExists(atPath: sandbox.appendingPathComponent("assets").path))

        _ = try manager.importImage(data: sampleBytes("x"), mimeType: "image/png")

        XCTAssertTrue(FileManager.default.fileExists(atPath: sandbox.appendingPathComponent("assets").path))
    }

    func testUntitledDocImportWritesToTempDirectory() throws {
        let manager = AssetsManager(documentDirectoryProvider: { nil })

        let imported = try manager.importImage(data: sampleBytes("untitled"), mimeType: "image/jpeg")
        XCTAssertTrue(imported.storageFilename.hasSuffix(".jpg"))

        // Should not have written anything inside our test sandbox (the
        // sandbox is the would-be doc directory; untitled docs use Caches).
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: sandbox.appendingPathComponent("assets").path)
        )

        // The imported file is somewhere on disk and findable via the manager.
        XCTAssertNotNil(manager.storedFileURL(forFilename: imported.storageFilename))
    }

    // MARK: importVideo

    func testImportVideoWritesToAdjacentAssetsWithVideoExtension() throws {
        let manager = AssetsManager(documentDirectoryProvider: { [sandbox] in sandbox })

        let imported = try manager.importVideo(data: sampleBytes("fake mp4 bytes"), mimeType: "video/mp4")

        let target = sandbox.appendingPathComponent("assets/\(imported.storageFilename)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
        XCTAssertTrue(imported.storageFilename.hasSuffix(".mp4"))
        XCTAssertEqual(imported.markdownPath, "./assets/\(imported.storageFilename)")
        XCTAssertEqual(imported.assetURL.absoluteString, "donemd-asset://\(imported.storageFilename)")
        XCTAssertEqual(imported.storageFilename.split(separator: ".").first?.count, 64)
    }

    func testImportVideoDedupsIdenticalBytes() throws {
        let manager = AssetsManager(documentDirectoryProvider: { [sandbox] in sandbox })
        let bytes = sampleBytes("dedup video")
        let first = try manager.importVideo(data: bytes, mimeType: "video/quicktime")
        let second = try manager.importVideo(data: bytes, mimeType: "video/quicktime")
        XCTAssertEqual(first.storageFilename, second.storageFilename)
        XCTAssertTrue(first.storageFilename.hasSuffix(".mov"))
    }

    // MARK: storedFileURL

    func testStoredFileURLReturnsNilForUnknownFilename() {
        let manager = AssetsManager(documentDirectoryProvider: { [sandbox] in sandbox })
        XCTAssertNil(manager.storedFileURL(forFilename: "does-not-exist.png"))
    }

    // MARK: migrateAssets

    func testMigrateAssetsMovesFromTempToDocDirectory() throws {
        // Start untitled — assets land in temp.
        let manager = AssetsManager(documentDirectoryProvider: { nil })
        let imported = try manager.importImage(data: sampleBytes("migrate"), mimeType: "image/png")
        XCTAssertTrue(FileManager.default.fileExists(atPath: manager.storedFileURL(forFilename: imported.storageFilename)!.path))
        let originalLocation = manager.storedFileURL(forFilename: imported.storageFilename)!

        // Pretend the user just chose Save As → sandbox.
        try manager.migrateAssets(to: sandbox)

        let migrated = sandbox.appendingPathComponent("assets/\(imported.storageFilename)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: migrated.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: originalLocation.path))
    }

    func testMigrateAssetsIsNoOpWhenTempIsEmpty() throws {
        let manager = AssetsManager(documentDirectoryProvider: { [sandbox] in sandbox })
        // No imports — nothing to migrate. Should not throw.
        XCTAssertNoThrow(try manager.migrateAssets(to: sandbox))
    }

    // MARK: filenameExtension

    func testMimeTypeToExtensionMapping() {
        let cases: [(String, String)] = [
            ("image/png", "png"),
            ("IMAGE/PNG", "png"),
            ("image/jpeg", "jpg"),
            ("image/jpg", "jpg"),
            ("image/gif", "gif"),
            ("image/webp", "webp"),
            ("image/heic", "heic"),
            ("image/heif", "heic"),
            ("image/svg+xml", "svg"),
            ("application/octet-stream", "bin"),
            ("", "bin"),
        ]
        for (mime, ext) in cases {
            XCTAssertEqual(
                AssetsManager.filenameExtension(forMimeType: mime),
                ext,
                "mime: \(mime)"
            )
        }
    }

    // MARK: helpers

    private func sampleBytes(_ s: String) -> Data {
        Data(s.utf8)
    }
}
