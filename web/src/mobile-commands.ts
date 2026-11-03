import type { Editor } from '@tiptap/core';
import { closeHistory } from '@tiptap/pm/history';
import { findMatches } from './document-search';

export function replaceMatches(editor: Editor, query: string, replacement: string, all: boolean): number {
  if (!editor.isEditable) return 0;
  const hits = findMatches(editor.state.doc, query);
  const selected = all ? hits : hits.slice(0, 1);
  if (!selected.length) return 0;
  const tr = closeHistory(editor.state.tr);
  for (const hit of [...selected].reverse()) {
    if (replacement) tr.insertText(replacement, hit.from, hit.to);
    else tr.delete(hit.from, hit.to);
  }
  editor.view.dispatch(tr);
  editor.view.dispatch(closeHistory(editor.state.tr));
  return selected.length;
}

export function changeBlock(editor: Editor, action: 'up' | 'down' | 'copy' | 'delete'): boolean {
  if (!editor.isEditable) return false;
  const { state } = editor;
  const blocks: { pos: number; node: typeof state.doc }[] = [];
  state.doc.forEach((node, pos) => blocks.push({ node, pos }));
  const index = blocks.findIndex(({ pos, node }) => state.selection.from >= pos && state.selection.from < pos + node.nodeSize);
  if (index < 0) return false;
  const { node, pos } = blocks[index];
  const tr = closeHistory(state.tr);
  if (action === 'delete') tr.delete(pos, pos + node.nodeSize);
  if (action === 'copy') tr.insert(pos + node.nodeSize, node);
  if (action === 'up') {
    if (!index) return false;
    tr.delete(pos, pos + node.nodeSize).insert(blocks[index - 1].pos, node);
  }
  if (action === 'down') {
    if (index === blocks.length - 1) return false;
    const next = blocks[index + 1];
    tr.delete(pos, pos + node.nodeSize).insert(pos + next.node.nodeSize, node);
  }
  editor.view.dispatch(tr);
  editor.view.dispatch(closeHistory(editor.state.tr));
  return true;
}
