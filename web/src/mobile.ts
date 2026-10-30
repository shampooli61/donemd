import { createNativeCommands } from './mobile-native-commands';
import { createSnapshotProtection } from './mobile-snapshot-protection';
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
let identity = '';
let snapshotSequence = 0;
const snapshot = (current: Editor) => ({ body: current.getJSON(), identity, revision, composing: current.view.composing, sequence: ++snapshotSequence });
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
  onUpdate: ({ editor }) => { if (!editor.view.composing) send('documentChanged', snapshot(editor)); },
});
window.donemdMobileProtection = createSnapshotProtection(editor, () => revision, value => { revision = value; }, () => ++snapshotSequence);
const nativeCommands = createNativeCommands(editor, {
  revision: () => revision, locked: () => window.donemdMobileProtection.isLocked(),
  publish: state => send('editorState', state), result: result => send('editorCommandResult', result),
  preview: src => send('previewImage', { src }),
});
on('editorCommand', payload => { void nativeCommands.receive(payload); });
// A composition commit may arrive after the final update; never reload during IME input.
editor.view.dom.addEventListener('compositionstart', () => send('compositionState', true));
editor.view.dom.addEventListener('compositionend', () => setTimeout(() => {
  send('compositionState', false);
  send('documentChanged', snapshot(editor));
}, 0));
on('loadDocument', payload => {
  if (window.donemdMobileProtection.isLocked()) return; // A queued ordinary load cannot bypass the replacement lock.
  const next = payload as { document: JSONContent; revision: number };
  loadMobileDocument(editor, next.document); revision = next.revision; nativeCommands.publish();
});
declare global { interface Window { donemdMobileSnapshot: () => { body: JSONContent; revision: number; composing: boolean } } }
window.donemdMobileSnapshot = () => snapshot(editor);
on('setEditable', payload => { if (!window.donemdMobileProtection.isLocked() && !editor.view.composing) nativeCommands.mode(Boolean(payload)); });
on('flush', () => send('documentChanged', snapshot(editor)));
const toolbar = attachWritingControls(editor, index => {
  const folded = new Set(headingFoldKey.getState(editor.state)?.collapsed ?? []); folded.delete(index); applyFoldState(editor.view, [...folded]);
}, nativeCommands.search);
attachRichControls(editor, toolbar);


on('insertImage', payload => {
  if (document.body.classList.contains('native-controls') || window.donemdMobileProtection.isLocked() || editor.view.composing || !editor.isEditable) return;
  const src = (payload as { src: string }).src;
  const selected = editor.state.selection;
  if (selected instanceof NodeSelection && selected.node.type.name === 'image') editor.commands.updateAttributes('image', { src });
  else commitRichNode(editor, { type: 'image', attrs: { src } });
});
on('insertVideo', payload => {
  if (document.body.classList.contains('native-controls') || window.donemdMobileProtection.isLocked() || editor.view.composing || !editor.isEditable) return;
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

// bridge.on has one handler per message type. Reading controls own documentInfo;
// derive BOTH snapshot and command identities from that one accepted callback.
attachReadingControls(editor, toolbar, info => {
  identity = info.identity;
  nativeCommands.info(info);
});
attachMobileViewport(editor, toolbar);

send('editorReady');
