import XCTest

final class MobileWritingUITests: XCTestCase {
    func testOpenInsertTableInspectReadOnlySourceAndReopen() {
        let app = XCUIApplication()
        app.launchArguments = ["--uitest-fixture"]
        app.launch()
        let file = app.buttons["测试文档"]
        XCTAssertTrue(file.waitForExistence(timeout: 15)); file.tap()
        let insert = app.webViews.buttons["插入"]
        XCTAssertTrue(insert.waitForExistence(timeout: 20))
        insert.tap()
        app.webViews.buttons["表格"].tap()
        app.webViews.buttons["创建表格"].tap()
        app.webViews.buttons["源码"].tap()
        XCTAssertTrue(app.webViews.staticTexts["Markdown 源码 · 只读"].waitForExistence(timeout: 5))
        let screenshot = XCTAttachment(screenshot: app.screenshot()); screenshot.name = "iOS source mirror"; screenshot.lifetime = .keepAlways; add(screenshot)
        app.webViews.buttons["关闭"].tap()
        app.webViews.buttons["阅读"].tap()
        XCTAssertTrue(app.webViews.buttons["编辑"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.webViews.buttons["插入"].exists)
        app.webViews.buttons["编辑"].tap()
        app.buttons["返回"].tap()
        XCTAssertTrue(file.waitForExistence(timeout: 10)); file.tap()
        XCTAssertTrue(app.webViews.buttons["源码"].waitForExistence(timeout: 15))
    }
    func testReturnRequestsNormalizationAndCancelKeepsDocumentOpen() {
        let app = XCUIApplication()
        app.launchArguments = ["--uitest-fixture", "--uitest-noncanonical"]
        app.launch()
        let file = app.buttons["测试文档"]
        XCTAssertTrue(file.waitForExistence(timeout: 15)); file.tap()
        XCTAssertTrue(app.webViews.buttons["插入"].waitForExistence(timeout: 20))
        // Reading and returning must not require permission to rewrite the file.
        app.buttons["返回"].tap()
        XCTAssertTrue(file.waitForExistence(timeout: 10)); file.tap()
        XCTAssertTrue(app.webViews.buttons["插入"].waitForExistence(timeout: 20))
        app.webViews.buttons["插入"].tap()
        app.webViews.buttons["表格"].tap()
        app.webViews.buttons["创建表格"].tap()
        app.buttons["返回"].tap()
        let confirmation = app.alerts["确认首次保存"]
        XCTAssertTrue(confirmation.waitForExistence(timeout: 5))
        confirmation.buttons["继续编辑"].tap()
        XCTAssertTrue(app.webViews.buttons["源码"].exists)
        app.buttons["返回"].tap()
        XCTAssertTrue(confirmation.waitForExistence(timeout: 5))
        confirmation.buttons["保存并返回"].tap()
        XCTAssertTrue(file.waitForExistence(timeout: 10)); file.tap()
        XCTAssertTrue(app.webViews.buttons["源码"].waitForExistence(timeout: 20))
        app.webViews.buttons["源码"].tap()
        XCTAssertTrue(app.webViews.staticTexts["Markdown 源码 · 只读"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.webViews.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "| ---")).firstMatch.exists)
        app.webViews.buttons["关闭"].tap()
        app.buttons["返回"].tap()
        XCTAssertTrue(file.waitForExistence(timeout: 10))
    }

    func testExternalURLColdAndWarmLaunchRequestsFolderWithoutReplacingEditor() throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("iOS blocks system.open of the runner's private file. Verify warm Files dispatch with a user-selected iCloud document; cold URL delivery has a separate device test.")
        #else
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("External-" + UUID().uuidString + ".md")
        try "# External URL fixture\n".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        let app = XCUIApplication()
        app.launchArguments = ["--uitest-fixture"]
        app.open(file)
        XCTAssertTrue(app.buttons["选择文档所在文件夹"].waitForExistence(timeout: 15))
        app.buttons["取消打开"].tap()
        app.buttons["测试文档"].tap()
        XCTAssertTrue(app.webViews.buttons["源码"].waitForExistence(timeout: 20))
        XCUIDevice.shared.system.open(file)
        XCTAssertTrue(app.buttons["取消待打开文档"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.webViews.buttons["源码"].exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "External request preserves current editor"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.buttons["取消待打开文档"].tap()
        app.buttons["返回"].tap()
        XCTAssertTrue(app.buttons["测试文档"].waitForExistence(timeout: 10))
        #endif
    }

    func testExternalURLColdLaunchRequestsFolderAndCanCancel() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("External-" + UUID().uuidString + ".md")
        try "# External cold launch\n".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        let app = XCUIApplication()
        app.launchArguments = ["--uitest-fixture"]
        app.open(file)
        XCTAssertTrue(app.buttons["选择文档所在文件夹"].waitForExistence(timeout: 15))
        app.buttons["取消打开"].tap()
        XCTAssertTrue(app.buttons["测试文档"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["选择文档所在文件夹"].exists)
    }

}
