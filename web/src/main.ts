import { Editor, Extension } from '@tiptap/core';
import StarterKit from '@tiptap/starter-kit';
import Heading from '@tiptap/extension-heading';
import Link from '@tiptap/extension-link';
import { DonemdImage } from './image-node';
import { DonemdVideo } from './video-node';
import Table from '@tiptap/extension-table';
import TableRow from '@tiptap/extension-table-row';
import TableCell from '@tiptap/extension-table-cell';
import TableHeader from '@tiptap/extension-table-header';
import { DonemdTableSelection } from './table-selection';
import TaskList from '@tiptap/extension-task-list';
import TaskItem from '@tiptap/extension-task-item';
import BubbleMenu from '@tiptap/extension-bubble-menu';
import { RawMarkdownBlock } from './raw-markdown-block';
import { FeishuPlaceholderBlock } from './feishu-placeholder-block';
import { Callout } from './callout';
import { MermaidCodeBlock } from './mermaid-codeblock';
import { MathInline } from './math-inline';
import { MathBlock } from './math-block';
import { isMathBroken } from './katex-render';
import { createBubbleMenu, runFormatCommand } from './bubble-menu';
import type { AICommandItem } from './bubble-menu';
import { AIStreaming, aiStreamingKey } from './ai-streaming';
import { InlineDiff, inlineDiffKey } from './inline-diff';
import type { AIStreamMode } from './ai-streaming';
import { createSlashMenu } from './slash-menu';
import { createTableToolbar } from './table-toolbar';
import type { SlashCommand } from './slash-menu';
import { AIHint } from './ai-hint';
import { BlockDragHandle } from './block-drag-handle';
import { linkHrefFromClickTarget } from './link-open';
import { extractHeadings } from './heading-extractor';
import { HeadingFold, applyFoldState } from './heading-fold';
// prosemirror-tables' own stylesheet — REQUIRED for column resize to work at
// all. It positions the resize-handle widget `absolute` (so hovering a column
// border doesn't shove the cell's content and grow the row), supplies the
// `col-resize` cursor, and defines `--default-cell-min-width`. Without it the
// handle is an in-flow 4px span (rows jitter/grow on hover) and dragging has
// no cursor affordance — i.e. resize looked entirely absent. Imported BEFORE
// visual.css so our M4 table polish (rounded frame, header band, zebra) wins
// on the cascade. (#76 bug fix)
import 'prosemirror-tables/style/tables.css';
import './visual.css';
import 'katex/dist/katex.min.css';
import { on, request, send } from './bridge';

// Whether the current selection sits inside a table cell (header or body).
// Used to forbid headings there: GFM table cells can't encode a heading level
// on disk, so a header styled as a heading would silently revert to plain text
// on save/reopen (#76). We block the operation instead of losing it later.
function selectionInTableCell(editor: Editor): boolean {
  return editor.isActive('tableCell') || editor.isActive('tableHeader');
}

// --- Heading: replace StarterKit's default Mod-Alt-N with our Mod-Shift-N
// (matching Notion / Bear / Typora). StarterKit's heading is disabled
// below so this override wins. Headings inside table cells are refused —
// returning true swallows the keystroke (no error bell) without applying it.
const DonemdHeading = Heading.extend({
  addKeyboardShortcuts() {
    const toggle = (level: 1 | 2 | 3) => (): boolean => {
      if (selectionInTableCell(this.editor)) return true;
      return this.editor.commands.toggleHeading({ level });
    };
    return {
      'Mod-Shift-1': toggle(1),
      'Mod-Shift-2': toggle(2),
      'Mod-Shift-3': toggle(3),
    };
  },
});

// --- Custom shortcuts that don't fit any one extension's keymap.
const DonemdShortcuts = Extension.create({
  name: 'donemdShortcuts',
  addKeyboardShortcuts() {
    return {
      // Slack / Notion / Google Docs convention. Tiptap's default Mod-Shift-s
      // also still works, but Cmd+Shift+X is what the PRD locks in.
      'Mod-Shift-x': () => this.editor.commands.toggleStrike(),
      // Reset block to paragraph (matches Word / Notion).
      'Mod-Alt-0': () => this.editor.commands.setParagraph(),
      // Clear inline marks AND reset the block to paragraph (Pages "Remove Style").
      'Mod-\\': () =>
        this.editor.chain().focus().clearNodes().unsetAllMarks().run(),
      // Insert / edit a link via a small webview-internal prompt.
      // Always returns true so cancelling the prompt doesn't ring the
      // unhandled-keystroke bell.
      'Mod-k': () => {
        insertLinkInteractive(this.editor);
        return true;
      },
      // Insert a 3×3 table with a header row (Bear convention). Shared with
      // the 插入 → 表格 menu entry (Swift → `insertTable` bridge message).
      'Mod-Alt-t': () => {
        insertTable(this.editor);
        return true;
      },
    };
  },
});

// Insert a 3×3 table with a header row at the caret. Shared by the ⌘⌥T
// shortcut and the 插入 → 表格 menu (via the `insertTable` bridge message) so
// both entry points behave identically. Row/column editing is then done with
// the in-editor table toolbar.
function insertTable(editor: Editor): void {
  editor.chain().focus().insertTable({ rows: 3, cols: 3, withHeaderRow: true }).run();
}

function insertLinkInteractive(editor: Editor): void {
  const existingHref =
    (editor.getAttributes('link').href as string | undefined) ?? '';
  const url = window.prompt('链接地址 (URL)：', existingHref);
  if (url === null) return; // user cancelled
  if (url === '') {
    // Empty URL clears any existing link mark on the selection.
    editor.chain().focus().extendMarkRange('link').unsetLink().run();
    return;
  }
  const { from, to } = editor.state.selection;
  if (from === to) {
    // No selection: insert a "链接" placeholder and apply the link mark.
    editor
      .chain()
      .focus()
      .insertContent({
        type: 'text',
        text: '链接',
        marks: [{ type: 'link', attrs: { href: url } }],
      })
      .run();
  } else {
    editor.chain().focus().extendMarkRange('link').setLink({ href: url }).run();
  }
}

// --- Editor

const mountPoint = document.querySelector<HTMLElement>('#editor');
if (!mountPoint) {
  throw new Error('Editor mount point #editor not found in visual.html');
}

// Build the bubble menu DOM up front — Tiptap's BubbleMenu extension wraps
// this element with tippy.js for selection-relative positioning, so it
// has to exist before `new Editor`.
const bubble = createBubbleMenu();
document.body.appendChild(bubble.element);

// Slash command panel (#67). onPick is wired to a function defined after the
// editor exists (hoisted below); the extension just needs the handle object.
const slash = createSlashMenu({
  onPick: (command) => handleSlashPick(command),
});

declare global {
  interface Window {
    /** Exposed so Swift can pull the current Tiptap doc state for Cmd+S
     *  (Slice 3) without round-tripping through a bridge request/reply. */
    donemdEditor?: Editor;
  }
}

const editor = new Editor({
  element: mountPoint,
  extensions: [
    StarterKit.configure({
      // We override Heading and CodeBlock below.
      heading: false,
      codeBlock: false,
    }),
    // Mermaid-aware code block — for `language === "mermaid"` it swaps
    // between source and rendered SVG depending on cursor position. All
    // other languages render as a plain `<pre><code>` exactly like
    // StarterKit's default, so disabling StarterKit's codeBlock and
    // routing everything through MermaidCodeBlock is safe.
    MermaidCodeBlock,
    DonemdHeading.configure({ levels: [1, 2, 3, 4, 5, 6] }),
    Link.configure({ openOnClick: false }),
    DonemdImage,
    DonemdVideo,
    Table.configure({ resizable: true }),
    TableRow,
    TableCell,
    TableHeader,
    // Feishu-style whole-table selection: progressive ⌘A (cell → table) and
    // Delete/Backspace on a full-table selection removes the table. Registered
    // after the table nodes so its keymap sits above prosemirror-tables'.
    DonemdTableSelection,
    TaskList,
    TaskItem.configure({ nested: true }),
    RawMarkdownBlock,
    FeishuPlaceholderBlock,
    Callout,
    MathInline,
    MathBlock,
    BubbleMenu.configure({
      element: bubble.element,
      tippyOptions: {
        placement: 'top',
        duration: [180, 120],
        // Don't grab focus when the bubble shows up.
        hideOnClick: false,
        // tippy's default maxWidth is 350px — with the AI group the bubble is
        // wider than that, so the rightmost (AI) buttons got clipped. Let it
        // size to content, and keep it inside the viewport near the edges.
        maxWidth: 'none',
        popperOptions: {
          modifiers: [
            { name: 'preventOverflow', options: { padding: 8 } },
            { name: 'flip', options: { padding: 8 } },
          ],
        },
      },
      // Show only when the user actually has a non-empty text selection
      // inside an editable region. Empty selection / read-only / clicked
      // out of editor → hide.
      shouldShow: ({ editor, from, to }) => {
        if (from === to) return false;
        if (!editor.isEditable) return false;
        return true;
      },
    }),
    DonemdShortcuts,
    AIStreaming,
    InlineDiff,
    AIHint,
    // Heading fold (标题折叠). The chevron click does NOT fold locally — it
    // asks Swift, which is the single source of truth and echoes the new
    // collapsed set back to BOTH panes via `applyFold`. This keeps the two
    // panes in lockstep and prevents A→B→A ping-pong (see heading-fold.ts).
    HeadingFold.configure({
      onToggle: (ordinal, collapse) => {
        send('foldToggled', { ordinal, collapse });
      },
    }),
    slash.extension,
    // Block drag handle (块拖拽手柄). Dragging a FOLDED heading moves its whole
    // section; that renumbers heading ordinals, so we ship the recomputed
    // collapsed set to Swift (authoritative), which echoes it to both panes.
    BlockDragHandle.configure({
      onFoldReindex: (collapsed) => {
        send('foldReplace', { collapsed });
      },
    }),
  ],
  content: '',
  autofocus: 'end',
});

// Clear a block NodeSelection (image / math / callout etc.) when the user
// clicks blank space that ProseMirror doesn't own — the editor's padding,
// the gutter margins, anywhere off the actual content. Without this the blue
// `ProseMirror-selectednode` outline lingers until the user selects another
// node, because PM only reassigns the selection when a click lands on real
// content. On a content click PM overwrites the selection right after, so
// collapsing here first is a no-op in that case.
//
// Capture phase: run before PM's own view handlers so, for an off-content
// click, we've already collapsed the node selection to a caret and the
// outline is gone by the time the click settles.
document.addEventListener(
  'mousedown',
  (e) => {
    // The block drag handle lives on document.body (outside view.dom) and sets
    // its own NodeSelection on click. Without this exemption we'd collapse that
    // selection to a caret a beat before the handle sets it — a flicker. Let the
    // handle own the selection when the click lands on it.
    if ((e.target as HTMLElement | null)?.closest?.('.donemd-drag-handle')) return;
    const sel = editor.state.selection as { node?: unknown };
    if (!sel.node) return; // not a block NodeSelection → nothing to clear
    const dom = editor.view.nodeDOM(editor.state.selection.from) as
      | HTMLElement
      | null;
    // Click inside the selected node itself (or its NodeView chrome, e.g. the
    // image zoom badge) → leave the selection alone; that's a real interaction
    // with the block, not a click-away.
    if (dom && dom.contains(e.target as Node)) return;
    // Collapse to a caret at the same spot. If the click then lands on other
    // content, PM's handler reassigns the selection normally.
    editor.commands.setTextSelection(editor.state.selection.from);
  },
  true,
);

// Single-click a link → follow it natively. Tiptap's Link runs with
// `openOnClick: false` so the webview never navigates on its own; we hand the
// href to Swift, which opens URLs in the default browser and local file paths
// in their default app (see LinkTarget.swift + VisualWebView.handleOpenLink).
// Capture phase so we beat ProseMirror's own click handling. Only a true
// single click follows (see linkHrefFromClickTarget) — double / triple clicks
// fall through so the user can still select a word to edit the link's text.
editor.view.dom.addEventListener(
  'click',
  (e) => {
    const href = linkHrefFromClickTarget(e.target, e.detail);
    if (href === null) return;
    e.preventDefault();
    e.stopPropagation();
    // Following a link hands focus to an external app (browser / Finder). When
    // the user returns, WebKit refocuses the editable and scrolls its caret
    // into view — and with `autofocus: 'end'` an untouched caret sits at the
    // doc end, so the whole pane jumps to the bottom (same window-scroller
    // hazard the AI-insert paths above guard against). Pin the viewport back:
    // now, next frame, and once when the window next regains focus (the
    // return-from-browser case). Bounded by a timeout so a much-later,
    // unrelated focus can't yank a stale scroll position.
    const prevScrollX = window.scrollX;
    const prevScrollY = window.scrollY;
    const restoreScroll = () => window.scrollTo(prevScrollX, prevScrollY);
    send('openLink', { href });
    restoreScroll();
    requestAnimationFrame(restoreScroll);
    const onRefocus = () => {
      window.removeEventListener('focus', onRefocus);
      clearTimeout(timer);
      restoreScroll();
      requestAnimationFrame(restoreScroll);
    };
    window.addEventListener('focus', onRefocus);
    const timer = setTimeout(() => window.removeEventListener('focus', onRefocus), 30000);
  },
  true,
);

// Inbound: Swift hands us the parsed Tiptap document.
on('loadDocument', (payload) => {
  // Load the parsed document WITHOUT recording a history step: the initial
  // content is the baseline, not an edit. Otherwise ⌘Z could pop past the
  // user's first real edit and clear the whole document back to empty.
  editor
    .chain()
    .setContent(payload as object, false)
    .command(({ tr }) => {
      tr.setMeta('addToHistory', false);
      return true;
    })
    .run();
  // Emit the outline for the freshly-loaded document so the 大纲 sidebar
  // (#78) has content the moment the doc opens, without waiting for the
  // first edit.
  emitOutline();
  // Reset scrollspy for the new document (a fresh doc starts at the top) and
  // publish the initial active heading so the sidebar highlights correctly
  // before the user scrolls.
  lastActiveHeading = null;
  emitActiveHeading();
  // Flag any broken formulas in the freshly-loaded document (S9 M2) so the
  // source pane red-flags them from the start, not just after the first edit.
  emitBadMath();
});

// Inbound: Swift picked an image (Cmd+Shift+I → AssetsManager → here).
// Just inserts at the current selection — Swift has already written the
// file under <doc>/assets/<hash>.<ext>.
// Insert a block image at a position that always accepts one. `setImage`
// inserts at the caret, which throws "Called contentMatchAt on a node with
// invalid content" when the caret sits somewhere a block image isn't allowed
// (inside a heading, a table cell, an atom, etc.). Instead we insert *after*
// the enclosing top-level block — a depth-1 boundary always accepts a block
// node — so insertion works regardless of where the caret was.
function insertImageSafely(src: string): void {
  if (!src) return;
  const { state } = editor;
  const $from = state.selection.$from;
  // Position just after the top-level (depth 1) block containing the caret.
  // Fall back to the document end if resolution is degenerate.
  const insertPos = $from.depth >= 1 ? $from.after(1) : state.doc.content.size;
  editor
    .chain()
    .focus()
    .insertContentAt(insertPos, { type: 'image', attrs: { src } })
    .run();
}

on('insertImage', (payload) => {
  const src = (payload as { src?: string })?.src;
  if (typeof src === 'string') insertImageSafely(src);
});

// Local video (#88). Same depth-1 hoist as images: a block atom can't land
// inside a heading / table cell / another atom, so insert after the enclosing
// top-level block.
function insertVideoSafely(src: string): void {
  if (!src) return;
  const { state } = editor;
  const $from = state.selection.$from;
  const insertPos = $from.depth >= 1 ? $from.after(1) : state.doc.content.size;
  editor
    .chain()
    .focus()
    .insertContentAt(insertPos, { type: 'video', attrs: { src } })
    .run();
}

on('insertVideo', (payload) => {
  const src = (payload as { src?: string })?.src;
  if (typeof src === 'string') insertVideoSafely(src);
});

// Inbound: Swift's 格式 / 插入 menu → 表格. Same 3×3-with-header table as ⌘⌥T.
on('insertTable', () => {
  insertTable(editor);
});

// Inbound: the native 格式 menu. Each menu item sends { cmd } and we run the
// SAME action the selection floater's button of that cmd would run (shared via
// runFormatCommand — one action map, so menu and floater never drift). The
// `link` cmd routes through this file's interactive link prompt. Marks/blocks
// toggle on the current selection or block, exactly like clicking the floater.
on('formatCommand', (payload) => {
  const cmd = (payload as { cmd?: string })?.cmd;
  if (typeof cmd === 'string') {
    runFormatCommand(editor, cmd, insertLinkInteractive);
  }
});

// --- Image paste & drop. Both routes ship bytes to Swift's AssetsManager,
// then insert the image node with the donemd-asset:// URL Swift returns.

mountPoint.addEventListener('paste', (event) => {
  const items = event.clipboardData?.items;
  if (!items) return;
  for (const item of Array.from(items)) {
    if (item.kind === 'file' && item.type.startsWith('image/')) {
      event.preventDefault();
      const file = item.getAsFile();
      if (file) void importAndInsertImage(file);
      return;
    }
  }
});

mountPoint.addEventListener('drop', (event) => {
  const files = event.dataTransfer?.files;
  if (!files || files.length === 0) return;
  for (const file of Array.from(files)) {
    if (file.type.startsWith('image/')) {
      event.preventDefault();
      void importAndInsertImage(file);
      return;
    }
  }
});

// --- QuickLook preview (#77) is now triggered by the magnifier badge that
// DonemdImage's NodeView fades in on hover (see image-node.ts), not by a bare
// click on the image. A single click selects the node (blue outline) so the
// user can see it's picked and press Delete; the badge keeps preview opt-in
// and separate from selection.

async function importAndInsertImage(file: File): Promise<void> {
  try {
    const base64 = await fileToBase64(file);
    const reply = await request(
      'importImage',
      { mime: file.type || 'image/png', base64 },
      'imageImported',
    );
    if (reply.success && typeof reply.assetURL === 'string') {
      insertImageSafely(reply.assetURL);
    } else {
      console.warn('[image] import failed:', reply.error);
    }
  } catch (err) {
    console.warn('[image] import threw:', err);
  }
}

function fileToBase64(file: File): Promise<string> {
  return new Promise((resolve, reject) => {
    const reader = new FileReader();
    reader.onload = () => {
      const result = reader.result;
      if (typeof result !== 'string') {
        reject(new Error('FileReader did not return a string'));
        return;
      }
      // result is a data URL: "data:<mime>;base64,<payload>" — strip prefix.
      const comma = result.indexOf(',');
      resolve(comma >= 0 ? result.slice(comma + 1) : result);
    };
    reader.onerror = () => reject(reader.error ?? new Error('FileReader failed'));
    reader.readAsDataURL(file);
  });
}

// Make the editor reachable from Swift's evaluateJavaScript for the
// Cmd+S pull (DonemdDocument.save → window.donemdEditor.getJSON()).
window.donemdEditor = editor;

// --- Phase 3 #63: AI streaming controller (M5) ---------------------------
//
// Drives the AIStreaming decoration plugin from bridge messages, RAF-throttles
// incoming tokens, locks the editor read-only during a stream, and commits the
// parsed result atomically (one undo step) when Swift sends the final node.

interface ActiveStream {
  id: string;
  from: number;
  to: number;
  mode: AIStreamMode;    // how the result lands (replace / append / generate)
  buffer: string;        // tokens not yet flushed to the decoration
  flushScheduled: boolean;
}
let activeStream: ActiveStream | null = null;

/** The last stream's id + range + mode, retained across endStream() so the
 *  failure toast's 「重试」 can re-send with the same selection + landing
 *  behavior (PRD 26). */
let lastStream: { id: string; from: number; to: number; mode: AIStreamMode } | null = null;

interface ToastButton {
  label: string;
  onClick: () => void;
}

/** Simple text toast (progress spinner line / done line). */
function aiToast(message: string, kind: 'progress' | 'done'): HTMLElement {
  return renderToast(message, kind, []);
}

/** Toast with action buttons (failure: 「重试」 + optional 「打开 Provider 设置」). */
function renderToast(message: string, kind: 'progress' | 'done' | 'error', buttons: ToastButton[]): HTMLElement {
  let el = document.getElementById('donemd-ai-toast');
  if (!el) {
    el = document.createElement('div');
    el.id = 'donemd-ai-toast';
    document.body.appendChild(el);
  }
  el.className = `donemd-ai-toast donemd-ai-toast--${kind}`;
  el.replaceChildren();
  const text = document.createElement('span');
  text.className = 'donemd-ai-toast__text';
  text.textContent = message;
  el.appendChild(text);
  for (const b of buttons) {
    const btn = document.createElement('button');
    btn.type = 'button';
    btn.className = 'donemd-ai-toast__btn';
    btn.textContent = b.label;
    btn.addEventListener('mousedown', (e) => e.preventDefault());
    btn.addEventListener('click', (e) => { e.preventDefault(); b.onClick(); });
    el.appendChild(btn);
  }
  // A manual × so a non-auto-dismissed error toast can be closed (PRD).
  if (kind === 'error') {
    const close = document.createElement('button');
    close.type = 'button';
    close.className = 'donemd-ai-toast__close';
    close.textContent = '×';
    close.setAttribute('aria-label', '关闭');
    close.addEventListener('click', (e) => { e.preventDefault(); hideAIToast(); });
    el.appendChild(close);
  }
  el.style.display = 'flex';
  return el;
}
function hideAIToast(): void {
  const el = document.getElementById('donemd-ai-toast');
  if (el) el.style.display = 'none';
}

/** Tear down the provisional decoration + unlock the editor. Does NOT touch
 *  the document — the decoration is an overlay, never a doc transaction, so
 *  there's nothing to undo and ⌘⇧Z can't resurface a half-stream (PRD 13). */
function endStream(): void {
  if (!activeStream) return;
  editor.view.dispatch(editor.state.tr.setMeta(aiStreamingKey, { kind: 'clear' }));
  editor.setEditable(true);
  activeStream = null;
}

// Cancel: ESC, any key, or click outside while streaming. Silent (PRD 21/22).
function cancelStreamFromUser(): void {
  if (!activeStream) return;
  send('aiCancel', { streamId: activeStream.id });
  endStream();
  hideAIToast();
}

// Launcher injected into the bubble menu: extract selection + neighbour blocks
// from the live ProseMirror state and ship to Swift.
function launchAI(ed: Editor, command: AICommandItem): void {
  if (activeStream) return; // single in-flight (Q4)
  const { state } = ed;
  const { from, to } = state.selection;
  if (from === to) return;
  const selection = state.doc.textBetween(from, to, '\n');

  // Find the top-level block(s) the selection sits in, plus prev/next siblings.
  const $from = state.doc.resolve(from);
  const blockIndex = $from.index(0);
  const root = state.doc;
  const blockText = (i: number): string | null => {
    if (i < 0 || i >= root.childCount) return null;
    const node = root.child(i);
    return node.textContent || null;
  };
  const paragraph = blockText(blockIndex) ?? selection;
  // Up to 3 blocks each side (document order). Swift slices to the user's
  // ai.contextRange; sending more is cheap and lets the setting change without
  // a JS round-trip. Nearest neighbour = before.last / after.first.
  const before: string[] = [];
  for (let i = blockIndex - 3; i < blockIndex; i++) {
    const t = blockText(i);
    if (t) before.push(t);
  }
  const after: string[] = [];
  for (let i = blockIndex + 1; i <= blockIndex + 3; i++) {
    const t = blockText(i);
    if (t) after.push(t);
  }

  // 续写 extends from the selection end ([[续写插入]]); all other floater
  // commands transform the selection in place ([[直接替换]]). [[生成插入]]
  // (cursor, no selection) is driven by the slash command in S6.
  const mode: AIStreamMode = command.kind === 'continueWriting' ? 'append' : 'replace';

  const streamId = `ai-${Date.now()}`;
  activeStream = { id: streamId, from, to, mode, buffer: '', flushScheduled: false };
  lastStream = { id: streamId, from, to, mode };

  send('aiCommand', {
    streamId,
    command: command.kind,
    ...(command.arg ? { arg: command.arg } : {}),
    selection,
    paragraph,
    ...(before.length ? { before } : {}),
    ...(after.length ? { after } : {}),
  });
}

// --- Slash command (#67) launchers -----------------------------------------

/** Generate from the cursor ([[生成插入]]): no selection; the typed input is
 *  the whole prompt. mode='generate' → M5 inserts at the cursor and auto-selects
 *  the result so the user can chain a polish. */
function launchGenerate(kind: string, arg: string, provider?: string): void {
  if (activeStream) return;
  const { from } = editor.state.selection;
  const mode: AIStreamMode = 'generate';
  const streamId = `ai-${Date.now()}`;
  activeStream = { id: streamId, from, to: from, mode, buffer: '', flushScheduled: false };
  lastStream = { id: streamId, from, to: from, mode };
  send('aiCommand', {
    streamId,
    command: kind,
    arg,
    // inputOnly commands ignore selection on the Swift side, but the bridge
    // contract still carries the typed text in `arg`.
    ...(provider ? { provider } : {}),
  });
}

/** 续写 from the cursor with no selection ([[续写插入]], the [[AI 唤起]] direct-
 *  execute entry). The whole document is the voice context — Swift rebuilds it
 *  from currentBodyMarkdown(), so `selection` only needs to be non-empty to
 *  clear Swift's "selection required" guard for non-inputOnly commands; we send
 *  the text before the cursor (基于光标前全文) which also serves as the builder's
 *  fullDocument fallback. mode='append' inserts at the cursor, original text
 *  untouched, one ⌘Z removes just the continuation. */
function launchContinue(): void {
  if (activeStream) return;
  const { from } = editor.state.selection;
  const before = editor.state.doc.textBetween(0, from, '\n');
  if (!before.trim()) {
    // Nothing to continue from — let the user know rather than firing a no-op.
    const toast = aiToast('光标前没有内容可续写', 'done');
    window.setTimeout(() => { if (toast.classList.contains('donemd-ai-toast--done')) hideAIToast(); }, 3000);
    return;
  }
  const mode: AIStreamMode = 'append';
  const streamId = `ai-${Date.now()}`;
  activeStream = { id: streamId, from, to: from, mode, buffer: '', flushScheduled: false };
  lastStream = { id: streamId, from, to: from, mode };
  send('aiCommand', {
    streamId,
    command: 'continueWriting',
    selection: before,
  });
}

/** A chosen [[AI 唤起]] command: run it (续写) or show whatever second-level
 *  input it needs, then launch. 续写 is direct-execute; the rest are generate
 *  with a topic / free-prompt input ([[生成插入]]). */
function handleSlashPick(command: SlashCommand): void {
  // Transform family (has selection): route to the same launcher the bubble's
  // "AI ▾" uses ([[直接替换]]). 自定义改写 / 翻译为… pop a mini-input first
  // (mirrors the bubble's sub-layer); the rest dispatch straight away.
  if (command.family === 'transform') {
    switch (command.needs) {
      case 'rewrite':
        showSlashInput('请描述改写意图', false, (text) => {
          launchAI(editor, { kind: command.kind, label: command.label, arg: text });
        });
        break;
      case 'language':
        showSlashInput('翻译为…（语种）', false, (text) => {
          launchAI(editor, { kind: command.kind, label: command.label, arg: text });
        });
        break;
      default:
        launchAI(editor, { kind: command.kind, label: command.label });
    }
    return;
  }

  // Generate family (no selection).
  switch (command.needs) {
    case 'none':
      launchContinue();
      break;
    case 'topic':
      showSlashInput(`要写什么的${command.label === '写大纲' ? '大纲' : '主题'}？`, false, (text) => {
        launchGenerate(command.kind, text);
      });
      break;
    case 'free':
      showFreePromptInput();
      break;
  }
}

// --- Slash mini-input UI ----------------------------------------------------

let slashInputEl: HTMLElement | null = null;
let slashInputDocHandlers: (() => void) | null = null;
function dismissSlashInput(): void {
  if (slashInputDocHandlers) { slashInputDocHandlers(); slashInputDocHandlers = null; }
  if (slashInputEl) { slashInputEl.remove(); slashInputEl = null; }
}

/** Position a small floating input at the caret. `multiline` swaps <input> for
 *  <textarea>. onSubmit fires on Enter (Cmd+Enter for multiline); ESC cancels. */
function showSlashInput(
  placeholder: string,
  multiline: boolean,
  onSubmit: (text: string) => void,
  extra?: HTMLElement,
): void {
  dismissSlashInput();
  const box = document.createElement('div');
  box.className = 'donemd-slash-input';
  const field = document.createElement(multiline ? 'textarea' : 'input') as
    HTMLInputElement | HTMLTextAreaElement;
  field.className = 'donemd-slash-input__field';
  field.placeholder = placeholder;
  field.addEventListener('mousedown', (e) => e.stopPropagation());
  field.addEventListener('keydown', (ev: Event) => {
    const e = ev as KeyboardEvent;
    const submitKey = multiline ? (e.key === 'Enter' && (e.metaKey || e.ctrlKey)) : e.key === 'Enter';
    if (submitKey) {
      e.preventDefault();
      const v = field.value.trim();
      if (v) { dismissSlashInput(); onSubmit(v); }
    } else if (e.key === 'Escape') {
      e.preventDefault();
      dismissSlashInput();
      editor.commands.focus();
    }
  });
  if (extra) box.appendChild(extra);
  box.appendChild(field);
  const hint = document.createElement('div');
  hint.className = 'donemd-slash-input__hint';
  hint.textContent = multiline ? '⌘↩ 发送 · Esc 取消' : '↩ 发送 · Esc 取消';
  box.appendChild(hint);
  document.body.appendChild(box);
  slashInputEl = box;
  // Position at the caret.
  const coords = editor.view.coordsAtPos(editor.state.selection.from);
  box.style.left = `${Math.round(coords.left)}px`;
  box.style.top = `${Math.round(coords.bottom + 4)}px`;
  field.focus();

  // Focus-independent dismissal (real-machine feedback: ESC on the field
  // didn't always close it — focus can sit elsewhere in WKWebView, and the
  // provider <select> steals it). Capture-phase document listeners catch ESC
  // and outside-clicks regardless of where focus is. Removed on dismiss.
  const onDocKey = (ev: KeyboardEvent) => {
    if (ev.key === 'Escape') {
      ev.preventDefault();
      ev.stopPropagation();
      dismissSlashInput();
      editor.commands.focus();
    }
  };
  const onDocDown = (ev: MouseEvent) => {
    if (slashInputEl && !slashInputEl.contains(ev.target as Node)) {
      dismissSlashInput();
    }
  };
  document.addEventListener('keydown', onDocKey, true);
  document.addEventListener('mousedown', onDocDown, true);
  slashInputDocHandlers = () => {
    document.removeEventListener('keydown', onDocKey, true);
    document.removeEventListener('mousedown', onDocDown, true);
  };
}

/** Free-prompt input: multiline + a provider dropdown listing only configured
 *  providers (queried from Swift). The provider override rides with the launch. */
function showFreePromptInput(): void {
  let chosenProvider: string | undefined;
  const select = document.createElement('select');
  select.className = 'donemd-slash-input__provider';
  // Placeholder while we fetch; populated from Swift's reply.
  const loading = document.createElement('option');
  loading.textContent = '默认 Provider';
  loading.value = '';
  select.appendChild(loading);
  select.addEventListener('mousedown', (e) => e.stopPropagation());
  select.addEventListener('change', () => { chosenProvider = select.value || undefined; });

  showSlashInput('输入你的指令…', true, (text) => {
    launchGenerate('freePrompt', text, chosenProvider);
  }, select);

  // Populate the dropdown with configured providers (only usable ones).
  request('aiProvidersQuery', {}, 'aiProvidersReply')
    .then((reply) => {
      const providers = (reply.providers as Array<{ id: string; name: string }>) ?? [];
      const def = reply.default as string | undefined;
      if (!providers.length) return; // keep "默认 Provider"
      select.replaceChildren();
      for (const p of providers) {
        const opt = document.createElement('option');
        opt.value = p.id;
        opt.textContent = p.name + (p.id === def ? '（默认）' : '');
        if (p.id === def) opt.selected = true;
        select.appendChild(opt);
      }
      // Default to the default provider unless the user already changed it.
      if (def && chosenProvider === undefined) chosenProvider = undefined; // undefined → Swift uses default
    })
    .catch(() => { /* offline / no reply — leave the 默认 Provider option */ });
}

on('aiStreamStart', (payload) => {
  const p = payload as { streamId?: string };
  if (!activeStream || p.streamId !== activeStream.id) return;
  // Clear any lingering inline-diff overlay from a previous transform before a
  // new stream paints over the same area.
  editor.view.dispatch(editor.state.tr.setMeta(inlineDiffKey, { kind: 'clear' }));
  editor.setEditable(false);
  editor.view.dispatch(
    editor.state.tr.setMeta(aiStreamingKey, {
      kind: 'start',
      mode: activeStream.mode,
      from: activeStream.from,
      to: activeStream.to,
    })
  );
  aiToast('AI 生成中，按 ESC 取消', 'progress');
});

// 8K guard fired: the prompt was rebuilt selection-only (PRD 60). Flash a
// brief notice; the progress toast then takes over for the actual stream.
on('aiStreamDegrade', (payload) => {
  const p = payload as { streamId?: string };
  if (!activeStream || p.streamId !== activeStream.id) return;
  const el = aiToast('文档过长，已切换为仅选区调用', 'progress');
  el.classList.add('donemd-ai-toast--flash');
  window.setTimeout(() => el.classList.remove('donemd-ai-toast--flash'), 600);
});

on('aiStreamToken', (payload) => {
  const p = payload as { streamId?: string; text?: string };
  if (!activeStream || p.streamId !== activeStream.id || !p.text) return;
  activeStream.buffer += p.text;
  // RAF throttle: one decoration repaint per frame, however fast tokens land.
  if (!activeStream.flushScheduled) {
    activeStream.flushScheduled = true;
    requestAnimationFrame(() => {
      if (!activeStream) return;
      const text = activeStream.buffer;
      activeStream.buffer = '';
      activeStream.flushScheduled = false;
      editor.view.dispatch(
        editor.state.tr.setMeta(aiStreamingKey, { kind: 'append', text })
      );
    });
  }
});

on('aiStreamComplete', (payload) => {
  const p = payload as {
    streamId?: string;
    node?: { content?: Array<{ type?: string; content?: object[] }> };
  };
  if (!activeStream || p.streamId !== activeStream.id) return;
  const { from, to, mode } = activeStream;
  const blocks = p.node?.content ?? [];

  // Inline-vs-block decision (real-machine feedback #3): the result is parsed
  // as block nodes (e.g. a paragraph). Inserting a *block* paragraph into an
  // inline range pushes the text onto a new line every time. When the result
  // is a single paragraph (the common polish / translate / formal case),
  // unwrap it and insert just its inline content so the text stays in its
  // original position. Multi-block results (列大纲 / 转表格 / 续写 spanning
  // paragraphs) keep block insertion — they legitimately want new blocks.
  const single = blocks.length === 1 ? blocks[0] : undefined;
  const content: object[] =
    single?.type === 'paragraph' && Array.isArray(single.content)
      ? single.content
      : blocks;

  // Where the result lands + what the cursor does afterward, per mode. Each is
  // ONE atomic transaction (clear decoration + insert) → a single ⌘Z step.
  //  - replace:  overwrite [from,to] in place (S2 [[直接替换]]).
  //  - append:   insert at `to`, original [from,to] untouched ([[续写插入]]);
  //              ⌘Z removes only the inserted text, the selection stays put.
  //  - generate: insert at the cursor, then select the inserted range so the
  //              user can chain a polish straight away ([[生成插入]]).
  editor.setEditable(true);
  if (mode === 'replace') {
    // Capture the original text *before* it's overwritten so the [[内联 Diff
    // 视图]] can diff it against the result.
    const before = editor.state.doc.textBetween(from, to, '\n');
    // The stream ran with the editor set non-editable, which drops the WebView's
    // DOM caret. Re-enabling it and focusing can make WebKit scroll the whole
    // pane (the window is the scroller — see scrollspy below) back to the top of
    // the document — the "润色完跳回开头" bug (Tiptap #7318 class). Snapshot the
    // viewport so we can pin it back on the just-polished paragraph: an in-place
    // 直接替换 barely moves the block, so restoring the pre-commit scroll keeps
    // the user exactly where they were.
    const prevScrollX = window.scrollX;
    const prevScrollY = window.scrollY;
    // Mutate first, THEN focus at the resulting selection: focusing *before* the
    // new selection is set is precisely what triggers the scroll-to-top; focus
    // last so it lands on the committed range.
    editor
      .chain()
      .command(({ tr }) => { tr.setMeta(aiStreamingKey, { kind: 'clear' }); return true; })
      .insertContentAt({ from, to }, content)
      .focus()
      .run();
    // After insertContentAt, the selection head sits at the end of the
    // inserted content — that's the new range end.
    const newTo = editor.state.selection.to;
    const after = editor.state.doc.textBetween(from, newTo, '\n');
    // Pin the viewport back. Restore now (covers a synchronous scroll) and again
    // after Tiptap's delayed-focus rAF (where the spurious scroll actually
    // lands). If preventScroll already held, both restores are no-ops.
    const restoreScroll = () => window.scrollTo(prevScrollX, prevScrollY);
    restoreScroll();
    requestAnimationFrame(restoreScroll);
    activeStream = null;
    // The progress toast ("AI 生成中…") has no done-toast to replace it in
    // replace mode — the diff overlay is the feedback now, so dismiss it here.
    hideAIToast();
    // Auto-open the inline diff (绿增红删 + 还原/保留 with an auto-keep
    // countdown). No toast — the overlay itself is the feedback, and it
    // self-dismisses, so the result lands whether or not the user acts.
    if (before !== after) {
      editor.view.dispatch(
        editor.state.tr.setMeta(inlineDiffKey, { kind: 'show', from, to: newTo, before, after })
      );
    }
  } else {
    // append inserts after the selection end; generate inserts at the cursor
    // (from === to for generate, so `to` is correct for both).
    const insertAt = to;
    // Same scroll-to-top hazard as the replace branch above: the stream ran with
    // the editor non-editable (which drops the WebView's DOM caret), so focusing
    // can make WebKit scroll the whole pane (the window is the scroller — see
    // scrollspy below) to the top of the document (Tiptap #7318 class). Snapshot
    // the viewport and pin it back so 续写/生成 leaves the user on the current
    // focus — the inserted block lands right after it — instead of jumping.
    const prevScrollX = window.scrollX;
    const prevScrollY = window.scrollY;
    // Mutate first, THEN focus at the resulting selection: focusing *before* the
    // new selection is set is precisely what triggers the scroll-to-top.
    editor
      .chain()
      .command(({ tr }) => { tr.setMeta(aiStreamingKey, { kind: 'clear' }); return true; })
      .insertContentAt(insertAt, content)
      .focus()
      .run();
    // After insertContentAt, the editor selection sits at the end of the
    // inserted content. Derive the inserted range from current head.
    const end = editor.state.selection.to;
    if (mode === 'generate') {
      // Auto-select the generated range so a follow-up 润色 acts on it. Focus
      // last, after the selection is set — same ordering rule as above.
      editor.chain().setTextSelection({ from: insertAt, to: end }).focus().run();
    }
    // Pin the viewport back. Restore now (covers a synchronous scroll) and again
    // after Tiptap's delayed-focus rAF (where the spurious scroll actually
    // lands). If preventScroll already held, both restores are no-ops.
    const restoreScroll = () => window.scrollTo(prevScrollX, prevScrollY);
    restoreScroll();
    requestAnimationFrame(restoreScroll);
    activeStream = null;
    const label = mode === 'append' ? '已续写，⌘Z 撤销' : '已生成，⌘Z 撤销';
    const toast = aiToast(label, 'done');
    window.setTimeout(() => { if (toast.classList.contains('donemd-ai-toast--done')) hideAIToast(); }, 5000);
  }
});

// Command declined to transform (转表格 不适合). Drop the decoration and
// leave the selection exactly as it was — do NOT replace (real-machine
// feedback #2). Just a brief notice toast.
on('aiStreamNotApplicable', (payload) => {
  const p = payload as { streamId?: string; message?: string };
  if (activeStream && p.streamId !== activeStream.id) return;
  endStream();
  const toast = aiToast(p.message ?? '该内容不适合此操作', 'done');
  window.setTimeout(() => { if (toast.classList.contains('donemd-ai-toast--done')) hideAIToast(); }, 5000);
});

// Re-issue the failed call with the same prompt + selection (PRD 26). Re-arms
// the decoration over the original range and asks Swift to retry.
function retryLastStream(): void {
  if (!lastStream) return;
  const { id, from, to, mode } = lastStream;
  activeStream = { id, from, to, mode, buffer: '', flushScheduled: false };
  hideAIToast();
  send('aiRetry', { streamId: id });
}

on('aiStreamError', (payload) => {
  const p = payload as { streamId?: string; message?: string; canOpenSettings?: boolean };
  // Errors arrive after endStream cleared activeStream; match against lastStream.
  endStream();
  const buttons: ToastButton[] = [{ label: '重试', onClick: retryLastStream }];
  if (p.canOpenSettings) {
    buttons.push({ label: '打开 Provider 设置', onClick: () => send('aiOpenSettings', {}) });
  }
  // Failure toast stays until the user acts or 5s passes (PRD: 5s auto-dismiss
  // / manual × / non-blocking). The × is rendered for kind 'error'.
  renderToast(p.message ?? 'AI 调用失败', 'error', buttons);
  window.setTimeout(() => {
    const el = document.getElementById('donemd-ai-toast');
    if (el?.classList.contains('donemd-ai-toast--error')) hideAIToast();
  }, 5000);
});

// A concurrent request was ignored (one already in flight) — flash the
// progress toast so the user sees "正在进行中" (PRD 27).
on('aiStreamBusy', () => {
  const el = aiToast('AI 正在进行中…', 'progress');
  el.classList.add('donemd-ai-toast--flash');
  window.setTimeout(() => el.classList.remove('donemd-ai-toast--flash'), 600);
});

// While streaming, ESC or any character key = cancel (PRD 21/22) — the
// intuitive "I want to keep editing now" signal. Ignore bare modifier
// presses (⌘/⇧/⌥/⌃ alone) so a user reaching for a shortcut doesn't trip it.
document.addEventListener(
  'keydown',
  (e) => {
    if (!activeStream) return;
    const bareModifier = ['Meta', 'Shift', 'Alt', 'Control'].includes(e.key);
    if (bareModifier) return;
    e.preventDefault();
    cancelStreamFromUser();
  },
  true
);

// Clicking anywhere while streaming = cancel (PRD 23). Capture-phase so it
// fires before the click lands in the editor; the toast's own buttons stop
// propagation via their handlers so this doesn't cancel a retry click.
document.addEventListener(
  'mousedown',
  (e) => {
    if (!activeStream) return;
    const toast = document.getElementById('donemd-ai-toast');
    if (toast && toast.contains(e.target as Node)) return; // let toast buttons work
    cancelStreamFromUser();
  },
  true
);

// [[内联 Diff 视图]] dismissal. The overlay auto-keeps after a countdown, but the user
// can also dismiss it early by just getting on with editing: ESC keeps, and
// clicking anywhere outside the overlay keeps too. (Explicit 还原/保留 buttons
// live inside the overlay.) "Keep" = clear the decoration; the doc already
// holds the AI result, so there's nothing else to do.
function inlineDiffActive(): boolean {
  return inlineDiffKey.getState(editor.state)?.active === true;
}
function keepInlineDiff(): void {
  if (!inlineDiffActive()) return;
  editor.view.dispatch(editor.state.tr.setMeta(inlineDiffKey, { kind: 'clear' }));
}
document.addEventListener(
  'keydown',
  (e) => {
    if (!inlineDiffActive() || activeStream) return;
    // ESC = keep + swallow; any other key dismisses but is NOT swallowed, so
    // the user keeps typing seamlessly over the (now-committed) result.
    if (e.key === 'Escape') e.preventDefault();
    if (['Meta', 'Shift', 'Alt', 'Control'].includes(e.key)) return;
    keepInlineDiff();
  },
  true
);
document.addEventListener(
  'mousedown',
  (e) => {
    if (!inlineDiffActive()) return;
    const target = e.target as HTMLElement;
    if (target.closest('.donemd-inline-diff')) return; // let 还原/保留 work
    keepInlineDiff();
  },
  true
);

// Wire the bubble menu's click handlers and active-state tracking now
// that the editor instance exists. The link button reuses the same
// prompt helper Cmd+K uses; the AI dropdown uses launchAI.
bubble.attach(editor, insertLinkInteractive, launchAI);

// Table toolbar (#16 / #76): floating row/column controls shown while the
// caret is inside a table. Attach after the editor exists — it subscribes to
// selectionUpdate/transaction to show/hide + reposition itself.
const tableToolbar = createTableToolbar();
tableToolbar.attach(editor);

// Tell Swift the document changed on every edit transaction (typing,
// formatting, paste, drop, anything). Swift uses this for two things:
// dirty-flag tracking (so Cmd+S actually saves) and real-time push to
// the Markdown 源 pane (Slice 4).
//
// Tiptap's 'update' fires per transaction, which means tens of times per
// second when the user types fast. Coalesce to one emit per animation
// frame (~60Hz) to keep the JS↔Swift round-trip from spinning.
let updateScheduled = false;

// Document outline (#78 M5). On every edit, re-extract the heading tree and
// push it to Swift for the 大纲 sidebar. Debounced ~300ms (per CONTEXT.md
// §文档大纲) — the outline only changes when the user adds/removes/edits a
// heading, so it doesn't need per-frame freshness like the source-pane sync.
let outlineTimer: number | undefined;
function emitOutline(): void {
  send('outlineChanged', { headings: extractHeadings(editor.getJSON()) });
}
function scheduleOutline(): void {
  if (outlineTimer !== undefined) window.clearTimeout(outlineTimer);
  outlineTimer = window.setTimeout(() => {
    outlineTimer = undefined;
    emitOutline();
  }, 300);
}

// Bad-math relay (S9 M2). The Markdown 源 pane is a separate bundle with no
// KaTeX and no `$`-recognition, so it can't tell which formula is broken. The
// Visual pane already knows — its math NodeViews render via KaTeX. Walk the
// math nodes, run the SAME renderMath used by the NodeViews, and ship the raw
// LaTeX of the failing ones to Swift, which forwards them to the source pane.
// The source pane does a literal substring match (LaTeX is serialized
// verbatim, so `$latex$` / `$$\nlatex\n$$` always contain it) and red-flags
// the matching ranges. We send LaTeX strings, not positions — identical LaTeX
// renders identically, so flagging every textual occurrence is correct, and
// substring match avoids duplicating the Swift-side `$` recognition rules.
function collectBadMathLatex(): string[] {
  const bad: string[] = [];
  const seen = new Set<string>();
  editor.state.doc.descendants((node) => {
    if (node.type.name === 'math_inline' || node.type.name === 'math_block') {
      const latex = String(node.attrs.latex ?? '');
      if (latex.length === 0 || seen.has(latex)) return;
      seen.add(latex);
      const displayMode = node.type.name === 'math_block';
      if (isMathBroken(latex, displayMode)) bad.push(latex);
    }
  });
  return bad;
}
function emitBadMath(): void {
  send('badMathFormulas', { latex: collectBadMathLatex() });
}

// Outline jump (#79). Swift sends the ordinal of a clicked heading; scroll the
// Nth heading in document order into view. The ordinal must match
// extractHeadings' order — both walk the doc depth-first counting `heading`
// nodes — so alignment survives normalization reflow (anchored by "the Nth
// heading", not by pixel row; see heading-extractor.ts).
// Find the doc position of the Nth heading (document order). Ordinal matches
// extractHeadings / scrollToHeading everywhere else.
function headingPosByOrdinal(index: number): number | undefined {
  let seen = 0;
  let targetPos: number | undefined;
  editor.state.doc.descendants((node, pos) => {
    if (targetPos !== undefined) return false;
    if (node.type.name === 'heading') {
      if (seen === index) {
        targetPos = pos;
        return false;
      }
      seen += 1;
      return false; // headings don't nest inside headings
    }
    return true;
  });
  return targetPos;
}

// Bring the heading's DOM node to the top of the viewport. Prefer the DOM
// scroll (gives "block: start"); fall back to moving the caret into it.
function scrollHeadingToTop(targetPos: number, behavior: ScrollBehavior): void {
  const dom = editor.view.nodeDOM(targetPos) as HTMLElement | null;
  if (dom && typeof dom.scrollIntoView === 'function') {
    dom.scrollIntoView({ block: 'start', behavior });
  } else {
    editor.chain().setTextSelection(targetPos + 1).scrollIntoView().run();
  }
}

// A running "pin" loop id, so a new scroll request cancels a stale one.
let pinRafId = 0;

// Outline jump (#79). Swift sends the ordinal of a clicked heading; scroll the
// Nth heading in document order into view. The ordinal must match
// extractHeadings' order — both walk the doc depth-first counting `heading`
// nodes — so alignment survives normalization reflow (anchored by "the Nth
// heading", not by pixel row; see heading-extractor.ts).
on('scrollToHeading', (payload) => {
  const p = payload as { index?: number; smooth?: boolean } | null;
  const index = p?.index;
  if (typeof index !== 'number' || index < 0) return;
  const targetPos = headingPosByOrdinal(index);
  if (targetPos === undefined) return;

  // Cancel any in-flight pin loop from a previous toggle.
  if (pinRafId) {
    cancelAnimationFrame(pinRafId);
    pinRafId = 0;
  }

  if (p?.smooth !== false) {
    // Outline-row click: a single smooth glide the user follows with their eyes.
    scrollHeadingToTop(targetPos, 'smooth');
    return;
  }

  // Sidebar-toggle re-anchor: the split animation resizes this WKWebView over
  // ~300ms, and WebKit's scroll anchoring drifts the viewport a little on EVERY
  // reflow frame — the user sees it slide up/down a paragraph before settling.
  // A single late snap can't cover that; instead pin the heading to the top on
  // every frame until the reflow stops moving it.
  //
  // A fixed duration is guesswork: stop too early and the last drift shows as a
  // quick jitter; too late and it spins for nothing. So converge on stability
  // instead — keep pinning until the heading's top has held within 1px for a
  // few consecutive frames (reflow has settled), with a hard ceiling as a
  // backstop. This self-adjusts to the machine's animation/reflow timing.
  //
  // The catch: the sidebar animation is EASE-OUT, so its tail moves only a
  // fraction of a pixel per frame — small enough to slip under the stability
  // threshold while the animation is still visibly finishing. Stopping there
  // drops the last few pixels in one snap (the end jitter). So gate stability
  // behind a MIN_MS floor that outlasts the whole open/close animation: we keep
  // pinning every frame through the entire animation regardless, and only let
  // "settled" end the loop once the animation window has surely passed.
  const STABLE_FRAMES = 6; // ~100ms of no drift ⇒ settled
  const MIN_MS = 380; // outlast the ease-out sidebar animation before trusting "stable"
  const MAX_MS = 1600; // backstop so a pathological reflow can't spin forever
  const start = performance.now();
  let stable = 0;
  // Where the heading's top sat right after the PREVIOUS frame's pin. This
  // frame, before re-pinning, we read its top again: the difference is exactly
  // how far the ongoing reflow nudged it in one frame. When that per-frame drift
  // stays ~0 for STABLE_FRAMES, the reflow has settled and we can stop — no
  // fixed-duration guessing, so it can't stop a beat too early (the jitter) or
  // spin needlessly.
  let pinnedTop = Number.NaN;
  const topOf = (): number => {
    const dom = editor.view.nodeDOM(targetPos) as HTMLElement | null;
    return dom ? dom.getBoundingClientRect().top : Number.NaN;
  };
  const pin = (now: number): void => {
    const drift = topOf() - pinnedTop;
    scrollHeadingToTop(targetPos, 'auto');
    pinnedTop = topOf();
    if (!Number.isNaN(drift) && Math.abs(drift) < 1.5) {
      stable += 1;
    } else {
      stable = 0;
    }
    const settled = stable >= STABLE_FRAMES && now - start >= MIN_MS;
    if (settled || now - start >= MAX_MS) {
      pinRafId = 0;
    } else {
      pinRafId = requestAnimationFrame(pin);
    }
  };
  pinRafId = requestAnimationFrame(pin);
});

// 标题折叠 (heading fold) — Swift broadcasts the authoritative collapsed set
// (by heading ordinal) after any pane toggles. This is the ONLY thing that
// mutates the fold plugin's state, so a fold started in either pane lands here
// identically and can't loop back out (see heading-fold.ts § 状态流与防回环).
on('applyFold', (payload) => {
  const raw = (payload as { collapsed?: unknown } | null)?.collapsed;
  const ordinals = Array.isArray(raw)
    ? raw.filter((x): x is number => typeof x === 'number')
    : [];
  applyFoldState(editor.view, ordinals);
});

// Scrollspy (#79). The reverse channel of the outline jump: as the user scrolls
// the Visual pane, figure out which heading's section is currently at the top of
// the viewport and push its ordinal to Swift so the 大纲 sidebar auto-highlights
// it. The ordinal is computed by the SAME depth-first heading-node walk as
// extractHeadings / scrollToHeading, so the highlighted row is always the exact
// row the jump would target — no drift between the two directions.
//
// "Current" = the last heading whose top has scrolled to or above a line a bit
// below the viewport top (SPY_OFFSET). Above the first heading → nothing
// highlighted (null). Only emit on change to keep the bridge quiet.
const SPY_OFFSET = 80;
let lastActiveHeading: number | null = null;

function computeActiveHeading(): number | null {
  let ordinal = 0;
  let active: number | null = null;
  editor.state.doc.descendants((node, pos) => {
    if (node.type.name === 'heading') {
      const dom = editor.view.nodeDOM(pos) as HTMLElement | null;
      if (dom && typeof dom.getBoundingClientRect === 'function') {
        if (dom.getBoundingClientRect().top <= SPY_OFFSET) {
          active = ordinal;
        }
      }
      ordinal += 1;
      return false; // headings don't nest inside headings
    }
    return true;
  });
  return active;
}

function emitActiveHeading(): void {
  const active = computeActiveHeading();
  if (active === lastActiveHeading) return;
  lastActiveHeading = active;
  send('activeHeadingChanged', { index: active });
}

let spyScheduled = false;
function scheduleActiveHeading(): void {
  if (spyScheduled) return;
  spyScheduled = true;
  requestAnimationFrame(() => {
    spyScheduled = false;
    emitActiveHeading();
  });
}

// The Visual pane scrolls the window (see visual.css: #editor has no own
// overflow), so scrollspy listens on window scroll. `passive` — we never
// preventDefault.
window.addEventListener('scroll', scheduleActiveHeading, { passive: true });

editor.on('update', () => {
  scheduleOutline();
  // Editing can add/remove headings above the viewport, shifting ordinals —
  // recompute which one is active so the sidebar highlight stays correct.
  scheduleActiveHeading();
  if (updateScheduled) return;
  updateScheduled = true;
  requestAnimationFrame(() => {
    updateScheduled = false;
    send('documentChanged');
    // After the source pane receives the fresh markdown, tell it which
    // formulas are broken so it can red-flag them (S9 M2).
    emitBadMath();
  });
});

// Outbound: signal Swift that the editor is mounted and ready to receive
// the document. Swift's bridge handler responds with `loadDocument`.
send('editorReady');
