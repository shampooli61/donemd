import XCTest
import SwiftUI
import UIKit
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

    func testCompareRequires300PointsOfContentAfterMeasuredTitles() {
        func container(_ height: Double, title: Double? = 36, accessibility: Bool = false) -> MobileEditorLayout {
            MobileEditorLayout(width: 760, containerHeight: height, paneTitleHeight: title, accessibility: accessibility)
        }
        XCTAssertTrue(layout(760, 300).supportsCompare, "The layout's height contract is content height")
        XCTAssertFalse(container(300).supportsCompare, "300pt including the title leaves only 264pt of content")
        XCTAssertEqual(container(300).height, 264)
        XCTAssertFalse(container(335.99).supportsCompare)
        XCTAssertTrue(container(336).supportsCompare, "A measured default 36pt title leaves exactly 300pt")
        XCTAssertFalse(container(336, title: 52).supportsCompare, "A larger/wrapped source title cannot use the body title's height")
        XCTAssertTrue(container(352, title: 52).supportsCompare)
        XCTAssertFalse(container(900, title: nil).supportsCompare, "Do not guess before current title measurement arrives")
        XCTAssertFalse(container(900, accessibility: true).supportsCompare)
        XCTAssertEqual(container(20, title: 52).height, 0)
    }

    @MainActor
    func testActualPaneTitlesSupplyDefaultBoundaryAndDynamicTypeHeight() {
        func titleHeight(_ title: String, width: CGFloat, type: DynamicTypeSize) -> CGFloat {
            let host = UIHostingController(rootView: MobileEditorPaneTitle(title: title).environment(\.dynamicTypeSize, type))
            return host.sizeThatFits(in: CGSize(width: width, height: 1000)).height
        }
        let columns = layout().widths(for: .compare, divider: 0.5)
        let bodyHeight = titleHeight("正文", width: CGFloat(columns.body), type: .large)
        let sourceHeight = titleHeight("Markdown 源·只读", width: CGFloat(columns.source), type: .large)
        let measured = Double(max(bodyHeight, sourceHeight))
        XCTAssertEqual(measured, 36, accuracy: 0.01)
        XCTAssertTrue(MobileEditorLayout(width: 760, containerHeight: 336, paneTitleHeight: measured, accessibility: false).supportsCompare)
        XCTAssertFalse(MobileEditorLayout(width: 760, containerHeight: 300, paneTitleHeight: measured, accessibility: false).supportsCompare)
        let largestStandardBody = titleHeight("正文", width: CGFloat(columns.body), type: .xxxLarge)
        let largestStandardSource = titleHeight("Markdown 源·只读", width: CGFloat(columns.source), type: .xxxLarge)
        let largestStandardTitle = Double(max(largestStandardBody, largestStandardSource))
        XCTAssertGreaterThanOrEqual(largestStandardTitle, measured)
        XCTAssertTrue(MobileEditorLayout(width: 760, containerHeight: 300 + largestStandardTitle,
                                        paneTitleHeight: largestStandardTitle, accessibility: false).supportsCompare)
        XCTAssertFalse(MobileEditorLayout(width: 760, containerHeight: 299.99 + largestStandardTitle,
                                         paneTitleHeight: largestStandardTitle, accessibility: false).supportsCompare)
        let largeBody = titleHeight("正文", width: CGFloat(columns.body), type: .accessibility5)
        let largeSource = titleHeight("Markdown 源·只读", width: CGFloat(columns.source), type: .accessibility5)
        XCTAssertGreaterThan(largeSource, sourceHeight, "The actual header must grow rather than clip at 36pt")
        XCTAssertGreaterThanOrEqual(largeSource, largeBody)
        XCTAssertFalse(MobileEditorLayout(width: 760, containerHeight: 1000,
                                         paneTitleHeight: Double(max(largeBody, largeSource)), accessibility: true).supportsCompare)
    }

    func testAutomaticCollapseNeverHidesFocusedOrComposingBody() {
        var preference = MobileEditorViewPreference()
        preference.select(.source, in: layout(390))
        preference.select(.compare, in: layout())
        let saved = preference
        XCTAssertEqual(preference.mode(in: layout()), .compare)
        // Each signal independently protects the actual geometry-driven shown
        // mode; IME state need not coincide with a keyboard notification/focus ACK.
        for collapsed in [layout(390), layout(1000, 299), layout(1000, 900, accessibility: true)] {
            XCTAssertEqual(preference.mode(in: collapsed, focused: true), .body)
            XCTAssertEqual(preference.mode(in: collapsed, composing: true), .body)
            XCTAssertEqual(preference.mode(in: collapsed, keyboardVisible: true), .body)
            XCTAssertEqual(preference.mode(in: collapsed, focused: true, composing: true, keyboardVisible: true), .body)
            XCTAssertEqual(preference.mode(in: collapsed), .source, "A fully inactive body can restore the saved source preference")
        }
        XCTAssertEqual(preference, saved, "Automatic protection must not overwrite wide/narrow choices")
        XCTAssertEqual(preference.mode(in: layout(), focused: true, composing: true), .compare)
    }

    func testAutomaticExpansionNeverRestoresWideSourceOverActiveBody() {
        var preference = MobileEditorViewPreference()
        preference.select(.source, in: layout())
        XCTAssertEqual(preference.mode(in: layout(390)), .source)
        preference.select(.body, in: layout(390))
        let saved = preference
        XCTAssertEqual(preference.mode(in: layout(390), focused: true, composing: true), .body)
        for expanded in [layout(), layout(1000), layout(1200, 900)] {
            XCTAssertEqual(preference.mode(in: expanded, focused: true), .body)
            XCTAssertEqual(preference.mode(in: expanded, composing: true), .body)
            XCTAssertEqual(preference.mode(in: expanded, keyboardVisible: true), .body)
            XCTAssertEqual(preference.mode(in: expanded, focused: true, composing: true, keyboardVisible: true), .body)
            XCTAssertEqual(preference.mode(in: expanded), .source, "Inactive expansion may restore wide source")
        }
        XCTAssertEqual(preference, saved, "Protecting active input must not rewrite either preference")
        XCTAssertEqual(preference.mode(in: layout(390)), .body)
        preference.select(.compare, in: layout())
        XCTAssertEqual(preference.mode(in: layout(), focused: true, composing: true, keyboardVisible: true), .compare,
                       "Compare already keeps the input owner visible")
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
