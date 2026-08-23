import Foundation

/// v2-9a-step1' (Slice rewrite of #50) — wire encoder/decoder for Feishu's
/// docx blocks API.
///
/// Encoding direction (`FeishuBlock` → `[String: Any]`) is what the
/// `POST .../blocks/{parent_id}/descendant` endpoint consumes:
///
///     {
///       "index": -1,
///       "children_id": [<top-level synthetic IDs from the page block>],
///       "descendants": [<every non-page block, see encodeBlockEnvelope>]
///     }
///
/// Decoding direction (`[String: Any]` → `FeishuBlock`) replaces v2-5's
/// `.divider`-fallback `WireBlock` decoder. v2-5 left this stubbed because
/// no real Feishu response was on hand at TDD time; this file now handles
/// the same eight block types `FeishuStructuralConverter` round-trips.
///
/// **Real-line uncertainty:** Feishu's docx OpenAPI doc site requires JS
/// rendering, so a few field names below are best-effort. v2-9a-step1'
/// expects to refine via real-line iteration through the #DEBUG push menu —
/// the partial-success protocol catches each failure cleanly so we can
/// fix one field-name typo per round-trip. Call sites flag uncertain
/// fields with `// TODO(integration)` comments.
enum FeishuBlockEncoder {

    // MARK: - public entry points

    /// Encode a `[FeishuBlock]` (with a synthetic page root from
    /// `FeishuStructuralConverter.toFeishuBlocks`) into the body shape
    /// for `POST .../blocks/{parent_id}/descendant`.
    ///
    /// Throws `FeishuBlockEncodingError.missingPageRoot` if the input
    /// has no page block — the converter always emits one, so this is a
    /// programmer error, not a recoverable wire error.
    static func encodeDescendantBody(
        from blocks: [FeishuBlock],
        index: Int = -1
    ) throws -> [String: Any] {
        guard let page = blocks.first(where: {
            if case .page = $0.payload { return true } else { return false }
        }) else {
            throw FeishuBlockEncodingError.missingPageRoot
        }
        let topLevelIds = Set(page.children ?? [])
        let nonPageBlocks = blocks.filter {
            if case .page = $0.payload { return false } else { return true }
        }
        // Top-level descendants reference the synthetic page block id
        // we minted in `tiptapToBlocks` (e.g. "blk_000001") via their
        // `parent_id` field — but Feishu's strict wire validator rejects
        // the body with code 1770001 when those parent_ids don't match
        // any real block on the document side. The endpoint already
        // takes the real parent block id as a path param, so the
        // body's root-level parent_id is redundant. Strip it on
        // top-level blocks; nested descendants (table cells pointing
        // at their table parent, etc.) keep their parent_id since
        // those references are internal to the descendants array and
        // the validator does check them for consistency. Discovered
        // by real-device push of a doc containing a table block —
        // the failure mode survived because tables nest, which made
        // the validator suddenly care about the root parent_id (most
        // single-block payloads slip through with a nonsense root
        // parent_id ignored).
        let descendants = nonPageBlocks
            .flatMap(encodeBlockToWire)
            .map { (envelope: [String: Any]) -> [String: Any] in
                guard let id = envelope["block_id"] as? String,
                      topLevelIds.contains(id) else {
                    return envelope
                }
                var stripped = envelope
                stripped.removeValue(forKey: "parent_id")
                return stripped
            }
        return [
            "index": index,
            "children_id": Array(page.children ?? []),
            "descendants": descendants,
        ]
    }

    /// Encode one typed block as one or more wire dicts. Most blocks emit a
    /// single envelope; `.quote` expands into two — Feishu models a quote as
    /// a `quote_container` (block_type 34, empty body) whose visible text
    /// lives in a child text block (block_type 2). Trying to inline the text
    /// onto the container fails the field validator with code 99992402.
    static func encodeBlockToWire(_ block: FeishuBlock) -> [[String: Any]] {
        if case .quote(let textPayload) = block.payload {
            return encodeQuoteContainer(block: block, text: textPayload)
        }
        return [encodeBlockEnvelope(block)]
    }

    /// Encode a single block as the dict shape Feishu expects inside
    /// `descendants`: `{ block_id, block_type, parent_id?, children?, <payload-key>: <payload-dict> }`.
    static func encodeBlockEnvelope(_ block: FeishuBlock) -> [String: Any] {
        var dict: [String: Any] = [
            "block_id": block.blockId,
            "block_type": block.blockType,
        ]
        if let parent = block.parentId {
            dict["parent_id"] = parent
        }
        if let children = block.children, !children.isEmpty {
            dict["children"] = children
        }
        let (key, payload) = encodePayload(block.payload)
        if let payload {
            dict[key] = payload
        }
        return dict
    }

    /// Quote expansion: container + synthesized child text block.
    /// The text child id is derived deterministically (`<quoteId>_qtxt`) so a
    /// re-encode of the same input produces the same wire IDs — useful for
    /// stable diff inspection during real-line iteration.
    private static func encodeQuoteContainer(
        block: FeishuBlock, text: FeishuBlock.TextPayload
    ) -> [[String: Any]] {
        let textChildId = block.blockId + "_qtxt"
        let nestedChildren = block.children ?? []
        var container: [String: Any] = [
            "block_id": block.blockId,
            "block_type": 34,
            "children": [textChildId] + nestedChildren,
            "quote_container": [String: Any](),
        ]
        if let parent = block.parentId {
            container["parent_id"] = parent
        }
        let textChild: [String: Any] = [
            "block_id": textChildId,
            "block_type": 2,
            "parent_id": block.blockId,
            "text": ["elements": encodeElements(text.elements)],
        ]
        return [container, textChild]
    }

    // MARK: - payload encoding

    /// Returns `(field_name, payload_dict_or_nil)`. `divider` carries an
    /// empty dict — Feishu requires the field to be present even when
    /// it has no body.
    private static func encodePayload(_ payload: FeishuBlock.Payload)
        -> (String, [String: Any]?)
    {
        switch payload {
        case .page(let p):
            return ("page", ["elements": encodeElements(p.title.elements)])
        case .text(let t):
            return ("text", encodeTextBody(t))
        case .heading(let level, let t):
            // Feishu uses block_type 3..8 for heading 1..6 and the
            // payload field name `heading1` ... `heading6`.
            return ("heading\(level)", encodeTextBody(t))
        case .bullet(let t):
            return ("bullet", encodeTextBody(t))
        case .ordered(let t):
            return ("ordered", encodeTextBody(t))
        case .quote:
            // Real wire response (2026-05-24): a quote is a `quote_container`
            // (block_type 34, empty body) with the text living in a child
            // block. The expansion happens in `encodeQuoteContainer`; this
            // branch only fires if a caller invokes `encodeBlockEnvelope`
            // directly on a `.quote`, in which case we emit the empty
            // container shape so the wire payload at least passes validation.
            return ("quote_container", [:])
        case .todo(let t, let done):
            var body = encodeTextBody(t)
            // Todo carries `done` inside the per-block style sub-object.
            var style: [String: Any] = (body["style"] as? [String: Any]) ?? [:]
            style["done"] = done
            body["style"] = style
            return ("todo", body)
        case .code(let c):
            // Feishu's wire schema requires `style.language` to be an
            // integer enum (1..73 mapping to Swift / Python / etc.) — a
            // string trips field validation (real-line 99992402, 2026-05-24).
            // The full enum table isn't wired up yet; until then, emit a
            // language-less code block so the body lands on Feishu, then
            // fill the language in a follow-up. `wrap: false` matches
            // Feishu's default echo.
            //
            // The converter's `c.language` is preserved on the typed model
            // for round-trip back to markdown — only the wire output drops
            // it.
            _ = c.language
            return ("code", [
                "elements": encodeElements(c.elements),
                "style": ["wrap": false],
            ])
        case .divider:
            return ("divider", [:])
        case .image(let img):
            var body: [String: Any] = [:]
            if let token = img.token { body["token"] = token }
            if let width = img.width { body["width"] = width }
            if let height = img.height { body["height"] = height }
            // `src` is intentionally NOT sent: Feishu only accepts an
            // `image_token` (post-upload). v2-9a-step2 owns the
            // upload-then-rewrite flow; for step1' an image with no
            // token won't reach here because the converter strips it.
            return ("image", body)
        case .callout(let c):
            var body: [String: Any] = [:]
            if let emoji = c.emoji { body["emoji_id"] = emoji }
            if let bg = c.backgroundColor,
               let bgNum = lightColorNumber(forName: bg) {
                // Feishu wire requires the background_color as one of
                // the int codes 1-15, NOT the human-readable
                // "light-blue" / "light-green" name. Real-device push
                // returned 99992402 "field validation failed:
                // descendants[*].callout.background_color is optional,
                // options: [1,2,...,15]". Map locally; unknown names
                // (palette additions / typos) fall through to no
                // background — same effect as the omit-when-nil path
                // above, never blocks the push.
                body["background_color"] = bgNum
            }
            return ("callout", body)
        case .table(let t):
            return ("table", [
                "property": [
                    "row_size": t.rowSize,
                    "column_size": t.columnSize,
                    "header_row": t.headerRow,
                ],
            ])
        case .tableCell:
            return ("table_cell", [:])
        case .placeholder:
            // step3 / 9b owns preserve_existing reference shape. Step1'
            // never invokes the encoder on a placeholder block — the
            // coordinator filters them out before encoding. If one does
            // reach here, drop it cleanly (return nil payload) rather
            // than emitting a bogus block_type Feishu can't materialize.
            return ("placeholder", nil)
        }
    }

    // MARK: - text payload helpers

    /// `text` payload field shape: `{ "elements": [...], "style": {...} }`.
    /// `style` is omitted when empty so Feishu's strict decoders don't
    /// reject extra-but-empty objects.
    private static func encodeTextBody(_ payload: FeishuBlock.TextPayload) -> [String: Any] {
        return ["elements": encodeElements(payload.elements)]
    }

    /// Internal so `FeishuHTTPAPIClient.updateDocumentTitle` can reuse the
    /// same wire-shape for the page-block `update_text_elements` payload —
    /// keeping the strict-validator-required style defaults (see
    /// `encodeStyle`) in one place.
    ///
    /// Empty input produces a single empty-content textRun rather than
    /// an empty `elements: []` array. Feishu's strict validator on the
    /// `descendant` endpoint rejects bodies whose text payload has an
    /// empty elements list with code 1770001 (real-device push of any
    /// document containing an empty table cell hit this). The
    /// no-content placeholder textRun keeps the wire shape valid while
    /// rendering as an empty cell on Feishu side.
    static func encodeElements(_ elements: [FeishuBlock.TextElement]) -> [[String: Any]] {
        guard !elements.isEmpty else {
            return [encodeElement(.textRun(.init(content: "")))]
        }
        return elements.map(encodeElement)
    }

    private static func encodeElement(_ element: FeishuBlock.TextElement) -> [String: Any] {
        switch element {
        case .textRun(let run):
            return ["text_run": [
                "content": run.content,
                "text_element_style": encodeStyle(run.style),
            ]]
        }
    }

    /// Real-line responses (2026-05-24) always echo all five booleans
    /// explicit, including `underline` which our model doesn't track yet.
    /// The strict validator (error 99992402) rejects styles missing any of
    /// the five keys, so we emit them all on every text run — plus `link`
    /// when present.
    private static func encodeStyle(_ style: FeishuBlock.TextElementStyle) -> [String: Any] {
        var dict: [String: Any] = [
            "bold": style.bold,
            "italic": style.italic,
            "inline_code": style.inlineCode,
            "strikethrough": style.strikethrough,
            "underline": false,
        ]
        if let link = style.link {
            dict["link"] = ["url": link]
        }
        return dict
    }

    // MARK: - decoding (replacement for v2-5's WireBlock stub)

    /// Decode a Feishu block JSON dict (as returned by the GET `/blocks`
    /// listing) into a typed `FeishuBlock`. Replaces the `.divider`-only
    /// fallback v2-5 shipped before any real wire fixture was on hand.
    ///
    /// Unknown block_types still fall through to `.divider` so the pull
    /// path never hard-fails on a Feishu schema addition — diagnosable via
    /// logs, not an exception.
    static func decodeBlockEnvelope(_ dict: [String: Any]) throws -> FeishuBlock {
        guard let blockId = dict["block_id"] as? String,
              let blockTypeRaw = dict["block_type"] as? Int else {
            throw FeishuBlockEncodingError.malformedEnvelope
        }
        let parentId = dict["parent_id"] as? String
        let children = dict["children"] as? [String]
        let payload = decodePayload(blockType: blockTypeRaw, dict: dict)
        return FeishuBlock(
            blockId: blockId, parentId: parentId,
            children: children, payload: payload
        )
    }

    private static func decodePayload(blockType: Int, dict: [String: Any]) -> FeishuBlock.Payload {
        switch blockType {
        case 1:
            let body = dict["page"] as? [String: Any] ?? [:]
            return .page(.init(title: decodeTextPayload(body)))
        case 2:
            return .text(decodeTextPayload(dict["text"] as? [String: Any] ?? [:]))
        case 3...8:
            let level = blockType - 2
            let body = dict["heading\(level)"] as? [String: Any] ?? [:]
            return .heading(level: level, decodeTextPayload(body))
        case 12:
            return .bullet(decodeTextPayload(dict["bullet"] as? [String: Any] ?? [:]))
        case 13:
            return .ordered(decodeTextPayload(dict["ordered"] as? [String: Any] ?? [:]))
        case 14:
            let body = dict["code"] as? [String: Any] ?? [:]
            let style = body["style"] as? [String: Any] ?? [:]
            let language = (style["language"] as? String)
                ?? (style["language"] as? Int).map(String.init)
            return .code(.init(
                elements: decodeElements(body["elements"] as? [[String: Any]] ?? []),
                language: language
            ))
        case 34:
            // `quote_container` carries no inline text — Feishu hangs the
            // quote text on a child block (block_type 2). Pull only needs
            // page.children for the delete leg in v2-9a-step1', so an empty
            // payload is fine here; v2-9b PullCoordinator will reassemble
            // the container + child into a single typed `.quote`.
            return .quote(.init())
        case 15:
            // Legacy quote shape, kept for back-compat reading until we're
            // sure no docs in the wild still serialize this way.
            return .quote(decodeTextPayload(dict["quote"] as? [String: Any] ?? [:]))
        case 17:
            let body = dict["todo"] as? [String: Any] ?? [:]
            let style = body["style"] as? [String: Any] ?? [:]
            let done = (style["done"] as? Bool) ?? false
            return .todo(decodeTextPayload(body), done: done)
        case 19:
            let body = dict["callout"] as? [String: Any] ?? [:]
            // background_color comes back as an Int (1-15) — same
            // shape encoder writes for push. We map back to the
            // canonical "light-*" name so the rest of Done.md keeps
            // its string-typed enum surface unchanged.
            let bgName: String?
            if let bgNum = body["background_color"] as? Int {
                bgName = lightColorName(forNumber: bgNum)
            } else {
                // Tolerate older / mock responses that send a string,
                // and leave nil when the field is missing entirely.
                bgName = body["background_color"] as? String
            }
            return .callout(.init(
                emoji: body["emoji_id"] as? String,
                backgroundColor: bgName
            ))
        case 22:
            return .divider
        case 27:
            let body = dict["image"] as? [String: Any] ?? [:]
            return .image(.init(
                token: body["token"] as? String,
                src: nil,
                alt: body["alt"] as? String,
                width: body["width"] as? Int,
                height: body["height"] as? Int
            ))
        case 31:
            let body = dict["table"] as? [String: Any] ?? [:]
            let prop = body["property"] as? [String: Any] ?? [:]
            return .table(.init(
                rowSize: (prop["row_size"] as? Int) ?? 0,
                columnSize: (prop["column_size"] as? Int) ?? 0,
                headerRow: (prop["header_row"] as? Bool) ?? true
            ))
        case 32:
            return .tableCell
        case 43:
            // Board (whiteboard / 画板). Wire shape: { board: { token } }.
            // Verified live 2026-05-30 against feishu-mcp-pro (which uses
            // BLOCK_TYPE.Board === 43).
            let body = dict["board"] as? [String: Any] ?? [:]
            let token = body["token"] as? String ?? ""
            return .placeholder(.init(
                subtype: .board,
                blockToken: token.isEmpty ? nil : token,
                title: "画板",
                summary: nil,
                url: token.isEmpty ? "" : "feishu://board/\(token)"
            ))
        case 30:
            // Sheet (电子表格). Wire shape: { sheet: { token, row_size?, column_size? } }.
            // Verified live 2026-05-30 — note this is BLOCK_TYPE.Sheet === 30,
            // NOT 24 as the legacy `PlaceholderSubtype.sheet.blockType`
            // declares. The push side still emits 24 because that's what
            // ADR-0007 froze and the v2-9c segmented-push contract is
            // built on; mismatched encode/decode numbers is acceptable
            // here because pull never round-trips through that integer
            // (it goes block -> magic-comment -> block via subtype enum
            // name). A follow-up issue will reconcile the enum.
            let body = dict["sheet"] as? [String: Any] ?? [:]
            let token = body["token"] as? String ?? ""
            let rows = body["row_size"] as? Int
            let cols = body["column_size"] as? Int
            var summary: String? = nil
            if let r = rows, let c = cols { summary = "\(r) × \(c)" }
            return .placeholder(.init(
                subtype: .sheet,
                blockToken: token.isEmpty ? nil : token,
                title: "电子表格",
                summary: summary,
                url: token.isEmpty ? "" : "feishu://sheet/\(token)"
            ))
        case 18:
            // Bitable (多维表格). Wire shape: { bitable: { token, view_type? } }.
            // BLOCK_TYPE.Bitable === 18 in feishu-mcp-pro.
            let body = dict["bitable"] as? [String: Any] ?? [:]
            let token = body["token"] as? String ?? ""
            let viewType = body["view_type"] as? Int
            let viewLabel: String?
            switch viewType {
            case 1: viewLabel = "table"
            case 2: viewLabel = "kanban"
            default: viewLabel = nil
            }
            return .placeholder(.init(
                subtype: .bitable,
                blockToken: token.isEmpty ? nil : token,
                title: "多维表格",
                summary: viewLabel,
                url: token.isEmpty ? "" : "feishu://bitable/\(token)"
            ))
        case 29:
            // Mindnote (思维笔记). Wire shape: { mindnote: { token } }.
            // BLOCK_TYPE.Mindnote === 29.
            let body = dict["mindnote"] as? [String: Any] ?? [:]
            let token = body["token"] as? String ?? ""
            return .placeholder(.init(
                subtype: .mindnote,
                blockToken: token.isEmpty ? nil : token,
                title: "思维笔记",
                summary: nil,
                url: token.isEmpty ? "" : "feishu://mindnote/\(token)"
            ))
        case 26:
            // Iframe (嵌入资源). Wire shape:
            //   { iframe: { component: { url, iframe_type } } }
            // BLOCK_TYPE.Iframe === 26.
            let body = dict["iframe"] as? [String: Any] ?? [:]
            let component = body["component"] as? [String: Any] ?? [:]
            let url = component["url"] as? String ?? ""
            return .placeholder(.init(
                subtype: .embed,
                blockToken: nil,
                title: "嵌入资源",
                summary: nil,
                url: url
            ))
        case 23:
            // File (附件). Wire shape: { file: { token, name? } }.
            // BLOCK_TYPE.File === 23.
            let body = dict["file"] as? [String: Any] ?? [:]
            let token = body["token"] as? String ?? ""
            let name = body["name"] as? String
            return .placeholder(.init(
                subtype: .attachment,
                blockToken: token.isEmpty ? nil : token,
                title: name ?? "附件",
                summary: nil,
                url: token.isEmpty ? "" : "feishu://file/\(token)"
            ))
        case 33:
            // View (视图) — Feishu wraps an uploaded video (and some
            // other inline media) in a `view` block whose child `file`
            // block (block_type 23) carries the real token + filename.
            // This per-block decode can't reach the child, so we emit a
            // bare `.video` placeholder here and let
            // FeishuStructuralConverter absorb the child file's token +
            // name during tree assembly (where `byId` is available).
            // Verified live 2026-08-16 against docx
            // JS04dEQuRoAd4DxBtplcYwWWn4v: a video = view(33, view_type:2)
            // → file(23, *.mp4). Without this case the view fell through
            // to `.divider` and the video was silently lost, violating the
            // structural-fidelity guarantee (ADR-0007 「不丢信息」).
            //
            // NOTE: `.video`'s frozen enum blockType is 26 (ADR-0007),
            // which diverges from this real wire type 33 — the same
            // accepted encode/decode divergence as `.sheet` (decodes 30 /
            // enum 24): pull never round-trips through that integer, only
            // through the magic-comment subtype name "video".
            return .placeholder(.init(
                subtype: .video,
                blockToken: nil,
                title: "视频",
                summary: nil,
                url: ""
            ))
        default:
            // Unknown / not-yet-supported block_type (chat-card, equation,
            // grid / grid-column, OKR family, AddOns, JiraIssue,
            // SyncedBlock, …). Fall through to .divider so pull never
            // hard-fails on a Feishu schema addition. These should
            // surface as a converter warning long-term so the user
            // knows content was lost — currently just diagnosable
            // via debugLog.
            debugLog("[pull] unknown block_type \(blockType) → divider fallback")
            return .divider
        }
    }

    private static func decodeTextPayload(_ body: [String: Any]) -> FeishuBlock.TextPayload {
        let elements = body["elements"] as? [[String: Any]] ?? []
        return .init(elements: decodeElements(elements))
    }

    private static func decodeElements(_ raw: [[String: Any]]) -> [FeishuBlock.TextElement] {
        raw.compactMap { decodeElement($0) }
    }

    private static func decodeElement(_ raw: [String: Any]) -> FeishuBlock.TextElement? {
        guard let run = raw["text_run"] as? [String: Any],
              let content = run["content"] as? String else {
            return nil
        }
        let styleDict = run["text_element_style"] as? [String: Any] ?? [:]
        // Done.md's schema doesn't yet have a color/highlight mark, so
        // any Feishu-side text_color / background_color is lost on the
        // way in. We don't preserve the value (no schema slot to put it
        // in) but we DO flag the run so the converter can surface a
        // user-facing warning. See ADR-* / GH #59.
        let textColor = styleDict["text_color"]
        let backgroundColor = styleDict["background_color"]
        let hadStrippedColor =
            (textColor != nil && !(textColor is NSNull))
            || (backgroundColor != nil && !(backgroundColor is NSNull))
        let style = FeishuBlock.TextElementStyle(
            bold: (styleDict["bold"] as? Bool) ?? false,
            italic: (styleDict["italic"] as? Bool) ?? false,
            inlineCode: (styleDict["inline_code"] as? Bool) ?? false,
            strikethrough: (styleDict["strikethrough"] as? Bool) ?? false,
            link: (styleDict["link"] as? [String: Any])?["url"] as? String,
            hadStrippedFeishuColor: hadStrippedColor
        )
        return .textRun(.init(content: content, style: style))
    }
}

enum FeishuBlockEncodingError: Error, Equatable {
    case missingPageRoot
    case malformedEnvelope
}

/// Light-color palette mapping: Feishu's wire uses int codes 1-15
/// for callout background_color, but Done.md's TypeScript-friendly
/// string surface (FeishuCalloutType / converter / tests) uses
/// "light-blue", "light-green", etc. Encoder/decoder route through
/// this pair to keep the rest of the codebase string-typed.
///
/// Numbers cross-checked against feishu-mcp-pro's color-maps.js
/// LIGHT_COLORS table on 2026-05-30. Aliases (red ↔ light-red, etc.)
/// resolve to the same number; numbers map to the "light-*" form on
/// reverse to match the canonical name the rest of Done.md uses.
private let lightColorNames: [(String, Int)] = [
    ("light-red", 1),
    ("light-orange", 2),
    ("light-yellow", 3),
    ("light-green", 4),
    ("light-blue", 5),
    ("light-purple", 6),
    ("light-gray", 7),
    ("dark-gray", 8),
    // 9-15 reserved by Feishu but not currently mapped to any
    // canonical Done.md callout type; the encoder/decoder still
    // accept them on round-trip via the int.
]
private let lightNameToNumber: [String: Int] = {
    var m: [String: Int] = [:]
    for (name, num) in lightColorNames { m[name] = num }
    // Aliases — same number, alternate spellings users / Feishu UI
    // sometimes emit. light-* is the canonical form we write back.
    m["red"] = 1
    m["orange"] = 2
    m["yellow"] = 3
    m["green"] = 4
    m["blue"] = 5
    m["purple"] = 6
    m["light-grey"] = 7
    m["gray"] = 7
    m["grey"] = 7
    m["pale-gray"] = 7
    m["dark-grey"] = 8
    return m
}()
private let lightNumberToName: [Int: String] = Dictionary(
    uniqueKeysWithValues: lightColorNames.map { ($1, $0) }
)

func lightColorNumber(forName name: String) -> Int? {
    lightNameToNumber[name.lowercased()]
}

func lightColorName(forNumber num: Int) -> String? {
    lightNumberToName[num]
}
