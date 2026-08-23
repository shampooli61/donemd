// Phase 3 Slice 10 (#71) — [[内联 Diff 视图]] (inline diff view).
//
// After a [[直接替换]] transform completes, the document already holds the NEW
// text in [from,to]. This view opens **automatically** right after the
// transform: the original (before) and the result are diffed word/char-level
// and shown *in place* at the original selection position — 绿色插入 + 红色
// 删除 — with 「还原 / 保留」 actions. The 「保留」 button carries a 30s
// countdown; if the user does nothing it auto-keeps when it hits 0. So the
// review is opt-OUT (auto-dismiss), not a blocking confirmation — the AI
// 助手's "零确认、不打断" core holds (the result lands either way).
//
// Interaction decision (2026-06-30, real-machine feedback): replaced the
// earlier "hidden behind ⌘⇧D, optional review" design. ⌘⇧D was unintuitive —
// no one reaches for it. Auto-open + countdown-auto-keep makes the diff a
// glanceable, self-dismissing confirmation that never costs a step.
//
// Form decision (deviates from the PRD's literal "复用首保 diff 查看器"): we
// render inline in the editor (CONTEXT.md form), reusing the diff *algorithm
// semantics* of LineDiff.swift — added/removed segments — not the Swift
// FirstSaveDiffView side-by-side modal. #20 (Phase 5) unifies the diff
// component later; this slice does not pre-merge.
//
// Built as a ProseMirror plugin mirroring ai-streaming.ts: a PluginKey, meta-
// driven state (show / clear), and a DecorationSet. The real [from,to] text is
// hidden with an inline decoration while a widget renders the diff over it.

import { Extension } from '@tiptap/core';
import { Plugin, PluginKey } from '@tiptap/pm/state';
import { Decoration, DecorationSet } from '@tiptap/pm/view';
import type { EditorView } from '@tiptap/pm/view';

export const inlineDiffKey = new PluginKey('inlineDiff');

/** Auto-keep countdown shown on the 「保留」 button (seconds). When it hits 0
 *  with no user action, the diff dismisses and the AI result stays. */
export const AUTO_KEEP_SECONDS = 10;

/** One run of diff output. `equal` survived, `del` was in `before` only, `ins`
 *  is in the result only. */
export interface DiffSegment {
  text: string;
  kind: 'equal' | 'del' | 'ins';
}

interface InlineDiffState {
  active: boolean;
  from: number;
  to: number;
  /** Original text, used by 还原 to restore + by the diff render. */
  before: string;
  segments: DiffSegment[];
}

const EMPTY: InlineDiffState = { active: false, from: 0, to: 0, before: '', segments: [] };

type InlineDiffMeta =
  | { kind: 'show'; from: number; to: number; before: string; after: string }
  | { kind: 'clear' };

// MARK: - Word/char-level diff (reuses LineDiff.swift's added/removed semantics)

/** Tokenize for a natural-looking inline diff: each CJK glyph is its own token,
 *  Latin/digit runs stay whole words, whitespace runs and lone punctuation are
 *  their own tokens. So Chinese diffs per-character and English diffs per-word. */
function tokenize(s: string): string[] {
  const re = /[㐀-鿿぀-ヿ＀-￯]|[A-Za-z0-9]+|\s+|[\s\S]/gu;
  return s.match(re) ?? [];
}

/** Longest-common-subsequence diff over tokens → merged equal/del/ins segments.
 *  O(n·m) DP; selections are small (the transform target), so this is cheap. */
export function computeDiff(before: string, after: string): DiffSegment[] {
  const a = tokenize(before);
  const b = tokenize(after);
  const n = a.length;
  const m = b.length;

  // dp[i][j] = LCS length of a[i:] and b[j:].
  const dp: number[][] = Array.from({ length: n + 1 }, () => new Array<number>(m + 1).fill(0));
  for (let i = n - 1; i >= 0; i--) {
    for (let j = m - 1; j >= 0; j--) {
      dp[i][j] = a[i] === b[j] ? dp[i + 1][j + 1] + 1 : Math.max(dp[i + 1][j], dp[i][j + 1]);
    }
  }

  const raw: DiffSegment[] = [];
  let i = 0;
  let j = 0;
  while (i < n && j < m) {
    if (a[i] === b[j]) {
      raw.push({ text: a[i], kind: 'equal' });
      i++;
      j++;
    } else if (dp[i + 1][j] >= dp[i][j + 1]) {
      raw.push({ text: a[i], kind: 'del' });
      i++;
    } else {
      raw.push({ text: b[j], kind: 'ins' });
      j++;
    }
  }
  while (i < n) { raw.push({ text: a[i++], kind: 'del' }); }
  while (j < m) { raw.push({ text: b[j++], kind: 'ins' }); }

  // Merge consecutive same-kind runs so the DOM is one span per run.
  const merged: DiffSegment[] = [];
  for (const seg of raw) {
    const last = merged[merged.length - 1];
    if (last && last.kind === seg.kind) last.text += seg.text;
    else merged.push({ ...seg });
  }
  return merged;
}

// MARK: - Widget DOM

/** Dismiss the overlay, keeping the AI result (the doc already holds it). */
function keepAndClear(view: EditorView): void {
  if (!inlineDiffKey.getState(view.state)?.active) return;
  view.dispatch(view.state.tr.setMeta(inlineDiffKey, { kind: 'clear' }));
}

/** Restore the original text over the (possibly mapped) range, then dismiss.
 *  One transaction → a single ⌘Z re-applies the AI result if the user changes
 *  their mind. Reads positions from live plugin state, not build-time capture. */
function revertAndClear(view: EditorView): void {
  const s = inlineDiffKey.getState(view.state);
  if (!s?.active) return;
  const tr = view.state.tr.insertText(s.before, s.from, s.to);
  tr.setMeta(inlineDiffKey, { kind: 'clear' });
  view.dispatch(tr);
}

/** Build the in-place diff overlay: the diffed text (red strikethrough deletes
 *  + green inserts) + a 「还原 / 保留 (Ns)」 action row. The 「保留」 button runs
 *  a 30s countdown that auto-keeps at 0. The interval is cleaned up via the
 *  widget spec's `destroy` (PM calls it when the decoration is removed); a
 *  stable decoration `key` keeps this DOM across re-renders so the timer isn't
 *  reset every transaction. */
function buildWidget(view: EditorView, state: InlineDiffState): HTMLElement {
  const box = document.createElement('span');
  box.className = 'donemd-inline-diff';
  box.contentEditable = 'false';
  // Don't let clicks inside the overlay move the editor selection.
  box.addEventListener('mousedown', (e) => e.preventDefault());

  const body = document.createElement('span');
  body.className = 'donemd-inline-diff__body';
  for (const seg of state.segments) {
    const span = document.createElement('span');
    span.className =
      seg.kind === 'del' ? 'donemd-inline-diff__del'
        : seg.kind === 'ins' ? 'donemd-inline-diff__ins'
          : 'donemd-inline-diff__equal';
    span.textContent = seg.text;
    body.appendChild(span);
  }
  box.appendChild(body);

  const actions = document.createElement('span');
  actions.className = 'donemd-inline-diff__actions';

  const revert = document.createElement('button');
  revert.type = 'button';
  revert.className = 'donemd-inline-diff__btn donemd-inline-diff__btn--revert';
  revert.textContent = '还原';
  revert.title = '还原为 AI 改前的原文';
  revert.addEventListener('click', (e) => {
    e.preventDefault();
    revertAndClear(view);
  });

  const keep = document.createElement('button');
  keep.type = 'button';
  keep.className = 'donemd-inline-diff__btn donemd-inline-diff__btn--keep';
  let remaining = AUTO_KEEP_SECONDS;
  const render = () => { keep.textContent = `保留 (${remaining})`; };
  render();
  keep.title = '保留 AI 改后的内容（倒计时结束自动保留）';
  keep.addEventListener('click', (e) => {
    e.preventDefault();
    keepAndClear(view);
  });
  // Self-managing countdown: tick every second; auto-keep at 0.
  const timer = window.setInterval(() => {
    remaining -= 1;
    if (remaining <= 0) {
      window.clearInterval(timer);
      keepAndClear(view);
    } else {
      render();
    }
  }, 1000);
  // Expose for the spec.destroy cleanup (decoration removed → stop the timer).
  (box as HTMLElement & { _donemdTimer?: number })._donemdTimer = timer;

  actions.appendChild(revert);
  actions.appendChild(keep);
  box.appendChild(actions);
  return box;
}

export const InlineDiff = Extension.create({
  name: 'inlineDiff',

  addProseMirrorPlugins() {
    return [
      new Plugin<InlineDiffState>({
        key: inlineDiffKey,
        state: {
          init: () => ({ ...EMPTY }),
          apply(tr, prev): InlineDiffState {
            const meta = tr.getMeta(inlineDiffKey) as InlineDiffMeta | undefined;
            if (meta) {
              if (meta.kind === 'show') {
                return {
                  active: true,
                  from: meta.from,
                  to: meta.to,
                  before: meta.before,
                  segments: computeDiff(meta.before, meta.after),
                };
              }
              return { ...EMPTY };
            }
            if (prev.active && tr.docChanged) {
              return {
                ...prev,
                from: tr.mapping.map(prev.from),
                to: tr.mapping.map(prev.to),
              };
            }
            return prev;
          },
        },
        props: {
          decorations(this: Plugin<InlineDiffState>, editorState) {
            const s = this.getState(editorState);
            if (!s || !s.active) return null;
            const decos: Decoration[] = [];
            // Hide the real (new) text in [from,to]; the widget shows the diff
            // in its place so the result isn't rendered twice.
            if (s.to > s.from) {
              decos.push(
                Decoration.inline(s.from, s.to, { class: 'donemd-inline-diff__source' })
              );
            }
            decos.push(
              Decoration.widget(s.from, (view) => buildWidget(view as EditorView, s), {
                side: -1,
                ignoreSelection: true,
                // Stable key → PM reuses the same widget DOM across re-renders
                // instead of rebuilding it, so the countdown timer isn't reset
                // every transaction.
                key: 'donemd-inline-diff',
                // Stop the countdown interval when the decoration is removed.
                destroy: (node: Node) => {
                  const t = (node as HTMLElement & { _donemdTimer?: number })._donemdTimer;
                  if (t) window.clearInterval(t);
                },
              })
            );
            return DecorationSet.create(editorState.doc, decos);
          },
        },
      }),
    ];
  },
});
