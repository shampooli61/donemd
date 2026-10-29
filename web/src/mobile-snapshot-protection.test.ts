// @vitest-environment jsdom
import { afterEach, expect, it } from 'vitest';
import { Editor } from '@tiptap/core';
import StarterKit from '@tiptap/starter-kit';
import { createSnapshotProtection } from './mobile-snapshot-protection';

const editors: Editor[] = [];
function fixture(editable = true) {
  const editor = new Editor({ extensions: [StarterKit], content: '<p>native baseline</p>', editable });
  editors.push(editor);
  let revision = 7;
  const protocol = createSnapshotProtection(editor, () => revision, value => { revision = value; });
  return { editor, protocol, revision: () => revision };
}
afterEach(() => { for (const editor of editors.splice(0)) editor.destroy(); });

it('ACK includes Web-only text and blocks every edit throughout an awaited native reload', async () => {
  const { editor, protocol, revision } = fixture();
  // No Swift bridge or documentChanged subscriber exists: this edit is Web-only.
  editor.commands.setContent('<p>Web-only final marker</p>');
  const ack = protocol.begin('operation');
  expect(ack?.body).toEqual(editor.getJSON());
  expect(JSON.stringify(ack)).toContain('Web-only final marker');
  expect(ack).toMatchObject({ token: 'operation', revision: 7, locked: true, composing: false });
  expect(editor.isEditable).toBe(false);
  const protectedBody = editor.getJSON();
  await Promise.resolve(); // Model the native revert suspension while JS keeps running.
  editor.setEditable(true); // Even a custom control bypassing contenteditable cannot mutate.
  editor.commands.insertContent('late lost character');
  expect(editor.getJSON()).toEqual(protectedBody);
  const disk = { type: 'doc', content: [{ type: 'paragraph', content: [{ type: 'text', text: 'disk version' }] }] };
  expect(protocol.finish('operation', disk, 8)).toBe(true);
  expect(revision()).toBe(8);
  expect(editor.getJSON()).toEqual(disk);
  expect(editor.getText()).toBe('disk version');
  expect(editor.isEditable).toBe(true);
  editor.commands.insertContent('new revision edit');
  expect(editor.getText()).toContain('new revision edit');
  expect(editor.commands.undo()).toBe(true);
  expect(editor.getText()).not.toContain('Web-only final marker');
});

it('abort restores editability without replacing the ACK body or revision', () => {
  const { editor, protocol, revision } = fixture();
  editor.commands.setContent('<p>unbridged draft</p>');
  const ack = protocol.begin('failed-backup');
  expect(ack).not.toBeNull();
  expect(protocol.abort('failed-backup')).toBe(true);
  expect(editor.getText()).toBe('unbridged draft');
  expect(revision()).toBe(7);
  expect(editor.isEditable).toBe(true);
});

it('preserves reading mode and rejects stale tokens and overlapping locks', () => {
  const { editor, protocol } = fixture(false);
  expect(protocol.begin('first')).not.toBeNull();
  expect(protocol.begin('second')).toBeNull();
  expect(protocol.abort('wrong')).toBe(false);
  expect(editor.isEditable).toBe(false);
  expect(protocol.abort('first')).toBe(true);
  expect(editor.isEditable).toBe(false);
});

it('rejects composition before snapshot and unlocks if replacement parsing fails', () => {
  const { editor, protocol } = fixture();
  Object.defineProperty(editor.view, 'composing', { configurable: true, value: true });
  expect(protocol.begin('ime')).toBeNull();
  expect(editor.isEditable).toBe(true);
  Object.defineProperty(editor.view, 'composing', { configurable: true, value: false });
  expect(protocol.begin('invalid')).not.toBeNull();
  expect(protocol.finish('invalid', { type: 'not-in-schema' }, 8)).toBe(false);
  expect(editor.isEditable).toBe(true);
  expect(editor.getText()).toBe('native baseline');
});

it('lets a denied catchup IME commit finish, pauses stale editing, and includes it in retry ACK', async () => {
  const { editor, protocol } = fixture();
  Object.defineProperty(editor.view, 'composing', { configurable: true, value: true });
  expect(protocol.begin('catchup')).toBeNull();
  protocol.pauseUntilRetry();
  // Pending pause must not filter the final composition transaction.
  editor.commands.setContent('<p>IME committed draft must survive</p>');
  Object.defineProperty(editor.view, 'composing', { configurable: true, value: false });
  editor.view.dom.dispatchEvent(new Event('compositionend'));
  await new Promise(resolve => setTimeout(resolve, 0));
  expect(editor.isEditable).toBe(false);
  expect(protocol.isLocked()).toBe(true);
  editor.commands.insertContent('must be blocked after IME');
  expect(editor.getText()).toBe('IME committed draft must survive');
  const ack = protocol.begin('retry');
  expect(JSON.stringify(ack?.body)).toContain('IME committed draft must survive');
  expect(protocol.abort('retry')).toBe(true);
  expect(editor.isEditable).toBe(true);
});
