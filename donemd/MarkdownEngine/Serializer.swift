import Foundation

/// Converts a Tiptap document tree back into canonical Markdown source.
///
/// Canonical form (locked here, ratified in ADR-0002 by Slice 7):
///   - Headings:           ATX (`#`), never setext
///   - Bullets:            `-` only
///   - Ordered list start: explicit "<n>. " per item; default 1
///   - Block separators:   exactly one blank line between blocks
///   - Code blocks:        triple-backtick fenced, language tag preserved
///   - Tables:             pipe-delimited, no manual padding (Slice 5 lands)
///   - Lists:              2-space continuation indent
///   - Image src:          `donemd-asset://<filename>` → `./assets/<filename>`
///   - Trailing newline:   exactly one
///
/// `parse → serialize` is a fixed point on canonical input (idempotent).
struct MarkdownSerializer {
    private let assetSchemePrefix = "donemd-asset://"
    private let markdownAssetsPath = "./assets/"

    /// Serialize a Tiptap doc node to a Markdown string.
    func serialize(document root: TiptapNode) -> String {
        guard root.type == "doc", let blocks = root.content else { return "\n" }
        let parts = blocks.compactMap { serializeBlock($0) }
        if parts.isEmpty { return "\n" }
        return parts.joined(separator: "\n\n") + "\n"
    }

    // MARK: Block

    private func serializeBlock(_ node: TiptapNode) -> String? {
        switch node.type {
        case "paragraph":
            let inline = serializeInlineChildren(node.content ?? [])
            // An empty paragraph still emits a blank-line slot; keep as empty string.
            return inline
        case "heading":
            let level = intAttr(node.attrs, key: "level") ?? 1
            let prefix = String(repeating: "#", count: max(1, min(6, level)))
            let inline = serializeInlineChildren(node.content ?? [])
            return inline.isEmpty ? prefix : "\(prefix) \(inline)"
        case "blockquote":
            let inner = (node.content ?? [])
                .compactMap { serializeBlock($0) }
                .joined(separator: "\n\n")
            return inner
                .components(separatedBy: "\n")
                .map { line in line.isEmpty ? ">" : "> \(line)" }
                .joined(separator: "\n")
        case "callout":
            // GitHub callout: `> [!TYPE]` header line followed by body
            // lines, all prefixed with `> `. TYPE is always serialized
            // uppercase per GitHub's renderer (only ALL-CAPS triggers the
            // callout box; lowercase falls back to a plain blockquote).
            let type = (stringAttr(node.attrs, key: "type") ?? "note").uppercased()
            let body = (node.content ?? [])
                .compactMap { serializeBlock($0) }
                .joined(separator: "\n\n")
            let inner = body.isEmpty ? "[!\(type)]" : "[!\(type)]\n\(body)"
            return inner
                .components(separatedBy: "\n")
                .map { line in line.isEmpty ? ">" : "> \(line)" }
                .joined(separator: "\n")
        case "bulletList":
            return serializeList(node, ordered: false)
        case "orderedList":
            return serializeList(node, ordered: true)
        case "taskList":
            return serializeTaskList(node)
        case "table":
            return serializeTable(node)
        case "codeBlock":
            let language = stringAttr(node.attrs, key: "language") ?? ""
            let body = (node.content ?? []).compactMap { $0.text }.joined()
            return "```\(language)\n\(body)\n```"
        case "horizontalRule":
            return "---"
        case "image":
            // Block-level image (rare — Tiptap usually wraps in paragraph).
            return serializeInline(node)
        case "video":
            // Local video (#88). Canonical disk form: a single-line
            // `<video controls src="./assets/<file>"></video>` — byte-stable
            // round-trip (ASTConverter parses it straight back to this node).
            // runtime `donemd-asset://` → disk `./assets/` via the shared
            // image rewrite (same asset store).
            let src = rewriteImageSrcForDisk(stringAttr(node.attrs, key: "src") ?? "")
            return "<video controls src=\"\(src)\"></video>"
        case "raw_markdown_block":
            // Raw fallback content (HTML / callouts / …). Emit the stored
            // source verbatim — no canonicalization, no escaping.
            return stringAttr(node.attrs, key: "raw") ?? ""
        case "math_block":
            // Canonical block-math form (Phase 5 M2): `$$` on its own line,
            // the LaTeX body verbatim (may be multi-line), `$$` on its own
            // line. Single-line `$$x$$` input normalizes to this on first
            // save (ADR-0002 stable normalization). The latex string is
            // stored raw in attrs and re-emitted byte-for-byte regardless of
            // whether KaTeX can render it.
            let latex = stringAttr(node.attrs, key: "latex") ?? ""
            return "$$\n\(latex)\n$$"
        case "feishu_placeholder_block":
            return serializeFeishuPlaceholder(node)
        default:
            // Anything else falls through. Future slices can extend.
            return nil
        }
    }

    /// Round-trip a `feishu_placeholder_block` node back to its disk-form
    /// magic comment. Reads the typed attrs ASTConverter wrote; rebuilds
    /// the `FeishuPlaceholder` value; hands off to the engine's serializer
    /// so the field-order contract (ADR-0007) lives in one place.
    private func serializeFeishuPlaceholder(_ node: TiptapNode) -> String {
        let placeholder = FeishuPlaceholder(
            type: stringAttr(node.attrs, key: "type") ?? "",
            blockId: stringAttr(node.attrs, key: "block_id") ?? "",
            blockToken: stringAttr(node.attrs, key: "block_token"),
            title: stringAttr(node.attrs, key: "title") ?? "",
            summary: stringAttr(node.attrs, key: "summary"),
            url: stringAttr(node.attrs, key: "url") ?? "",
            createdInFeishuAt: stringAttr(node.attrs, key: "created_in_feishu_at"),
            unknownFields: extractUnknownPlaceholderFields(node.attrs)
        )
        return FeishuPlaceholderEngine.serialize(placeholder)
    }

    private func extractUnknownPlaceholderFields(
        _ attrs: [String: AttrValue]?
    ) -> [UnknownPlaceholderField] {
        guard let attrs = attrs,
              let raw = attrs["unknown_fields"],
              case .array(let items) = raw else {
            return []
        }
        return items.compactMap { item in
            guard case .object(let obj) = item,
                  case .string(let key)? = obj["key"],
                  case .string(let value)? = obj["value"] else {
                return nil
            }
            return UnknownPlaceholderField(key: key, value: value)
        }
    }

    private func serializeList(_ list: TiptapNode, ordered: Bool) -> String {
        let items = list.content ?? []
        let start = ordered ? (intAttr(list.attrs, key: "start") ?? 1) : 1
        var lines: [String] = []
        for (index, item) in items.enumerated() {
            let bullet = ordered ? "\(start + index). " : "- "
            let indent = String(repeating: " ", count: bullet.count)
            let body = (item.content ?? []).compactMap { serializeBlock($0) }
            // Each child block becomes one or more lines; first line gets the
            // bullet, subsequent lines get continuation indent.
            for (blockIndex, block) in body.enumerated() {
                let blockLines = block.components(separatedBy: "\n")
                for (lineIndex, line) in blockLines.enumerated() {
                    if blockIndex == 0 && lineIndex == 0 {
                        lines.append(bullet + line)
                    } else {
                        lines.append(line.isEmpty ? "" : indent + line)
                    }
                }
                // Multi-block list items get a blank line between blocks.
                if blockIndex < body.count - 1 {
                    lines.append("")
                }
            }
        }
        return lines.joined(separator: "\n")
    }

    private func serializeTaskList(_ list: TiptapNode) -> String {
        let items = list.content ?? []
        var lines: [String] = []
        for item in items {
            let checked = boolAttr(item.attrs, key: "checked") ?? false
            let bullet = "- [\(checked ? "x" : " ")] "
            let indent = String(repeating: " ", count: bullet.count)
            let body = (item.content ?? []).compactMap { serializeBlock($0) }
            for (blockIndex, block) in body.enumerated() {
                let blockLines = block.components(separatedBy: "\n")
                for (lineIndex, line) in blockLines.enumerated() {
                    if blockIndex == 0 && lineIndex == 0 {
                        lines.append(bullet + line)
                    } else {
                        lines.append(line.isEmpty ? "" : indent + line)
                    }
                }
                if blockIndex < body.count - 1 {
                    lines.append("")
                }
            }
        }
        return lines.joined(separator: "\n")
    }

    /// GFM table — pipe-delimited, no manual padding. The header row is
    /// followed by an alignment row (`|---|---|`); body rows follow.
    private func serializeTable(_ table: TiptapNode) -> String {
        let rows = table.content ?? []
        guard !rows.isEmpty else { return "" }
        // First row is the header (we always emit one when parsing).
        let headerCells = (rows[0].content ?? []).map { cellInline($0) }
        let separator = headerCells.map { _ in "---" }
        var lines: [String] = [
            "| \(headerCells.joined(separator: " | ")) |",
            "| \(separator.joined(separator: " | ")) |",
        ]
        for row in rows.dropFirst() {
            let cells = (row.content ?? []).map { cellInline($0) }
            lines.append("| \(cells.joined(separator: " | ")) |")
        }
        return lines.joined(separator: "\n")
    }

    /// Render a tableCell / tableHeader's first block as a single inline
    /// string. Table cells allow block content (`block+`), so the first block
    /// may be a paragraph OR a heading (a header cell styled with a heading
    /// level), a blockquote, etc. GFM tables can't express block structure —
    /// collapse whatever's there to inline text. We must read the block's
    /// inline `content`, not `node.text` (block nodes carry their text in
    /// `content`, so `node.text` is nil — the old paragraph-only path dropped
    /// header text entirely once a header cell held a heading).
    private func cellInline(_ cell: TiptapNode) -> String {
        guard let blocks = cell.content, let first = blocks.first else { return "" }
        // First block's inline children, whatever the block type (paragraph,
        // heading, …). Falls back to any nested text if it has no inline model.
        if let inline = first.content, !inline.isEmpty {
            return serializeInlineChildren(inline)
        }
        return collectText(first)
    }

    /// Depth-first concatenation of every descendant `text` — last-resort
    /// fallback for a cell block with no direct inline content.
    private func collectText(_ node: TiptapNode) -> String {
        var out = node.text ?? ""
        for child in node.content ?? [] { out += collectText(child) }
        return out
    }

    // MARK: Inline

    private func serializeInlineChildren(_ nodes: [TiptapNode]) -> String {
        nodes.map { serializeInline($0) }.joined()
    }

    private func serializeInline(_ node: TiptapNode) -> String {
        switch node.type {
        case "text":
            return applyMarks(text: node.text ?? "", marks: node.marks ?? [])
        case "hardBreak":
            return "\\\n"
        case "image":
            let src = rewriteImageSrcForDisk(stringAttr(node.attrs, key: "src") ?? "")
            let alt = stringAttr(node.attrs, key: "alt") ?? ""
            if let title = stringAttr(node.attrs, key: "title"), !title.isEmpty {
                return "![\(alt)](\(src) \"\(title)\")"
            }
            return "![\(alt)](\(src))"
        case "math_inline":
            // Inline math (Phase 5 M2): `$latex$`. Stored raw in attrs,
            // re-emitted verbatim (KaTeX validity is irrelevant to disk form).
            let latex = stringAttr(node.attrs, key: "latex") ?? ""
            return "$\(latex)$"
        default:
            // Unknown inline node: best-effort serialize children if any.
            return serializeInlineChildren(node.content ?? [])
        }
    }

    /// Apply marks to a text run, innermost (closest to the text) first so the
    /// resulting Markdown nests correctly.
    private func applyMarks(text: String, marks: [TiptapMark]) -> String {
        var result = text
        for mark in marks {
            switch mark.type {
            case "code":
                result = "`\(result)`"
            case "italic":
                result = "*\(result)*"
            case "bold":
                result = "**\(result)**"
            case "strike":
                result = "~~\(result)~~"
            case "link":
                let href = stringAttr(mark.attrs, key: "href") ?? ""
                if let title = stringAttr(mark.attrs, key: "title"), !title.isEmpty {
                    result = "[\(result)](\(href) \"\(title)\")"
                } else {
                    result = "[\(result)](\(href))"
                }
            default:
                break
            }
        }
        return result
    }

    // MARK: Image src rewrite

    /// Convert runtime `donemd-asset://<filename>` URLs back to the
    /// disk-form relative path `./assets/<filename>` that we keep in
    /// the actual Markdown source on disk.
    private func rewriteImageSrcForDisk(_ src: String) -> String {
        guard src.hasPrefix(assetSchemePrefix) else { return src }
        return markdownAssetsPath + String(src.dropFirst(assetSchemePrefix.count))
    }

    // MARK: AttrValue extraction

    private func intAttr(_ attrs: [String: AttrValue]?, key: String) -> Int? {
        guard let attrs = attrs, let value = attrs[key], case .int(let i) = value else {
            return nil
        }
        return i
    }

    private func stringAttr(_ attrs: [String: AttrValue]?, key: String) -> String? {
        guard let attrs = attrs, let value = attrs[key], case .string(let s) = value else {
            return nil
        }
        return s
    }

    private func boolAttr(_ attrs: [String: AttrValue]?, key: String) -> Bool? {
        guard let attrs = attrs, let value = attrs[key], case .bool(let b) = value else {
            return nil
        }
        return b
    }
}
