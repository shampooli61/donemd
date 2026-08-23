import XCTest
@testable import donemd

/// Table-driven tests for `MarkdownEngine.parse`.
///
/// Each case asserts the full Tiptap document tree that should result from a
/// given Markdown input. New cases are added by appending rows, not by adding
/// methods.
final class MarkdownEngineTests: XCTestCase {
    func testParseCases() {
        for testCase in cases {
            let actual = MarkdownEngine.parse(markdown: testCase.input)
            XCTAssertEqual(
                actual,
                testCase.expected,
                "case: \(testCase.name)\ninput:\n\(testCase.input)"
            )
        }
    }

    private struct Case {
        let name: String
        let input: String
        let expected: TiptapNode
    }

    private var cases: [Case] {
        [
            Case(
                name: "empty input → doc with single empty paragraph",
                input: "",
                expected: doc(paragraph())
            ),
            Case(
                name: "single paragraph",
                input: "hello",
                expected: doc(paragraph(text("hello")))
            ),
            Case(
                name: "heading level 1",
                input: "# Title",
                expected: doc(heading(1, text("Title")))
            ),
            Case(
                name: "heading level 2",
                input: "## Subtitle",
                expected: doc(heading(2, text("Subtitle")))
            ),
            Case(
                name: "heading level 6",
                input: "###### Six",
                expected: doc(heading(6, text("Six")))
            ),
            Case(
                name: "two paragraphs",
                input: "first\n\nsecond",
                expected: doc(
                    paragraph(text("first")),
                    paragraph(text("second"))
                )
            ),
            Case(
                name: "bold inline",
                input: "**bold**",
                expected: doc(paragraph(text("bold", bold())))
            ),
            Case(
                name: "italic inline",
                input: "*italic*",
                expected: doc(paragraph(text("italic", italic())))
            ),
            Case(
                name: "bold + italic combined (parser produces Emphasis > Strong)",
                input: "***both***",
                expected: doc(paragraph(text("both", italic(), bold())))
            ),
            Case(
                name: "inline code",
                input: "`x = 1`",
                expected: doc(paragraph(text("x = 1", code())))
            ),
            Case(
                name: "link without title",
                input: "[click](https://example.com)",
                expected: doc(paragraph(text("click", link("https://example.com"))))
            ),
            Case(
                name: "link with title",
                input: "[click](https://example.com \"Hover\")",
                expected: doc(paragraph(text("click", linkWithTitle("https://example.com", title: "Hover"))))
            ),
            // A lone image on its own line hoists OUT of the paragraph wrapper
            // to a top-level block node: `image` is `group: block` in our schema
            // (see image-node.ts + ASTConverter's standalone-image hoist), so it
            // can't legally sit inside a paragraph (`inline*`). Expected shape is
            // therefore doc → image, not doc → paragraph → image.
            Case(
                name: "image with alt",
                input: "![alt text](img.png)",
                expected: doc(image(src: "img.png", alt: "alt text"))
            ),
            Case(
                name: "image with title",
                input: "![alt](img.png \"caption\")",
                expected: doc(image(src: "img.png", alt: "alt", title: "caption"))
            ),
            Case(
                name: "image with ./assets/ disk-form path is rewritten to donemd-asset://",
                input: "![local](./assets/abc.png)",
                expected: doc(image(src: "donemd-asset://abc.png", alt: "local"))
            ),
            Case(
                name: "image with bare assets/ path (no ./) is also rewritten to donemd-asset://",
                input: "![local](assets/abc.png)",
                expected: doc(image(src: "donemd-asset://abc.png", alt: "local"))
            ),
            Case(
                name: "unordered list with two items",
                input: "- one\n- two",
                expected: doc(bulletList(
                    listItem(paragraph(text("one"))),
                    listItem(paragraph(text("two")))
                ))
            ),
            Case(
                name: "ordered list (default start)",
                input: "1. first\n2. second",
                expected: doc(orderedList(
                    items: [
                        listItem(paragraph(text("first"))),
                        listItem(paragraph(text("second")))
                    ]
                ))
            ),
            Case(
                name: "ordered list with explicit start",
                input: "5. fifth\n6. sixth",
                expected: doc(orderedList(
                    start: 5,
                    items: [
                        listItem(paragraph(text("fifth"))),
                        listItem(paragraph(text("sixth")))
                    ]
                ))
            ),
            Case(
                name: "nested bullet list",
                input: "- outer\n  - inner",
                expected: doc(bulletList(
                    listItem(
                        paragraph(text("outer")),
                        bulletList(
                            listItem(paragraph(text("inner")))
                        )
                    )
                ))
            ),
            Case(
                name: "blockquote single line",
                input: "> quoted",
                expected: doc(blockquote(paragraph(text("quoted"))))
            ),
            Case(
                name: "fenced code block without language",
                input: "```\nlet x = 1\n```",
                expected: doc(codeBlock(language: nil, code: "let x = 1"))
            ),
            Case(
                name: "fenced code block with language",
                input: "```swift\nlet x = 1\n```",
                expected: doc(codeBlock(language: "swift", code: "let x = 1"))
            ),
            Case(
                name: "horizontal rule",
                input: "---",
                expected: doc(horizontalRule())
            ),
            Case(
                // A soft break (wrapped source line) renders as a space, and
                // adjacent same-mark text runs coalesce into one node — the
                // canonical shape re-parsing serialized output yields, which
                // keeps the parse-stable invariant (#56) intact.
                name: "soft break renders as space (coalesced into one run)",
                input: "line one\nline two",
                expected: doc(paragraph(
                    text("line one line two")
                ))
            ),
            Case(
                name: "hard break (backslash + newline)",
                input: "first\\\nsecond",
                expected: doc(paragraph(
                    text("first"),
                    hardBreak(),
                    text("second")
                ))
            ),
            Case(
                name: "mixed inline marks in paragraph",
                input: "go **fast** and *slow*, see [docs](u) or `code`",
                expected: doc(paragraph(
                    text("go "),
                    text("fast", bold()),
                    text(" and "),
                    text("slow", italic()),
                    text(", see "),
                    text("docs", link("u")),
                    text(" or "),
                    text("code", code())
                ))
            ),

            // GFM extensions (Slice 5)

            Case(
                name: "strikethrough inline",
                input: "~~gone~~",
                expected: doc(paragraph(text("gone", strike())))
            ),
            Case(
                name: "task list — checked + unchecked",
                input: "- [ ] todo\n- [x] done",
                expected: doc(taskList(
                    taskItem(checked: false, paragraph(text("todo"))),
                    taskItem(checked: true, paragraph(text("done")))
                ))
            ),
            Case(
                name: "task list — mixed item with no checkbox coerced to unchecked",
                input: "- [ ] todo\n- plain item\n- [x] done",
                expected: doc(taskList(
                    taskItem(checked: false, paragraph(text("todo"))),
                    taskItem(checked: false, paragraph(text("plain item"))),
                    taskItem(checked: true, paragraph(text("done")))
                ))
            ),
            Case(
                name: "GFM table — header + two rows",
                input: """
                | name | role |
                |------|------|
                | a    | dev  |
                | b    | ux   |
                """,
                expected: doc(table(
                    tableRow(
                        tableHeader(paragraph(text("name"))),
                        tableHeader(paragraph(text("role")))
                    ),
                    tableRow(
                        tableCell(paragraph(text("a"))),
                        tableCell(paragraph(text("dev")))
                    ),
                    tableRow(
                        tableCell(paragraph(text("b"))),
                        tableCell(paragraph(text("ux")))
                    )
                ))
            ),

            // raw_markdown_block fallback (Slice 6)

            Case(
                name: "block-level HTML → raw_markdown_block",
                input: "<details>\n<summary>Click</summary>\nhidden\n</details>",
                expected: doc(rawBlock("<details>\n<summary>Click</summary>\nhidden\n</details>"))
            ),
            Case(
                name: "details element with empty body → raw_markdown_block",
                input: "<div class=\"x\">\n  inner\n</div>",
                expected: doc(rawBlock("<div class=\"x\">\n  inner\n</div>"))
            ),

            // Local video (#88): <video> HTMLBlock → video node, disk src
            // rewritten to the runtime donemd-asset:// scheme.

            Case(
                name: "canonical <video> → video node (runtime src)",
                input: "<video controls src=\"./assets/abc.mp4\"></video>",
                expected: doc(video(src: "donemd-asset://abc.mp4"))
            ),
            Case(
                name: "bare assets/ path <video> also parses to video node",
                input: "<video src=\"assets/def.mov\"></video>",
                expected: doc(video(src: "donemd-asset://def.mov"))
            ),
            Case(
                name: "<video> without src falls through to raw_markdown_block",
                input: "<video controls></video>",
                expected: doc(rawBlock("<video controls></video>"))
            ),

            // GitHub callout (Phase 2 / Slice 1 #23)

            Case(
                name: "callout note: > [!NOTE] header + body paragraph",
                input: "> [!NOTE]\n> body text",
                expected: doc(callout("note", paragraph(text("body text"))))
            ),
            Case(
                name: "callout tip type",
                input: "> [!TIP]\n> tipping",
                expected: doc(callout("tip", paragraph(text("tipping"))))
            ),
            Case(
                name: "callout important type",
                input: "> [!IMPORTANT]\n> imp",
                expected: doc(callout("important", paragraph(text("imp"))))
            ),
            Case(
                name: "callout warning type",
                input: "> [!WARNING]\n> warn",
                expected: doc(callout("warning", paragraph(text("warn"))))
            ),
            Case(
                name: "callout caution type",
                input: "> [!CAUTION]\n> careful",
                expected: doc(callout("caution", paragraph(text("careful"))))
            ),
            Case(
                name: "callout case-insensitive parse: lowercase [!note]",
                input: "> [!note]\n> body",
                expected: doc(callout("note", paragraph(text("body"))))
            ),
            Case(
                name: "callout case-insensitive parse: mixed-case [!Warning]",
                input: "> [!Warning]\n> body",
                expected: doc(callout("warning", paragraph(text("body"))))
            ),
            Case(
                name: "callout multi-paragraph body",
                input: "> [!NOTE]\n> first paragraph\n>\n> second paragraph",
                expected: doc(callout(
                    "note",
                    paragraph(text("first paragraph")),
                    paragraph(text("second paragraph"))
                ))
            ),
            Case(
                name: "callout with nested unordered list in body",
                input: "> [!TIP]\n> intro\n>\n> - one\n> - two",
                expected: doc(callout(
                    "tip",
                    paragraph(text("intro")),
                    bulletList(
                        listItem(paragraph(text("one"))),
                        listItem(paragraph(text("two")))
                    )
                ))
            ),

            // Math (Phase 5 M2 / Slice 2 #74)
            Case(
                name: "inline math: $x$",
                input: "$x$",
                expected: doc(paragraph(mathInline("x")))
            ),
            Case(
                name: "inline math mid-sentence",
                input: "a $x+y$ b",
                expected: doc(paragraph(text("a "), mathInline("x+y"), text(" b")))
            ),
            Case(
                name: "two inline math in one run",
                input: "$a$ and $b$",
                expected: doc(paragraph(mathInline("a"), text(" and "), mathInline("b")))
            ),
            Case(
                name: "block math three-line form",
                input: "$$\nx\n$$",
                expected: doc(mathBlock("x"))
            ),
            Case(
                name: "block math single-line form",
                input: "$$x$$",
                expected: doc(mathBlock("x"))
            ),
            Case(
                name: "block math multi-line body preserved",
                input: "$$\n\\begin{aligned}\na&=b\n\\end{aligned}\n$$",
                expected: doc(mathBlock("\\begin{aligned}\na&=b\n\\end{aligned}"))
            ),
            Case(
                name: "dollar amounts stay literal ($5 and $10)",
                input: "cost is $5 and $10 total",
                expected: doc(paragraph(text("cost is $5 and $10 total")))
            ),
            Case(
                name: "spaces adjacent to $ → not math",
                input: "$ x $",
                expected: doc(paragraph(text("$ x $")))
            ),
            Case(
                name: "escaped dollar → literal $ (swift-markdown unescapes before us)",
                input: "price \\$5",
                expected: doc(paragraph(text("price $5")))
            ),
            Case(
                name: "empty $$ → literal paragraph, not math_block",
                input: "$$$$",
                expected: doc(paragraph(text("$$$$")))
            ),
            Case(
                name: "unbalanced single $ → literal",
                input: "a $x here",
                expected: doc(paragraph(text("a $x here")))
            ),
            Case(
                name: "inline math in list item",
                input: "- $x$",
                expected: doc(bulletList(listItem(paragraph(mathInline("x")))))
            ),
            Case(
                name: "inline math in heading",
                input: "# $E=mc^2$",
                expected: doc(heading(1, mathInline("E=mc^2")))
            ),
            Case(
                name: "block math adjacent to text paragraph",
                input: "text\n\n$$x$$",
                expected: doc(paragraph(text("text")), mathBlock("x"))
            ),
        ]
    }
}

// MARK: - Test DSL

private func doc(_ children: TiptapNode...) -> TiptapNode {
    TiptapNode(type: "doc", content: children)
}

private func paragraph(_ children: TiptapNode...) -> TiptapNode {
    TiptapNode(type: "paragraph", content: children.isEmpty ? nil : children)
}

private func heading(_ level: Int, _ children: TiptapNode...) -> TiptapNode {
    TiptapNode(type: "heading", attrs: ["level": .int(level)], content: children)
}

private func bulletList(_ items: TiptapNode...) -> TiptapNode {
    TiptapNode(type: "bulletList", content: items)
}

private func orderedList(start: Int? = nil, items: [TiptapNode]) -> TiptapNode {
    let attrs: [String: AttrValue]? = start.map { ["start": .int($0)] }
    return TiptapNode(type: "orderedList", attrs: attrs, content: items)
}

private func listItem(_ children: TiptapNode...) -> TiptapNode {
    TiptapNode(type: "listItem", content: children)
}

private func blockquote(_ children: TiptapNode...) -> TiptapNode {
    TiptapNode(type: "blockquote", content: children)
}

private func codeBlock(language: String?, code: String) -> TiptapNode {
    let attrs: [String: AttrValue]? = language.map { ["language": .string($0)] }
    let textNodes = code.isEmpty ? [] : [TiptapNode(type: "text", text: code)]
    return TiptapNode(type: "codeBlock", attrs: attrs, content: textNodes)
}

private func horizontalRule() -> TiptapNode { TiptapNode(type: "horizontalRule") }
private func hardBreak() -> TiptapNode { TiptapNode(type: "hardBreak") }

private func image(src: String, alt: String? = nil, title: String? = nil) -> TiptapNode {
    var attrs: [String: AttrValue] = ["src": .string(src)]
    if let alt = alt { attrs["alt"] = .string(alt) }
    if let title = title { attrs["title"] = .string(title) }
    return TiptapNode(type: "image", attrs: attrs)
}

private func video(src: String) -> TiptapNode {
    TiptapNode(type: "video", attrs: ["src": .string(src)])
}

private func text(_ s: String, _ marks: TiptapMark...) -> TiptapNode {
    TiptapNode.text(s, marks: marks.isEmpty ? nil : marks)
}

private func bold() -> TiptapMark { TiptapMark(type: "bold") }
private func italic() -> TiptapMark { TiptapMark(type: "italic") }
private func code() -> TiptapMark { TiptapMark(type: "code") }
private func strike() -> TiptapMark { TiptapMark(type: "strike") }

// GFM table / task list helpers

private func table(_ rows: TiptapNode...) -> TiptapNode {
    TiptapNode(type: "table", content: rows)
}
private func tableRow(_ cells: TiptapNode...) -> TiptapNode {
    TiptapNode(type: "tableRow", content: cells)
}
private func tableHeader(_ children: TiptapNode...) -> TiptapNode {
    TiptapNode(type: "tableHeader", content: children)
}
private func tableCell(_ children: TiptapNode...) -> TiptapNode {
    TiptapNode(type: "tableCell", content: children)
}
private func taskList(_ items: TiptapNode...) -> TiptapNode {
    TiptapNode(type: "taskList", content: items)
}
private func taskItem(checked: Bool, _ children: TiptapNode...) -> TiptapNode {
    TiptapNode(type: "taskItem", attrs: ["checked": .bool(checked)], content: children)
}

private func rawBlock(_ raw: String) -> TiptapNode {
    TiptapNode(type: "raw_markdown_block", attrs: ["raw": .string(raw)])
}

private func mathInline(_ latex: String) -> TiptapNode {
    TiptapNode(type: "math_inline", attrs: ["latex": .string(latex)])
}

private func mathBlock(_ latex: String) -> TiptapNode {
    TiptapNode(type: "math_block", attrs: ["latex": .string(latex)])
}

private func callout(_ type: String, _ children: TiptapNode...) -> TiptapNode {
    TiptapNode(type: "callout", attrs: ["type": .string(type)], content: children)
}

private func link(_ href: String) -> TiptapMark {
    TiptapMark(type: "link", attrs: ["href": .string(href)])
}

private func linkWithTitle(_ href: String, title: String) -> TiptapMark {
    TiptapMark(type: "link", attrs: [
        "href": .string(href),
        "title": .string(title)
    ])
}
