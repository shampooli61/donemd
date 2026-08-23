import Foundation
import AppKit
import Combine

/// Long-lived facade the Settings panel binds to. Owns the singleton
/// SyncRootStore + SyncRootScanner pair plus the OAuth client, and
/// exposes ObservableObject state so SwiftUI can re-render on auth
/// changes / root list edits / file-count updates.
///
/// Lifecycle: instantiated in AppDelegate.applicationDidFinishLaunching,
/// which calls `boot()` to load persisted roots and start the file
/// system watcher. `shutdown()` is called from
/// applicationWillTerminate to cancel the watchers cleanly.
///
/// Why a single manager instead of constructing OAuth/Store/Scanner
/// at each callsite (the way push/pull commands do today): the
/// SyncRootScanner holds DispatchSource watchers that must outlive any
/// individual command invocation, and the Settings UI must reflect
/// authentication state after a login completes anywhere in the app.
@MainActor
public final class FeishuSyncManager: ObservableObject {

    // MARK: - published state for SwiftUI

    public enum AuthState: Equatable {
        case notConfigured              // FeishuAppConfig.load() returned nil
        case loggedOut                  // configured but no credentials in store
        case loggedIn(tenantKey: String?)  // credentials present
    }

    @Published public private(set) var authState: AuthState = .notConfigured
    @Published public private(set) var roots: [URL] = []
    /// Per-root count of files carrying `feishu.doc_token`. Updated
    /// whenever the scanner reports a change or the root list mutates.
    @Published public private(set) var boundFileCounts: [URL: Int] = [:]
    /// Set true while a login flow is awaiting the OAuth callback so the
    /// UI can show "正在等待浏览器授权…" instead of letting the user click
    /// the button repeatedly.
    @Published public private(set) var isLoggingIn: Bool = false
    @Published public private(set) var lastError: String?

    // MARK: - dependencies

    private let store: SyncRootStore
    private let scanner: SyncRootScanner
    private let credentialStore: KeychainCredentialStore
    private let appConfigStore: AppConfigStore
    private var oauthClient: FeishuOAuthClient?
    private var refreshTask: Task<Void, Never>?

    /// Non-secret UserDefaults mirror of auth state, so `boot()` can render the
    /// Settings panel / badge at launch WITHOUT reading `feishu-app-config` or
    /// `feishu-oauth` from the Keychain (each read pops an access prompt on an
    /// ad-hoc build). Only the coarse state + a tenant-key label live here —
    /// never the token / secret, so the "secrets stay in Keychain" line holds.
    /// The real read happens on the next user action (login / push / pull),
    /// which also refreshes this mirror.
    private enum MirrorKeys {
        static let authState = "feishu.authState.mirror"        // notConfigured|loggedOut|loggedIn
        static let tenantKey = "feishu.tenantKey.mirror"        // non-secret label
    }

    // MARK: - init / boot

    public init(
        store: SyncRootStore = SyncRootStore(),
        scanner: SyncRootScanner = SyncRootScanner(),
        credentialStore: KeychainCredentialStore = KeychainCredentialStore(),
        appConfigStore: AppConfigStore = FeishuKeychainAppConfigStore()
    ) {
        self.store = store
        self.scanner = scanner
        self.credentialStore = credentialStore
        self.appConfigStore = appConfigStore
        self.roots = store.list()
    }

    /// Resolver bound to the manager's scanner. Used by the #58
    /// import-from-URL path to dispatch the four cases (openExisting /
    /// ambiguous / createNew / requiresAPIResolution) without exposing
    /// the scanner directly.
    public func bindingResolver() -> SyncBindingResolver {
        SyncBindingResolver(scanner: scanner)
    }

    public func boot() {
        // Do NOT build the OAuth client or read the Keychain here — both would
        // pop access prompts at every launch. Render auth state from the
        // non-secret mirror; the client is built lazily on first login/logout
        // (ensureOAuthClient), and the real Keychain read happens then.
        loadAuthStateFromMirror()
        let initialRoots = roots
        Task { @MainActor in
            await scanner.start(initialRoots)
            await refreshFileCounts()
        }
    }

    public func shutdown() {
        Task { @MainActor in
            await scanner.stop()
        }
    }

    // MARK: - OAuth surface

    public func login() async {
        guard let oauth = ensureOAuthClient() else {
            lastError = "未配置飞书应用凭证。请到 ~/Library/Application Support/Done.md/feishu-config.plist 填好后重启。"
            return
        }
        isLoggingIn = true
        lastError = nil
        defer { isLoggingIn = false }
        do {
            _ = try await oauth.login()
            refreshAuthState()
        } catch {
            lastError = "登录失败：\(error)"
            debugLog("[settings] login error: \(error)")
        }
    }

    // MARK: - app config (client_id / secret / redirect_uri)

    /// Read the currently-active app config — what the running OAuth
    /// client would see. UI uses this to pre-fill the input fields
    /// when the panel opens. Returns nil when no source has all three
    /// fields set yet.
    public func currentAppConfig() -> FeishuAppConfig? {
        FeishuAppConfig.load()
    }

    /// Read whatever's stored in *Keychain* specifically — distinct
    /// from `currentAppConfig()` which falls through to env / plist.
    /// UI uses this to surface "is there a Settings-managed config?"
    /// vs "we're running on env / plist", since the form's [清除]
    /// button only makes sense when the Keychain entry exists.
    public func keychainAppConfig() -> FeishuAppConfig? {
        (try? appConfigStore.load()) ?? nil
    }

    public enum SaveAppConfigError: Error, Equatable {
        case missingField
        case persistFailed(String)
    }

    @discardableResult
    public func saveAppConfig(
        clientID: String,
        clientSecret: String,
        redirectURI: String
    ) -> SaveAppConfigError? {
        let id = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = clientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        let redirect = redirectURI.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, !secret.isEmpty, !redirect.isEmpty else {
            return .missingField
        }
        let config = FeishuAppConfig(
            clientID: id, clientSecret: secret, redirectURI: redirect
        )
        do {
            try appConfigStore.save(config)
        } catch {
            return .persistFailed("\(error)")
        }
        // Newly-saved config means the OAuth client must be rebuilt to
        // pick up the new clientID/secret. The next login() / push /
        // pull will use the fresh values.
        rebuildOAuthClient()
        refreshAuthState()
        return nil
    }

    /// Wipe the Keychain-stored app config. Resolution falls back to
    /// env / plist / bundle on the next read. Does NOT touch user
    /// credentials (access token) — for that use `logout()`.
    public func clearAppConfig() {
        try? appConfigStore.clear()
        rebuildOAuthClient()
        refreshAuthState()
    }

    public func logout() async {
        guard let oauth = ensureOAuthClient() else {
            // No client → just wipe local store directly.
            try? credentialStore.clear()
            refreshAuthState()
            return
        }
        do {
            try await oauth.logout()
        } catch {
            // Even if logout failed, clear the local store so the UI
            // reflects logged-out and the next login works.
            try? credentialStore.clear()
            debugLog("[settings] logout error (ignored): \(error)")
        }
        refreshAuthState()
    }

    // MARK: - sync root surface

    public enum AddRootError: Error, Equatable {
        case alreadyAdded
        case notADirectory
        case persistFailed(String)
    }

    @discardableResult
    public func addRoot(_ url: URL) async -> AddRootError? {
        let canonical = url.standardizedFileURL
        if roots.contains(canonical) { return .alreadyAdded }

        do {
            try store.add(canonical)
        } catch SyncRootStore.StoreError.notADirectory {
            return .notADirectory
        } catch {
            return .persistFailed("\(error)")
        }

        roots = store.list()
        await scanner.addRoot(canonical)
        await refreshFileCounts()
        return nil
    }

    public func removeRoot(_ url: URL) async {
        let canonical = url.standardizedFileURL
        store.remove(canonical)
        roots = store.list()
        await scanner.removeRoot(canonical)
        await refreshFileCounts()
    }

    public func reorderRoots(_ newOrder: [URL]) async {
        let canonical = newOrder.map { $0.standardizedFileURL }
        store.reorder(canonical)
        roots = store.list()
        // Reorder doesn't change membership; re-start the scanner so
        // priority for token-conflict resolution updates.
        await scanner.start(roots)
        await refreshFileCounts()
    }

    /// Force a re-read of bound-file counts from the scanner. Settings
    /// view calls this after add/remove. Watcher-driven changes (user
    /// adding/removing files outside Done.md) currently don't push back
    /// — that's fine for v2-10 step1 since the count is a hint, not
    /// transactionally critical.
    public func refreshFileCounts() async {
        var counts: [URL: Int] = [:]
        for root in roots {
            counts[root] = await scanner.boundFileCount(for: root)
        }
        boundFileCounts = counts
    }

    // MARK: - private helpers

    private func rebuildOAuthClient() {
        guard let config = FeishuAppConfig.load() else {
            oauthClient = nil
            return
        }
        oauthClient = FeishuOAuthClient(
            config: config,
            store: credentialStore,
            receiver: FeishuOAuthLoopbackReceiver(),
            opener: NSWorkspaceURLOpener()
        )
    }

    /// Lazily build (and cache) the OAuth client on first use. Called from
    /// login/logout — user-initiated paths where reading `feishu-app-config`
    /// from the Keychain is acceptable (and, post Part-A migration, silent).
    /// Keeping this out of `boot()` is what removes the launch-time prompt.
    @discardableResult
    private func ensureOAuthClient() -> FeishuOAuthClient? {
        if oauthClient == nil {
            rebuildOAuthClient()
        }
        return oauthClient
    }

    /// Render auth state from the non-secret mirror only — no Keychain read.
    /// Used by `boot()` so launch never triggers an access prompt. Falls back
    /// to `.notConfigured` when the mirror is unseeded (fresh install); the
    /// first login/push/pull then reads for real and seeds it via
    /// `refreshAuthState()`.
    private func loadAuthStateFromMirror() {
        switch UserDefaults.standard.string(forKey: MirrorKeys.authState) {
        case "loggedIn":
            let tenant = UserDefaults.standard.string(forKey: MirrorKeys.tenantKey)
            authState = .loggedIn(tenantKey: tenant)
        case "loggedOut":
            authState = .loggedOut
        default:
            authState = .notConfigured
        }
    }

    private func refreshAuthState() {
        guard FeishuAppConfig.load() != nil else {
            authState = .notConfigured
            persistAuthStateMirror()
            return
        }
        do {
            if let credentials = try credentialStore.load() {
                authState = .loggedIn(tenantKey: credentials.tenantKey)
            } else {
                authState = .loggedOut
            }
        } catch {
            // Keychain read failure is rare but possible (locked, no
            // user session). Treat as logged-out — next login attempt
            // will surface the underlying error.
            authState = .loggedOut
            debugLog("[settings] credentialStore.load failed: \(error)")
        }
        persistAuthStateMirror()
    }

    /// Write the current `authState` into the non-secret mirror so the next
    /// launch can render it without a Keychain read.
    private func persistAuthStateMirror() {
        switch authState {
        case .loggedIn(let tenantKey):
            UserDefaults.standard.set("loggedIn", forKey: MirrorKeys.authState)
            UserDefaults.standard.set(tenantKey, forKey: MirrorKeys.tenantKey)
        case .loggedOut:
            UserDefaults.standard.set("loggedOut", forKey: MirrorKeys.authState)
            UserDefaults.standard.removeObject(forKey: MirrorKeys.tenantKey)
        case .notConfigured:
            UserDefaults.standard.set("notConfigured", forKey: MirrorKeys.authState)
            UserDefaults.standard.removeObject(forKey: MirrorKeys.tenantKey)
        }
    }
}
