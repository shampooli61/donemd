// @vitest-environment jsdom
import { afterEach, beforeEach, expect, it, vi } from 'vitest';
import { Editor } from '@tiptap/core';
import StarterKit from '@tiptap/starter-kit';
import { readFileSync } from 'node:fs';
import { attachMobileViewport } from './mobile-viewport';

let editor: Editor, shell: HTMLElement, pane: HTMLElement, toolbar: HTMLElement;
let viewport: EventTarget & { height: number; width: number; offsetTop: number; offsetLeft: number };
let caret = { top: 390, bottom: 410 };
let focused = true;
const rect = (top: number, bottom: number) => ({ top, bottom, height: bottom - top, left: 0, right: 400, width: 400, x: 0, y: top, toJSON() {} });
function flush() { vi.advanceTimersByTime(20); }
beforeEach(() => {
  vi.useFakeTimers();
  vi.stubGlobal('requestAnimationFrame', (cb: FrameRequestCallback) => setTimeout(() => cb(0), 1));
  vi.stubGlobal('cancelAnimationFrame', clearTimeout);
  viewport = Object.assign(new EventTarget(), { height: 460, width: 390, offsetTop: 0, offsetLeft: 0 });
  vi.stubGlobal('visualViewport', viewport);
  document.body.innerHTML = '<div id="mobile-viewport"><nav class="mobile-reading"></nav><div id="mobile-scroll"><main id="editor"></main></div><nav class="mobile-toolbar"></nav></div>';
  shell = document.querySelector('#mobile-viewport')!;
  pane = document.querySelector('#mobile-scroll')!;
  toolbar = document.querySelector('.mobile-toolbar')!;
  pane.getBoundingClientRect = () => rect(44, 400);
  toolbar.getBoundingClientRect = () => rect(400, 460);
  shell.querySelector<HTMLElement>('.mobile-reading')!.getBoundingClientRect = () => rect(0, 44);
  editor = new Editor({ element: document.querySelector('#editor')!, extensions: [StarterKit], content: '<p>原文</p>' });
  focused = true; caret = { top: 390, bottom: 410 };
  vi.spyOn(editor.view, 'hasFocus').mockImplementation(() => focused);
  vi.spyOn(editor.view, 'coordsAtPos').mockImplementation(() => ({ ...caret, left: 0, right: 0 }));
  window.getSelection()?.removeAllRanges();
  // jsdom has no layout-backed Range geometry.
  Object.defineProperty(Range.prototype, 'getClientRects', { configurable: true, value: () => [] });
});
afterEach(() => { editor.destroy(); vi.unstubAllGlobals(); vi.useRealTimers(); document.body.innerHTML = ''; });

it('uses a clipped flexible pane rather than a fixed overlay and hardcoded bottom reserve', () => {
  const css = readFileSync('src/mobile.css', 'utf8');
  expect(css).toMatch(/#mobile-scroll\s*\{[^}]*min-height: 0;[^}]*overflow: auto/);
  expect(css).toMatch(/\.mobile-toolbar\s*\{ position: relative/);
  expect(css).toContain('scroll-padding-block: 8px');
  expect(css).not.toContain('18px 100px');
  expect(css).toContain('inset: var(--mobile-reading-height, 0px) 0 var(--mobile-toolbar-height, 0px)');
});
it('initially sizes the entire shell and leaves at least 8px above the toolbar', () => {
  const before = editor.getJSON(); attachMobileViewport(editor, toolbar);
  expect(shell.style.height).toBe('460px');
  expect(shell.style.getPropertyValue('--mobile-toolbar-height')).toBe('60px');
  expect(pane.scrollTop).toBe(18);
  expect(editor.getJSON()).toEqual(before);
});
it.each([[390, 270, 20], [840, 450, 0], [640, 310, 48]])('handles keyboard/fold resize width %s height %s offset %s', (width, height, top) => {
  attachMobileViewport(editor, toolbar); pane.scrollTop = 0;
  Object.assign(viewport, { width, height, offsetTop: top });
  viewport.dispatchEvent(new Event('resize')); viewport.dispatchEvent(new Event('scroll')); flush();
  expect(shell.style.height).toBe(`${height}px`); expect(shell.style.width).toBe(`${width}px`);
  expect(shell.style.top).toBe(`${top}px`); expect(pane.scrollTop).toBe(18);
});
it('rechecks continuous edits and newline transactions without changing the document', () => {
  attachMobileViewport(editor, toolbar);
  for (let i = 0; i < 3; i++) {
    pane.scrollTop = 0; caret = { top: 420 + i * 20, bottom: 440 + i * 20 };
    editor.commands.insertContent(i === 1 ? '<p>换行</p>' : '连续输入'); flush();
    expect(pane.scrollTop).toBe(caret.bottom - 400 + 8);
  }
});
it('uses the live DOM caret during IME, and schedules another check on commit', () => {
  const text = editor.view.dom.querySelector('p')!.firstChild!;
  window.getSelection()!.collapse(text, 1);
  vi.spyOn(Range.prototype, 'getClientRects').mockReturnValue([rect(430, 450)] as unknown as DOMRectList);
  const before = editor.getJSON(); attachMobileViewport(editor, toolbar);
  expect(pane.scrollTop).toBe(58);
  pane.scrollTop = 0;
  editor.view.dom.dispatchEvent(new Event('compositionupdate')); flush(); expect(pane.scrollTop).toBe(58);
  pane.scrollTop = 0;
  editor.view.dom.dispatchEvent(new Event('compositionend')); flush(); expect(pane.scrollTop).toBe(58);
  expect(editor.getJSON()).toEqual(before);
});
it('reveals above the top edge too', () => {
  caret = { top: 30, bottom: 50 }; pane.scrollTop = 100;
  attachMobileViewport(editor, toolbar); expect(pane.scrollTop).toBe(78);
});
it('does not steal scrolling from reading mode, dialogs or an unfocused editor', async () => {
  const destroy = attachMobileViewport(editor, toolbar); pane.scrollTop = 0;
  focused = false; window.dispatchEvent(new Event('resize')); flush(); expect(pane.scrollTop).toBe(0);
  focused = true; editor.setEditable(false); toolbar.hidden = true;
  await Promise.resolve(); flush();
  expect(pane.scrollTop).toBe(0); expect(shell.style.getPropertyValue('--mobile-toolbar-height')).toBe('0px');
  editor.setEditable(true); document.body.insertAdjacentHTML('beforeend', '<dialog open><input></dialog>'); flush();
  expect(pane.scrollTop).toBe(0); destroy();
});
it('falls back to current window bounds without visualViewport and cleans up listeners', () => {
  vi.stubGlobal('visualViewport', undefined);
  const destroy = attachMobileViewport(editor, toolbar);
  expect(shell.style.height).toBe(`${window.innerHeight}px`);
  destroy(); pane.scrollTop = 0; window.dispatchEvent(new Event('resize')); flush();
  expect(pane.scrollTop).toBe(0);
});

it('preserves reading position using the document pane and toggles reading without editing content', async () => {
  const { attachReadingControls } = await import('./mobile-reading');
  shell.querySelector('.mobile-reading')!.remove();
  attachReadingControls(editor, toolbar);
  const reading = shell.querySelector<HTMLElement>('.mobile-reading')!;
  reading.getBoundingClientRect = () => rect(0, 44);
  attachMobileViewport(editor, toolbar);
  localStorage.setItem('position:keyboard-test', '123');
  window.donemdBridge.receive({ version: 1, type: 'documentInfo', payload: { source: '# 原文', identity: 'keyboard-test' } });
  vi.advanceTimersByTime(300); expect(pane.scrollTop).toBe(123);
  pane.scrollTop = 180; pane.dispatchEvent(new Event('scroll')); vi.advanceTimersByTime(300);
  expect(localStorage.getItem('position:keyboard-test')).toBe('180');
  const before = editor.getJSON();
  reading.querySelector<HTMLButtonElement>('button')!.click();
  await Promise.resolve(); flush();
  expect(editor.isEditable).toBe(false); expect(toolbar.hidden).toBe(true);
  expect(editor.getJSON()).toEqual(before);
  reading.querySelector<HTMLButtonElement>('button')!.click();
  await Promise.resolve(); flush();
  expect(editor.isEditable).toBe(true); expect(toolbar.hidden).toBe(false);
});

it('reveals the caret inside nested scrolling surfaces before moving the document', () => {
  const paragraph = editor.view.dom.querySelector('p')!;
  paragraph.style.overflowY = 'auto';
  Object.defineProperties(paragraph, { scrollHeight: { value: 600 }, clientHeight: { value: 200 } });
  paragraph.getBoundingClientRect = () => rect(100, 300);
  window.getSelection()!.collapse(paragraph.firstChild!, 1);
  vi.spyOn(Range.prototype, 'getClientRects').mockReturnValue([rect(430, 450)] as unknown as DOMRectList);
  attachMobileViewport(editor, toolbar);
  expect(paragraph.scrollTop).toBe(158);
  expect(pane.scrollTop).toBe(0);
});
