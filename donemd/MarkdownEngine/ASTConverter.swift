import Foundation
import Markdown

/// Converts a `swift-markdown` `Document` AST into a Tiptap node tree.
///
/// Block-level: headings, paragraphs, blockquotes, lists, code blocks, hr.
/// Inline: text, strong, emphasis, code, link, image, soft/hard breaks.
///
/// Marks (bold, italic, code, link) accumulate down inline ancestors and end
/// up on the leaf text nodes — matching ProseMirror's flat inline model.
struct ASTConverter {
    /// Raw Markdown body (frontmatter already stripped). Used to recover
    /// block-math ($$…$$) content from source verbatim via node source
    /// ranges — the parsed inline tree mangles LaTeX backslashes. Split into
    /// lines once (1-indexed by `SourceLocation.line`).
    private let sourceLines: [Substring]

    init(sourceBody: String = "") {
        // `split(omittingEmptySubsequences: false)` keeps blank lines so line
        // numbers line up with swift-markdown's 1-based `SourceLocation.line`.
        self.sourceLines = sourceBody.split(separator: "\n", omittingEmptySubsequences: false)
    }

    func convertDocument(_ document: Document) -> TiptapNode {
        let blocks = document.children.compactMap { convertBlock($0) }
        // Tiptap's doc schema requires `block+`. Empty input ⇒ single empty paragraph.
        let content = blocks.isEmpty ? [TiptapNode(type: "paragraph")] : blocks
        return TiptapNode(type: "doc", content: content)
    }

    // MARK: Block-level

    private func convertBlock(_ markup: Markup) -> TiptapNode? {
        switch markup {
        case let h as Heading:
            return TiptapNode(
                type: "heading",
                attrs: ["level": .int(h.level)],
                content: convertInline(of: h)
            )
        case let p as Paragraph:
            // Block math `$$...$$` (Phase 5 M2): swift-markdown has no math
            // construct, so a display-math block surfaces as an ordinary
            // Paragraph whose text is fenced by `$$`. Sniff it before falling
            // back to normal inline conversion.
            if let mathBlock = convertMathBlockIfMatched(p) {
                return mathBlock
            }
            // Local video (#88). A single-line `<video …></video>` is NOT a
            // CommonMark HTML block (`video` isn't a type-6 tag, and an
            // open+close tag on one line doesn't start a type-7 block), so
            // swift-markdown delivers it as a Paragraph of inline HTML.
            // Sniff it before normal inline conversion (which would drop the
            // InlineHTML fragments into an empty paragraph).
            if let videoNode = convertVideoIfMatched(p) {
                return videoNode
            }
            let inline = convertInline(of: p)
            // Standalone image line (`![alt](src)` on its own): swift-markdown
            // models `![]()` as INLINE, so it lands inside this paragraph. But
            // our `image` node is block-level (schema `group: block`, not inline)
            // — a paragraph is `inline*` and cannot legally contain it. Tiptap
            // renders and even deletes it leniently, but ProseMirror's strict
            // content check fires on UNDO ("Invalid content for node paragraph:
            // <image>"), aborting the whole history step so a deleted image
            // can't be brought back (see image-node.ts). Hoist a lone image out
            // of its paragraph wrapper to a top-level block so the doc matches
            // the schema and undo round-trips cleanly.
            if let loneImage = soleImageNode(in: inline) {
                return loneImage
            }
            return TiptapNode(type: "paragraph", content: inline)
        case let bq as BlockQuote:
            if let calloutNode = convertCalloutIfMatched(bq) {
                return calloutNode
            }
            let inner = bq.children.compactMap { convertBlock($0) }
            return TiptapNode(type: "blockquote", content: inner)
        case let ul as UnorderedList:
            // GFM task list: any list whose items carry a `[ ]` / `[x]`
            // checkbox becomes a Tiptap taskList. Items missing a checkbox
            // are coerced to unchecked task items so the list stays
            // schema-consistent (Tiptap rejects mixed listItem/taskItem).
            if ul.listItems.contains(where: { $0.checkbox != nil }) {
                return TiptapNode(
                    type: "taskList",
                    content: ul.listItems.map { convertTaskItem($0) }
                )
            }
            return TiptapNode(
                type: "bulletList",
                content: ul.listItems.map { convertListItem($0) }
            )
        case let ol as OrderedList:
            var attrs: [String: AttrValue]? = nil
            if ol.startIndex != 1 {
                attrs = ["start": .int(Int(ol.startIndex))]
            }
            return TiptapNode(
                type: "orderedList",
                attrs: attrs,
                content: ol.listItems.map { convertListItem($0) }
            )
        case let cb as CodeBlock:
            var attrs: [String: AttrValue]? = nil
            if let language = cb.language, !language.isEmpty {
                attrs = ["language": .string(language)]
            }
            // Trim trailing newline that swift-markdown preserves at block end.
            let code = cb.code.hasSuffix("\n") ? String(cb.code.dropLast()) : cb.code
            let textNodes: [TiptapNode] = code.isEmpty ? [] : [TiptapNode(type: "text", text: code)]
            return TiptapNode(type: "codeBlock", attrs: attrs, content: textNodes)
        case is ThematicBreak:
            return TiptapNode(type: "horizontalRule")
        case let tbl as Markdown.Table:
            return convertTable(tbl)
        case let html as Markdown.HTMLBlock:
            // Block-level HTML — preserve verbatim. `rawHTML` already has
            // the literal source; trim the trailing newline swift-markdown
            // pads on (the serializer joins blocks with \n\n itself).
            let raw = html.rawHTML.trimmingCharacters(in: .newlines)
            // Feishu placeholder magic comment? Hand off to the placeholder
            // parser; on failure (corrupt body, missing required fields)
            // fall through to a raw markdown block so the bytes survive.
            if let placeholder = FeishuPlaceholderEngine.parse(raw) {
                return makeFeishuPlaceholderBlock(placeholder)
            }
            // Local video (#88): a canonical `<video controls src="./assets/…">`.
            // Intercept BEFORE the raw-markdown fallback so it becomes a real
            // `video` node (inline-playable, src-rewritten, walkable by Feishu)
            // instead of inert source text. Anything we can't parse as a video
            // (no src) still falls through to the verbatim raw block.
            if let src = Self.parseVideoSrc(fromRawHTML: raw) {
                let runtimeSrc = rewriteImageSrcForRuntime(src)
                return TiptapNode(type: "video", attrs: ["src": .string(runtimeSrc)])
            }
            return makeRawMarkdownBlock(raw: raw)
        case let directive as BlockDirective:
            // Custom containers / callouts (`@Note { ... }`,
            // `:::warning ... :::`, etc.) — Phase 1 doesn't render them
            // natively. Round-trip via swift-markdown's canonical
            // formatter; loses byte-perfect fidelity for whitespace
            // around the directive but preserves semantics.
            let raw = directive.format().trimmingCharacters(in: .newlines)
            return makeRawMarkdownBlock(raw: raw)
        default:
            // Anything still unrecognized falls through. Phase 2+ may
            // expand the bridge for math (`$$..$$`), footnotes, etc.
            return nil
        }
    }

    private func makeRawMarkdownBlock(raw: String) -> TiptapNode {
        TiptapNode(
            type: "raw_markdown_block",
            attrs: ["raw": .string(raw)]
        )
    }

    /// If a paragraph's converted inline content is exactly one image (a
    /// standalone `![alt](src)` line, optionally with surrounding whitespace-only
    /// text), return that image node to hoist to the top level; else nil.
    ///
    /// `image` is a block node in our schema, so it must not live inside a
    /// paragraph (`inline*`) — see the call site for the undo failure this
    /// prevents. We tolerate stray empty/whitespace text nodes that
    /// swift-markdown sometimes emits around the image so a lone image on its
    /// own line still hoists cleanly; a paragraph mixing an image with real
    /// text keeps the image inline (unsupported layout, but we don't drop text).
    private func soleImageNode(in inline: [TiptapNode]) -> TiptapNode? {
        var image: TiptapNode?
        for node in inline {
            if node.type == "image" {
                if image != nil { return nil } // more than one image ⇒ not "lone"
                image = node
            } else if node.type == "text" {
                if (node.text ?? "").trimmingCharacters(in: .whitespaces).isEmpty {
                    continue // ignore blank filler text
                }
                return nil // real text alongside the image ⇒ keep inline
            } else {
                return nil // any other inline sibling ⇒ keep inline
            }
        }
        return image
    }

    /// Local video detection at the paragraph level (#88). A canonical
    /// single-line `<video controls src="./assets/…"></video>` arrives from
    /// swift-markdown as a Paragraph whose children are `InlineHTML`
    /// fragments (the raw `<video …>` open tag and the `</video>` close tag) —
    /// not a `Markdown.HTMLBlock`. Reassemble those fragments; if they form a
    /// lone `<video>` element, return a `video` node (src rewritten to the
    /// runtime `donemd-asset://` scheme). A `<video>` we can't extract a src
    /// from is preserved verbatim as a raw block rather than silently dropped.
    /// Returns nil (→ normal paragraph conversion) if the paragraph carries
    /// any real inline content alongside — or instead of — the `<video>`.
    private func convertVideoIfMatched(_ paragraph: Paragraph) -> TiptapNode? {
        var raw = ""
        var sawInlineHTML = false
        for child in paragraph.children {
            if let html = child as? InlineHTML {
                raw += html.rawHTML
                sawInlineHTML = true
            } else if let text = child as? Text,
                      text.string.trimmingCharacters(in: .whitespaces).isEmpty {
                continue // tolerate whitespace filler between the tags
            } else {
                return nil // real inline content alongside ⇒ not a lone <video>
            }
        }
        guard sawInlineHTML else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasPrefix("<video") else { return nil }
        if let src = Self.parseVideoSrc(fromRawHTML: trimmed) {
            let runtimeSrc = rewriteImageSrcForRuntime(src)
            return TiptapNode(type: "video", attrs: ["src": .string(runtimeSrc)])
        }
        return makeRawMarkdownBlock(raw: trimmed)
    }

    /// Block math detection (Phase 5 M2). A `$$...$$` display formula reaches
    /// us as a plain `Paragraph` (swift-markdown doesn't model math). Returns
    /// a `math_block` node when the paragraph is *purely* a `$$`-fenced text
    /// run, else nil so the caller falls back to normal paragraph conversion.
    ///
    /// Robust to swift-markdown's tokenization: `$$\nx\n$$` may arrive as one
    /// `Text` child or as `Text`/`SoftBreak`/`Text` — we flatten all inline
    /// descendants to a single string (soft/hard breaks → `\n`) first, then
    /// match on the string, so the split no longer matters.
    private func convertMathBlockIfMatched(_ paragraph: Paragraph) -> TiptapNode? {
        // Reject paragraphs carrying any non-text inline (emphasis, links,
        // images, inline code): a real math block is pure text + breaks.
        for child in paragraph.children {
            switch child {
            case is Text, is SoftBreak, is LineBreak:
                continue
            default:
                return nil
            }
        }

        // Reconstruct the paragraph's RAW source text from `sourceLines`
        // (not the parsed inline tree, which mangles LaTeX `\\`). The
        // paragraph's range spans full lines for a `$$…$$` block.
        guard let raw = rawText(for: paragraph) else { return nil }

        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("$$"), trimmed.hasSuffix("$$"),
              trimmed.count >= 4 else {
            return nil
        }

        // Inner text between the leading and trailing `$$`.
        var inner = String(trimmed.dropFirst(2).dropLast(2))
        // Strip exactly one leading / trailing newline (the canonical
        // three-line form `$$\n…\n$$`); preserve everything else verbatim so
        // multi-line bodies like `\begin{aligned}…` survive untouched.
        if inner.hasPrefix("\n") { inner.removeFirst() }
        if inner.hasSuffix("\n") { inner.removeLast() }

        // Empty formula (`$$$$` / `$$\n$$`): not math — let the literal `$$`
        // round-trip as an ordinary paragraph instead of an empty node.
        guard !inner.isEmpty else { return nil }

        return TiptapNode(type: "math_block", attrs: ["latex": .string(inner)])
    }

    /// Verbatim source text for a block-level node, sliced from `sourceLines`
    /// by its `SourceRange` (1-based lines). Returns nil when the range is
    /// unavailable (e.g. synthetic input parsed without source tracking) or
    /// out of bounds — the caller then declines to treat it as math.
    private func rawText(for markup: Markup) -> String? {
        guard let range = markup.range else { return nil }
        let start = range.lowerBound.line
        let end = range.upperBound.line
        guard start >= 1, end >= start, end <= sourceLines.count else { return nil }
        return sourceLines[(start - 1)..<end].joined(separator: "\n")
    }

    /// Feishu placeholder block (ADR-0007). Atom node with typed attrs;
    /// the JS-side NodeView reads them to render the card. `unknown_fields`
    /// is an array of `{key, value}` objects so future Feishu metadata
    /// extensions round-trip through the editor untouched.
    private func makeFeishuPlaceholderBlock(_ placeholder: FeishuPlaceholder) -> TiptapNode {
        var attrs: [String: AttrValue] = [
            "type": .string(placeholder.type),
            "block_id": .string(placeholder.blockId),
            "title": .string(placeholder.title),
            "url": .string(placeholder.url),
        ]
        if let token = placeholder.blockToken {
            attrs["block_token"] = .string(token)
        }
        if let summary = placeholder.summary {
            attrs["summary"] = .string(summary)
        }
        if let created = placeholder.createdInFeishuAt {
            attrs["created_in_feishu_at"] = .string(created)
        }
        if !placeholder.unknownFields.isEmpty {
            attrs["unknown_fields"] = .array(placeholder.unknownFields.map { field in
                .object([
                    "key": .string(field.key),
                    "value": .string(field.value),
                ])
            })
        }
        return TiptapNode(type: "feishu_placeholder_block", attrs: attrs)
    }

    /// GitHub callout detection: a blockquote whose first paragraph leads
    /// with a `[!TYPE]` token (followed by a soft break + body) becomes a
    /// `callout` node. Returns nil for plain blockquotes so the caller can
    /// fall back to normal conversion.
    ///
    /// Schema constraint: callouts may only contain paragraphs, lists, and
    /// nested blockquotes (飞书高亮块的硬限制 — see CONTEXT.md). codeBlock /
    /// table / horizontalRule descendants are dropped here at the parse
    /// layer; the NodeView (Slice 2) enforces the same at the edit layer.
    private func convertCalloutIfMatched(_ bq: BlockQuote) -> TiptapNode? {
        let bqChildren = Array(bq.children)
        guard let firstParagraph = bqChildren.first as? Paragraph else { return nil }
        let paragraphChildren = Array(firstParagraph.children)
        guard let firstText = paragraphChildren.first as? Text else { return nil }

        let token = firstText.string
        guard token.hasPrefix("[!"), token.hasSuffix("]") else { return nil }
        let typeRaw = String(token.dropFirst(2).dropLast())
        guard !typeRaw.isEmpty, typeRaw.allSatisfy({ $0.isLetter }) else { return nil }
        let type = typeRaw.lowercased()

        // Strip `[!TYPE]` and the soft break that follows it on the same
        // paragraph; what remains is the body of the header paragraph.
        var remainingInlines = paragraphChildren
        remainingInlines.removeFirst()
        if let next = remainingInlines.first, next is SoftBreak {
            remainingInlines.removeFirst()
        }

        var content: [TiptapNode] = []
        if !remainingInlines.isEmpty {
            var inlineNodes: [TiptapNode] = []
            for child in remainingInlines {
                walkInline(child, marks: [], into: &inlineNodes)
            }
            content.append(
                TiptapNode(type: "paragraph", content: coalesceAdjacentText(inlineNodes))
            )
        }

        let disallowed: Set<String> = ["codeBlock", "table", "horizontalRule"]
        for child in bqChildren.dropFirst() {
            guard let block = convertBlock(child) else { continue }
            if disallowed.contains(block.type) { continue }
            content.append(block)
        }

        // Tiptap schema: callout content is `(paragraph | … )+` — at least
        // one block required. An empty body (`> [!NOTE]` alone) would fail
        // schema validation on the Visual side, so seed an empty paragraph.
        if content.isEmpty {
            content.append(TiptapNode(type: "paragraph"))
        }

        return TiptapNode(
            type: "callout",
            attrs: ["type": .string(type)],
            content: content
        )
    }

    private func convertListItem(_ item: ListItem) -> TiptapNode {
        let inner = item.children.compactMap { convertBlock($0) }
        return TiptapNode(type: "listItem", content: inner)
    }

    private func convertTaskItem(_ item: ListItem) -> TiptapNode {
        let checked = item.checkbox == .checked
        let inner = item.children.compactMap { convertBlock($0) }
        return TiptapNode(
            type: "taskItem",
            attrs: ["checked": .bool(checked)],
            content: inner
        )
    }

    private func convertTable(_ table: Markdown.Table) -> TiptapNode {
        var rows: [TiptapNode] = []

        // Head row → tableRow with tableHeader cells
        let headCells: [TiptapNode] = table.head.children.compactMap { child in
            guard let cell = child as? Markdown.Table.Cell else { return nil }
            return wrapCell(cell, type: "tableHeader")
        }
        rows.append(TiptapNode(type: "tableRow", content: headCells))

        // Body rows → tableRow with tableCell cells
        for child in table.body.children {
            guard let row = child as? Markdown.Table.Row else { continue }
            let bodyCells: [TiptapNode] = row.children.compactMap { rChild in
                guard let cell = rChild as? Markdown.Table.Cell else { return nil }
                return wrapCell(cell, type: "tableCell")
            }
            rows.append(TiptapNode(type: "tableRow", content: bodyCells))
        }

        return TiptapNode(type: "table", content: rows)
    }

    private func wrapCell(_ cell: Markdown.Table.Cell, type: String) -> TiptapNode {
        // Tiptap's table-cell schema requires `block+` content. Wrap the
        // inline children of the cell in a paragraph.
        let inline = convertInline(of: cell)
        let paragraph = TiptapNode(type: "paragraph", content: inline.isEmpty ? nil : inline)
        return TiptapNode(type: type, content: [paragraph])
    }

    // MARK: Inline

    private func convertInline(of markup: Markup) -> [TiptapNode] {
        var nodes: [TiptapNode] = []
        for child in markup.children {
            walkInline(child, marks: [], into: &nodes)
        }
        return coalesceAdjacentText(nodes)
    }

    /// Merge adjacent `text` runs that carry identical marks into one node.
    ///
    /// swift-markdown hands us prose as separate fragments — a soft break
    /// (a wrapped source line) arrives as its own `" "` `Text`, sitting
    /// between two same-mark text runs. The serializer joins a paragraph's
    /// inline children onto a single line, so `serialize→reparse` collapses
    /// those fragments into one run — leaving the first parse structurally
    /// different from the reparse and breaking the parse-stable invariant
    /// (#56). Coalescing here makes the *first* parse already canonical:
    /// contiguous same-mark text becomes the single node that re-parsing
    /// canonical output yields. Non-text nodes (image / hardBreak /
    /// math_inline atoms) and runs with differing marks stay as boundaries,
    /// so this never fuses across a real structural break.
    private func coalesceAdjacentText(_ nodes: [TiptapNode]) -> [TiptapNode] {
        var out: [TiptapNode] = []
        for node in nodes {
            if node.type == "text", node.content == nil,
               let last = out.last, last.type == "text", last.content == nil,
               last.marks == node.marks {
                out[out.count - 1] = TiptapNode.text(
                    (last.text ?? "") + (node.text ?? ""),
                    marks: last.marks
                )
            } else {
                out.append(node)
            }
        }
        return out
    }

    private func walkInline(
        _ markup: Markup,
        marks: [TiptapMark],
        into nodes: inout [TiptapNode]
    ) {
        switch markup {
        case let text as Text:
            // Inline math `$...$` (Phase 5 M2): swift-markdown delivers it as
            // literal text, so scan the run and split out math_inline nodes.
            appendTextWithInlineMath(text.string, marks: marks, into: &nodes)
        case let strong as Strong:
            walkInlineChildren(of: strong, marks: marks + [TiptapMark(type: "bold")], into: &nodes)
        case let em as Emphasis:
            walkInlineChildren(of: em, marks: marks + [TiptapMark(type: "italic")], into: &nodes)
        case let strike as Strikethrough:
            walkInlineChildren(of: strike, marks: marks + [TiptapMark(type: "strike")], into: &nodes)
        case let code as InlineCode:
            nodes.append(TiptapNode.text(code.code, marks: marks + [TiptapMark(type: "code")]))
        case let link as Link:
            let href = link.destination ?? ""
            var linkAttrs: [String: AttrValue] = ["href": .string(href)]
            if let title = link.title, !title.isEmpty {
                linkAttrs["title"] = .string(title)
            }
            walkInlineChildren(
                of: link,
                marks: marks + [TiptapMark(type: "link", attrs: linkAttrs)],
                into: &nodes
            )
        case let image as Image:
            // Disk-form `./assets/<filename>` → runtime-form
            // `donemd-asset://<filename>` so AssetURLSchemeHandler can
            // serve the bytes. Serializer does the inverse on save.
            let runtimeSrc = rewriteImageSrcForRuntime(image.source ?? "")
            var imageAttrs: [String: AttrValue] = ["src": .string(runtimeSrc)]
            let alt = image.plainText
            if !alt.isEmpty { imageAttrs["alt"] = .string(alt) }
            if let title = image.title, !title.isEmpty {
                imageAttrs["title"] = .string(title)
            }
            nodes.append(TiptapNode(type: "image", attrs: imageAttrs))
        case is LineBreak:
            nodes.append(TiptapNode(type: "hardBreak"))
        case is SoftBreak:
            // CommonMark soft breaks render as a space between words.
            nodes.append(TiptapNode.text(" ", marks: marks.isEmpty ? nil : marks))
        default:
            // Unknown inline container: descend into its children, preserving accumulated marks.
            walkInlineChildren(of: markup, marks: marks, into: &nodes)
        }
    }

    private func walkInlineChildren(
        of markup: Markup,
        marks: [TiptapMark],
        into nodes: inout [TiptapNode]
    ) {
        for child in markup.children {
            walkInline(child, marks: marks, into: &nodes)
        }
    }

    /// Split a plain text run into text + `math_inline` nodes (Phase 5 M2).
    ///
    /// Strict recognition (per product decision): a `$` opens math only when
    /// the next char is non-space/non-newline; the closing `$` must be
    /// preceded by a non-space/non-newline, sit on the same line (no newline
    /// between), and be unescaped. `\$` is always a literal dollar. This
    /// rejects prose like `$5 and $10` and `$ x $`.
    ///
    /// Accumulated `marks` (bold/italic from ancestor inlines) apply to the
    /// surrounding text splits only — math nodes are atoms and carry no marks.
    private func appendTextWithInlineMath(
        _ s: String,
        marks: [TiptapMark],
        into nodes: inout [TiptapNode]
    ) {
        let chars = Array(s)
        let n = chars.count
        var pending = ""
        var i = 0

        func flushPending() {
            if !pending.isEmpty {
                nodes.append(TiptapNode.text(pending, marks: marks.isEmpty ? nil : marks))
                pending = ""
            }
        }

        while i < n {
            let c = chars[i]

            // Escaped dollar: keep `\$` literal, never a delimiter.
            if c == "\\", i + 1 < n, chars[i + 1] == "$" {
                pending.append("\\")
                pending.append("$")
                i += 2
                continue
            }

            if c == "$" {
                // Open rule: next char exists and is non-space/non-newline.
                if i + 1 < n {
                    let next = chars[i + 1]
                    if !next.isWhitespace {
                        // Find an unescaped closing `$` on the same line whose
                        // preceding char is non-space/non-newline.
                        var j = i + 1
                        var found = -1
                        while j < n {
                            let cj = chars[j]
                            if cj == "\n" { break } // one-line rule
                            if cj == "$" {
                                // Count preceding backslashes for escape parity.
                                var back = 0
                                var k = j - 1
                                while k >= 0, chars[k] == "\\" { back += 1; k -= 1 }
                                let unescaped = (back % 2 == 0)
                                let prev = chars[j - 1]
                                if unescaped, !prev.isWhitespace {
                                    found = j
                                    break
                                }
                            }
                            j += 1
                        }
                        // Require at least one char of latex between the
                        // delimiters (`found > i + 1`) — `$$` / `$$$$` are not
                        // empty inline formulas, they stay literal.
                        if found > i + 1 {
                            flushPending()
                            let latex = String(chars[(i + 1)..<found])
                            nodes.append(TiptapNode(
                                type: "math_inline",
                                attrs: ["latex": .string(latex)]
                            ))
                            i = found + 1
                            continue
                        }
                    }
                }
                // Not a valid opener → literal dollar.
                pending.append("$")
                i += 1
                continue
            }

            pending.append(c)
            i += 1
        }

        flushPending()
    }

    /// Inverse of `MarkdownSerializer.rewriteImageSrcForDisk`. The Markdown
    /// on disk stores `./assets/<filename>`; the WKWebView can't resolve
    /// that relative path because the editor HTML is loaded from the App
    /// bundle, not from the document's directory. Rewrite to our custom
    /// scheme so `AssetURLSchemeHandler` serves the file from
    /// `<docDir>/assets/`.
    private func rewriteImageSrcForRuntime(_ src: String) -> String {
        // Canonical disk form is `./assets/<file>`, but hand-authored files and
        // other editors commonly write the bare relative `assets/<file>` (no
        // `./`). Accept both — first save normalizes back to `./assets/` — so
        // externally-created docs display their images too. Absolute paths,
        // http(s) URLs, and other relative dirs are left untouched.
        let canonicalPrefix = "./assets/"
        let barePrefix = "assets/"
        let filename: String
        if src.hasPrefix(canonicalPrefix) {
            filename = String(src.dropFirst(canonicalPrefix.count))
        } else if src.hasPrefix(barePrefix) {
            filename = String(src.dropFirst(barePrefix.count))
        } else {
            return src
        }
        return "donemd-asset://\(filename)"
    }

    /// Extract the `src` from a `<video …>` HTML string (#88). Returns `nil`
    /// if the string isn't a `<video>` tag or has no `src`, so the caller can
    /// fall through to the verbatim raw-markdown block. Kept deliberately
    /// small: only the `<video>` we emit (and common hand-written variants)
    /// need to round-trip; the disk form is canonicalized on save.
    static func parseVideoSrc(fromRawHTML raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasPrefix("<video") else { return nil }
        // Match src="…" or src='…' in the opening tag.
        let pattern = "src\\s*=\\s*(\"([^\"]*)\"|'([^']*)')"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(
                  in: trimmed,
                  range: NSRange(trimmed.startIndex..., in: trimmed)
              )
        else { return nil }
        // Group 2 = double-quoted value, group 3 = single-quoted value.
        for group in [2, 3] {
            let r = match.range(at: group)
            if r.location != NSNotFound, let swiftRange = Range(r, in: trimmed) {
                let value = String(trimmed[swiftRange])
                return value.isEmpty ? nil : value
            }
        }
        return nil
    }
}
