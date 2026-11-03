import XCTest
@testable import donemdIOS

@MainActor
final class MobileSourceMirrorTests: XCTestCase {
    func testWinningThemeConfigureHandsOffContentWhenBootstrapWasSuperseded() async throws {
        let document = MobileDocument(fileURL: URL(fileURLWithPath: "/tmp/mirror-config-order.md"))
        try document.load(fromContents: Data("# Initial content\n".utf8), ofType: nil)
        let coordinator = MobileSourceWebView.Coordinator(document: document, theme: "system", fontScale: 1)
        coordinator.pageReady = true
        let sourceReady = expectation(description: "winning initial configure reconciles once")
        var readinessSignals = 0
        coordinator.initialReadinessReconciler = {
            readinessSignals += 1
            sourceReady.fulfill()
        }
        let firstSent = expectation(description: "bootstrap configure sent")
        let secondSent = expectation(description: "theme configure sent")
        let thirdSent = expectation(description: "later theme configure sent")
        var requests: [[String: Any]] = []
        coordinator.messageSender = { type, payload in
            XCTAssertEqual(type, "configureMobileSource")
            requests.append(payload)
            if requests.count == 1 { firstSent.fulfill() }
            else if requests.count == 2 { secondSent.fulfill() }
            else if requests.count == 3 { thirdSent.fulfill() }
            return true
        }
        var sourcePushes: [[String: Any]] = []
        document.sourceMirror.send = { type, payload in
            if type == "setMarkdownSource" { sourcePushes.append(payload) }
        }
        let bootstrap = Task { await coordinator.configure(theme: "system") }
        await fulfillment(of: [firstSent], timeout: 1)
        let theme = Task { await coordinator.configure(theme: "night") }
        await fulfillment(of: [secondSent], timeout: 1)
        XCTAssertEqual(requests.count, 2)
        guard requests.count == 2 else { return }
        var olderAck = requests[0]
        olderAck["success"] = true
        coordinator.receiveConfigurationAck(olderAck)
        let bootstrapSucceeded = await bootstrap.value
        XCTAssertFalse(bootstrapSucceeded)
        XCTAssertTrue(sourcePushes.isEmpty)
        var winningAck = requests[1]
        winningAck["success"] = true
        coordinator.receiveConfigurationAck(winningAck)
        let themeSucceeded = await theme.value
        XCTAssertTrue(themeSucceeded)
        await fulfillment(of: [sourceReady], timeout: 1)
        XCTAssertEqual(readinessSignals, 1)
        XCTAssertEqual(sourcePushes.count, 1, "Winning configure must push without bootstrap continuation or typing")
        XCTAssertEqual(sourcePushes.first?["text"] as? String, document.sourceMirror.source)
        let sequence = try XCTUnwrap(sourcePushes.first?["sequence"] as? Int)
        XCTAssertTrue(document.sourceMirror.acknowledge(identity: document.fileURL.path, revision: document.revision, sequence: sequence))
        XCTAssertTrue(document.sourceMirror.ready)
        coordinator.receiveConfigurationAck(olderAck)
        XCTAssertEqual(sourcePushes.count, 1, "A duplicate old configuration ACK cannot restart initialization")
        XCTAssertEqual(readinessSignals, 1, "A duplicate ACK must not create a reconcile loop")
        let laterTheme = Task { await coordinator.configure(theme: "paper") }
        await fulfillment(of: [thirdSent], timeout: 1)
        guard requests.count == 3 else { return }
        var laterAck = requests[2]
        laterAck["success"] = true
        coordinator.receiveConfigurationAck(laterAck)
        let laterSucceeded = await laterTheme.value
        XCTAssertTrue(laterSucceeded)
        await Task.yield()
        XCTAssertEqual(readinessSignals, 1, "Later theme ACKs cannot trigger perpetual readiness reconciliation")
    }

    func testOnlyCurrentGenerationAndLatestTransactionCanBecomeReady() {
        let mirror = MobileSourceMirror()
        mirror.accept(source: "# One", identity: "a", revision: 1)
        let old = mirror.sequence
        mirror.accept(source: "# Two", identity: "a", revision: 1)
        XCTAssertFalse(mirror.acknowledge(identity: "a", revision: 1, sequence: old))
        XCTAssertFalse(mirror.acknowledge(identity: "b", revision: 1, sequence: mirror.sequence))
        XCTAssertTrue(mirror.acknowledge(identity: "a", revision: 1, sequence: mirror.sequence))
        mirror.accept(source: "# Reload", identity: "a", revision: 2)
        XCTAssertFalse(mirror.ready)
        XCTAssertFalse(mirror.acknowledge(identity: "a", revision: 1, sequence: mirror.sequence))
        mirror.accept(source: "# Late", identity: "a", revision: 1)
        XCTAssertEqual(mirror.source, "# Reload")
    }

    func testFailureClearlyMarksLastGoodAsStaleAndRetryUsesFreshSequence() {
        let mirror = MobileSourceMirror()
        mirror.accept(source: "old", identity: "a", revision: 1)
        XCTAssertTrue(mirror.acknowledge(identity: "a", revision: 1, sequence: mirror.sequence))
        mirror.accept(source: "new", identity: "a", revision: 1)
        mirror.failed()
        XCTAssertTrue(mirror.stale)
        XCTAssertNotNil(mirror.error)
        let oldSequence = mirror.sequence
        mirror.push()
        XCTAssertGreaterThan(mirror.sequence, oldSequence)
        XCTAssertTrue(mirror.acknowledge(identity: "a", revision: 1, sequence: mirror.sequence))
        XCTAssertFalse(mirror.stale)
        XCTAssertNil(mirror.error)
    }

    func testStaleFoldCannotModifyBodyAndAcceptedFoldUsesAuthority() {
        let mirror = MobileSourceMirror()
        mirror.accept(source: "# Heading", identity: "a", revision: 3)
        XCTAssertTrue(mirror.acknowledge(identity: "a", revision: 3, sequence: mirror.sequence))
        var calls = 0
        mirror.toggleFold = { ordinal, collapse in
            XCTAssertEqual(ordinal, 0)
            XCTAssertTrue(collapse)
            calls += 1
        }
        mirror.receiveFold(ordinal: 0, collapse: true, identity: "b", revision: 3, sequence: mirror.sequence)
        mirror.receiveFold(ordinal: 0, collapse: true, identity: "a", revision: 2, sequence: mirror.sequence)
        XCTAssertEqual(calls, 0)
        mirror.receiveFold(ordinal: 0, collapse: true, identity: "a", revision: 3, sequence: mirror.sequence)
        XCTAssertEqual(calls, 1)
    }

    func testOpeningCanonicalMirrorAndRetryNeverFlushOrNormalizeDocument() throws {
        let document = MobileDocument(fileURL: URL(fileURLWithPath: "/tmp/mirror-original.md"))
        let original = "---\ntitle: Keep metadata\n---\n\n# Heading\n\n*text*\n"
        try document.load(fromContents: Data(original.utf8), ofType: nil)
        var flushes = 0
        document.flushEditor = { flushes += 1; return true }
        XCTAssertEqual(document.sourceMirror.source, MarkdownEngine.serialize(document: document.body))
        XCTAssertFalse(document.sourceMirror.source.contains("title: Keep metadata"))
        document.requestMirrorRefresh()
        XCTAssertEqual(flushes, 0)
        XCTAssertEqual(document.source, original)
        XCTAssertFalse(document.hasUnsavedChanges)
        XCTAssertFalse(document.needsNormalization)
    }

    func testCommittedBridgeTransactionsUpdateMirrorWithoutExtraFlushAndRejectComposition() throws {
        let document = MobileDocument(fileURL: URL(fileURLWithPath: "/tmp/mirror-transactions.md"))
        try document.load(fromContents: Data("# Original\n".utf8), ofType: nil)
        let bridge = MobileWebView.Coordinator(document)
        var flushes = 0
        document.flushEditor = { flushes += 1; return true }
        func payload(_ markdown: String, sequence: Int, composing: Bool = false, identity: String? = nil) throws -> [String: Any] {
            var result: [String: Any] = ["revision": document.revision, "sequence": sequence, "composing": composing,
                "body": try JSONSerialization.jsonObject(with: JSONEncoder().encode(MarkdownEngine.parse(markdown: markdown)))]
            if let identity { result["identity"] = identity }
            return result
        }
        XCTAssertFalse(bridge.applySnapshot(try payload("# IME partial", sequence: 1, composing: true)))
        XCTAssertFalse(bridge.applySnapshot(try payload("# Other document", sequence: 2, identity: "other")))
        XCTAssertFalse(bridge.applySnapshot(try payload("# Missing bootstrap identity", sequence: 2, identity: "")),
                       "An overwritten web documentInfo handler must fail closed, not bypass identity safety")
        XCTAssertTrue(bridge.applySnapshot(try payload("# Committed", sequence: 3, identity: document.fileURL.path)))
        XCTAssertTrue(document.sourceMirror.source.contains("Committed"))
        XCTAssertEqual(document.sourceMirror.revision, document.revision)
        let sequence = document.sourceMirror.sequence
        XCTAssertFalse(bridge.applySnapshot(try payload("# Late", sequence: 2)))
        XCTAssertEqual(document.sourceMirror.sequence, sequence)
        XCTAssertEqual(flushes, 0)
        document.updateChangeCount(.cleared)
    }
}
