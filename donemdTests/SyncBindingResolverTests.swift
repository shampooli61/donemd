import XCTest
@testable import donemd

final class SyncBindingResolverTests: XCTestCase {

    private var tempDir: URL!
    private var rootA: URL!
    private var rootB: URL!

    override func setUpWithError() throws {
        tempDir = try makeTempDir()
        rootA = try makeSubDir("RootA")
        rootB = try makeSubDir("RootB")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: openExisting

    func testResolveOpenExistingOnSingleHit() async throws {
        let token = "doxcnSingleHit123"
        try writeMD(at: rootA.appendingPathComponent("a.md"), docToken: token)
        let scanner = SyncRootScanner(logger: { _ in })
        await scanner.start([rootA, rootB])
        let resolver = SyncBindingResolver(scanner: scanner)

        let urlString = "https://feishu.cn/docx/\(token)"
        let parsed = FeishuURLDetector.extract(urlString)!
        let resolution = await resolver.resolve(parsed)

        switch resolution {
        case .openExisting(let url):
            XCTAssertEqual(url.lastPathComponent, "a.md")
        default:
            XCTFail("expected .openExisting, got \(resolution)")
        }
    }

    // MARK: ambiguous

    func testResolveAmbiguousWhenMultipleRootsClaimToken() async throws {
        let token = "doxcnAmbiguousAB1"
        try writeMD(at: rootA.appendingPathComponent("a.md"), docToken: token)
        try writeMD(at: rootB.appendingPathComponent("b.md"), docToken: token)
        let scanner = SyncRootScanner(logger: { _ in })
        await scanner.start([rootA, rootB])
        let resolver = SyncBindingResolver(scanner: scanner)

        let parsed = FeishuURLDetector.extract("https://feishu.cn/docx/\(token)")!
        let resolution = await resolver.resolve(parsed)

        switch resolution {
        case .ambiguous(let urls):
            XCTAssertEqual(urls.count, 2)
            XCTAssertEqual(urls[0].lastPathComponent, "a.md") // higher priority first
            XCTAssertEqual(urls[1].lastPathComponent, "b.md")
        default:
            XCTFail("expected .ambiguous, got \(resolution)")
        }
    }

    // MARK: createNew

    func testResolveCreateNewWhenIndexMisses() async throws {
        // Index has something else, so no false positive on empty index.
        try writeMD(at: rootA.appendingPathComponent("other.md"),
                    docToken: "doxcnSomethingElse")
        let scanner = SyncRootScanner(logger: { _ in })
        await scanner.start([rootA])
        let resolver = SyncBindingResolver(scanner: scanner)

        let parsed = FeishuURLDetector.extract("https://feishu.cn/docx/doxcnNotIndexed999")!
        let resolution = await resolver.resolve(parsed)

        switch resolution {
        case .createNew(let token):
            XCTAssertEqual(token.rawValue, "doxcnNotIndexed999")
        default:
            XCTFail("expected .createNew, got \(resolution)")
        }
    }

    // MARK: requiresAPIResolution

    func testResolveWikiYieldsRequiresAPIResolution() async {
        let scanner = SyncRootScanner(logger: { _ in })
        await scanner.start([])
        let resolver = SyncBindingResolver(scanner: scanner)

        let parsed = FeishuURLDetector.extract("https://feishu.cn/wiki/wikcnNodeToken99")!
        let resolution = await resolver.resolve(parsed)

        switch resolution {
        case .requiresAPIResolution(let url):
            XCTAssertEqual(url.kind, .wiki)
            XCTAssertEqual(url.token, "wikcnNodeToken99")
        default:
            XCTFail("expected .requiresAPIResolution, got \(resolution)")
        }
    }

    func testResolveShortLinkYieldsRequiresAPIResolution() async {
        let scanner = SyncRootScanner(logger: { _ in })
        await scanner.start([])
        let resolver = SyncBindingResolver(scanner: scanner)

        let parsed = FeishuURLDetector.extract("https://feishu.cn/X3kAbCdEfG1")!
        let resolution = await resolver.resolve(parsed)

        switch resolution {
        case .requiresAPIResolution(let url):
            XCTAssertEqual(url.kind, .short)
            XCTAssertEqual(url.token, "X3kAbCdEfG1")
        default:
            XCTFail("expected .requiresAPIResolution, got \(resolution)")
        }
    }

    // MARK: helpers

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default
            .temporaryDirectory
            .appendingPathComponent("SyncBindingResolverTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeSubDir(_ name: String) throws -> URL {
        let dir = tempDir.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func writeMD(at url: URL, docToken: String) throws {
        let content = """
        ---
        feishu:
          doc_token: \(docToken)
        ---
        body
        """
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try content.write(to: url, atomically: true, encoding: .utf8)
    }
}
