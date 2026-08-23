import XCTest
@testable import donemd

final class DocumentSizeEstimateTests: XCTestCase {

    // MARK: - Basic counts

    func testEmptyDocument() {
        let e = DocumentSizeEstimate.compute(bodyMarkdown: "")
        XCTAssertEqual(e.byteCount, 0)
        XCTAssertEqual(e.characterCount, 0)
        XCTAssertEqual(e.estimatedTokens, 0)
        XCTAssertEqual(e.tier, .comfortable)
    }

    func testByteVsCharacterCountDiffersForCJK() {
        // A Chinese character is 3 UTF-8 bytes but one Swift Character.
        let e = DocumentSizeEstimate.compute(bodyMarkdown: "中文")
        XCTAssertEqual(e.characterCount, 2)
        XCTAssertEqual(e.byteCount, 6)
    }

    // MARK: - Token heuristic

    func testLatinTokenEstimateIsRoughlyQuarterOfCharacters() {
        // 40 Latin chars → ~10 tokens (÷4 rule).
        let text = String(repeating: "a", count: 40)
        XCTAssertEqual(DocumentSizeEstimate.estimateTokens(text), 10)
    }

    func testCJKTokenEstimateUsesPerCharacterWeight() {
        // 100 Han characters → 100 * 0.6 = 60 tokens.
        let text = String(repeating: "字", count: 100)
        XCTAssertEqual(DocumentSizeEstimate.estimateTokens(text), 60)
    }

    func testMixedTextAddsBothClasses() {
        // 10 Han (→6) + 20 Latin (→5) = 11 tokens.
        let text = String(repeating: "字", count: 10) + String(repeating: "b", count: 20)
        XCTAssertEqual(DocumentSizeEstimate.estimateTokens(text), 11)
    }

    func testCJKPunctuationCountsAsCJK() {
        // Full-width comma/period sit in the CJK weight class (0xFF00–0xFFEF).
        let text = "，。！？"
        // 4 chars * 0.6 = 2.4 → rounds to 2.
        XCTAssertEqual(DocumentSizeEstimate.estimateTokens(text), 2)
    }

    // MARK: - Tier boundaries

    func testTierComfortableAtCeiling() {
        // Exactly 16K tokens is still comfortable (≤ boundary). 16000 / 0.6
        // Han chars would overshoot rounding, so drive tokens via Latin: 64000
        // Latin chars ÷4 = 16000 tokens.
        let text = String(repeating: "a", count: DocumentSizeEstimate.comfortableCeiling * 4)
        let e = DocumentSizeEstimate.compute(bodyMarkdown: text)
        XCTAssertEqual(e.estimatedTokens, DocumentSizeEstimate.comfortableCeiling)
        XCTAssertEqual(e.tier, .comfortable)
    }

    func testTierLargeJustAboveComfortable() {
        // One token past the comfortable ceiling → large.
        let tokens = DocumentSizeEstimate.comfortableCeiling + 1
        let text = String(repeating: "a", count: tokens * 4)
        let e = DocumentSizeEstimate.compute(bodyMarkdown: text)
        XCTAssertEqual(e.tier, .large)
    }

    func testTierLargeAtLargeCeiling() {
        let text = String(repeating: "a", count: DocumentSizeEstimate.largeCeiling * 4)
        let e = DocumentSizeEstimate.compute(bodyMarkdown: text)
        XCTAssertEqual(e.estimatedTokens, DocumentSizeEstimate.largeCeiling)
        XCTAssertEqual(e.tier, .large)
    }

    func testTierTooLargeAboveLargeCeiling() {
        let tokens = DocumentSizeEstimate.largeCeiling + 1000
        let text = String(repeating: "a", count: tokens * 4)
        let e = DocumentSizeEstimate.compute(bodyMarkdown: text)
        XCTAssertEqual(e.tier, .tooLarge)
    }

    // MARK: - Display formatting

    func testTokensCompactBelowThousand() {
        let text = String(repeating: "a", count: 400) // 100 tokens
        let e = DocumentSizeEstimate.compute(bodyMarkdown: text)
        XCTAssertEqual(e.tokensCompact, "≈100 tokens")
    }

    func testTokensCompactOneDecimalBelow10K() {
        // 4200 tokens → ≈4.2K
        let text = String(repeating: "a", count: 4200 * 4)
        let e = DocumentSizeEstimate.compute(bodyMarkdown: text)
        XCTAssertEqual(e.tokensCompact, "≈4.2K tokens")
    }

    func testTokensCompactWholeKAtOrAbove10K() {
        // 40000 tokens → ≈40K
        let text = String(repeating: "a", count: 40000 * 4)
        let e = DocumentSizeEstimate.compute(bodyMarkdown: text)
        XCTAssertEqual(e.tokensCompact, "≈40K tokens")
    }

    func testBytesReadableKB() {
        let text = String(repeating: "a", count: 2048)
        let e = DocumentSizeEstimate.compute(bodyMarkdown: text)
        XCTAssertEqual(e.bytesReadable, "2 KB")
    }

    func testBytesReadableUnderKB() {
        let text = String(repeating: "a", count: 500)
        let e = DocumentSizeEstimate.compute(bodyMarkdown: text)
        XCTAssertEqual(e.bytesReadable, "500 B")
    }

    func testVerdictTextPerTier() {
        XCTAssertEqual(DocumentSizeEstimate.Tier.comfortable.verdict, "AI 可轻松读完整篇")
        XCTAssertEqual(DocumentSizeEstimate.Tier.large.verdict, "较大，部分 AI 需分段读")
        XCTAssertEqual(DocumentSizeEstimate.Tier.tooLarge.verdict, "过大，建议拆分后再给 AI")
    }
}
