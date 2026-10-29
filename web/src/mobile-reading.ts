import type { Editor } from '@tiptap/core';
import { EditorState } from '@codemirror/state';
import { EditorView } from '@codemirror/view';
import { markdown } from '@codemirror/lang-markdown';
import { button, panel } from './mobile-controls';
import { applyFoldState, headingFoldKey } from './heading-fold';
import { on, send } from './bridge';

export function attachReadingControls(editor: Editor, toolbar: HTMLElement) {
  const scroller = document.querySelector('#mobile-scroll') as HTMLElement;
  let source = '', sourceView: EditorView | undefined, identity = '';
  on('documentInfo', payload => {
    const info = payload as { source: string; identity: string };
    source = info.source;
    if (sourceView) sourceView.dispatch({ changes: { from: 0, to: sourceView.state.doc.length, insert: source } });
    if (identity !== info.identity) {
      identity = info.identity;
      const previous = Number(localStorage.getItem('position:' + identity) ?? 0);
      setTimeout(() => scroller.scrollTop = previous, 250);
    }
  });
  let timer: ReturnType<typeof setTimeout>;
  scroller.addEventListener('scroll', () => { clearTimeout(timer); timer = setTimeout(() => { if (identity) localStorage.setItem('position:' + identity, String(scroller.scrollTop)); }, 250); });
  const bar = document.createElement('nav'); bar.className = 'mobile-reading'; bar.setAttribute('aria-label', '阅读与导航');
  let reading = false;
  const mode = button('阅读', () => {
    reading = !reading; editor.setEditable(!reading); toolbar.hidden = reading;
    send('editingMode', { editable: !reading });
    document.body.classList.toggle('reading-mode', reading); mode.textContent = reading ? '编辑' : '阅读'; mode.setAttribute('aria-label', mode.textContent);
    if (reading) editor.commands.blur();
  });
  bar.append(mode, button('源码', () => {
    const { dialog, close } = panel('Markdown 源码 · 只读');
    const host = document.createElement('div'); dialog.append(host);
    sourceView = new EditorView({ parent: host, state: EditorState.create({ doc: source, extensions: [markdown(), EditorState.readOnly.of(true), EditorView.editable.of(false), EditorView.lineWrapping] }) });
    const observer = new MutationObserver(() => { if (!dialog.isConnected) { sourceView?.destroy(); sourceView = undefined; observer.disconnect(); } });
    observer.observe(document.body, { childList: true });
    dialog.append(button('复制源码', () => { void navigator.clipboard.writeText(source).catch(() => { const p = document.createElement('p'); p.textContent = '请长按源码选中复制'; dialog.append(p); }); }));
    void close;
  }), button('大纲', () => {
    const { dialog, close } = panel('文档大纲');
    let ordinal = 0;
    editor.state.doc.forEach((node, pos) => {
      if (node.type.name !== 'heading') return;
      const index = ordinal++;
      const row = document.createElement('div');
      row.style.paddingLeft = `${(node.attrs.level - 1) * 12}px`;
      row.append(button(node.textContent || '空标题', () => {
        applyFoldState(editor.view, []); close();
        (editor.view.nodeDOM(pos) as HTMLElement)?.scrollIntoView({ block: 'start' });
      }), button('折叠 / 展开', () => {
        const folded = new Set(headingFoldKey.getState(editor.state)?.collapsed ?? []);
        if (folded.has(index)) folded.delete(index); else folded.add(index);
        applyFoldState(editor.view, [...folded]);
      }));
      dialog.append(row);
    });
    if (!ordinal) dialog.append(document.createTextNode('文档还没有标题'));
  }), button('阅读设置', () => {
    const { dialog } = panel('阅读设置与统计');
    const text = editor.state.doc.textContent;
    const info = document.createElement('p'); info.textContent = `正文字符（不含空白）：${Array.from(text.replace(/\s/g, '')).length} · 源码 UTF-8：${new TextEncoder().encode(source).length} 字节`;
    dialog.append(info);
    for (const [label, theme] of [['跟随系统', ''], ['纸质', 'paper'], ['赛博夜色', 'night']]) dialog.append(button(label, () => {
      document.documentElement.dataset.theme = theme; localStorage.setItem('mobile-theme', theme);
    }));
    for (const size of [15, 17, 19, 22, 26]) dialog.append(button(`${size} 号字`, () => {
      editor.view.dom.style.fontSize = `${size}px`; localStorage.setItem('mobile-font', String(size));
    }));
  }));
  document.querySelector('#mobile-viewport')!.prepend(bar);
  document.documentElement.dataset.theme = localStorage.getItem('mobile-theme') ?? '';
  editor.view.dom.style.fontSize = `${Number(localStorage.getItem('mobile-font') ?? 17)}px`;
}
