// Phase 3 Slice 8 (#69) — [[AI 唤起]] line-start gray hint.
//
// A ProseMirror plugin that paints a gray "⌘/ 唤起 AI" widget after the cursor
// whenever there is no selection AND the cursor sits in an empty top-level
// paragraph (空段落 / 行首). This is the permanent discoverability affordance
// for the no-selection [[AI 唤起]] entry — Notion-style placeholder — which
// replaced the scrapped one-shot toast (2026-06-30 grill, see CONTEXT.md).
//
// Pure decoration: it never touches the document. It hides itself while text
// streams in (aiStreaming active) so it can't collide with the [[临时态]]
// widget, and while the editor is read-only.

import { Extension } from '@tiptap/core';
import { Plugin, PluginKey } from '@tiptap/pm/state';
import { Decoration, DecorationSet } from '@tiptap/pm/view';
import { aiStreamingKey } from './ai-streaming';

export const aiHintKey = new PluginKey('aiHint');

/** Should the gray hint show at the current cursor? No selection, cursor in an
 *  empty top-level paragraph, editor editable, and no AI stream in flight. Kept
 *  in sync with slash-menu's "empty paragraph" notion of 行首 — the hint marks
 *  exactly the spots where ⌘/ is most discoverable, even though ⌘/ itself now
 *  fires on any no-selection cursor (S8 widened the trigger; the hint stays
 *  conservative so prose isn't littered with it). */
function shouldShowHint(state: import('@tiptap/pm/state').EditorState): boolean {
  const { $from, empty } = state.selection;
  if (!empty) return false;
  // An AI stream is committing / painting — don't double up widgets.
  const streaming = aiStreamingKey.getState(state);
  if (streaming?.active) return false;
  if ($from.depth !== 1) return false;
  if ($from.parent.type.name !== 'paragraph') return false;
  if ($from.parent.content.size !== 0) return false;
  return true;
}

function buildHint(): HTMLElement {
  const el = document.createElement('span');
  el.className = 'donemd-ai-hint';
  el.textContent = '⌘/ 唤起 AI';
  // Never let the placeholder interfere with clicks / caret placement.
  el.contentEditable = 'false';
  return el;
}

export const AIHint = Extension.create({
  name: 'aiHint',

  addProseMirrorPlugins() {
    return [
      new Plugin({
        key: aiHintKey,
        props: {
          decorations(editorState) {
            if (!shouldShowHint(editorState)) return null;
            const { from } = editorState.selection;
            // side: 1 keeps the widget after the caret so the caret stays at the
            // line start; ignoreSelection so it never becomes a selection target.
            return DecorationSet.create(editorState.doc, [
              Decoration.widget(from, buildHint, { side: 1, ignoreSelection: true }),
            ]);
          },
        },
      }),
    ];
  },
});
