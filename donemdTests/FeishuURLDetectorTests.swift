import XCTest
@testable import donemd

final class FeishuURLDetectorTests: XCTestCase {

    // MARK: docx

    func testExtractsDocxFromFeishuCN() {
        let url = "https://bytedance.feishu.cn/docx/doxcnAbc123XYZ"
        let parsed = FeishuURLDetector.extract(url)
        XCTAssertEqual(parsed?.kind, .docx)
        XCTAssertEqual(parsed?.token, "doxcnAbc123XYZ")
        XCTAssertEqual(parsed?.originalURL, url)
    }

    func testExtractsDocxFromLarksuite() {
        let url = "https://example.larksuite.com/docx/doxcnLarkXYZ123"
        let parsed = FeishuURLDetector.extract(url)
        XCTAssertEqual(parsed?.kind, .docx)
        XCTAssertEqual(parsed?.token, "doxcnLarkXYZ123")
    }

    func testExtractsDocxFromMioffice() {
        let url = "https://f.mioffice.cn/docx/doxcnMioffice99"
        let parsed = FeishuURLDetector.extract(url)
        XCTAssertEqual(parsed?.kind, .docx)
        XCTAssertEqual(parsed?.token, "doxcnMioffice99")
    }

    func testDocxStripsTrailingPathAndQuery() {
        let url = "https://feishu.cn/docx/doxcnHelloWorld?from=share#anchor"
        let parsed = FeishuURLDetector.extract(url)
        XCTAssertEqual(parsed?.kind, .docx)
        XCTAssertEqual(parsed?.token, "doxcnHelloWorld")
    }

    // MARK: wiki

    func testExtractsWiki() {
        let url = "https://bytedance.feishu.cn/wiki/wikcnNodeToken99"
        let parsed = FeishuURLDetector.extract(url)
        XCTAssertEqual(parsed?.kind, .wiki)
        XCTAssertEqual(parsed?.token, "wikcnNodeToken99")
    }

    // MARK: short

    func testExtractsShortLinkOnFeishuHost() {
        let url = "https://feishu.cn/X3kAbCdEfG1"
        let parsed = FeishuURLDetector.extract(url)
        XCTAssertEqual(parsed?.kind, .short)
        XCTAssertEqual(parsed?.token, "X3kAbCdEfG1")
    }

    func testRejectsReservedSinglePathSegment() {
        // /login is reserved — must not be misread as a short link.
        XCTAssertNil(FeishuURLDetector.extract("https://feishu.cn/login"))
        XCTAssertNil(FeishuURLDetector.extract("https://feishu.cn/settings"))
    }

    // MARK: rejection

    func testRejectsGitHub() {
        XCTAssertNil(FeishuURLDetector.extract("https://github.com/owner/repo"))
    }

    func testRejectsNotion() {
        XCTAssertNil(FeishuURLDetector.extract("https://notion.so/Page-abc123"))
    }

    func testRejectsPlainHTTPS() {
        XCTAssertNil(FeishuURLDetector.extract("https://example.com/docx/abc"))
    }

    func testRejectsNonHTTP() {
        XCTAssertNil(FeishuURLDetector.extract("ftp://feishu.cn/docx/doxcnAbc123"))
    }

    func testRejectsEmpty() {
        XCTAssertNil(FeishuURLDetector.extract(""))
        XCTAssertNil(FeishuURLDetector.extract("    "))
    }

    func testRejectsMalformedTokenInDocx() {
        // Token too short — fails tokenPattern.
        XCTAssertNil(FeishuURLDetector.extract("https://feishu.cn/docx/abc"))
    }

    func testRejectsBareDocxPath() {
        XCTAssertNil(FeishuURLDetector.extract("https://feishu.cn/docx/"))
        XCTAssertNil(FeishuURLDetector.extract("https://feishu.cn/docx"))
    }

    // MARK: text extraction

    func testFindsURLEmbeddedInText() {
        let text = "看下这篇 https://feishu.cn/docx/doxcnEmbedded12 吧"
        let parsed = FeishuURLDetector.extract(text)
        XCTAssertEqual(parsed?.kind, .docx)
        XCTAssertEqual(parsed?.token, "doxcnEmbedded12")
    }

    func testFindsFirstURLWhenMultiplePresent() {
        let text = """
        first: https://feishu.cn/docx/doxcnFirst000001
        second: https://feishu.cn/docx/doxcnSecond00002
        """
        let parsed = FeishuURLDetector.extract(text)
        XCTAssertEqual(parsed?.token, "doxcnFirst000001")
    }

    func testSkipsNonFeishuURLAndFindsFeishuOne() {
        let text = "https://github.com/x/y and https://feishu.cn/docx/doxcnRealOne123"
        let parsed = FeishuURLDetector.extract(text)
        XCTAssertEqual(parsed?.kind, .docx)
        XCTAssertEqual(parsed?.token, "doxcnRealOne123")
    }

    // MARK: parse() direct entry

    func testParseDirect() {
        let parsed = FeishuURLDetector.parse("https://feishu.cn/docx/doxcnDirectXYZ1")
        XCTAssertEqual(parsed?.kind, .docx)
        XCTAssertEqual(parsed?.token, "doxcnDirectXYZ1")
    }
}
