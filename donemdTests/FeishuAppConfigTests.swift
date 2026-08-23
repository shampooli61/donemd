import XCTest
@testable import donemd

/// v2-2B-1 coverage for the OAuth app-config loader (issue #41).
///
/// Acceptance criteria covered:
///   - env vars take precedence over the plist
///   - plist takes precedence over the bundle fallback
///   - missing any required key in any source falls through to the next
///   - whitespace-only values are treated as missing
///   - blank / partial environment never produces a half-baked config
///   - bundle fallback returns nil when the resource isn't present
final class FeishuAppConfigTests: XCTestCase {

    // MARK: - environment

    func testLoadFromEnvironmentHappyPath() {
        let env = [
            FeishuAppConfig.envAppID: "cli_aaa",
            FeishuAppConfig.envAppSecret: "secret-bbb",
            FeishuAppConfig.envRedirectURI: "donemd://oauth/callback",
        ]
        let config = FeishuAppConfig.loadFromEnvironment(env)
        XCTAssertEqual(config?.clientID, "cli_aaa")
        XCTAssertEqual(config?.clientSecret, "secret-bbb")
        XCTAssertEqual(config?.redirectURI, "donemd://oauth/callback")
    }

    func testLoadFromEnvironmentMissingFieldReturnsNil() {
        let env = [
            FeishuAppConfig.envAppID: "cli_aaa",
            FeishuAppConfig.envAppSecret: "",
            FeishuAppConfig.envRedirectURI: "donemd://oauth/callback",
        ]
        XCTAssertNil(FeishuAppConfig.loadFromEnvironment(env))
    }

    func testLoadFromEnvironmentWhitespaceOnlyTreatedAsMissing() {
        let env = [
            FeishuAppConfig.envAppID: "  ",
            FeishuAppConfig.envAppSecret: "secret",
            FeishuAppConfig.envRedirectURI: "donemd://oauth/callback",
        ]
        XCTAssertNil(FeishuAppConfig.loadFromEnvironment(env))
    }

    func testLoadFromEnvironmentTrimsWhitespace() {
        // A trailing newline from Xcode's Environment Variables UI must
        // not poison the value — Feishu rejects redirect URIs with stray
        // whitespace so we trim defensively.
        let env = [
            FeishuAppConfig.envAppID: "  cli_aaa\n",
            FeishuAppConfig.envAppSecret: "secret-bbb",
            FeishuAppConfig.envRedirectURI: "donemd://oauth/callback ",
        ]
        let config = FeishuAppConfig.loadFromEnvironment(env)
        XCTAssertEqual(config?.clientID, "cli_aaa")
        XCTAssertEqual(config?.redirectURI, "donemd://oauth/callback")
    }

    // MARK: - plist

    func testDecodePlistHappyPath() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>client_id</key>
            <string>cli_xxx</string>
            <key>client_secret</key>
            <string>secret-yyy</string>
            <key>redirect_uri</key>
            <string>donemd://oauth/callback</string>
        </dict>
        </plist>
        """.data(using: .utf8)!
        let config = FeishuAppConfig.decodePlist(xml)
        XCTAssertEqual(config?.clientID, "cli_xxx")
        XCTAssertEqual(config?.clientSecret, "secret-yyy")
        XCTAssertEqual(config?.redirectURI, "donemd://oauth/callback")
    }

    func testDecodePlistMissingFieldReturnsNil() {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0">
        <dict>
            <key>client_id</key>
            <string>cli_xxx</string>
            <key>client_secret</key>
            <string></string>
            <key>redirect_uri</key>
            <string>donemd://oauth/callback</string>
        </dict>
        </plist>
        """.data(using: .utf8)!
        XCTAssertNil(FeishuAppConfig.decodePlist(xml))
    }

    func testDecodePlistMalformedReturnsNil() {
        let garbage = "this is not a plist".data(using: .utf8)!
        XCTAssertNil(FeishuAppConfig.decodePlist(garbage))
    }

    func testLoadFromPlistFileRoundtrip() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("feishu-config-\(UUID().uuidString).plist")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let dict: [String: String] = [
            "client_id": "cli_zzz",
            "client_secret": "secret-aaa",
            "redirect_uri": "donemd://oauth/callback",
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: dict, format: .xml, options: 0
        )
        try data.write(to: tmp)
        let config = FeishuAppConfig.loadFromPlist(at: tmp)
        XCTAssertEqual(config?.clientID, "cli_zzz")
    }

    func testLoadFromPlistMissingFileReturnsNil() {
        let nowhere = FileManager.default.temporaryDirectory
            .appendingPathComponent("does-not-exist-\(UUID().uuidString).plist")
        XCTAssertNil(FeishuAppConfig.loadFromPlist(at: nowhere))
    }

    // MARK: - precedence chain

    func testEnvWinsOverPlist() throws {
        let tmpPlist = FileManager.default.temporaryDirectory
            .appendingPathComponent("feishu-config-\(UUID().uuidString).plist")
        defer { try? FileManager.default.removeItem(at: tmpPlist) }
        try PropertyListSerialization.data(
            fromPropertyList: [
                "client_id": "from-plist",
                "client_secret": "p-secret",
                "redirect_uri": "donemd://oauth/callback",
            ] as [String: String],
            format: .xml, options: 0
        ).write(to: tmpPlist)

        let env = [
            FeishuAppConfig.envAppID: "from-env",
            FeishuAppConfig.envAppSecret: "e-secret",
            FeishuAppConfig.envRedirectURI: "donemd://oauth/callback",
        ]
        let config = FeishuAppConfig.load(
            keychainStore: nil,
            environment: env,
            plistURL: tmpPlist,
            bundle: Bundle(for: Self.self)
        )
        XCTAssertEqual(config?.clientID, "from-env",
            "env vars must take precedence over the plist")
    }

    func testPlistUsedWhenEnvIncomplete() throws {
        let tmpPlist = FileManager.default.temporaryDirectory
            .appendingPathComponent("feishu-config-\(UUID().uuidString).plist")
        defer { try? FileManager.default.removeItem(at: tmpPlist) }
        try PropertyListSerialization.data(
            fromPropertyList: [
                "client_id": "from-plist",
                "client_secret": "p-secret",
                "redirect_uri": "donemd://oauth/callback",
            ] as [String: String],
            format: .xml, options: 0
        ).write(to: tmpPlist)

        // Only one env var set — incomplete, must fall through to plist.
        let env = [FeishuAppConfig.envAppID: "from-env"]
        let config = FeishuAppConfig.load(
            keychainStore: nil,
            environment: env,
            plistURL: tmpPlist,
            bundle: Bundle(for: Self.self)
        )
        XCTAssertEqual(config?.clientID, "from-plist")
    }

    func testReturnsNilWhenAllSourcesEmpty() {
        let config = FeishuAppConfig.load(
            keychainStore: nil,
            environment: [:],
            plistURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("nonexistent.plist"),
            // `Bundle(for:)` of a test class points at the donemdTests
            // bundle, which doesn't ship feishu-config.plist — so the
            // bundle fallback also fails, and load() must return nil.
            bundle: Bundle(for: Self.self)
        )
        XCTAssertNil(config)
    }

    // MARK: - Keychain (highest-priority source, v2-10 step2)

    /// Stub that echoes a fixed config back. Tests inject this instead
    /// of FeishuKeychainAppConfigStore to avoid touching the real
    /// system Keychain (which would be brittle across CI / dev
    /// machines and require credential entitlements).
    private final class StubAppConfigStore: AppConfigStore {
        var stored: FeishuAppConfig?
        var loadError: Error?
        func save(_ config: FeishuAppConfig) throws { stored = config }
        func load() throws -> FeishuAppConfig? {
            if let loadError { throw loadError }
            return stored
        }
        func clear() throws { stored = nil }
    }

    func testKeychainWinsOverEnvAndPlist() throws {
        let keychain = StubAppConfigStore()
        keychain.stored = FeishuAppConfig(
            clientID: "from-keychain",
            clientSecret: "k-secret",
            redirectURI: "http://127.0.0.1:9876/callback"
        )
        let tmpPlist = FileManager.default.temporaryDirectory
            .appendingPathComponent("feishu-config-\(UUID().uuidString).plist")
        defer { try? FileManager.default.removeItem(at: tmpPlist) }
        try PropertyListSerialization.data(
            fromPropertyList: [
                "client_id": "from-plist",
                "client_secret": "p-secret",
                "redirect_uri": "donemd://oauth/callback",
            ] as [String: String],
            format: .xml, options: 0
        ).write(to: tmpPlist)
        let env = [
            FeishuAppConfig.envAppID: "from-env",
            FeishuAppConfig.envAppSecret: "e-secret",
            FeishuAppConfig.envRedirectURI: "donemd://oauth/callback",
        ]

        let config = FeishuAppConfig.load(
            keychainStore: keychain,
            environment: env,
            plistURL: tmpPlist,
            bundle: Bundle(for: Self.self)
        )
        XCTAssertEqual(config?.clientID, "from-keychain",
            "Keychain (Settings UI) must win over env / plist / bundle")
    }

    func testKeychainEmptyFallsThroughToEnv() throws {
        let keychain = StubAppConfigStore()  // stored = nil
        let env = [
            FeishuAppConfig.envAppID: "from-env",
            FeishuAppConfig.envAppSecret: "e-secret",
            FeishuAppConfig.envRedirectURI: "donemd://oauth/callback",
        ]
        let config = FeishuAppConfig.load(
            keychainStore: keychain,
            environment: env,
            plistURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("nonexistent.plist"),
            bundle: Bundle(for: Self.self)
        )
        XCTAssertEqual(config?.clientID, "from-env",
            "Empty Keychain must fall through to env, not return nil")
    }

    func testKeychainErrorDoesNotPoisonChain() throws {
        // Keychain access can fail (locked / inaccessible). load()
        // should treat that as "no Keychain entry" and try env / plist
        // — failing closed here would leave the user unable to log in.
        let keychain = StubAppConfigStore()
        keychain.loadError = NSError(domain: "test", code: -25300)
        let env = [
            FeishuAppConfig.envAppID: "from-env",
            FeishuAppConfig.envAppSecret: "e-secret",
            FeishuAppConfig.envRedirectURI: "donemd://oauth/callback",
        ]
        let config = FeishuAppConfig.load(
            keychainStore: keychain,
            environment: env,
            plistURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("nonexistent.plist"),
            bundle: Bundle(for: Self.self)
        )
        XCTAssertEqual(config?.clientID, "from-env")
    }

    func testKeychainStoreSaveLoadRoundtrip() throws {
        let store = StubAppConfigStore()
        let config = FeishuAppConfig(
            clientID: "cli_save",
            clientSecret: "secret-save",
            redirectURI: "http://127.0.0.1:9999/cb"
        )
        try store.save(config)
        let loaded = try store.load()
        XCTAssertEqual(loaded?.clientID, "cli_save")
        XCTAssertEqual(loaded?.clientSecret, "secret-save")
        try store.clear()
        XCTAssertNil(try store.load(), "clear() must wipe the entry")
    }
}
