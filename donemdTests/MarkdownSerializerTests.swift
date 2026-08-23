import XCTest
@testable import donemd

/// Direct serialization tests — given a hand-built Tiptap doc, assert the
/// exact Markdown bytes that come out.
final class MarkdownSerializerTests: XCTestCase {
    func testSerializeCases() {
        for testCase in cases {
            let actual = MarkdownEngine.serialize(document: testCase.input)
            XCTAssertEqual(
                actual,
                testCase.expected,
                "case: \(testCase.name)\nexpected:\n\(testCase.expected)\nactual:\n\(actual)"
            )
        }
    }

    private struct Case {
        let name: String
        let input: TiptapNode
        let expected: String
    }

    private var cases: [Case] {
        [
            Case(
                name: "single paragraph",
                input: doc(paragraph(text("hello"))),
                expected: "hello\n"
            ),
            Case(
                name: "two paragraphs separated by blank line",
                input: doc(paragraph(text("first")), paragraph(text("second"))),
                expected: "first\n\nsecond\n"
            ),
            Case(
                name: "heading levels 1-3",
                input: doc(
                    heading(1, text("h1")),
                    heading(2, text("h2")),
                    heading(3, text("h3"))
                ),
                expected: "# h1\n\n## h2\n\n### h3\n"
            ),
            Case(
                name: "heading level 6",
                input: doc(heading(6, text("six"))),
                expected: "###### six\n"
            ),
            Case(
                name: "bold inline",
                input: doc(paragraph(text("bold", bold()))),
                expected: "**bold**\n"
            ),
            Case(
                name: "italic inline",
                input: doc(paragraph(text("italic", italic()))),
                expected: "*italic*\n"
            ),
            Case(
                name: "bold containing italic (italic mark inner, bold outer)",
                input: doc(paragraph(text("both", italic(), bold()))),
                expected: "***both***\n"
            ),
            Case(
                name: "inline code",
                input: doc(paragraph(text("x = 1", code()))),
                expected: "`x = 1`\n"
            ),
            Case(
                name: "link no title",
                input: doc(paragraph(text("anthropic", link("https://anthropic.com")))),
                expected: "[anthropic](https://anthropic.com)\n"
            ),
            Case(
                name: "link with title",
                input: doc(paragraph(text("docs", linkTitled("https://x", title: "Hover")))),
                expected: "[docs](https://x \"Hover\")\n"
            ),
            Case(
                name: "image basic",
                input: doc(paragraph(image(src: "./assets/a.png", alt: "alt text"))),
                expected: "![alt text](./assets/a.png)\n"
            ),
            Case(
                name: "image with title",
                input: doc(paragraph(image(src: "./assets/a.png", alt: "alt", title: "tooltip"))),
                expected: "![alt](./assets/a.png \"tooltip\")\n"
            ),
            Case(
                name: "image runtime URL gets rewritten to disk path",
                input: doc(paragraph(image(src: "donemd-asset://abc.png", alt: ""))),
                expected: "![](./assets/abc.png)\n"
            ),
            Case(
                name: "video node serializes to canonical <video> (disk src)",
                input: doc(video(src: "donemd-asset://abc123.mp4")),
                expected: "<video controls src=\"./assets/abc123.mp4\"></video>\n"
            ),
            Case(
                name: "bullet list two items",
                input: doc(bulletList(
                    listItem(paragraph(text("one"))),
                    listItem(paragraph(text("two")))
                )),
                expected: "- one\n- two\n"
            ),
            Case(
                name: "ordered list default start",
                input: doc(orderedList(items: [
                    listItem(paragraph(text("alpha"))),
                    listItem(paragraph(text("beta")))
                ])),
                expected: "1. alpha\n2. beta\n"
            ),
            Case(
                name: "ordered list explicit start",
                input: doc(orderedList(start: 5, items: [
                    listItem(paragraph(text("five"))),
                    listItem(paragraph(text("six")))
                ])),
                expected: "5. five\n6. six\n"
            ),
            Case(
                name: "nested bullet list (one outer, one inner)",
                input: doc(bulletList(
                    listItem(
                        paragraph(text("outer")),
                        bulletList(listItem(paragraph(text("inner"))))
                    )
                )),
                expected: "- outer\n\n  - inner\n"
            ),
            Case(
                name: "blockquote single line",
                input: doc(blockquote(paragraph(text("quoted")))),
                expected: "> quoted\n"
            ),
            Case(
                name: "blockquote multi-line",
                input: doc(blockquote(
                    paragraph(text("first line")),
                    paragraph(text("second line"))
                )),
                expected: "> first line\n>\n> second line\n"
            ),
            Case(
                name: "fenced code block without language",
                input: doc(codeBlock(language: nil, code: "let x = 1")),
                expected: "```\nlet x = 1\n```\n"
            ),
            Case(
                name: "fenced code block with language",
                input: doc(codeBlock(language: "swift", code: "let x = 1")),
                expected: "```swift\nlet x = 1\n```\n"
            ),
            Case(
                name: "horizontal rule",
                input: doc(horizontalRule()),
                expected: "---\n"
            ),
            Case(
                name: "hard break inside paragraph",
                input: doc(paragraph(text("first"), hardBreak(), text("second"))),
                expected: "first\\\nsecond\n"
            ),
            Case(
                name: "mixed inline marks in paragraph",
                input: doc(paragraph(
                    text("go "),
                    text("fast", bold()),
                    text(" and "),
                    text("slow", italic()),
                    text(", see "),
                    text("docs", link("u")),
                    text(" or "),
                    text("code", code())
                )),
                expected: "go **fast** and *slow*, see [docs](u) or `code`\n"
            ),
            Case(
                name: "empty doc → minimal trailing newline",
                input: doc(paragraph()),
                expected: "\n"
            ),

            // GFM extensions (Slice 5)

            Case(
                name: "strikethrough mark",
                input: doc(paragraph(text("gone", strike()))),
                expected: "~~gone~~\n"
            ),
            Case(
                name: "task list — checked + unchecked",
                input: doc(taskList(
                    taskItem(checked: false, paragraph(text("todo"))),
                    taskItem(checked: true, paragraph(text("done")))
                )),
                expected: "- [ ] todo\n- [x] done\n"
            ),
            Case(
                name: "GFM table — header + two rows, no padding",
                input: doc(table(
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
                )),
                expected: """
                | name | role |
                | --- | --- |
                | a | dev |
                | b | ux |

                """
            ),
            Case(
                // Regression (#76): a header cell whose first block is a
                // `heading` (user picked a heading-size for the header) must
                // still serialize its text. The old paragraph-only path
                // dropped it — MD source blank + data loss on save.
                name: "GFM table — heading in header cell serializes its text",
                input: doc(table(
                    tableRow(
                        tableHeader(heading(3, text("name"))),
                        tableHeader(heading(3, text("role")))
                    ),
                    tableRow(
                        tableCell(paragraph(text("a"))),
                        tableCell(paragraph(text("dev")))
                    )
                )),
                expected: """
                | name | role |
                | --- | --- |
                | a | dev |

                """
            ),

            // raw_markdown_block fallback (Slice 6)

            Case(
                name: "raw_markdown_block emits raw verbatim",
                input: doc(rawBlock("<details><summary>x</summary>y</details>")),
                expected: "<details><summary>x</summary>y</details>\n"
            ),
            Case(
                name: "raw_markdown_block multiline preserves internal newlines",
                input: doc(rawBlock("<div>\n  line1\n  line2\n</div>")),
                expected: "<div>\n  line1\n  line2\n</div>\n"
            ),

            // GitHub callout (Phase 2 / Slice 1 #23) — TYPE always uppercased on disk
            // for GitHub renderer compatibility (only ALL-CAPS triggers the callout box).

            Case(
                name: "callout note: single paragraph body",
                input: doc(callout("note", paragraph(text("body text")))),
                expected: "> [!NOTE]\n> body text\n"
            ),
            Case(
                name: "callout tip type uppercased",
                input: doc(callout("tip", paragraph(text("hi")))),
                expected: "> [!TIP]\n> hi\n"
            ),
            Case(
                name: "callout important type uppercased",
                input: doc(callout("important", paragraph(text("imp")))),
                expected: "> [!IMPORTANT]\n> imp\n"
            ),
            Case(
                name: "callout warning type uppercased",
                input: doc(callout("warning", paragraph(text("warn")))),
                expected: "> [!WARNING]\n> warn\n"
            ),
            Case(
                name: "callout caution type uppercased",
                input: doc(callout("caution", paragraph(text("careful")))),
                expected: "> [!CAUTION]\n> careful\n"
            ),
            Case(
                name: "callout multi-paragraph body",
                input: doc(callout(
                    "note",
                    paragraph(text("first paragraph")),
                    paragraph(text("second paragraph"))
                )),
                expected: "> [!NOTE]\n> first paragraph\n>\n> second paragraph\n"
            ),
            Case(
                name: "callout with bullet list in body",
                input: doc(callout(
                    "tip",
                    paragraph(text("intro")),
                    bulletList(
                        listItem(paragraph(text("one"))),
                        listItem(paragraph(text("two")))
                    )
                )),
                expected: "> [!TIP]\n> intro\n>\n> - one\n> - two\n"
            ),

            // Math (Phase 5 M2 / Slice 2 #74)
            Case(
                name: "inline math → $latex$",
                input: doc(paragraph(mathInline("x"))),
                expected: "$x$\n"
            ),
            Case(
                name: "inline math between text",
                input: doc(paragraph(text("a "), mathInline("x+y"), text(" b"))),
                expected: "a $x+y$ b\n"
            ),
            Case(
                name: "block math → three-line form",
                input: doc(mathBlock("x")),
                expected: "$$\nx\n$$\n"
            ),
            Case(
                name: "block math multi-line body preserved",
                input: doc(mathBlock("\\begin{aligned}\na&=b\n\\end{aligned}")),
                expected: "$$\n\\begin{aligned}\na&=b\n\\end{aligned}\n$$\n"
            ),
        ]
    }
}

/// Round-trip / fixed-point tests — given canonical Markdown, parse + serialize
/// must produce the same bytes.
final class MarkdownEngineRoundTripTests: XCTestCase {
    /// Pure CommonMark fixtures (no GFM yet — Slice 5 (#8) adds those).
    private let canonicalFixtures: [(name: String, markdown: String)] = [
        ("paragraph", "hello\n"),
        ("two paragraphs", "first\n\nsecond\n"),
        ("h1 + paragraph", "# Title\n\nbody\n"),
        ("multiple headings", "# h1\n\n## h2\n\n### h3\n"),
        ("bold + italic", "**bold** and *italic*\n"),
        ("inline code", "use `x()`\n"),
        ("link", "see [anthropic](https://anthropic.com)\n"),
        ("link with title", "see [docs](https://x \"Hover\")\n"),
        ("image", "![alt](./assets/a.png)\n"),
        ("image with title", "![alt](./assets/a.png \"tooltip\")\n"),
        ("bullet list", "- alpha\n- beta\n- gamma\n"),
        ("ordered list", "1. one\n2. two\n3. three\n"),
        ("blockquote single", "> quoted\n"),
        ("hr", "---\n"),
        ("fenced code no lang",
         "```\nlet x = 1\n```\n"),
        ("fenced code with lang",
         "```swift\nlet x = 1\n```\n"),
        // GFM
        ("strikethrough", "~~gone~~\n"),
        ("task list",
         "- [ ] todo\n- [x] done\n"),
        ("GFM table",
         "| name | role |\n| --- | --- |\n| a | dev |\n| b | ux |\n"),
        // Local video (#88) — canonical `<video>` must round-trip byte-for-byte
        ("local video canonical",
         "<video controls src=\"./assets/abc123.mp4\"></video>\n"),
        // Raw markdown block (Slice 6) — block HTML must round-trip byte-for-byte
        ("HTML details block",
         "<details>\n<summary>Hello</summary>\nworld\n</details>\n"),
        ("HTML div with attrs",
         "<div class=\"warn\">\n  inner content\n</div>\n"),
        // GitHub callout (Phase 2 / Slice 1 #23) — uppercase TYPE on disk
        ("callout note single line",
         "> [!NOTE]\n> body\n"),
        ("callout tip", "> [!TIP]\n> hi\n"),
        ("callout important",
         "> [!IMPORTANT]\n> imp\n"),
        ("callout warning",
         "> [!WARNING]\n> warn\n"),
        ("callout caution",
         "> [!CAUTION]\n> careful\n"),
        ("callout multi-paragraph body",
         "> [!NOTE]\n> first paragraph\n>\n> second paragraph\n"),
    ]

    func testCanonicalFixturesAreFixedPointUnderParseSerialize() {
        for fixture in canonicalFixtures {
            let parsed = MarkdownEngine.parse(markdown: fixture.markdown)
            let serialized = MarkdownEngine.serialize(document: parsed)
            XCTAssertEqual(
                serialized,
                fixture.markdown,
                "fixture not idempotent: \(fixture.name)\nexpected:\n\(fixture.markdown)\nactual:\n\(serialized)"
            )
        }
    }
}

/// Normalization invariants — non-canonical input must come out canonical.
final class MarkdownNormalizationTests: XCTestCase {
    func testSetextHeadingNormalizesToATX() {
        let input = "Hello\n=====\n"
        let out = MarkdownEngine.serialize(document: MarkdownEngine.parse(markdown: input))
        XCTAssertEqual(out, "# Hello\n")
    }

    func testSetextLevel2NormalizesToATX() {
        let input = "Hello\n-----\n"
        let out = MarkdownEngine.serialize(document: MarkdownEngine.parse(markdown: input))
        XCTAssertEqual(out, "## Hello\n")
    }

    func testStarBulletNormalizesToDash() {
        let input = "* one\n* two\n"
        let out = MarkdownEngine.serialize(document: MarkdownEngine.parse(markdown: input))
        XCTAssertEqual(out, "- one\n- two\n")
    }

    func testPlusBulletNormalizesToDash() {
        let input = "+ one\n+ two\n"
        let out = MarkdownEngine.serialize(document: MarkdownEngine.parse(markdown: input))
        XCTAssertEqual(out, "- one\n- two\n")
    }

    func testMultipleBlankLinesCollapseToOne() {
        let input = "first\n\n\n\n\nsecond\n"
        let out = MarkdownEngine.serialize(document: MarkdownEngine.parse(markdown: input))
        XCTAssertEqual(out, "first\n\nsecond\n")
    }

    func testTrailingNewlineIsAlwaysExactlyOne() {
        let input = "hello"  // no trailing newline at all
        let out = MarkdownEngine.serialize(document: MarkdownEngine.parse(markdown: input))
        XCTAssertEqual(out, "hello\n")
    }

    func testItalicUnderscoreNormalizesToStar() {
        let input = "_italic_\n"
        let out = MarkdownEngine.serialize(document: MarkdownEngine.parse(markdown: input))
        XCTAssertEqual(out, "*italic*\n")
    }

    func testBoldUnderscoreNormalizesToStar() {
        let input = "__bold__\n"
        let out = MarkdownEngine.serialize(document: MarkdownEngine.parse(markdown: input))
        XCTAssertEqual(out, "**bold**\n")
    }
}

// MARK: - Test DSL (mirror of MarkdownEngineTests so cases read symmetrically)

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
private func link(_ href: String) -> TiptapMark {
    TiptapMark(type: "link", attrs: ["href": .string(href)])
}
private func linkTitled(_ href: String, title: String) -> TiptapMark {
    TiptapMark(type: "link", attrs: ["href": .string(href), "title": .string(title)])
}

private func mathInline(_ latex: String) -> TiptapNode {
    TiptapNode(type: "math_inline", attrs: ["latex": .string(latex)])
}

private func mathBlock(_ latex: String) -> TiptapNode {
    TiptapNode(type: "math_block", attrs: ["latex": .string(latex)])
}

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

private func callout(_ type: String, _ children: TiptapNode...) -> TiptapNode {
    TiptapNode(type: "callout", attrs: ["type": .string(type)], content: children)
}
