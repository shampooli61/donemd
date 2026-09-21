// @vitest-environment jsdom
import { it, expect } from 'vitest';
import { Editor } from '@tiptap/core';
import StarterKit from '@tiptap/starter-kit';
import { RawMarkdownBlock } from './raw-markdown-block';
it('edits raw source without executing HTML and supports undo and cancel', () => {
  const mount = document.createElement('div'); document.body.append(mount);
  const editor = new Editor({ element: mount, extensions: [StarterKit, RawMarkdownBlock], content: { type: 'doc', content: [{ type: 'raw_markdown_block', attrs: { raw: '<details>original</details>' } }] } });
  const open = () => document.querySelector<HTMLButtonElement>('[aria-label="编辑原文"]')!.click();
  open();
  const input = document.querySelector<HTMLTextAreaElement>('[aria-label="原文内容"]')!;
  input.value = '<script>window.bad=true</script>';
  document.querySelector<HTMLButtonElement>('[data-raw-save]')!.click();
  expect(editor.getJSON().content?.[0].attrs?.raw).toBe('<script>window.bad=true</script>');
  expect(document.querySelectorAll('script')).toHaveLength(0);
  editor.commands.undo();
  expect(editor.getJSON().content?.[0].attrs?.raw).toBe('<details>original</details>');
  open(); document.querySelector<HTMLTextAreaElement>('[aria-label="原文内容"]')!.value = 'cancelled';
  document.querySelector<HTMLButtonElement>('[data-raw-cancel]')!.click();
  expect(editor.getJSON().content?.[0].attrs?.raw).toBe('<details>original</details>');
  editor.destroy(); mount.remove();
});
