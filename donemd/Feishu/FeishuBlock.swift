import Foundation

/// Faithful Swift mirror of the JSON shape returned by Feishu's
/// docx OpenAPI (`raw_content` / block tree), modelling **only the
/// subset Done.md round-trips through `FeishuStructuralConverter`**.
///
/// The full Feishu block schema has dozens of payload variants; v2-4a
/// covers eight basic types (heading × 6 / paragraph / list × 2 / todo /
/// quote / code / divider / image). v2-4b/4c extend `Payload` with
/// rich-format and placeholder cases — the enum is the extension seam.
///
/// The shape is **flat**: every block carries its own `parent_id` and
/// child ID list, mirroring how Feishu serializes documents on the wire.
/// Tree assembly happens in the converter, not here.
///
/// v2-4b adds rich-format payloads — `.callout` (highlight block,
/// block_type 19) and `.table` / `.tableCell` (block_types 31 / 32).
/// Mermaid stays inside `.code` with `language = "mermaid"`; it shares
/// the basic code-block code path and needs no new payload variant.
///
/// v2-4c adds `.placeholder` for Feishu-native blocks with no Markdown
/// equivalent (sheet / mindnote / board / bitable / attachment / video /
/// embed). These never carry inline content the way text-bearing blocks
/// do; the converter never reconstructs their bodies locally — they ride
/// across the bridge as opaque references whose content stays in Feishu
/// (ADR-0007).
public struct FeishuBlock: Equatable {

    public var blockId: String
    public var parentId: String?
    /// Child block IDs in document order. The order matters for both
    /// rendering and round-trip equivalence.
    public var children: [String]?
    public var payload: Payload

    public init(
        blockId: String,
        parentId: String? = nil,
        children: [String]? = nil,
        payload: Payload
    ) {
        self.blockId = blockId
        self.parentId = parentId
        self.children = children
        self.payload = payload
    }

    /// `block_type` integer, recovered from `payload`. Kept as a derived
    /// property so the source of truth stays the typed enum — no risk of
    /// `payload` and `blockType` drifting out of sync.
    public var blockType: Int { payload.blockType }
}

extension FeishuBlock {
    public enum Payload: Equatable {
        case page(PagePayload)                  // 1
        case text(TextPayload)                  // 2
        case heading(level: Int, TextPayload)   // 3..8 (level 1..6)
        case bullet(TextPayload)                // 12
        case ordered(TextPayload)               // 13
        case code(CodePayload)                  // 14
        case quote(TextPayload)                 // 34 (quote_container)
        case todo(TextPayload, done: Bool)      // 17
        case callout(CalloutPayload)            // 19
        case divider                            // 22
        case image(ImagePayload)                // 27
        case table(TablePayload)                // 31
        case tableCell                          // 32
        case placeholder(PlaceholderPayload)    // 23 / 24 / 25 / 26 / 28 / 33 / 43

        public var blockType: Int {
            switch self {
            case .page: return 1
            case .text: return 2
            case .heading(let level, _): return 2 + max(1, min(level, 6))
            case .bullet: return 12
            case .ordered: return 13
            case .code: return 14
            case .quote: return 34
            case .todo: return 17
            case .callout: return 19
            case .divider: return 22
            case .image: return 27
            case .table: return 31
            case .tableCell: return 32
            case .placeholder(let p): return p.subtype.blockType
            }
        }
    }

    /// Page (root) block carries title elements; for v2-4a we only round-
    /// trip the title text. Real Feishu pages have many title-style attrs
    /// (cover image, etc.) — out of scope.
    public struct PagePayload: Equatable {
        public var title: TextPayload
        public init(title: TextPayload = TextPayload()) {
            self.title = title
        }
    }

    /// Inline content of a block: an ordered list of styled runs (and,
    /// later, mentions / equations). v2-4a only has `textRun`.
    public struct TextPayload: Equatable {
        public var elements: [TextElement]
        public init(elements: [TextElement] = []) {
            self.elements = elements
        }
    }

    public enum TextElement: Equatable {
        case textRun(TextRun)
    }

    public struct TextRun: Equatable {
        public var content: String
        public var style: TextElementStyle
        public init(content: String, style: TextElementStyle = TextElementStyle()) {
            self.content = content
            self.style = style
        }
    }

    public struct TextElementStyle: Equatable {
        public var bold: Bool
        public var italic: Bool
        public var inlineCode: Bool
        public var strikethrough: Bool
        public var link: String?

        /// Pull-side hint: this run carried `text_color` / `background_color`
        /// in the Feishu wire payload that Done.md doesn't yet model
        /// (no color/highlight mark in the Tiptap schema). The decoder
        /// records it here so the converter can surface a warning to the
        /// user ("N 处文字颜色未保留"), and so push round-trip never
        /// silently restores half-truth — until Phase 5 adds native
        /// color/highlight marks (#59), the round-trip is honest one-way:
        /// pull strips, push omits.
        public var hadStrippedFeishuColor: Bool

        public init(
            bold: Bool = false,
            italic: Bool = false,
            inlineCode: Bool = false,
            strikethrough: Bool = false,
            link: String? = nil,
            hadStrippedFeishuColor: Bool = false
        ) {
            self.bold = bold
            self.italic = italic
            self.inlineCode = inlineCode
            self.strikethrough = strikethrough
            self.link = link
            self.hadStrippedFeishuColor = hadStrippedFeishuColor
        }

        public static let plain = TextElementStyle()
    }

    public struct CodePayload: Equatable {
        public var elements: [TextElement]
        /// Canonical lowercase language name (`swift`, `python`, etc.).
        /// v2-4a stores Feishu's language as-is — Feishu uses an Int
        /// enum on the wire, but `FeishuStructuralConverter` accepts the
        /// already-translated string at the data-model boundary so the
        /// converter doesn't have to embed the full language table.
        public var language: String?

        public init(elements: [TextElement] = [], language: String? = nil) {
            self.elements = elements
            self.language = language
        }
    }

    /// Highlight / callout block (Feishu block_type 19).
    ///
    /// Carries the visual style (`emoji` + `backgroundColor`) Feishu
    /// renders; the actual children (paragraphs, lists, headings, nested
    /// quotes) live in the regular `children` ID list. Code blocks /
    /// tables / images / dividers are forbidden inside per Feishu's
    /// hard limit (CONTEXT.md §高亮块) — converter enforces this.
    public struct CalloutPayload: Equatable {
        /// Emoji shown by Feishu (`💡`, `⚠️`, etc.). Optional in the wire
        /// format; some legacy callouts ship without one.
        public var emoji: String?
        /// `light-blue`, `light-green`, `light-purple`, `light-yellow`,
        /// `light-red`, etc. — see Feishu MD syntax reference.
        public var backgroundColor: String?

        public init(emoji: String? = nil, backgroundColor: String? = nil) {
            self.emoji = emoji
            self.backgroundColor = backgroundColor
        }
    }

    /// Table block (Feishu block_type 31). Children are `table_cell`
    /// blocks in row-major order (length must equal `rowSize × columnSize`).
    /// Done.md does not support cell merging — `headerRow` is always
    /// `true` on the local side because GFM tables require a header row.
    public struct TablePayload: Equatable {
        public var rowSize: Int
        public var columnSize: Int
        public var headerRow: Bool

        public init(rowSize: Int, columnSize: Int, headerRow: Bool = true) {
            self.rowSize = rowSize
            self.columnSize = columnSize
            self.headerRow = headerRow
        }
    }

    /// One of the seven Feishu-native block types Done.md ferries through
    /// as opaque references (ADR-0007). The integer `blockType` mappings
    /// follow Feishu's docx OpenAPI — these are best-effort declarations
    /// for the converter's round-trip; v2-5 (`FeishuAPIClient`) confirms
    /// each value against live API responses and adjusts if Feishu's wire
    /// format disagrees.
    public enum PlaceholderSubtype: String, Equatable, CaseIterable {
        case attachment   // 23
        case sheet        // 24
        case mindnote     // 25
        case video        // 26
        case bitable      // 28
        case embed        // 33  third-party iframe / jira / etc.
        case board        // 43  Feishu native whiteboard (≠ mermaid)

        public var blockType: Int {
            switch self {
            case .attachment: return 23
            case .sheet: return 24
            case .mindnote: return 25
            case .video: return 26
            case .bitable: return 28
            case .embed: return 33
            case .board: return 43
            }
        }
    }

    /// Payload for a Feishu-native block routed through the local
    /// `feishu_placeholder_block` Tiptap node + `<!-- feishu-placeholder -->`
    /// magic comment. Carries every field ADR-0007 promises to round-trip,
    /// plus an `unknownFields` slot for forward-compat metadata Feishu may
    /// add in the future.
    ///
    /// `subtype` carries the wire-shape identity (sheet / mindnote / …).
    /// The owning `FeishuBlock.blockId` is the Feishu document's actual
    /// block ID — never overwritten by synthetic IDs the converter assigns
    /// to other block types. `PushCoordinator` (v2-9) reads `blockId` and
    /// `subtype.rawValue` to emit the `_done_md_directive: preserve_existing`
    /// reference shape that flips Feishu OpenAPI into "reference an existing
    /// block, don't recreate it" mode.
    public struct PlaceholderPayload: Equatable {
        public var subtype: PlaceholderSubtype
        public var blockToken: String?
        public var title: String
        public var summary: String?
        public var url: String
        public var createdInFeishuAt: String?
        /// Feishu-side metadata Done.md doesn't recognize, preserved
        /// verbatim in original order so future Feishu schema additions
        /// round-trip untouched. Reuses the same shape as
        /// `FeishuPlaceholderEngine`.
        public var unknownFields: [UnknownPlaceholderField]

        public init(
            subtype: PlaceholderSubtype,
            blockToken: String? = nil,
            title: String,
            summary: String? = nil,
            url: String,
            createdInFeishuAt: String? = nil,
            unknownFields: [UnknownPlaceholderField] = []
        ) {
            self.subtype = subtype
            self.blockToken = blockToken
            self.title = title
            self.summary = summary
            self.url = url
            self.createdInFeishuAt = createdInFeishuAt
            self.unknownFields = unknownFields
        }
    }

    /// JSON-shaped reference structure (`{block_id, block_type,
    /// _done_md_directive: "preserve_existing"}`) for placeholder blocks.
    /// Returns `nil` for any non-placeholder block — callers who need to
    /// distinguish "this block is a preserve-existing reference" from
    /// "this block carries full content" branch on this property.
    ///
    /// String keys / values keep the call site free of `Any`; the JSON
    /// encoder in `PushCoordinator` (v2-9) lifts these into the wire
    /// payload alongside regular blocks. ADR-0007 § 推送时如何还原飞书侧原块
    /// pins the exact field names.
    public var preserveExistingReference: [String: String]? {
        guard case .placeholder(let p) = payload else { return nil }
        return [
            "block_id": blockId,
            "block_type": p.subtype.rawValue,
            "_done_md_directive": "preserve_existing",
        ]
    }

    public struct ImagePayload: Equatable {
        /// `image_token` returned by Feishu's media upload endpoint.
        /// For v2-4a we store and round-trip whatever the source supplies;
        /// actual upload happens in v2-5.
        public var token: String?
        /// Fallback URL for images authored locally (Markdown `![alt](url)`)
        /// before they've been uploaded. After upload `token` is filled.
        public var src: String?
        public var alt: String?
        public var width: Int?
        public var height: Int?

        public init(
            token: String? = nil,
            src: String? = nil,
            alt: String? = nil,
            width: Int? = nil,
            height: Int? = nil
        ) {
            self.token = token
            self.src = src
            self.alt = alt
            self.width = width
            self.height = height
        }
    }
}
