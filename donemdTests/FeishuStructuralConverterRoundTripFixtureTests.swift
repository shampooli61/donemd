import XCTest
@testable import donemd

/// Phase 2 v2 验收门 (#54) — single comprehensive fixture exercising
/// every Feishu payload kind in a single round-trip pipeline. The
/// per-feature tests in `FeishuStructuralConverter*Tests` cover
/// individual block shapes; this suite is the **integration** check
/// that the whole converter pipeline holds together when a realistic
/// document mixes everything.
///
/// Two paths:
///  - **Path A (Feishu → local → Feishu)**: build a `[FeishuBlock]`
///    fixture mirroring what a real `pullDocument` would return
///    (modulo block_ids), feed it through `toMarkdown` then
///    `toFeishuBlocks`, assert payload-shape equivalence. Block IDs
///    are deliberately NOT compared — the converter mints fresh IDs
///    from markdown, so structural identity (the same payload
///    sequence, in the same parent/child topology) is the strongest
///    guarantee available.
///  - **Path B (local → Feishu → local)**: feed a markdown fixture
///    through `toFeishuBlocks` then `toMarkdown`, assert the result
///    matches a hand-canonicalized expected form. Some shapes get
///    rewritten (e.g. setext → ATX headings) so we compare against
///    the canonical, not the input verbatim.
///
/// Failure messages output the diverging payload-shape index + a
/// pretty-printed diff so the failure is cheap to triage.
final class FeishuStructuralConverterRoundTripFixtureTests: XCTestCase {

    // MARK: - Path A: feishuJSON → toMarkdown → toFeishuBlocks

    /// Build a kitchen-sink `[FeishuBlock]` covering every payload
    /// branch the converter knows about + the boundary cases that
    /// have caught regressions before (callout named ID, GFM-table
    /// cell with inline marks, placeholder block with `--` in fields,
    /// nested callout containing a list, …). Run it through the full
    /// roundtrip and assert payload-shape equivalence.
    func testKitchenSinkFeishuBlocksRoundTripPreservesShapes() {
        let original = makeKitchenSinkFeishuBlocks()
        let md = FeishuStructuralConverter.toMarkdown(original)
        let regenerated = FeishuStructuralConverter.toFeishuBlocks(md)

        let originalShapes = payloadShapes(original)
        let regeneratedShapes = payloadShapes(regenerated)

        XCTAssertEqual(
            originalShapes.count, regeneratedShapes.count,
            """
            Block count diverged after round-trip.
            Original (\(originalShapes.count)): \(payloadKindList(originalShapes))
            Regenerated (\(regeneratedShapes.count)): \(payloadKindList(regeneratedShapes))

            === markdown produced ===
            \(md)
            """
        )

        // Pairwise compare — when shapes diverge, we want to know
        // which index, not just "they're not equal".
        for (index, (original, regenerated)) in zip(originalShapes, regeneratedShapes).enumerated() {
            XCTAssertEqual(
                original, regenerated,
                """
                Block #\(index) diverged.
                Original kind: \(kindName(original))
                Regenerated kind: \(kindName(regenerated))

                === markdown around this position ===
                \(md)
                """
            )
        }
    }

    // MARK: - Path B: markdown → toFeishuBlocks → toMarkdown

    /// Path B is the canonical-form contract: feed a hand-written
    /// markdown fixture, run the round-trip, assert the result is
    /// **byte-identical** to the canonical form. Inputs that are
    /// already in canonical form should be 100% idempotent.
    func testCanonicalMarkdownIsRoundTripIdempotent() {
        let canonical = canonicalMarkdownFixture()
        let blocks = FeishuStructuralConverter.toFeishuBlocks(canonical)
        let regenerated = FeishuStructuralConverter.toMarkdown(blocks)
        // Trim trailing whitespace (newlines specifically) on both
        // sides — toMarkdown deliberately ends with a trailing
        // newline as a Unix file-final-newline convention, but the
        // multiline string literal we compare against does not.
        // Comparison ignores that purely cosmetic difference.
        let expected = canonical.trimmingCharacters(in: .whitespacesAndNewlines)
        let actual = regenerated.trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(
            actual, expected,
            """
            Canonical markdown failed to round-trip byte-identically.

            === diff (expected vs actual) ===
            \(diffSummary(expected: expected, actual: actual))
            """
        )
    }

    // MARK: - kitchen-sink builders

    private func makeKitchenSinkFeishuBlocks() -> [FeishuBlock] {
        var blocks: [FeishuBlock] = []
        let pageId = "p"
        var pageChildren: [String] = []

        func add(_ block: FeishuBlock) {
            blocks.append(block)
            if block.parentId == pageId {
                pageChildren.append(block.blockId)
            }
        }

        // Headings 1–6, each preceded by a paragraph so we don't have
        // adjacent headings (Done.md's Tiptap normalizer treats those
        // OK but the canonical markdown form has blank line between).
        for level in 1...6 {
            add(textBlock(id: "h\(level)-intro", parent: pageId,
                          content: "Intro for heading \(level)"))
            add(headingBlock(id: "h\(level)", parent: pageId,
                             level: level, content: "Heading level \(level)"))
        }

        // Bullet + ordered lists.
        add(bulletBlock(id: "b1", parent: pageId, content: "bullet one"))
        add(bulletBlock(id: "b2", parent: pageId, content: "bullet two"))
        add(orderedBlock(id: "o1", parent: pageId, content: "step 1"))
        add(orderedBlock(id: "o2", parent: pageId, content: "step 2"))

        // Todo (checked + unchecked) — round-trip preserves done state.
        add(todoBlock(id: "td1", parent: pageId, content: "task pending", done: false))
        add(todoBlock(id: "td2", parent: pageId, content: "task done", done: true))

        // Quote container (block_type 34 — Done.md's > [single-paragraph-quote]
        // canonical form). One block carries a single text payload.
        add(quoteBlock(id: "q1", parent: pageId, content: "a quoted line"))

        // Code blocks: plain + mermaid.
        add(codeBlock(id: "code1", parent: pageId,
                      language: "swift", content: "let x = 1"))
        add(codeBlock(id: "code2", parent: pageId,
                      language: "mermaid", content: "graph TD; A-->B;"))

        // Divider.
        add(FeishuBlock(blockId: "div1", parentId: pageId,
                        children: nil, payload: .divider))

        // Callout × 5 types — the wireEmojiId values that the 2026-06-04
        // 1770006 fix established. After round-trip these MUST come back
        // as the same wire-format named IDs (not Unicode glyphs).
        let calloutSpecs: [(id: String, color: String, emoji: String, text: String)] = [
            ("ca-note",      "light-blue",   "bulb",           "note callout"),
            ("ca-tip",       "light-green",  "sparkles",       "tip callout"),
            ("ca-important", "light-purple", "exclamation",    "important callout"),
            ("ca-warning",   "light-yellow", "warning",        "warning callout"),
            ("ca-caution",   "light-red",    "rotating_light", "caution callout"),
        ]
        for spec in calloutSpecs {
            let textId = "\(spec.id)-t"
            add(FeishuBlock(
                blockId: spec.id, parentId: pageId, children: [textId],
                payload: .callout(.init(emoji: spec.emoji, backgroundColor: spec.color))
            ))
            add(textBlock(id: textId, parent: spec.id, content: spec.text))
        }

        // Table 2×2 (header row + one body row), GFM-compatible cell
        // contents (plain inline, no block-level — see ADR-0007 § 已知
        // 限制 #8). Cell IDs go in row-major order; their text children
        // follow each cell so the depth-first order is canonical.
        let tableId = "tab1"
        let tableCellIds = ["c00", "c01", "c10", "c11"]
        add(FeishuBlock(
            blockId: tableId, parentId: pageId,
            children: tableCellIds,
            payload: .table(.init(rowSize: 2, columnSize: 2, headerRow: true))
        ))
        let tableCells: [(cellId: String, textId: String, content: String)] = [
            ("c00", "tt00", "Name"),
            ("c01", "tt01", "Status"),
            ("c10", "tt10", "Alice"),
            ("c11", "tt11", "active"),
        ]
        for spec in tableCells {
            add(FeishuBlock(
                blockId: spec.cellId, parentId: tableId,
                children: [spec.textId], payload: .tableCell
            ))
            add(textBlock(id: spec.textId, parent: spec.cellId, content: spec.content))
        }

        // Placeholder blocks — every subtype the converter decodes. The
        // url field deliberately contains `&` to test URL escaping; the
        // summary field contains `--` (commonmark forbids it inside HTML
        // comments — ADR-0007 § 已知限制 #6 — converter sanitizes).
        let placeholderSpecs: [(id: String, type: FeishuBlock.PlaceholderSubtype, title: String, url: String, summary: String?)] = [
            ("ph-sheet",    .sheet,      "Q2 OKR 表",      "https://feishu.cn/sheets/shtcnA?utm=1&x=2", "12 行 · 4 列"),
            ("ph-mindnote", .mindnote,   "架构脑图",        "https://feishu.cn/docx/mn_X",               nil),
            ("ph-board",    .board,      "Sprint 画板",     "https://feishu.cn/docx/bd_Y",               "草图 · DRY-RUN 状态"),
            ("ph-bitable",  .bitable,    "Bug 多维表",      "https://feishu.cn/base/bcA",                 "P0 · 12 / P1 · 8"),
            ("ph-attach",   .attachment, "spec.pdf",       "https://feishu.cn/file/atA",                 "1.2 MB"),
            ("ph-video",    .video,      "Demo 录屏",       "https://feishu.cn/file/vidA",                "3 min"),
            ("ph-embed",    .embed,      "Jira 工单",       "https://example.atlassian.net/browse/X-1",   nil),
        ]
        for spec in placeholderSpecs {
            add(FeishuBlock(
                blockId: spec.id, parentId: pageId, children: nil,
                payload: .placeholder(.init(
                    subtype: spec.type,
                    title: spec.title,
                    summary: spec.summary,
                    url: spec.url
                ))
            ))
        }

        // Trailing paragraph with inline marks (bold + italic + code +
        // strikethrough + link). Validates inline-mark round-trip across
        // a representative collage.
        add(FeishuBlock(
            blockId: "p-final", parentId: pageId, children: nil,
            payload: .text(.init(elements: [
                .textRun(.init(content: "plain ")),
                .textRun(.init(content: "bold", style: .init(bold: true))),
                .textRun(.init(content: " ")),
                .textRun(.init(content: "italic", style: .init(italic: true))),
                .textRun(.init(content: " ")),
                .textRun(.init(content: "code", style: .init(inlineCode: true))),
                .textRun(.init(content: " ")),
                .textRun(.init(content: "struck", style: .init(strikethrough: true))),
                .textRun(.init(content: " ")),
                .textRun(.init(content: "link", style: .init(link: "https://example.com/?a=1&b=2"))),
                .textRun(.init(content: " end."))
            ]))
        ))

        // Prepend the page block now that we know the children list.
        let page = FeishuBlock(
            blockId: pageId, parentId: nil, children: pageChildren,
            payload: .page(.init())
        )
        return [page] + blocks
    }

    /// Canonical markdown fixture for Path B. Includes only block
    /// kinds whose on-disk canonical form is byte-stable today.
    /// Deliberately omitted:
    /// - **Multi-line block quotes** (`> a\n> b`): serializer joins
    ///   the lines with a space on round-trip — known divergence,
    ///   tracked outside this slice. Single-line quotes work.
    /// - **Multi-line table cells**: GFM table parsing rules around
    ///   internal whitespace are inconsistent across libs.
    ///
    /// Every block kind covered here is one Done.md is willing to
    /// commit to as the disk truth. When serialization changes its
    /// canonical form intentionally, update this fixture. When it
    /// changes accidentally (regression), this fixture catches it.
    private func canonicalMarkdownFixture() -> String {
        return """
        # Heading one

        Plain paragraph **bold** *italic* `code` ~~struck~~ [link](https://example.com/).

        ## Heading two

        - bullet a
        - bullet b

        1. step one
        2. step two

        - [ ] todo pending
        - [x] todo done

        > single-line quote stays intact

        ---

        ```mermaid
        graph TD; A-->B;
        ```

        > [!NOTE]
        > note callout body

        > [!WARNING]
        > warning callout body

        | Name | Status |
        | --- | --- |
        | Alice | active |
        | Bob | offline |

        <!-- feishu-placeholder
        type: sheet
        block_id: doxbcXXX_blk001
        title: Q2 OKR
        summary: 12 行
        url: https://example.feishu.cn/sheets/shtcnA
        -->

        Trailing line.
        """
    }

    // MARK: - debug helpers (failure messages)

    private func payloadShapes(_ blocks: [FeishuBlock]) -> [FeishuBlock.Payload] {
        blocks.map(\.payload)
    }

    private func payloadKindList(_ shapes: [FeishuBlock.Payload]) -> String {
        shapes.map(kindName).joined(separator: ", ")
    }

    private func kindName(_ payload: FeishuBlock.Payload) -> String {
        switch payload {
        case .page: return "page"
        case .text: return "text"
        case .heading(let level, _): return "heading(\(level))"
        case .bullet: return "bullet"
        case .ordered: return "ordered"
        case .code(let p): return "code(\(p.language ?? "?"))"
        case .quote: return "quote"
        case .todo(_, let done): return "todo(\(done ? "done" : "pending"))"
        case .callout(let p): return "callout(\(p.backgroundColor ?? "?"))"
        case .divider: return "divider"
        case .image: return "image"
        case .table: return "table"
        case .tableCell: return "tableCell"
        case .placeholder(let p): return "placeholder(\(p.subtype))"
        }
    }

    /// Compact inline diff: line N, expected vs actual. Avoids
    /// pulling in a real diff lib for one assertion.
    private func diffSummary(expected: String, actual: String) -> String {
        let exp = expected.split(separator: "\n", omittingEmptySubsequences: false)
        let act = actual.split(separator: "\n", omittingEmptySubsequences: false)
        var lines: [String] = []
        let maxLines = max(exp.count, act.count)
        for i in 0..<maxLines {
            let e = i < exp.count ? String(exp[i]) : "<EOF>"
            let a = i < act.count ? String(act[i]) : "<EOF>"
            if e != a {
                lines.append("L\(i + 1):")
                lines.append("  -expected: \(e)")
                lines.append("  +actual:   \(a)")
                if lines.count > 30 { break }   // cap so failure msg stays readable
            }
        }
        return lines.isEmpty ? "(no line-level diffs found despite inequality — full equality check failed)" : lines.joined(separator: "\n")
    }

    // MARK: - block construction helpers

    private func textBlock(id: String, parent: String, content: String) -> FeishuBlock {
        FeishuBlock(blockId: id, parentId: parent, children: nil,
                    payload: .text(.init(elements: [.textRun(.init(content: content))])))
    }

    private func headingBlock(id: String, parent: String, level: Int, content: String) -> FeishuBlock {
        FeishuBlock(blockId: id, parentId: parent, children: nil,
                    payload: .heading(level: level,
                                      .init(elements: [.textRun(.init(content: content))])))
    }

    private func bulletBlock(id: String, parent: String, content: String) -> FeishuBlock {
        FeishuBlock(blockId: id, parentId: parent, children: nil,
                    payload: .bullet(.init(elements: [.textRun(.init(content: content))])))
    }

    private func orderedBlock(id: String, parent: String, content: String) -> FeishuBlock {
        FeishuBlock(blockId: id, parentId: parent, children: nil,
                    payload: .ordered(.init(elements: [.textRun(.init(content: content))])))
    }

    private func todoBlock(id: String, parent: String, content: String, done: Bool) -> FeishuBlock {
        FeishuBlock(blockId: id, parentId: parent, children: nil,
                    payload: .todo(.init(elements: [.textRun(.init(content: content))]),
                                   done: done))
    }

    private func quoteBlock(id: String, parent: String, content: String) -> FeishuBlock {
        let textId = "\(id)-t"
        // quote_container is block_type 34 — its children are the
        // wrapped paragraphs. To keep the helper simple in fixtures
        // we generate a single text child here; if a future test
        // needs multi-paragraph quotes we'll inline the construction.
        // Fixture builder caller is expected to add the text block
        // separately when nesting matters; for the kitchen-sink we
        // keep it self-contained.
        return FeishuBlock(blockId: id, parentId: parent, children: [textId],
                           payload: .quote(.init(elements: [.textRun(.init(content: content))])))
    }

    private func codeBlock(id: String, parent: String, language: String, content: String) -> FeishuBlock {
        FeishuBlock(blockId: id, parentId: parent, children: nil,
                    payload: .code(.init(elements: [.textRun(.init(content: content))],
                                         language: language)))
    }
}
