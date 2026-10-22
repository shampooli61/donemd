import type { Editor } from '@tiptap/core';
import { NodeSelection } from '@tiptap/pm/state';
import mermaid from 'mermaid';
import { renderMath } from './katex-render';
import { commitRichNode } from './mobile-rich';
import { button, field, panel } from './mobile-controls';
import 'katex/dist/katex.min.css';

export function attachRichControls(editor: Editor, toolbar: HTMLElement) {
  function editSource(type: string, position?: number) {
    if (!editor.isEditable) return;
    const old = position === undefined ? undefined : editor.state.doc.nodeAt(position);
    const { dialog, close } = panel(type === 'codeBlock' ? '代码 / Mermaid' : type === 'raw_markdown_block' ? '编辑原文' : '编辑公式');
    const input = field('内容源码', old?.textContent || old?.attrs.latex || old?.attrs.raw || '', true);
    const language = field('代码语言（图表填 mermaid）', old?.attrs.language ?? '');
    if (type === 'codeBlock') dialog.append(language);
    const preview = document.createElement('div'); preview.className = 'mobile-preview';
    let generation = 0;
    const render = async () => {
      const token = ++generation;
      if (type.startsWith('math_')) { preview.innerHTML = renderMath(input.value, type === 'math_block').html; return; }
      if (type === 'codeBlock' && language.value === 'mermaid') {
        try {
          const result = await mermaid.render(`mobile-${Date.now()}-${token}`, input.value);
          if (token === generation && dialog.isConnected) preview.innerHTML = result.svg;
        } catch { if (token === generation) preview.textContent = '图表语法有误；可继续修改，原文会保留。'; }
      } else preview.textContent = input.value;
    };
    let timer: ReturnType<typeof setTimeout>;
    input.addEventListener('input', () => { clearTimeout(timer); timer = setTimeout(() => void render(), 300); });
    language.addEventListener('input', () => void render());
    dialog.append(input, button('保存内容', () => {
      const content = type === 'codeBlock'
        ? { type, attrs: { language: language.value }, content: input.value ? [{ type: 'text', text: input.value }] : [] }
        : { type, attrs: type === 'raw_markdown_block' ? { raw: input.value } : { latex: input.value } };
      if (commitRichNode(editor, content, position)) close();
    }), preview);
    void render(); input.focus();
  }
  toolbar.append(button('插入', () => {
    const { dialog, close } = panel('插入内容');
    for (const [label, type] of [['独立公式', 'math_block'], ['行内公式', 'math_inline'], ['代码 / 图表', 'codeBlock'], ['原文块', 'raw_markdown_block']]) {
      dialog.append(button(label, () => { close(); editSource(type); }));
    }
    dialog.append(button('表格', () => {
      close(); const table = panel('插入表格');
      const rows = field('行数', '3') as HTMLInputElement, columns = field('列数', '3') as HTMLInputElement;
      rows.type = columns.type = 'number'; rows.min = columns.min = '1'; rows.max = '100'; columns.max = '20';
      table.dialog.append(rows, columns, button('创建表格', () => {
        const r = Math.max(1, Math.min(100, Number(rows.value) || 3));
        const c = Math.max(1, Math.min(20, Number(columns.value) || 3));
        editor.chain().focus().insertTable({ rows: Math.floor(r), cols: Math.floor(c), withHeaderRow: true }).run(); table.close();
      }));
    }));
  }), button('编辑块', () => {
    const selection = editor.state.selection;
    const selected = selection instanceof NodeSelection ? { node: selection.node, pos: selection.from } : undefined;
    let target = selected;
    if (!target) {
      for (let d = selection.$from.depth; d > 0; d--) {
        const node = selection.$from.node(d);
        if (node.type.name === 'codeBlock') { target = { node, pos: selection.$from.before(d) }; break; }
      }
    }
    if (target && ['math_block', 'math_inline', 'codeBlock', 'raw_markdown_block'].includes(target.node.type.name)) {
      editSource(target.node.type.name, target.pos); return;
    }
    const { dialog, close } = panel('表格操作');
    if (!editor.isActive('table')) { dialog.append(document.createTextNode('先点选公式、代码、原文块，或将光标放入表格。')); return; }
    const actions: [string, () => void][] = [
      ['前插一行', () => editor.chain().focus().addRowBefore().run()], ['后插一行', () => editor.chain().focus().addRowAfter().run()],
      ['前插一列', () => editor.chain().focus().addColumnBefore().run()], ['后插一列', () => editor.chain().focus().addColumnAfter().run()],
      ['删除当前行', () => editor.chain().focus().deleteRow().run()], ['删除当前列', () => editor.chain().focus().deleteColumn().run()],
      ['删除表格', () => editor.chain().focus().deleteTable().run()],
    ];
    for (const [label, action] of actions) dialog.append(button(label, () => { close(); action(); }));
  }));
}
