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
}
