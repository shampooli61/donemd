import type { Editor, JSONContent } from '@tiptap/core';
import { closeHistory } from '@tiptap/pm/history';

export function commitRichNode(editor: Editor, content: JSONContent, position?: number): boolean {
  if (!editor.isEditable) return false;
  const node = editor.schema.nodeFromJSON(content);
  const tr = closeHistory(editor.state.tr);
  if (position !== undefined) {
    const old = tr.doc.nodeAt(position);
    if (!old || old.type !== node.type) return false;
    tr.replaceWith(position, position + old.nodeSize, node);
  } else if (node.isInline) {
    tr.replaceSelectionWith(node);
  } else {
    const from = editor.state.selection.$from;
    const at = from.depth ? from.after(1) : editor.state.doc.content.size;
    tr.insert(at, node);
  }
  editor.view.dispatch(tr);
  editor.view.dispatch(closeHistory(editor.state.tr));
  return true;
}
