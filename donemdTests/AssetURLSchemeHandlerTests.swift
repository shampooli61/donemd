import XCTest
@testable import donemd

final class AssetURLSchemeHandlerTests: XCTestCase {

    // MARK: filename parsing

    func testParsesPlainFilename() {
        let url = URL(string: "donemd-asset://abc123.png")!
        XCTAssertEqual(AssetURLSchemeHandler.filename(from: url), "abc123.png")
    }

    func testRejectsForeignSchemes() {
        XCTAssertNil(AssetURLSchemeHandler.filename(from: URL(string: "https://example.com/x.png")!))
        XCTAssertNil(AssetURLSchemeHandler.filename(from: URL(string: "file:///tmp/x.png")!))
    }

    func testStripsLeadingSlashes() {
        let url = URL(string: "donemd-asset:///abc.png")!
        XCTAssertEqual(AssetURLSchemeHandler.filename(from: url), "abc.png")
    }

    func testStripsQueryAndFragment() {
        let q = URL(string: "donemd-asset://abc.png?v=2")!
        XCTAssertEqual(AssetURLSchemeHandler.filename(from: q), "abc.png")
        let f = URL(string: "donemd-asset://abc.png#frag")!
        XCTAssertEqual(AssetURLSchemeHandler.filename(from: f), "abc.png")
    }

    // MARK: mime type mapping

    func testMimeTypeForCommonExtensions() {
        let cases: [(String, String)] = [
            ("foo.png", "image/png"),
            ("foo.PNG", "image/png"),
            ("foo.jpg", "image/jpeg"),
            ("foo.jpeg", "image/jpeg"),
            ("foo.gif", "image/gif"),
            ("foo.webp", "image/webp"),
            ("foo.heic", "image/heic"),
            ("foo.heif", "image/heic"),
            ("foo.svg", "image/svg+xml"),
            ("foo.tiff", "image/tiff"),
            ("foo.bmp", "image/bmp"),
            // Local video (#88).
            ("foo.mp4", "video/mp4"),
            ("foo.MP4", "video/mp4"),
            ("foo.mov", "video/quicktime"),
            ("foo.qt", "video/quicktime"),
            ("foo.m4v", "video/x-m4v"),
            ("foo.webm", "video/webm"),
            ("noext", "application/octet-stream"),
            ("foo.bin", "application/octet-stream"),
        ]
        for (filename, expected) in cases {
            XCTAssertEqual(
                AssetURLSchemeHandler.mimeType(forFilename: filename),
                expected,
                "filename: \(filename)"
            )
        }
    }

    // MARK: Range header parsing (#88 — <video> seek issues HTTP Range requests)

    func testParsesClosedRange() {
        let r = AssetURLSchemeHandler.parseByteRange("bytes=0-499", totalLength: 1000)
        XCTAssertEqual(r?.start, 0)
        XCTAssertEqual(r?.end, 499)
    }

    func testParsesOpenEndedRangeToLastByte() {
        // `bytes=500-` means "from 500 to the end" → clamps to totalLength-1.
        let r = AssetURLSchemeHandler.parseByteRange("bytes=500-", totalLength: 1000)
        XCTAssertEqual(r?.start, 500)
        XCTAssertEqual(r?.end, 999)
    }

    func testParsesSuffixRange() {
        // `bytes=-200` means "the last 200 bytes".
        let r = AssetURLSchemeHandler.parseByteRange("bytes=-200", totalLength: 1000)
        XCTAssertEqual(r?.start, 800)
        XCTAssertEqual(r?.end, 999)
    }

    func testSuffixLargerThanFileClampsToStart() {
        // Requesting more suffix than the file has → whole file.
        let r = AssetURLSchemeHandler.parseByteRange("bytes=-5000", totalLength: 1000)
        XCTAssertEqual(r?.start, 0)
        XCTAssertEqual(r?.end, 999)
    }

    func testEndBeyondFileClampsToLastByte() {
        let r = AssetURLSchemeHandler.parseByteRange("bytes=990-100000", totalLength: 1000)
        XCTAssertEqual(r?.start, 990)
        XCTAssertEqual(r?.end, 999)
    }

    func testWhitespaceTolerant() {
        let r = AssetURLSchemeHandler.parseByteRange("  bytes=10-20  ", totalLength: 1000)
        XCTAssertEqual(r?.start, 10)
        XCTAssertEqual(r?.end, 20)
    }

    func testRejectsMultipartRange() {
        XCTAssertNil(AssetURLSchemeHandler.parseByteRange("bytes=0-99,200-299", totalLength: 1000))
    }

    func testRejectsMissingBytesPrefix() {
        XCTAssertNil(AssetURLSchemeHandler.parseByteRange("0-499", totalLength: 1000))
        XCTAssertNil(AssetURLSchemeHandler.parseByteRange("items=0-499", totalLength: 1000))
    }

    func testRejectsStartBeyondFile() {
        // start >= totalLength is unsatisfiable → nil (caller serves full 200).
        XCTAssertNil(AssetURLSchemeHandler.parseByteRange("bytes=1000-1500", totalLength: 1000))
        XCTAssertNil(AssetURLSchemeHandler.parseByteRange("bytes=2000-", totalLength: 1000))
    }

    func testRejectsInvertedRange() {
        XCTAssertNil(AssetURLSchemeHandler.parseByteRange("bytes=500-100", totalLength: 1000))
    }

    func testRejectsMalformedAndEmptyRanges() {
        XCTAssertNil(AssetURLSchemeHandler.parseByteRange("bytes=", totalLength: 1000))
        XCTAssertNil(AssetURLSchemeHandler.parseByteRange("bytes=abc-def", totalLength: 1000))
        XCTAssertNil(AssetURLSchemeHandler.parseByteRange("bytes=-", totalLength: 1000))
        XCTAssertNil(AssetURLSchemeHandler.parseByteRange("bytes=-0", totalLength: 1000))
    }

    func testRejectsAnyRangeOnEmptyFile() {
        XCTAssertNil(AssetURLSchemeHandler.parseByteRange("bytes=0-0", totalLength: 0))
    }
}
