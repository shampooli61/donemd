import XCTest
@testable import donemd

final class FirstSavePromptCoordinatorTests: XCTestCase {

    /// Each test gets its own UserDefaults suite so they don't see each
    /// other's writes or pollute the real domain.
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        suiteName = "donemd.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
    }

    // MARK: shouldPrompt

    func testShouldPromptIsTrueForUntrackedFile() {
        let coord = FirstSavePromptCoordinator(defaults: defaults)
        let url = URL(fileURLWithPath: "/tmp/donemd-test-\(UUID()).md")
        XCTAssertTrue(coord.shouldPrompt(forFileAt: url))
    }

    func testShouldPromptIsFalseForUntitledDocument() {
        let coord = FirstSavePromptCoordinator(defaults: defaults)
        XCTAssertFalse(coord.shouldPrompt(forFileAt: nil),
                       "Untitled docs never trigger the first-save prompt — no path to track")
    }

    func testShouldPromptIsFalseForNonFileURL() {
        let coord = FirstSavePromptCoordinator(defaults: defaults)
        let httpURL = URL(string: "https://example.com/x.md")!
        XCTAssertFalse(coord.shouldPrompt(forFileAt: httpURL))
    }

    // MARK: markPrompted

    func testMarkPromptedSilencesSubsequentShouldPrompt() {
        let coord = FirstSavePromptCoordinator(defaults: defaults)
        let url = URL(fileURLWithPath: "/tmp/donemd-test-mark.md")
        coord.markPrompted(forFileAt: url)
        XCTAssertFalse(coord.shouldPrompt(forFileAt: url))
    }

    func testMarkPromptedIsIdempotent() {
        let coord = FirstSavePromptCoordinator(defaults: defaults)
        let url = URL(fileURLWithPath: "/tmp/donemd-test-idempotent.md")
        coord.markPrompted(forFileAt: url)
        coord.markPrompted(forFileAt: url)
        coord.markPrompted(forFileAt: url)
        // Underlying storage shouldn't grow.
        let stored = defaults.stringArray(forKey: "donemd.firstSavePromptedFiles") ?? []
        XCTAssertEqual(stored.count, 1)
    }

    func testDifferentFilesTrackedIndependently() {
        let coord = FirstSavePromptCoordinator(defaults: defaults)
        let a = URL(fileURLWithPath: "/tmp/donemd-test-a.md")
        let b = URL(fileURLWithPath: "/tmp/donemd-test-b.md")
        coord.markPrompted(forFileAt: a)
        XCTAssertFalse(coord.shouldPrompt(forFileAt: a))
        XCTAssertTrue(coord.shouldPrompt(forFileAt: b))
    }

    // MARK: persistence across coordinator instances

    func testPromptedStatePersistsAcrossInstances() {
        let url = URL(fileURLWithPath: "/tmp/donemd-test-persist.md")
        let first = FirstSavePromptCoordinator(defaults: defaults)
        first.markPrompted(forFileAt: url)

        // Simulate app relaunch — same UserDefaults backing, fresh coordinator.
        let second = FirstSavePromptCoordinator(defaults: defaults)
        XCTAssertFalse(second.shouldPrompt(forFileAt: url),
                       "marker should persist across coordinator instances")
    }

    // MARK: rename / move behavior (documented Phase 1 limitation)

    func testRenamingFileResurfacesPrompt() {
        // Per ADR-0002: path-based keying means a rename / move is
        // observed as a fresh file. The user sees the first-save prompt
        // again at the new path. Tracked here as the canonical expectation
        // so we don't accidentally change it.
        let coord = FirstSavePromptCoordinator(defaults: defaults)
        let original = URL(fileURLWithPath: "/tmp/donemd-test-original.md")
        let renamed  = URL(fileURLWithPath: "/tmp/donemd-test-renamed.md")
        coord.markPrompted(forFileAt: original)
        XCTAssertFalse(coord.shouldPrompt(forFileAt: original))
        XCTAssertTrue(coord.shouldPrompt(forFileAt: renamed))
    }

    // MARK: forgetPrompt (test escape hatch)

    func testForgetPromptResurfacesSingleFile() {
        let coord = FirstSavePromptCoordinator(defaults: defaults)
        let url = URL(fileURLWithPath: "/tmp/donemd-test-forget.md")
        coord.markPrompted(forFileAt: url)
        coord.forgetPrompt(forFileAt: url)
        XCTAssertTrue(coord.shouldPrompt(forFileAt: url))
    }

    func testForgetPromptWithNilClearsAll() {
        let coord = FirstSavePromptCoordinator(defaults: defaults)
        let a = URL(fileURLWithPath: "/tmp/donemd-test-clear-a.md")
        let b = URL(fileURLWithPath: "/tmp/donemd-test-clear-b.md")
        coord.markPrompted(forFileAt: a)
        coord.markPrompted(forFileAt: b)
        coord.forgetPrompt(forFileAt: nil)
        XCTAssertTrue(coord.shouldPrompt(forFileAt: a))
        XCTAssertTrue(coord.shouldPrompt(forFileAt: b))
    }
}
