import XCTest
@testable import donemd

/// Parse-stable invariant: for any Markdown source `x`, the AST you get
/// from `parse(serialize(parse(x)))` must equal the AST from `parse(x)`.
///
/// In words: serialize-then-reparse must not lose or distort
/// information that the parser preserved on the first pass. This is a
/// stronger guarantee than the canonical-form round-trip (which only
/// asserts byte-equality on already-canonical inputs) — parse-stable
/// catches serializer bugs that produce technically-valid Markdown
/// that re-parses into a *different* tree (e.g. wrong escaping of
/// backslashes, dropped attributes, list nesting drift).
///
/// Run on the actual sample files in `samples/` so the invariant gets
/// tested against real Markdown the user has been editing — not just
/// hand-built fixtures.
final class MarkdownParseStableTests: XCTestCase {

    /// Synthetic inputs that exercise specific edge cases. Independent of
    /// the file-system samples so this layer doesn't break if a sample is
    /// renamed.
    func testParseStableOnSyntheticEdgeCases() throws {
        let inputs: [(name: String, markdown: String)] = [
            // Non-canonical inputs (these will normalize on first
            // serialize, but should be parse-stable thereafter).
            ("setext h1",         "Hello\n=====\n"),
            ("setext h2",         "Sub\n-----\n"),
            ("star bullets",      "* one\n* two\n"),
            ("plus bullets",      "+ a\n+ b\n"),
            ("underscore italic", "_italic_\n"),
            ("underscore bold",   "__bold__\n"),
            ("multi blank lines", "first\n\n\n\nsecond\n"),
            // Inline composition — basic cases only. Composed marks
            // (e.g. `**bold *italic***`) where adjacent text nodes
            // share a mark prefix are a known parser-stable miss; the
            // naive serializer wraps each text run independently and
            // CommonMark re-parses the joined output differently.
            // Tracked: issue #21.
            ("link in heading",   "## See [docs](https://x)\n"),
            ("image in para",     "see ![alt](./assets/x.png) here\n"),
            // GFM constructs.
            ("strike",            "~~gone~~\n"),
            ("task list mixed",   "- [x] done\n- [ ] todo\n"),
            ("table",             "| a | b |\n| --- | --- |\n| 1 | 2 |\n"),
            // Raw block (HTML).
            ("html details",      "<details>\n<summary>x</summary>\ny\n</details>\n"),
            // Local video (#88). Canonical form is byte-stable; non-canonical
            // (bare assets/, single quotes, extra attrs) converges to the
            // canonical `<video controls src="./assets/…">` after one serialize.
            ("video canonical",   "<video controls src=\"./assets/x.mp4\"></video>\n"),
            ("video bare path normalizes", "<video src=\"assets/x.mov\"></video>\n"),
            ("video single quotes normalizes", "<video src='./assets/x.webm'></video>\n"),
            // GitHub callout — both canonical (uppercase) and non-canonical (lowercase / mixed)
            // must converge after one serialize round.
            ("callout uppercase",      "> [!NOTE]\n> body\n"),
            ("callout lowercase parse → uppercase canonical",
                                       "> [!note]\n> body\n"),
            ("callout mixed-case parse → uppercase canonical",
                                       "> [!Warning]\n> body\n"),
            ("callout multi-paragraph", "> [!TIP]\n> first\n>\n> second\n"),
            ("callout with bullet list",
                                       "> [!IMPORTANT]\n> intro\n>\n> - one\n> - two\n"),
            ("plain blockquote stays as blockquote",
                                       "> not a callout, just a quote\n"),
            // Math (Phase 5 M2 / Slice 2 #74). Block $$x$$ normalizes to
            // three-line form on first serialize but stays parse-stable
            // (both forms parse to the same math_block node). Math-in-
            // emphasis is deliberately excluded — it inherits the composed-
            // mark #21 limitation noted above.
            ("inline math",           "an equation $E=mc^2$ here\n"),
            ("block math three-line",  "$$\nx+y\n$$\n"),
            ("block math single-line normalizes", "$$x$$\n"),
            ("block math multi-line body",
                                       "$$\n\\begin{aligned}\na&=b\n\\end{aligned}\n$$\n"),
            ("dollar literals stay literal", "cost is $5 and $10 total\n"),
            ("escaped dollar",         "price \\$5\n"),
            ("two inline math",        "$a$ and $b$\n"),
            // Empty / minimal.
            ("empty",             ""),
            ("just whitespace",   "   \n   \n"),
            ("trailing newline",  "hello\n"),
            ("missing newline",   "hello"),
        ]

        for (name, markdown) in inputs {
            assertParseStable(markdown, name: name)
        }
    }

    /// The real `samples/*.md` files in the repo — the same files the
    /// user opens for verification. Catches issues a synthetic fixture
    /// might miss because the actual content composes constructs in
    /// ways we wouldn't think to invent.
    ///
    /// Note: `samples/gfm.md` is currently excluded — it contains
    /// composed-mark patterns (adjacent text runs that share a mark
    /// prefix) that the naive serializer doesn't round-trip cleanly.
    /// Tracked: issue #21.
    func testParseStableOnRepoSamples() throws {
        let samples = ["commonmark.md", "raw-blocks.md", "math-test.md"]
        for filename in samples {
            guard let url = sampleURL(filename) else {
                XCTFail("could not locate samples/\(filename)")
                continue
            }
            let source = try String(contentsOf: url, encoding: .utf8)
            assertParseStable(source, name: "samples/\(filename)")
        }
    }

    // MARK: Helpers

    /// Core invariant assertion. `parse(serialize(parse(x))) == parse(x)`.
    private func assertParseStable(
        _ markdown: String,
        name: String,
        file: StaticString = #file,
        line: UInt = #line
    ) {
        let firstParse = MarkdownEngine.parse(markdown: markdown)
        let serialized = MarkdownEngine.serialize(document: firstParse)
        let secondParse = MarkdownEngine.parse(markdown: serialized)

        XCTAssertEqual(
            secondParse,
            firstParse,
            "parse-stable invariant violated for: \(name)\n"
                + "first parse blocks: \(firstParse.content?.count ?? 0)\n"
                + "after serialize+reparse blocks: \(secondParse.content?.count ?? 0)",
            file: file,
            line: line
        )
    }

    /// Find a `samples/<filename>` next to the project root. Resolved
    /// from `#filePath` (the test source location), going up to the
    /// project directory.
    private func sampleURL(_ filename: String) -> URL? {
        let testFile = URL(fileURLWithPath: #filePath)
        let projectRoot = testFile
            .deletingLastPathComponent()    // strip MarkdownParseStableTests.swift
            .deletingLastPathComponent()    // strip donemdTests/
        let url = projectRoot
            .appendingPathComponent("samples", isDirectory: true)
            .appendingPathComponent(filename)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}
