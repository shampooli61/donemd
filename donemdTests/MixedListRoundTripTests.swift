import XCTest
import Markdown
@testable import donemd

/// Shared-engine regressions, intentionally mirrored in the macOS and iOS targets.
final class MixedListRoundTripTests: XCTestCase {
    func testOrdinaryAndCheckedItemsKeepTheirOwnKindsAndOrder() {
        let source = "- plain one\n- plain two\n- [ ] todo\n- [x] done\n- plain last\n"
        let expected = node("doc", [
            node("bulletList", [item("plain one"), item("plain two")]),
            node("taskList", [item("todo", checked: false), item("done", checked: true)]),
            node("bulletList", [item("plain last")]),
        ])
        XCTAssertEqual(MarkdownEngine.parse(markdown: source), expected)
        assertStable(source)
        let saved = MarkdownEngine.serialize(document: expected)
        XCTAssertFalse(saved.contains("[ ] plain"))
    }

    func testMixedListsExpandInsideEveryBlockContainer() throws {
        let cases: [(String, [Int], [String])] = [
            ("> - plain\n> - [ ] todo\n> - [x] done\n> - tail\n", [0], ["bulletList", "taskList", "bulletList"]),
            ("- parent\n  - plain\n  - [ ] todo\n  - tail\n", [0, 0], ["paragraph", "bulletList", "taskList", "bulletList"]),
            ("- [x] parent\n  - plain\n  - [ ] todo\n  - tail\n", [0, 0], ["paragraph", "bulletList", "taskList", "bulletList"]),
            ("7. parent\n   - plain\n   - [x] done\n   - tail\n", [0, 0], ["paragraph", "bulletList", "taskList", "bulletList"]),
            ("> [!NOTE]\n> intro\n>\n> - plain\n> - [ ] todo\n> - tail\n", [0], ["paragraph", "bulletList", "taskList", "bulletList"]),
        ]
        for (source, path, expectedTypes) in cases {
            var container = MarkdownEngine.parse(markdown: source)
            for index in path {
                let children = try XCTUnwrap(container.content)
                XCTAssertTrue(children.indices.contains(index))
                guard children.indices.contains(index) else { return }
                container = children[index]
            }
            XCTAssertEqual(container.content?.map(\.type), expectedTypes, source)
            assertStable(source)
        }
    }

    func testQuotedTasksRecoverStateAndFormattingButNotLiteralMarkers() throws {
        let source = "> - plain\n> - [ ] **todo**\n> - [X] done\n> - tail\n"
        let expected = node("doc", [node("blockquote", [
            node("bulletList", [item("plain")]),
            node("taskList", [
                node("taskItem", [node("paragraph", [.text("todo", marks: [TiptapMark(type: "bold")])])], attrs: ["checked": .bool(false)]),
                item("done", checked: true),
            ]),
            node("bulletList", [item("tail")]),
        ])])
        XCTAssertEqual(MarkdownEngine.parse(markdown: source), expected)
        assertStable(source)

        // Parsed text alone is insufficient: escaped/entity brackets must not
        // become tasks. Code, links, and a marker later in prose aren't tasks.
        let literals = "> - \\[ ] escaped\n> - &#91;x] entity\n> - `[ ]` code\n> - [x](https://example.com) link\n> - prose [ ] later\n"
        let quote = try XCTUnwrap(MarkdownEngine.parse(markdown: literals).content?.first)
        XCTAssertEqual(quote.content?.map(\.type), ["bulletList"])
        let list = try XCTUnwrap(quote.content?.first)
        XCTAssertEqual(list.content?.count, 5)
        XCTAssertTrue(list.content?.allSatisfy { $0.type == "listItem" && $0.attrs?["checked"] == nil } == true)
        assertStable(literals)
        assertStable("> > - plain\n> > - [x] nested quote\n> > - tail\n")
    }

    func testNeighboringBlocksAndOrderedStartDoNotShift() throws {
        let source = "Before\n\n- first\n- [ ] todo\n- middle\n- [x] done\n- last\n\n10. ten\n11. eleven\n\nAfter\n"
        let root = MarkdownEngine.parse(markdown: source)
        XCTAssertEqual(root.content?.map(\.type), ["paragraph", "bulletList", "taskList", "bulletList", "taskList", "bulletList", "orderedList", "paragraph"])
        let ordered = try XCTUnwrap(root.content?.first(where: { $0.type == "orderedList" }))
        XCTAssertEqual(ordered.attrs?["start"], .int(10))
        assertStable(source)
    }

    func testAdjacentSourceListsNormalizeWithoutMovingItems() throws {
        // Different bullet markers force separate swift-markdown lists. After
        // conversion, the two task runs at that boundary must canonicalize as
        // one run, not cause a different block count on every reopen.
        let source = "* plain\n* [ ] first\n\n- [x] second\n- tail\n"
        let root = MarkdownEngine.parse(markdown: source)
        XCTAssertEqual(root.content?.map(\.type), ["bulletList", "taskList", "bulletList"])
        let tasks = try XCTUnwrap(root.content?.first(where: { $0.type == "taskList" }))
        XCTAssertEqual(tasks.content?.count, 2)
        XCTAssertEqual(tasks.content?.map { $0.attrs?["checked"] }, [.bool(false), .bool(true)])
        assertStable(source)
    }

    func testTaskContinuationIsParagraphAndNestedListInActualMarkdownAST() throws {
        let root = node("doc", [node("taskList", [node("taskItem", [
            paragraph("parent"), paragraph("second paragraph"),
            node("bulletList", [item("plain child")]),
            node("taskList", [item("child todo", checked: false), item("child done", checked: true)]),
            node("orderedList", [item("seven"), item("eight")], attrs: ["start": .int(7)]),
        ], attrs: ["checked": .bool(true)])])])
        let saved = MarkdownEngine.serialize(document: root)
        // This inspects swift-markdown's actual parse, not just indentation bytes.
        let ast = Document(parsing: saved)
        let list = try XCTUnwrap(Array(ast.children).first as? UnorderedList)
        let parent = try XCTUnwrap(Array(list.listItems).first)
        XCTAssertEqual(parent.checkbox, .checked)
        let blocks = Array(parent.children)
        XCTAssertEqual(blocks.count, 4) // paragraph, paragraph, merged unordered, ordered
        XCTAssertTrue(blocks.first is Paragraph)
        XCTAssertTrue(blocks.dropFirst().first is Paragraph)
        XCTAssertFalse(blocks.contains(where: { $0 is CodeBlock }))
        let nested = try XCTUnwrap(blocks.compactMap { $0 as? UnorderedList }.first)
        XCTAssertEqual(Array(nested.listItems).count, 3)
        XCTAssertNil(Array(nested.listItems).first?.checkbox)
        let ordered = try XCTUnwrap(blocks.compactMap { $0 as? OrderedList }.first)
        XCTAssertEqual(ordered.startIndex, 7)
        XCTAssertEqual(MarkdownEngine.parse(markdown: saved), root)
        assertStable(saved)
    }

    func testOpenEditUnrelatedBodySaveReopenPreservesMetadataAndRawSource() throws {
        let frontmatter = "---\ntitle: 'Mixed list' # keep quote and comment\ntags: [one, two]\n---\n"
        let raw = "<div data-note=\"raw\">\n  untouched &amp; [ ] source\n</div>"
        let source = frontmatter + "\n- plain\n- [ ] todo\n- [x] done\n\nUnrelated body\n\n" + raw + "\n"
        var opened = MarkdownEngine.parseDocument(source: source)
        let original = opened
        let index = try XCTUnwrap(opened.body.content?.firstIndex(where: { $0.type == "paragraph" }))
        opened.body.content?[index] = paragraph("Edited unrelated body")
        let saved = MarkdownEngine.serialize(document: opened)
        XCTAssertTrue(saved.hasPrefix(frontmatter))
        XCTAssertTrue(saved.contains(raw))
        XCTAssertFalse(saved.contains("[ ] plain"))
        let reopened = MarkdownEngine.parseDocument(source: saved)
        XCTAssertEqual(reopened, opened)
        XCTAssertEqual(reopened.frontmatter, original.frontmatter)
        XCTAssertEqual(reopened.body.content?.filter { $0.type.hasSuffix("List") }, original.body.content?.filter { $0.type.hasSuffix("List") })
        XCTAssertEqual(MarkdownEngine.serialize(document: reopened), saved)
    }

    func testPureListsKeepExistingCanonicalBytes() {
        for source in ["- plain\n- other\n", "- [ ] todo\n- [x] done\n", "7. seven\n8. eight\n"] {
            XCTAssertEqual(MarkdownEngine.serialize(document: MarkdownEngine.parse(markdown: source)), source)
            assertStable(source)
        }
    }

    private func assertStable(_ source: String, file: StaticString = #filePath, line: UInt = #line) {
        let firstTree = MarkdownEngine.parse(markdown: source)
        let firstSave = MarkdownEngine.serialize(document: firstTree)
        let reopened = MarkdownEngine.parse(markdown: firstSave)
        XCTAssertEqual(reopened, firstTree, source, file: file, line: line)
        let secondSave = MarkdownEngine.serialize(document: reopened)
        XCTAssertEqual(secondSave, firstSave, source, file: file, line: line)
        XCTAssertEqual(MarkdownEngine.serialize(document: MarkdownEngine.parse(markdown: secondSave)), secondSave, file: file, line: line)
    }

    private func node(_ type: String, _ children: [TiptapNode], attrs: [String: AttrValue]? = nil) -> TiptapNode {
        TiptapNode(type: type, attrs: attrs, content: children)
    }
    private func paragraph(_ text: String) -> TiptapNode { node("paragraph", [.text(text)]) }
    private func item(_ text: String, checked: Bool? = nil) -> TiptapNode {
        if let checked = checked { return node("taskItem", [paragraph(text)], attrs: ["checked": .bool(checked)]) }
        return node("listItem", [paragraph(text)])
    }
}
