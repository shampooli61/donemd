import XCTest
@testable import donemdIOS

final class MobileEditorLayoutTests: XCTestCase {
    private func layout(_ width: Double = 760, _ height: Double = 300, accessibility: Bool = false) -> MobileEditorLayout {
        MobileEditorLayout(width: width, height: height, accessibility: accessibility)
    }

    func testCompareUsesActualWidthHeightAndAccessibilityBoundaries() {
        XCTAssertTrue(layout().supportsCompare)
        XCTAssertFalse(layout(759.99).supportsCompare)
        XCTAssertFalse(layout(760, 299.99).supportsCompare)
        XCTAssertFalse(layout(1200, 900, accessibility: true).supportsCompare)
        XCTAssertTrue(layout(760, 300).supportsCompare)
    }

    func testColumnMinimumsRatioMaximumAndPhysicalPixelDivider() {
        let boundary = layout().widths(for: .compare, divider: 0.5)
        XCTAssertGreaterThanOrEqual(boundary.body, 400)
        XCTAssertGreaterThanOrEqual(boundary.source, 300)
        XCTAssertEqual(boundary.body + boundary.source + 0.5, 760, accuracy: 0.0001)
        let normal = layout(1000).widths(for: .compare, divider: 0.5)
        XCTAssertEqual(normal.source, 999.5 * 0.42, accuracy: 0.0001)
        let large = layout(1800).widths(for: .compare, divider: 0.5)
        XCTAssertEqual(large.source, 520)
        XCTAssertEqual(large.body, 1279.5)
    }

    func testSinglePaneHasNoDividerOrUnusedSpace() {
        XCTAssertEqual(layout(390).widths(for: .body, divider: 0).body, 390)
        XCTAssertEqual(layout(390).widths(for: .body, divider: 0).source, 0)
        XCTAssertEqual(layout(390).widths(for: .source, divider: 0).source, 390)
        XCTAssertEqual(layout(390).widths(for: .source, divider: 0).body, 0)
    }

    func testDefaultAutoCompareCollapsesToBodyAndReexpands() {
        let preference = MobileEditorViewPreference()
        XCTAssertEqual(preference.mode(in: layout()), .compare)
        XCTAssertEqual(preference.mode(in: layout(390)), .body)
        XCTAssertEqual(preference.mode(in: layout()), .compare)
    }

    func testExplicitSourceSurvivesFoldHeightAndAccessibilityChanges() {
        var preference = MobileEditorViewPreference()
        preference.select(.source, in: layout())
        XCTAssertEqual(preference.mode(in: layout(390)), .source)
        XCTAssertEqual(preference.mode(in: layout(1000, 240)), .source)
        XCTAssertEqual(preference.mode(in: layout(1000, 900, accessibility: true)), .source)
        XCTAssertEqual(preference.mode(in: layout()), .source)
    }

    func testWideCompareAndNarrowChoiceAreIndependentSessionPreferences() {
        var preference = MobileEditorViewPreference()
        preference.select(.source, in: layout(390))
        XCTAssertEqual(preference.mode(in: layout()), .compare)
        preference.select(.compare, in: layout())
        XCTAssertEqual(preference.mode(in: layout(390)), .source)
        preference.select(.body, in: layout(390))
        XCTAssertEqual(preference.mode(in: layout()), .compare)
        XCTAssertEqual(preference.mode(in: layout(390)), .body)
        XCTAssertEqual(MobileEditorViewPreference().mode(in: layout(390)), .body, "A new document gets a fresh session preference")
    }

    func testUnavailableCompareCannotOverwritePreference() {
        var preference = MobileEditorViewPreference()
        preference.select(.source, in: layout(390))
        let before = preference
        preference.select(.compare, in: layout(390))
        XCTAssertEqual(preference, before)
    }

    func testSwitchGuardRejectsCompositionAndLateSelectionResults() {
        let gate = MobileEditorViewSwitchGuard(identity: "note", revision: 7)
        XCTAssertTrue(gate.accepts(identity: "note", revision: 7, ready: true, composing: false))
        XCTAssertFalse(gate.accepts(identity: "note", revision: 7, ready: true, composing: true))
        XCTAssertFalse(gate.accepts(identity: "other", revision: 7, ready: true, composing: false))
        XCTAssertFalse(gate.accepts(identity: "note", revision: 8, ready: true, composing: false))
        XCTAssertFalse(gate.accepts(identity: "note", revision: 7, ready: false, composing: false))
    }
}
