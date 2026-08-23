// Phase 3 Slice 2 (#63) — M5 StreamingDecoration.
//
// A ProseMirror plugin that paints the [[临时态]] (provisional state) over the
// selection while AI output streams in: the original text greyed + struck
// through underneath, and the accumulating raw-markdown tokens rendered in a
// monospace widget on top. Nothing touches the real document until the stream
// completes — so any interruption (ESC / failure) just clears the decoration
// and the doc is byte-for-byte unchanged, no auto-undo, no undo-history junk.
//
// Token throughput is RAF-throttled (Q7): tokens land in a buffer; one
// requestAnimationFrame flush per frame repaints the widget. So the user sees
// a typewriter cadence while the editor mutates at most ~60Hz.

import { Extension } from '@tiptap/core';
import { Plugin, PluginKey } from '@tiptap/pm/state';
import { Decoration, DecorationSet } from '@tiptap/pm/view';

export const aiStreamingKey = new PluginKey('aiStreaming');

/** How streamed output lands (PRD § 直接替换 / 续写插入 / 生成插入). Only the
 *  decoration differs here; the commit lives in main.ts.
 *  - replace:  transform the selection — original is struck through, widget
 *              overlays it (S2 [[直接替换]]).
 *  - append:   continue from the selection end — original stays untouched,
 *              widget streams in after it ([[续写插入]]).
 *  - generate: produce from a cursor (no selection) — widget streams at the
 *              cursor, result auto-selected on commit ([[生成插入]]). */
export type AIStreamMode = 'replace' | 'append' | 'generate';

/** What the plugin tracks between transactions. */
interface AIStreamState {
  active: boolean;
  mode: AIStreamMode;
  from: number;
  to: number;
  /** Accumulated raw-markdown text rendered in the widget. */
  text: string;
}

const EMPTY: AIStreamState = { active: false, mode: 'replace', from: 0, to: 0, text: '' };

/** Meta payloads dispatched to drive the plugin (via tr.setMeta). */
type AIStreamMeta =
  | { kind: 'start'; mode: AIStreamMode; from: number; to: number }
  | { kind: 'append'; text: string }
  | { kind: 'clear' };

/** Build the widget DOM showing the streaming raw markdown. */
function buildWidget(text: string): HTMLElement {
  const el = document.createElement('span');
  el.className = 'donemd-ai-stream__text';
  // Show the accumulated text; a trailing caret hints "still streaming".
  el.textContent = text;
  const caret = document.createElement('span');
  caret.className = 'donemd-ai-stream__caret';
  caret.textContent = '▍';
  el.appendChild(caret);
  return el;
}

export const AIStreaming = Extension.create({
  name: 'aiStreaming',

  addProseMirrorPlugins() {
    return [
      new Plugin<AIStreamState>({
        key: aiStreamingKey,
        state: {
          init: () => ({ ...EMPTY }),
          apply(tr, prev): AIStreamState {
            const meta = tr.getMeta(aiStreamingKey) as AIStreamMeta | undefined;
            if (meta) {
              switch (meta.kind) {
                case 'start':
                  return { active: true, mode: meta.mode, from: meta.from, to: meta.to, text: '' };
                case 'append':
                  if (!prev.active) return prev;
                  return { ...prev, text: prev.text + meta.text };
                case 'clear':
                  return { ...EMPTY };
              }
            }
            // Map positions through document changes so the decoration tracks
            // edits (there shouldn't be any while readonly, but be safe).
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
          decorations(this: Plugin<AIStreamState>, editorState) {
            const s = this.getState(editorState);
            if (!s || !s.active) return null;
            const decos: Decoration[] = [];
            // Only [[直接替换]] greys + strikes the original (it's being
            // transformed away). [[续写插入]] / [[生成插入]] leave the existing
            // text intact — they extend from the selection end / cursor, so
            // the original must look untouched (PRD: 不动原选区).
            if (s.mode === 'replace' && s.to > s.from) {
              decos.push(
                Decoration.inline(s.from, s.to, { class: 'donemd-ai-stream__original' })
              );
            }
            // Widget streams at s.to: the selection end (append) or cursor
            // (generate, where from === to). side: 1 keeps it after the
            // boundary so appended text reads as a continuation.
            decos.push(
              Decoration.widget(s.to, () => buildWidget(s.text), {
                side: 1,
                ignoreSelection: true,
              })
            );
            return DecorationSet.create(editorState.doc, decos);
          },
        },
      }),
    ];
  },
});
