// @vitest-environment jsdom
import { afterEach, expect, it, vi } from 'vitest';
import type { Editor } from '@tiptap/core';

// Exercise actual mobile bootstrap + real single-handler bridge registration.
// Isolated native-command tests bypassed attachReadingControls and missed its
// documentInfo handler overwriting the live snapshot's identity handler.
it('tags live changes AND safe flush snapshots with the documentInfo identity after full mobile bootstrap', async () => {
  document.body.innerHTML = '<div id="mobile-viewport"><div id="mobile-scroll"><main id="editor"></main></div></div>';
  localStorage.clear();
  const posted: { type: string; payload: Record<string, unknown> }[] = [];
  window.webkit = { messageHandlers: { donemd: { postMessage: value => { posted.push(JSON.parse(value)); } } } };
  await import('./mobile');
  const receive = (type: string, payload: unknown) => window.donemdBridge.receive({ version: 1, type, payload });
  const identity = '/documents/live-source.md';
  receive('documentInfo', { identity, source: '# Initial' });
  receive('loadDocument', { revision: 7, document: { type: 'doc', content: [{ type: 'paragraph', content: [{ type: 'text', text: 'Initial' }] }] } });
  const editor = (document.querySelector('.tiptap') as HTMLElement & { editor: Editor }).editor;
  expect(editor).toBeDefined();
  editor.commands.insertContent('中文已提交');
  const live = posted.filter(value => value.type === 'documentChanged').at(-1)!.payload;
  expect(live.identity).toBe(identity);
  expect(live.revision).toBe(7);
  expect(JSON.stringify(live.body)).toContain('中文已提交');
  // Swift saveNow's flush uses exactly this API. Empty identity rejected both
  // the continuous mirror and saves, even though the rich editor stayed editable.
  const flush = window.donemdMobileSnapshot() as ReturnType<typeof window.donemdMobileSnapshot> & { identity: string; sequence: number };
  expect(flush.identity).toBe(identity);
  expect(flush.revision).toBe(7);
  expect(flush.composing).toBe(false);
  expect(JSON.stringify(flush.body)).toContain('中文已提交');
  expect(flush.sequence).toBeGreaterThan(live.sequence as number);
  editor.destroy();
});

afterEach(() => {
  vi.restoreAllMocks();
  delete window.webkit;
  document.body.innerHTML = '';
});
