import XCTest
@testable import donemd

/// Pure classification behind single-click link following. Path resolution and
/// NSWorkspace opening are verified by hand on-device per project convention;
/// here we lock the intent decision table (mirrors FeishuURLDetectorTests).
final class LinkTargetTests: XCTestCase {

    // MARK: Web URLs

    func testHTTPSIsWeb() {
        XCTAssertEqual(
            LinkTarget.classify("https://example.com/path?q=1#frag"),
            .web(URL(string: "https://example.com/path?q=1#frag")!)
        )
    }

    func testHTTPIsWeb() {
        XCTAssertEqual(LinkTarget.classify("http://example.com"),
                       .web(URL(string: "http://example.com")!))
    }

    func testMailtoIsWeb() {
        XCTAssertEqual(LinkTarget.classify("mailto:a@b.com"),
                       .web(URL(string: "mailto:a@b.com")!))
    }

    func testSchemeIsCaseInsensitive() {
        XCTAssertEqual(LinkTarget.classify("HTTPS://example.com"),
                       .web(URL(string: "HTTPS://example.com")!))
    }

    // MARK: Dangerous / unsupported schemes → reject

    func testJavascriptRejected() {
        XCTAssertEqual(LinkTarget.classify("javascript:alert(1)"), .reject)
    }

    func testDataRejected() {
        XCTAssertEqual(LinkTarget.classify("data:text/html,<h1>x</h1>"), .reject)
    }

    func testVBScriptRejected() {
        XCTAssertEqual(LinkTarget.classify("vbscript:msgbox(1)"), .reject)
    }

    func testEmptyRejected() {
        XCTAssertEqual(LinkTarget.classify(""), .reject)
        XCTAssertEqual(LinkTarget.classify("   \n "), .reject)
    }

    func testInPageAnchorRejected() {
        XCTAssertEqual(LinkTarget.classify("#section-2"), .reject)
    }

    // MARK: Local paths

    func testAbsolutePathIsLocal() {
        XCTAssertEqual(LinkTarget.classify("/Users/x/notes.md"),
                       .localPath("/Users/x/notes.md", mayFallBackToWeb: false))
    }

    func testTildePathIsLocal() {
        XCTAssertEqual(LinkTarget.classify("~/Documents/notes.md"),
                       .localPath("~/Documents/notes.md", mayFallBackToWeb: false))
    }

    func testDotSlashRelativeIsLocal() {
        XCTAssertEqual(LinkTarget.classify("./assets/foo.png"),
                       .localPath("./assets/foo.png", mayFallBackToWeb: false))
    }

    func testDotDotSlashRelativeIsLocal() {
        XCTAssertEqual(LinkTarget.classify("../sibling/foo.md"),
                       .localPath("../sibling/foo.md", mayFallBackToWeb: false))
    }

    func testFileSchemeNormalizesToLocalPath() {
        XCTAssertEqual(LinkTarget.classify("file:///Users/x/notes.md"),
                       .localPath("/Users/x/notes.md", mayFallBackToWeb: false))
    }

    func testDotlessBareNameIsLocalNoWebFallback() {
        // No extension, no scheme → can only be a relative file.
        XCTAssertEqual(LinkTarget.classify("README"),
                       .localPath("README", mayFallBackToWeb: false))
    }

    // MARK: Ambiguous schemeless-with-dot → local first, web fallback

    func testBareDomainAllowsWebFallback() {
        XCTAssertEqual(LinkTarget.classify("example.com"),
                       .localPath("example.com", mayFallBackToWeb: true))
    }

    func testBareRelativeFileWithExtensionAllowsWebFallback() {
        // `notes.md` and `example.com` are indistinguishable without a TLD
        // list; both resolve local-first, then https as fallback.
        XCTAssertEqual(LinkTarget.classify("notes.md"),
                       .localPath("notes.md", mayFallBackToWeb: true))
    }
}
