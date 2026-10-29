import XCTest

final class MobileWritingUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }
    private func moreButton(_ app: XCUIApplication) -> XCUIElement {
        // ToolbarOverflowMenu owns its system label; only the iOS17 fallback has our ID.
        app.buttons.matching(NSPredicate(format: "identifier == %@ OR label IN %@", "native-more", ["更多", "更多操作", "More", "More Actions"])).firstMatch
    }
    private func waitForEditor(_ app: XCUIApplication) {
        XCTAssertTrue(moreButton(app).waitForExistence(timeout: 25))
        // Native formatting appears only after WebKit has loaded and published editor readiness.
        XCTAssertTrue(app.buttons["native-format"].waitForExistence(timeout: 45))
        XCTAssertFalse(app.webViews.buttons["格式"].exists, "Native and web controls must not both be exposed")
        XCTAssertFalse(app.webViews.buttons["源码"].exists, "Old reading bar must not remain exposed")
    }
    private func openSource(_ app: XCUIApplication) -> XCUIElement {
        moreButton(app).tap()
        let source = app.buttons["查看 Markdown 源码"]
        XCTAssertTrue(source.waitForExistence(timeout: 5)); source.tap()
        let text = app.staticTexts["native-source-text"]
        XCTAssertTrue(text.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["仅供查看，不能在此编辑。"].exists)
        return text
    }
    private func sourceValue(_ element: XCUIElement) -> String {
        // The source mirror is a selectable SwiftUI Text, not a text field.
        // XCTest can expose an empty value for static text; its label is the content.
        element.elementType == .staticText ? element.label : ((element.value as? String) ?? element.label)
    }
    private func insertTable(_ app: XCUIApplication) {
        app.buttons["native-insert"].tap()
        let table = app.buttons["表格"]
        XCTAssertTrue(table.waitForExistence(timeout: 5)); table.tap()
        let create = app.buttons["native-table-create"]
        XCTAssertTrue(create.waitForExistence(timeout: 5)); create.tap()
        XCTAssertTrue(moreButton(app).waitForExistence(timeout: 10))
    }

    func testToolbarMenusAndRecoveryCloseRemainAccessible() {
        let app = XCUIApplication()
        app.launchArguments = ["--uitest-fixture"]
        app.launch()
        let fileOperations = app.buttons["更多操作"]
        XCTAssertTrue(fileOperations.waitForExistence(timeout: 15))
        XCTAssertTrue(fileOperations.isHittable)
        fileOperations.tap()
        let refresh = app.buttons["刷新"]
        XCTAssertTrue(refresh.waitForExistence(timeout: 5)); refresh.tap()
        let file = app.buttons["测试文档"]
        XCTAssertTrue(file.waitForExistence(timeout: 10)); file.tap()
        waitForEditor(app)
        let documentOperations = moreButton(app)
        XCTAssertTrue(documentOperations.isHittable); documentOperations.tap()
        let recovery = app.buttons["恢复版本"]
        XCTAssertTrue(recovery.waitForExistence(timeout: 5)); recovery.tap()
        let close = app.buttons["关闭"]
        XCTAssertTrue(close.waitForExistence(timeout: 5)); XCTAssertTrue(close.isHittable); close.tap()
        let back = app.buttons["保存并返回目录"]
        XCTAssertTrue(back.waitForExistence(timeout: 5)); XCTAssertTrue(back.isHittable); back.tap()
        XCTAssertTrue(file.waitForExistence(timeout: 10))
    }

    func testOpenInsertTableInspectReadOnlySourceAndReopen() {
        let app = XCUIApplication()
        app.launchArguments = ["--uitest-fixture"]
        app.launch()
        let file = app.buttons["测试文档"]
        XCTAssertTrue(file.waitForExistence(timeout: 15)); file.tap()
        waitForEditor(app)
        insertTable(app)
        let source = openSource(app)
        XCTAssertTrue(sourceValue(source).contains("| ---"), "Table must be in current source, not only the visual body")
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Native read-only source mirror"; screenshot.lifetime = .keepAlways; add(screenshot)
        app.buttons["native-source-close"].tap()
        moreButton(app).tap(); app.buttons["阅读模式"].tap()
        XCTAssertTrue(app.buttons["编辑"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["无效的预览类型"].exists, "Reading mode must not dispatch a preview for a dismissed panel")
        XCTAssertFalse(app.buttons["native-insert"].exists)
        moreButton(app).tap()
        let history = app.buttons["恢复版本"]
        XCTAssertTrue(history.waitForExistence(timeout: 5)); XCTAssertTrue(history.isEnabled); history.tap()
        XCTAssertTrue(app.buttons["关闭"].waitForExistence(timeout: 5)); app.buttons["关闭"].tap()
        app.buttons["编辑"].tap()
        XCTAssertTrue(app.buttons["native-insert"].waitForExistence(timeout: 5))
        app.buttons["保存并返回目录"].tap()
        XCTAssertTrue(file.waitForExistence(timeout: 10)); file.tap(); waitForEditor(app)
        XCTAssertTrue(sourceValue(openSource(app)).contains("| ---"), "Saved/reopened table must survive")
        app.buttons["native-source-close"].tap()
    }

    func testNativeFormatPanelCancelPreservesCurrentSource() {
        let app = XCUIApplication()
        app.launchArguments = ["--uitest-fixture"]
        app.launch()
        let file = app.buttons["测试文档"]
        XCTAssertTrue(file.waitForExistence(timeout: 15)); file.tap(); waitForEditor(app)
        let before = sourceValue(openSource(app))
        XCTAssertTrue(before.contains("这里是手机写作测试。"))
        app.buttons["native-source-close"].tap()
        app.buttons["native-format"].tap()
        let bold = app.buttons["粗体"]
        if !bold.waitForExistence(timeout: 2) { app.swipeUp() }
        XCTAssertTrue(bold.waitForExistence(timeout: 5))
        XCTAssertFalse(app.webViews.buttons["粗体"].exists, "Format choices must be native")
        app.buttons["native-format-close"].tap()
        XCTAssertEqual(sourceValue(openSource(app)), before, "Closing without an action must not change content")
        app.buttons["native-source-close"].tap()
        app.buttons["保存并返回目录"].tap()
        XCTAssertTrue(file.waitForExistence(timeout: 10))
    }

    func testReturnRequestsNormalizationAndCancelKeepsDocumentOpen() {
        let app = XCUIApplication()
        app.launchArguments = ["--uitest-fixture", "--uitest-noncanonical"]
        app.launch()
        let file = app.buttons["测试文档"]
        XCTAssertTrue(file.waitForExistence(timeout: 15)); file.tap(); waitForEditor(app)
        app.buttons["保存并返回目录"].tap()
        XCTAssertTrue(file.waitForExistence(timeout: 10)); file.tap(); waitForEditor(app)
        insertTable(app)
        app.buttons["保存并返回目录"].tap()
        let confirmation = app.alerts["确认首次保存"]
        XCTAssertTrue(confirmation.waitForExistence(timeout: 5))
        confirmation.buttons["继续编辑"].tap()
        XCTAssertTrue(moreButton(app).exists)
        app.buttons["保存并返回目录"].tap()
        XCTAssertTrue(confirmation.waitForExistence(timeout: 5))
        confirmation.buttons["保存并返回"].tap()
        XCTAssertTrue(file.waitForExistence(timeout: 10)); file.tap(); waitForEditor(app)
        XCTAssertTrue(sourceValue(openSource(app)).contains("| ---"))
        app.buttons["native-source-close"].tap()
        app.buttons["保存并返回目录"].tap()
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
        app.buttons["取消打开"].tap(); app.buttons["测试文档"].tap(); waitForEditor(app)
        XCUIDevice.shared.system.open(file)
        XCTAssertTrue(app.buttons["取消待打开文档"].waitForExistence(timeout: 10))
        XCTAssertTrue(moreButton(app).exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "External request preserves current editor"; screenshot.lifetime = .keepAlways; add(screenshot)
        app.buttons["取消待打开文档"].tap(); app.buttons["保存并返回目录"].tap()
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
