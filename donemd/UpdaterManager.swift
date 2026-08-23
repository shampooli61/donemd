import SwiftUI
import Sparkle

/// Owns the Sparkle updater for the whole app.
///
/// `SPUStandardUpdaterController` is the batteries-included entry point: it
/// wires up the updater, the user-driver (the standard "A new version is
/// available" UI), and the scheduled background check. `startingUpdater: true`
/// kicks off the automatic check cycle on launch — with `SUFeedURL` +
/// `SUPublicEDKey` in Info.plist, it periodically fetches the EdDSA-signed
/// appcast from GitHub Pages and prompts when a newer, correctly-signed build
/// is available.
///
/// Auto-update only *installs* cleanly on Developer ID-signed + notarized
/// builds (Sparkle verifies the downloaded archive's signature and Gatekeeper
/// must accept it). On the current self-signed Debug build the "检查更新" menu
/// still works end to end (fetch feed, show UI); the install step is what needs
/// the real signing pipeline. See docs/notes/sparkle-release.md.
final class UpdaterManager: ObservableObject {
    static let shared = UpdaterManager()

    private let controller: SPUStandardUpdaterController

    private init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    /// Invoked by the 检查更新… menu item. Shows the standard Sparkle progress /
    /// "up to date" / "update available" UI.
    func checkForUpdates() {
        controller.updater.checkForUpdates()
    }
}
