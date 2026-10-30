import XCTest
import Combine
@testable import donemdIOS

@MainActor
final class MobileEditorControllerTests: XCTestCase {
    private func ready(_ controller: MobileEditorController, revision: Int = 3) {
        controller.prepare(identity: "note", revision: revision)
        var state = MobileEditorState()
        state.identity = "note"
        state.revision = revision
        state.ready = true
        state.editable = true
        controller.receive(state: state)
    }

    func testPartialStateDecodesWithSafeDefaultsAndExactCommandKeys() throws {
        let state = try JSONDecoder().decode(MobileEditorState.self, from: Data("{\"identity\":\"note\",\"revision\":3}".utf8))
        XCTAssertFalse(state.ready)
        XCTAssertFalse(state.editable)
        XCTAssertEqual(state.headings, [])
        XCTAssertEqual(state.attributes, [:])
        let command = MobileEditorCommand(requestId: "r", identity: "note", revision: 3,
                                          name: "format.bold", args: [:], selectionToken: "bookmark")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(command)) as? [String: Any])
        XCTAssertEqual(Set(json.keys), Set(["requestId", "identity", "revision", "name", "args", "selectionToken"]))
        XCTAssertEqual(json["selectionToken"] as? String, "bookmark")
    }

    func testCommandsWaitForMatchingACKAndPublishReturnedState() async {
        let controller = MobileEditorController()
        let firstSent = expectation(description: "first command")
        let secondSent = expectation(description: "second command")
        var sent: [MobileEditorCommand] = []
        controller.installTransport({ command in
            sent.append(command)
            (sent.count == 1 ? firstSent : secondSent).fulfill()
        }, currentSource: { nil })
        ready(controller)
        let first = Task { await controller.perform("format.bold", selectionToken: "frozen") }
        await fulfillment(of: [firstSent], timeout: 1)
        let second = Task { await controller.perform("history.undo") }
        await Task.yield()
        XCTAssertTrue(controller.busy)
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent[0].selectionToken, "frozen")
        controller.receive(result: .init(requestId: "unrelated", success: true))
        XCTAssertEqual(sent.count, 1, "Unmatched ACK must not dequeue another action")
        var next = controller.state
        next.marks = ["bold"]
        controller.receive(result: .init(requestId: sent[0].requestId, success: true, state: next))
        await fulfillment(of: [secondSent], timeout: 1)
        XCTAssertEqual(controller.state.marks, ["bold"])
        controller.receive(result: .init(requestId: sent[1].requestId, success: true))
        let firstResult = await first.value
        let secondResult = await second.value
        XCTAssertTrue(firstResult.success)
        XCTAssertTrue(secondResult.success)
        XCTAssertFalse(controller.busy)
    }

    func testRevisionChangeCancelsInflightAndQueuedAndIgnoresLateACK() async {
        let controller = MobileEditorController()
        let dispatched = expectation(description: "dispatched")
        var sent: [MobileEditorCommand] = []
        controller.installTransport({ sent.append($0); dispatched.fulfill() }, currentSource: { nil })
        ready(controller)
        let first = Task { await controller.perform("format.bold") }
        await fulfillment(of: [dispatched], timeout: 1)
        let second = Task { await controller.perform("format.italic") }
        await Task.yield()
        controller.prepare(identity: "other", revision: 4)
        let firstResult = await first.value
        let secondResult = await second.value
        XCTAssertFalse(firstResult.success)
        XCTAssertFalse(secondResult.success)
        XCTAssertEqual(sent.count, 1)
        var stale = MobileEditorState()
        stale.identity = "note"; stale.revision = 3; stale.ready = true
        controller.receive(result: .init(requestId: sent[0].requestId, success: true, state: stale))
        controller.receive(state: stale)
        XCTAssertEqual(controller.state.identity, "other")
        XCTAssertFalse(controller.state.ready)
    }

    func testStaleStateInMatchingACKIsFailureNotApplied() async {
        let controller = MobileEditorController()
        controller.installTransport({ command in
            var stale = MobileEditorState()
            stale.identity = "different"; stale.revision = 3; stale.ready = true
            controller.receive(result: .init(requestId: command.requestId, success: true, state: stale))
        }, currentSource: { nil })
        ready(controller)
        let result = await controller.perform("format.bold")
        XCTAssertFalse(result.success)
        XCTAssertEqual(controller.state.identity, "note")
        XCTAssertNotNil(controller.error)
    }

    func testTimeoutFailsClosedAndDoesNotSendDependentMutation() async {
        let controller = MobileEditorController(timeoutNanoseconds: 1_000_000)
        var sent: [MobileEditorCommand] = []
        controller.installTransport({ sent.append($0) }, currentSource: { nil })
        ready(controller)
        let result = await controller.perform("format.bold")
        XCTAssertFalse(result.success)
        XCTAssertFalse(controller.state.ready)
        XCTAssertFalse(controller.busy)
        let later = await controller.perform("format.italic")
        XCTAssertFalse(later.success)
        XCTAssertEqual(sent.count, 1)
        var lateState = controller.state
        lateState.ready = true
        controller.receive(state: lateState)
        XCTAssertFalse(controller.state.ready, "Late state cannot unquarantine an unknown command")
    }

    func testCancellationAndDisconnectResumeWaiters() async {
        let controller = MobileEditorController()
        let dispatched = expectation(description: "dispatched")
        controller.installTransport({ _ in dispatched.fulfill() }, currentSource: { nil })
        ready(controller)
        let task = Task { await controller.perform("format.bold") }
        await fulfillment(of: [dispatched], timeout: 1)
        task.cancel()
        let result = await task.value
        XCTAssertFalse(result.success)
        XCTAssertFalse(controller.busy)
        XCTAssertFalse(controller.state.ready)
        ready(controller, revision: 4)
        let nextSent = expectation(description: "next dispatched")
        controller.installTransport({ _ in nextSent.fulfill() }, currentSource: { nil })
        ready(controller, revision: 4)
        let next = Task { await controller.perform("format.bold") }
        await fulfillment(of: [nextSent], timeout: 1)
        controller.disconnect()
        let disconnected = await next.value
        XCTAssertFalse(disconnected.success)
        XCTAssertFalse(controller.busy)
    }

    func testActivationAllowedBeforeReadyAndCaptureReturnsBookmark() async {
        let controller = MobileEditorController()
        var sent: [String] = []
        controller.installTransport({ command in
            sent.append(command.name)
            var state = controller.state
            state.ready = true; state.editable = true
            controller.receive(result: .init(requestId: command.requestId, success: true,
                                             selectionToken: command.name == "selection.capture" ? "captured" : nil,
                                             state: state))
        }, currentSource: { nil })
        controller.prepare(identity: "note", revision: 3)
        let premature = await controller.perform("format.bold")
        XCTAssertFalse(premature.success)
        let activation = await controller.perform("native.activate")
        XCTAssertTrue(activation.success)
        let token = await controller.captureSelection()
        XCTAssertEqual(token, "captured")
        XCTAssertEqual(sent, ["native.activate", "selection.capture"])
    }

    func testSourceCommandFlushesCurrentNativeModelWithoutSavingDisk() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("note.md")
        try "# Saved\n".write(to: url, atomically: true, encoding: .utf8)
        let document = MobileDocument(fileURL: url)
        let recovery = try DocumentRecoveryStore.directory(for: url)
        defer {
            try? FileManager.default.removeItem(at: folder)
            try? FileManager.default.removeItem(at: recovery)
        }
        try document.load(fromContents: Data("# Saved\n".utf8), ofType: nil)
        var flushed = false
        document.flushEditor = {
            flushed = true
            return document.applyEditorSnapshot(MarkdownEngine.parse(markdown: "# Current unsaved model"), revision: document.revision)
        }
        document.editor.installTransport({ _ in XCTFail("source.get must not read stale JS/saved source") }, currentSource: { [weak document] in
            await document?.currentEditorSource()
        })
        document.editor.prepare(identity: url.path, revision: document.revision)
        var state = MobileEditorState()
        state.identity = url.path; state.revision = document.revision; state.ready = true
        document.editor.receive(state: state)
        let result = await document.editor.perform("source.get")
        XCTAssertTrue(flushed)
        XCTAssertTrue(result.success)
        XCTAssertEqual(result.data?["source"], document.source)
        XCTAssertTrue(result.data?["source"]?.contains("Current unsaved model") == true)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "# Saved\n")
        document.updateChangeCount(.cleared)
    }
    func testMediaKeepsOriginalSelectionAndWaitsForInsertionACK() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("note.md")
        let image = folder.appendingPathComponent("photo.png")
        try Data([1, 2, 3]).write(to: image)
        let document = MobileDocument(fileURL: url)
        let dispatched = expectation(description: "insertion dispatched")
        var command: MobileEditorCommand?
        document.editor.installTransport({ value in command = value; dispatched.fulfill() }, currentSource: { nil })
        document.editor.prepare(identity: url.path, revision: document.revision)
        var state = MobileEditorState()
        state.identity = url.path; state.revision = document.revision; state.ready = true; state.editable = true
        document.editor.receive(state: state)
        let task = Task { await document.importMedia(image, selectionToken: "original-picker-target") }
        await fulfillment(of: [dispatched], timeout: 2)
        let sent = try XCTUnwrap(command)
        XCTAssertEqual(sent.name, "insert.image")
        XCTAssertEqual(sent.selectionToken, "original-picker-target")
        XCTAssertTrue(document.importing, "Asset write alone is not insertion completion")
        XCTAssertNil(document.outgoing, "Acknowledged path must not duplicate legacy insertion")
        document.editor.receive(result: .init(requestId: sent.requestId, message: "选区已失效"))
        await task.value
        XCTAssertFalse(document.importing)
        XCTAssertTrue(document.message?.contains("未插入引用") == true)
        XCTAssertEqual(document.source, "")
        let stored = try FileManager.default.contentsOfDirectory(at: folder.appendingPathComponent("assets"), includingPropertiesForKeys: nil)
        XCTAssertFalse(stored.isEmpty, "Failed insertion must retain imported media")
    }

    func testSourceFlushRejectsRevisionChangedDuringAwait() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("note.md")
        let document = MobileDocument(fileURL: url)
        let recovery = try DocumentRecoveryStore.directory(for: url)
        defer {
            try? FileManager.default.removeItem(at: folder)
            try? FileManager.default.removeItem(at: recovery)
        }
        try document.load(fromContents: Data("# Original\n".utf8), ofType: nil)
        document.flushEditor = {
            try? document.load(fromContents: Data("# External replacement\n".utf8), ofType: nil)
            return true
        }
        let source = await document.currentEditorSource()
        XCTAssertNil(source)
        XCTAssertTrue(document.source.contains("External replacement"))
        document.flushEditor = nil
    }

    func testEqualStateDoesNotRepublishAndDocumentInfoIsDeduplicated() throws {
        let controller = MobileEditorController()
        ready(controller)
        var publications = 0
        let observation = controller.$state.sink { _ in publications += 1 }
        let original = controller.state
        controller.receive(state: original)
        controller.receive(state: original)
        XCTAssertEqual(publications, 1, "Equal state must not trigger a SwiftUI/WK refresh cycle")
        var changed = original
        changed.canUndo = true
        controller.receive(state: changed)
        controller.receive(state: changed)
        XCTAssertEqual(publications, 2)
        withExtendedLifetime(observation) {}

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let document = MobileDocument(fileURL: folder.appendingPathComponent("info.md"))
        let recovery = try DocumentRecoveryStore.directory(for: document.fileURL)
        defer {
            try? FileManager.default.removeItem(at: folder)
            try? FileManager.default.removeItem(at: recovery)
        }
        let bridge = MobileWebView.Coordinator(document)
        var messages: [String] = []
        bridge.messageSender = { type, _ in messages.append(type); return true }
        bridge.sendDocumentInfo()
        bridge.sendDocumentInfo()
        bridge.sendDocumentInfo()
        XCTAssertEqual(messages, ["documentInfo"])
        try document.load(fromContents: Data("# New source\n".utf8), ofType: nil)
        bridge.sendDocumentInfo()
        bridge.sendDocumentInfo()
        XCTAssertEqual(messages, ["documentInfo", "documentInfo"])
    }

    func testNativeActivationFollowsIdentityAndLoadAndReactivatesAfterReload() async {
        let document = MobileDocument(fileURL: URL(fileURLWithPath: "/tmp/native-load-order.md"))
        let bridge = MobileWebView.Coordinator(document)
        let firstActivation = expectation(description: "first activation")
        let nextActivation = expectation(description: "reactivation")
        var messages: [String] = []
        var activations = 0
        bridge.messageSender = { type, payload in
            messages.append(type)
            if type == "editorCommand", let values = payload as? [String: Any],
               let request = values["requestId"] as? String {
                XCTAssertEqual(values["name"] as? String, "native.activate")
                activations += 1
                document.editor.receive(result: .init(requestId: request, success: true))
                (activations == 1 ? firstActivation : nextActivation).fulfill()
            }
            return true
        }
        bridge.installNotReadyProtection()
        bridge.ready = true
        bridge.load()
        await fulfillment(of: [firstActivation], timeout: 1)
        XCTAssertEqual(messages, ["documentInfo", "loadDocument", "editorCommand"])
        bridge.load()
        await fulfillment(of: [nextActivation], timeout: 1)
        XCTAssertEqual(Array(messages.suffix(2)), ["loadDocument", "editorCommand"])
        document.editor.disconnect()
    }

    func testRealEditFirstSeenBySourceFlushRetainsAutosaveAfterIdenticalSnapshot() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("note.md")
        let document = MobileDocument(fileURL: url)
        let recovery = try DocumentRecoveryStore.directory(for: url)
        defer {
            document.flushEditor = nil
            document.updateChangeCount(.cleared)
            try? FileManager.default.removeItem(at: folder)
            try? FileManager.default.removeItem(at: recovery)
        }
        let saved = "# Saved\n"
        try saved.write(to: url, atomically: true, encoding: .utf8)
        try document.load(fromContents: Data(saved.utf8), ofType: nil)
        document.acceptNormalization()
        let edited = MarkdownEngine.parse(markdown: "# Real edit discovered by source flush")
        let autosaveAttempt = expectation(description: "ordinary autosave remains pending")
        var flushes = 0
        document.flushEditor = {
            flushes += 1
            if flushes == 1 {
                return document.applyEditorSnapshot(edited, revision: document.revision)
            }
            autosaveAttempt.fulfill()
            // Observe the scheduled save without allowing the test to write the document.
            return false
        }
        let source = await document.currentEditorSource()
        XCTAssertTrue(source?.contains("Real edit discovered by source flush") == true)
        XCTAssertEqual(flushes, 1, "Viewing source must not synchronously save")
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), saved)
        XCTAssertTrue(document.applyEditorSnapshot(edited, revision: document.revision), "Ordinary identical snapshot is accepted")
        await fulfillment(of: [autosaveAttempt], timeout: 2)
        XCTAssertEqual(flushes, 2, "The no-op snapshot must not lose the real edit's debounced autosave")
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), saved)
    }

    func testUnchangedSourceOnlyFlushDoesNotScheduleAutosave() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("note.md")
        let document = MobileDocument(fileURL: url)
        let recovery = try DocumentRecoveryStore.directory(for: url)
        defer {
            document.flushEditor = nil
            document.updateChangeCount(.cleared)
            try? FileManager.default.removeItem(at: folder)
            try? FileManager.default.removeItem(at: recovery)
        }
        let saved = "# Saved\n"
        try saved.write(to: url, atomically: true, encoding: .utf8)
        try document.load(fromContents: Data(saved.utf8), ofType: nil)
        let unexpectedAutosave = expectation(description: "source-only read must not schedule autosave")
        unexpectedAutosave.isInverted = true
        var flushes = 0
        document.flushEditor = {
            flushes += 1
            if flushes > 1 { unexpectedAutosave.fulfill() }
            return document.applyEditorSnapshot(document.body, revision: document.revision)
        }
        let source = await document.currentEditorSource()
        XCTAssertEqual(source, saved)
        await fulfillment(of: [unexpectedAutosave], timeout: 1)
        XCTAssertEqual(flushes, 1)
        XCTAssertFalse(document.hasUnsavedChanges)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), saved)
    }

    func testControllerCanBeConstructedOffActorBeforeInstallingTransport() async {
        let controller = await Task.detached { MobileEditorController() }.value
        XCTAssertFalse(controller.state.ready)
        XCTAssertFalse(controller.usesCommandTransport)
        XCTAssertFalse(controller.busy)
    }

    func testReplacementMediaTypeMismatchRejectsBeforeWritingAssetOrSendingCommand() async throws {
        for (filename, expectedType) in [("photo.png", "video"), ("movie.mp4", "image")] {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            let url = folder.appendingPathComponent("note.md")
            let media = folder.appendingPathComponent(filename)
            try Data([1, 2, 3]).write(to: media)
            let document = MobileDocument(fileURL: url)
            document.editor.installTransport({ _ in XCTFail("A type mismatch must not capture or insert") }, currentSource: { nil })
            document.editor.prepare(identity: url.path, revision: document.revision)
            var state = MobileEditorState()
            state.identity = url.path; state.revision = document.revision; state.ready = true; state.editable = true
            document.editor.receive(state: state)
            await document.importMedia(media, selectionToken: "replacement-target", expectedType: expectedType)
            XCTAssertTrue(document.message?.contains("附件类型不匹配") == true)
            XCTAssertFalse(document.importing)
            XCTAssertNil(document.outgoing)
            XCTAssertEqual(document.source, "")
            XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("assets").path))
            XCTAssertEqual(try Data(contentsOf: media), Data([1, 2, 3]), "Rejected picker file remains intact")
            document.editor.disconnect()
        }
    }

    func testRecoveryLoadFailureIsVisibleAndDoesNotRewriteStorage() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("note.md")
        let document = MobileDocument(fileURL: url)
        let recovery = try DocumentRecoveryStore.directory(for: url)
        defer {
            try? FileManager.default.removeItem(at: folder)
            try? FileManager.default.removeItem(at: recovery)
        }
        try DocumentRecoveryStore.save("# Retained recovery", for: url, reason: "test")
        XCTAssertTrue(document.refreshRecovery())
        let before = document.recoveryVersions
        XCTAssertFalse(before.isEmpty)
        document.loadRecoveryVersions = { throw CocoaError(.fileReadNoPermission) }
        XCTAssertFalse(document.refreshRecovery())
        XCTAssertTrue(document.recoveryVersions.isEmpty, "Stale results cannot masquerade as a successful refresh")
        XCTAssertTrue(document.message?.contains("恢复版本读取失败") == true)
        let stored = try DocumentRecoveryStore.versions(for: url)
        XCTAssertEqual(stored.map(\.markdown), before.map(\.markdown))
        document.loadRecoveryVersions = nil
        XCTAssertTrue(document.refreshRecovery(), "Retry must be able to recover after access is restored")
        XCTAssertEqual(document.recoveryVersions.map(\.markdown), before.map(\.markdown))
        let corrupt = recovery.appendingPathComponent("corrupt.json")
        let corruptBytes = Data("not a recovery version".utf8)
        try corruptBytes.write(to: corrupt)
        XCTAssertFalse(document.refreshRecovery(), "Corrupt entries must not be silently compactMapped away")
        XCTAssertTrue(document.message?.contains("部分恢复版本无法读取") == true)
        XCTAssertEqual(document.recoveryVersions.map(\.markdown), before.map(\.markdown), "Healthy entries remain accessible with a partial warning")
        XCTAssertEqual(try Data(contentsOf: corrupt), corruptBytes, "Failure must not delete or repair recovery storage")
        try FileManager.default.removeItem(at: corrupt)
        XCTAssertTrue(document.refreshRecovery())
        document.loadRecoveryVersions = { [] }
        XCTAssertTrue(document.refreshRecovery(), "A genuinely empty list is a successful read, not an I/O failure")
        XCTAssertTrue(document.recoveryVersions.isEmpty)
    }

    func testMixedMalformedAndValidRecoveryEntriesKeepValidVersionAndWarnWithoutWritingFiles() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("note.md")
        let document = MobileDocument(fileURL: url)
        let recovery = try DocumentRecoveryStore.directory(for: url)
        defer {
            try? FileManager.default.removeItem(at: folder)
            try? FileManager.default.removeItem(at: recovery)
        }
        let good = DocumentRecoveryStore.Version(id: UUID(), date: Date(), markdown: "# Healthy version", reason: "mixed test")
        let validFile = recovery.appendingPathComponent("valid.json")
        let malformedFile = recovery.appendingPathComponent("malformed.json")
        let goodBytes = try JSONEncoder().encode(good)
        let malformedBytes = Data("{malformed JSON".utf8)
        try goodBytes.write(to: validFile)
        try malformedBytes.write(to: malformedFile)
        XCTAssertFalse(document.refreshRecovery(), "A partial read remains retryable")
        XCTAssertEqual(document.recoveryVersions.map(\.id), [good.id])
        XCTAssertTrue(document.message?.contains("部分恢复版本无法读取") == true)
        XCTAssertTrue(document.message?.contains("可用版本仍可查看") == true)
        XCTAssertEqual(try Data(contentsOf: validFile), goodBytes)
        XCTAssertEqual(try Data(contentsOf: malformedFile), malformedBytes)
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: recovery.path)), Set(["valid.json", "malformed.json"]))
    }

}
