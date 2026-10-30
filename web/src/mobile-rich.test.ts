// @vitest-environment jsdom
import { it, expect } from 'vitest';
import { Editor } from '@tiptap/core';
import StarterKit from '@tiptap/starter-kit';
import { MathBlock } from './math-block';
import { commitRichNode } from './mobile-rich';
it('edits an existing formula in the same undo history', () => {
  const editor = new Editor({ extensions: [StarterKit, MathBlock], content: { type: 'doc', content: [{ type: 'math_block', attrs: { latex: 'x' } }] } });
  commitRichNode(editor, { type: 'math_block', attrs: { latex: 'x^2' } }, 0);
  expect(editor.getJSON().content?.[0].attrs?.latex).toBe('x^2');
  editor.commands.undo();
  expect(editor.getJSON().content?.[0].attrs?.latex).toBe('x');
  editor.destroy();
});
