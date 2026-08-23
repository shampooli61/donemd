import { Extension } from '@tiptap/core';
import { Plugin, PluginKey, NodeSelection } from '@tiptap/pm/state';
import { dropPoint } from '@tiptap/pm/transform';
import type { Node as PMNode, Slice } from '@tiptap/pm/model';
import type { EditorView } from '@tiptap/pm/view';
import { headingFoldKey, applyFoldState } from './heading-fold';
import { send } from './bridge';

/**
 * 块拖拽手柄 (Block drag handle) — Feishu-style. Hovering a top-level block
 * fades a six-dot handle into the left gutter; press-and-drag it to reorder
 * blocks within the document (paragraphs, headings, lists, images, tables,
 * callouts, math, mermaid, raw / placeholder cards — every depth-1 node).
 *
 * How it moves blocks: the handle owns no reordering logic of its own. On
 * `dragstart` it turns the hovered block into a ProseMirror `NodeSelection`
 * and hands the selection's slice to `view.dragging` (move: true). From there
 * ProseMirror's built-in drop handling inserts the slice at the drop point and
 * deletes the original — and StarterKit's Dropcursor draws the drop line. The
 * reorder is one ordinary transaction, so the existing `editor.on('update')`
 * → serialize path syncs the Markdown 源 pane and disk with no extra work.
 *
 * v1 scope: drag-to-reorder only. A click-to-open block menu (delete / copy /
 * move up-down) is a deliberate follow-up, not built here.
 */

// Two-column, three-row dot grid — the conventional "grip" affordance.
const HANDLE_ICON =
  '<svg width="16" height="16" viewBox="0 0 16 16" aria-hidden="true">' +
  '<g fill="currentColor">' +
  '<circle cx="5.5" cy="4" r="1.3"></circle>' +
  '<circle cx="10.5" cy="4" r="1.3"></circle>' +
  '<circle cx="5.5" cy="8" r="1.3"></circle>' +
  '<circle cx="10.5" cy="8" r="1.3"></circle>' +
  '<circle cx="5.5" cy="12" r="1.3"></circle>' +
  '<circle cx="10.5" cy="12" r="1.3"></circle>' +
  '</g></svg>';

const HANDLE_WIDTH = 22;
// How far left of the block's edge the handle sits. Headings carry a fold
// chevron in that same gutter (~ -1.5rem), so their handle goes further left
// to sit on the chevron's *left* — matching the user's "handle ← chevron ←
// heading" order. Ordinary blocks have no chevron, so the handle hugs closer.
const OFFSET_DEFAULT = 30;
const OFFSET_HEADING = 52;
// How far right of the block the pointer may stray and still keep the handle
// (covers the whole reading column) and vertical slack across block margins.
const Y_SLACK = 8;

// Plain-text blocks — paragraphs, bullet / ordered lists, task (checkbox)
// lists — are text you type into, not self-contained "block objects." Feishu
// shows no drag grip on them either: reordering a paragraph among paragraphs
// is what the caret + cut/paste is for. The grip is reserved for block objects
// (image, table, callout, code / mermaid, math block, raw / placeholder cards)
// and — conditionally — folded headings. Keyed by ProseMirror node-type name.
const NON_DRAGGABLE_TYPES = new Set([
  'paragraph',
  'bulletList',
  'orderedList',
  'taskList',
]);

function isHeading(el: HTMLElement): boolean {
  return /^H[1-6]$/.test(el.tagName);
}

/**
 * A heading is grippable ONLY while folded — its chevron then carries
 * `.is-collapsed`. Rationale (user): dragging an *expanded* heading would haul
 * its entire (possibly very long) section around, an unwieldy move; folded, the
 * heading is a single compact line that stands in for the whole collapsed
 * section, so reordering it reads cleanly. Expanded (or bodyless) headings show
 * no grip. The chevron is a widget decoration rendered inside the heading DOM,
 * so a descendant query on the block element finds it.
 */
function headingIsFolded(el: HTMLElement): boolean {
  return el.querySelector('.donemd-fold-toggle.is-collapsed') != null;
}

/** A top-level block reduced to what fold-reindexing needs: whether it's a
 *  heading, its level, and (for headings) its ordinal among top-level headings
 *  in document order — the same key the fold state is stored under. */
interface TopBlock {
  isHeading: boolean;
  level: number;
  /** Heading ordinal (0-based, document order); -1 for non-headings. */
  ordinal: number;
  /** Absolute start pos of this top-level block. */
  from: number;
  /** Absolute end pos (from + nodeSize). */
  to: number;
}

function readTopBlocks(doc: PMNode): TopBlock[] {
  const out: TopBlock[] = [];
  let ordinal = 0;
  doc.forEach((child, offset) => {
    const isHeading = child.type.name === 'heading';
    out.push({
      isHeading,
      level: isHeading ? Number(child.attrs.level ?? 1) : 0,
      ordinal: isHeading ? ordinal++ : -1,
      from: offset,
      to: offset + child.nodeSize,
    });
  });
  return out;
}

/**
 * The document range a folded heading "owns": from the heading's own start to
 * the start of the next top-level heading at the same-or-higher level (or end
 * of doc). Dragging a folded heading moves this whole span as one unit, so the
 * collapsed body travels with its title instead of being orphaned — matching
 * the "folded heading = one compact block" mental model the user chose.
 */
function headingSectionRange(
  blocks: TopBlock[],
  index: number
): { from: number; to: number } {
  const level = blocks[index].level;
  let to = blocks[blocks.length - 1].to;
  for (let j = index + 1; j < blocks.length; j++) {
    if (blocks[j].isHeading && blocks[j].level <= level) {
      to = blocks[j].from;
      break;
    }
  }
  return { from: blocks[index].from, to };
}

/** The currently-collapsed heading ordinals, read from the headingFold plugin. */
function collapsedOrdinals(view: EditorView): Set<number> {
  const s = headingFoldKey.getState(view.state);
  return s ? new Set(s.collapsed) : new Set<number>();
}

/**
 * Recompute the collapsed-ordinal set after a section move, purely at the
 * block-array level (no ProseMirror position mapping — deleted-then-reinserted
 * blocks can't be tracked through `tr.mapping`). Fold state is keyed by "the Nth
 * top-level heading in document order", so moving a heading section renumbers
 * every heading after the source or the destination. We move the same block run
 * the transaction moves, carrying each heading's folded flag with it, then walk
 * the reordered array to read off the new ordinals that are folded.
 *
 * `insertBeforeIdx` is an index into the ORIGINAL `blocks` array (insert the run
 * before that block); it's adjusted here for the run's own removal.
 */
function reindexFold(
  blocks: TopBlock[],
  collapsed: Set<number>,
  mStart: number,
  mEnd: number,
  insertBeforeIdx: number
): number[] {
  const items = blocks.map((b) => ({
    isHeading: b.isHeading,
    folded: b.isHeading && collapsed.has(b.ordinal),
  }));
  const moved = items.slice(mStart, mEnd);
  const rest = [...items.slice(0, mStart), ...items.slice(mEnd)];
  let insertAt = insertBeforeIdx > mStart ? insertBeforeIdx - (mEnd - mStart) : insertBeforeIdx;
  insertAt = Math.max(0, Math.min(insertAt, rest.length));
  const arr = [...rest.slice(0, insertAt), ...moved, ...rest.slice(insertAt)];
  const out: number[] = [];
  let ordinal = 0;
  for (const it of arr) {
    if (it.isHeading) {
      if (it.folded) out.push(ordinal);
      ordinal += 1;
    }
  }
  return out;
}

/**
 * The top-level block whose vertical band contains `y`. We key off the pointer's
 * Y (not a precise XY hit-test) so moving left into the gutter toward the handle
 * doesn't count as "left the block" and hide it. `x` only gates the far-right
 * edge so the handle doesn't linger when the pointer is way outside the column.
 */
function blockAtY(view: EditorView, x: number, y: number): HTMLElement | null {
  const children = view.dom.children;
  let best: HTMLElement | null = null;
  for (let i = 0; i < children.length; i++) {
    const el = children[i];
    if (!(el instanceof HTMLElement)) continue;
    if (el.classList.contains('is-folded-hidden')) continue;
    const rect = el.getBoundingClientRect();
    if (rect.height === 0) continue;
    // Pointer must be within the block's vertical band (small slack for the
    // margins between blocks).
    if (y < rect.top - Y_SLACK || y > rect.bottom + Y_SLACK) continue;
    // Horizontal window: from just left of where the handle sits (so moving
    // into the gutter to grab it keeps the block "active") to the block's
    // right edge. Beyond that (e.g. the outline sidebar) → no handle.
    const leftEdge = rect.left - (OFFSET_HEADING + HANDLE_WIDTH + 12);
    if (x < leftEdge || x > rect.right + 40) continue;
    best = el;
    if (y >= rect.top && y <= rect.bottom) break; // exact band wins
  }
  return best;
}

/**
 * Run `fn` (which calls `view.focus()`), then pin the window scroll back to
 * where it was. WebKit treats the *window* as the pane's scroller and, on
 * refocusing the editable, scrolls to the current DOM caret — which after
 * `autofocus: 'end'` sits at the doc end. When a block object holds a focusable
 * element (a `<video controls>`), grabbing its handle would otherwise yank the
 * pane to the bottom before the block NodeSelection is even set — the "click
 * the handle → jumps to the bottom" bug. Restore now and once on the next frame
 * (before paint) so the jump never shows. For every other block this restores
 * to the same position — a no-op. (Same window-scroller guard main.ts uses for
 * link-nav and AI-insert.)
 */
function withScrollPinned(fn: () => void): void {
  const x = window.scrollX;
  const y = window.scrollY;
  fn();
  window.scrollTo(x, y);
  requestAnimationFrame(() => window.scrollTo(x, y));
}

export interface BlockDragHandleOptions {
  /** Called after a folded-heading section is dragged to a new place, with the
   *  full recomputed set of collapsed heading ordinals. main.ts relays it to
   *  Swift (`foldReplace`) so the authoritative fold set is renumbered to match
   *  the new block order; Swift echoes it back to both panes. */
  onFoldReindex: (collapsed: number[]) => void;
}

export const BlockDragHandle = Extension.create<BlockDragHandleOptions>({
  name: 'blockDragHandle',

  addOptions() {
    return { onFoldReindex: () => {} };
  },

  addProseMirrorPlugins() {
    return [blockDragHandlePlugin(this.options.onFoldReindex)];
  },
});

/** Set on dragstart when a FOLDED heading section is being dragged (multi-block
 *  move owned by this plugin's handleDrop); null for single-block-object drags
 *  (handled natively). Module-scoped: one editor view per pane, and a drag can't
 *  overlap another. Cleared on drop / dragend. */
let sectionDrag: { from: number; to: number } | null = null;

function blockDragHandlePlugin(
  onFoldReindex: BlockDragHandleOptions['onFoldReindex']
): Plugin {
  return new Plugin({
    key: new PluginKey('blockDragHandle'),
    props: {
      // Own the drop ONLY for a folded-heading section move (multi-block). For a
      // single block object we return false and let ProseMirror's native drop
      // handle it — the path already validated by the user.
      handleDrop(view, event, slice, moved): boolean {
        if (!sectionDrag || !moved) return false;
        const { from, to } = sectionDrag;
        const dragEvent = event as DragEvent;
        const coords = { left: dragEvent.clientX, top: dragEvent.clientY };
        const eventPos = view.posAtCoords(coords);
        if (!eventPos) return true; // consumed; nowhere sane to drop
        const insertPos = dropPoint(view.state.doc, eventPos.pos, slice) ?? eventPos.pos;
        // Dropping back inside (or immediately adjacent to) the section is a
        // no-op — don't churn the doc or the fold set.
        if (insertPos >= from && insertPos <= to) return true;

        const original = view.state.doc;
        const blocks = readTopBlocks(original);
        const mStart = blocks.findIndex((b) => b.from === from);
        if (mStart < 0) return true;
        let mEnd = mStart + 1;
        while (mEnd < blocks.length && blocks[mEnd].to <= to) mEnd += 1;
        let insertBeforeIdx = blocks.findIndex((b) => b.from >= insertPos);
        if (insertBeforeIdx < 0) insertBeforeIdx = blocks.length;

        const collapsed = collapsedOrdinals(view);
        const newOrdinals = reindexFold(blocks, collapsed, mStart, mEnd, insertBeforeIdx);

        const content = (slice as Slice).content;
        const tr = view.state.tr;
        tr.delete(from, to);
        const mapped = tr.mapping.map(insertPos);
        tr.insert(mapped, content);
        // Renumber the fold set atomically with the move so the visual pane
        // never renders a frame with stale ordinals (would fold wrong sections).
        tr.setMeta(headingFoldKey, { collapsed: newOrdinals });
        try {
          tr.setSelection(NodeSelection.create(tr.doc, tr.mapping.map(insertPos)));
        } catch {
          /* selection is best-effort */
        }
        tr.setMeta('uiEvent', 'drop');
        view.dispatch(tr);
        // Tell Swift the new authoritative set (source pane + persistence).
        onFoldReindex(newOrdinals);
        event.preventDefault();
        return true;
      },
    },
    view(view) {
      let hoveredPos: number | null = null;
      let hoveredDom: HTMLElement | null = null;
      let rafId = 0;

      const handle = document.createElement('div');
      handle.className = 'donemd-drag-handle';
      handle.setAttribute('contenteditable', 'false');
      handle.setAttribute('draggable', 'true');
      handle.setAttribute('aria-label', '拖动以调整顺序');
      handle.title = '拖动以调整顺序';
      handle.innerHTML = HANDLE_ICON;
      handle.style.display = 'none';
      document.body.appendChild(handle);

      const hide = (): void => {
        handle.style.display = 'none';
        hoveredPos = null;
        hoveredDom = null;
      };

      // Position the handle against a top-level block at the cursor. Editing is
      // disabled while readonly (AI streaming) — skip then.
      const positionAt = (x: number, y: number): void => {
        if (!view.editable) return hide();
        const blockDom = blockAtY(view, x, y);
        if (!blockDom) return hide();
        let pos: number;
        try {
          const inner = view.posAtDOM(blockDom, 0);
          pos = view.state.doc.resolve(inner).before(1);
        } catch {
          return hide();
        }
        // Only block-objects (and folded headings) get a grip. Plain-text
        // blocks — paragraphs / lists / checkbox lists — are excluded; an
        // expanded heading is excluded too (drag it only once folded).
        const node = view.state.doc.nodeAt(pos);
        if (!node) return hide();
        if (isHeading(blockDom)) {
          if (!headingIsFolded(blockDom)) return hide();
        } else if (NON_DRAGGABLE_TYPES.has(node.type.name)) {
          return hide();
        }
        hoveredPos = pos;
        hoveredDom = blockDom;
        const rect = blockDom.getBoundingClientRect();
        const offset = isHeading(blockDom) ? OFFSET_HEADING : OFFSET_DEFAULT;
        const left = Math.max(2, rect.left - offset);
        handle.style.display = 'flex';
        // Align to the block's top for tall blocks; for short/1-line blocks the
        // CSS height + flex centering keeps the grip vertically centered.
        handle.style.top = `${rect.top}px`;
        handle.style.left = `${left}px`;
        handle.style.height = `${Math.min(rect.height, 34)}px`;
      };

      // Track the pointer at the document level (not just over the editor):
      // the handle sits in the left gutter, outside `view.dom`, so a `dom`-only
      // listener would fire `mouseleave` and hide the handle the instant the
      // pointer moved left to grab it. `blockAtY`'s horizontal window keeps the
      // handle only while the pointer is near a block or its gutter.
      const onMouseMove = (event: MouseEvent): void => {
        if (rafId) return;
        const { clientX, clientY } = event;
        rafId = requestAnimationFrame(() => {
          rafId = 0;
          // Pointer over the handle itself → keep it shown, don't reposition.
          if (event.target === handle || handle.contains(event.target as Node)) {
            return;
          }
          positionAt(clientX, clientY);
        });
      };

      // Focus the editor before a drag so the NodeSelection we set actually
      // becomes the live selection. A plain click (no drag) ALSO selects the
      // whole block object here: tables and callouts can't be whole-selected by
      // a text drag (a table drag makes a CellSelection; a callout is isolating),
      // so the handle click is their reliable "select the whole block, then press
      // Delete" affordance — matching Feishu. The NodeSelection lives in editor
      // state, so it survives the pointer (and this handle) moving away. If the
      // click turns into a drag, `dragstart` re-sets the same selection, so this
      // is idempotent with the reorder path.
      handle.addEventListener('mousedown', () => {
        withScrollPinned(() => {
          view.focus();
          if (hoveredPos == null) return;
          const { doc } = view.state;
          if (!doc.nodeAt(hoveredPos)) return;
          try {
            view.dispatch(view.state.tr.setSelection(NodeSelection.create(doc, hoveredPos)));
          } catch {
            /* position isn't selectable as a node — leave the selection as-is */
          }
        });
      });

      handle.addEventListener('dragstart', (event: DragEvent) => {
        if (hoveredPos == null || !event.dataTransfer) return;
        const { doc } = view.state;
        const node = doc.nodeAt(hoveredPos);
        if (!node) return;
        // Pin the window scroll across the focus (see withScrollPinned): a
        // focusable <video> in the dragged block would otherwise jump the pane
        // to the bottom the instant the drag grabs focus.
        withScrollPinned(() => view.focus());
        event.dataTransfer.effectAllowed = 'move';
        // Some engines won't initiate a drag without data set.
        event.dataTransfer.setData('text/plain', '');
        if (hoveredDom) event.dataTransfer.setDragImage(hoveredDom, 0, 0);

        const isFoldedHeading =
          hoveredDom != null && isHeading(hoveredDom) && headingIsFolded(hoveredDom);
        if (isFoldedHeading) {
          // Folded heading → drag its whole section (title + collapsed body) as
          // one unit. We slice the multi-block span and let this plugin's
          // handleDrop do the move + fold reindex. The selection is just the
          // heading (for a valid drag origin); the moved content is the span.
          const blocks = readTopBlocks(doc);
          const idx = blocks.findIndex((b) => b.from === hoveredPos);
          if (idx >= 0) {
            const range = headingSectionRange(blocks, idx);
            const slice = doc.slice(range.from, range.to);
            sectionDrag = { from: range.from, to: range.to };
            view.dispatch(view.state.tr.setSelection(NodeSelection.create(doc, hoveredPos)));
            view.dragging = { slice, move: true };
            handle.classList.add('is-dragging');
            return;
          }
        }
        // Single block object → native NodeSelection drag (validated path).
        sectionDrag = null;
        const selection = NodeSelection.create(doc, hoveredPos);
        view.dispatch(view.state.tr.setSelection(selection));
        view.dragging = { slice: selection.content(), move: true };
        handle.classList.add('is-dragging');
      });

      const onDragEnd = (): void => {
        handle.classList.remove('is-dragging');
        sectionDrag = null;
        hide();
      };
      handle.addEventListener('dragend', onDragEnd);

      document.addEventListener('mousemove', onMouseMove);

      return {
        destroy() {
          if (rafId) cancelAnimationFrame(rafId);
          document.removeEventListener('mousemove', onMouseMove);
          handle.remove();
        },
      };
    },
  });
}
