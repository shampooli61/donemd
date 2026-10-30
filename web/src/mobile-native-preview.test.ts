// @vitest-environment jsdom
import { afterEach, expect, it, vi } from 'vitest';
import { Editor } from '@tiptap/core';
import StarterKit from '@tiptap/starter-kit';
import mermaid from 'mermaid';
import * as previewRenderer from './mobile-native-preview';
import { createNativeCommands } from './mobile-native-commands';

// Only the external async SVG renderer is controlled here. Transactions,
// selection bookmarks, FIFO dispatch and ACKs use a real TipTap editor.
vi.mock('mermaid', () => ({ default: { initialize: vi.fn(), render: vi.fn() } }));
afterEach(() => { vi.restoreAllMocks(); vi.clearAllMocks(); });
it('mode.set cannot invoke draft preview rendering or return a preview validation error', async () => {
  const editor = new Editor({ extensions: [StarterKit], content: '<p>original</p>' });
  const results: { success: boolean; message?: string }[] = [];
  const native = createNativeCommands(editor, { revision: () => 1, locked: () => false, publish: () => {}, result: result => results.push(result), preview: () => {} });
  native.info({ identity: 'file', source: 'original' });
  const render = vi.spyOn(previewRenderer, 'renderNativePreview');
  for (const editable of ['false', 'true', 'false']) {
    const result = await native.receive({ requestId: `mode-${results.length}`, identity: 'file', revision: 1, name: 'mode.set', args: { editable } });
    expect(result.success).toBe(true); expect(result.message).toBeUndefined();
    expect(result.state?.editable).toBe(editable === 'true');
    expect(editor.isEditable).toBe(editable === 'true');
  }
  expect(render).not.toHaveBeenCalled(); expect(results).toHaveLength(3);
  editor.destroy();
});
it('waits for async strict Mermaid preview before ACKing the following editor command', async () => {
  const editor = new Editor({ extensions: [StarterKit], content: '<p>original</p>' });
  const acknowledgments: string[] = [];
  const native = createNativeCommands(editor, { revision: () => 1, locked: () => false, publish: () => {}, result: result => acknowledgments.push(result.requestId), preview: () => {} });
  native.info({ identity: 'file', source: 'original' });
  let finish!: () => void;
  vi.mocked(mermaid.render).mockImplementationOnce(() => new Promise(resolve => { finish = () => resolve({ svg: '<svg><text>Diagram</text></svg>' } as Awaited<ReturnType<typeof mermaid.render>>); }));
  const before = editor.getJSON();
  const first = native.receive({ requestId: 'preview', identity: 'file', revision: 1, name: 'preview.render', args: { type: 'code', language: 'mermaid', text: 'graph TD; A-->B' } });
  const second = native.receive({ requestId: 'format', identity: 'file', revision: 1, name: 'format.bold', args: {} });
  await Promise.resolve();
  expect(acknowledgments).toEqual([]); expect(editor.getJSON()).toEqual(before);
  expect(mermaid.initialize).toHaveBeenCalledWith(expect.objectContaining({ securityLevel: 'strict' }));
  finish();
  const result = await first; await second;
  expect(result.success).toBe(true); expect(result.data?.html).toContain('<svg><text>Diagram</text></svg>');
  expect(acknowledgments).toEqual(['preview', 'format']); expect(editor.isActive('bold')).toBe(true);
  editor.destroy();
});
it('preserves invalid Mermaid draft text and returns a readable preview error', async () => {
  const editor = new Editor({ extensions: [StarterKit], content: '<p>original</p>' });
  const native = createNativeCommands(editor, { revision: () => 1, locked: () => false, publish: () => {}, result: () => {}, preview: () => {} });
  native.info({ identity: 'file', source: 'original' });
  vi.mocked(mermaid.render).mockRejectedValueOnce(new Error('parse failure'));
  const before = editor.getJSON();
  const result = await native.receive({ requestId: 'broken', identity: 'file', revision: 1, name: 'preview.render', args: { type: 'code', language: 'mermaid', text: '<broken diagram>' } });
  expect(result.success).toBe(true); expect(result.data?.error).toContain('原文会保留');
  expect(result.data?.html).toContain('&lt;broken diagram&gt;'); expect(editor.getJSON()).toEqual(before);
  editor.destroy();
});
