// @vitest-environment jsdom
import { describe, it, expect } from 'vitest';
import { Editor } from '@tiptap/core';
import StarterKit from '@tiptap/starter-kit';
import { runFormatCommand } from './bubble-menu';

describe('native format/history commands', () => {
  it('undoes and redoes edits in the originating editor only', () => {
    const editor = new Editor({ extensions: [StarterKit], content: '<p>original</p>' });
    const other = new Editor({ extensions: [StarterKit], content: '<p>other</p>' });
    editor.commands.insertContent('new ');
    const changed = editor.getHTML();
    runFormatCommand(editor, 'undo', () => {});
    expect(editor.getText()).toBe('original');
    runFormatCommand(editor, 'redo', () => {});
    expect(editor.getHTML()).toBe(changed);
    expect(other.getText()).toBe('other');
    editor.destroy(); other.destroy();
  });
});
