import { Editor } from '@tiptap/core';
import StarterKit from '@tiptap/starter-kit';
import Link from '@tiptap/extension-link';
import Table from '@tiptap/extension-table';
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
import './visual.css';
import './mobile.css';

const editor = new Editor({
  element: document.querySelector('#editor') as HTMLElement,
  extensions: [StarterKit.configure({ codeBlock: false }), Link.configure({ openOnClick: false }),
    Table.configure({ resizable: false }), TableRow, TableCell, TableHeader, TaskList,
    TaskItem.configure({ nested: true }), DonemdImage, DonemdVideo, MermaidCodeBlock,
    MathInline, MathBlock, RawMarkdownBlock, FeishuPlaceholderBlock, Callout],
  editorProps: { attributes: { 'aria-label': '文档正文', role: 'textbox', 'aria-multiline': 'true' } },
  onUpdate: ({ editor }) => { if (!editor.view.composing) send('documentChanged', editor.getJSON()); },
});
// A composition commit may arrive after the final update; never reload during IME input.
editor.view.dom.addEventListener('compositionend', () => setTimeout(() => send('documentChanged', editor.getJSON()), 0));
on('loadDocument', payload => editor.commands.setContent(payload as object, false));
on('setEditable', payload => editor.setEditable(Boolean(payload)));
on('flush', () => send('documentChanged', editor.getJSON()));
send('editorReady');
