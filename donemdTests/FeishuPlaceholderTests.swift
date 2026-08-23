import XCTest
@testable import donemd

/// Tests for the Feishu placeholder block parser + serializer (ADR-0007 /
/// issue #42).
///
/// Acceptance criteria covered:
///   - `<!-- feishu-placeholder ... -->` lands in `feishu_placeholder_block`,
///     not raw markdown block
///   - all 7 known fields parse; unknown fields preserved in original order
///   - missing required fields (type / block_id / title) → fall back
///     to raw markdown block (bytes survive)
///   - `url` is optional on disk (#89): omitted when derivable from
///     type + block_token, backfilled on parse; embed external urls kept
///   - serialize emits fields in canonical order; round-trip is byte-stable
final class FeishuPlaceholderTests: XCTestCase {

    // MARK: - Engine: parse

    func testParseFullPlaceholder() {
        let raw = """
        <!-- feishu-placeholder
        type: sheet
        block_id: doxbcXXX_blk001
        block_token: shtcnYYY
        title: Q2 OKR 进度表
        summary: 列：目标 / 责任人 / 进度 / 备注 · 共 12 行
        url: https://example.feishu.cn/sheets/shtcnYYY
        created_in_feishu_at: 2026-04-15T09:00:00+08:00
        -->
        """
        let parsed = FeishuPlaceholderEngine.parse(raw)
        XCTAssertEqual(parsed?.type, "sheet")
        XCTAssertEqual(parsed?.blockId, "doxbcXXX_blk001")
        XCTAssertEqual(parsed?.blockToken, "shtcnYYY")
        XCTAssertEqual(parsed?.title, "Q2 OKR 进度表")
        XCTAssertEqual(parsed?.summary, "列：目标 / 责任人 / 进度 / 备注 · 共 12 行")
        XCTAssertEqual(parsed?.url, "https://example.feishu.cn/sheets/shtcnYYY")
        XCTAssertEqual(parsed?.createdInFeishuAt, "2026-04-15T09:00:00+08:00")
        XCTAssertEqual(parsed?.unknownFields, [])
    }

    func testParseMinimalRequiredFieldsOnly() {
        let raw = """
        <!-- feishu-placeholder
        type: embed
        block_id: doxbcXXX_blk003
        title: 第三方系统嵌入
        url: https://example.com/foo
        -->
        """
        let parsed = FeishuPlaceholderEngine.parse(raw)
        XCTAssertEqual(parsed?.type, "embed")
        XCTAssertEqual(parsed?.blockId, "doxbcXXX_blk003")
        XCTAssertEqual(parsed?.title, "第三方系统嵌入")
        XCTAssertEqual(parsed?.url, "https://example.com/foo")
        XCTAssertNil(parsed?.blockToken)
        XCTAssertNil(parsed?.summary)
        XCTAssertNil(parsed?.createdInFeishuAt)
    }

    func testParseUnknownFieldsPreservedInOrder() {
        let raw = """
        <!-- feishu-placeholder
        type: sheet
        block_id: doxbcXXX_blk001
        title: Q2 OKR 进度表
        url: https://example.feishu.cn/sheets/shtcnYYY
        future_quota: 42
        future_owner: alice
        -->
        """
        let parsed = FeishuPlaceholderEngine.parse(raw)
        XCTAssertEqual(parsed?.unknownFields.count, 2)
        XCTAssertEqual(parsed?.unknownFields[0].key, "future_quota")
        XCTAssertEqual(parsed?.unknownFields[0].value, "42")
        XCTAssertEqual(parsed?.unknownFields[1].key, "future_owner")
        XCTAssertEqual(parsed?.unknownFields[1].value, "alice")
    }

    func testParseRejectsWhenNotPlaceholder() {
        let raw = """
        <!-- not a feishu placeholder
        type: sheet
        -->
        """
        XCTAssertNil(FeishuPlaceholderEngine.parse(raw))
    }

    func testParseRejectsWhenOpenerLineHasTrailingTokens() {
        // Single-line variant is explicitly disallowed (ADR-0007 §
        // "首尾分别独占一行").
        let raw = "<!-- feishu-placeholder type: sheet block_id: x title: y url: u -->"
        XCTAssertNil(FeishuPlaceholderEngine.parse(raw))
    }

    func testParseRejectsMissingRequiredField() {
        // Missing `block_id` — still required. type/title present but the
        // block reference is gone → nil → caller renders raw bytes.
        let raw = """
        <!-- feishu-placeholder
        type: sheet
        title: Q2 OKR
        url: https://x.feishu.cn/foo
        -->
        """
        XCTAssertNil(FeishuPlaceholderEngine.parse(raw))
    }

    func testParseBackfillsOmittedURLFromToken() {
        // #89: url line omitted, but type + block_token make it derivable.
        // Parse succeeds and backfills url = feishu://board/<token>.
        let raw = """
        <!-- feishu-placeholder
        type: board
        block_id: doxbcXXX_blk012
        block_token: bdcnAAA
        title: 架构图
        -->
        """
        let parsed = FeishuPlaceholderEngine.parse(raw)
        XCTAssertEqual(parsed?.type, "board")
        XCTAssertEqual(parsed?.blockToken, "bdcnAAA")
        XCTAssertEqual(parsed?.url, "feishu://board/bdcnAAA")
    }

    func testParseBackfillsAttachmentURLToFileSegment() {
        // attachment maps to the `file` url segment (not `attachment`).
        let raw = """
        <!-- feishu-placeholder
        type: attachment
        block_id: doxbcXXX_blk020
        block_token: fileTOK
        title: 季度报告.pdf
        -->
        """
        XCTAssertEqual(
            FeishuPlaceholderEngine.parse(raw)?.url,
            "feishu://file/fileTOK"
        )
    }

    func testParseOmittedURLWithNoTokenBackfillsEmpty() {
        // Not derivable (no block_token) and no url line → url = "".
        // Still a valid placeholder (type/block_id/title present).
        let raw = """
        <!-- feishu-placeholder
        type: embed
        block_id: doxbcXXX_blk003
        title: 第三方系统嵌入
        -->
        """
        let parsed = FeishuPlaceholderEngine.parse(raw)
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.url, "")
    }

    func testParseRejectsEmptyRequiredField() {
        // Empty `type` — present but empty.
        let raw = """
        <!-- feishu-placeholder
        type:
        block_id: doxbcXXX_blk001
        title: Q2 OKR
        url: https://x.feishu.cn/foo
        -->
        """
        XCTAssertNil(FeishuPlaceholderEngine.parse(raw))
    }

    func testParseRejectsLineWithoutColon() {
        let raw = """
        <!-- feishu-placeholder
        type: sheet
        block_id doxbcXXX_blk001
        title: Q2 OKR
        url: https://x.feishu.cn/foo
        -->
        """
        XCTAssertNil(FeishuPlaceholderEngine.parse(raw))
    }

    func testParseRejectsMissingCloser() {
        let raw = """
        <!-- feishu-placeholder
        type: sheet
        block_id: doxbcXXX_blk001
        title: Q2 OKR
        url: https://x.feishu.cn/foo
        """
        XCTAssertNil(FeishuPlaceholderEngine.parse(raw))
    }

    // MARK: - Engine: serialize

    func testSerializeFullPlaceholder() {
        let placeholder = FeishuPlaceholder(
            type: "sheet",
            blockId: "doxbcXXX_blk001",
            blockToken: "shtcnYYY",
            title: "Q2 OKR 进度表",
            summary: "列：目标 / 责任人 / 进度 / 备注 · 共 12 行",
            url: "https://example.feishu.cn/sheets/shtcnYYY",
            createdInFeishuAt: "2026-04-15T09:00:00+08:00"
        )
        let expected = """
        <!-- feishu-placeholder
        type: sheet
        block_id: doxbcXXX_blk001
        block_token: shtcnYYY
        title: Q2 OKR 进度表
        summary: 列：目标 / 责任人 / 进度 / 备注 · 共 12 行
        url: https://example.feishu.cn/sheets/shtcnYYY
        created_in_feishu_at: 2026-04-15T09:00:00+08:00
        -->
        """
        XCTAssertEqual(FeishuPlaceholderEngine.serialize(placeholder), expected)
    }

    func testSerializeOmitsOptionalFields() {
        let placeholder = FeishuPlaceholder(
            type: "embed",
            blockId: "doxbcXXX_blk003",
            title: "第三方系统嵌入",
            url: "https://example.com/foo"
        )
        let expected = """
        <!-- feishu-placeholder
        type: embed
        block_id: doxbcXXX_blk003
        title: 第三方系统嵌入
        url: https://example.com/foo
        -->
        """
        XCTAssertEqual(FeishuPlaceholderEngine.serialize(placeholder), expected)
    }

    func testSerializeUnknownFieldsAfterKnownInOrder() {
        let placeholder = FeishuPlaceholder(
            type: "sheet",
            blockId: "doxbcXXX_blk001",
            title: "Q2 OKR",
            url: "https://x.feishu.cn/foo",
            unknownFields: [
                UnknownPlaceholderField(key: "future_quota", value: "42"),
                UnknownPlaceholderField(key: "future_owner", value: "alice"),
            ]
        )
        let expected = """
        <!-- feishu-placeholder
        type: sheet
        block_id: doxbcXXX_blk001
        title: Q2 OKR
        url: https://x.feishu.cn/foo
        future_quota: 42
        future_owner: alice
        -->
        """
        XCTAssertEqual(FeishuPlaceholderEngine.serialize(placeholder), expected)
    }

    func testSerializeOmitsCanonicalURL() {
        // #89: url == feishu://<type>/<block_token> → the url line is dropped.
        let placeholder = FeishuPlaceholder(
            type: "video",
            blockId: "doxbcXXX_blk001",
            blockToken: "vidTOK",
            title: "demo.mp4",
            url: "feishu://video/vidTOK"
        )
        let expected = """
        <!-- feishu-placeholder
        type: video
        block_id: doxbcXXX_blk001
        block_token: vidTOK
        title: demo.mp4
        -->
        """
        XCTAssertEqual(FeishuPlaceholderEngine.serialize(placeholder), expected)
    }

    func testSerializeKeepsEmbedExternalURL() {
        // embed carries a non-derivable external link (no block_token) →
        // canonicalURL is nil → the url line is always written.
        let placeholder = FeishuPlaceholder(
            type: "embed",
            blockId: "doxbcXXX_blk003",
            title: "第三方系统嵌入",
            url: "https://grafana.example.com/d/abc"
        )
        XCTAssertTrue(
            FeishuPlaceholderEngine.serialize(placeholder)
                .contains("url: https://grafana.example.com/d/abc")
        )
    }

    func testSerializeKeepsNonCanonicalURL() {
        // Native type + token present, but url is a real http link (legacy
        // pull) rather than the feishu:// canonical → kept, never dropped.
        let placeholder = FeishuPlaceholder(
            type: "sheet",
            blockId: "doxbcXXX_blk001",
            blockToken: "shtcnYYY",
            title: "Q2 OKR",
            url: "https://example.feishu.cn/sheets/shtcnYYY"
        )
        XCTAssertTrue(
            FeishuPlaceholderEngine.serialize(placeholder)
                .contains("url: https://example.feishu.cn/sheets/shtcnYYY")
        )
    }

    // MARK: - canonicalURL

    func testCanonicalURLMapping() {
        XCTAssertEqual(FeishuPlaceholderEngine.canonicalURL(type: "board", blockToken: "t"), "feishu://board/t")
        XCTAssertEqual(FeishuPlaceholderEngine.canonicalURL(type: "sheet", blockToken: "t"), "feishu://sheet/t")
        XCTAssertEqual(FeishuPlaceholderEngine.canonicalURL(type: "bitable", blockToken: "t"), "feishu://bitable/t")
        XCTAssertEqual(FeishuPlaceholderEngine.canonicalURL(type: "mindnote", blockToken: "t"), "feishu://mindnote/t")
        XCTAssertEqual(FeishuPlaceholderEngine.canonicalURL(type: "video", blockToken: "t"), "feishu://video/t")
        XCTAssertEqual(FeishuPlaceholderEngine.canonicalURL(type: "attachment", blockToken: "t"), "feishu://file/t")
        // Non-derivable: embed, unknown type, or missing/empty token.
        XCTAssertNil(FeishuPlaceholderEngine.canonicalURL(type: "embed", blockToken: "t"))
        XCTAssertNil(FeishuPlaceholderEngine.canonicalURL(type: "board", blockToken: nil))
        XCTAssertNil(FeishuPlaceholderEngine.canonicalURL(type: "board", blockToken: ""))
    }

    // MARK: - Round-trip

    func testRoundTripCanonicalOmittedURLIsByteStable() {
        // #89: a source with no url line round-trips byte-stably at the
        // shorter form, and the derived url is available in memory.
        let raw = """
        <!-- feishu-placeholder
        type: bitable
        block_id: doxbcXXX_blk008
        block_token: bascnZZZ
        title: 任务跟踪表
        -->
        """
        guard let parsed = FeishuPlaceholderEngine.parse(raw) else {
            XCTFail("parse returned nil for valid input")
            return
        }
        XCTAssertEqual(parsed.url, "feishu://bitable/bascnZZZ")
        XCTAssertEqual(FeishuPlaceholderEngine.serialize(parsed), raw)
    }

    func testRoundTripEmbedExternalURLIsByteStable() {
        let raw = """
        <!-- feishu-placeholder
        type: embed
        block_id: doxbcXXX_blk003
        title: 第三方系统嵌入
        url: https://grafana.example.com/d/abc
        -->
        """
        guard let parsed = FeishuPlaceholderEngine.parse(raw) else {
            XCTFail("parse returned nil for valid input")
            return
        }
        XCTAssertEqual(FeishuPlaceholderEngine.serialize(parsed), raw)
    }

    func testRoundTripFullPlaceholderIsByteStable() {
        let raw = """
        <!-- feishu-placeholder
        type: bitable
        block_id: doxbcXXX_blk008
        block_token: bascnZZZ
        title: 任务跟踪表
        summary: 字段：负责人 / 状态 / 截止日 · 共 28 行
        url: https://example.feishu.cn/base/bascnZZZ
        created_in_feishu_at: 2026-03-01T14:30:00+08:00
        -->
        """
        guard let parsed = FeishuPlaceholderEngine.parse(raw) else {
            XCTFail("parse returned nil for valid input")
            return
        }
        XCTAssertEqual(FeishuPlaceholderEngine.serialize(parsed), raw)
    }

    func testRoundTripWithUnknownFieldsIsByteStable() {
        let raw = """
        <!-- feishu-placeholder
        type: board
        block_id: doxbcXXX_blk012
        title: 架构图
        url: https://example.feishu.cn/board/bdcnAAA
        future_collab_count: 7
        -->
        """
        guard let parsed = FeishuPlaceholderEngine.parse(raw) else {
            XCTFail("parse returned nil for valid input")
            return
        }
        XCTAssertEqual(FeishuPlaceholderEngine.serialize(parsed), raw)
    }

    // MARK: - End-to-end through MarkdownEngine

    func testMarkdownParseProducesPlaceholderNode() {
        let source = """
        前言段落。

        <!-- feishu-placeholder
        type: sheet
        block_id: doxbcXXX_blk001
        title: Q2 OKR 进度表
        url: https://example.feishu.cn/sheets/shtcnYYY
        -->

        后续段落。
        """
        let body = MarkdownEngine.parse(markdown: source)
        let blocks = body.content ?? []
        XCTAssertEqual(blocks.count, 3)
        XCTAssertEqual(blocks[0].type, "paragraph")
        XCTAssertEqual(blocks[1].type, "feishu_placeholder_block")
        XCTAssertEqual(blocks[2].type, "paragraph")

        let attrs = blocks[1].attrs ?? [:]
        XCTAssertEqual(attrs["type"], .string("sheet"))
        XCTAssertEqual(attrs["block_id"], .string("doxbcXXX_blk001"))
        XCTAssertEqual(attrs["title"], .string("Q2 OKR 进度表"))
        XCTAssertEqual(attrs["url"], .string("https://example.feishu.cn/sheets/shtcnYYY"))
        XCTAssertNil(attrs["block_token"])
        XCTAssertNil(attrs["summary"])
    }

    func testCorruptPlaceholderFallsBackToRawBlock() {
        // Missing required `block_id` — parser returns nil, so the bytes
        // round-trip through the raw markdown block path instead of being
        // lost. (url is no longer required as of #89; block_id still is.)
        let source = """
        <!-- feishu-placeholder
        type: sheet
        title: 没有 block_id 的占位块
        url: https://x.feishu.cn/foo
        -->
        """
        let body = MarkdownEngine.parse(markdown: source)
        let blocks = body.content ?? []
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0].type, "raw_markdown_block")
    }

    func testMarkdownParseBackfillsURLAttrWhenOmitted() {
        // #89: a placeholder written WITHOUT the url line still produces a
        // feishu_placeholder_block whose attrs.url is backfilled to the
        // canonical form — so the web NodeView's open button keeps working.
        let source = """
        <!-- feishu-placeholder
        type: video
        block_id: doxbcXXX_blk001
        block_token: vidTOK
        title: demo.mp4
        -->
        """
        let body = MarkdownEngine.parse(markdown: source)
        let blocks = body.content ?? []
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0].type, "feishu_placeholder_block")
        XCTAssertEqual(blocks[0].attrs?["url"], .string("feishu://video/vidTOK"))
    }

    func testNonPlaceholderHTMLCommentStillRoutesToRawBlock() {
        // Plain HTML comments (anything not starting with our magic word)
        // continue to follow the original raw_markdown_block path.
        let source = """
        <!-- TODO revisit this section -->
        """
        let body = MarkdownEngine.parse(markdown: source)
        let blocks = body.content ?? []
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0].type, "raw_markdown_block")
    }

    func testFullDocumentRoundTripPreservesPlaceholder() {
        let source = """
        # 标题

        <!-- feishu-placeholder
        type: sheet
        block_id: doxbcXXX_blk001
        title: Q2 OKR 进度表
        url: https://example.feishu.cn/sheets/shtcnYYY
        -->

        正文段落。
        """
        let body = MarkdownEngine.parse(markdown: source)
        let serialized = MarkdownEngine.serialize(document: body)
        // Serializer adds a trailing newline (canonical form); compare the
        // body content rather than exact equality to source spacing.
        let expected = """
        # 标题

        <!-- feishu-placeholder
        type: sheet
        block_id: doxbcXXX_blk001
        title: Q2 OKR 进度表
        url: https://example.feishu.cn/sheets/shtcnYYY
        -->

        正文段落。

        """
        XCTAssertEqual(serialized, expected)
    }

    func testUnknownFieldsRoundTripThroughTiptapAttrs() {
        let source = """
        <!-- feishu-placeholder
        type: sheet
        block_id: doxbcXXX_blk001
        title: Q2 OKR
        url: https://x.feishu.cn/foo
        future_quota: 42
        -->
        """
        let body = MarkdownEngine.parse(markdown: source)
        let serialized = MarkdownEngine.serialize(document: body)
        XCTAssertTrue(serialized.contains("future_quota: 42"))
        // Order: known fields first, unknown after.
        let typeIdx = serialized.range(of: "type: sheet")!.lowerBound
        let urlIdx = serialized.range(of: "url: https://x.feishu.cn/foo")!.lowerBound
        let unknownIdx = serialized.range(of: "future_quota: 42")!.lowerBound
        XCTAssertLessThan(typeIdx, urlIdx)
        XCTAssertLessThan(urlIdx, unknownIdx)
    }
}
