import XCTest
@testable import donemd

/// Wire-shape regression tests for `FeishuBlockEncoder.encodeDescendantBody`.
///
/// The Feishu strict validator returns code 1770001 ("invalid param")
/// without telling us which key is wrong. Real-device push of a
/// document containing a table block surfaced exactly this — the
/// bug was: top-level descendants in the body had a `parent_id`
/// pointing at the converter's synthetic page id ("blk_000001"),
/// which doesn't exist on the Feishu side. The endpoint already
/// receives the real parent block id as a path param, so the body's
/// root-level parent_id is redundant; nested descendants (table_cell
/// → text, etc.) keep their parent_id since those references are
/// internal to the descendants array.
final class FeishuBlockEncoderTests: XCTestCase {

    /// Top-level descendants must NOT carry a `parent_id` field —
    /// that's what triggered the 1770001 on real-device push.
    func testTopLevelDescendantsHaveNoParentId() throws {
        let blocks: [FeishuBlock] = [
            FeishuBlock(
                blockId: "blk_001", parentId: nil,
                children: ["blk_002"],
                payload: .page(.init())
            ),
            FeishuBlock(
                blockId: "blk_002", parentId: "blk_001",
                children: nil,
                payload: .text(.init(elements: [.textRun(.init(content: "x"))]))
            ),
        ]
        let body = try FeishuBlockEncoder.encodeDescendantBody(from: blocks)
        let descendants = try XCTUnwrap(body["descendants"] as? [[String: Any]])
        XCTAssertEqual(descendants.count, 1)
        XCTAssertNil(descendants[0]["parent_id"],
            "top-level descendant must have parent_id stripped — Feishu validator " +
            "rejects bodies whose root parent_id doesn't match the path param")
    }

    /// Nested descendants (table_cell pointing at its table parent,
    /// text inside table_cell) must KEEP their `parent_id` because
    /// the validator checks consistency within the descendants array.
    func testNestedDescendantsKeepParentId() throws {
        let blocks: [FeishuBlock] = [
            FeishuBlock(
                blockId: "blk_001", parentId: nil,
                children: ["blk_table"],
                payload: .page(.init())
            ),
            FeishuBlock(
                blockId: "blk_table", parentId: "blk_001",
                children: ["blk_cell"],
                payload: .table(.init(rowSize: 1, columnSize: 1))
            ),
            FeishuBlock(
                blockId: "blk_cell", parentId: "blk_table",
                children: ["blk_text"],
                payload: .tableCell
            ),
            FeishuBlock(
                blockId: "blk_text", parentId: "blk_cell",
                children: nil,
                payload: .text(.init(elements: [.textRun(.init(content: "x"))]))
            ),
        ]
        let body = try FeishuBlockEncoder.encodeDescendantBody(from: blocks)
        let descendants = try XCTUnwrap(body["descendants"] as? [[String: Any]])
        let byId = Dictionary(uniqueKeysWithValues: descendants.compactMap { env -> (String, [String: Any])? in
            guard let id = env["block_id"] as? String else { return nil }
            return (id, env)
        })

        // Top-level table: parent_id stripped.
        XCTAssertNil(byId["blk_table"]?["parent_id"],
            "table is a top-level descendant — parent_id stripped")

        // Nested cell: parent_id == "blk_table" (internal to descendants).
        XCTAssertEqual(byId["blk_cell"]?["parent_id"] as? String, "blk_table",
            "table_cell points at its in-body table parent")

        // Nested text inside cell: parent_id == "blk_cell".
        XCTAssertEqual(byId["blk_text"]?["parent_id"] as? String, "blk_cell",
            "text in cell points at its in-body cell parent")
    }

    /// children_id list comes from the page block's children, in
    /// document order. Multiple top-level blocks all get parent_id
    /// stripped, not just the first.
    func testAllTopLevelDescendantsHaveParentIdStripped() throws {
        let blocks: [FeishuBlock] = [
            FeishuBlock(
                blockId: "blk_001", parentId: nil,
                children: ["blk_a", "blk_b", "blk_c"],
                payload: .page(.init())
            ),
            FeishuBlock(
                blockId: "blk_a", parentId: "blk_001", children: nil,
                payload: .text(.init(elements: [.textRun(.init(content: "a"))]))
            ),
            FeishuBlock(
                blockId: "blk_b", parentId: "blk_001", children: nil,
                payload: .heading(level: 1, .init(elements: [.textRun(.init(content: "b"))]))
            ),
            FeishuBlock(
                blockId: "blk_c", parentId: "blk_001", children: nil,
                payload: .divider
            ),
        ]
        let body = try FeishuBlockEncoder.encodeDescendantBody(from: blocks)
        let descendants = try XCTUnwrap(body["descendants"] as? [[String: Any]])
        for env in descendants {
            XCTAssertNil(env["parent_id"],
                "all top-level descendants strip parent_id — got \(env["block_id"] ?? "?") with parent_id")
        }

        let childrenId = try XCTUnwrap(body["children_id"] as? [String])
        XCTAssertEqual(childrenId, ["blk_a", "blk_b", "blk_c"])
    }

    /// `index` parameter round-trips. -1 means append; non-negative
    /// is an explicit insert position the segmented push uses.
    func testIndexRoundTrips() throws {
        let blocks: [FeishuBlock] = [
            FeishuBlock(
                blockId: "blk_001", parentId: nil,
                children: ["blk_a"],
                payload: .page(.init())
            ),
            FeishuBlock(
                blockId: "blk_a", parentId: "blk_001", children: nil,
                payload: .text(.init(elements: [.textRun(.init(content: "x"))]))
            ),
        ]
        let appendBody = try FeishuBlockEncoder.encodeDescendantBody(from: blocks)
        XCTAssertEqual(appendBody["index"] as? Int, -1, "default = append")

        let insertBody = try FeishuBlockEncoder.encodeDescendantBody(from: blocks, index: 3)
        XCTAssertEqual(insertBody["index"] as? Int, 3)
    }

    /// Empty text payload (e.g. a table_cell with no content) must
    /// render with at least one empty-content textRun, NOT an empty
    /// elements array. Real-device push of a document with empty
    /// table cells hit 1770001 because the body contained
    /// "text":{"elements":[]} — the strict validator rejects that.
    func testEmptyTextPayloadEncodesEmptyTextRunNotEmptyArray() throws {
        let blocks: [FeishuBlock] = [
            FeishuBlock(
                blockId: "blk_001", parentId: nil,
                children: ["blk_empty"],
                payload: .page(.init())
            ),
            FeishuBlock(
                blockId: "blk_empty", parentId: "blk_001", children: nil,
                payload: .text(.init(elements: []))
            ),
        ]
        let body = try FeishuBlockEncoder.encodeDescendantBody(from: blocks)
        let descendants = try XCTUnwrap(body["descendants"] as? [[String: Any]])
        let textPayload = try XCTUnwrap(descendants[0]["text"] as? [String: Any])
        let elements = try XCTUnwrap(textPayload["elements"] as? [[String: Any]])
        XCTAssertEqual(elements.count, 1,
            "empty text payload must encode as a single empty-content textRun")
        let textRun = try XCTUnwrap(elements[0]["text_run"] as? [String: Any])
        XCTAssertEqual(textRun["content"] as? String, "",
            "the placeholder textRun's content is the empty string")
    }

    /// Empty cells in a table — direct regression for the
    /// real-device 1770001 case.
    func testEmptyTableCellTextEncodesNonEmptyElementsArray() throws {
        let blocks: [FeishuBlock] = [
            FeishuBlock(
                blockId: "blk_001", parentId: nil,
                children: ["blk_table"],
                payload: .page(.init())
            ),
            FeishuBlock(
                blockId: "blk_table", parentId: "blk_001",
                children: ["blk_cell"],
                payload: .table(.init(rowSize: 1, columnSize: 1))
            ),
            FeishuBlock(
                blockId: "blk_cell", parentId: "blk_table",
                children: ["blk_emptyText"],
                payload: .tableCell
            ),
            FeishuBlock(
                blockId: "blk_emptyText", parentId: "blk_cell",
                children: nil,
                payload: .text(.init(elements: []))
            ),
        ]
        let body = try FeishuBlockEncoder.encodeDescendantBody(from: blocks)
        let descendants = try XCTUnwrap(body["descendants"] as? [[String: Any]])
        let byId = Dictionary(uniqueKeysWithValues: descendants.compactMap { env -> (String, [String: Any])? in
            guard let id = env["block_id"] as? String else { return nil }
            return (id, env)
        })
        let textPayload = try XCTUnwrap(byId["blk_emptyText"]?["text"] as? [String: Any])
        let elements = try XCTUnwrap(textPayload["elements"] as? [[String: Any]])
        XCTAssertFalse(elements.isEmpty,
            "empty table cell text must NOT serialize as elements:[] — Feishu rejects with 1770001")
    }

    // MARK: - callout color round-trip (real-device 99992402)

    /// Push body must encode callout.background_color as the int 1-15
    /// flavor Feishu's wire validator requires. Sending the
    /// human-readable "light-blue" string returned 99992402
    /// "field validation failed" on real-device 2026-05-30.
    func testCalloutBackgroundColorEncodesAsInt() throws {
        let blocks: [FeishuBlock] = [
            FeishuBlock(
                blockId: "p", parentId: nil, children: ["c1"],
                payload: .page(.init())
            ),
            FeishuBlock(
                blockId: "c1", parentId: "p", children: nil,
                payload: .callout(.init(emoji: "💡", backgroundColor: "light-blue"))
            ),
        ]
        let body = try FeishuBlockEncoder.encodeDescendantBody(from: blocks)
        let descendants = try XCTUnwrap(body["descendants"] as? [[String: Any]])
        let calloutPayload = try XCTUnwrap(descendants[0]["callout"] as? [String: Any])
        XCTAssertEqual(calloutPayload["background_color"] as? Int, 5,
            "light-blue must encode as 5; Feishu wire returns 99992402 for the string form")
        XCTAssertEqual(calloutPayload["emoji_id"] as? String, "💡")
    }

    /// Pull side: int 1-15 from Feishu decodes back to the canonical
    /// "light-*" string Done.md uses internally (FeishuCalloutType
    /// dispatches on the string form).
    func testCalloutBackgroundColorDecodesFromInt() throws {
        let dict: [String: Any] = [
            "block_id": "c1",
            "block_type": 19,
            "parent_id": "p",
            "callout": [
                "emoji_id": "✨",
                "background_color": 4,
            ],
        ]
        let block = try FeishuBlockEncoder.decodeBlockEnvelope(dict)
        guard case .callout(let payload) = block.payload else {
            XCTFail("expected .callout, got \(block.payload)"); return
        }
        XCTAssertEqual(payload.backgroundColor, "light-green",
            "int 4 must decode to canonical light-green name")
        XCTAssertEqual(payload.emoji, "✨")
    }

    /// Round-trip: canonical name → int → canonical name. Pin all 5
    /// colors Done.md's FeishuCalloutType cares about.
    func testCalloutColorRoundTripsAcrossAllCanonicalColors() throws {
        let canonical: [(name: String, num: Int)] = [
            ("light-red", 1),
            ("light-orange", 2),
            ("light-yellow", 3),
            ("light-green", 4),
            ("light-blue", 5),
            ("light-purple", 6),
            ("light-gray", 7),
        ]
        for (name, expected) in canonical {
            let blocks: [FeishuBlock] = [
                FeishuBlock(blockId: "p", parentId: nil, children: ["c"], payload: .page(.init())),
                FeishuBlock(blockId: "c", parentId: "p", children: nil,
                            payload: .callout(.init(emoji: nil, backgroundColor: name))),
            ]
            let body = try FeishuBlockEncoder.encodeDescendantBody(from: blocks)
            let descendants = try XCTUnwrap(body["descendants"] as? [[String: Any]])
            let payload = try XCTUnwrap(descendants[0]["callout"] as? [String: Any])
            XCTAssertEqual(payload["background_color"] as? Int, expected,
                "\(name) must encode as \(expected)")
        }
    }

    // MARK: - placeholder block decoding (#19)

    /// Real-world wire shape for a Feishu whiteboard (block_type 43)
    /// — captured via mcp doc_list_blocks against a live document.
    /// decodeBlockEnvelope must surface this as `.placeholder(.board)`,
    /// NOT as `.divider` (which is what the v2-9a-step1' default case
    /// did, silently dropping every whiteboard).
    func testDecodeBoardBlockProducesBoardPlaceholder() throws {
        let dict: [String: Any] = [
            "block_id": "doxc_BOARD",
            "block_type": 43,
            "parent_id": "page_X",
            "board": ["token": "BOARD_TOKEN_xyz"],
        ]
        let block = try FeishuBlockEncoder.decodeBlockEnvelope(dict)
        guard case .placeholder(let payload) = block.payload else {
            XCTFail("expected .placeholder, got \(block.payload)")
            return
        }
        XCTAssertEqual(payload.subtype, .board)
        XCTAssertEqual(payload.blockToken, "BOARD_TOKEN_xyz")
        XCTAssertEqual(payload.title, "画板",
            "default title surfaces a localized hint when Feishu side has none")
        XCTAssertEqual(payload.url, "feishu://board/BOARD_TOKEN_xyz")
    }

    /// Sheet block (block_type 30 — note this differs from the legacy
    /// `PlaceholderSubtype.sheet.blockType` value 24, which is
    /// permanent on the push side until a coordinated ADR pass).
    func testDecodeSheetBlockProducesSheetPlaceholder() throws {
        let dict: [String: Any] = [
            "block_id": "doxc_SHEET",
            "block_type": 30,
            "parent_id": "page_X",
            "sheet": [
                "token": "SHEET_TOKEN_xyz",
                "row_size": 10,
                "column_size": 5,
            ],
        ]
        let block = try FeishuBlockEncoder.decodeBlockEnvelope(dict)
        guard case .placeholder(let payload) = block.payload else {
            XCTFail("expected .placeholder, got \(block.payload)")
            return
        }
        XCTAssertEqual(payload.subtype, .sheet)
        XCTAssertEqual(payload.blockToken, "SHEET_TOKEN_xyz")
        XCTAssertEqual(payload.summary, "10 × 5",
            "row × column dimensions surface as the placeholder summary")
    }

    /// Bitable block (block_type 18) — multi-dimensional table.
    func testDecodeBitableBlockProducesBitablePlaceholder() throws {
        let dict: [String: Any] = [
            "block_id": "doxc_BITABLE",
            "block_type": 18,
            "parent_id": "page_X",
            "bitable": [
                "token": "BITABLE_TOKEN",
                "view_type": 2,  // kanban
            ],
        ]
        let block = try FeishuBlockEncoder.decodeBlockEnvelope(dict)
        guard case .placeholder(let payload) = block.payload else {
            XCTFail("got \(block.payload)")
            return
        }
        XCTAssertEqual(payload.subtype, .bitable)
        XCTAssertEqual(payload.blockToken, "BITABLE_TOKEN")
        XCTAssertEqual(payload.summary, "kanban",
            "view_type 2 surfaces as 'kanban' in the placeholder summary")
    }

    /// Mindnote block (block_type 29).
    func testDecodeMindnoteBlockProducesMindnotePlaceholder() throws {
        let dict: [String: Any] = [
            "block_id": "doxc_MINDNOTE",
            "block_type": 29,
            "parent_id": "page_X",
            "mindnote": ["token": "MINDNOTE_TOKEN"],
        ]
        let block = try FeishuBlockEncoder.decodeBlockEnvelope(dict)
        guard case .placeholder(let payload) = block.payload else {
            XCTFail("got \(block.payload)")
            return
        }
        XCTAssertEqual(payload.subtype, .mindnote)
        XCTAssertEqual(payload.blockToken, "MINDNOTE_TOKEN")
    }

    /// Iframe / embed block (block_type 26). The url lives nested
    /// under iframe.component.url, not at top level.
    func testDecodeIframeBlockProducesEmbedPlaceholder() throws {
        let dict: [String: Any] = [
            "block_id": "doxc_IFRAME",
            "block_type": 26,
            "parent_id": "page_X",
            "iframe": [
                "component": [
                    "url": "https://example.com/embed",
                    "iframe_type": 1,
                ],
            ],
        ]
        let block = try FeishuBlockEncoder.decodeBlockEnvelope(dict)
        guard case .placeholder(let payload) = block.payload else {
            XCTFail("got \(block.payload)")
            return
        }
        XCTAssertEqual(payload.subtype, .embed)
        XCTAssertEqual(payload.url, "https://example.com/embed")
    }

    /// File block (block_type 23). Title comes from the file's `name`
    /// when present, otherwise localized fallback.
    func testDecodeFileBlockProducesAttachmentPlaceholder() throws {
        let dict: [String: Any] = [
            "block_id": "doxc_FILE",
            "block_type": 23,
            "parent_id": "page_X",
            "file": [
                "token": "FILE_TOKEN",
                "name": "report.pdf",
            ],
        ]
        let block = try FeishuBlockEncoder.decodeBlockEnvelope(dict)
        guard case .placeholder(let payload) = block.payload else {
            XCTFail("got \(block.payload)")
            return
        }
        XCTAssertEqual(payload.subtype, .attachment)
        XCTAssertEqual(payload.blockToken, "FILE_TOKEN")
        XCTAssertEqual(payload.title, "report.pdf",
            "file name surfaces as the placeholder title when present")
    }

    /// View block (block_type 33) — Feishu's inline-media container that
    /// wraps an uploaded video's `file` child. Decode surfaces a *bare*
    /// `.video` placeholder (token + filename are absorbed later by the
    /// converter, which can resolve the child via `byId`). Before this
    /// case existed, block_type 33 fell through to `.divider` and the
    /// video was silently lost (violating ADR-0007 「不丢信息」).
    func testDecodeViewBlockProducesBareVideoPlaceholder() throws {
        let dict: [String: Any] = [
            "block_id": "doxc_VIEW",
            "block_type": 33,
            "parent_id": "page_X",
            "view": ["view_type": 2],
            "children": ["doxc_FILE_child"],
        ]
        let block = try FeishuBlockEncoder.decodeBlockEnvelope(dict)
        guard case .placeholder(let payload) = block.payload else {
            XCTFail("expected .placeholder(.video), got \(block.payload)")
            return
        }
        XCTAssertEqual(payload.subtype, .video)
        XCTAssertNil(payload.blockToken,
            "token lives on the child file block — the converter absorbs it")
        XCTAssertEqual(payload.title, "视频")
    }

    /// End-to-end integration on the EXACT wire shapes pulled live from
    /// docx JS04dEQuRoAd4DxBtplcYwWWn4v (2026-08-16): a page (block_type 1)
    /// whose child is a view (33, view_type 2) whose child is a file (23)
    /// carrying the real *.mp4 token + name. Routes the raw dicts through
    /// the SAME two production steps a pull uses — `decodeBlockEnvelope`
    /// per block, then `toMarkdownWithWarnings` on the collected array —
    /// and asserts the video survives as a `type: video` magic comment.
    /// This closes the gap the hand-built payload tests leave open: it
    /// proves the real 33→23 decode + tree-assembly + absorb + serialize
    /// chain emits the placeholder, so any remaining "video is empty"
    /// report is a stale-binary or render-layer issue, not lost data.
    func testRealWireVideoSurvivesFullPullConversion() throws {
        let page: [String: Any] = [
            "block_id": "JS04dEQuRoAd4DxBtplcYwWWn4v",
            "block_type": 1,
            "children": ["UZC5dlS3nojQ2XxkKFfcDF0wnVf"],
            "page": ["elements": []],
        ]
        let view: [String: Any] = [
            "block_id": "UZC5dlS3nojQ2XxkKFfcDF0wnVf",
            "block_type": 33,
            "parent_id": "JS04dEQuRoAd4DxBtplcYwWWn4v",
            "view": ["view_type": 2],
            "children": ["WPTld9a5joj1bPxGa5WcD64fnbh"],
        ]
        let file: [String: Any] = [
            "block_id": "WPTld9a5joj1bPxGa5WcD64fnbh",
            "block_type": 23,
            "parent_id": "UZC5dlS3nojQ2XxkKFfcDF0wnVf",
            "file": [
                "name": "20260728-172558.mp4",
                "token": "MzMvbKV31opGhoxYpgMcbN98nSg",
            ],
        ]
        let blocks = try [page, view, file].map {
            try FeishuBlockEncoder.decodeBlockEnvelope($0)
        }
        let result = FeishuStructuralConverter.toMarkdownWithWarnings(blocks)
        XCTAssertTrue(result.value.contains("type: video"),
            "pulled markdown must carry the video placeholder\n---\n\(result.value)")
        XCTAssertTrue(result.value.contains("block_token: MzMvbKV31opGhoxYpgMcbN98nSg"),
            "the video's real token is lifted from the absorbed file child")
        XCTAssertTrue(result.value.contains("title: 20260728-172558.mp4"),
            "card title = the uploaded file's name")
        XCTAssertFalse(result.warnings.contains {
            if case .nestedContentDroppedInPlaceholder = $0 { return true }
            return false
        }, "the file child is absorbed, not dropped — no false loss warning")
    }

    /// Unknown block_type still falls through to .divider (safety net
    /// — no hard failure on a Feishu schema addition like OKR / Synced).
    func testDecodeTrulyUnknownBlockTypeFallsThroughToDivider() throws {
        let dict: [String: Any] = [
            "block_id": "doxc_FUTURE",
            "block_type": 999,  // not in any known mapping
            "parent_id": "page_X",
        ]
        let block = try FeishuBlockEncoder.decodeBlockEnvelope(dict)
        guard case .divider = block.payload else {
            XCTFail("expected .divider fallback for unknown block_type, got \(block.payload)")
            return
        }
    }

    /// Quote container: the synthesized text child has the quote's
    /// id as parent — it's nested, never top-level. Make sure that
    /// internal parent_id survives.
    func testQuoteContainerNestedTextKeepsParentId() throws {
        let blocks: [FeishuBlock] = [
            FeishuBlock(
                blockId: "blk_001", parentId: nil,
                children: ["blk_quote"],
                payload: .page(.init())
            ),
            FeishuBlock(
                blockId: "blk_quote", parentId: "blk_001",
                children: nil,
                payload: .quote(.init(elements: [.textRun(.init(content: "q"))]))
            ),
        ]
        let body = try FeishuBlockEncoder.encodeDescendantBody(from: blocks)
        let descendants = try XCTUnwrap(body["descendants"] as? [[String: Any]])
        let byId = Dictionary(uniqueKeysWithValues: descendants.compactMap { env -> (String, [String: Any])? in
            guard let id = env["block_id"] as? String else { return nil }
            return (id, env)
        })

        // Top-level quote_container: parent_id stripped.
        XCTAssertNil(byId["blk_quote"]?["parent_id"],
            "quote_container is top-level — parent_id stripped")

        // Synthesized text child (id "blk_quote_qtxt"): parent_id kept.
        XCTAssertEqual(
            byId["blk_quote_qtxt"]?["parent_id"] as? String, "blk_quote",
            "synthesized quote text child points at its quote container")
    }
}
