// @vitest-environment jsdom
import { afterAll, beforeAll, describe, expect, it, vi } from 'vitest';
import { EditorView } from '@codemirror/view';
import { foldEffect } from '@codemirror/language';
const bridge = vi.hoisted(() => ({ handlers: new Map<string, (payload: unknown) => void>(), send: vi.fn() }));
vi.mock('./bridge', () => ({ on: (name: string, handler: (payload: unknown) => void) => bridge.handlers.set(name, handler), send: bridge.send }));
let view: EditorView;
const receive = (name: string, payload: unknown) => bridge.handlers.get(name)!(payload);
const config = (theme: string, sequence: number, extra = {}) => receive('configureMobileSource', { identity: 'note', revision: 3, fontScale: 1, theme, sequence, ...extra });
const source = (text: string, sequence: number, extra = {}) => receive('setMarkdownSource', { identity: 'note', revision: 3, text, sequence, ...extra });

beforeAll(async () => {
  document.body.innerHTML = '<div id="source"></div>';
  vi.stubGlobal('ResizeObserver', class { observe() {} unobserve() {} disconnect() {} });
  Object.defineProperty(Range.prototype, 'getClientRects', { configurable: true, value: () => [] });
  Object.defineProperty(Range.prototype, 'getBoundingClientRect', { configurable: true, value: () => new DOMRect() });
  await import('./markdown-source');
  view = EditorView.findFromDOM(document.querySelector('.cm-editor')!)!;
});
afterAll(() => { view?.destroy(); vi.restoreAllMocks(); vi.unstubAllGlobals(); });

describe('shared CodeMirror mobile bridge', () => {
  it('preserves Mac string compatibility until mobile configuration', () => {
    receive('setMarkdownSource', '# Mac\n\nbody');
    expect(view.state.doc.toString()).toBe('# Mac\n\nbody');
  });
  it('ACKs normalized three-theme configuration without changing accepted source', () => {
    config('paper', 1); source('# Title\n\ncopy text', 1);
    const text = view.state.doc.toString();
    for (const [theme, sequence] of [['night', 2], ['', 3]] as const) {
      config(theme, sequence);
      expect(bridge.send).toHaveBeenLastCalledWith('mobileSourceConfigured', expect.objectContaining({ identity: 'note', revision: 3, sequence, success: true, theme: theme || 'system' }));
      expect(view.state.doc.toString()).toBe(text);
    }
    expect(document.documentElement.hasAttribute('data-theme')).toBe(false);
    expect(view.contentDOM.getAttribute('contenteditable')).toBe('false');
  });
  it('rejects stale source identity, revision and sequence with negative ACK', () => {
    const text = view.state.doc.toString();
    for (const extra of [{ identity: 'old' }, { revision: 2 }, { sequence: 1 }]) {
      source('bad', 2, extra);
      expect(bridge.send).toHaveBeenLastCalledWith('markdownSourceApplied', expect.objectContaining({ success: false }));
      expect(view.state.doc.toString()).toBe(text);
    }
  });
  it('maps copy selection and retains independent scroll for minimal changes', () => {
    view.dispatch({ selection: { anchor: 9, head: 13 } });
    view.scrollDOM.scrollTop = 42;
    source('# Title!\n\ncopy text', 2);
    expect(view.state.sliceDoc(view.state.selection.main.from, view.state.selection.main.to)).toBe('copy');
    expect(view.scrollDOM.scrollTop).toBe(42);
    expect(bridge.send).toHaveBeenLastCalledWith('markdownSourceApplied', expect.objectContaining({ sequence: 2, success: true }));
  });
  it('tags user fold events with the actual accepted source sequence', () => {
    view.dispatch({ effects: foldEffect.of({ from: view.state.doc.line(1).to, to: view.state.doc.length }) });
    expect(bridge.send).toHaveBeenLastCalledWith('foldToggled', { ordinal: 0, collapse: true, identity: 'note', revision: 3, sequence: 2 });
  });
  it('rejects invalid or out-of-order config without changing theme/font/content', () => {
    const text = view.state.doc.toString();
    config('paper', 2);
    expect(bridge.send).toHaveBeenLastCalledWith('mobileSourceConfigured', expect.objectContaining({ success: false }));
    config('invalid', 4);
    config('paper', 5, { fontScale: -1 });
    expect(document.documentElement.hasAttribute('data-theme')).toBe(false);
    expect(document.documentElement.style.getPropertyValue('--mobile-source-font-size')).toBe('15px');
    expect(view.state.doc.toString()).toBe(text);
  });
});
