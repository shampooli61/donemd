import { attachMobileViewport } from './mobile-viewport';
import { MobileReadOnlyGuard } from './mobile-readonly';
import { loadMobileDocument } from './mobile-document-session';
import type { JSONContent } from '@tiptap/core';
import { HeadingFold, applyFoldState, headingFoldKey } from './heading-fold';
import { attachReadingControls } from './mobile-reading';
import { NodeSelection } from '@tiptap/pm/state';
import { commitRichNode } from './mobile-rich';
import { button, field, panel } from './mobile-controls';
import { Editor } from '@tiptap/core';
import StarterKit from '@tiptap/starter-kit';
import Link from '@tiptap/extension-link';
import { MobileTable } from './mobile-table';
import TableRow from '@tiptap/extension-table-row';
import TableCell from '@tiptap/extension-table-cell';
import TableHeader from '@tiptap/extension-table-header';
import TaskList from '@tiptap/extension-task-list';
import TaskItem from '@tiptap/extension-task-item';
import { DonemdImage } from './image-node';
import { DonemdVideo } from './video-node';
import { MermaidCodeBlock } from './mermaid-codeblock';
import { MathInline } from './math-inline';
import { MathBlock } from './math-block';
import { RawMarkdownBlock } from './raw-markdown-block';
import { FeishuPlaceholderBlock } from './feishu-placeholder-block';
import { Callout } from './callout';
import { on, send } from './bridge';
import { attachRichControls } from './mobile-rich-controls';
import { attachWritingControls } from './mobile-controls';
import './visual.css';
import './mobile.css';

let revision = 0;
const editor = new Editor({
  element: document.querySelector('#editor') as HTMLElement,
  extensions: [MobileReadOnlyGuard, StarterKit.configure({ codeBlock: false }), Link.configure({ openOnClick: false }),
    MobileTable.configure({ resizable: false }), TableRow, TableCell, TableHeader, TaskList,
    TaskItem.configure({ nested: true }), DonemdImage, DonemdVideo, MermaidCodeBlock,
    MathInline, MathBlock, RawMarkdownBlock, FeishuPlaceholderBlock, Callout,
    HeadingFold.configure({ onToggle: (index, collapse) => {
      const folded = new Set(headingFoldKey.getState(editor.state)?.collapsed ?? []);
      if (collapse) folded.add(index); else folded.delete(index);
      applyFoldState(editor.view, [...folded]);
    } })],
  editorProps: { attributes: { 'aria-label': '文档正文', role: 'textbox', 'aria-multiline': 'true' } },
  onUpdate: ({ editor }) => { if (!editor.view.composing) send('documentChanged', { body: editor.getJSON(), revision }); },
});
// A composition commit may arrive after the final update; never reload during IME input.
editor.view.dom.addEventListener('compositionstart', () => send('compositionState', true));
editor.view.dom.addEventListener('compositionend', () => setTimeout(() => {
  send('compositionState', false);
  send('documentChanged', { body: editor.getJSON(), revision });
}, 0));
on('loadDocument', payload => {
  const next = payload as { document: JSONContent; revision: number };
  loadMobileDocument(editor, next.document); revision = next.revision;
});
declare global { interface Window { donemdMobileSnapshot: () => { body: JSONContent; revision: number; composing: boolean } } }
window.donemdMobileSnapshot = () => ({ body: editor.getJSON(), revision, composing: editor.view.composing });
on('setEditable', payload => editor.setEditable(Boolean(payload)));
on('flush', () => send('documentChanged', { body: editor.getJSON(), revision }));
const toolbar = attachWritingControls(editor, index => {
  const folded = new Set(headingFoldKey.getState(editor.state)?.collapsed ?? []); folded.delete(index); applyFoldState(editor.view, [...folded]);
});
attachRichControls(editor, toolbar);


on('insertImage', payload => {
  const src = (payload as { src: string }).src;
  const selected = editor.state.selection;
  if (selected instanceof NodeSelection && selected.node.type.name === 'image') editor.commands.updateAttributes('image', { src });
  else commitRichNode(editor, { type: 'image', attrs: { src } });
});
on('insertVideo', payload => {
  const src = (payload as { src: string }).src;
  const selected = editor.state.selection;
  if (selected instanceof NodeSelection && selected.node.type.name === 'video') editor.commands.updateAttributes('video', { src });
  else commitRichNode(editor, { type: 'video', attrs: { src } });
});
toolbar.append(button('附件', () => {
  const selected = editor.state.selection;
  const { dialog, close } = panel('附件操作');
  if (!(selected instanceof NodeSelection) || !['image', 'video'].includes(selected.node.type.name)) {
    dialog.append(document.createTextNode('从顶部文档菜单插入图片或视频；点选正文附件后，可修改或删除。')); return;
  }
  const position = selected.from, node = selected.node;
  dialog.append(button('预览', () => { send('previewImage', { src: node.attrs.src }); close(); }),
    button('删除此引用', () => { editor.chain().focus().deleteSelection().run(); close(); }));
  if (node.type.name === 'image') {
    const description = field('图片描述', node.attrs.alt ?? '');
    dialog.append(description, button('保存描述', () => {
      editor.view.dispatch(editor.state.tr.setNodeMarkup(position, undefined, { ...node.attrs, alt: description.value })); close();
    }));
  }
  dialog.append(document.createTextNode('替换：保持选中，从顶部菜单重新插入同类附件。磁盘上的旧附件会保留。'));
}));
// A missing iCloud attachment is recoverable; don't silently render an empty box.
editor.view.dom.addEventListener('error', event => {
  if (event.target instanceof HTMLImageElement || event.target instanceof HTMLVideoElement) {
    const element = event.target;
    if (element.nextElementSibling?.classList.contains('mobile-retry')) return;
    const retry = button('附件未就绪，下载后重试', () => { const src = element.getAttribute('src'); if (src) element.setAttribute('src', src); retry.remove(); });
    retry.className = 'mobile-retry'; element.after(retry);
  }
}, true);

attachReadingControls(editor, toolbar);
attachMobileViewport(editor, toolbar);

send('editorReady');
