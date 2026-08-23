import Foundation

/// Canonical mapping between Done.md's 5 GitHub-style callout types and
/// Feishu's `(emoji, background-color)` callout payload.
///
/// **Single source of truth** for the table referenced as
/// "PRD § 飞书 callout 类型映射表" — this enum is what production code,
/// tests, and the PRD section all point to. If the table needs to change
/// (e.g. a new emoji), update here and update PRD/CONTEXT.md text alongside.
///
/// Resolution direction:
/// - **Local → Feishu**: pick `emoji` + `backgroundColor` from the type.
/// - **Feishu → local**: dispatch on `backgroundColor` first (1:1 to the
///   5 colors). `emoji` is informational; users may have edited it
///   manually in Feishu and we still want a stable type.
///
/// Callouts whose Feishu `backgroundColor` falls outside the canonical
/// 5-color set fall back to `.note` (closest neutral) — converter logs
/// the original color so v2-12 acceptance can flag if real-world
/// documents need a wider palette.
public enum FeishuCalloutType: String, Equatable, CaseIterable {
    case note
    case tip
    case important
    case warning
    case caution

    public var emoji: String {
        switch self {
        case .note: return "💡"
        case .tip: return "✨"
        case .important: return "❗"
        case .warning: return "⚠️"
        case .caution: return "🚨"
        }
    }

    /// Wire-format `emoji_id` value the Feishu callout endpoint
    /// requires. **Different from `emoji`**: the wire wants a named
    /// string ID (`"bulb"`, `"sparkles"`, …), not the Unicode glyph.
    /// Sending the Unicode codepoint as `emoji_id` returns 1770006
    /// schema mismatch — confirmed real-device 2026-06-04.
    ///
    /// Source of names: https://open.feishu.cn/document/docs/docs/data-structure/emoji
    /// (cross-checked against feishu-mcp-pro's CALLOUT_EMOJI_MAP).
    /// We only need 5 mappings — one per FeishuCalloutType — so a
    /// computed property is enough; full Unicode→named lookup table
    /// (~900 entries) isn't needed in Done.md because user-typed
    /// arbitrary emojis don't reach this path: the only callouts the
    /// converter emits are these 5 canonical types.
    public var wireEmojiId: String {
        switch self {
        case .note: return "bulb"
        case .tip: return "sparkles"
        case .important: return "exclamation"
        case .warning: return "warning"
        case .caution: return "rotating_light"
        }
    }

    public var backgroundColor: String {
        switch self {
        case .note: return "light-blue"
        case .tip: return "light-green"
        case .important: return "light-purple"
        case .warning: return "light-yellow"
        case .caution: return "light-red"
        }
    }

    /// Reverse-lookup from a Feishu callout payload's `(emoji, color)`.
    /// Color is the primary discriminator; `emoji` is ignored. Returns
    /// `.note` for any unknown color so unknown-palette Feishu callouts
    /// don't crash the converter.
    public static func from(emoji: String?, backgroundColor: String?) -> FeishuCalloutType {
        switch backgroundColor {
        case "light-blue": return .note
        case "light-green": return .tip
        case "light-purple": return .important
        case "light-yellow": return .warning
        case "light-red": return .caution
        default: return .note
        }
    }
}
