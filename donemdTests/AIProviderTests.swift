import XCTest
@testable import donemd

/// Phase 3 Slice 1 (#62) — the `AIProvider` metadata table.
/// Locks the fallback model table + protocol-family mapping + key/endpoint
/// rules so a careless edit to the enum trips a test.
final class AIProviderTests: XCTestCase {

    func testFiveProviders() {
        XCTAssertEqual(AIProvider.allCases.count, 5)
    }

    func testProtocolFamilyMapping() {
        XCTAssertEqual(AIProvider.deepseek.family, .openAICompatible)
        XCTAssertEqual(AIProvider.openai.family, .openAICompatible)
        XCTAssertEqual(AIProvider.mimo.family, .openAICompatible)
        XCTAssertEqual(AIProvider.claude.family, .anthropic)
        XCTAssertEqual(AIProvider.gemini.family, .google)
    }

    func testFallbackModelTable() {
        // PRD § 默认 Model 表. The three TBD entries are pinned to the
        // current best guess; this test is the tripwire that forces a
        // conscious update when #72 verifies them at ship.
        XCTAssertEqual(AIProvider.deepseek.fallbackModel, "deepseek-v4-flash")
        XCTAssertEqual(AIProvider.gemini.fallbackModel, "gemini-2.5-flash")
        XCTAssertEqual(AIProvider.openai.fallbackModel, "gpt-4o-mini")
        XCTAssertEqual(AIProvider.claude.fallbackModel, "claude-haiku-4-5")
        XCTAssertEqual(AIProvider.mimo.fallbackModel, "MiMo-V2.5-Pro")
    }

    func testAllProvidersRequireKey() {
        // Every provider authenticates with a user-supplied API key.
        for provider in AIProvider.allCases {
            XCTAssertTrue(provider.requiresAPIKey, "\(provider)")
        }
    }

    func testDeepSeekIsRecommendedDefault() {
        XCTAssertTrue(AIProvider.deepseek.isRecommendedDefault)
        XCTAssertEqual(AIProvider.allCases.filter(\.isRecommendedDefault), [.deepseek])
    }

    func testDefaultEndpointsAreValidURLs() {
        for provider in AIProvider.allCases {
            XCTAssertNotNil(URL(string: provider.defaultEndpoint), "\(provider)")
        }
    }

    func testKeychainServiceNamespacing() {
        XCTAssertEqual(
            AIProvider.deepseek.keychainService(bundleID: "com.shampoo.donemd"),
            "com.shampoo.donemd.deepseek"
        )
    }
}
