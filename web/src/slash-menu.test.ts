// @vitest-environment jsdom
import { it, expect, vi } from 'vitest';
import { Editor } from '@tiptap/core';
import StarterKit from '@tiptap/starter-kit';
import { createSlashMenu } from './slash-menu';
import { createDocumentSearch } from './document-search';
it('announces commands, moves active focus and restores the editor without changing its selection', () => {
  const onPick = vi.fn();
  const slash = createSlashMenu({ onPick });
  const editor = new Editor({ extensions: [StarterKit, slash.extension], content: '<p>example</p>' });
  editor.commands.setTextSelection({ from: 1, to: 5 });
  const selection = editor.state.selection.toJSON();
  const search = createDocumentSearch(editor, () => {});
  editor.view.coordsAtPos = () => ({ left: 0, right: 0, top: 0, bottom: 20 });
  slash.panel.show(editor.view);
  const menu = document.querySelector<HTMLElement>('[role="menu"][aria-label="AI 操作"]')!;
  expect(menu).not.toBeNull();
  const first = menu.getAttribute('aria-activedescendant');
  menu.dispatchEvent(new KeyboardEvent('keydown', { key: 'ArrowDown', bubbles: true }));
  expect(menu.getAttribute('aria-activedescendant')).not.toBe(first);
  expect(menu.querySelectorAll('[role="menuitem"]').length).toBeGreaterThan(0);
  menu.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', bubbles: true }));
  expect(onPick).toHaveBeenCalledOnce();
  expect(editor.state.selection.toJSON()).toEqual(selection);
  search.destroy(); editor.destroy();
});
