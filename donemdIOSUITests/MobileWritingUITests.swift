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
    private func waitForFileList(_ app: XCUIApplication, file: XCUIElement) {
        // The directory remains in the AX tree underneath the document presentation.
        // Its existence alone does not prove save/close has finished.
        XCTAssertTrue(app.buttons["native-view-toggle"].wait(for: \.exists, toEqual: false, timeout: 10),
                      "The editor must finish closing before returning to or reopening the file")
        XCTAssertTrue(file.waitForExistence(timeout: 10))
        XCTAssertTrue(file.wait(for: \.isHittable, toEqual: true, timeout: 10),
                      "The directory file must be actionable, not covered by the editor")
    }
    private func openSource(_ app: XCUIApplication) -> XCUIElement {
        app.buttons["native-view-toggle"].tap()
        XCTAssertTrue(app.staticTexts["Markdown 源·只读"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["在正文中编辑，此处实时更新。"].exists)
        let source = app.webViews["native-source-web"]
        XCTAssertTrue(source.waitForExistence(timeout: 10))
        return source
    }
    private func sourceValue(_ element: XCUIElement) -> String {
        // CodeMirror is a rendered read-only web document. Query actual visible text,
        // not a hidden test-only copy or the document's cached Swift mirror.
        // Read one coherent AX snapshot. Per-node XCUIElement label/frame reads
        // each cross the WebKit process boundary and can exhaust the wait timeout
        // even when the first observed source already satisfies the assertion.
        guard let snapshot = try? element.snapshot() else { return "" }
        if snapshot.elementType == .webView {
            // WebKit may split a syntax-highlighted line into several AX chunks.
            // Only add line breaks between rendered rows, never between inline tokens.
            // AX can also repeat the same node through multiple ancestry paths.
            var chunks: [(text: String, frame: CGRect)] = []
            func collect(_ node: XCUIElementSnapshot) {
                if node.elementType == .staticText {
                    let chunk = (text: node.label, frame: node.frame)
                    if !chunk.text.isEmpty,
                       !chunks.contains(where: { $0.text == chunk.text && $0.frame == chunk.frame }) {
                        chunks.append(chunk)
                    }
                }
                for child in node.children { collect(child) }
            }
            collect(snapshot)
            var text = ""
            var previous: CGRect?
            for chunk in chunks {
                if let previous, abs(previous.minY - chunk.frame.minY) > 2 { text += "\n" }
                text += chunk.text
                previous = chunk.frame
            }
            return text
        }
        return (snapshot.value as? String) ?? snapshot.label
    }
    private func assertSourceContains(_ expected: String, in source: XCUIElement,
                                      _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        var actual = ""
        let rendered = NSPredicate { _, _ in
            actual = self.sourceValue(source)
            return actual.contains(expected)
        }
        _ = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: rendered, object: source)], timeout: 10)
        // Assert the observed content, not the waiter's scheduling result: an AX
        // query can return matching content just as the waiter deadline expires.
        if !actual.contains(expected) {
            let attachment = XCTAttachment(string: "Rendered source:\n\(actual)\n\n\(source.debugDescription)")
            attachment.name = "Source AX failure diagnostics"; attachment.lifetime = .keepAlways; add(attachment)
        }
        XCTAssertTrue(actual.contains(expected), "\(message)\nRendered source: \(actual)", file: file, line: line)
    }
    private func themeMenuEntry(_ app: XCUIApplication) -> XCUIElement {
        // iOS 27's system overflow recreates UIActions and drops SwiftUI identifiers.
        app.buttons.matching(NSPredicate(format: "identifier == %@ OR label == %@", "native-theme-mode", "主题模式")).firstMatch
    }
    private func insertTable(_ app: XCUIApplication) {
        app.buttons["native-insert"].tap()
        let table = app.buttons["表格"]
        XCTAssertTrue(table.waitForExistence(timeout: 5)); table.tap()
        let create = app.buttons["native-table-create"]
        XCTAssertTrue(create.waitForExistence(timeout: 5)); create.tap()
        XCTAssertTrue(create.wait(for: \.exists, toEqual: false, timeout: 10), "Table command must succeed and dismiss its panel")
        XCTAssertTrue(app.buttons["native-insert"].wait(for: \.isHittable, toEqual: true, timeout: 10))
        XCTAssertTrue(moreButton(app).waitForExistence(timeout: 10))
    }

    func testCoreSourceUsesFullPageViewSwitch() {
        let app = XCUIApplication()
        app.launchArguments = ["--uitest-fixture"]
        app.launch()
        let file = app.buttons["测试文档"]
        XCTAssertTrue(file.waitForExistence(timeout: 15)); file.tap()
        waitForEditor(app)
        let view = app.buttons["native-view-toggle"]
        XCTAssertTrue(view.waitForExistence(timeout: 10), "Core source must have a first-level view switch, not only a modal sheet")
        view.tap()
        XCTAssertTrue(app.staticTexts["Markdown 源·只读"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["在正文中编辑，此处实时更新。"].exists)
        XCTAssertFalse(app.buttons["native-insert"].exists, "Source mode must hide body mutation controls")
        XCTAssertFalse(app.buttons["native-source-close"].exists, "Do not retain the obsolete source sheet")
        XCTAssertFalse(app.keyboards.firstMatch.exists, "Read-only source must not summon an editable keyboard")
        view.tap()
        XCTAssertTrue(app.buttons["native-format"].waitForExistence(timeout: 10))
    }

    func testThemeChoiceSharesAuthorityAndSurvivesReopen() {
        let app = XCUIApplication()
        app.launchArguments = ["--uitest-fixture", "--uitest-no-animations"]
        app.launch()
        let file = app.buttons["测试文档"]
        XCTAssertTrue(file.waitForExistence(timeout: 15)); file.tap(); waitForEditor(app)
        moreButton(app).tap()
        let themeEntry = themeMenuEntry(app)
        XCTAssertTrue(themeEntry.waitForExistence(timeout: 5)); themeEntry.tap()
        let paper = app.buttons["native-theme-paper"]
        for id in ["system", "paper", "night"] {
            let choice = app.buttons["native-theme-" + id]
            XCTAssertTrue(choice.waitForExistence(timeout: 10), "Theme form must expose every option, not only its header")
            XCTAssertTrue(choice.wait(for: \.isHittable, toEqual: true, timeout: 10))
        }
        paper.tap()
        XCTAssertTrue(paper.wait(for: \.isSelected, toEqual: true, timeout: 10))
        XCTAssertFalse(app.staticTexts["主题未能切换，请重试"].exists)
        app.buttons["native-panel-close"].tap()
        app.buttons["保存并返回目录"].tap()
        waitForFileList(app, file: file); file.tap(); waitForEditor(app)
        moreButton(app).tap(); XCTAssertTrue(themeMenuEntry(app).waitForExistence(timeout: 5)); themeMenuEntry(app).tap()
        XCTAssertTrue(app.buttons["native-theme-paper"].wait(for: \.isSelected, toEqual: true, timeout: 10))
        for id in ["night", "system"] {
            let choice = app.buttons["native-theme-" + id]
            choice.tap()
            XCTAssertTrue(choice.wait(for: \.isSelected, toEqual: true, timeout: 10))
            XCTAssertFalse(app.staticTexts["主题未能切换，请重试"].exists)
        }
        app.buttons["native-panel-close"].tap()
        XCTAssertFalse(app.alerts["确认首次保存"].exists, "Display-only choices must not demand normalization consent")
    }

    func testThemePickerShowsAllChoicesAfterRotation() {
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = XCUIApplication()
        app.launchArguments = ["--uitest-fixture", "--uitest-no-animations"]
        app.launch()
        // AX application bounds can stay in physical-screen coordinates on Duo;
        // they do not describe the rotated content's usable width and height.
        let landscape = NSPredicate { _, _ in XCUIDevice.shared.orientation == .landscapeLeft }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: landscape, object: app)], timeout: 10), .completed,
                       "The requested landscape orientation must be active")
        let file = app.buttons["测试文档"]
        XCTAssertTrue(file.waitForExistence(timeout: 15)); file.tap(); waitForEditor(app)
        XCTAssertTrue(moreButton(app).wait(for: \.isHittable, toEqual: true, timeout: 10))
        moreButton(app).tap()
        let theme = themeMenuEntry(app)
        XCTAssertTrue(theme.waitForExistence(timeout: 5)); theme.tap()
        // A wide phone can still be height-constrained. Test the actual popover
        // content without assuming this device qualifies for compare mode.
        for id in ["system", "paper", "night"] {
            let choice = app.buttons["native-theme-" + id]
            XCTAssertTrue(choice.waitForExistence(timeout: 10), "Theme form must expose every option, not only its header")
            XCTAssertTrue(choice.wait(for: \.isHittable, toEqual: true, timeout: 10),
                          "Every theme choice must fit the rotated viewport")
        }
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Landscape theme popover choices"; screenshot.lifetime = .keepAlways; add(screenshot)
        let close = app.buttons["native-panel-close"]
        XCTAssertTrue(close.wait(for: \.isHittable, toEqual: true, timeout: 10)); close.tap()
        XCTAssertFalse(app.alerts["确认首次保存"].exists)
        app.buttons["保存并返回目录"].tap()
        waitForFileList(app, file: file)
    }

    func testToolbarMenusAndRecoveryCloseRemainAccessible() {
        let app = XCUIApplication()
        app.launchArguments = ["--uitest-fixture", "--uitest-no-animations"]
        app.launch()
        let fileOperations = app.buttons["更多操作"]
        XCTAssertTrue(fileOperations.waitForExistence(timeout: 15))
        XCTAssertTrue(fileOperations.isHittable)
        fileOperations.tap()
        let refresh = app.buttons["刷新"]
        XCTAssertTrue(refresh.waitForExistence(timeout: 5)); refresh.tap()
        let file = app.buttons["测试文档"]
        waitForFileList(app, file: file); file.tap()
        waitForEditor(app)
        let documentOperations = moreButton(app)
        XCTAssertTrue(documentOperations.isHittable); documentOperations.tap()
        let recovery = app.buttons["恢复版本"]
        XCTAssertTrue(recovery.waitForExistence(timeout: 5)); recovery.tap()
        let close = app.buttons["关闭"]
        XCTAssertTrue(close.waitForExistence(timeout: 5)); XCTAssertTrue(close.isHittable); close.tap()
        let back = app.buttons["保存并返回目录"]
        XCTAssertTrue(back.waitForExistence(timeout: 5)); XCTAssertTrue(back.isHittable); back.tap()
        waitForFileList(app, file: file)
    }

    func testOpenInsertTableInspectReadOnlySourceAndReopen() {
        let app = XCUIApplication()
        app.launchArguments = ["--uitest-fixture", "--uitest-no-animations"]
        app.launch()
        let file = app.buttons["测试文档"]
        XCTAssertTrue(file.waitForExistence(timeout: 15)); file.tap()
        waitForEditor(app)
        insertTable(app)
        let source = openSource(app)
        assertSourceContains("| ---", in: source, "Table must be in current source, not only the visual body")
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Native read-only source mirror"; screenshot.lifetime = .keepAlways; add(screenshot)
        app.buttons["native-view-toggle"].tap()
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
        waitForFileList(app, file: file); file.tap(); waitForEditor(app)
        assertSourceContains("| ---", in: openSource(app), "Saved/reopened table must survive")
        app.buttons["native-view-toggle"].tap()
    }

    func testNativeFormatPanelCancelPreservesCurrentSource() {
        let app = XCUIApplication()
        app.launchArguments = ["--uitest-fixture", "--uitest-no-animations"]
        app.launch()
        let file = app.buttons["测试文档"]
        XCTAssertTrue(file.waitForExistence(timeout: 15)); file.tap(); waitForEditor(app)
        let before = sourceValue(openSource(app))
        XCTAssertTrue(before.contains("这里是手机写作测试。"))
        app.buttons["native-view-toggle"].tap()
        app.buttons["native-format"].tap()
        let bold = app.buttons["粗体"]
        if !bold.waitForExistence(timeout: 2) { app.swipeUp() }
        XCTAssertTrue(bold.waitForExistence(timeout: 5))
        XCTAssertFalse(app.webViews.buttons["粗体"].exists, "Format choices must be native")
        app.buttons["native-format-close"].tap()
        XCTAssertEqual(sourceValue(openSource(app)), before, "Closing without an action must not change content")
        app.buttons["native-view-toggle"].tap()
        app.buttons["保存并返回目录"].tap()
        waitForFileList(app, file: file)
    }

    func testReturnRequestsNormalizationAndCancelKeepsDocumentOpen() {
        let app = XCUIApplication()
        app.launchArguments = ["--uitest-fixture", "--uitest-noncanonical", "--uitest-no-animations"]
        app.launch()
        let file = app.buttons["测试文档"]
        XCTAssertTrue(file.waitForExistence(timeout: 15)); file.tap(); waitForEditor(app)
        app.buttons["保存并返回目录"].tap()
        waitForFileList(app, file: file); file.tap(); waitForEditor(app)
        insertTable(app)
        app.buttons["保存并返回目录"].tap()
        let confirmation = app.alerts["确认首次保存"]
        XCTAssertTrue(confirmation.waitForExistence(timeout: 5))
        confirmation.buttons["继续编辑"].tap()
        XCTAssertTrue(moreButton(app).exists)
        app.buttons["保存并返回目录"].tap()
        XCTAssertTrue(confirmation.waitForExistence(timeout: 5))
        confirmation.buttons["保存并返回"].tap()
        waitForFileList(app, file: file); file.tap(); waitForEditor(app)
        assertSourceContains("| ---", in: openSource(app), "Confirmed save must preserve the table after reopening")
        app.buttons["native-view-toggle"].tap()
        app.buttons["保存并返回目录"].tap()
        waitForFileList(app, file: file)
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
        waitForFileList(app, file: app.buttons["测试文档"])
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
        waitForFileList(app, file: app.buttons["测试文档"])
        XCTAssertFalse(app.buttons["选择文档所在文件夹"].exists)
    }
}
