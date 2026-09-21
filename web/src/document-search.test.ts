// @vitest-environment jsdom
import { describe, it, expect } from 'vitest';
import { Editor } from '@tiptap/core';
import StarterKit from '@tiptap/starter-kit';
import { findMatches, createDocumentSearch } from './document-search';

describe('document find', () => {
  it('finds text across marks, without crossing paragraphs or treating input as regex', () => {
    const editor = new Editor({ extensions: [StarterKit], content: '<p>星<strong>河</strong> a.b</p><p>星</p><p>河</p>' });
    const hits = findMatches(editor.state.doc, '星河');
    expect(hits).toHaveLength(1);
    expect(editor.state.doc.textBetween(hits[0].from, hits[0].to)).toBe('星河');
    expect(findMatches(editor.state.doc, 'a.b')).toHaveLength(1);
    expect(findMatches(editor.state.doc, 'a+b')).toHaveLength(0);
    editor.destroy();
  });
  it('opens, navigates and closes without editing the document or its history', () => {
    const editor = new Editor({ extensions: [StarterKit], content: '<p>星河 星河</p>' });
    const before = editor.getJSON();
    const search = createDocumentSearch(editor, () => {});
    search.open();
    const field = document.querySelector<HTMLInputElement>('[aria-label="查找文档"]')!;
    field.value = '星河'; field.dispatchEvent(new Event('input'));
    expect(document.querySelector('[role="status"]')?.textContent).toBe('1 / 2');
    field.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', bubbles: true }));
    expect(document.querySelector('[role="status"]')?.textContent).toBe('2 / 2');
    field.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true }));
    expect(editor.getJSON()).toEqual(before);
    expect(editor.can().undo()).toBe(false);
    search.destroy(); editor.destroy();
  });
});
