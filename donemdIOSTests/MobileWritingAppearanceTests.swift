import XCTest
import SwiftUI
import UIKit
import WebKit
@testable import donemdIOS

@MainActor
final class MobileWritingAppearanceTests: XCTestCase {
    /// UIWindow's style stands in for the OS trait, without changing the shared
    /// simulator appearance. The bridge may override only its presentation root.
    func testNightToSystemFollowsLiveTraitsInBothMountedPanes() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 900, height: 600))
        window.overrideUserInterfaceStyle = .dark
        let host = UIViewController()
        window.rootViewController = host
        let body = WKWebView()
        let source = WKWebView()
        host.view.addSubview(body)
        host.view.addSubview(source)
        let bridge = MobileWritingAppearance.AppearanceView()
        host.view.addSubview(bridge)
        window.isHidden = false
        defer { bridge.releaseAppearance(); window.isHidden = true; window.rootViewController = nil }

        let bodyID = ObjectIdentifier(body), sourceID = ObjectIdentifier(source)
        for (theme, system, expected) in [
            (MobileWritingTheme.night, UIUserInterfaceStyle.dark, UIUserInterfaceStyle.dark),
            (.system, .dark, .dark),
            (.system, .light, .light),
            (.system, .dark, .dark),
            (.paper, .dark, .light),
            (.night, .light, .dark),
            (.system, .light, .light),
        ] {
            window.overrideUserInterfaceStyle = system
            bridge.style = theme.interfaceStyle
            bridge.apply()
            window.layoutIfNeeded()
            XCTAssertEqual(host.overrideUserInterfaceStyle, theme.interfaceStyle)
            XCTAssertEqual(host.traitCollection.userInterfaceStyle, expected)
            XCTAssertEqual(body.traitCollection.userInterfaceStyle, expected)
            XCTAssertEqual(source.traitCollection.userInterfaceStyle, expected)
            XCTAssertEqual(ObjectIdentifier(body), bodyID)
            XCTAssertEqual(ObjectIdentifier(source), sourceID)
            XCTAssertFalse(body.isLoading, "Appearance changes must not reload either editor")
            XCTAssertFalse(source.isLoading)
        }

        // Once System is selected, a trait change alone must be enough: no
        // bridge update, reader.set, source configure, document edit, or reopen.
        window.overrideUserInterfaceStyle = .dark
        window.layoutIfNeeded()
        XCTAssertEqual(body.traitCollection.userInterfaceStyle, .dark)
        XCTAssertEqual(source.traitCollection.userInterfaceStyle, .dark)
        window.overrideUserInterfaceStyle = .light
        window.layoutIfNeeded()
        XCTAssertEqual(body.traitCollection.userInterfaceStyle, .light)
        XCTAssertEqual(source.traitCollection.userInterfaceStyle, .light)
    }

    private final class Selection: ObservableObject {
        @Published var theme: MobileWritingTheme = .night
    }

    private struct Pane: UIViewRepresentable {
        let webView: WKWebView
        func makeUIView(context: Context) -> WKWebView { webView }
        func updateUIView(_ view: WKWebView, context: Context) {}
    }

    private struct Surface: View {
        @ObservedObject var selection: Selection
        let bodyPane: WKWebView
        let sourcePane: WKWebView
        var schemeChanged: ((ColorScheme) -> Void)? = nil
        var body: some View {
            HStack { Pane(webView: bodyPane); Pane(webView: sourcePane) }
                .background { if let schemeChanged { SchemeProbe(changed: schemeChanged) } }
                .modifier(MobileWritingSurface(theme: selection.theme))
        }
    }

    func testMountedSwiftUISurfaceReleasesNightWithoutRebuildingPanes() async {
        let selection = Selection()
        let body = WKWebView(), source = WKWebView()
        var nativeScheme: ColorScheme?
        let host = UIHostingController(rootView: Surface(selection: selection, bodyPane: body, sourcePane: source,
                                                         schemeChanged: { nativeScheme = $0 }))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 900, height: 600))
        // Start opposite Night so a merely inherited dark trait cannot pass.
        window.overrideUserInterfaceStyle = .light
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
        // A non-key test UIWindow does not get the app's normal presentation
        // layout pass. Force hosting/attachment before testing theme updates.
        window.layoutIfNeeded()
        host.view.layoutIfNeeded()
        let mounted = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            body.window === window && source.window === window
        }, object: nil)
        await fulfillment(of: [mounted], timeout: 3)
        let bodySuperview = body.superview, sourceSuperview = source.superview
        let nightApplied = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            host.overrideUserInterfaceStyle == .dark && nativeScheme == .dark &&
                body.traitCollection.userInterfaceStyle == .dark && source.traitCollection.userInterfaceStyle == .dark
        }, object: nil)
        await fulfillment(of: [nightApplied], timeout: 3)
        selection.theme = .system
        let systemApplied = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            host.overrideUserInterfaceStyle == .unspecified && nativeScheme == .light &&
                body.traitCollection.userInterfaceStyle == .light && source.traitCollection.userInterfaceStyle == .light
        }, object: nil)
        await fulfillment(of: [systemApplied], timeout: 3)
        // Window observation publishes SwiftUI state asynchronously; wait for
        // the effective UI (including representable traits), not just UIKit's
        // synchronous window layout. No theme publication or editor remount.
        for (style, scheme) in [(UIUserInterfaceStyle.dark, ColorScheme.dark), (.light, .light), (.dark, .dark)] {
            window.overrideUserInterfaceStyle = style
            window.layoutIfNeeded()
            let followed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                nativeScheme == scheme && body.traitCollection.userInterfaceStyle == style &&
                    source.traitCollection.userInterfaceStyle == style
            }, object: nil)
            await fulfillment(of: [followed], timeout: 3)
            XCTAssertEqual(host.overrideUserInterfaceStyle, .unspecified)
            XCTAssertTrue(body.superview === bodySuperview)
            XCTAssertTrue(source.superview === sourceSuperview)
            XCTAssertFalse(body.isLoading)
            XCTAssertFalse(source.isLoading)
        }
    }

    private struct SchemeProbe: UIViewRepresentable {
        let changed: (ColorScheme) -> Void
        func makeUIView(context: Context) -> UIView { UIView() }
        func updateUIView(_ view: UIView, context: Context) { changed(context.environment.colorScheme) }
    }

    private struct NativePanel: View {
        @ObservedObject var selection: Selection
        let changed: (ColorScheme) -> Void
        var body: some View {
            NavigationStack {
                Form { Text("Theme"); SchemeProbe(changed: changed).frame(height: 1) }
            }.modifier(MobileWritingSurface(theme: selection.theme))
        }
    }

    func testOpenPopoverReleasesNightAndTracksSystemEnvironmentWithoutReopening() async {
        let selection = Selection()
        let body = WKWebView(), source = WKWebView()
        let workspace = UIHostingController(rootView: Surface(selection: selection, bodyPane: body, sourcePane: source))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 900, height: 600))
        window.overrideUserInterfaceStyle = .dark
        window.rootViewController = workspace
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
        var panelScheme: ColorScheme?
        let panel = UIHostingController(rootView: NativePanel(selection: selection) { panelScheme = $0 })
        panel.modalPresentationStyle = .popover
        panel.preferredContentSize = CGSize(width: 320, height: 400)
        panel.popoverPresentationController?.sourceView = workspace.view
        panel.popoverPresentationController?.sourceRect = CGRect(x: 400, y: 100, width: 1, height: 1)
        let presented = expectation(description: "popover presented")
        workspace.present(panel, animated: false) { presented.fulfill() }
        await fulfillment(of: [presented], timeout: 3)
        let night = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            panel.overrideUserInterfaceStyle == .dark && panelScheme == .dark
        }, object: nil)
        await fulfillment(of: [night], timeout: 3)
        selection.theme = .system
        let released = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            panel.overrideUserInterfaceStyle == .unspecified && workspace.overrideUserInterfaceStyle == .unspecified
        }, object: nil)
        await fulfillment(of: [released], timeout: 3)
        for (style, scheme) in [(UIUserInterfaceStyle.light, ColorScheme.light), (.dark, .dark), (.light, .light)] {
            window.overrideUserInterfaceStyle = style
            window.layoutIfNeeded()
            let followed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                panelScheme == scheme && panel.traitCollection.userInterfaceStyle == style &&
                    body.traitCollection.userInterfaceStyle == style && source.traitCollection.userInterfaceStyle == style
            }, object: nil)
            await fulfillment(of: [followed], timeout: 3)
            XCTAssertTrue(workspace.presentedViewController === panel, "Popover must stay mounted")
        }
        let dismissed = expectation(description: "popover dismissed")
        panel.dismiss(animated: false) { dismissed.fulfill() }
        await fulfillment(of: [dismissed], timeout: 3)
        XCTAssertEqual(workspace.overrideUserInterfaceStyle, .unspecified)
    }

    private final class AlertState: ObservableObject {
        @Published var presented = false
    }

    private struct BrowserAlertSurface: View {
        @ObservedObject var selection: Selection
        @ObservedObject var alert: AlertState
        @State private var name = "Document"
        var body: some View {
            NavigationStack {
                List { Text("Document") }
                    .background(MobileRenameAlert(theme: selection.theme,
                        isPresented: $alert.presented, name: $name,
                        message: "输入新的文档名称。") { alert.presented = false }
                        .frame(width: 0, height: 0))
            }
            .modifier(MobileWritingSurface(theme: selection.theme))
        }
    }

    func testBrowserNativeRenameAlertUsesThemeAndSystemTracksWindow() async {
        let selection = Selection()
        selection.theme = .paper
        let alertState = AlertState()
        let host = UIHostingController(rootView: BrowserAlertSurface(selection: selection, alert: alertState))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.overrideUserInterfaceStyle = .dark
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
        window.layoutIfNeeded()
        host.view.layoutIfNeeded()

        for (theme, system, expected) in [
            (MobileWritingTheme.paper, UIUserInterfaceStyle.dark, UIUserInterfaceStyle.light),
            (.night, .light, .dark),
            (.system, .light, .light),
            (.system, .dark, .dark),
            (.system, .light, .light),
        ] {
            window.overrideUserInterfaceStyle = system
            selection.theme = theme
            // This non-key UIWindow has no app presentation/layout driver.
            // Flush trait propagation as in the existing live-system tests;
            // changing a window override alone can leave host traits cached.
            window.layoutIfNeeded()
            host.view.layoutIfNeeded()
            let effective = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                host.traitCollection.userInterfaceStyle == expected
            }, object: nil)
            effective.expectationDescription = "Browser theme=\(theme.rawValue), system=\(system.rawValue), expected=\(expected.rawValue)"
            await fulfillment(of: [effective], timeout: 3)
            XCTAssertEqual(host.overrideUserInterfaceStyle, theme.interfaceStyle,
                           "Root override for \(theme.rawValue), system=\(system.rawValue)")
            alertState.presented = true
            let presented = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                guard let alert = host.presentedViewController as? UIAlertController else { return false }
                return alert.traitCollection.userInterfaceStyle == expected &&
                    alert.textFields?.first?.traitCollection.userInterfaceStyle == expected
            }, object: nil)
            presented.expectationDescription = "Rename alert theme=\(theme.rawValue), system=\(system.rawValue), expected=\(expected.rawValue)"
            await fulfillment(of: [presented], timeout: 3)
            XCTAssertEqual(window.overrideUserInterfaceStyle, system, "Browser must not override the window")
            alertState.presented = false
            let dismissed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                host.presentedViewController == nil
            }, object: nil)
            await fulfillment(of: [dismissed], timeout: 3)
        }
    }

    func testFolderBrowserUsesPersistedThemeAtLaunchWithoutWritingPreference() async {
        for theme in MobileWritingTheme.allCases {
            let suite = "FolderAppearance-" + UUID().uuidString
            let defaults = UserDefaults(suiteName: suite)!
            defaults.set(theme.rawValue, forKey: MobileThemeStore.preferenceKey)
            let themes = MobileThemeStore(defaults: defaults)
            let folders = FolderStore()
            let session = DocumentOpenCoordinator(folders: folders)
            let host = UIHostingController(rootView:
                MobileFolderBrowser(folders: folders, themes: themes).environmentObject(session))
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
            window.overrideUserInterfaceStyle = .dark
            window.rootViewController = host
            window.isHidden = false
            window.layoutIfNeeded()
            host.view.layoutIfNeeded()
            let applied = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                host.overrideUserInterfaceStyle == theme.interfaceStyle &&
                    host.traitCollection.userInterfaceStyle == (theme == .paper ? .light : .dark)
            }, object: nil)
            await fulfillment(of: [applied], timeout: 3)
            XCTAssertEqual(defaults.string(forKey: MobileThemeStore.preferenceKey), theme.rawValue)
            XCTAssertFalse(themes.applying, "Browsing must not initiate a theme transaction")
            window.isHidden = true
            window.rootViewController = nil
            defaults.removePersistentDomain(forName: suite)
        }
    }

    func testContainmentTargetsPresentationAndReleasesOverrideWhenRemoved() {
        let presentation = UIViewController()
        let nested = UIViewController()
        presentation.addChild(nested)
        presentation.view.addSubview(nested.view)
        nested.didMove(toParent: presentation)
        let bridge = MobileWritingAppearance.AppearanceView()
        bridge.style = MobileWritingTheme.night.interfaceStyle
        nested.view.addSubview(bridge)
        XCTAssertEqual(presentation.overrideUserInterfaceStyle, .dark)
        XCTAssertEqual(nested.overrideUserInterfaceStyle, .unspecified)
        bridge.removeFromSuperview()
        XCTAssertEqual(presentation.overrideUserInterfaceStyle, .unspecified,
                       "Returning to the file list must not leave a writing override")
    }
}
