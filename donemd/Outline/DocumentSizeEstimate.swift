import Foundation

/// AI-readability estimate for the current document body (源码区顶栏, #82).
///
/// The user's goal: "let me know whether this .md is feasible to hand to an AI
/// to read." The honest metric for that is **token count**, not byte size —
/// what an AI can ingest, and its context-window ceiling, are counted in tokens,
/// and the byte/token ratio differs sharply between CJK and Latin text (a
/// Chinese character is 3 bytes in UTF-8 but roughly 0.6 tokens; ~4 Latin
/// characters make ~1 token). So the same KB can be very different token loads.
///
/// We can't tokenize exactly (every model's tokenizer differs), so this is a
/// deliberately-labeled `≈` estimate from a CJK-weighted character heuristic.
/// It's a pure function of the markdown string — no model dependency — so the
/// verdict stays stable and testable.
struct DocumentSizeEstimate: Equatable {
    /// UTF-8 byte size of the body markdown. Shown as a secondary detail (KB).
    let byteCount: Int
    /// Number of Unicode scalar "characters" (Swift `Character` count), i.e.
    /// human-visible glyphs. The 字数 shown in the tooltip.
    let characterCount: Int
    /// Estimated token count (`≈`). Never exact — see `estimateTokens`.
    let estimatedTokens: Int
    /// The three-way readability bucket driving the color dot + one-line verdict.
    let tier: Tier

    /// Readability tiers, keyed by estimated tokens. Boundaries chosen to be
    /// model-agnostic (not tied to one provider's window): ≤16K reads
    /// comfortably almost everywhere, 16–64K is large enough that smaller-window
    /// models must chunk, >64K exceeds most single-pass windows. The user sees a
    /// plain-language verdict, never the tier name (等级词 has comprehension cost).
    enum Tier: Equatable {
        case comfortable   // 🟢 ≤ 16K
        case large         // 🟡 16K–64K
        case tooLarge      // 🔴 > 64K

        /// Plain-language verdict — states what an AI can do with the doc, no
        /// jargon, no tier label. Chosen口吻: 直说 AI 能不能读.
        var verdict: String {
            switch self {
            case .comfortable: return "AI 可轻松读完整篇"
            case .large:       return "较大，部分 AI 需分段读"
            case .tooLarge:    return "过大，建议拆分后再给 AI"
            }
        }
    }

    /// Threshold constants (estimated tokens). Named so the tests and the tier
    /// logic share one definition.
    static let comfortableCeiling = 16_000
    static let largeCeiling = 64_000

    /// Compute the estimate from body markdown (frontmatter excluded by the
    /// caller — frontmatter is Feishu sync metadata, not content you'd feed an
    /// AI, so it shouldn't inflate the reading estimate).
    static func compute(bodyMarkdown: String) -> DocumentSizeEstimate {
        let bytes = bodyMarkdown.utf8.count
        let chars = bodyMarkdown.count
        let tokens = estimateTokens(bodyMarkdown)
        let tier: Tier
        if tokens <= comfortableCeiling {
            tier = .comfortable
        } else if tokens <= largeCeiling {
            tier = .large
        } else {
            tier = .tooLarge
        }
        return DocumentSizeEstimate(
            byteCount: bytes,
            characterCount: chars,
            estimatedTokens: tokens,
            tier: tier
        )
    }

    /// CJK-weighted token heuristic. We split the character stream into two
    /// classes and weight each by its typical token density:
    ///
    ///   • CJK (Han / Kana / Hangul, plus full-width forms): ≈ 0.6 token per
    ///     character — most common CJK words are one or two tokens.
    ///   • Everything else (Latin letters, digits, whitespace, punctuation,
    ///     markdown syntax): ≈ 1 token per 4 characters, the well-known English
    ///     rule of thumb.
    ///
    /// This is intentionally simple and provider-neutral; the UI labels the
    /// result `≈` so it never reads as an exact count.
    static func estimateTokens(_ text: String) -> Int {
        var cjk = 0
        var other = 0
        for scalar in text.unicodeScalars {
            if isCJK(scalar) {
                cjk += 1
            } else {
                other += 1
            }
        }
        let cjkTokens = Double(cjk) * 0.6
        let otherTokens = Double(other) / 4.0
        return Int((cjkTokens + otherTokens).rounded())
    }

    /// Whether a scalar belongs to a CJK block dense enough to warrant the
    /// per-character token weight. Covers the ranges that actually show up in
    /// Chinese/Japanese/Korean prose; anything outside falls to the Latin rule.
    private static func isCJK(_ s: Unicode.Scalar) -> Bool {
        switch s.value {
        case 0x3040...0x30FF,   // Hiragana + Katakana
             0x3400...0x4DBF,   // CJK Extension A
             0x4E00...0x9FFF,   // CJK Unified Ideographs
             0xF900...0xFAFF,   // CJK Compatibility Ideographs
             0xFF00...0xFFEF,   // Full-width forms (、。！？ etc.)
             0xAC00...0xD7AF,   // Hangul syllables
             0x20000...0x2A6DF: // CJK Extension B
            return true
        default:
            return false
        }
    }

    // MARK: - Display helpers

    /// SF Symbol / colored dot is drawn by the view; this is the tier's semantic
    /// color name the view maps to a SwiftUI Color.
    var tierColorIsGreen: Bool { tier == .comfortable }
    var tierColorIsYellow: Bool { tier == .large }
    var tierColorIsRed: Bool { tier == .tooLarge }

    /// "≈12K tokens" — the compact primary readout. Rounds to K above 1000 so
    /// the narrow top bar stays legible; below 1000 shows the raw number.
    var tokensCompact: String {
        if estimatedTokens >= 1000 {
            let k = Double(estimatedTokens) / 1000.0
            // One decimal below 10K (≈4.2K), whole K at/above (≈40K) — keeps it short.
            if k < 10 {
                return String(format: "≈%.1fK tokens", k)
            }
            return "≈\(Int(k.rounded()))K tokens"
        }
        return "≈\(estimatedTokens) tokens"
    }

    /// "34 KB" — secondary detail for the tooltip. Uses KB (1024) with no
    /// decimal for compactness; shows bytes under 1 KB.
    var bytesReadable: String {
        if byteCount >= 1024 {
            return "\(Int((Double(byteCount) / 1024.0).rounded())) KB"
        }
        return "\(byteCount) B"
    }

    /// "8,200 字" — character count with thousands separators for the tooltip.
    var charactersReadable: String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        let n = formatter.string(from: NSNumber(value: characterCount)) ?? "\(characterCount)"
        return "\(n) 字"
    }
}
