import Foundation
import Markdown

/// Converts between Markdown source text and Tiptap (ProseMirror) document JSON,
/// optionally carrying a YAML frontmatter block at the top.
///
/// Phase 1 surface (`parse(markdown:)` / `serialize(document:)`) treats the
/// input as a body-only Markdown stream. Phase 2 v2 adds the
/// `parseDocument` / `serialize(document: ParsedDocument)` pair, which round-
/// trips the leading `---\n…\n---` block via `FrontmatterEngine`.
public enum MarkdownEngine {
    /// Parsed shape of a `.md` source: optional document-level metadata
    /// plus the Tiptap body. The body alone is the Phase 1 model — the
    /// frontmatter slot is what Phase 2 sync coordinators read and
    /// write through.
    public struct ParsedDocument: Equatable {
        public var frontmatter: Frontmatter
        public var body: TiptapNode

        public init(frontmatter: Frontmatter, body: TiptapNode) {
            self.frontmatter = frontmatter
            self.body = body
        }
    }

    /// Parse a Markdown string into a Tiptap document. Any leading YAML
    /// frontmatter block is detected and stripped before swift-markdown
    /// runs, but is **not** returned — the call is body-only by design.
    /// New callers that need the frontmatter should use
    /// `parseDocument(source:)`.
    ///
    /// Phase 1 supported syntax (CommonMark core):
    ///   headings · paragraphs · strong / emphasis · inline code · links ·
    ///   images · blockquotes · ordered & unordered lists · fenced code blocks ·
    ///   horizontal rules · soft & hard line breaks
    ///
    /// Out of scope for this slice (handled later):
    ///   tables, task lists, strikethrough (Slice 5)
    ///   inline HTML, Mermaid, math, callouts (Slice 6 — raw_markdown_block)
    public static func parse(markdown: String) -> TiptapNode {
        return parseDocument(source: markdown).body
    }

    /// Serialize a Tiptap document back to canonical Markdown source.
    ///
    /// Idempotent on canonical input: parsing canonical-form Markdown and
    /// serializing back yields the same bytes. This entry point omits the
    /// frontmatter section entirely — callers that need it should use the
    /// `ParsedDocument` overload.
    public static func serialize(document: TiptapNode) -> String {
        MarkdownSerializer().serialize(document: document)
    }

    /// Parse a Markdown string, splitting off any YAML frontmatter and
    /// returning both halves. The body is parsed by swift-markdown
    /// exactly as `parse(markdown:)` would handle it.
    public static func parseDocument(source: String) -> ParsedDocument {
        let split = FrontmatterEngine.parse(source)
        let document = Document(parsing: split.body, options: [.parseBlockDirectives])
        // Pass the raw body so the converter can recover block-math ($$…$$)
        // content from source verbatim — swift-markdown's inline parser
        // mangles LaTeX backslashes (`\\` line breaks in `aligned` etc.), so
        // reconstructing from the parsed tree would not round-trip.
        let body = ASTConverter(sourceBody: split.body).convertDocument(document)
        return ParsedDocument(frontmatter: split.frontmatter, body: body)
    }

    /// Serialize a `ParsedDocument` (frontmatter + body) back to a single
    /// Markdown source string. Frontmatter goes first (when present),
    /// then the canonical-form body.
    public static func serialize(document: ParsedDocument) -> String {
        let body = MarkdownSerializer().serialize(document: document.body)
        return FrontmatterEngine.serialize(document.frontmatter, body: body)
    }
}
