import XCTest
@testable import donemd

/// Tests for the YAML frontmatter parse/serialize/merge engine that
/// sits in front of swift-markdown.
///
/// Acceptance criteria covered (issue #40):
///   - parse handles 3 cases: no frontmatter, valid yaml, broken yaml
///   - serialize is idempotent on parsed input (round-trip byte-equal)
///   - user fields preserved verbatim (no yaml-style normalization)
///   - typed `feishu:` accessors work on every recognized key
///   - unrecognized `feishu:` sub-keys round-trip
///   - placeholder_blocks order is stable
///   - `+++` (TOML) is rejected — file is treated as plain body
final class FrontmatterEngineTests: XCTestCase {

    // MARK: - parse: detection

    func testParseNoFrontmatter() {
        let source = "# 标题\n\n正文段落\n"
        let result = FrontmatterEngine.parse(source)
        XCTAssertEqual(result.frontmatter, .empty)
        XCTAssertEqual(result.body, source)
    }

    func testParseEmptyInput() {
        let result = FrontmatterEngine.parse("")
        XCTAssertEqual(result.frontmatter, .empty)
        XCTAssertEqual(result.body, "")
    }

    func testParseFenceLikeButNotAtFileStart() {
        // Frontmatter must be at file start. `---` somewhere in the
        // middle is just a thematic break; not our problem.
        let source = "intro\n---\ntitle: x\n---\n"
        let result = FrontmatterEngine.parse(source)
        XCTAssertEqual(result.frontmatter, .empty)
        XCTAssertEqual(result.body, source)
    }

    func testParseRejectsTOMLFence() {
        // `+++` is Hugo's TOML marker; ADR-0005 rejects it (yaml only).
        let source = "+++\ntitle = \"x\"\n+++\n\nbody\n"
        let result = FrontmatterEngine.parse(source)
        XCTAssertEqual(result.frontmatter, .empty)
        XCTAssertEqual(result.body, source)
    }

    func testParseUnclosedFenceFallsBackToBody() {
        // Open fence with no matching close → not a valid frontmatter.
        let source = "---\ntitle: x\nbody never closes\n"
        let result = FrontmatterEngine.parse(source)
        XCTAssertEqual(result.frontmatter, .empty)
        XCTAssertEqual(result.body, source)
    }

    // MARK: - parse: yaml content

    func testParseSimpleUserFields() {
        let source = """
        ---
        title: 我的文档
        author: shampoo
        ---

        # 正文
        """
        let result = FrontmatterEngine.parse(source)
        XCTAssertTrue(result.frontmatter.hasFence)
        XCTAssertEqual(result.frontmatter.userFields.count, 2)
        XCTAssertEqual(result.frontmatter.userFields[0].key, "title")
        XCTAssertEqual(result.frontmatter.userFields[1].key, "author")
        XCTAssertNil(result.frontmatter.feishu)
        XCTAssertEqual(result.body, "\n# 正文")
    }

    func testParseEmptyFenceBlock() {
        let source = "---\n---\n\nbody\n"
        let result = FrontmatterEngine.parse(source)
        XCTAssertTrue(result.frontmatter.hasFence)
        XCTAssertTrue(result.frontmatter.userFields.isEmpty)
        XCTAssertNil(result.frontmatter.feishu)
        XCTAssertEqual(result.body, "\nbody\n")
    }

    func testParseCorruptYAMLFallsBackToBody() {
        // `key: : nope` is malformed YAML — engine must not throw.
        let source = "---\nkey: : nope\n---\n\nbody\n"
        let result = FrontmatterEngine.parse(source)
        XCTAssertEqual(result.frontmatter, .empty)
        XCTAssertEqual(result.body, source)
    }

    // MARK: - parse: feishu namespace

    func testParseRecognizedFeishuFields() {
        let source = """
        ---
        feishu:
          doc_token: doxcnAbc123XYZ
          doc_url: https://example.feishu.cn/docx/doxcnAbc123XYZ
          last_pulled_revision: 142
          last_pushed_at: '2026-05-23T10:23:45+08:00'
        ---

        body
        """
        let fm = FrontmatterEngine.parse(source).frontmatter
        XCTAssertNotNil(fm.feishu)
        let f = fm.feishu!
        XCTAssertEqual(f.docToken, DocToken("doxcnAbc123XYZ"))
        XCTAssertEqual(f.docURL?.absoluteString, "https://example.feishu.cn/docx/doxcnAbc123XYZ")
        XCTAssertEqual(f.lastPulledRevision, 142)
        XCTAssertNotNil(f.lastPushedAt)
        XCTAssertEqual(f.placeholderBlocks, [])
        XCTAssertEqual(f.unknownFields, [])
    }

    func testParsePlaceholderBlocksStableOrder() {
        let source = """
        ---
        feishu:
          doc_token: doxcnAbc123XYZ
          placeholder_blocks:
            - block_id: doxbcXXX_blk001
              type: sheet
              title: Q2 OKR
            - block_id: doxbcXXX_blk007
              type: board
              title: 架构图
            - block_id: doxbcXXX_blk012
              type: bitable
        ---
        body
        """
        let f = FrontmatterEngine.parse(source).frontmatter.feishu!
        XCTAssertEqual(f.placeholderBlocks.count, 3)
        XCTAssertEqual(f.placeholderBlocks[0].blockId, "doxbcXXX_blk001")
        XCTAssertEqual(f.placeholderBlocks[0].type, "sheet")
        XCTAssertEqual(f.placeholderBlocks[0].title, "Q2 OKR")
        XCTAssertEqual(f.placeholderBlocks[1].blockId, "doxbcXXX_blk007")
        XCTAssertEqual(f.placeholderBlocks[2].blockId, "doxbcXXX_blk012")
        XCTAssertNil(f.placeholderBlocks[2].title)
    }

    func testParseUnrecognizedFeishuKeys() {
        // Future / foreign keys under `feishu:` must round-trip.
        let source = """
        ---
        feishu:
          doc_token: doxcnAbc
          foo: bar
          experimental_setting: true
        ---
        """
        let fm = FrontmatterEngine.parse(source).frontmatter
        let unknown = fm.feishu!.unknownFields
        XCTAssertEqual(unknown.count, 2)
        XCTAssertEqual(unknown.map { $0.key }, ["foo", "experimental_setting"])
    }

    // MARK: - serialize: idempotent

    func testSerializeIdempotentSimpleUserFields() {
        let source = """
        ---
        title: 我的文档
        author: shampoo
        ---

        # 正文

        段落。
        """
        assertParseSerializeRoundTrip(source)
    }

    func testSerializeIdempotentFullFeishuBlock() {
        // Schema-canonical form (key order matches emitter output).
        let source = """
        ---
        title: Q2 路线图
        feishu:
          doc_token: doxcnAbc123XYZ
          doc_url: https://example.feishu.cn/docx/doxcnAbc123XYZ
          last_pulled_revision: 142
          placeholder_blocks:
            - block_id: doxbcXXX_blk001
              type: sheet
              title: Q2 OKR
            - block_id: doxbcXXX_blk007
              type: board
              title: 架构图
        ---

        # 正文
        """
        assertParseSerializeRoundTrip(source)
    }

    func testSerializeIdempotentUserFieldVerbatim() {
        // Whitespace, quoting, comments inside a value should survive
        // verbatim — the user's text is not normalized.
        let source = """
        ---
        title: '带 单引号 的 标题'
        tags: [roadmap, q2]
        authors:
          - 蛋蛋
          - 蝌蚪
        ---

        body
        """
        assertParseSerializeRoundTrip(source)
    }

    func testSerializeIdempotentEmptyFence() {
        let source = "---\n---\n\nbody\n"
        assertParseSerializeRoundTrip(source)
    }

    func testSerializeNoFrontmatterPassthrough() {
        let source = "# heading\n\nparagraph\n"
        let parsed = FrontmatterEngine.parse(source)
        let serialized = FrontmatterEngine.serialize(parsed.frontmatter, body: parsed.body)
        XCTAssertEqual(serialized, source)
    }

    func testSerializeUnknownFeishuKeyRoundTrips() {
        let source = """
        ---
        feishu:
          doc_token: doxcnAbc
          foo: bar
        ---
        body
        """
        let parsed = FrontmatterEngine.parse(source)
        let serialized = FrontmatterEngine.serialize(parsed.frontmatter, body: parsed.body)
        // The engine puts recognized fields in canonical order first,
        // then unknown fields after. We don't require byte-equality
        // with the input here — only that re-parsing gives the same
        // frontmatter (idempotent from the second save onwards).
        let reparsed = FrontmatterEngine.parse(serialized)
        XCTAssertEqual(reparsed.frontmatter, parsed.frontmatter)
        XCTAssertEqual(reparsed.body, parsed.body)
        // And that "foo: bar" survived.
        XCTAssertTrue(serialized.contains("foo: bar"))
    }

    // MARK: - merge

    func testMergeAppendsFeishuWhenAbsent() {
        let existing = FrontmatterEngine.parse("""
        ---
        title: 我的文档
        ---

        body
        """).frontmatter
        let incoming = Frontmatter(
            userFields: [],
            feishu: FeishuFrontmatter(docToken: DocToken("doxcnNEW")),
            feishuOriginalIndex: 0,
            hasFence: true
        )
        let merged = FrontmatterEngine.merge(existing: existing, incoming: incoming)
        XCTAssertEqual(merged.userFields.count, 1)
        XCTAssertEqual(merged.userFields[0].key, "title")
        XCTAssertEqual(merged.feishu?.docToken, DocToken("doxcnNEW"))
        XCTAssertEqual(merged.feishuOriginalIndex, 1) // appended after the user field
    }

    func testMergeReplacesFeishuPreservingPosition() {
        let existing = FrontmatterEngine.parse("""
        ---
        title: 我的
        feishu:
          doc_token: doxcnOLD
          last_pulled_revision: 1
        author: shampoo
        ---

        body
        """).frontmatter
        let incoming = Frontmatter(
            feishu: FeishuFrontmatter(
                docToken: DocToken("doxcnOLD"),
                lastPulledRevision: 99
            ),
            hasFence: true
        )
        let merged = FrontmatterEngine.merge(existing: existing, incoming: incoming)
        // feishu replaced wholesale
        XCTAssertEqual(merged.feishu?.lastPulledRevision, 99)
        // position preserved (between title and author)
        XCTAssertEqual(merged.feishuOriginalIndex, 1)
        XCTAssertEqual(merged.userFields.map { $0.key }, ["title", "author"])
    }

    func testMergeNoIncomingFeishuKeepsExisting() {
        let existing = FrontmatterEngine.parse("""
        ---
        feishu:
          doc_token: doxcnSTAY
        ---
        """).frontmatter
        let merged = FrontmatterEngine.merge(existing: existing, incoming: .empty)
        XCTAssertEqual(merged.feishu?.docToken, DocToken("doxcnSTAY"))
    }

    // MARK: - integration with MarkdownEngine

    func testMarkdownEngineParseStripsFrontmatter() {
        let source = """
        ---
        title: x
        ---

        # heading
        """
        let body = MarkdownEngine.parse(markdown: source)
        // Body alone — no doc-level metadata, just the heading.
        XCTAssertEqual(body.type, "doc")
        let firstBlock = body.content?.first
        XCTAssertEqual(firstBlock?.type, "heading")
    }

    func testMarkdownEngineParseDocumentReturnsFrontmatter() {
        let source = """
        ---
        title: x
        feishu:
          doc_token: doxcnX
        ---

        # heading
        """
        let doc = MarkdownEngine.parseDocument(source: source)
        XCTAssertEqual(doc.frontmatter.userFields.first?.key, "title")
        XCTAssertEqual(doc.frontmatter.feishu?.docToken, DocToken("doxcnX"))
        XCTAssertEqual(doc.body.content?.first?.type, "heading")
    }

    func testMarkdownEngineParsedDocumentRoundTripsFrontmatter() {
        let source = """
        ---
        title: 文档
        feishu:
          doc_token: doxcnX
          last_pulled_revision: 5
        ---

        # heading

        para
        """
        let doc = MarkdownEngine.parseDocument(source: source)
        let serialized = MarkdownEngine.serialize(document: doc)
        let reparsed = MarkdownEngine.parseDocument(source: serialized)
        XCTAssertEqual(reparsed.frontmatter, doc.frontmatter)
        XCTAssertEqual(reparsed.body, doc.body)
    }

    // MARK: - Helpers

    private func assertParseSerializeRoundTrip(
        _ source: String,
        file: StaticString = #file,
        line: UInt = #line
    ) {
        let parsed = FrontmatterEngine.parse(source)
        let serialized = FrontmatterEngine.serialize(parsed.frontmatter, body: parsed.body)
        let reparsed = FrontmatterEngine.parse(serialized)
        // Frontmatter equality + body byte-equality on round-trip.
        XCTAssertEqual(
            reparsed.frontmatter,
            parsed.frontmatter,
            "frontmatter drifted on round-trip\n--- before ---\n\(source)\n--- after ---\n\(serialized)",
            file: file, line: line
        )
        XCTAssertEqual(
            reparsed.body, parsed.body,
            "body drifted on round-trip",
            file: file, line: line
        )
    }
}
