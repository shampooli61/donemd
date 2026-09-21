import type { Editor } from '@tiptap/core';
import type { Node as PMNode } from '@tiptap/pm/model';
import { Plugin, PluginKey, TextSelection } from '@tiptap/pm/state';
import { Decoration, DecorationSet } from '@tiptap/pm/view';
import { computeFoldRanges, headingFoldKey } from './heading-fold';

export interface SearchMatch { from: number; to: number }
export function findMatches(doc: PMNode, query: string): SearchMatch[] {
  if (!query) return [];
  const hits: SearchMatch[] = [];
  // Literal Unicode-insensitive matching preserves original UTF-16 offsets;
  // lowercasing a whole string could change its length (for example İ).
  const escaped = query.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  const pattern = new RegExp(escaped, 'giu');
  doc.descendants((node, pos) => {
    if (!node.isTextblock) return true;
    const text = node.textBetween(0, node.content.size, '', '\uFFFC');
    for (const match of text.matchAll(pattern)) {
      hits.push({ from: pos + 1 + match.index!, to: pos + 1 + match.index! + match[0].length });
    }
    return false;
  });
  return hits;
}

export function createDocumentSearch(editor: Editor, unfold: (ordinal: number) => void) {
  const key = new PluginKey('documentSearch');
  let query = '', current = 0, opened = false;
  const bar = document.createElement('div');
  bar.className = 'donemd-find'; bar.hidden = true;
  bar.setAttribute('role', 'search'); bar.setAttribute('aria-label', '文档内查找');
  const input = document.createElement('input');
  input.type = 'search'; input.placeholder = '查找文档'; input.setAttribute('aria-label', '查找文档');
  const count = document.createElement('span'); count.setAttribute('role', 'status'); count.setAttribute('aria-live', 'polite');
  const button = (label: string, action: () => void) => {
    const b = document.createElement('button'); b.type = 'button'; b.textContent = label;
    b.setAttribute('aria-label', label); b.addEventListener('click', action); return b;
  };
  const previous = button('上一处', () => navigate(-1));
  const next = button('下一处', () => navigate(1));
  bar.append(input, count, previous, next, button('关闭查找', close)); document.body.append(bar);
  const hits = () => opened ? findMatches(editor.state.doc, query) : [];
  const refreshCount = () => {
    const matches = hits(); current = Math.min(current, Math.max(0, matches.length - 1));
    count.textContent = matches.length ? `${current + 1} / ${matches.length}` : (query ? '无匹配' : '输入查找内容');
    previous.disabled = next.disabled = !matches.length;
  };
  editor.registerPlugin(new Plugin({
    key,
    props: { decorations(state) {
      return DecorationSet.create(state.doc, hits().map((hit, i) => Decoration.inline(hit.from, hit.to, {
        class: i === current ? 'donemd-find-match is-current' : 'donemd-find-match',
      })));
    } },
  }));
  function repaint() {
    editor.view.dispatch(editor.state.tr.setMeta(key, true).setMeta('addToHistory', false)); refreshCount();
  }
  function navigate(delta: number) {
    const matches = hits(); if (!matches.length) { repaint(); return; }
    current = (current + delta + matches.length) % matches.length;
    const match = matches[current];
    const blocks: { isHeading: boolean; level: number; pos: number; size: number }[] = [];
    editor.state.doc.forEach((node, pos) => blocks.push({ isHeading: node.type.name === 'heading', level: node.attrs.level ?? 0, pos, size: node.nodeSize }));
    const collapsed = headingFoldKey.getState(editor.state)?.collapsed;
    for (const range of computeFoldRanges(blocks)) {
      const start = blocks[range.startBlock]?.pos ?? Infinity;
      const end = blocks[range.endBlock]?.pos ?? editor.state.doc.content.size;
      if (collapsed?.has(range.ordinal) && match.from >= start && match.from < end) unfold(range.ordinal);
    }
    editor.view.dispatch(editor.state.tr.setSelection(TextSelection.create(editor.state.doc, match.from, match.to)).setMeta('addToHistory', false));
    repaint();
    requestAnimationFrame(() => {
      if (editor.isDestroyed || !opened) return;
      const dom = editor.view.domAtPos(match.from).node;
      (dom instanceof HTMLElement ? dom : dom.parentElement)?.scrollIntoView?.({ block: 'center' });
    });
  }
  function open() { opened = true; bar.hidden = false; repaint(); input.focus(); input.select(); }
  function close() { opened = false; bar.hidden = true; repaint(); editor.commands.focus(); }
  input.addEventListener('input', () => { query = input.value; current = 0; navigate(0); });
  bar.addEventListener('keydown', (e) => {
    if (e.key === 'Escape') { e.preventDefault(); e.stopPropagation(); close(); }
    if (e.key === 'Enter') { e.preventDefault(); navigate(e.shiftKey ? -1 : 1); }
  });
  function keydown(e: KeyboardEvent) {
    if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === 'f') { e.preventDefault(); open(); }
  }
  window.addEventListener('keydown', keydown);
  editor.on('update', refreshCount);
  return { open, close, destroy() { window.removeEventListener('keydown', keydown); editor.off('update', refreshCount); editor.unregisterPlugin(key); bar.remove(); } };
}
