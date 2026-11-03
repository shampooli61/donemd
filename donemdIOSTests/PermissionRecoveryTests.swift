import XCTest
@testable import donemdIOS

@MainActor
final class PermissionRecoveryTests: XCTestCase {
    private func defaults() -> UserDefaults {
        let name = "PermissionRecoveryTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    func testInvalidRestoredBookmarkIsRemovedAndCanBeReauthorized() throws {
        let defaults = defaults()
        let key = "document-folder-bookmark"
        defaults.set(Data([0, 1, 2]), forKey: key)
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let original = folder.appendingPathComponent("original.md")
        try "# Original\n".write(to: original, atomically: true, encoding: .utf8)
        let store = FolderStore(defaults: defaults)
        XCTAssertNil(store.root)
        XCTAssertNotNil(store.error)
        XCTAssertNil(defaults.data(forKey: key), "Do not retry the unusable saved grant on every launch")
        try store.select(folder)
        XCTAssertEqual(store.root, folder)
        XCTAssertNil(store.error)
        XCTAssertNotNil(defaults.data(forKey: key))
        XCTAssertEqual(try String(contentsOf: original, encoding: .utf8), "# Original\n")
    }

    func testResolvedButUnreadableBookmarkIsRemovedAndScopeReleased() throws {
        let defaults = defaults()
        let key = "document-folder-bookmark"
        defaults.set(Data([1]), forKey: key)
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        var starts = 0, stops = 0
        var access = FolderStore.Access()
        access.resolveBookmark = { _ in folder }
        access.makeBookmark = { _ in Data([2]) }
        access.readDirectory = { _, _, _ in throw CocoaError(.fileReadNoPermission) }
        access.start = { _ in starts += 1; return true }
        access.stop = { _ in stops += 1 }
        let store = FolderStore(defaults: defaults, access: access)
        XCTAssertNil(store.root)
        XCTAssertNotNil(store.error)
        XCTAssertNil(defaults.data(forKey: key))
        XCTAssertEqual(starts, 1)
        XCTAssertEqual(stops, 1)
    }

    func testFailedReselectionPreservesWorkingFolderBookmarkAndScope() throws {
        let defaults = defaults()
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let missing = folder.appendingPathComponent("missing")
        var starts: [URL] = [], stops: [URL] = []
        var access = FolderStore.Access()
        access.start = { starts.append($0); return true }
        access.stop = { stops.append($0) }
        var store: FolderStore? = FolderStore(defaults: defaults, access: access)
        try store!.select(folder)
        let saved = defaults.data(forKey: "document-folder-bookmark")
        XCTAssertThrowsError(try store!.select(missing))
        XCTAssertEqual(store!.root, folder)
        XCTAssertEqual(defaults.data(forKey: "document-folder-bookmark"), saved)
        XCTAssertEqual(stops, [missing])
        XCTAssertNoThrow(try store!.entries(in: folder))
        store = nil
        XCTAssertEqual(starts, [folder, missing])
        XCTAssertEqual(stops, [missing, folder])
    }

    func testLocalFolderDoesNotRequireStartAccessingToReturnTrue() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        var stops = 0
        var access = FolderStore.Access()
        access.start = { _ in false }
        access.stop = { _ in stops += 1 }
        var store: FolderStore? = FolderStore(defaults: defaults(), access: access)
        try store!.select(folder)
        XCTAssertEqual(store!.root, folder)
        XCTAssertNil(store!.error)
        store = nil
        XCTAssertEqual(stops, 0)
    }

    func testFailedOpenInKnownFolderCanReauthorizeAndRetryWithoutReplacingPending() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("failed.md")
        try "# Original\n".write(to: file, atomically: true, encoding: .utf8)
        let folders = FolderStore(defaults: defaults())
        try folders.select(folder)
        var fail = true
        let session = DocumentOpenCoordinator(folders: folders, openDocument: { document in
            if fail { return false }
            return await document.open()
        })
        await session.receiveExternal(file)
        XCTAssertEqual(session.pendingURL, file)
        XCTAssertFalse(session.needsFolderAuthorization, "Path membership is only an initial routing check")
        XCTAssertTrue(session.canReauthorizePending)
        await session.receiveExternal(folder.appendingPathComponent("other.md"))
        XCTAssertEqual(session.pendingURL, file, "A new URL must not discard the failed pending request")
        XCTAssertNotNil(session.error)
        fail = false
        await session.selectFolder(folder)
        let opened = try XCTUnwrap(session.opened)
        XCTAssertEqual(opened.fileURL, file)
        XCTAssertNil(session.pendingURL)
        XCTAssertNil(session.error)
        XCTAssertFalse(session.canReauthorizePending)
        _ = await opened.close()
        await session.didDismiss()
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "# Original\n")
    }

    func testFailedListOpenCanCancelAndRetryAndBalancesScope() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("failed.md")
        try "# Original\n".write(to: file, atomically: true, encoding: .utf8)
        let folders = FolderStore(defaults: defaults())
        try folders.select(folder)
        var starts = 0, stops = 0
        var fail = true
        let session = DocumentOpenCoordinator(folders: folders, openDocument: { document in
            if fail { return false }
            return await document.open()
        }, startAccess: { _ in starts += 1; return true }, stopAccess: { _ in stops += 1 })
        await session.open(file)
        XCTAssertEqual(session.pendingURL, file)
        XCTAssertTrue(session.canReauthorizePending)
        XCTAssertEqual(starts, 1)
        XCTAssertEqual(stops, 0)
        session.cancelPending()
        XCTAssertNil(session.pendingURL)
        XCTAssertNil(session.error)
        XCTAssertFalse(session.canReauthorizePending)
        XCTAssertEqual(stops, 1)
        await session.receiveExternal(file)
        XCTAssertEqual(session.pendingURL, file)
        fail = false
        await session.openPending()
        let opened = try XCTUnwrap(session.opened)
        XCTAssertNil(session.pendingURL)
        XCTAssertEqual(stops, 1, "Successful retry transfers the scope to the active document")
        _ = await opened.close()
        await session.didDismiss()
        XCTAssertEqual(starts, 2)
        XCTAssertEqual(stops, 2)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "# Original\n")
    }

    func testBookmarkCreationFailureAlsoPreservesPriorAuthorization() throws {
        let defaults = defaults()
        let folder = try temporaryFolder()
        let replacement = try temporaryFolder()
        defer {
            try? FileManager.default.removeItem(at: folder)
            try? FileManager.default.removeItem(at: replacement)
        }
        var failBookmark = false
        var access = FolderStore.Access()
        access.makeBookmark = { _ in
            if failBookmark { throw CocoaError(.fileWriteUnknown) }
            return Data([42])
        }
        let store = FolderStore(defaults: defaults, access: access)
        try store.select(folder)
        failBookmark = true
        XCTAssertThrowsError(try store.select(replacement))
        XCTAssertEqual(store.root, folder)
        XCTAssertEqual(defaults.data(forKey: "document-folder-bookmark"), Data([42]))
    }

    func testFailedReauthorizationKeepsPendingAndValidFolderThenCancellationClearsError() async throws {
        let defaults = defaults()
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("pending.md")
        try "# Untouched\n".write(to: file, atomically: true, encoding: .utf8)
        var denyRead = false
        var access = FolderStore.Access()
        let readDirectory = access.readDirectory
        access.readDirectory = { url, keys, options in
            if denyRead { throw CocoaError(.fileReadNoPermission) }
            return try readDirectory(url, keys, options)
        }
        let folders = FolderStore(defaults: defaults, access: access)
        try folders.select(folder)
        let saved = defaults.data(forKey: "document-folder-bookmark")
        var starts = 0, stops = 0
        let session = DocumentOpenCoordinator(folders: folders, openDocument: { _ in false },
            startAccess: { _ in starts += 1; return true }, stopAccess: { _ in stops += 1 })
        await session.receiveExternal(file)
        denyRead = true
        await session.selectFolder(folder)
        XCTAssertEqual(session.pendingURL, file)
        XCTAssertTrue(session.canReauthorizePending)
        XCTAssertNotNil(session.error)
        XCTAssertEqual(folders.root, folder)
        XCTAssertEqual(defaults.data(forKey: "document-folder-bookmark"), saved)
        XCTAssertEqual(starts, 2)
        XCTAssertEqual(stops, 1, "Picker callback scope must be released even on authorization failure")
        session.cancelPending()
        XCTAssertNil(session.error)
        XCTAssertNil(session.pendingURL)
        XCTAssertEqual(stops, 2)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "# Untouched\n")
    }

    func testPendingReauthorizationCannotReplaceCurrentUnsavedEditor() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = folder.appendingPathComponent("first.md")
        let second = folder.appendingPathComponent("second.md")
        try "# First\n".write(to: first, atomically: true, encoding: .utf8)
        try "# Second\n".write(to: second, atomically: true, encoding: .utf8)
        let folders = FolderStore(defaults: defaults())
        try folders.select(folder)
        let session = DocumentOpenCoordinator(folders: folders)
        await session.open(first)
        let current = try XCTUnwrap(session.opened)
        current.acceptNormalization()
        current.replaceBody(MarkdownEngine.parse(markdown: "# Unsaved edit\n"))
        await session.receiveExternal(second)
        await session.selectFolder(folder)
        XCTAssertTrue(session.opened === current)
        XCTAssertTrue(current.source.contains("Unsaved edit"))
        XCTAssertEqual(session.pendingURL, second)
        session.cancelPending()
        XCTAssertTrue(session.opened === current)
        XCTAssertTrue(current.source.contains("Unsaved edit"))
        XCTAssertEqual(try String(contentsOf: second, encoding: .utf8), "# Second\n")
        // Explicitly save only during cleanup; cancellation itself must not touch either document.
        _ = await current.saveNow()
        _ = await current.close()
        await session.didDismiss()
    }

    func testRealDirectoryWithMarkdownExtensionStillSelectsAsFolderAndClearsOldError() async throws {
        let parent = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: parent) }
        let folder = parent.appendingPathComponent("folder.md")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let folders = FolderStore(defaults: defaults())
        folders.error = "Old restoration error"
        let session = DocumentOpenCoordinator(folders: folders)
        session.error = "Old picker error"
        await session.selectFolder(folder)
        XCTAssertEqual(folders.root, folder)
        XCTAssertNil(folders.error)
        XCTAssertNil(session.error)
        XCTAssertNil(session.pendingURL)
        XCTAssertNil(session.opened)
    }

    func testSuspendedListOpenFailureDoesNotReplaceNewPendingRequest() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = folder.appendingPathComponent("first.md")
        let second = folder.appendingPathComponent("second.md")
        let folders = FolderStore(defaults: defaults())
        try folders.select(folder)
        let began = expectation(description: "Document open suspended")
        var finish: CheckedContinuation<Bool, Never>?
        var stops: [URL] = []
        let session = DocumentOpenCoordinator(folders: folders, openDocument: { _ in
            await withCheckedContinuation { continuation in
                finish = continuation
                began.fulfill()
            }
        }, startAccess: { _ in true }, stopAccess: { stops.append($0) })
        let opening = Task { await session.open(first) }
        await fulfillment(of: [began], timeout: 2)
        await session.receiveExternal(second)
        XCTAssertEqual(session.pendingURL, second)
        finish?.resume(returning: false)
        await opening.value
        XCTAssertEqual(session.pendingURL, second)
        XCTAssertFalse(session.canReauthorizePending, "The failed first request must not mark a different request as failed")
        XCTAssertEqual(stops, [first])
        session.cancelPending()
        XCTAssertEqual(stops, [first, second])
    }

    private func temporaryFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
