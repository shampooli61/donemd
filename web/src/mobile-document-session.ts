import type { Editor, JSONContent } from '@tiptap/core';
import { EditorState } from '@tiptap/pm/state';

/** New disk content is a baseline, never an undo step into a different version. */
export function loadMobileDocument(editor: Editor, content: JSONContent): void {
  const doc = editor.schema.nodeFromJSON(content);
  doc.check();
  editor.view.updateState(EditorState.create({ schema: editor.schema, doc, plugins: editor.state.plugins }));
}
