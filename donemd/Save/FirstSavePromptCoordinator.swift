import Foundation

/// State machine for "has the user been shown the first-save prompt for
/// this file?"
///
/// Tracks per-file URL paths in a UserDefaults-backed Set. Once a file
/// path is marked, the prompt is skipped on subsequent saves regardless
/// of which button the user clicked the first time. Path-based keying
/// means a `mv` / rename surfaces a fresh prompt on the new path — a
/// minor annoyance documented in ADR-0002, traded for not having to
/// touch extended file attributes (which several sync tools strip).
public final class FirstSavePromptCoordinator {
    /// Shared instance backed by UserDefaults.standard. Tests inject a
    /// scoped UserDefaults via `init(defaults:)` to avoid polluting the
    /// global domain.
    public static let shared = FirstSavePromptCoordinator()

    private let defaults: UserDefaults
    private let defaultsKey = "donemd.firstSavePromptedFiles"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// True when Done.md has not yet shown the first-save prompt for
    /// this file path. Returns false for untitled / nil URLs — the
    /// concept doesn't apply until a real file path exists.
    public func shouldPrompt(forFileAt url: URL?) -> Bool {
        guard let url = url, url.isFileURL else { return false }
        let path = canonicalPath(for: url)
        return !promptedPaths.contains(path)
    }

    /// Record that we showed the prompt for this file. Idempotent —
    /// calling more than once is safe.
    public func markPrompted(forFileAt url: URL?) {
        guard let url = url, url.isFileURL else { return }
        let path = canonicalPath(for: url)
        var paths = promptedPaths
        guard !paths.contains(path) else { return }
        paths.insert(path)
        // Sorted for deterministic UserDefaults storage (helps tests).
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

    /// Standardize the URL so equivalent paths (with / without symlinks
    /// resolved) compare equal. Doesn't resolve symlinks aggressively —
    /// keeps the URL pointing at the same name the user saw.
    private func canonicalPath(for url: URL) -> String {
        url.standardizedFileURL.path
    }
}
