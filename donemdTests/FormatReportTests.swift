import XCTest
@testable import donemd

final class FormatReportTests: XCTestCase {

    func testEmptyInputProducesNoChanges() {
        let report = FormatReportComputer.compute(originalMarkdown: "")
        XCTAssertFalse(report.hasAnyChange)
        XCTAssertTrue(report.summaryItems.isEmpty)
    }

    func testCanonicalInputProducesNoChanges() {
        let canonical = """
        # Title

        - one
        - two

        body text
        """
        // Note: missing trailing newline → that's a fix. So this isn't
        // strictly "no changes". Add the trailing newline.
        let report = FormatReportComputer.compute(originalMarkdown: canonical + "\n")
        XCTAssertFalse(report.hasAnyChange, "should be: \(report.summaryItems)")
    }

    func testSetextHeadingCounted() {
        let input = """
        First

        Hello
        =====

        Body
        """
        let report = FormatReportComputer.compute(originalMarkdown: input)
        XCTAssertEqual(report.setextHeadings, 1)
        XCTAssertTrue(report.summaryItems.contains(where: { $0.hasPrefix("标题格式统一") }))
    }

    func testStarBulletCounted() {
        let input = "* one\n* two\n* three\n"
        let report = FormatReportComputer.compute(originalMarkdown: input)
        XCTAssertEqual(report.bulletNormalization, 3)
    }

    func testPlusBulletCounted() {
        let input = "+ a\n+ b\n"
        let report = FormatReportComputer.compute(originalMarkdown: input)
        XCTAssertEqual(report.bulletNormalization, 2)
    }

    func testNestedStarBulletCounted() {
        let input = "- top\n  * nested\n  * nested\n"
        let report = FormatReportComputer.compute(originalMarkdown: input)
        XCTAssertEqual(report.bulletNormalization, 2)
    }

    func testUnderscoreItalicCounted() {
        let input = "this is _italic_ and _so_ is this\n"
        let report = FormatReportComputer.compute(originalMarkdown: input)
        XCTAssertEqual(report.emphasisNormalization, 2)
    }

    func testUnderscoreBoldCounted() {
        let input = "__bold__ here\n"
        let report = FormatReportComputer.compute(originalMarkdown: input)
        XCTAssertEqual(report.emphasisNormalization, 1)
    }

    func testMultipleBlankLinesCounted() {
        let input = "first\n\n\n\nsecond\n\n\nthird\n"
        let report = FormatReportComputer.compute(originalMarkdown: input)
        // Two runs of ≥2 consecutive blank lines.
        XCTAssertEqual(report.blankLinesCollapsed, 2)
    }

    func testTrailingWhitespaceCounted() {
        let input = "hello   \nworld  \nclean\n"
        let report = FormatReportComputer.compute(originalMarkdown: input)
        XCTAssertEqual(report.trailingWhitespaceLines, 2)
    }

    func testMissingTrailingNewlineFlagged() {
        let report = FormatReportComputer.compute(originalMarkdown: "hello")
        XCTAssertTrue(report.trailingNewlineFix)
    }

    func testSummaryFormatting() {
        let input = """
        Title
        =====

        * one
        * two

        _italic_ here
        """
        let report = FormatReportComputer.compute(originalMarkdown: input + "\n")
        XCTAssertTrue(report.summaryItems.contains(where: { $0 == "标题格式统一（1 处）" }))
        XCTAssertTrue(report.summaryItems.contains(where: { $0 == "列表符号标准化（2 处）" }))
        XCTAssertTrue(report.summaryItems.contains(where: { $0 == "强调写法统一（1 处）" }))
    }
}

final class LineDiffTests: XCTestCase {

    func testIdenticalInputsHaveNoChanges() {
        let diff = LineDiffComputer.compute(before: "a\nb\nc\n", after: "a\nb\nc\n")
        XCTAssertFalse(diff.hasAnyChange)
    }

    func testInsertedLineMarkedAdded() {
        let diff = LineDiffComputer.compute(before: "a\nc\n", after: "a\nb\nc\n")
        XCTAssertTrue(diff.afterLines.contains(where: { $0.text == "b" && $0.status == .added }))
        XCTAssertTrue(diff.beforeLines.allSatisfy { $0.status == .unchanged })
    }

    func testRemovedLineMarkedRemoved() {
        let diff = LineDiffComputer.compute(before: "a\nb\nc\n", after: "a\nc\n")
        XCTAssertTrue(diff.beforeLines.contains(where: { $0.text == "b" && $0.status == .removed }))
        XCTAssertTrue(diff.afterLines.allSatisfy { $0.status == .unchanged })
    }

    func testModifiedLineSurfacesAsRemovedAndAdded() {
        let diff = LineDiffComputer.compute(before: "Hello\n=====\n", after: "# Hello\n")
        XCTAssertTrue(diff.hasAnyChange)
        XCTAssertTrue(diff.beforeLines.contains(where: { $0.status == .removed }))
        XCTAssertTrue(diff.afterLines.contains(where: { $0.status == .added }))
    }
}
