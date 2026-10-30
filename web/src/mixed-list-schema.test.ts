// @vitest-environment jsdom
import { describe, expect, it } from 'vitest';
import { Editor, getSchema, type JSONContent } from '@tiptap/core';
import StarterKit from '@tiptap/starter-kit';
import TaskList from '@tiptap/extension-task-list';
import TaskItem from '@tiptap/extension-task-item';
import { Callout } from './callout';

const paragraph = (text: string): JSONContent => ({ type: 'paragraph', content: [{ type: 'text', text }] });
const bullet = (text: string): JSONContent => ({ type: 'bulletList', content: [{ type: 'listItem', content: [paragraph(text)] }] });
const tasks: JSONContent = {
  type: 'taskList', content: [
    { type: 'taskItem', attrs: { checked: false }, content: [paragraph('todo'), bullet('nested ordinary')] },
    { type: 'taskItem', attrs: { checked: true }, content: [paragraph('done')] },
  ],
};
const mixed: JSONContent[] = [bullet('plain'), tasks, bullet('tail')];
const extensions = [StarterKit, TaskList, TaskItem.configure({ nested: true }), Callout];

describe('mixed-list schema contract shared by desktop and mobile', () => {
  for (const container of ['doc', 'blockquote', 'listItem', 'taskItem', 'callout']) {
    it(`accepts homogeneous sibling list runs inside ${container} and preserves JSON on reopen`, () => {
      let content: JSONContent = { type: container, content: mixed };
      if (container === 'callout') content.attrs = { type: 'note' };
      if (container === 'listItem' || container === 'taskItem') {
        content.content = [paragraph('parent'), ...mixed];
        if (container === 'taskItem') content.attrs = { checked: true };
        content = { type: container === 'taskItem' ? 'taskList' : 'bulletList', content: [content] };
      }
      const doc: JSONContent = container === 'doc' ? content : { type: 'doc', content: [content] };
      const schema = getSchema(extensions);
      const parsed = schema.nodeFromJSON(doc);
      // nodeFromJSON alone is permissive; check() actually validates content.
      expect(() => parsed.check()).not.toThrow();
      const editor = new Editor({ extensions, content: doc });
      try {
        editor.state.doc.check();
        const saved = editor.getJSON();
        expect(saved).toEqual(parsed.toJSON());
        expect(editor.commands.setContent(saved)).toBe(true);
        editor.state.doc.check();
        expect(editor.getJSON()).toEqual(saved);
      } finally {
        editor.destroy();
      }
    });
  }
});
