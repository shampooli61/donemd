// Phase 3 Slice 6 (#67) → Slice 8 (#69) — [[AI 唤起]] command dropdown.
//
// A ProseMirror plugin + DOM panel that pops on ⌘/ and ADAPTS to the selection
// state (#69 双路径冗余):
//   - no selection  → generate-class (续写 / 写大纲 / 扩写主题 / 自由 prompt)
//   - has selection → a curated transform subset (改正式 / 改口语化 / 简化 /
//                     总结 / 扩写 / 翻译为…). The bubble "AI ▾" stays the
//                     parallel mouse path with the full 13; while ⌘/ is open
//                     over a selection the bubble is suppressed (CSS, see
//                     show()/hide()) so the two panels don't stack.
//
// The panel is a Spotlight-style list, keyboard-navigable (↑↓ / ↩ / ESC).
// Recently-used commands float to the top (per family, persisted in
// localStorage — a pure JS concern, no Swift round-trip).
//
// S8 (#69, 2026-06-30 grill) widened the trigger from "empty paragraph / line
// start" to "any ⌘/", and the old 2×2 long-press gesture matrix was scrapped —
// see CONTEXT.md § grill 墓碑. Discoverability rides on the gray line-start hint
// (ai-hint.ts) plus the bubble's ⌘/ annotation.
//
// This module owns ONLY the trigger + panel UI + selection. What a chosen
// command actually does (direct launch, mini input, free-prompt provider
// dropdown, launching the stream) is injected by main.ts via the `onPick`
// callback, so this file stays free of bridge / editor-command knowledge.

import { Extension } from '@tiptap/core';
import { Plugin, PluginKey } from '@tiptap/pm/state';
import type { EditorView } from '@tiptap/pm/view';
import { AI_GROUPS } from './bubble-menu';

export const slashMenuKey = new PluginKey('slashMenu');

/** A command shown in the ⌘/ panel. `kind` matches the Swift AICommand map.
 *  Two families share one panel, chosen by selection state (#69 双路径冗余):
 *   - generate (no selection): 续写 / 写大纲 / 扩写主题 / 自由 prompt
 *   - transform (has selection): the bubble's 13 commands (润色 / 翻译 / …) */
export interface SlashCommand {
  kind: string;
  label: string;
  hint: string;
  /** Which family — drives where onPick routes (generate launcher vs the
   *  bubble's launchAI transform path). */
  family: 'generate' | 'transform';
  /** Second-level input needed before launching. Absent → run immediately.
   *  - 'none'   : direct execute (续写 — 光标前全文; transform commands w/o param)
   *  - 'topic'  : one-line topic (写大纲 / 扩写主题)
   *  - 'free'   : multiline prompt + provider dropdown (自由 prompt)
   *  - 'rewrite': free-text rewrite intent (自定义改写)
   *  - 'language': target-language popover (翻译为…) */
  needs: 'none' | 'topic' | 'free' | 'rewrite' | 'language';
}

/** The [[AI 唤起]] generate-class catalog (no selection — 从空白 / 光标前文生成).
 *
 *  续写 is the first item and the only direct-execute one (needs:'none'): it
 *  extends from the cursor using the whole document as voice context
 *  ([[续写插入]]), so it has nothing to ask for. The rest take a second-level
 *  input before launching ([[生成插入]]). */
export const GENERATE_COMMANDS: SlashCommand[] = [
  { kind: 'continueWriting', label: '续写', hint: '基于光标前全文自然续写', family: 'generate', needs: 'none' },
  { kind: 'writeOutline', label: '写大纲', hint: '为一个主题生成 Markdown 大纲', family: 'generate', needs: 'topic' },
  { kind: 'expandTopic', label: '扩写主题', hint: '把一个主题展开成段落', family: 'generate', needs: 'topic' },
  { kind: 'freePrompt', label: '自由 prompt…', hint: '自定义指令，可选 Provider', family: 'generate', needs: 'free' },
];

/** The transform-class catalog for the ⌘/ panel (has selection). This is a
 *  CURATED subset of the bubble's full 13 — the ⌘/ keyboard path keeps only the
 *  high-intent transforms; the bubble "AI ▾" mouse path still offers everything.
 *  (#69 real-machine feedback: 润色 目的性不强 dropped; 翻译 collapses to a
 *  single 翻译为… → language sub-level; 列大纲 / 转表格 / 自定义改写 / 续写
 *  stay bubble-only.)
 *
 *  Labels + `needs` are still looked up from AI_GROUPS so wording / prompt kind
 *  never drift from the bubble; only the SET and ORDER are curated here. */
const SLASH_TRANSFORM_KINDS = ['formal', 'colloquial', 'simplify', 'summarize', 'expand', 'translateTo'];

export const TRANSFORM_COMMANDS: SlashCommand[] = (() => {
  const byKind = new Map(
    AI_GROUPS.flatMap((g) => g.items.map((it) => [it.kind, { it, title: g.title }] as const)),
  );
  return SLASH_TRANSFORM_KINDS.flatMap((kind): SlashCommand[] => {
    const found = byKind.get(kind);
    if (!found) return []; // kind retired from AI_GROUPS — skip rather than crash
    return [{
      kind: found.it.kind,
      label: found.it.label,
      hint: found.title,
      family: 'transform',
      needs: found.it.prompt ?? 'none',
    }];
  });
})();

const RECENTS_MAX = 3;
/** Recents are scoped per family so the generate list and transform list don't
 *  reorder each other. */
function recentsKey(family: 'generate' | 'transform'): string {
  return `donemd.ai.slashRecents.${family}`;
}

function loadRecents(family: 'generate' | 'transform'): string[] {
  try {
    const raw = localStorage.getItem(recentsKey(family));
    if (!raw) return [];
    const arr = JSON.parse(raw);
    return Array.isArray(arr) ? arr.filter((x) => typeof x === 'string') : [];
  } catch {
    return [];
  }
}

function pushRecent(family: 'generate' | 'transform', kind: string): void {
  try {
    const next = [kind, ...loadRecents(family).filter((k) => k !== kind)].slice(0, RECENTS_MAX);
    localStorage.setItem(recentsKey(family), JSON.stringify(next));
  } catch {
    /* localStorage unavailable — recents are best-effort, ignore */
  }
}

/** The command set for the current selection state: transform when something is
 *  selected, generate otherwise. Recently-used (per family) float to the top. */
function orderedCommands(view: EditorView): SlashCommand[] {
  const hasSelection = !view.state.selection.empty;
  const family = hasSelection ? 'transform' : 'generate';
  const catalog = hasSelection ? TRANSFORM_COMMANDS : GENERATE_COMMANDS;
  const recents = loadRecents(family);
  const byKind = new Map(catalog.map((c) => [c.kind, c]));
  const top: SlashCommand[] = [];
  for (const k of recents) {
    const c = byKind.get(k);
    if (c) { top.push(c); byKind.delete(k); }
  }
  return [...top, ...catalog.filter((c) => byKind.has(c.kind))];
}

/** Should ⌘/ open the AI panel? S8 (#69): always — the panel adapts to the
 *  selection state (transform commands with a selection, generate without).
 *  ⌘ carries a modifier so it never lands as text mid-paragraph (no flicker),
 *  so triggering with the cursor inside prose is safe. The bubble menu's
 *  "AI ▾" remains the parallel mouse path for transforms (双路径冗余). */
function shouldTrigger(_view: EditorView): boolean {
  return true;
}

export interface SlashMenuHandle {
  /** Injected by main.ts: called with the chosen command. main.ts handles the
   *  mini-input / provider-dropdown / stream launch. */
  onPick: (command: SlashCommand) => void;
}

/** Build the panel DOM + a controller. The panel lives detached from the
 *  editor and is positioned at the caret when shown. */
function createPanel(handle: SlashMenuHandle) {
  const root = document.createElement('div');
  root.className = 'donemd-slash';
  root.style.display = 'none';
  document.body.appendChild(root);

  let items: SlashCommand[] = [];
  let active = 0;
  let open = false;

  const render = (): void => {
    root.replaceChildren();
    items.forEach((cmd, i) => {
      const row = document.createElement('div');
      row.className = 'donemd-slash__item' + (i === active ? ' is-active' : '');
      const label = document.createElement('span');
      label.className = 'donemd-slash__label';
      label.textContent = cmd.label;
      const hint = document.createElement('span');
      hint.className = 'donemd-slash__hint';
      hint.textContent = cmd.hint;
      row.appendChild(label);
      row.appendChild(hint);
      // mousedown (not click) so the editor selection isn't lost first.
      row.addEventListener('mousedown', (e) => {
        e.preventDefault();
        pick(i);
      });
      row.addEventListener('mousemove', () => {
        if (active !== i) { active = i; render(); }
      });
      root.appendChild(row);
    });
  };

  const positionAtCaret = (view: EditorView): void => {
    // Anchor at the selection head (= caret with no selection). For a forward
    // selection that's the end; either way the panel sits at the active edge.
    const coords = view.coordsAtPos(view.state.selection.to);
    const gap = 4;
    // Flip up when the caret sits too low for the panel to fit below it —
    // otherwise a ⌘/ near the bottom of the viewport gets clipped by the
    // editor's lower edge. Measure the rendered panel (show() renders +
    // displays before calling us, so offsetHeight is real here).
    const panelH = root.offsetHeight;
    const spaceBelow = window.innerHeight - coords.bottom;
    const top =
      spaceBelow < panelH + gap && coords.top - gap - panelH >= 0
        ? coords.top - gap - panelH // flip above the caret line
        : coords.bottom + gap; // default: below the caret
    // Also keep the panel within the right edge of the viewport.
    const left = Math.min(
      Math.round(coords.left),
      Math.max(0, window.innerWidth - root.offsetWidth - gap)
    );
    root.style.left = `${left}px`;
    root.style.top = `${Math.round(top)}px`;
  };

  const show = (view: EditorView): void => {
    items = orderedCommands(view);
    active = 0;
    open = true;
    render();
    root.style.display = 'block';
    positionAtCaret(view);
    // With a selection, the bubble menu ([[选区浮窗]]) is also showing — suppress
    // it so the two panels don't stack. CSS hides .donemd-bubble while this
    // class is on <body>. Cleared in hide().
    document.body.classList.add('donemd-slash-open');
  };

  const hide = (): void => {
    open = false;
    root.style.display = 'none';
    document.body.classList.remove('donemd-slash-open');
  };

  const pick = (i: number): void => {
    const cmd = items[i];
    if (!cmd) return;
    pushRecent(cmd.family, cmd.kind);
    hide();
    handle.onPick(cmd);
  };

  /** Returns true if the key was consumed (panel handled it). */
  const handleKey = (e: KeyboardEvent): boolean => {
    if (!open) return false;
    switch (e.key) {
      case 'ArrowDown':
        active = (active + 1) % items.length; render(); return true;
      case 'ArrowUp':
        active = (active - 1 + items.length) % items.length; render(); return true;
      // Enter and Space both activate the highlighted item — standard
      // macOS list/menu muscle memory. Safe because the panel has no
      // type-to-filter (Space isn't needed as input). If filtering is ever
      // added, Space must revert to typing a space.
      case 'Enter':
      case ' ':
        e.preventDefault();
        pick(active); return true;
      case 'Escape':
        hide(); return true;
      default:
        // Bare modifier presses (⌘/⇧/⌥/⌃ held alone) aren't a dismissal — the
        // user may be reaching for a shortcut; keep the panel open.
        if (['Shift', 'Meta', 'Alt', 'Control'].includes(e.key)) return false;
        // Any other key (a typed character) dismisses the panel — we have no
        // type-to-filter, so the panel steps aside and the key falls through
        // to the editor. Crucially this resets `open`, so the next `/` opens a
        // fresh panel (the bug: a stuck `open` made later `/` insert as text).
        hide();
        return false;
    }
  };

  return { show, hide, handleKey, isOpen: () => open };
}

export function createSlashMenu(handle: SlashMenuHandle) {
  const panel = createPanel(handle);

  const extension = Extension.create({
    name: 'slashMenu',
    addProseMirrorPlugins() {
      return [
        new Plugin({
          key: slashMenuKey,
          props: {
            handleKeyDown(view, event) {
              // When the panel is open, it owns navigation keys (↑↓ ↩ ESC).
              if (panel.isOpen()) {
                return panel.handleKey(event);
              }
              // Trigger on ⌘/ (real-machine decision). A bare `/` was tried but
              // (a) flickers — the char inserts then gets swallowed — and
              // (b) is unreliable under a Chinese IME, where the keydown
              // reports key='Process' not '/'. ⌘/ carries the ⌘ modifier so it
              // bypasses the IME and never lands as text, so no flicker / no
              // conflict with typing.
              //
              // S8 (#69): ⌘/ opens this [[AI 唤起]] dropdown only with no
              // selection. With a selection, ⌘/ falls through (return false) so
              // the [[选区浮窗]] can own the transform-class commands.
              const isCmdSlash = event.key === '/' && (event.metaKey || event.ctrlKey);
              if (isCmdSlash && shouldTrigger(view)) {
                event.preventDefault();
                panel.show(view);
                return true;
              }
              return false;
            },
            // Any click / blur in the editor closes the panel.
            handleClick() {
              panel.hide();
              return false;
            },
          },
          // Safety net: if the document or selection changes while the panel is
          // open (anything other than our own open keystroke), close it. Stops
          // `open` getting stranded when focus / selection moves by a path that
          // doesn't go through handleKeyDown (e.g. clicking another pane).
          view() {
            return {
              update(view, prevState) {
                if (!panel.isOpen()) return;
                if (!view.state.selection.eq(prevState.selection) || !view.state.doc.eq(prevState.doc)) {
                  panel.hide();
                }
              },
            };
          },
        }),
      ];
    },
  });

  return { extension, panel };
}
