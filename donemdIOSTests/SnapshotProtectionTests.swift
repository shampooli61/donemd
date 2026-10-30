import XCTest
@testable import donemdIOS

@MainActor
final class SnapshotProtectionTests: XCTestCase {
    func testRestoreBacksUpLatestFlushedWebBodyBeforeReplacingIt() async throws {
        try await withDocument { document, _ in
            var flushed = false
            document.flushEditor = {
                flushed = true
                return document.applyEditorSnapshot(MarkdownEngine.parse(markdown: "# Latest Web restore marker"), revision: document.revision)
            }
            let revision = document.revision
            try await document.restore(self.recoveryVersion)
            XCTAssertTrue(flushed)
            XCTAssertEqual(document.source, self.recoveryVersion.markdown)
            XCTAssertEqual(document.revision, revision + 1)
            XCTAssertTrue(document.recoveryVersions.contains {
                $0.reason == "恢复前的正文" && $0.markdown.contains("Latest Web restore marker")
            })
        }
    }

    func testConflictProtectionBacksUpLatestFlushedWebBodyAndSiblingBeforeReload() async throws {
        try await withDocument { document, folder in
            self.markConflict(document)
            document.flushEditor = {
                document.applyEditorSnapshot(MarkdownEngine.parse(markdown: "# Latest Web conflict marker"), revision: document.revision)
            }
            try await document.preserveConflictsAndReload()
            XCTAssertFalse(document.conflict)
            XCTAssertEqual(document.source, "# Native\n")
            XCTAssertTrue(document.recoveryVersions.contains {
                $0.reason == "冲突保护" && $0.markdown.contains("Latest Web conflict marker")
            })
            let siblings = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
                .filter { $0.lastPathComponent.contains(" 冲突 ") }
            XCTAssertTrue(try siblings.contains { try String(contentsOf: $0, encoding: .utf8).contains("Latest Web conflict marker") })
        }
    }

    func testRestoreRejectsFailedFlushOrCompositionWithoutReplacingBody() async throws {
        for composing in [false, true] {
            try await withDocument { document, _ in
                let source = document.source
                let body = document.body
                let revision = document.revision
                var flushed = false
                document.composing = composing
                document.flushEditor = { flushed = true; return composing }
                do {
                    try await document.restore(self.recoveryVersion)
                    XCTFail("Restore must reject a failed flush or active IME")
                } catch {}
                XCTAssertEqual(document.source, source)
                XCTAssertEqual(document.body, body)
                XCTAssertEqual(document.revision, revision)
                XCTAssertFalse(document.hasUnsavedChanges)
                XCTAssertTrue(try DocumentRecoveryStore.versions(for: document.fileURL).isEmpty)
                if composing { XCTAssertFalse(flushed, "Do not request a snapshot during native IME composition") }
            }
        }
    }

    func testConflictProtectionRejectsFailedFlushOrCompositionWithoutResolving() async throws {
        for composing in [false, true] {
            try await withDocument { document, folder in
                self.markConflict(document)
                let source = document.source
                let body = document.body
                let revision = document.revision
                document.composing = composing
                document.flushEditor = { !composing ? false : true }
                do {
                    try await document.preserveConflictsAndReload()
                    XCTFail("Conflict protection must reject a failed flush or active IME")
                } catch {}
                XCTAssertEqual(document.source, source)
                XCTAssertEqual(document.body, body)
                XCTAssertEqual(document.revision, revision)
                XCTAssertTrue(document.conflict)
                XCTAssertEqual(try String(contentsOf: document.fileURL, encoding: .utf8), source)
                XCTAssertTrue(try DocumentRecoveryStore.versions(for: document.fileURL).isEmpty)
                XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), ["note.md"])
            }
        }
    }

    func testCompositionStartingDuringFlushRejectsBothReplacementOperations() async throws {
        for restore in [true, false] {
            try await withDocument { document, _ in
                self.markConflict(document)
                let source = document.source
                let revision = document.revision
                document.flushEditor = { document.composing = true; return true }
                do {
                    if restore { try await document.restore(self.recoveryVersion) }
                    else { try await document.preserveConflictsAndReload() }
                    XCTFail("Recheck composition after awaiting the editor")
                } catch {}
                XCTAssertEqual(document.source, source)
                XCTAssertEqual(document.revision, revision)
                XCTAssertTrue(document.conflict)
                XCTAssertTrue(try DocumentRecoveryStore.versions(for: document.fileURL).isEmpty)
            }
        }
    }

    func testBackupFailureDoesNotReplaceOrResolveEitherOperation() async throws {
        for restore in [true, false] {
            try await withDocument { document, _ in
                self.markConflict(document)
                let source = document.source
                let revision = document.revision
                let recoveryDirectory = try DocumentRecoveryStore.directory(for: document.fileURL)
                try FileManager.default.removeItem(at: recoveryDirectory)
                try Data("block recovery directory creation".utf8).write(to: recoveryDirectory)
                do {
                    if restore { try await document.restore(self.recoveryVersion) }
                    else { try await document.preserveConflictsAndReload() }
                    XCTFail("A failed backup must abort the operation")
                } catch {}
                XCTAssertEqual(document.source, source)
                XCTAssertEqual(document.revision, revision)
                XCTAssertTrue(document.conflict)
                XCTAssertEqual(try String(contentsOf: document.fileURL, encoding: .utf8), source)
            }
        }
    }

    func testCompositionWithoutEditorStillRejectsBothReplacementOperations() async throws {
        for restore in [true, false] {
            try await withDocument { document, _ in
                self.markConflict(document)
                let source = document.source
                let revision = document.revision
                XCTAssertNil(document.flushEditor)
                document.composing = true
                do {
                    if restore { try await document.restore(self.recoveryVersion) }
                    else { try await document.preserveConflictsAndReload() }
                    XCTFail("The native composition guard must also work without an editor")
                } catch {}
                XCTAssertEqual(document.source, source)
                XCTAssertEqual(document.revision, revision)
                XCTAssertTrue(document.conflict)
            }
        }
    }

    func testReloadDuringFlushDoesNotGetReplacedByRecoveryTarget() async throws {
        try await withDocument { document, _ in
            document.flushEditor = {
                try? document.load(fromContents: Data("# Concurrent reload\n".utf8), ofType: nil)
                return true
            }
            do {
                try await document.restore(self.recoveryVersion)
                XCTFail("The revision captured before the flush is no longer current")
            } catch {}
            XCTAssertEqual(document.source, "# Concurrent reload\n")
        }
    }

    func testRestoreWithoutEditorStillPreservesNativeBody() async throws {
        try await withDocument { document, _ in
            XCTAssertNil(document.flushEditor)
            try await document.restore(self.recoveryVersion)
            XCTAssertEqual(document.source, self.recoveryVersion.markdown)
            XCTAssertTrue(document.recoveryVersions.contains { $0.reason == "恢复前的正文" && $0.markdown == "# Native\n" })
        }
    }

    func testAcknowledgedEditorLockSpansBackupAndSuspendedReloadAndRestore() async throws {
        for restore in [true, false] {
            try await withDocument { document, _ in
                self.markConflict(document)
                var locked = false
                var finished = false
                let revision = document.revision
                document.beginEditorProtection = {
                    locked = true
                    return document.applyEditorSnapshot(MarkdownEngine.parse(markdown: "# Final locked snapshot"), revision: document.revision)
                }
                document.finishEditorProtection = {
                    XCTAssertTrue(locked)
                    XCTAssertEqual(document.revision, revision + 1)
                    XCTAssertTrue(document.source.contains(restore ? "Recovery target" : "Native"))
                    locked = false
                    finished = true
                    return true
                }
                document.reloadProtectedDocument = {
                    XCTAssertTrue(locked, "The Web lock must remain held inside the revert suspension")
                    await Task.yield()
                    XCTAssertTrue(locked)
                    do {
                        let versions = try DocumentRecoveryStore.versions(for: document.fileURL)
                        XCTAssertTrue(versions.contains { $0.reason == "冲突保护" && $0.markdown.contains("Final locked snapshot") })
                    } catch { XCTFail("Recovery read failed: \(error)") }
                    try? document.load(fromContents: Data("# Native\n".utf8), ofType: nil)
                    return true
                }
                if restore { try await document.restore(self.recoveryVersion) }
                else { try await document.preserveConflictsAndReload() }
                XCTAssertTrue(finished)
                XCTAssertFalse(locked)
                XCTAssertTrue(document.recoveryVersions.contains { $0.markdown.contains("Final locked snapshot") })
            }
        }
    }

    func testAcknowledgedLockIsReleasedOnBackupFailureAndRejectedAcquisition() async throws {
        for rejectAcquisition in [true, false] {
            try await withDocument { document, _ in
                self.markConflict(document)
                let revision = document.revision
                let source = document.source
                var released = false
                document.beginEditorProtection = { !rejectAcquisition }
                document.finishEditorProtection = { released = true; return true }
                if !rejectAcquisition {
                    let directory = try DocumentRecoveryStore.directory(for: document.fileURL)
                    try FileManager.default.removeItem(at: directory)
                    try Data("backup blocked".utf8).write(to: directory)
                }
                do {
                    try await document.preserveConflictsAndReload()
                    XCTFail("Protection should fail without replacing the document")
                } catch {}
                XCTAssertTrue(released)
                XCTAssertEqual(document.source, source)
                XCTAssertEqual(document.revision, revision)
                XCTAssertTrue(document.conflict)
            }
        }
    }

    func testAcknowledgedLockIsReleasedAfterSuspendedRevertFailure() async throws {
        try await withDocument { document, _ in
            self.markConflict(document)
            var locked = false
            document.beginEditorProtection = { locked = true; return true }
            document.finishEditorProtection = { locked = false; return true }
            document.reloadProtectedDocument = {
                await Task.yield()
                XCTAssertTrue(locked)
                return false
            }
            let revision = document.revision
            do {
                try await document.preserveConflictsAndReload()
                XCTFail("The failed revert must be surfaced")
            } catch {}
            XCTAssertFalse(locked)
            XCTAssertTrue(document.conflict)
            XCTAssertEqual(document.revision, revision)
        }
    }

    func testBridgeRejectsQueuedSnapshotsOlderThanLockAckEvenAtSameRevision() throws {
        let document = MobileDocument(fileURL: URL(fileURLWithPath: "/tmp/sequence-protection.md"))
        try document.load(fromContents: Data("# Baseline\n".utf8), ofType: nil)
        let bridge = MobileWebView.Coordinator(document)
        func snapshot(_ text: String, sequence: Int) throws -> [String: Any] {
            let body = MarkdownEngine.parse(markdown: text)
            let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(body))
            return ["body": json, "revision": document.revision, "sequence": sequence]
        }
        XCTAssertTrue(bridge.applySnapshot(try snapshot("# Final ACK", sequence: 10)))
        XCTAssertFalse(bridge.applySnapshot(try snapshot("# Queued stale message", sequence: 9)))
        XCTAssertTrue(document.source.contains("Final ACK"))
        XCTAssertTrue(bridge.applySnapshot(try snapshot("# Typed just after JS unlock", sequence: 11)))
        XCTAssertTrue(document.source.contains("Typed just after JS unlock"))
    }

    func testAttachedButNotReadyEditorRejectsReplacementInsteadOfActingHeadless() async throws {
        try await withDocument { document, _ in
            let bridge = MobileWebView.Coordinator(document)
            bridge.installNotReadyProtection()
            let revision = document.revision
            do {
                try await document.restore(self.recoveryVersion)
                XCTFail("An attached editor must ACK before replacement, even before editorReady")
            } catch {}
            XCTAssertEqual(document.source, "# Native\n")
            XCTAssertEqual(document.revision, revision)
        }
    }

    func testFinishAckCatchesUpExternalRevisionAndPreservesInterveningWebDraft() async throws {
        try await withDocument { document, _ in
            let bridge = MobileWebView.Coordinator(document)
            bridge.ready = true
            let initialRevision = document.revision
            var begins = 0
            var finishes = 0
            bridge.protectionEvaluator = { script in
                if script.contains(".begin(") {
                    begins += 1
                    let token = script.components(separatedBy: "'")[1]
                    let body = MarkdownEngine.parse(markdown: begins == 1 ? "# Initial ACK" : "# Intervening Web draft")
                    let json = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(body))) ?? [:]
                    return ["token": token, "locked": true, "composing": false,
                            "revision": initialRevision, "sequence": begins * 10, "body": json]
                }
                if script.contains(".finish(") {
                    finishes += 1
                    if finishes == 1 {
                        // Deterministic stand-in for UIDocument load while JS finish ACK is awaited.
                        try? document.load(fromContents: Data("# External newest\n".utf8), ofType: nil)
                    } else {
                        XCTAssertTrue(script.contains("External newest"))
                        XCTAssertTrue(script.contains(", \(document.revision))"))
                    }
                    return true
                }
                return true
            }
            let acquired = await bridge.beginProtection()
            XCTAssertTrue(acquired)
            let finished = await bridge.finishProtection()
            XCTAssertTrue(finished)
            XCTAssertEqual(finishes, 2)
            XCTAssertEqual(bridge.revision, document.revision)
            XCTAssertTrue(document.source.contains("External newest"))
            XCTAssertTrue(document.recoveryVersions.contains { $0.reason == "重载追赶前的编辑器正文" && $0.markdown.contains("Intervening Web draft") })
        }
    }

    func testImeDeniedCatchupRetryProtectsMismatchedAckBeforeCleanupCanReplace() async throws {
        try await withDocument { document, _ in
            let bridge = MobileWebView.Coordinator(document)
            bridge.ready = true
            let oldRevision = document.revision
            var begins = 0
            var finishes = 0
            var paused = false
            bridge.protectionEvaluator = { script in
                if script.contains(".begin(") {
                    begins += 1
                    if begins == 2 { return nil } // User starts IME just after the first unlock.
                    let token = script.components(separatedBy: "'")[1]
                    let body = MarkdownEngine.parse(markdown: begins == 1 ? "# ACK baseline" : "# IME committed draft must survive")
                    let json = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(body))) ?? [:]
                    return ["token": token, "locked": true, "composing": false,
                            "revision": oldRevision, "sequence": begins * 10, "body": json]
                }
                if script.contains(".pauseUntilRetry(") { paused = true; return true }
                if script.contains(".finish(") {
                    finishes += 1
                    if finishes == 1 {
                        try? document.load(fromContents: Data("# External R plus one\n".utf8), ofType: nil)
                    } else {
                        XCTAssertTrue(script.contains("External R plus one"))
                        XCTAssertTrue(document.recoveryVersions.contains {
                            $0.markdown.contains("IME committed draft must survive")
                        }, "Cleanup must not install R+1 until the mismatched ACK is protected")
                    }
                    return true
                }
                return true
            }
            let firstBegin = await bridge.beginProtection()
            XCTAssertTrue(firstBegin)
            let firstFinish = await bridge.finishProtection()
            XCTAssertFalse(firstFinish)
            XCTAssertTrue(paused)
            XCTAssertEqual(finishes, 1)
            let retryBegin = await bridge.beginProtection()
            XCTAssertFalse(retryBegin, "Retry must report a revision mismatch, not accept stale body as current")
            XCTAssertTrue(document.recoveryVersions.contains { $0.markdown.contains("IME committed draft must survive") })
            let retryCleanup = await bridge.finishProtection()
            XCTAssertTrue(retryCleanup)
            XCTAssertEqual(finishes, 2)
            XCTAssertEqual(bridge.revision, document.revision)
            XCTAssertTrue(document.source.contains("External R plus one"))
        }
    }

    private var recoveryVersion: DocumentRecoveryStore.Version {
        .init(id: UUID(), date: Date(), markdown: "# Recovery target\n", reason: "test")
    }

    private func markConflict(_ document: MobileDocument) {
        document.composing = true
        XCTAssertThrowsError(try document.load(fromContents: Data("# External\n".utf8), ofType: nil))
        document.composing = false
        XCTAssertTrue(document.conflict)
    }

    private func withDocument(_ operation: (MobileDocument, URL) async throws -> Void) async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("note.md")
        try "# Native\n".write(to: url, atomically: true, encoding: .utf8)
        let recoveryDirectory = try DocumentRecoveryStore.directory(for: url)
        defer {
            try? FileManager.default.removeItem(at: folder)
            try? FileManager.default.removeItem(at: recoveryDirectory)
        }
        let document = MobileDocument(fileURL: url)
        let opened = await document.open()
        XCTAssertTrue(opened)
        do { try await operation(document, folder) }
        catch {
            document.composing = false
            document.flushEditor = nil
            document.updateChangeCount(.cleared)
            _ = await document.close()
            throw error
        }
        document.composing = false
        document.flushEditor = nil
        document.updateChangeCount(.cleared)
        _ = await document.close()
    }
}
