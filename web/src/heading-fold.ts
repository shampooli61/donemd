// HeadingFold — collapse a heading's section in the Visual (Tiptap) pane,
// Feishu/Notion style: a chevron on the left of each foldable heading toggles
// hiding every block from just after the heading down to the next heading of
// the same-or-higher level (or end of document).
//
// State model (see plan flickering-beaming-mist.md § 状态流与防回环):
//   Swift's DonemdDocument is the SINGLE source of truth for which headings are
//   collapsed. A chevron click here does NOT optimistically fold — it fires the
//   `onToggle(ordinal, collapse)` callback (main.ts ships it to Swift as
//   `foldToggled`). Swift updates its set and broadcasts `applyFold` to BOTH
//   panes; only `applyFoldState()` (driven by that broadcast) mutates the
//   plugin's collapsed set. So a fold in one pane can never ping-pong back
//   (A → Swift → B, never B → Swift → A again).
//
// Fold is pure view state: the hidden blocks stay in the document, so
// getJSON() / disk serialization are untouched (folding never reaches `.md`).
//
// Ordinal contract: folding is keyed by "the Nth TOP-LEVEL heading" (direct
// child of the doc), counted in document order. The Markdown-source pane counts
// column-0 ATX `#` lines the same way, so the same ordinal means the same
// section on both sides. (This intentionally differs from heading-extractor.ts,
// which also recurses into callouts for the outline — a heading buried in a
// callout isn't a document section you'd fold.)

import { Extension } from '@tiptap/core';
import { Plugin, PluginKey } from '@tiptap/pm/state';
import type { EditorState, Transaction } from '@tiptap/pm/state';
import { Decoration, DecorationSet } from '@tiptap/pm/view';
import type { EditorView } from '@tiptap/pm/view';
import type { Node as ProseMirrorNode } from '@tiptap/pm/model';

export const headingFoldKey = new PluginKey<HeadingFoldState>('headingFold');

/** A top-level block, reduced to just what fold-range math needs. */
export interface FoldBlock {
  /** True if this block is a heading node. */
  isHeading: boolean;
  /** Heading level 1–6 (ignored when `isHeading` is false). */
  level: number;
}

/** The section a heading collapses: hide top-level blocks `[startBlock, endBlock)`. */
export interface FoldRange {
  /** 0-based ordinal of this heading among top-level headings, document order. */
  ordinal: number;
  /** Index of the heading's own top-level block. */
  headingBlock: number;
  /** First hidden block (always `headingBlock + 1`). */
  startBlock: number;
  /** One past the last hidden block (exclusive). `startBlock === endBlock` ⇒
   *  nothing to fold (heading immediately followed by a same/higher heading or
   *  end of doc) — such a heading gets no chevron. */
  endBlock: number;
}

/**
 * Pure fold-range computation over a flat list of top-level blocks. For each
 * heading, its section runs from the block after it up to (but not including)
 * the next heading whose level is ≤ its own, or the end of the list. Kept free
 * of any ProseMirror runtime dependency so it's plainly unit-testable: feed a
 * `FoldBlock[]`, assert on the ranges (same discipline as heading-extractor.ts).
 */
export function computeFoldRanges(blocks: FoldBlock[]): FoldRange[] {
  const ranges: FoldRange[] = [];
  let ordinal = 0;
  for (let i = 0; i < blocks.length; i++) {
    const block = blocks[i];
    if (!block.isHeading) continue;
    const level = block.level;
    // Scan forward for the next heading of same-or-higher level; everything
    // before it (below this heading) is this section's foldable body.
    let end = blocks.length;
    for (let j = i + 1; j < blocks.length; j++) {
      const other = blocks[j];
      if (other.isHeading && other.level <= level) {
        end = j;
        break;
      }
    }
    ranges.push({ ordinal, headingBlock: i, startBlock: i + 1, endBlock: end });
    ordinal += 1;
  }
  return ranges;
}

/** Read a live ProseMirror doc's direct children into the flat block list
 *  `computeFoldRanges` consumes, and capture each child's absolute start pos +
 *  nodeSize so the plugin can map block indices → decoration ranges. */
interface BlockPos {
  from: number;
  to: number;
}
function readTopLevelBlocks(doc: ProseMirrorNode): { blocks: FoldBlock[]; positions: BlockPos[] } {
  const blocks: FoldBlock[] = [];
  const positions: BlockPos[] = [];
  doc.forEach((child, offset) => {
    const isHeading = child.type.name === 'heading';
    const level = isHeading ? Number(child.attrs.level ?? 1) : 0;
    blocks.push({ isHeading, level });
    positions.push({ from: offset, to: offset + child.nodeSize });
  });
  return { blocks, positions };
}

/** What the plugin tracks between transactions: the set of collapsed heading
 *  ordinals. That's the whole state — ranges are recomputed from the live doc
 *  on every decoration pass, so no position remapping is needed. */
interface HeadingFoldState {
  collapsed: Set<number>;
}

/** Meta payload: replace the collapsed set wholesale (Swift is authoritative). */
interface HeadingFoldMeta {
  collapsed: number[];
}

/** Options wired from main.ts. */
export interface HeadingFoldOptions {
  /** Fired when the user clicks a chevron. `collapse` is the DESIRED next state
   *  (true = fold). The pane does not apply it locally — main.ts relays it to
   *  Swift, which echoes back via applyFoldState(). */
  onToggle: (ordinal: number, collapse: boolean) => void;
}

/** Apply the authoritative collapsed set from Swift's `applyFold` broadcast.
 *  This is the ONLY writer of the plugin's collapsed state — the anti-loop
 *  guarantee. Dispatches a metadata-only transaction (no doc change). */
export function applyFoldState(view: EditorView, ordinals: number[]): void {
  const meta: HeadingFoldMeta = { collapsed: ordinals };
  view.dispatch(view.state.tr.setMeta(headingFoldKey, meta));
}

/** Build the left-margin chevron button for a heading. `collapsed` picks the
 *  glyph/rotation; clicking requests the opposite state via `onToggle`. */
function buildChevron(
  ordinal: number,
  collapsed: boolean,
  onToggle: HeadingFoldOptions['onToggle']
): HTMLElement {
  const btn = document.createElement('button');
  btn.type = 'button';
  btn.className = 'donemd-fold-toggle' + (collapsed ? ' is-collapsed' : '');
  btn.textContent = '▸';
  btn.setAttribute('aria-label', collapsed ? '展开' : '折叠');
  btn.title = collapsed ? '展开' : '折叠';
  // Don't move the selection when toggling.
  btn.addEventListener('mousedown', (e) => e.preventDefault());
  btn.addEventListener('click', (e) => {
    e.preventDefault();
    onToggle(ordinal, !collapsed);
  });
  return btn;
}

export const HeadingFold = Extension.create<HeadingFoldOptions>({
  name: 'headingFold',

  addOptions() {
    return {
      onToggle: () => {},
    };
  },

  addProseMirrorPlugins() {
    const onToggle = this.options.onToggle;
    return [
      new Plugin<HeadingFoldState>({
        key: headingFoldKey,
        state: {
          init: (): HeadingFoldState => ({ collapsed: new Set() }),
          apply(tr: Transaction, prev: HeadingFoldState): HeadingFoldState {
            const meta = tr.getMeta(headingFoldKey) as HeadingFoldMeta | undefined;
            if (meta) {
              return { collapsed: new Set(meta.collapsed) };
            }
            // No remapping needed: state is keyed by ordinal, and decorations
            // recompute ranges from the current doc each pass. Ordinals no
            // longer present (heading deleted) are simply ignored at render.
            return prev;
          },
        },
        props: {
          decorations(this: Plugin<HeadingFoldState>, editorState: EditorState) {
            const s = this.getState(editorState);
            if (!s) return null;
            const { blocks, positions } = readTopLevelBlocks(editorState.doc);
            const ranges = computeFoldRanges(blocks);
            if (ranges.length === 0) return null;

            const decos: Decoration[] = [];
            for (const range of ranges) {
              const foldable = range.endBlock > range.startBlock;
              // Chevron only where there's a body to fold.
              if (foldable) {
                // +1 = the position just inside the heading, before its first
                // character, so the chevron renders as an inline child of the
                // heading DOM (CSS floats it into the left gutter and reveals it
                // on heading hover). side: -1 keeps it left of the text.
                const insideHeading = positions[range.headingBlock].from + 1;
                const collapsed = s.collapsed.has(range.ordinal);
                decos.push(
                  Decoration.widget(
                    insideHeading,
                    () => buildChevron(range.ordinal, collapsed, onToggle),
                    { side: -1, key: `fold-${range.ordinal}-${collapsed ? 'c' : 'e'}` }
                  )
                );
              }
              // Hide the section's blocks when this heading is collapsed.
              if (foldable && s.collapsed.has(range.ordinal)) {
                for (let b = range.startBlock; b < range.endBlock; b++) {
                  const pos = positions[b];
                  decos.push(
                    Decoration.node(pos.from, pos.to, { class: 'is-folded-hidden' })
                  );
                }
              }
            }
            return DecorationSet.create(editorState.doc, decos);
          },
        },
      }),
    ];
  },
});
