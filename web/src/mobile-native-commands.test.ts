// @vitest-environment jsdom
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { Editor } from '@tiptap/core';
import StarterKit from '@tiptap/starter-kit';
import Link from '@tiptap/extension-link';
import TaskList from '@tiptap/extension-task-list';
import TaskItem from '@tiptap/extension-task-item';
import TableRow from '@tiptap/extension-table-row';
import TableCell from '@tiptap/extension-table-cell';
import TableHeader from '@tiptap/extension-table-header';
import { NodeSelection } from '@tiptap/pm/state';
import { createNativeCommands, type NativeEditorResult, type NativeEditorState } from './mobile-native-commands';
import { loadMobileDocument } from './mobile-document-session';
import { MobileReadOnlyGuard } from './mobile-readonly';
import { createSnapshotProtection } from './mobile-snapshot-protection';
import { RawMarkdownBlock } from './raw-markdown-block';
import { MathBlock } from './math-block';
import { MathInline } from './math-inline';
import { DonemdImage } from './image-node';
import { DonemdVideo } from './video-node';
import { MobileTable } from './mobile-table';
import { Callout } from './callout';
import { HeadingFold } from './heading-fold';
import { attachMobileViewport } from './mobile-viewport';
import { readFileSync } from 'node:fs';

let editor: Editor, native: ReturnType<typeof createNativeCommands>, revision: number;
let protection: ReturnType<typeof createSnapshotProtection>;
let results: NativeEditorResult[], states: NativeEditorState[], serial: number;
const send = (name: string, args: Record<string, string> = {}, selectionToken?: string) => native.receive({ requestId: `request-${++serial}`, identity: 'file-a', revision, name, args, selectionToken });
const capture = async () => { const result = await send('selection.capture'); expect(result.success).toBe(true); return result.selectionToken!; };
beforeEach(() => {
  document.body.className = ''; localStorage.clear();
  document.body.innerHTML = '<div id="mobile-viewport"><nav class="mobile-reading"><button>阅读</button></nav><div id="mobile-scroll"><main id="editor"></main></div><nav class="mobile-toolbar"></nav></div>';
  revision = 3; serial = 0; results = []; states = [];
  editor = new Editor({ element: document.querySelector('#editor')!, extensions: [MobileReadOnlyGuard, StarterKit, Link,
    TaskList, TaskItem.configure({ nested: true }), MobileTable, TableRow, TableCell, TableHeader,
    RawMarkdownBlock, MathBlock, MathInline, DonemdImage, DonemdVideo, Callout, HeadingFold], content: '<p>first word</p><p>second word</p>' });
  protection = createSnapshotProtection(editor, () => revision, next => { revision = next; });
  native = createNativeCommands(editor, { revision: () => revision, locked: () => protection.isLocked(), publish: value => states.push(value), result: value => results.push(value), preview: vi.fn() });
  native.info({ identity: 'file-a', source: 'first word\n\nsecond word' });
});
afterEach(() => { editor.destroy(); vi.restoreAllMocks(); document.body.innerHTML = ''; });

describe('native selection bookmarks', () => {
  it('retains independent panel selection after focus and cursor changes, and maps inserted content', async () => {
    editor.commands.setTextSelection({ from: 1, to: 6 });
    const token = await capture();
    editor.commands.setTextSelection(15);
    editor.commands.insertContentAt(1, 'prefix ');
    const result = await send('format.bold', {}, token);
    expect(result.success).toBe(true);
    expect(editor.state.doc.textBetween(editor.state.selection.from, editor.state.selection.to)).toBe('first');
    expect(editor.state.selection.from).toBe(8);
    expect(editor.isActive('bold')).toBe(true);
    expect(editor.state.doc.textContent).toBe('prefix first wordsecond word');
    expect((await send('format.italic', {}, token)).success).toBe(true);
    expect(editor.isActive('bold')).toBe(true); expect(editor.isActive('italic')).toBe(true);
    expect((await send('focus.restore', {}, token)).success).toBe(true);
    expect(editor.state.selection.from).toBe(8);
  });
  it('restores selection without requesting keyboard focus when focus is false', async () => {
    editor.commands.setTextSelection({ from: 1, to: 6 }); const token = await capture();
    editor.commands.setTextSelection(15);
    const focus = vi.spyOn(editor.view, 'focus');
    const result = await send('focus.restore', { focus: 'false' }, token);
    expect(result.success).toBe(true);
    expect(editor.state.selection.from).toBe(1); expect(editor.state.selection.to).toBe(6);
    expect(focus).not.toHaveBeenCalled(); expect(editor.isFocused).toBe(false);
    expect((await send('focus.restore', { focus: 'invalid' }, token)).success).toBe(false);
    expect(focus).not.toHaveBeenCalled();
  });
  it('rejects a deleted captured text range instead of formatting a neighboring paragraph', async () => {
    editor.commands.setTextSelection({ from: 1, to: 6 }); const token = await capture();
    editor.commands.deleteRange({ from: 1, to: 6 });
    const before = editor.getJSON();
    expect((await send('format.bold', {}, token)).success).toBe(false);
    expect(editor.getJSON()).toEqual(before);
  });
  it('invalidates every bookmark on true load even if identity/revision are unchanged', async () => {
    const token = await capture();
    loadMobileDocument(editor, { type: 'doc', content: [{ type: 'paragraph', content: [{ type: 'text', text: 'replacement' }] }] });
    const before = editor.getJSON();
    const result = await send('insert.raw', { text: 'must not insert' }, token);
    expect(result.success).toBe(false); expect(result.message).toContain('选区'); expect(editor.getJSON()).toEqual(before);
  });
  it('rejects stale identities, revisions, released tokens and non-whitelisted code', async () => {
    const token = await capture();
    const before = editor.getJSON();
    expect((await native.receive({ requestId: 'old-id', identity: 'old-file', revision, name: 'format.bold', args: {} })).success).toBe(false);
    expect((await native.receive({ requestId: 'old-revision', identity: 'file-a', revision: 2, name: 'format.bold', args: {} })).success).toBe(false);
    expect((await send('selection.release', {}, token)).success).toBe(true);
    expect((await send('format.bold', {}, token)).success).toBe(false);
    expect((await send('editor.commands.clearContent()')).success).toBe(false);
    expect((await native.receive({ requestId: 'bad-args', identity: 'file-a', revision, name: 'insert.table', args: { rows: 3 } })).success).toBe(false);
    expect(editor.getJSON()).toEqual(before);
  });
  it('does not mint tokens or emit changes for repeated equal documentInfo, state reads or publishes', () => {
    const initial = native.state(), count = states.length;
    for (let i = 0; i < 20; i++) {
      native.info({ identity: 'file-a', source: 'first word\n\nsecond word' });
      native.publish(); expect(native.state()).toEqual(initial);
    }
    expect(states).toHaveLength(count);
    native.info({ identity: 'file-a', source: 'longer source' });
    expect(states).toHaveLength(count + 1);
    expect(native.state().selectionToken).toBe(initial.selectionToken);
  });
});

describe('native command gates and ordering', () => {
  it('ACKs synchronous commands and failures in FIFO order without loading content', async () => {
    editor.commands.setTextSelection({ from: 1, to: 6 }); const token = await capture(); results.length = 0;
    const firstDoc = editor.state.doc;
    const requests = [send('format.bold', {}, token), send('not.a.command'), send('format.italic', {}, token), send('format.strike', {}, token)];
    const replies = await Promise.all(requests);
    expect(results.map(r => r.requestId)).toEqual(replies.map(r => r.requestId));
    expect(replies.map(r => r.success)).toEqual([true, false, true, true]);
    expect(editor.state.doc.textContent).toBe(firstDoc.textContent);
    expect(editor.getJSON().content?.[0].content?.[0].marks?.map(mark => mark.type)).toEqual(['bold', 'italic', 'strike']);
    expect(editor.can().undo()).toBe(true);
    expect((await send('history.undo')).success).toBe(true);
    expect((await send('history.redo')).success).toBe(true);
  });
  it('does not truncate composition, blur, toggle readonly, or restore selection during IME', async () => {
    const token = await capture(), before = editor.getJSON();
    Object.defineProperty(editor.view, 'composing', { configurable: true, value: true });
    const blur = vi.spyOn(editor.commands, 'blur');
    for (const name of ['keyboard.dismiss', 'format.bold', 'insert.rule', 'history.undo', 'mode.set', 'focus.restore']) {
      const result = await send(name, name === 'mode.set' ? { editable: 'false' } : {}, token);
      expect(result.success).toBe(false); expect(result.message).toContain('输入');
    }
    expect(editor.getJSON()).toEqual(before); expect(editor.isEditable).toBe(true); expect(blur).not.toHaveBeenCalled();
    Object.defineProperty(editor.view, 'composing', { configurable: true, value: false });
    expect((await send('format.bold', {}, token)).success).toBe(true);
  });
  it('rejects tokenless search navigation while composing without moving selection or changing query', async () => {
    await send('search.set', { query: 'word' });
    const before = editor.state.selection.toJSON(), searchBefore = native.state().searchQuery;
    Object.defineProperty(editor.view, 'composing', { configurable: true, value: true });
    for (const name of ['search.set', 'search.next', 'search.previous']) {
      const result = await send(name, { query: 'first' });
      expect(result.success).toBe(false); expect(result.message).toContain('输入');
      expect(editor.state.selection.toJSON()).toEqual(before);
      expect(native.state().searchQuery).toBe(searchBefore);
    }
    Object.defineProperty(editor.view, 'composing', { configurable: true, value: false });
    expect((await send('search.next')).success).toBe(true);
    expect(editor.state.selection.toJSON()).not.toEqual(before);
  });
  it('unifies reading state and allows nonwrite actions but blocks all writes', async () => {
    expect((await send('mode.set', { editable: 'false' })).success).toBe(true);
    expect(editor.isEditable).toBe(false); expect(document.body.classList.contains('reading-mode')).toBe(true);
    expect(native.state().editable).toBe(false);
    const before = editor.getJSON();
    for (const name of ['format.bold', 'insert.rule', 'history.undo', 'block.delete', 'search.replace', 'context.edit', 'table.delete']) expect((await send(name)).success).toBe(false);
    expect((await send('search.set', { query: 'word' })).success).toBe(true);
    expect((await send('search.next')).success).toBe(true);
    expect((await send('reader.set', { theme: 'paper', fontSize: '22' })).success).toBe(true);
    expect(native.state()).toMatchObject({ searchCount: 2, theme: 'paper', fontSize: 22 });
    expect(editor.getJSON()).toEqual(before);
    expect((await send('mode.set', { editable: 'true' })).success).toBe(true);
    expect(document.body.classList.contains('reading-mode')).toBe(false); expect(editor.isEditable).toBe(true);
  });
  it('honors the actual snapshot protection lock and retains its ACK/unlock semantics', async () => {
    const token = await capture(), before = editor.getJSON();
    expect(protection.begin('backup')?.body).toEqual(before);
    expect(native.state().locked).toBe(true);
    for (const name of ['mode.set', 'format.bold', 'insert.image', 'history.undo']) expect((await send(name, { editable: 'true', src: 'assets/a.png' }, token)).success).toBe(false);
    expect(editor.getJSON()).toEqual(before); expect(editor.isEditable).toBe(false);
    expect(protection.abort('wrong')).toBe(false); expect(protection.abort('backup')).toBe(true);
    expect(editor.isEditable).toBe(true); expect(native.state().locked).toBe(false);
    expect((await send('format.bold', {}, token)).success).toBe(true);
  });
});

describe('native search, context and rich insertion', () => {
  it('keeps search navigation and highlighters available without opening DOM controls', async () => {
    await send('native.activate');
    await send('search.set', { query: 'word' });
    expect(native.state()).toMatchObject({ searchActive: true, searchCount: 2, searchCurrent: 1 });
    expect(document.querySelector('.donemd-find-match.is-current')).not.toBeNull();
    expect(document.querySelector<HTMLElement>('.donemd-find')!.hidden).toBe(true);
    await send('search.next'); expect(native.state().searchCurrent).toBe(2);
    await send('search.previous'); expect(native.state().searchCurrent).toBe(1);
    const replaced = await send('search.replace', { query: 'word', replacement: '词', all: 'true' });
    expect(replaced.data).toEqual({ replaced: '2' }); expect(editor.getText()).toBe('first 词\n\nsecond 词');
    await send('history.undo'); expect(editor.getText()).toBe('first word\n\nsecond word');
    await send('search.close'); expect(native.state().searchActive).toBe(false);
    expect(document.querySelector('.donemd-find-match')).toBeNull();
  });
  it('uses top-level rich insertion and edits only an explicitly captured node, with undo', async () => {
    editor.commands.setTextSelection(4); const token = await capture();
    expect((await send('insert.raw', { text: '<unsupported original="yes" />' }, token)).success).toBe(true);
    expect(editor.state.doc.child(0).textContent).toBe('first word');
    expect(editor.state.doc.child(1).type.name).toBe('raw_markdown_block');
    const pos = editor.state.doc.child(0).nodeSize;
    editor.view.dispatch(editor.state.tr.setSelection(NodeSelection.create(editor.state.doc, pos)));
    const objectToken = await capture();
    expect(native.state()).toMatchObject({ nodeType: 'raw_markdown_block', attributes: { text: '<unsupported original="yes" />' } });
    editor.commands.setTextSelection(1);
    expect((await send('context.edit', { text: 'new raw' })).success).toBe(false);
    expect((await send('context.edit', { text: 'new raw' }, objectToken)).success).toBe(true);
    expect(editor.state.doc.child(1).attrs.raw).toBe('new raw');
    await send('history.undo'); expect(editor.state.doc.child(1).attrs.raw).toBe('<unsupported original="yes" />');
  });
  it('continues an attachment panel token after its own attribute edits, without reviving other captures', async () => {
    await send('insert.image', { src: 'assets/image.png' });
    const pos = editor.state.doc.child(0).nodeSize;
    editor.view.dispatch(editor.state.tr.setSelection(NodeSelection.create(editor.state.doc, pos)));
    const initiating = await capture(), independent = await capture();
    expect((await send('context.edit', { alt: 'first description' }, initiating)).success).toBe(true);
    expect(editor.state.doc.nodeAt(pos)!.attrs.alt).toBe('first description');
    expect((await send('context.edit', { alt: 'second description' }, initiating)).success).toBe(true);
    expect(editor.state.doc.nodeAt(pos)!.attrs.alt).toBe('second description');
    expect((await send('context.preview', {}, initiating)).success).toBe(true);
    expect((await send('context.preview', {}, independent)).success).toBe(false);
    expect((await send('context.deleteReference', {}, initiating)).success).toBe(true);
    expect(editor.state.doc.childCount).toBe(2);
    expect((await send('context.preview', {}, initiating)).success).toBe(false);
  });
  it('keeps a paragraph panel on the same logical block across repeated up/down moves', async () => {
    loadMobileDocument(editor, { type: 'doc', content: ['one', 'two', 'three'].map(text => ({ type: 'paragraph', content: [{ type: 'text', text }] })) });
    editor.commands.setTextSelection(6);
    const initiating = await capture(), independent = await capture();
    expect((await send('block.down', {}, initiating)).success).toBe(true);
    expect(editor.getText()).toBe('one\n\nthree\n\ntwo');
    expect(editor.state.selection.$from.parent.textContent).toBe('two');
    expect((await send('block.up', {}, initiating)).success).toBe(true);
    expect((await send('block.up', {}, initiating)).success).toBe(true);
    expect(editor.getText()).toBe('two\n\none\n\nthree');
    expect(native.state().attributes.canMoveUp).toBe('false');
    expect((await send('block.up', {}, initiating)).success).toBe(false);
    expect((await send('block.down', {}, initiating)).success).toBe(true);
    expect(editor.getText()).toBe('one\n\ntwo\n\nthree');
    expect((await send('format.bold', {}, independent)).success).toBe(false);
  });
  it('rejects a stale rich object even when a same-type object occupies its old numeric position', async () => {
    await send('insert.raw', { text: 'original object' });
    const pos = editor.state.doc.child(0).nodeSize;
    editor.view.dispatch(editor.state.tr.setSelection(NodeSelection.create(editor.state.doc, pos)));
    const token = await capture(), original = editor.state.doc.nodeAt(pos)!;
    editor.view.dispatch(editor.state.tr.replaceWith(pos, pos + original.nodeSize, editor.schema.nodes.raw_markdown_block.create({ raw: 'replacement object' })));
    const before = editor.getJSON();
    expect((await send('context.edit', { text: 'wrong overwrite' }, token)).success).toBe(false);
    expect(editor.getJSON()).toEqual(before); expect(editor.state.doc.nodeAt(pos)!.attrs.raw).toBe('replacement object');
  });
  it('validates link/table/theme bounds without clamping invalid input or mutating', async () => {
    const before = editor.getJSON();
    for (const [name, args] of [['format.link', { href: 'javascript:alert(1)' }], ['insert.table', { rows: '101', cols: '3' }], ['insert.table', { rows: '3', cols: '1.5' }], ['reader.set', { theme: 'unknown' }], ['insert.image', { src: 'data:text/html,bad' }]] as [string, Record<string, string>][]) expect((await send(name, args)).success).toBe(false);
    expect(editor.getJSON()).toEqual(before);
    editor.commands.setTextSelection({ from: 1, to: 6 });
    expect((await send('format.link', { href: 'https://example.com' })).success).toBe(true);
    expect(editor.getAttributes('link').href).toBe('https://example.com');
    expect((await send('format.link', { href: '' })).success).toBe(true); expect(editor.isActive('link')).toBe(false);
  });
  it('publishes outline and changes folding/navigation without body changes', async () => {
    loadMobileDocument(editor, { type: 'doc', content: [{ type: 'heading', attrs: { level: 1 }, content: [{ type: 'text', text: 'Title' }] }, { type: 'paragraph', content: [{ type: 'text', text: 'body' }] }] });
    const before = editor.getJSON();
    expect(native.state().headings).toEqual([{ id: 0, title: 'Title', level: 1, collapsed: false }]);
    expect((await send('outline.toggle', { id: '0' })).success).toBe(true); expect(native.state().headings[0].collapsed).toBe(true);
    expect((await send('outline.jump', { id: '0' })).success).toBe(true); expect(native.state().headings[0].collapsed).toBe(false);
    expect(editor.getJSON()).toEqual(before);
  });
});

it('activates native UI only by handshake, hides both DOM bars and reserves no blank toolbar viewport', async () => {
  const toolbar = document.querySelector<HTMLElement>('.mobile-toolbar')!, reading = document.querySelector<HTMLElement>('.mobile-reading')!;
  const box = (height: number) => ({ x: 0, y: 0, top: 0, left: 0, right: 390, bottom: height, width: 390, height, toJSON() {} });
  toolbar.getBoundingClientRect = () => box(60); reading.getBoundingClientRect = () => box(44);
  vi.spyOn(editor.view, 'hasFocus').mockReturnValue(false);
  const stop = attachMobileViewport(editor, toolbar), shell = document.querySelector<HTMLElement>('#mobile-viewport')!;
  expect(toolbar.hidden).toBe(false); expect(reading.hidden).toBe(false);
  const before = editor.getJSON(); expect((await send('native.activate')).success).toBe(true);
  expect(document.body.classList.contains('native-controls')).toBe(true);
  expect(toolbar.hidden).toBe(true); expect(reading.hidden).toBe(true);
  // Reattach to synchronously measure the same update performed on resize.
  stop(); const cleanup = attachMobileViewport(editor, toolbar);
  expect(shell.style.height).toBe(`${window.innerHeight}px`);
  expect(shell.style.getPropertyValue('--mobile-toolbar-height')).toBe('0px');
  expect(shell.style.getPropertyValue('--mobile-reading-height')).toBe('0px');
  expect(document.querySelector('#mobile-scroll #editor .ProseMirror')).not.toBeNull();
  expect(editor.getJSON()).toEqual(before);
  const css = readFileSync('src/mobile.css', 'utf8');
  expect(css).toMatch(/\.native-controls \.mobile-toolbar,[\s\S]*?display: none !important/);
  await send('mode.set', { editable: 'false' }); await send('mode.set', { editable: 'true' });
  expect(toolbar.hidden).toBe(true); expect(reading.hidden).toBe(true);
  cleanup();
});

it('renders actual formula drafts and escaped raw/code previews without editor transactions, focus or writes', async () => {
  await send('mode.set', { editable: 'false' });
  const before = editor.getJSON(), selection = editor.state.selection.toJSON();
  const dispatch = vi.spyOn(editor.view, 'dispatch');
  const math = await send('preview.render', { type: 'math', text: 'x^2 + \\frac{1}{2}', display: 'true' });
  expect(math.success).toBe(true); expect(math.data?.html).toContain('class="katex'); expect(math.data?.html).toContain('Content-Security-Policy');
  const raw = await send('preview.render', { type: 'raw', text: '<script>alert(1)</script>' });
  expect(raw.success).toBe(true); expect(raw.data?.html).toContain('&lt;script&gt;'); expect(raw.data?.html).not.toContain('<script>');
  const broken = await send('preview.render', { type: 'math', text: '\\frac{', display: 'false' });
  expect(broken.data?.error).toContain('原文会保留');
  expect(dispatch).not.toHaveBeenCalled(); expect(editor.getJSON()).toEqual(before); expect(editor.state.selection.toJSON()).toEqual(selection);
});
