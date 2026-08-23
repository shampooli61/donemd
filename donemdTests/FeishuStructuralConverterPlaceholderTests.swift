import XCTest
@testable import donemd

/// v2-4c coverage for the placeholder bridge — the part of
/// `FeishuStructuralConverter` that ferries the seven Feishu-native block
/// types (sheet / mindnote / board / bitable / attachment / video / embed)
/// across the Markdown ↔ Feishu boundary as opaque references (ADR-0007).
///
/// Acceptance criteria covered:
///   - all seven `PlaceholderSubtype` values round-trip through Markdown
///   - all seven magic-comment fields (4 required + 3 optional) survive
///   - `unknown_fields` are preserved in original order
///   - nested children inside a placeholder block emit a
///     `nestedContentDroppedInPlaceholder` warning via `toMarkdownWithWarnings`
///   - `preserveExistingReference` returns the canonical
///     `{block_id, block_type, _done_md_directive}` shape and `nil` for
///     non-placeholder blocks
///   - byte-stable round-trip with the v2-3 `FeishuPlaceholderEngine` parser
final class FeishuStructuralConverterPlaceholderTests: XCTestCase {

    // MARK: helpers

    private func body(_ blocks: [FeishuBlock]) -> [FeishuBlock] {
        blocks.filter { if case .page = $0.payload { return false } else { return true } }
    }

    private func payloadShapes(_ blocks: [FeishuBlock]) -> [FeishuBlock.Payload] {
        blocks.map(\.payload)
    }

    private func page(children: [String]) -> FeishuBlock {
        FeishuBlock(
            blockId: "p", parentId: nil, children: children,
            payload: .page(.init())
        )
    }

    /// Build a hand-crafted placeholder block. Defaults match the smallest
    /// legal payload (4 required fields).
    private func placeholderBlock(
        id: String,
        subtype: FeishuBlock.PlaceholderSubtype,
        title: String,
        url: String,
        blockToken: String? = nil,
        summary: String? = nil,
        createdInFeishuAt: String? = nil,
        unknownFields: [UnknownPlaceholderField] = [],
        children: [String]? = nil
    ) -> FeishuBlock {
        FeishuBlock(
            blockId: id,
            parentId: "p",
            children: children,
            payload: .placeholder(.init(
                subtype: subtype,
                blockToken: blockToken,
                title: title,
                summary: summary,
                url: url,
                createdInFeishuAt: createdInFeishuAt,
                unknownFields: unknownFields
            ))
        )
    }

    // MARK: blocks → Markdown

    func testToMarkdownEmitsMagicCommentForSheet() {
        let id = "doxbcXXX_blk001"
        let blocks: [FeishuBlock] = [
            page(children: [id]),
            placeholderBlock(
                id: id,
                subtype: .sheet,
                title: "Q2 OKR 进度表",
                url: "https://example.feishu.cn/sheets/shtcnYYY",
                blockToken: "shtcnYYY",
                summary: "列：目标 / 责任人 / 进度 / 备注 · 共 12 行",
                createdInFeishuAt: "2026-04-15T09:00:00+08:00"
            ),
        ]
        let md = FeishuStructuralConverter.toMarkdown(blocks)
        XCTAssertTrue(md.contains("<!-- feishu-placeholder"))
        XCTAssertTrue(md.contains("type: sheet"))
        XCTAssertTrue(md.contains("block_id: doxbcXXX_blk001"))
        XCTAssertTrue(md.contains("block_token: shtcnYYY"))
        XCTAssertTrue(md.contains("title: Q2 OKR 进度表"))
        XCTAssertTrue(md.contains("summary: 列：目标 / 责任人 / 进度 / 备注 · 共 12 行"))
        XCTAssertTrue(md.contains("url: https://example.feishu.cn/sheets/shtcnYYY"))
        XCTAssertTrue(md.contains("created_in_feishu_at: 2026-04-15T09:00:00+08:00"))
        XCTAssertTrue(md.contains("-->"))
    }

    func testToMarkdownEmitsMinimalMagicCommentWhenOptionalsMissing() {
        let id = "doxbcXXX_blk003"
        let blocks: [FeishuBlock] = [
            page(children: [id]),
            placeholderBlock(
                id: id,
                subtype: .embed,
                title: "第三方系统嵌入",
                url: "https://example.com/foo"
            ),
        ]
        let md = FeishuStructuralConverter.toMarkdown(blocks)
        XCTAssertTrue(md.contains("type: embed"))
        XCTAssertTrue(md.contains("block_id: doxbcXXX_blk003"))
        XCTAssertTrue(md.contains("title: 第三方系统嵌入"))
        XCTAssertTrue(md.contains("url: https://example.com/foo"))
        XCTAssertFalse(md.contains("block_token:"))
        XCTAssertFalse(md.contains("summary:"))
        XCTAssertFalse(md.contains("created_in_feishu_at:"))
    }

    // MARK: Markdown → blocks

    func testToFeishuBlocksParsesAllSevenSubtypes() {
        // One placeholder per subtype, paired in document order. Each row
        // exercises that the subtype string round-trips into the typed
        // `PlaceholderSubtype` enum the converter holds in payload.
        let cases: [(FeishuBlock.PlaceholderSubtype, String)] = [
            (.attachment, "attachment"),
            (.sheet, "sheet"),
            (.mindnote, "mindnote"),
            (.video, "video"),
            (.bitable, "bitable"),
            (.embed, "embed"),
            (.board, "board"),
        ]
        for (subtype, raw) in cases {
            let md = """
            <!-- feishu-placeholder
            type: \(raw)
            block_id: doxbcXXX_blk_\(raw)
            title: \(raw) sample
            url: https://example.feishu.cn/\(raw)/abc
            -->
            """
            let blocks = body(FeishuStructuralConverter.toFeishuBlocks(md))
            XCTAssertEqual(blocks.count, 1, "subtype \(raw) emitted \(blocks.count) blocks")
            guard case .placeholder(let payload) = blocks[0].payload else {
                XCTFail("subtype \(raw) did not produce .placeholder payload, got \(blocks[0].payload)")
                continue
            }
            XCTAssertEqual(payload.subtype, subtype)
            XCTAssertEqual(blocks[0].blockId, "doxbcXXX_blk_\(raw)")
            XCTAssertEqual(payload.title, "\(raw) sample")
            XCTAssertEqual(payload.url, "https://example.feishu.cn/\(raw)/abc")
        }
    }

    func testToFeishuBlocksPreservesAllSevenFields() {
        let md = """
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
        let blocks = body(FeishuStructuralConverter.toFeishuBlocks(md))
        XCTAssertEqual(blocks.count, 1)
        guard case .placeholder(let payload) = blocks[0].payload else {
            return XCTFail("expected placeholder payload, got \(blocks[0].payload)")
        }
        XCTAssertEqual(blocks[0].blockId, "doxbcXXX_blk008")
        XCTAssertEqual(payload.subtype, .bitable)
        XCTAssertEqual(payload.blockToken, "bascnZZZ")
        XCTAssertEqual(payload.title, "任务跟踪表")
        XCTAssertEqual(payload.summary, "字段：负责人 / 状态 / 截止日 · 共 28 行")
        XCTAssertEqual(payload.url, "https://example.feishu.cn/base/bascnZZZ")
        XCTAssertEqual(payload.createdInFeishuAt, "2026-03-01T14:30:00+08:00")
        XCTAssertEqual(payload.unknownFields, [])
    }

    func testUnknownFieldsArePreservedInOrder() {
        let md = """
        <!-- feishu-placeholder
        type: sheet
        block_id: doxbcXXX_blk001
        title: Q2 OKR
        url: https://x.feishu.cn/foo
        future_quota: 42
        future_owner: alice
        -->
        """
        let blocks = body(FeishuStructuralConverter.toFeishuBlocks(md))
        guard case .placeholder(let payload) = blocks[0].payload else {
            return XCTFail("expected placeholder payload")
        }
        XCTAssertEqual(payload.unknownFields.count, 2)
        XCTAssertEqual(payload.unknownFields[0].key, "future_quota")
        XCTAssertEqual(payload.unknownFields[0].value, "42")
        XCTAssertEqual(payload.unknownFields[1].key, "future_owner")
        XCTAssertEqual(payload.unknownFields[1].value, "alice")
    }

    // MARK: round-trip — byte stability

    func testRoundTripFullPlaceholderIsByteStable() {
        // Same fixture as FeishuPlaceholderTests.testRoundTripFullPlaceholderIsByteStable
        // but routed through the v2-4c structural converter end-to-end:
        //   magic comment → toFeishuBlocks → toMarkdown → magic comment
        // Asserts the placeholder text inside the regenerated markdown
        // matches the original byte-for-byte (the converter wraps with
        // canonical paragraph spacing that the comparison strips).
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
        let blocks = FeishuStructuralConverter.toFeishuBlocks(raw)
        let regenerated = FeishuStructuralConverter.toMarkdown(blocks)
        XCTAssertTrue(regenerated.contains(raw),
            "regenerated markdown should contain the verbatim magic comment\n--- regenerated ---\n\(regenerated)")
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
        let blocks = FeishuStructuralConverter.toFeishuBlocks(raw)
        let regenerated = FeishuStructuralConverter.toMarkdown(blocks)
        XCTAssertTrue(regenerated.contains(raw),
            "regenerated markdown should contain unknown_fields verbatim")
    }

    func testRoundTripStructuralEquivalenceForAllSubtypes() {
        // Build a hand-crafted block tree carrying all seven subtypes,
        // round-trip through Markdown, and assert payload-shape equality
        // (block_id rewrites tolerated for non-placeholder blocks; the
        // placeholder ones must keep their original block_id).
        let original: [FeishuBlock] = [
            page(children: ["a1", "s1", "m1", "v1", "bt1", "e1", "br1"]),
            placeholderBlock(id: "a1", subtype: .attachment, title: "PDF",
                url: "https://x.feishu.cn/file/a1"),
            placeholderBlock(id: "s1", subtype: .sheet, title: "Sheet",
                url: "https://x.feishu.cn/sheets/s1"),
            placeholderBlock(id: "m1", subtype: .mindnote, title: "Mind",
                url: "https://x.feishu.cn/mindnotes/m1"),
            placeholderBlock(id: "v1", subtype: .video, title: "Video",
                url: "https://x.feishu.cn/video/v1"),
            placeholderBlock(id: "bt1", subtype: .bitable, title: "Bitable",
                url: "https://x.feishu.cn/base/bt1"),
            placeholderBlock(id: "e1", subtype: .embed, title: "Embed",
                url: "https://example.com/e1"),
            placeholderBlock(id: "br1", subtype: .board, title: "Board",
                url: "https://x.feishu.cn/board/br1"),
        ]
        let md = FeishuStructuralConverter.toMarkdown(original)
        let regenerated = FeishuStructuralConverter.toFeishuBlocks(md)
        XCTAssertEqual(payloadShapes(original), payloadShapes(regenerated))

        // block_ids must survive verbatim on placeholder blocks (the whole
        // point of the round-trip — preserve_existing depends on it).
        let originalIds = body(original).map(\.blockId)
        let regeneratedIds = body(regenerated).map(\.blockId)
        XCTAssertEqual(originalIds, regeneratedIds)
    }

    // MARK: nested-content warning

    func testNestedChildrenInPlaceholderEmitWarning() {
        // Feishu rarely (but legally) lets a sheet / mindnote nest blocks.
        // Done.md drops those children at the inbound boundary and emits a
        // `nestedContentDroppedInPlaceholder` warning so the metadata-card
        // badge (Slice 11) can surface it.
        let blocks: [FeishuBlock] = [
            page(children: ["s1"]),
            placeholderBlock(
                id: "s1",
                subtype: .sheet,
                title: "Q2 OKR",
                url: "https://x.feishu.cn/sheets/s1",
                children: ["nested1", "nested2"]
            ),
            FeishuBlock(blockId: "nested1", parentId: "s1", children: nil,
                payload: .text(.init(elements: [.textRun(.init(content: "nested para"))]))),
            FeishuBlock(blockId: "nested2", parentId: "s1", children: nil,
                payload: .text(.init(elements: [.textRun(.init(content: "another"))]))),
        ]
        let result = FeishuStructuralConverter.toMarkdownWithWarnings(blocks)
        XCTAssertEqual(result.warnings.count, 1)
        guard case .nestedContentDroppedInPlaceholder(let blockId, let count) = result.warnings[0] else {
            return XCTFail("expected nested-content warning, got \(result.warnings)")
        }
        XCTAssertEqual(blockId, "s1")
        XCTAssertEqual(count, 2)
    }

    func testNoNestedChildrenEmitsNoWarning() {
        let blocks: [FeishuBlock] = [
            page(children: ["s1"]),
            placeholderBlock(id: "s1", subtype: .sheet, title: "OK",
                url: "https://x.feishu.cn/sheets/s1"),
        ]
        let result = FeishuStructuralConverter.toMarkdownWithWarnings(blocks)
        XCTAssertTrue(result.warnings.isEmpty)
    }

    // MARK: video (view 33 wrapping file 23)

    /// A Feishu video decodes as a bare `.video` placeholder (the `view`
    /// block, block_type 33) with a child `.attachment` placeholder (the
    /// `file` block, block_type 23) carrying the real token + filename.
    /// The converter must absorb that child so the video survives pull as
    /// a single 飞书视频 card enriched with the file's token + name —
    /// NOT lost, and NOT flagged as dropped nested content.
    func testVideoAbsorbsChildFileTokenAndName() {
        let blocks: [FeishuBlock] = [
            page(children: ["v1"]),
            placeholderBlock(
                id: "v1",
                subtype: .video,
                title: "视频",
                url: "",
                children: ["f1"]
            ),
            placeholderBlock(
                id: "f1",
                subtype: .attachment,
                title: "20260728-172558.mp4",
                url: "feishu://file/MP4TOKEN",
                blockToken: "MP4TOKEN"
            ),
        ]
        let result = FeishuStructuralConverter.toMarkdownWithWarnings(blocks)
        XCTAssertTrue(result.value.contains("type: video"))
        XCTAssertTrue(result.value.contains("block_id: v1"),
            "preserve-existing round-trip references the view block's id")
        XCTAssertTrue(result.value.contains("block_token: MP4TOKEN"),
            "the video's real token is lifted from the absorbed file child")
        XCTAssertTrue(result.value.contains("title: 20260728-172558.mp4"),
            "card title = the uploaded file's name")
        // #89: the serializer intentionally OMITS the `url:` line for
        // feishu-native placeholders — it's derivable from type + block_token
        // (`feishu://<type>/<block_token>`) and backfilled on parse. The real
        // guarantee is that the emitted card round-trips to that canonical url,
        // so parse it back and confirm the derived value rather than asserting
        // a line the converter deliberately no longer writes.
        let reparsed = MarkdownEngine.parse(markdown: result.value)
        let videoNode = reparsed.content?.first { $0.type == "feishu_placeholder_block" }
        XCTAssertEqual(
            videoNode?.attrs?["url"],
            .string("feishu://video/MP4TOKEN"),
            "url derives from type + block_token on parse-back (#89)"
        )
        XCTAssertTrue(result.warnings.isEmpty,
            "the file child is absorbed, not dropped — no false loss warning")
    }

    // MARK: preserveExistingReference

    func testPreserveExistingReferenceShape() {
        let block = placeholderBlock(
            id: "doxbcXXX_blk001",
            subtype: .sheet,
            title: "Q2 OKR",
            url: "https://x.feishu.cn/sheets/s1"
        )
        let ref = block.preserveExistingReference
        XCTAssertEqual(ref?["block_id"], "doxbcXXX_blk001")
        XCTAssertEqual(ref?["block_type"], "sheet")
        XCTAssertEqual(ref?["_done_md_directive"], "preserve_existing")
        XCTAssertEqual(ref?.count, 3)
    }

    func testPreserveExistingReferenceNilForNonPlaceholder() {
        let para = FeishuBlock(
            blockId: "p1", parentId: "p", children: nil,
            payload: .text(.init(elements: [.textRun(.init(content: "hi"))]))
        )
        XCTAssertNil(para.preserveExistingReference)
    }

    func testPreserveExistingReferenceCoversAllSubtypes() {
        for subtype in FeishuBlock.PlaceholderSubtype.allCases {
            let block = placeholderBlock(
                id: "blk_\(subtype.rawValue)",
                subtype: subtype,
                title: "x",
                url: "https://x.feishu.cn/foo"
            )
            XCTAssertEqual(block.preserveExistingReference?["block_type"], subtype.rawValue)
        }
    }

    // MARK: end-to-end with surrounding content

    func testPlaceholderInsideRegularContentRoundTrips() {
        let md = """
        # 项目状态

        正文段落。

        <!-- feishu-placeholder
        type: sheet
        block_id: doxbcXXX_blk001
        title: Q2 OKR 进度表
        url: https://example.feishu.cn/sheets/shtcnYYY
        -->

        - 上方是当前进度
        - 下方是风险点
        """
        let blocks = body(FeishuStructuralConverter.toFeishuBlocks(md))
        // heading + paragraph + placeholder + 2 bullets = 5 body blocks
        XCTAssertEqual(blocks.count, 5)
        guard case .heading = blocks[0].payload else { return XCTFail("expected heading") }
        guard case .text = blocks[1].payload else { return XCTFail("expected paragraph") }
        guard case .placeholder(let payload) = blocks[2].payload else {
            return XCTFail("expected placeholder")
        }
        XCTAssertEqual(payload.subtype, .sheet)
        XCTAssertEqual(blocks[2].blockId, "doxbcXXX_blk001")
        guard case .bullet = blocks[3].payload else { return XCTFail("expected bullet") }
        guard case .bullet = blocks[4].payload else { return XCTFail("expected bullet") }

        // And the reverse direction: regenerated markdown contains the
        // verbatim magic comment.
        let regenerated = FeishuStructuralConverter.toMarkdown(
            FeishuStructuralConverter.toFeishuBlocks(md)
        )
        XCTAssertTrue(regenerated.contains("<!-- feishu-placeholder"))
        XCTAssertTrue(regenerated.contains("block_id: doxbcXXX_blk001"))
    }
}
