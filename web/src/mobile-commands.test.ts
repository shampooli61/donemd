// @vitest-environment jsdom
import { it, expect } from 'vitest';
import { Editor } from '@tiptap/core';
import StarterKit from '@tiptap/starter-kit';
import { replaceMatches, changeBlock } from './mobile-commands';
it('replaces literal matches across formatting in one undoable edit', () => {
  const editor = new Editor({ extensions: [StarterKit], content: '<p>你好 <strong>你好</strong></p>' });
  expect(replaceMatches(editor, '你好', '世界', true)).toBe(2);
  expect(editor.getText()).toBe('世界 世界');
  editor.commands.undo();
  expect(editor.getText()).toBe('你好 你好');
  expect(replaceMatches(editor, '', '错误', true)).toBe(0);
  editor.destroy();
});

it('moves a selected paragraph without losing content and can undo', () => {
  const editor = new Editor({ extensions: [StarterKit], content: '<p>first</p><p>second</p>' });
  editor.commands.setTextSelection(1);
  expect(changeBlock(editor, 'up')).toBe(false);
  expect(changeBlock(editor, 'down')).toBe(true);
  expect(editor.getText()).toBe('second\n\nfirst');
  editor.commands.undo();
  expect(editor.getText()).toBe('first\n\nsecond');
  editor.destroy();
});
