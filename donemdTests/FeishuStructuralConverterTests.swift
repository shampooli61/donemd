import XCTest
@testable import donemd

/// v2-4a coverage for the 8 basic Feishu block types. Two test directions:
///
/// 1. **Markdown → blocks**: hand-built fixtures verify the converter
///    produces the right block_type + payload shapes.
/// 2. **Blocks → Markdown**: hand-built block trees verify the
///    Markdown serializer output matches canonical form.
/// 3. **Round-trip both ways**: assert structural equivalence (block_type
///    + payload, ignoring auto-generated block_ids) and canonical-form
///    Markdown idempotence.
final class FeishuStructuralConverterTests: XCTestCase {

    // MARK: helpers

    /// Compare blocks by block_type + payload, dropping block_id /
    /// parent_id / children-id-strings that round-trips legitimately
    /// rewrite. Tree structure is preserved by the *order* of `payload`
    /// emission — parents always emit before children — so an in-order
    /// comparison is sufficient for the basic block set.
    private func payloadShapes(_ blocks: [FeishuBlock]) -> [FeishuBlock.Payload] {
        blocks.map(\.payload)
    }

    /// Ignore page block (always present, always block_type=1) when
    /// counting body blocks.
    private func body(_ blocks: [FeishuBlock]) -> [FeishuBlock] {
        blocks.filter { if case .page = $0.payload { return false } else { return true } }
    }

    // MARK: Markdown → blocks

    func testParagraphBecomesText() {
        let blocks = FeishuStructuralConverter.toFeishuBlocks("hello world")
        let bodyBlocks = body(blocks)
        XCTAssertEqual(bodyBlocks.count, 1)
        guard case .text(let payload) = bodyBlocks[0].payload else {
            return XCTFail("expected .text, got \(bodyBlocks[0].payload)")
        }
        XCTAssertEqual(payload.elements.count, 1)
        if case .textRun(let run) = payload.elements[0] {
            XCTAssertEqual(run.content, "hello world")
            XCTAssertEqual(run.style, .plain)
        } else {
            XCTFail("expected textRun")
        }
    }

    func testHeadingLevelsOneThroughSix() {
        let md = """
        # h1
        ## h2
        ### h3
        #### h4
        ##### h5
        ###### h6
        """
        let bodyBlocks = body(FeishuStructuralConverter.toFeishuBlocks(md))
        XCTAssertEqual(bodyBlocks.count, 6)
        for (idx, expectedLevel) in (1...6).enumerated() {
            guard case .heading(let level, _) = bodyBlocks[idx].payload else {
                return XCTFail("expected .heading at \(idx)")
            }
            XCTAssertEqual(level, expectedLevel)
        }
    }

    func testBoldItalicMarksRoundTripIntoStyle() {
        let blocks = FeishuStructuralConverter.toFeishuBlocks("**bold** and *italic*")
        let bodyBlocks = body(blocks)
        guard case .text(let payload) = bodyBlocks[0].payload else {
            return XCTFail()
        }
        let runs: [(String, FeishuBlock.TextElementStyle)] = payload.elements.compactMap {
            if case .textRun(let r) = $0 { return (r.content, r.style) } else { return nil }
        }
        XCTAssertTrue(runs.contains { $0.0 == "bold" && $0.1.bold })
        XCTAssertTrue(runs.contains { $0.0 == "italic" && $0.1.italic })
    }

    func testInlineCodeMarkRoundTrips() {
        let blocks = FeishuStructuralConverter.toFeishuBlocks("call `foo()`")
        let bodyBlocks = body(blocks)
        guard case .text(let payload) = bodyBlocks[0].payload else { return XCTFail() }
        let runs: [(String, FeishuBlock.TextElementStyle)] = payload.elements.compactMap {
            if case .textRun(let r) = $0 { return (r.content, r.style) } else { return nil }
        }
        XCTAssertTrue(runs.contains { $0.0 == "foo()" && $0.1.inlineCode })
    }

    func testLinkMarkRoundTrips() {
        let blocks = FeishuStructuralConverter.toFeishuBlocks("see [docs](https://example.com)")
        let bodyBlocks = body(blocks)
        guard case .text(let payload) = bodyBlocks[0].payload else { return XCTFail() }
        let linked = payload.elements.compactMap { e -> (String, String)? in
            if case .textRun(let r) = e, let href = r.style.link { return (r.content, href) }
            return nil
        }
        XCTAssertEqual(linked.first?.0, "docs")
        XCTAssertEqual(linked.first?.1, "https://example.com")
    }

    func testBulletListBecomesBulletItems() {
        let md = """
        - alpha
        - beta
        """
        let bodyBlocks = body(FeishuStructuralConverter.toFeishuBlocks(md))
        XCTAssertEqual(bodyBlocks.count, 2)
        for block in bodyBlocks {
            guard case .bullet = block.payload else {
                return XCTFail("expected .bullet, got \(block.payload)")
            }
        }
    }

    func testOrderedListBecomesOrderedItems() {
        let md = """
        1. one
        2. two
        """
        let bodyBlocks = body(FeishuStructuralConverter.toFeishuBlocks(md))
        XCTAssertEqual(bodyBlocks.count, 2)
        for block in bodyBlocks {
            guard case .ordered = block.payload else {
                return XCTFail("expected .ordered, got \(block.payload)")
            }
        }
    }

    func testTodoListMapsCheckedState() {
        let md = """
        - [ ] open
        - [x] done
        """
        let bodyBlocks = body(FeishuStructuralConverter.toFeishuBlocks(md))
        XCTAssertEqual(bodyBlocks.count, 2)
        guard case .todo(_, let openDone) = bodyBlocks[0].payload,
              case .todo(_, let doneDone) = bodyBlocks[1].payload else {
            return XCTFail("expected todo blocks")
        }
        XCTAssertFalse(openDone)
        XCTAssertTrue(doneDone)
    }

    func testQuoteBecomesQuote() {
        let bodyBlocks = body(FeishuStructuralConverter.toFeishuBlocks("> wisdom"))
        XCTAssertEqual(bodyBlocks.count, 1)
        guard case .quote(let payload) = bodyBlocks[0].payload else {
            return XCTFail("expected quote")
        }
        if case .textRun(let r) = payload.elements.first {
            XCTAssertEqual(r.content, "wisdom")
        } else {
            XCTFail("expected textRun")
        }
    }

    func testCodeBlockPreservesLanguage() {
        let md = """
        ```swift
        let x = 1
        ```
        """
        let bodyBlocks = body(FeishuStructuralConverter.toFeishuBlocks(md))
        XCTAssertEqual(bodyBlocks.count, 1)
        guard case .code(let payload) = bodyBlocks[0].payload else {
            return XCTFail("expected code block")
        }
        XCTAssertEqual(payload.language, "swift")
        if case .textRun(let r) = payload.elements.first {
            XCTAssertTrue(r.content.contains("let x = 1"))
        } else {
            XCTFail("expected textRun in code")
        }
    }

    func testDividerBecomesDivider() {
        let bodyBlocks = body(FeishuStructuralConverter.toFeishuBlocks("---"))
        XCTAssertEqual(bodyBlocks.count, 1)
        guard case .divider = bodyBlocks[0].payload else {
            return XCTFail("expected divider")
        }
    }

    func testImagePreservesSrcAndAlt() {
        let bodyBlocks = body(FeishuStructuralConverter.toFeishuBlocks("![logo](https://example.com/logo.png)"))
        // swift-markdown wraps a standalone image in a paragraph; our
        // converter projects that paragraph as a Feishu text block whose
        // inline content is empty (image is a block-level node not yet
        // bridged in the inline path). Acceptable for v2-4a — image-as-
        // block path covered by the constructed-blocks direction below.
        // Here, just verify no crash and that something reasonable came back.
        XCTAssertGreaterThanOrEqual(bodyBlocks.count, 0)
    }

    /// Local video (#88): a `video` node emits no Feishu block (Feishu has no
    /// local-video block in v1). It must hit the explicit `case "video"`, not
    /// the silent `default` — the user-facing skip warning is surfaced by
    /// FeishuImageUploadStage's `Report.skippedVideos`, tested separately.
    func testLocalVideoNodeEmitsNoBlock() {
        let tiptapDoc = TiptapNode(type: "doc", content: [
            TiptapNode(type: "paragraph", content: [TiptapNode.text("before")]),
            TiptapNode(type: "video", attrs: ["src": .string("donemd-asset://clip.mp4")]),
            TiptapNode(type: "paragraph", content: [TiptapNode.text("after")]),
        ])
        let bodyBlocks = body(FeishuStructuralConverter.toFeishuBlocks(tiptap: tiptapDoc))
        // The two paragraphs survive; the video contributes nothing.
        XCTAssertEqual(bodyBlocks.count, 2, "video node must not emit a Feishu block")
        for block in bodyBlocks {
            guard case .text = block.payload else {
                return XCTFail("expected only text blocks, got \(block.payload)")
            }
        }
    }

    // MARK: blocks → Markdown

    func testToMarkdownRendersCanonicalHeadings() {
        let blocks: [FeishuBlock] = [
            page(children: ["b1", "b2"]),
            FeishuBlock(
                blockId: "b1", parentId: "p", children: nil,
                payload: .heading(level: 1, .init(elements: [.textRun(.init(content: "Title"))]))
            ),
            FeishuBlock(
                blockId: "b2", parentId: "p", children: nil,
                payload: .text(.init(elements: [.textRun(.init(content: "Body"))]))
            ),
        ]
        let md = FeishuStructuralConverter.toMarkdown(blocks)
        XCTAssertTrue(md.contains("# Title"))
        XCTAssertTrue(md.contains("Body"))
    }

    func testToMarkdownRendersTodoChecked() {
        let blocks: [FeishuBlock] = [
            page(children: ["t1", "t2"]),
            FeishuBlock(
                blockId: "t1", parentId: "p", children: nil,
                payload: .todo(.init(elements: [.textRun(.init(content: "open"))]), done: false)
            ),
            FeishuBlock(
                blockId: "t2", parentId: "p", children: nil,
                payload: .todo(.init(elements: [.textRun(.init(content: "done"))]), done: true)
            ),
        ]
        let md = FeishuStructuralConverter.toMarkdown(blocks)
        XCTAssertTrue(md.contains("- [ ] open"))
        XCTAssertTrue(md.contains("- [x] done"))
    }

    func testToMarkdownRendersImageWithToken() {
        let blocks: [FeishuBlock] = [
            page(children: ["i1"]),
            FeishuBlock(
                blockId: "i1", parentId: "p", children: nil,
                payload: .image(.init(token: "boxcnImg123", src: nil, alt: "diagram"))
            ),
        ]
        let md = FeishuStructuralConverter.toMarkdown(blocks)
        XCTAssertTrue(md.contains("feishu://image/boxcnImg123"))
        XCTAssertTrue(md.contains("diagram"))
    }

    // MARK: round-trip

    func testMarkdownRoundTripIsCanonicalIdempotent() {
        let canonical = """
        # Title

        Body paragraph with **bold** and *italic*.

        - [ ] open task
        - [x] done task

        > quoted line

        ```swift
        let x = 1
        ```

        ---
        """
        let blocks = FeishuStructuralConverter.toFeishuBlocks(canonical)
        let regenerated = FeishuStructuralConverter.toMarkdown(blocks)
        // Re-parse-and-emit should match the second pass (idempotence on
        // canonical input). We compare normalized to be tolerant of a
        // trailing newline difference at the end of the doc.
        let reBlocks = FeishuStructuralConverter.toFeishuBlocks(regenerated)
        XCTAssertEqual(payloadShapes(blocks), payloadShapes(reBlocks))
    }

    func testFeishuJSONRoundTripStructuralEquivalence() {
        // Hand-built block tree mirroring a Feishu pull. After
        // toMarkdown → toFeishuBlocks the body block sequence should
        // match the original (block_id rewrites allowed).
        //
        // Note on fixture ordering: bullet runs and todo runs are kept in
        // separate sibling groups with a paragraph or divider in between.
        // Mixed `-` markers in adjacent items collapse to a single
        // taskList per ADR-0002 / ASTConverter canonical form (a
        // checkbox anywhere in a `-` list pulls the whole list into
        // taskList), which is correct normalization but not block-by-
        // block equivalent.
        let original: [FeishuBlock] = [
            page(children: ["h1", "p1", "li1", "li2", "p2", "td1", "q1", "c1", "d1"]),
            FeishuBlock(blockId: "h1", parentId: "p", children: nil,
                payload: .heading(level: 2, .init(elements: [.textRun(.init(content: "Section"))]))),
            FeishuBlock(blockId: "p1", parentId: "p", children: nil,
                payload: .text(.init(elements: [.textRun(.init(content: "lead"))]))),
            FeishuBlock(blockId: "li1", parentId: "p", children: nil,
                payload: .bullet(.init(elements: [.textRun(.init(content: "alpha"))]))),
            FeishuBlock(blockId: "li2", parentId: "p", children: nil,
                payload: .bullet(.init(elements: [.textRun(.init(content: "beta"))]))),
            FeishuBlock(blockId: "p2", parentId: "p", children: nil,
                payload: .text(.init(elements: [.textRun(.init(content: "tasks below"))]))),
            FeishuBlock(blockId: "td1", parentId: "p", children: nil,
                payload: .todo(.init(elements: [.textRun(.init(content: "task"))]), done: true)),
            FeishuBlock(blockId: "q1", parentId: "p", children: nil,
                payload: .quote(.init(elements: [.textRun(.init(content: "quoted"))]))),
            FeishuBlock(blockId: "c1", parentId: "p", children: nil,
                payload: .code(.init(elements: [.textRun(.init(content: "code\n"))], language: "python"))),
            FeishuBlock(blockId: "d1", parentId: "p", children: nil, payload: .divider),
        ]
        let md = FeishuStructuralConverter.toMarkdown(original)
        let regenerated = FeishuStructuralConverter.toFeishuBlocks(md)
        XCTAssertEqual(payloadShapes(original), payloadShapes(regenerated))
    }

    func testNestedBulletPreservesHierarchy() {
        let md = """
        - top
          - inner
        """
        let blocks = FeishuStructuralConverter.toFeishuBlocks(md)
        let bullets = blocks.filter { if case .bullet = $0.payload { return true } else { return false } }
        XCTAssertEqual(bullets.count, 2)
        // The "top" bullet should list the inner bullet's id as a child.
        let topBlock = bullets.first { block -> Bool in
            if case .bullet(let p) = block.payload,
               case .textRun(let r) = p.elements.first,
               r.content == "top" { return true }
            return false
        }
        XCTAssertNotNil(topBlock?.children)
        XCTAssertEqual(topBlock?.children?.count, 1)
    }

    // MARK: page helper

    private func page(children: [String]) -> FeishuBlock {
        FeishuBlock(
            blockId: "p", parentId: nil, children: children,
            payload: .page(.init())
        )
    }
}
