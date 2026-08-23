import Foundation

/// Bidirectional, pure-function converter between Feishu's flat block tree
/// (`[FeishuBlock]`, mirroring docx OpenAPI's `raw_content`) and local
/// Markdown source.
///
/// The two public entry points form the contract for [[结构保真同步]]:
/// - `toMarkdown([FeishuBlock]) -> String` — Feishu → local
/// - `toFeishuBlocks(String) -> [FeishuBlock]` — local → Feishu
///
/// Implementation routes everything through `MarkdownEngine` and
/// `TiptapNode`, so any block type our existing parser/serializer
/// already handles in canonical form (ATX headings, `-` lists, fenced
/// code, etc. — see ADR-0002) round-trips for free. The Feishu-specific
/// translation layer here is the `[FeishuBlock] ↔ TiptapNode` bridge.
///
/// Scope today (v2-4c, #46): 8 basic block types — heading 1-6,
/// paragraph, ordered/unordered list, todo, quote, code, divider, image —
/// plus rich blocks (callout × 5, GFM table, mermaid) and placeholder
/// blocks (sheet / mindnote / board / bitable / attachment / video /
/// embed) routed through the `feishu_placeholder_block` Tiptap node.
public enum FeishuStructuralConverter {

    // MARK: Feishu → Markdown

    /// Render a flat Feishu block list as canonical Markdown source.
    /// The list must contain exactly one `page` (block_type=1) root —
    /// inputs without a page block return an empty string (consistent
    /// with `MarkdownEngine.parse(markdown: "")`).
    ///
    /// Discards conversion warnings; callers that want to surface them
    /// (e.g. the metadata-card "nested-content dropped" badge) call
    /// `toMarkdownWithWarnings` instead.
    public static func toMarkdown(_ blocks: [FeishuBlock]) -> String {
        toMarkdownWithWarnings(blocks).value
    }

    /// Like `toMarkdown` but also returns warnings produced during
    /// conversion. v2-4c emits one warning kind:
    /// `nestedContentDroppedInPlaceholder` — a Feishu placeholder block
    /// (sheet / mindnote / board / …) had children Done.md can't preserve
    /// locally because placeholder blocks are atom nodes (ADR-0007 §
    /// 已知限制 #1). The metadata-card badge subscribes to this signal.
    public static func toMarkdownWithWarnings(_ blocks: [FeishuBlock]) -> ConversionResult<String> {
        let ctx = ConversionContext()
        let tiptap = blocksToTiptap(blocks, ctx: ctx)
        // Inline color stripping is detected at decoder time and stamped
        // on each TextRun via `style.hadStrippedFeishuColor`. Aggregate
        // here once into a single warning — per-run noise would drown
        // the dialog. Done after the walk so we capture color from
        // every block kind (text / heading / list / table cell / …).
        let strippedColorRunCount = countStrippedColorRuns(blocks: blocks)
        if strippedColorRunCount > 0 {
            ctx.emit(.feishuInlineColorStripped(runCount: strippedColorRunCount))
        }
        return ConversionResult(
            value: MarkdownEngine.serialize(document: tiptap),
            warnings: aggregateWarnings(ctx.warnings)
        )
    }

    /// Roll up per-occurrence warnings of the same kind into a single
    /// summary entry. `tableCellBlockContentDropped` is emitted once
    /// per affected cell during the walk; the dialog wants "M 处" not
    /// M individual lines. Other warning kinds aggregate themselves
    /// at emit time and pass through unchanged.
    private static func aggregateWarnings(
        _ warnings: [ConversionWarning]
    ) -> [ConversionWarning] {
        var rolled: [ConversionWarning] = []
        var droppedCellTotal = 0
        for w in warnings {
            switch w {
            case .tableCellBlockContentDropped(let n):
                droppedCellTotal += n
            default:
                rolled.append(w)
            }
        }
        if droppedCellTotal > 0 {
            rolled.append(.tableCellBlockContentDropped(cellCount: droppedCellTotal))
        }
        return rolled
    }

    /// Count text runs whose decoder marked them as having had Feishu
    /// inline color stripped. Walks every block payload that carries
    /// a `[TextElement]` — text / heading / quote / list-item / code
    /// fence / table cell. Placeholder blocks have no inline runs;
    /// page payload's title elements DO get walked because the title
    /// surfaces as a leading H1 in the pulled body.
    private static func countStrippedColorRuns(blocks: [FeishuBlock]) -> Int {
        var count = 0
        for block in blocks {
            for run in extractTextRuns(from: block.payload) {
                if run.style.hadStrippedFeishuColor { count += 1 }
            }
        }
        return count
    }

    private static func extractTextRuns(
        from payload: FeishuBlock.Payload
    ) -> [FeishuBlock.TextRun] {
        let elements: [FeishuBlock.TextElement]
        switch payload {
        case .page(let p):
            elements = p.title.elements
        case .text(let t),
             .heading(_, let t),
             .bullet(let t),
             .ordered(let t),
             .quote(let t):
            elements = t.elements
        case .todo(let t, _):
            elements = t.elements
        case .code(let c):
            elements = c.elements
        case .callout, .divider, .image, .table, .tableCell, .placeholder:
            // callout / table cells carry their text in *child* blocks, so
            // their inline runs surface elsewhere in the walk; the empty
            // payloads have no inline at all.
            elements = []
        }
        return elements.compactMap { element in
            if case .textRun(let run) = element { return run }
            return nil
        }
    }

    // MARK: Markdown → Feishu

    /// Parse Markdown source and emit a flat Feishu block list rooted at
    /// a synthetic page block. Most blocks get deterministic synthetic
    /// IDs (`blk_000001`, …) — `feishu_placeholder_block` nodes are the
    /// exception: their `block_id` attr is preserved verbatim because it
    /// must match the Feishu-side block for `preserve_existing` push to
    /// resolve. Production callers may overwrite the synthetic IDs after
    /// a successful upload; placeholder IDs are sticky.
    public static func toFeishuBlocks(_ markdown: String) -> [FeishuBlock] {
        let tiptap = MarkdownEngine.parse(markdown: markdown)
        return tiptapToBlocks(tiptap)
    }

    /// Convert a Tiptap document directly to Feishu blocks, skipping the
    /// markdown round-trip. The PushCoordinator uses this entry point so a
    /// block-level image node (rewritten by `FeishuImageUploadStage` to
    /// carry `feishu://image/<token>`) survives all the way to the wire as
    /// an `ImagePayload(token:…)` instead of being collapsed back into a
    /// paragraph by the markdown parser's inline-image flattening.
    public static func toFeishuBlocks(tiptap: TiptapNode) -> [FeishuBlock] {
        return tiptapToBlocks(tiptap)
    }

    // MARK: - Conversion result + warnings

    public struct ConversionResult<T>: Equatable where T: Equatable {
        public let value: T
        public let warnings: [ConversionWarning]

        public init(value: T, warnings: [ConversionWarning] = []) {
            self.value = value
            self.warnings = warnings
        }
    }

    public enum ConversionWarning: Equatable {
        /// A Feishu placeholder block had nested children. The outer
        /// placeholder survives; the children are dropped because a
        /// `feishu_placeholder_block` is a Tiptap atom (no inline body,
        /// no child blocks). Carries the Feishu block ID + the count of
        /// dropped immediate children for diagnostic display.
        case nestedContentDroppedInPlaceholder(blockId: String, droppedChildCount: Int)

        /// Pull-side: Feishu source had `text_color` / `background_color`
        /// on inline runs that Done.md's schema can't represent yet
        /// (Phase 5 polish, GH #59). The text content is preserved; the
        /// color isn't. `runCount` aggregates across the whole document
        /// — Done.md surfaces a single "N 处文字颜色未保留" line in the
        /// pull result dialog, not per-run noise.
        case feishuInlineColorStripped(runCount: Int)

        /// Pull-side: a Feishu table cell contained block-level content
        /// (callout / list / heading / nested table / image / etc.)
        /// that GFM markdown's table syntax can't carry — GFM cells
        /// only hold inline content. Done.md collapses each such cell
        /// to its first text block (or empty if there's no text), and
        /// emits this warning so the user knows the cell isn't
        /// faithful to the Feishu side. `cellCount` aggregates across
        /// the whole document. Workaround in PRD: keep block content
        /// outside the table on Feishu side, or accept the loss.
        case tableCellBlockContentDropped(cellCount: Int)
    }

    /// Mutable bookkeeping for one `[FeishuBlock] → TiptapNode` walk.
    /// Carried through `blocksToTiptap` and the helpers it calls so
    /// warnings emitted deep in the tree bubble up to the caller without
    /// passing return tuples through every helper signature. Reference
    /// type so the recursion can mutate without `inout` plumbing.
    private final class ConversionContext {
        var warnings: [ConversionWarning] = []

        func emit(_ warning: ConversionWarning) {
            warnings.append(warning)
        }
    }

    // MARK: - [FeishuBlock] → TiptapNode

    private static func blocksToTiptap(_ blocks: [FeishuBlock], ctx: ConversionContext) -> TiptapNode {
        guard !blocks.isEmpty else { return .emptyDoc }
        let byId = Dictionary(uniqueKeysWithValues: blocks.map { ($0.blockId, $0) })
        guard let page = blocks.first(where: { if case .page = $0.payload { return true } else { return false } }) else {
            return .emptyDoc
        }
        let topLevelIds = page.children ?? []
        let topLevelBlocks = topLevelIds.compactMap { byId[$0] }
        var content = renderSiblings(topLevelBlocks, byId: byId, ctx: ctx)

        // Notion-style title binding (v2-9b step1.5): the page block's title
        // is the document's authoritative title on Feishu. Pull surfaces it
        // as a leading H1 so it's editable in-line; the matching push side
        // extracts the first H1 back into the page-block title. Empty title
        // → no prepend (don't add a stray "# " when the doc has no title).
        if case .page(let pagePayload) = page.payload {
            let titleInlines = inline(from: pagePayload.title)
            if !titleInlines.isEmpty {
                let titleHeading = TiptapNode(
                    type: "heading",
                    attrs: ["level": .int(1)],
                    content: titleInlines
                )
                content.insert(titleHeading, at: 0)
            }
        }

        return TiptapNode(type: "doc", content: content.isEmpty ? [TiptapNode(type: "paragraph")] : content)
    }

    /// Walk a sibling block sequence, grouping consecutive list-ish blocks
    /// (bullet / ordered / todo) into a Tiptap list container.
    private static func renderSiblings(
        _ siblings: [FeishuBlock],
        byId: [String: FeishuBlock],
        ctx: ConversionContext
    ) -> [TiptapNode] {
        var out: [TiptapNode] = []
        var i = 0
        while i < siblings.count {
            let block = siblings[i]
            switch block.payload {
            case .bullet, .ordered, .todo:
                let kind = listKind(of: block.payload)
                var run: [FeishuBlock] = []
                while i < siblings.count, listKind(of: siblings[i].payload) == kind {
                    run.append(siblings[i])
                    i += 1
                }
                out.append(renderListContainer(kind: kind, items: run, byId: byId, ctx: ctx))
            default:
                if let node = renderSingle(block, byId: byId, ctx: ctx) {
                    out.append(node)
                }
                i += 1
            }
        }
        return out
    }

    private enum ListKind { case bullet, ordered, todo }

    private static func listKind(of payload: FeishuBlock.Payload) -> ListKind? {
        switch payload {
        case .bullet: return .bullet
        case .ordered: return .ordered
        case .todo: return .todo
        default: return nil
        }
    }

    private static func renderListContainer(
        kind: ListKind?,
        items: [FeishuBlock],
        byId: [String: FeishuBlock],
        ctx: ConversionContext
    ) -> TiptapNode {
        let containerType: String
        switch kind {
        case .bullet: containerType = "bulletList"
        case .ordered: containerType = "orderedList"
        case .todo: containerType = "taskList"
        case .none: containerType = "bulletList"
        }
        let itemNodes = items.map { renderListItem($0, byId: byId, ctx: ctx) }
        return TiptapNode(type: containerType, content: itemNodes)
    }

    private static func renderListItem(
        _ block: FeishuBlock,
        byId: [String: FeishuBlock],
        ctx: ConversionContext
    ) -> TiptapNode {
        let (itemType, paragraph, attrs) = listItemShell(for: block)
        var content: [TiptapNode] = [paragraph]
        let childIds = block.children ?? []
        if !childIds.isEmpty {
            let childBlocks = childIds.compactMap { byId[$0] }
            let nested = renderSiblings(childBlocks, byId: byId, ctx: ctx)
            content.append(contentsOf: nested)
        }
        return TiptapNode(type: itemType, attrs: attrs, content: content)
    }

    private static func listItemShell(
        for block: FeishuBlock
    ) -> (itemType: String, paragraph: TiptapNode, attrs: [String: AttrValue]?) {
        switch block.payload {
        case .bullet(let payload):
            return ("listItem", paragraph(from: payload), nil)
        case .ordered(let payload):
            return ("listItem", paragraph(from: payload), nil)
        case .todo(let payload, let done):
            return ("taskItem", paragraph(from: payload), ["checked": .bool(done)])
        default:
            // Should not reach: caller already filtered list-ish payloads.
            return ("listItem", TiptapNode(type: "paragraph"), nil)
        }
    }

    private static func renderSingle(
        _ block: FeishuBlock,
        byId: [String: FeishuBlock],
        ctx: ConversionContext
    ) -> TiptapNode? {
        switch block.payload {
        case .page:
            // Page-as-child shouldn't happen — pages are roots only.
            return nil
        case .text(let payload):
            return paragraph(from: payload)
        case .heading(let level, let payload):
            return TiptapNode(
                type: "heading",
                attrs: ["level": .int(max(1, min(level, 6)))],
                content: inline(from: payload)
            )
        case .quote(let payload):
            // Feishu quote = single-block; children are nested quote
            // contents in rare multi-paragraph cases.
            var blocks: [TiptapNode] = [paragraph(from: payload)]
            let childIds = block.children ?? []
            if !childIds.isEmpty {
                let childBlocks = childIds.compactMap { byId[$0] }
                blocks.append(contentsOf: renderSiblings(childBlocks, byId: byId, ctx: ctx))
            }
            return TiptapNode(type: "blockquote", content: blocks)
        case .code(let payload):
            var attrs: [String: AttrValue]? = nil
            if let lang = payload.language, !lang.isEmpty {
                attrs = ["language": .string(lang)]
            }
            let textNode = TiptapNode.text(plainText(from: payload.elements))
            return TiptapNode(type: "codeBlock", attrs: attrs, content: [textNode])
        case .divider:
            return TiptapNode(type: "horizontalRule")
        case .image(let payload):
            var attrs: [String: AttrValue] = [:]
            // Prefer explicit src; fall back to a `feishu://` reference
            // for image_token so the canonical Markdown stays meaningful
            // before v2-5 wires real upload/download.
            if let src = payload.src, !src.isEmpty {
                attrs["src"] = .string(src)
            } else if let token = payload.token, !token.isEmpty {
                attrs["src"] = .string("feishu://image/\(token)")
            } else {
                attrs["src"] = .string("")
            }
            attrs["alt"] = .string(payload.alt ?? "")
            return TiptapNode(type: "image", attrs: attrs)
        case .callout(let payload):
            let type = FeishuCalloutType.from(
                emoji: payload.emoji,
                backgroundColor: payload.backgroundColor
            )
            // Children: paragraphs / headings / lists / nested quotes.
            // Disallowed children (codeBlock / table / horizontalRule /
            // image) drop here so the Tiptap callout schema stays valid;
            // matches ASTConverter.convertCalloutIfMatched's filter.
            let disallowed: Set<String> = ["codeBlock", "table", "horizontalRule", "image"]
            let childIds = block.children ?? []
            let childBlocks = childIds.compactMap { byId[$0] }
            let rendered = renderSiblings(childBlocks, byId: byId, ctx: ctx)
                .filter { !disallowed.contains($0.type) }
            // Tiptap callout schema requires `(paragraph | … )+`. Empty
            // body → seed an empty paragraph (matches ASTConverter).
            let content = rendered.isEmpty ? [TiptapNode(type: "paragraph")] : rendered
            return TiptapNode(
                type: "callout",
                attrs: ["type": .string(type.rawValue)],
                content: content
            )
        case .table(let payload):
            return renderTable(block: block, payload: payload, byId: byId, ctx: ctx)
        case .tableCell:
            // Cells are only meaningful as table children — outside that
            // context they're meaningless. Drop silently.
            return nil
        case .placeholder(let payload):
            // Video: a `view` block (block_type 33) wraps a child `file`
            // block (block_type 23) that carries the real video token +
            // filename (see FeishuBlockEncoder case 33). Absorb the child
            // here — where `byId` resolves it — so the video survives pull
            // as a single 飞书视频 placeholder instead of being lost. The
            // absorbed file child is *not* content loss, so we deliberately
            // skip the `nestedContentDroppedInPlaceholder` warning for it.
            if payload.subtype == .video {
                let childBlocks = (block.children ?? []).compactMap { byId[$0] }
                let fileChild = childBlocks.first { child in
                    if case .placeholder(let cp) = child.payload {
                        return cp.subtype == .attachment
                    }
                    return false
                }
                if let fileChild,
                   case .placeholder(let filePayload) = fileChild.payload {
                    let enriched = FeishuBlock.PlaceholderPayload(
                        subtype: .video,
                        blockToken: filePayload.blockToken,
                        title: filePayload.title,
                        summary: payload.summary,
                        url: filePayload.blockToken.map { "feishu://video/\($0)" }
                            ?? payload.url
                    )
                    return placeholderNode(blockId: block.blockId, payload: enriched)
                }
                // No file child (unexpected shape) — emit the bare video
                // card rather than warn about "dropped" children that
                // aren't actually content loss.
                return placeholderNode(blockId: block.blockId, payload: payload)
            }
            // Atom node — has no inline content and no child blocks.
            // Feishu rarely (but legally) nests blocks inside a sheet /
            // mindnote / bitable; ADR-0007 § 已知限制 #1 explicitly
            // accepts that those nested children are dropped here, with
            // a warning that surfaces as the metadata-card "⚠️ 该文档含
            // 嵌套块，部分内容仅在飞书可见" badge.
            let droppedChildCount = (block.children ?? []).count
            if droppedChildCount > 0 {
                ctx.emit(.nestedContentDroppedInPlaceholder(
                    blockId: block.blockId,
                    droppedChildCount: droppedChildCount
                ))
            }
            return placeholderNode(blockId: block.blockId, payload: payload)
        case .bullet, .ordered, .todo:
            // Filtered earlier by renderSiblings; never reached here.
            return nil
        }
    }

    /// Build the `feishu_placeholder_block` Tiptap node from a Feishu
    /// payload. Field set + ordering matches `ASTConverter.makeFeishuPlaceholderBlock`
    /// so the two paths land at the same node shape — magic-comment input
    /// and Feishu API input round-trip through identical Tiptap state.
    private static func placeholderNode(
        blockId: String,
        payload: FeishuBlock.PlaceholderPayload
    ) -> TiptapNode {
        var attrs: [String: AttrValue] = [
            "type": .string(payload.subtype.rawValue),
            "block_id": .string(blockId),
            "title": .string(payload.title),
            "url": .string(payload.url),
        ]
        if let token = payload.blockToken {
            attrs["block_token"] = .string(token)
        }
        if let summary = payload.summary {
            attrs["summary"] = .string(summary)
        }
        if let created = payload.createdInFeishuAt {
            attrs["created_in_feishu_at"] = .string(created)
        }
        if !payload.unknownFields.isEmpty {
            attrs["unknown_fields"] = .array(payload.unknownFields.map { field in
                .object([
                    "key": .string(field.key),
                    "value": .string(field.value),
                ])
            })
        }
        return TiptapNode(type: "feishu_placeholder_block", attrs: attrs)
    }

    /// Render a Feishu table block as a Tiptap `table` node. The first
    /// row becomes `tableHeader` cells when `headerRow` is true (always
    /// true for v2 — GFM requires headers). Cell children flatten to a
    /// single `paragraph` because GFM table cells can't carry block
    /// content; rich-cell content (lists / nested tables) is a known
    /// limitation tracked in [[已知限制]].
    private static func renderTable(
        block: FeishuBlock,
        payload: FeishuBlock.TablePayload,
        byId: [String: FeishuBlock],
        ctx: ConversionContext
    ) -> TiptapNode {
        let cellIds = block.children ?? []
        let expected = max(0, payload.rowSize) * max(0, payload.columnSize)
        // Be defensive: if Feishu sends fewer cells than rowSize × columnSize
        // claims (corrupt input), pad/truncate so we never read past array.
        var cells: [TiptapNode] = []
        for i in 0..<expected {
            let blk = (i < cellIds.count) ? byId[cellIds[i]] : nil
            cells.append(renderTableCell(block: blk, byId: byId, ctx: ctx))
        }

        var rows: [TiptapNode] = []
        let cols = max(1, payload.columnSize)
        for r in 0..<max(1, payload.rowSize) {
            let rowSlice = Array(cells[r * cols ..< min((r + 1) * cols, cells.count)])
            // First row → header cells when payload says so.
            let isHeaderRow = payload.headerRow && r == 0
            let cellType = isHeaderRow ? "tableHeader" : "tableCell"
            let typedCells = rowSlice.map { cell -> TiptapNode in
                TiptapNode(type: cellType, content: cell.content)
            }
            rows.append(TiptapNode(type: "tableRow", content: typedCells))
        }
        return TiptapNode(type: "table", content: rows)
    }

    private static func renderTableCell(
        block: FeishuBlock?,
        byId: [String: FeishuBlock],
        ctx: ConversionContext
    ) -> TiptapNode {
        guard let block = block else {
            return TiptapNode(type: "tableCell", content: [TiptapNode(type: "paragraph")])
        }
        // A cell's children are block IDs; for GFM compatibility we
        // collapse to the first paragraph's inline content. If the cell
        // has no children (rare) use an empty paragraph.
        //
        // GFM markdown table cells can only carry inline content. When a
        // Feishu cell has block-level children other than a leading
        // `.text` (callout / list / heading / nested table / image),
        // those are dropped here. We emit a single warning per cell so
        // the user is told upfront the cell isn't faithful — not per
        // dropped child, since a cell can have many.
        let childBlocks = (block.children ?? []).compactMap { byId[$0] }
        let hasNonTextBlock = childBlocks.contains { blk in
            if case .text = blk.payload { return false } else { return true }
        }
        if hasNonTextBlock {
            ctx.emit(.tableCellBlockContentDropped(cellCount: 1))
        }
        let firstText: FeishuBlock? = childBlocks.first { blk in
            if case .text = blk.payload { return true } else { return false }
        }
        if case .text(let payload)? = firstText?.payload {
            let inlines = inline(from: payload)
            let para = TiptapNode(type: "paragraph", content: inlines.isEmpty ? nil : inlines)
            return TiptapNode(type: "tableCell", content: [para])
        }
        return TiptapNode(type: "tableCell", content: [TiptapNode(type: "paragraph")])
    }

    private static func paragraph(from payload: FeishuBlock.TextPayload) -> TiptapNode {
        let inlines = inline(from: payload)
        return TiptapNode(type: "paragraph", content: inlines.isEmpty ? nil : inlines)
    }

    private static func inline(from payload: FeishuBlock.TextPayload) -> [TiptapNode] {
        payload.elements.compactMap { element -> TiptapNode? in
            switch element {
            case .textRun(let run):
                guard !run.content.isEmpty else { return nil }
                return TiptapNode.text(run.content, marks: marks(from: run.style))
            }
        }
    }

    private static func marks(from style: FeishuBlock.TextElementStyle) -> [TiptapMark]? {
        var out: [TiptapMark] = []
        if style.bold { out.append(TiptapMark(type: "bold")) }
        if style.italic { out.append(TiptapMark(type: "italic")) }
        if style.strikethrough { out.append(TiptapMark(type: "strike")) }
        if style.inlineCode { out.append(TiptapMark(type: "code")) }
        if let href = style.link, !href.isEmpty {
            out.append(TiptapMark(type: "link", attrs: ["href": .string(href)]))
        }
        return out.isEmpty ? nil : out
    }

    private static func plainText(from elements: [FeishuBlock.TextElement]) -> String {
        elements.map { element in
            switch element {
            case .textRun(let run): return run.content
            }
        }.joined()
    }

    // MARK: - TiptapNode → [FeishuBlock]

    private static func tiptapToBlocks(_ doc: TiptapNode) -> [FeishuBlock] {
        var ctx = EmissionContext()
        let pageId = ctx.nextId()
        let topChildren = (doc.content ?? []).flatMap { node in
            emit(node: node, parentId: pageId, ctx: &ctx)
        }
        let page = FeishuBlock(
            blockId: pageId,
            parentId: nil,
            children: topChildren.isEmpty ? nil : topChildren,
            payload: .page(.init())
        )
        return [page] + ctx.emitted
    }

    /// Mutable bookkeeping for one toFeishuBlocks call.
    private struct EmissionContext {
        var counter: Int = 0
        var emitted: [FeishuBlock] = []

        mutating func nextId() -> String {
            counter += 1
            return String(format: "blk_%06d", counter)
        }

        mutating func push(_ block: FeishuBlock) {
            emitted.append(block)
        }
    }

    /// Convert one Tiptap block-level node into one or more Feishu blocks
    /// (containers like `bulletList` expand to multiple sibling items).
    /// Returns the IDs of the top-level blocks emitted, in order — caller
    /// uses these as `children` of the parent block.
    private static func emit(
        node: TiptapNode,
        parentId: String,
        ctx: inout EmissionContext
    ) -> [String] {
        switch node.type {
        case "paragraph":
            let id = ctx.nextId()
            let block = FeishuBlock(
                blockId: id,
                parentId: parentId,
                children: nil,
                payload: .text(textPayload(from: node.content ?? []))
            )
            ctx.push(block)
            return [id]

        case "heading":
            let level: Int
            if case .int(let v) = node.attrs?["level"] {
                level = max(1, min(v, 6))
            } else {
                level = 1
            }
            let id = ctx.nextId()
            let block = FeishuBlock(
                blockId: id,
                parentId: parentId,
                children: nil,
                payload: .heading(level: level, textPayload(from: node.content ?? []))
            )
            ctx.push(block)
            return [id]

        case "blockquote":
            let id = ctx.nextId()
            // Feishu quote payload comes from the *first* paragraph; any
            // remaining children become nested children blocks. This is
            // the lossy path for multi-paragraph quotes, but the round-
            // trip of the predominant single-paragraph case is exact.
            let children = node.content ?? []
            let firstParagraphInlines: [TiptapNode]
            let restChildren: [TiptapNode]
            if let first = children.first, first.type == "paragraph" {
                firstParagraphInlines = first.content ?? []
                restChildren = Array(children.dropFirst())
            } else {
                firstParagraphInlines = []
                restChildren = children
            }
            // Reserve the quote ID before emitting children so children's
            // parentId / page-children ordering match document order.
            let quoteId = ctx.nextId()
            let nestedIds = restChildren.flatMap { child in
                emit(node: child, parentId: quoteId, ctx: &ctx)
            }
            let block = FeishuBlock(
                blockId: quoteId,
                parentId: parentId,
                children: nestedIds.isEmpty ? nil : nestedIds,
                payload: .quote(textPayload(from: firstParagraphInlines))
            )
            // Splice the quote ahead of its children so document order is preserved.
            insertBlock(block, before: nestedIds, ctx: &ctx)
            // Fix the quote's id position in `emitted`: above call uses
            // current counter ordering; rebuild order strictly by
            // re-appending in document order. (See helper for details.)
            _ = quoteId
            return [quoteId]

        case "codeBlock":
            let lang: String? = {
                guard case .string(let s) = node.attrs?["language"] else { return nil }
                return s.isEmpty ? nil : s
            }()
            let id = ctx.nextId()
            let raw = (node.content ?? [])
                .compactMap { $0.text }
                .joined()
            let block = FeishuBlock(
                blockId: id,
                parentId: parentId,
                children: nil,
                payload: .code(.init(
                    elements: raw.isEmpty ? [] : [.textRun(.init(content: raw))],
                    language: lang
                ))
            )
            ctx.push(block)
            return [id]

        case "horizontalRule":
            let id = ctx.nextId()
            ctx.push(FeishuBlock(
                blockId: id,
                parentId: parentId,
                children: nil,
                payload: .divider
            ))
            return [id]

        case "image":
            let src: String? = {
                if case .string(let s) = node.attrs?["src"] { return s }
                return nil
            }()
            let alt: String? = {
                if case .string(let s) = node.attrs?["alt"] { return s }
                return nil
            }()
            let payload: FeishuBlock.ImagePayload
            if let src, src.hasPrefix("feishu://image/") {
                let token = String(src.dropFirst("feishu://image/".count))
                payload = .init(token: token, src: nil, alt: alt)
            } else {
                payload = .init(token: nil, src: src, alt: alt)
            }
            let id = ctx.nextId()
            ctx.push(FeishuBlock(
                blockId: id,
                parentId: parentId,
                children: nil,
                payload: .image(payload)
            ))
            return [id]

        case "bulletList":
            return emitListItems(items: node.content ?? [], kind: .bullet, parentId: parentId, ctx: &ctx)
        case "orderedList":
            return emitListItems(items: node.content ?? [], kind: .ordered, parentId: parentId, ctx: &ctx)
        case "taskList":
            return emitListItems(items: node.content ?? [], kind: .todo, parentId: parentId, ctx: &ctx)

        case "callout":
            return emitCallout(node, parentId: parentId, ctx: &ctx)
        case "table":
            return emitTable(node, parentId: parentId, ctx: &ctx)
        case "feishu_placeholder_block":
            if let id = emitPlaceholder(node, parentId: parentId, ctx: &ctx) {
                return [id]
            }
            return []

        case "text", "hardBreak":
            // Inline only; should never reach block-emission path — fall
            // through silently rather than corrupting the output.
            return []

        case "video":
            // Local video (#88): Feishu has no local-video block in v1, so
            // emit nothing. The FeishuImageUploadStage already recorded this
            // node in `Report.skippedVideos` (→ soft warning), and the local
            // asset + disk `<video>` line are kept untouched. Explicit case so
            // a video never falls into the silent `default` unremarked.
            return []

        default:
            // Unknown block (raw_markdown_block, …) — drop silently so
            // downstream slices can layer in support without fighting an
            // exhaustive switch.
            return []
        }
    }

    /// Convert a `feishu_placeholder_block` Tiptap node back into a
    /// `FeishuBlock` carrying a `.placeholder` payload. Differs from every
    /// other emit path in two ways:
    ///
    /// 1. **`block_id` is preserved verbatim** from the node's attrs, not
    ///    drawn from `ctx.nextId()`. The whole point of the placeholder
    ///    round-trip is to hand the original Feishu block ID back to
    ///    `PushCoordinator` (via `preserveExistingReference`) so it can
    ///    say "reference this existing block, don't recreate it".
    /// 2. **No children are emitted.** Placeholder blocks are atom nodes;
    ///    nesting is dropped at the inbound-from-Feishu boundary
    ///    (`renderSingle`), not here. By the time we're emitting, the
    ///    Tiptap tree never has children under a placeholder node.
    ///
    /// Returns `nil` when the node is malformed (missing required attrs)
    /// — caller drops it silently rather than corrupting the output.
    private static func emitPlaceholder(
        _ node: TiptapNode,
        parentId: String,
        ctx: inout EmissionContext
    ) -> String? {
        guard
            case .string(let typeRaw)? = node.attrs?["type"],
            let subtype = FeishuBlock.PlaceholderSubtype(rawValue: typeRaw),
            case .string(let blockId)? = node.attrs?["block_id"],
            !blockId.isEmpty,
            case .string(let title)? = node.attrs?["title"],
            case .string(let url)? = node.attrs?["url"]
        else {
            return nil
        }

        let blockToken: String? = {
            if case .string(let s)? = node.attrs?["block_token"], !s.isEmpty { return s }
            return nil
        }()
        let summary: String? = {
            if case .string(let s)? = node.attrs?["summary"] { return s }
            return nil
        }()
        let created: String? = {
            if case .string(let s)? = node.attrs?["created_in_feishu_at"], !s.isEmpty { return s }
            return nil
        }()
        let unknown = extractUnknownFields(node.attrs?["unknown_fields"])

        let payload = FeishuBlock.PlaceholderPayload(
            subtype: subtype,
            blockToken: blockToken,
            title: title,
            summary: summary,
            url: url,
            createdInFeishuAt: created,
            unknownFields: unknown
        )
        ctx.push(FeishuBlock(
            blockId: blockId,
            parentId: parentId,
            children: nil,
            payload: .placeholder(payload)
        ))
        return blockId
    }

    private static func extractUnknownFields(_ raw: AttrValue?) -> [UnknownPlaceholderField] {
        guard case .array(let items)? = raw else { return [] }
        return items.compactMap { item in
            guard
                case .object(let obj) = item,
                case .string(let key)? = obj["key"],
                case .string(let value)? = obj["value"]
            else {
                return nil
            }
            return UnknownPlaceholderField(key: key, value: value)
        }
    }

    private static func emitCallout(
        _ node: TiptapNode,
        parentId: String,
        ctx: inout EmissionContext
    ) -> [String] {
        let typeRaw: String = {
            if case .string(let s) = node.attrs?["type"] { return s.lowercased() }
            return "note"
        }()
        let type = FeishuCalloutType(rawValue: typeRaw) ?? .note
        let calloutId = ctx.nextId()

        // Filter disallowed children at emission boundary too (defense in
        // depth — ASTConverter does the same, but Tiptap state from JS
        // could violate the schema). Disallowed: codeBlock / table /
        // horizontalRule / image.
        let disallowed: Set<String> = ["codeBlock", "table", "horizontalRule", "image"]
        let allowedChildren = (node.content ?? []).filter { !disallowed.contains($0.type) }
        let nestedIds = allowedChildren.flatMap { child in
            emit(node: child, parentId: calloutId, ctx: &ctx)
        }

        let block = FeishuBlock(
            blockId: calloutId,
            parentId: parentId,
            children: nestedIds.isEmpty ? nil : nestedIds,
            payload: .callout(.init(
                // Wire-format named ID (e.g. "bulb"), NOT the Unicode
                // glyph — Feishu callout endpoint returns 1770006
                // schema mismatch when fed the codepoint. The Unicode
                // form is only used for local Tiptap rendering.
                emoji: type.wireEmojiId,
                backgroundColor: type.backgroundColor
            ))
        )
        insertBlock(block, before: nestedIds, ctx: &ctx)
        return [calloutId]
    }

    private static func emitTable(
        _ node: TiptapNode,
        parentId: String,
        ctx: inout EmissionContext
    ) -> [String] {
        let rowNodes = node.content ?? []
        let rowSize = rowNodes.count
        // Column count is the max cell count across rows; pads short rows
        // with empty cells so Feishu's invariant `children.count == rowSize ×
        // columnSize` always holds.
        let columnSize = rowNodes.map { ($0.content ?? []).count }.max() ?? 0
        guard rowSize > 0, columnSize > 0 else { return [] }

        // Detect header row: any row whose first cell is `tableHeader`.
        // Tiptap's parser places headers in row 0 only.
        let headerRow: Bool = {
            guard let first = rowNodes.first?.content?.first else { return false }
            return first.type == "tableHeader"
        }()

        let tableId = ctx.nextId()

        // Reserve cell IDs and emit cell + paragraph children. Order:
        // for r,c the cell at (r,c) and its inner text block.
        var cellIds: [String] = []
        for row in rowNodes {
            let cells = row.content ?? []
            for c in 0..<columnSize {
                let cellNode: TiptapNode? = (c < cells.count) ? cells[c] : nil
                let cellId = ctx.nextId()
                cellIds.append(cellId)

                // Inner text block: collapse cell's first paragraph into
                // a Feishu text block. Empty cells get an empty text block.
                let inlines = (cellNode?.content?.first(where: { $0.type == "paragraph" })?.content) ?? []
                let textPayloadValue = textPayload(from: inlines)
                let textId = ctx.nextId()
                ctx.push(FeishuBlock(
                    blockId: textId,
                    parentId: cellId,
                    children: nil,
                    payload: .text(textPayloadValue)
                ))
                // Splice the cell ahead of its child text block.
                let cellBlock = FeishuBlock(
                    blockId: cellId,
                    parentId: tableId,
                    children: [textId],
                    payload: .tableCell
                )
                insertBlock(cellBlock, before: [textId], ctx: &ctx)
            }
        }

        let tableBlock = FeishuBlock(
            blockId: tableId,
            parentId: parentId,
            children: cellIds,
            payload: .table(.init(
                rowSize: rowSize,
                columnSize: columnSize,
                headerRow: headerRow
            ))
        )
        insertBlock(tableBlock, before: cellIds, ctx: &ctx)
        return [tableId]
    }

    private static func emitListItems(
        items: [TiptapNode],
        kind: ListKind,
        parentId: String,
        ctx: inout EmissionContext
    ) -> [String] {
        var ids: [String] = []
        for item in items {
            ids.append(emitListItem(item, kind: kind, parentId: parentId, ctx: &ctx))
        }
        return ids
    }

    private static func emitListItem(
        _ item: TiptapNode,
        kind: ListKind,
        parentId: String,
        ctx: inout EmissionContext
    ) -> String {
        let children = item.content ?? []
        // Tiptap list items always lead with a paragraph (canonical
        // shape). Nested lists / blockquotes follow as additional siblings.
        let firstParagraphInlines: [TiptapNode]
        let nestedBlocks: [TiptapNode]
        if let first = children.first, first.type == "paragraph" {
            firstParagraphInlines = first.content ?? []
            nestedBlocks = Array(children.dropFirst())
        } else {
            firstParagraphInlines = []
            nestedBlocks = children
        }

        let itemId = ctx.nextId()
        let nestedIds = nestedBlocks.flatMap { child in
            emit(node: child, parentId: itemId, ctx: &ctx)
        }
        let payload = textPayload(from: firstParagraphInlines)
        let block: FeishuBlock
        switch kind {
        case .bullet:
            block = FeishuBlock(
                blockId: itemId, parentId: parentId,
                children: nestedIds.isEmpty ? nil : nestedIds,
                payload: .bullet(payload)
            )
        case .ordered:
            block = FeishuBlock(
                blockId: itemId, parentId: parentId,
                children: nestedIds.isEmpty ? nil : nestedIds,
                payload: .ordered(payload)
            )
        case .todo:
            let done: Bool = {
                if case .bool(let b) = item.attrs?["checked"] { return b }
                return false
            }()
            block = FeishuBlock(
                blockId: itemId, parentId: parentId,
                children: nestedIds.isEmpty ? nil : nestedIds,
                payload: .todo(payload, done: done)
            )
        }
        insertBlock(block, before: nestedIds, ctx: &ctx)
        return itemId
    }

    /// Splice a parent block ahead of its already-emitted children so
    /// `emitted` stays in document order (parent before its descendants).
    /// Without this, `emit` for a blockquote / list-item that pre-allocates
    /// its ID would put the parent *after* its children in the output list.
    private static func insertBlock(
        _ block: FeishuBlock,
        before childIds: [String],
        ctx: inout EmissionContext
    ) {
        guard !childIds.isEmpty else {
            ctx.push(block)
            return
        }
        if let firstChildIndex = ctx.emitted.firstIndex(where: { $0.blockId == childIds.first }) {
            ctx.emitted.insert(block, at: firstChildIndex)
        } else {
            ctx.push(block)
        }
    }

    private static func textPayload(from inlines: [TiptapNode]) -> FeishuBlock.TextPayload {
        var out: [FeishuBlock.TextElement] = []
        for node in inlines {
            switch node.type {
            case "text":
                let style = textElementStyle(from: node.marks ?? [])
                let content = node.text ?? ""
                if !content.isEmpty {
                    out.append(.textRun(.init(content: content, style: style)))
                }
            case "hardBreak":
                if case .textRun(var run) = out.last {
                    run.content += "\n"
                    out[out.count - 1] = .textRun(run)
                } else {
                    out.append(.textRun(.init(content: "\n")))
                }
            default:
                // Image/inline-extension etc. Out of v2-4a inline scope.
                break
            }
        }
        return .init(elements: out)
    }

    private static func textElementStyle(from marks: [TiptapMark]) -> FeishuBlock.TextElementStyle {
        var style = FeishuBlock.TextElementStyle()
        for mark in marks {
            switch mark.type {
            case "bold": style.bold = true
            case "italic": style.italic = true
            case "strike": style.strikethrough = true
            case "code": style.inlineCode = true
            case "link":
                if case .string(let href) = mark.attrs?["href"] {
                    style.link = href
                }
            default: break
            }
        }
        return style
    }
}
