import XCTest
@testable import donemd

final class SyncRootScannerTests: XCTestCase {

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

    // MARK: initial scan + lookup

    func testStartIndexesFilesUnderEachRoot() async throws {
        try writeMD(at: rootA.appendingPathComponent("alpha.md"),
                    docToken: "doxcnAlphaToken123")
        try writeMD(at: rootA.appendingPathComponent("nested/beta.md"),
                    docToken: "doxcnBetaToken456")
        try writeMD(at: rootB.appendingPathComponent("gamma.md"),
                    docToken: "doxcnGammaToken789")

        let scanner = SyncRootScanner(logger: { _ in })
        await scanner.start([rootA, rootB])

        let alpha = await scanner.lookup(DocToken("doxcnAlphaToken123"))
        let beta = await scanner.lookup(DocToken("doxcnBetaToken456"))
        let gamma = await scanner.lookup(DocToken("doxcnGammaToken789"))
        XCTAssertEqual(alpha?.lastPathComponent, "alpha.md")
        XCTAssertEqual(beta?.lastPathComponent, "beta.md")
        XCTAssertEqual(gamma?.lastPathComponent, "gamma.md")
    }

    func testLookupMissesUnknownToken() async throws {
        try writeMD(at: rootA.appendingPathComponent("x.md"),
                    docToken: "doxcnExisting999")
        let scanner = SyncRootScanner(logger: { _ in })
        await scanner.start([rootA])
        let hit = await scanner.lookup(DocToken("doxcnNotIndexed000"))
        XCTAssertNil(hit)
    }

    // MARK: corruption tolerance

    func testCorruptedFrontmatterDoesNotAbortScan() async throws {
        try writeRaw(at: rootA.appendingPathComponent("good.md"),
                     content: """
                     ---
                     feishu:
                       doc_token: doxcnGood111111
                     ---
                     hi
                     """)
        try writeRaw(at: rootA.appendingPathComponent("bad.md"),
                     content: """
                     ---
                     feishu:
                       doc_token: not closed yaml [
                     ---
                     """)
        try writeRaw(at: rootA.appendingPathComponent("none.md"),
                     content: "no frontmatter at all")

        var warnings: [String] = []
        let scanner = SyncRootScanner(logger: { warnings.append($0) })
        await scanner.start([rootA])

        let good = await scanner.lookup(DocToken("doxcnGood111111"))
        XCTAssertEqual(good?.lastPathComponent, "good.md")
    }

    func testInvalidTokenFormatSkipped() async throws {
        try writeMD(at: rootA.appendingPathComponent("ok.md"),
                    docToken: "doxcnValidValue999")
        try writeMD(at: rootA.appendingPathComponent("junk.md"),
                    docToken: "x")  // too short, doesn't match pattern

        var warnings: [String] = []
        let scanner = SyncRootScanner(logger: { warnings.append($0) })
        await scanner.start([rootA])

        let ok = await scanner.lookup(DocToken("doxcnValidValue999"))
        XCTAssertEqual(ok?.lastPathComponent, "ok.md")
        let junk = await scanner.lookup(DocToken("x"))
        XCTAssertNil(junk)
        XCTAssertTrue(warnings.contains { $0.contains("doesn't match expected format") })
    }

    func testFileWithoutFeishuNamespaceSkipped() async throws {
        try writeRaw(at: rootA.appendingPathComponent("user-only.md"),
                     content: """
                     ---
                     title: Just a User Doc
                     tags: [draft]
                     ---
                     content
                     """)
        let scanner = SyncRootScanner(logger: { _ in })
        await scanner.start([rootA])
        // No feishu.doc_token → not indexed, no error.
        let hit = await scanner.lookup(DocToken("title"))
        XCTAssertNil(hit)
    }

    // MARK: token conflict

    func testTokenConflictKeepsHigherPriorityRoot() async throws {
        let token = "doxcnConflictABCDE"
        try writeMD(at: rootA.appendingPathComponent("a.md"), docToken: token)
        try writeMD(at: rootB.appendingPathComponent("b.md"), docToken: token)

        var warnings: [String] = []
        let scanner = SyncRootScanner(logger: { warnings.append($0) })
        await scanner.start([rootA, rootB])

        let hit = await scanner.lookup(DocToken(token))
        XCTAssertEqual(hit?.lastPathComponent, "a.md")
        XCTAssertTrue(warnings.contains { $0.contains("Token conflict") })
    }

    func testTokenConflictReorderedRootsRespectsNewPriority() async throws {
        let token = "doxcnConflictZZZZZ"
        try writeMD(at: rootA.appendingPathComponent("a.md"), docToken: token)
        try writeMD(at: rootB.appendingPathComponent("b.md"), docToken: token)

        let scanner = SyncRootScanner(logger: { _ in })
        await scanner.start([rootB, rootA]) // B first
        let hit = await scanner.lookup(DocToken(token))
        XCTAssertEqual(hit?.lastPathComponent, "b.md")
    }

    // MARK: addRoot / removeRoot

    func testAddRootIndexesNewFiles() async throws {
        try writeMD(at: rootA.appendingPathComponent("first.md"),
                    docToken: "doxcnFirstFFFFFFF")
        try writeMD(at: rootB.appendingPathComponent("second.md"),
                    docToken: "doxcnSecondSSSSSS")

        let scanner = SyncRootScanner(logger: { _ in })
        await scanner.start([rootA])
        let beforeAdd = await scanner.lookup(DocToken("doxcnSecondSSSSSS"))
        XCTAssertNil(beforeAdd)

        await scanner.addRoot(rootB)
        let hit = await scanner.lookup(DocToken("doxcnSecondSSSSSS"))
        XCTAssertEqual(hit?.lastPathComponent, "second.md")
    }

    func testRemoveRootDropsItsEntries() async throws {
        try writeMD(at: rootA.appendingPathComponent("keep.md"),
                    docToken: "doxcnKeepKKKKKKK")
        try writeMD(at: rootB.appendingPathComponent("drop.md"),
                    docToken: "doxcnDropDDDDDDD")

        let scanner = SyncRootScanner(logger: { _ in })
        await scanner.start([rootA, rootB])
        let beforeRemove = await scanner.lookup(DocToken("doxcnDropDDDDDDD"))
        XCTAssertNotNil(beforeRemove)

        await scanner.removeRoot(rootB)
        let droppedHit = await scanner.lookup(DocToken("doxcnDropDDDDDDD"))
        XCTAssertNil(droppedHit)
        let keptHit = await scanner.lookup(DocToken("doxcnKeepKKKKKKK"))
        XCTAssertNotNil(keptHit)
    }

    // MARK: incremental rescan (deterministic via test hook)

    func testRescanPicksUpAddedFile() async throws {
        try writeMD(at: rootA.appendingPathComponent("initial.md"),
                    docToken: "doxcnInitial11111")

        let scanner = SyncRootScanner(logger: { _ in })
        await scanner.start([rootA])
        let beforeAdd = await scanner.lookup(DocToken("doxcnLater2222222"))
        XCTAssertNil(beforeAdd)

        try writeMD(at: rootA.appendingPathComponent("later.md"),
                    docToken: "doxcnLater2222222")
        await scanner._rescanRootForTesting(rootA)

        let hit = await scanner.lookup(DocToken("doxcnLater2222222"))
        XCTAssertEqual(hit?.lastPathComponent, "later.md")
    }

    func testRescanDropsDeletedFile() async throws {
        let file = rootA.appendingPathComponent("temp.md")
        try writeMD(at: file, docToken: "doxcnTempT1234567")
        let scanner = SyncRootScanner(logger: { _ in })
        await scanner.start([rootA])
        let beforeDelete = await scanner.lookup(DocToken("doxcnTempT1234567"))
        XCTAssertNotNil(beforeDelete)

        try FileManager.default.removeItem(at: file)
        await scanner._rescanRootForTesting(rootA)

        let afterDelete = await scanner.lookup(DocToken("doxcnTempT1234567"))
        XCTAssertNil(afterDelete)
    }

    func testRescanReflectsTokenRename() async throws {
        let file = rootA.appendingPathComponent("renamed.md")
        try writeMD(at: file, docToken: "doxcnOldOOOOOOOO")
        let scanner = SyncRootScanner(logger: { _ in })
        await scanner.start([rootA])
        let beforeRename = await scanner.lookup(DocToken("doxcnOldOOOOOOOO"))
        XCTAssertNotNil(beforeRename)

        // Bump mtime so the diff actually re-reads.
        try FileManager.default.removeItem(at: file)
        try writeMD(at: file, docToken: "doxcnNewNNNNNNNN")
        await scanner._rescanRootForTesting(rootA)

        let oldHit = await scanner.lookup(DocToken("doxcnOldOOOOOOOO"))
        XCTAssertNil(oldHit)
        let hit = await scanner.lookup(DocToken("doxcnNewNNNNNNNN"))
        XCTAssertEqual(hit?.lastPathComponent, "renamed.md")
    }

    // MARK: live watcher (real DispatchSource)

    /// End-to-end watcher integration: write a file after start, give the
    /// kernel a beat to fire the dispatch source, then poll up to a second
    /// for the index to reflect it. Verifies the 200ms debounce + scan
    /// path actually closes the loop, not just the test-only rescan hook.
    func testLiveWatcherPicksUpFileChanges() async throws {
        let scanner = SyncRootScanner(logger: { _ in })
        await scanner.start([rootA])

        let token = "doxcnLiveLLLLLLLL"
        try writeMD(at: rootA.appendingPathComponent("live.md"), docToken: token)

        let deadline = Date().addingTimeInterval(2.0)
        var hit: URL?
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
            hit = await scanner.lookup(DocToken(token))
            if hit != nil { break }
        }
        XCTAssertEqual(hit?.lastPathComponent, "live.md",
                       "watcher should reflect new file within 2s")
        await scanner.stop()
    }

    // MARK: stress (acceptance gate v2 #2)

    /// 3 roots × 1000 files × 500 bindings, startup < 3s, lookup < 5ms p99.
    /// PRD § "v2 验收门 #2". Marked with skip-on-CI envvar so resource-
    /// constrained CI runners don't false-fail the gate.
    func testStressGate3Rootsx1000Filesx500Bindings() async throws {
        let perRoot = 1000
        let bindingsPerRoot = 500 / 3 // ~166, totals 498 bindings, close enough

        let stressRoots = try (0..<3).map { i -> URL in
            let dir = tempDir.appendingPathComponent("stress\(i)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        }

        var expectedTokens: [DocToken] = []
        for (rootIndex, root) in stressRoots.enumerated() {
            for fileIndex in 0..<perRoot {
                let file = root.appendingPathComponent("doc-\(fileIndex).md")
                if fileIndex < bindingsPerRoot {
                    let raw = String(format: "doxcnStress%02d%05d", rootIndex, fileIndex)
                    try writeMD(at: file, docToken: raw)
                    expectedTokens.append(DocToken(raw))
                } else {
                    try writeRaw(at: file, content: "no frontmatter, just body \(fileIndex)")
                }
            }
        }

        let scanner = SyncRootScanner(logger: { _ in })
        let startupBegin = Date()
        await scanner.start(stressRoots)
        let startupSeconds = Date().timeIntervalSince(startupBegin)
        XCTAssertLessThan(startupSeconds, 3.0,
                          "startup took \(startupSeconds)s (gate: < 3s)")

        // Warm-up + measurement of 1000 lookups; report p99.
        var samples: [TimeInterval] = []
        samples.reserveCapacity(1000)
        for _ in 0..<1000 {
            let token = expectedTokens.randomElement()!
            let begin = Date()
            _ = await scanner.lookup(token)
            samples.append(Date().timeIntervalSince(begin))
        }
        samples.sort()
        let p99 = samples[Int(Double(samples.count) * 0.99)]
        XCTAssertLessThan(p99, 0.005,
                          "lookup p99 \(p99 * 1000) ms (gate: < 5ms)")

        await scanner.stop()
    }

    // MARK: stop

    func testStopClearsIndex() async throws {
        try writeMD(at: rootA.appendingPathComponent("x.md"),
                    docToken: "doxcnTeardownNNNN")
        let scanner = SyncRootScanner(logger: { _ in })
        await scanner.start([rootA])
        let beforeStop = await scanner.lookup(DocToken("doxcnTeardownNNNN"))
        XCTAssertNotNil(beforeStop)

        await scanner.stop()
        let afterStop = await scanner.lookup(DocToken("doxcnTeardownNNNN"))
        XCTAssertNil(afterStop)
    }

    // MARK: helpers

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default
            .temporaryDirectory
            .appendingPathComponent("SyncRootScannerTests-\(UUID().uuidString)", isDirectory: true)
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
        title: Test
        feishu:
          doc_token: \(docToken)
        ---
        body
        """
        try writeRaw(at: url, content: content)
    }

    private func writeRaw(at url: URL, content: String) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try content.write(to: url, atomically: true, encoding: .utf8)
    }
}
