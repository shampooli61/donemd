import XCTest
@testable import donemd

/// v2-4b coverage for the rich-format Feishu blocks: callout × 5,
/// GFM table, and mermaid (` ```mermaid ` fenced code).
///
/// Two directions per block type, plus structural round-trip:
/// - **Markdown → blocks**: hand-built source verifies converter
///   produces the right Payload (callout/table) or `code` with
///   `language="mermaid"`.
/// - **Blocks → Markdown**: hand-built block trees verify the canonical
///   Markdown output.
final class FeishuStructuralConverterRichBlocksTests: XCTestCase {

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

    // MARK: mermaid

    func testMermaidCodeBlockPreservesLanguage() {
        let md = """
        ```mermaid
        graph TD; A-->B;
        ```
        """
        let blocks = body(FeishuStructuralConverter.toFeishuBlocks(md))
        XCTAssertEqual(blocks.count, 1)
        guard case .code(let payload) = blocks[0].payload else {
            return XCTFail("expected .code, got \(blocks[0].payload)")
        }
        XCTAssertEqual(payload.language, "mermaid")
        guard case .textRun(let r) = payload.elements.first else {
            return XCTFail("expected textRun")
        }
        XCTAssertTrue(r.content.contains("graph TD"))
    }

    func testMermaidRoundTripIsCanonicalIdempotent() {
        let canonical = """
        ```mermaid
        sequenceDiagram
            A->>B: Hi
        ```
        """
        let blocks = FeishuStructuralConverter.toFeishuBlocks(canonical)
        let md = FeishuStructuralConverter.toMarkdown(blocks)
        let reBlocks = FeishuStructuralConverter.toFeishuBlocks(md)
        XCTAssertEqual(payloadShapes(blocks), payloadShapes(reBlocks))
    }

    // MARK: callout — Markdown → blocks

    func testCalloutNoteEmitsLightBlue() {
        let md = """
        > [!NOTE]
        > info body
        """
        let blocks = body(FeishuStructuralConverter.toFeishuBlocks(md))
        // First body block is the callout itself, then nested paragraph.
        guard case .callout(let payload) = blocks[0].payload else {
            return XCTFail("expected callout, got \(blocks[0].payload)")
        }
        XCTAssertEqual(payload.backgroundColor, "light-blue")
        // wireEmojiId, NOT the Unicode glyph. Real-device 2026-06-04
        // returned 1770006 schema mismatch when "💡" was sent — the
        // Feishu wire requires the named ID.
        XCTAssertEqual(payload.emoji, "bulb")
    }

    func testCalloutAllFiveTypesMapDistinctColors() {
        let cases: [(String, String, String)] = [
            ("NOTE", "light-blue", "bulb"),
            ("TIP", "light-green", "sparkles"),
            ("IMPORTANT", "light-purple", "exclamation"),
            ("WARNING", "light-yellow", "warning"),
            ("CAUTION", "light-red", "rotating_light"),
        ]
        for (type, color, wireEmojiId) in cases {
            let md = "> [!\(type)]\n> body"
            let blocks = body(FeishuStructuralConverter.toFeishuBlocks(md))
            guard case .callout(let payload) = blocks[0].payload else {
                return XCTFail("expected callout for \(type)")
            }
            XCTAssertEqual(payload.backgroundColor, color, "color for \(type)")
            // Wire-format named ID, NOT Unicode glyph (1770006 fix).
            XCTAssertEqual(payload.emoji, wireEmojiId, "wireEmojiId for \(type)")
        }
    }

    /// End-to-end wire contract test for the 1770006 callout fix:
    /// markdown → toFeishuBlocks → encodeDescendantBody must produce
    /// JSON whose `callout.emoji_id` is the named ID. Anchors the
    /// fix at the wire boundary so a future regression that puts
    /// the Unicode glyph back into the path gets caught immediately.
    func testCalloutWireBodyEmojiIdIsNamedNotUnicode() throws {
        let md = "> [!NOTE]\n> info"
        // Encoder needs the full block list (including the page block
        // it uses as the descendant root); body() strips it for the
        // payload-shape tests above.
        let blocks = FeishuStructuralConverter.toFeishuBlocks(md)
        let wireBody = try FeishuBlockEncoder.encodeDescendantBody(from: blocks)
        let descendants = try XCTUnwrap(wireBody["descendants"] as? [[String: Any]])
        let callout = try XCTUnwrap(descendants[0]["callout"] as? [String: Any])
        XCTAssertEqual(callout["emoji_id"] as? String, "bulb",
            "wire contract: emoji_id must be the named ID, not Unicode (1770006 fix)")
    }

    func testCalloutChildrenAreNestedBlocks() {
        let md = """
        > [!WARNING]
        > heads up
        >
        > - item one
        > - item two
        """
        let blocks = body(FeishuStructuralConverter.toFeishuBlocks(md))
        guard case .callout = blocks[0].payload else {
            return XCTFail("expected callout")
        }
        // Children of the callout: at least 1 paragraph + 2 bullet items.
        let children = blocks[0].children ?? []
        XCTAssertGreaterThanOrEqual(children.count, 3)
    }

    // MARK: callout — blocks → Markdown

    func testCalloutBlocksToMarkdownEmitsGitHubSyntax() {
        let blocks: [FeishuBlock] = [
            page(children: ["c1"]),
            FeishuBlock(
                blockId: "c1", parentId: "p", children: ["t1"],
                payload: .callout(.init(emoji: "⚠️", backgroundColor: "light-yellow"))
            ),
            FeishuBlock(
                blockId: "t1", parentId: "c1", children: nil,
                payload: .text(.init(elements: [.textRun(.init(content: "heads up"))]))
            ),
        ]
        let md = FeishuStructuralConverter.toMarkdown(blocks)
        XCTAssertTrue(md.contains("> [!WARNING]"), "got: \(md)")
        XCTAssertTrue(md.contains("> heads up"), "got: \(md)")
    }

    func testCalloutDisallowedChildrenAreFiltered() {
        // Feishu hard limit: code blocks / tables / horizontalRule /
        // image inside callout are dropped at the converter boundary.
        let blocks: [FeishuBlock] = [
            page(children: ["c1"]),
            FeishuBlock(
                blockId: "c1", parentId: "p", children: ["t1", "code1", "div1"],
                payload: .callout(.init(emoji: "💡", backgroundColor: "light-blue"))
            ),
            FeishuBlock(
                blockId: "t1", parentId: "c1", children: nil,
                payload: .text(.init(elements: [.textRun(.init(content: "ok"))]))
            ),
            FeishuBlock(
                blockId: "code1", parentId: "c1", children: nil,
                payload: .code(.init(elements: [.textRun(.init(content: "x"))], language: "swift"))
            ),
            FeishuBlock(
                blockId: "div1", parentId: "c1", children: nil,
                payload: .divider
            ),
        ]
        let md = FeishuStructuralConverter.toMarkdown(blocks)
        XCTAssertTrue(md.contains("> [!NOTE]"))
        XCTAssertTrue(md.contains("> ok"))
        // The disallowed children must not appear inside or outside.
        XCTAssertFalse(md.contains("```swift"))
        XCTAssertFalse(md.contains("---"))
    }

    // MARK: table — Markdown → blocks

    func testGfmTableEmitsTableAndCells() {
        let md = """
        | Name | Age |
        | --- | --- |
        | Alice | 30 |
        | Bob | 25 |
        """
        let blocks = body(FeishuStructuralConverter.toFeishuBlocks(md))
        // Expect 1 table block + (3 rows × 2 cols = 6 cells) + 6 inner texts.
        let tables = blocks.filter { if case .table = $0.payload { return true } else { return false } }
        let cells = blocks.filter { if case .tableCell = $0.payload { return true } else { return false } }
        XCTAssertEqual(tables.count, 1)
        XCTAssertEqual(cells.count, 6)
        guard case .table(let payload) = tables[0].payload else {
            return XCTFail("expected table payload")
        }
        XCTAssertEqual(payload.rowSize, 3)
        XCTAssertEqual(payload.columnSize, 2)
        XCTAssertTrue(payload.headerRow)
    }

    // MARK: table — blocks → Markdown

    func testTableBlocksToMarkdownEmitsGfmPipes() {
        let blocks: [FeishuBlock] = [
            page(children: ["tab1"]),
            FeishuBlock(
                blockId: "tab1", parentId: "p",
                children: ["c00", "c01", "c10", "c11"],
                payload: .table(.init(rowSize: 2, columnSize: 2, headerRow: true))
            ),
            cell("c00", parent: "tab1", text: "Name", textId: "t00"),
            cell("c01", parent: "tab1", text: "Age", textId: "t01"),
            cell("c10", parent: "tab1", text: "Alice", textId: "t10"),
            cell("c11", parent: "tab1", text: "30", textId: "t11"),
            // text children referenced by the cells:
            text("t00", parent: "c00", content: "Name"),
            text("t01", parent: "c01", content: "Age"),
            text("t10", parent: "c10", content: "Alice"),
            text("t11", parent: "c11", content: "30"),
        ]
        let md = FeishuStructuralConverter.toMarkdown(blocks)
        XCTAssertTrue(md.contains("| Name | Age |"), "got: \(md)")
        XCTAssertTrue(md.contains("| --- | --- |"), "got: \(md)")
        XCTAssertTrue(md.contains("| Alice | 30 |"), "got: \(md)")
    }

    // MARK: round-trip

    func testCalloutRoundTripStructuralEquivalence() {
        // Fixture uses the wire-format named ID ("warning"), matching
        // what a real Feishu pull returns for `callout.emoji_id`.
        // Pre-1770006-fix this also worked with the Unicode glyph
        // because the converter passed `emoji` through unchanged;
        // post-fix the converter emits the wire format unconditionally,
        // so only a wire-format fixture round-trips identity.
        let original: [FeishuBlock] = [
            page(children: ["c1"]),
            FeishuBlock(
                blockId: "c1", parentId: "p", children: ["t1"],
                payload: .callout(.init(emoji: "warning", backgroundColor: "light-yellow"))
            ),
            FeishuBlock(
                blockId: "t1", parentId: "c1", children: nil,
                payload: .text(.init(elements: [.textRun(.init(content: "heads up"))]))
            ),
        ]
        let md = FeishuStructuralConverter.toMarkdown(original)
        let regenerated = FeishuStructuralConverter.toFeishuBlocks(md)
        // Body should contain a callout + a text child with same payload.
        XCTAssertEqual(payloadShapes(original), payloadShapes(regenerated))
    }

    func testTableRoundTripStructuralEquivalence() {
        // Canonical document order is depth-first preorder: each table_cell
        // is immediately followed by its text child. This matches how
        // FeishuStructuralConverter emits and how Feishu actually serializes
        // block trees on the wire (parent → its descendants → next sibling).
        let original: [FeishuBlock] = [
            page(children: ["tab1"]),
            FeishuBlock(
                blockId: "tab1", parentId: "p",
                children: ["c00", "c01", "c10", "c11"],
                payload: .table(.init(rowSize: 2, columnSize: 2, headerRow: true))
            ),
            cell("c00", parent: "tab1", text: "h1", textId: "t00"),
            text("t00", parent: "c00", content: "h1"),
            cell("c01", parent: "tab1", text: "h2", textId: "t01"),
            text("t01", parent: "c01", content: "h2"),
            cell("c10", parent: "tab1", text: "v1", textId: "t10"),
            text("t10", parent: "c10", content: "v1"),
            cell("c11", parent: "tab1", text: "v2", textId: "t11"),
            text("t11", parent: "c11", content: "v2"),
        ]
        let md = FeishuStructuralConverter.toMarkdown(original)
        let regenerated = FeishuStructuralConverter.toFeishuBlocks(md)
        XCTAssertEqual(payloadShapes(original), payloadShapes(regenerated))
    }

    // MARK: callout-type mapping (FeishuCalloutType)

    func testCalloutTypeReverseLookupIsTotal() {
        // Color → type round-trip identity for the canonical 5.
        for type in FeishuCalloutType.allCases {
            let resolved = FeishuCalloutType.from(
                emoji: type.emoji,
                backgroundColor: type.backgroundColor
            )
            XCTAssertEqual(resolved, type, "round-trip for \(type)")
        }
    }

    func testCalloutTypeUnknownColorFallsBackToNote() {
        let resolved = FeishuCalloutType.from(emoji: "🌟", backgroundColor: "neon-pink")
        XCTAssertEqual(resolved, .note)
    }

    // MARK: - cell with block-level child (architectural boundary)

    /// Feishu cell with a callout block inside → callout is dropped,
    /// cell renders as the leading text's inline content (or empty
    /// paragraph if the cell has only the callout). Warning carries
    /// the cell count.
    func testTableCellWithCalloutEmitsDroppedWarning() {
        // 2x1 table: cell A has [text "intro" + callout], cell B has [text "ok"].
        let blocks: [FeishuBlock] = [
            FeishuBlock(blockId: "p", parentId: nil, children: ["t"], payload: .page(.init())),
            FeishuBlock(
                blockId: "t", parentId: "p", children: ["cA", "cB"],
                payload: .table(.init(rowSize: 1, columnSize: 2, headerRow: false))
            ),
            FeishuBlock(blockId: "cA", parentId: "t", children: ["txA", "calloutA"],
                        payload: .tableCell),
            FeishuBlock(
                blockId: "txA", parentId: "cA", children: nil,
                payload: .text(.init(elements: [.textRun(.init(content: "intro"))]))
            ),
            FeishuBlock(
                blockId: "calloutA", parentId: "cA", children: nil,
                payload: .callout(.init(emoji: "💡", backgroundColor: "light-yellow"))
            ),
            FeishuBlock(blockId: "cB", parentId: "t", children: ["txB"],
                        payload: .tableCell),
            FeishuBlock(
                blockId: "txB", parentId: "cB", children: nil,
                payload: .text(.init(elements: [.textRun(.init(content: "ok"))]))
            ),
        ]

        let result = FeishuStructuralConverter.toMarkdownWithWarnings(blocks)

        // Cell A loses the callout but keeps the text.
        XCTAssertTrue(result.value.contains("intro"),
            "leading text in the affected cell must survive")
        XCTAssertTrue(result.value.contains("ok"),
            "unaffected cell must round-trip normally")
        // Exactly one warning, count = 1 (only cell A had block-level content).
        XCTAssertEqual(result.warnings.count, 1)
        guard case .tableCellBlockContentDropped(let count) = result.warnings.first else {
            XCTFail("expected tableCellBlockContentDropped, got \(result.warnings)")
            return
        }
        XCTAssertEqual(count, 1,
            "only cell A had block-level content; cell B is text-only")
    }

    /// Multiple cells with block-level children → warning aggregates
    /// to a single entry with the total count, not one per cell.
    func testTableCellWithBlockChildAggregatesAcrossCells() {
        let blocks: [FeishuBlock] = [
            FeishuBlock(blockId: "p", parentId: nil, children: ["t"], payload: .page(.init())),
            FeishuBlock(
                blockId: "t", parentId: "p", children: ["cA", "cB"],
                payload: .table(.init(rowSize: 1, columnSize: 2, headerRow: false))
            ),
            FeishuBlock(blockId: "cA", parentId: "t", children: ["calloutA"],
                        payload: .tableCell),
            FeishuBlock(
                blockId: "calloutA", parentId: "cA", children: nil,
                payload: .callout(.init(emoji: "💡", backgroundColor: "light-yellow"))
            ),
            FeishuBlock(blockId: "cB", parentId: "t", children: ["calloutB"],
                        payload: .tableCell),
            FeishuBlock(
                blockId: "calloutB", parentId: "cB", children: nil,
                payload: .callout(.init(emoji: "⚠️", backgroundColor: "light-red"))
            ),
        ]

        let result = FeishuStructuralConverter.toMarkdownWithWarnings(blocks)

        XCTAssertEqual(result.warnings.count, 1,
            "multiple affected cells must roll up to a single warning")
        guard case .tableCellBlockContentDropped(let count) = result.warnings.first else {
            XCTFail("got \(result.warnings)")
            return
        }
        XCTAssertEqual(count, 2,
            "two cells with block-level content → cellCount = 2")
    }

    /// Pure-text table cells produce no warning at all.
    func testTableCellTextOnlyEmitsNoWarning() {
        let blocks: [FeishuBlock] = [
            FeishuBlock(blockId: "p", parentId: nil, children: ["t"], payload: .page(.init())),
            FeishuBlock(
                blockId: "t", parentId: "p", children: ["cA"],
                payload: .table(.init(rowSize: 1, columnSize: 1, headerRow: false))
            ),
            FeishuBlock(blockId: "cA", parentId: "t", children: ["txA"],
                        payload: .tableCell),
            FeishuBlock(
                blockId: "txA", parentId: "cA", children: nil,
                payload: .text(.init(elements: [.textRun(.init(content: "plain"))]))
            ),
        ]

        let result = FeishuStructuralConverter.toMarkdownWithWarnings(blocks)
        let cellWarnings = result.warnings.filter {
            if case .tableCellBlockContentDropped = $0 { return true } else { return false }
        }
        XCTAssertTrue(cellWarnings.isEmpty,
            "text-only cells must not trigger the dropped-block warning")
    }

    // MARK: fixture helpers

    private func cell(_ id: String, parent: String, text: String, textId: String) -> FeishuBlock {
        FeishuBlock(blockId: id, parentId: parent, children: [textId], payload: .tableCell)
    }

    private func text(_ id: String, parent: String, content: String) -> FeishuBlock {
        FeishuBlock(
            blockId: id, parentId: parent, children: nil,
            payload: .text(.init(elements: [.textRun(.init(content: content))]))
        )
    }
}
