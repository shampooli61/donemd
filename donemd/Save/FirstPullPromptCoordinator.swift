import Foundation

/// State machine for "has the user been shown the first-pull dirty
/// confirmation for this file?"
///
/// Pull (⌘⌥O) overwrites the body with whatever Feishu has. When the
/// document is dirty, the very first time we ask three-option consent
/// (取消 / 保存为副本 / 丢弃并拉取). Once the user has *accepted* the
/// pull semantics for this file (副本 or 丢弃, not 取消), subsequent
/// pulls of the same file go straight through with the default
/// "discard local changes and pull" behavior.
///
/// Symmetric to `FirstSavePromptCoordinator`: same UserDefaults
/// persistence, same canonical path keying, same path-rename caveat
/// (a `mv` surfaces a fresh prompt on the new path — acceptable). The
/// one behavioral difference is that 取消 does NOT mark prompted —
/// canceling means the user backed out, not consented.
public final class FirstPullPromptCoordinator {
    public static let shared = FirstPullPromptCoordinator()

    private let defaults: UserDefaults
    private let defaultsKey = "donemd.firstPullPromptedFiles"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// True when Done.md has not yet recorded user consent for the pull
    /// dirty-overwrite semantics on this file path. Returns false for
    /// untitled / nil URLs — pull is gated upstream so this never
    /// matters there.
    public func shouldPrompt(forFileAt url: URL?) -> Bool {
        guard let url = url, url.isFileURL else { return false }
        let path = canonicalPath(for: url)
        return !promptedPaths.contains(path)
    }

    /// Record that the user accepted the pull dirty-overwrite semantics
    /// for this file. Idempotent. Caller should call this only when the
    /// user picked 副本 / 丢弃 — NOT on 取消.
    public func markPrompted(forFileAt url: URL?) {
        guard let url = url, url.isFileURL else { return }
        let path = canonicalPath(for: url)
        var paths = promptedPaths
        guard !paths.contains(path) else { return }
        paths.insert(path)
        defaults.set(Array(paths).sorted(), forKey: defaultsKey)
    }

    /// Test-only escape hatch — clear the marked set for the given
    /// path (or all paths if `nil`).
    public func forgetPrompt(forFileAt url: URL?) {
        if let url = url, url.isFileURL {
            let path = canonicalPath(for: url)
            var paths = promptedPaths
            paths.remove(path)
            defaults.set(Array(paths).sorted(), forKey: defaultsKey)
        } else {
            defaults.removeObject(forKey: defaultsKey)
        }
    }

    // MARK: Private

    private var promptedPaths: Set<String> {
        Set(defaults.stringArray(forKey: defaultsKey) ?? [])
    }

    private func canonicalPath(for url: URL) -> String {
        url.standardizedFileURL.path
    }
}
