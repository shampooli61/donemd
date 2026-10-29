import { renderNativePreview } from './mobile-native-preview';
import type { Editor, JSONContent } from '@tiptap/core';
import type { Node as PMNode } from '@tiptap/pm/model';
import { NodeSelection, TextSelection, Plugin, PluginKey, type SelectionBookmark } from '@tiptap/pm/state';
import { applyFoldState, headingFoldKey } from './heading-fold';
import { changeBlock, replaceMatches } from './mobile-commands';
import { commitRichNode } from './mobile-rich';
import { createDocumentSearch } from './document-search';

export interface NativeEditorCommand {
  requestId: string; identity: string; revision: number; name: string;
  args: Record<string, string>; selectionToken?: string;
}
export interface NativeEditorState {
  identity: string; revision: number; ready: boolean; editable: boolean; locked: boolean;
  composing: boolean; focused: boolean; canUndo: boolean; canRedo: boolean;
  block: string; marks: string[]; mixedMarks: string[]; nodeType: string;
  attributes: Record<string, string>; selectionToken?: string;
  headings: { id: number; title: string; level: number; collapsed: boolean }[];
  searchQuery: string; searchCount: number; searchCurrent: number; searchActive: boolean;
  theme: string; fontSize: number; characters: number; sourceBytes: number;
}
export interface NativeEditorResult {
  requestId: string; success: boolean; message?: string; selectionToken?: string;
  data?: Record<string, string>; state?: NativeEditorState;
}
interface Target { pos: number; node: PMNode }
interface SavedSelection { bookmark: SelectionBookmark; target?: Target; valid: boolean }
interface Options {
  revision: () => number; locked: () => boolean;
  publish: (state: NativeEditorState) => void;
  result: (result: NativeEditorResult) => void;
  preview: (src: string) => void;
}
const richTypes = new Set(['codeBlock', 'raw_markdown_block', 'math_block', 'math_inline', 'image', 'video', 'table']);
const readCommands = new Set(['preview.render', 'native.activate', 'selection.capture', 'selection.release', 'keyboard.dismiss', 'focus.restore',
  'mode.set', 'search.set', 'search.next', 'search.previous', 'search.close', 'source.get',
  'outline.jump', 'outline.toggle', 'reader.set', 'reader.info', 'context.preview', 'table.fullscreen']);
const commandNames = new Set([...readCommands, 'history.undo', 'history.redo',
  ...['paragraph', 'heading', 'bold', 'italic', 'strike', 'code', 'clear', 'bullet', 'ordered', 'task', 'indent', 'outdent', 'quote', 'callout', 'link'].map(x => `format.${x}`),
  ...['rule', 'table', 'image', 'video', 'math', 'code', 'raw'].map(x => `insert.${x}`),
  'context.edit', 'context.deleteReference', ...['rowBefore', 'rowAfter', 'columnBefore', 'columnAfter', 'deleteRow', 'deleteColumn', 'delete'].map(x => `table.${x}`),
  ...['up', 'down', 'copy', 'delete'].map(x => `block.${x}`), 'search.replace']);

/** Single typed, whitelisted command surface. Bookmarks belong to a document generation,
 * not a numeric offset supplied by native. No command reloads or serializes Markdown. */
export function createNativeCommands(editor: Editor, options: Options) {
  let identity = '', generation = 0, sequence = 0, active = false, sourceBytes = 0;
  let liveToken: string | undefined, publishing = false, lastPublished = '', queued = Promise.resolve();
  const bookmarks = new Map<string, SavedSelection>();
  const search = createDocumentSearch(editor, ordinal => {
    const folded = new Set(headingFoldKey.getState(editor.state)?.collapsed ?? []);
    folded.delete(ordinal); applyFoldState(editor.view, [...folded]);
  });
  function target(): Target | undefined {
    const selection = editor.state.selection;
    if (selection instanceof NodeSelection && richTypes.has(selection.node.type.name)) return { pos: selection.from, node: selection.node };
    for (let d = selection.$from.depth; d > 0; d--) {
      const node = selection.$from.node(d);
      if (richTypes.has(node.type.name)) return { pos: selection.$from.before(d), node };
    }
  }
  function capture(): string {
    const token = `${generation}:${++sequence}`;
    if (bookmarks.size >= 512) bookmarks.delete(bookmarks.keys().next().value!);
    bookmarks.set(token, { bookmark: editor.state.selection.getBookmark(), target: target(), valid: true });
    return token;
  }
  function reset() {
    generation++; bookmarks.clear(); liveToken = undefined;
    // Old search offsets/highlights must not leak into replacement content.
    search.close(false); publish();
  }
  editor.view.dom.addEventListener('mobile-document-loaded', reset);
  editor.registerPlugin(new Plugin({
    key: new PluginKey('mobileNativeBookmarks'),
    state: { init: () => null, apply(tr) {
      if (!tr.docChanged) return null;
      for (const saved of bookmarks.values()) {
        if (!saved.valid) continue;
        const old = saved.bookmark.resolve(tr.before);
        const from = tr.mapping.mapResult(old.from, 1), to = tr.mapping.mapResult(old.to, -1);
        if (from.deleted && to.deleted) saved.valid = false;
        saved.bookmark = saved.bookmark.map(tr.mapping);
        if (saved.target) {
          const mapped = tr.mapping.mapResult(saved.target.pos, 1);
          const node = tr.doc.nodeAt(mapped.pos);
          if (mapped.deleted || !node || node.type !== saved.target.node.type) saved.valid = false;
          else saved.target = { pos: mapped.pos, node };
        }
      }
      return null;
    } },
  }));
  function state(): NativeEditorState {
    if (!liveToken || !bookmarks.get(liveToken)?.valid) { if (liveToken) bookmarks.delete(liveToken); liveToken = capture(); }
    const selected = target(), attributes: Record<string, string> = {};
    if (selected) {
      for (const [key, value] of Object.entries(selected.node.attrs)) if (value != null) attributes[key] = String(value);
      if (selected.node.type.name === 'codeBlock') attributes.text = selected.node.textContent;
      if (selected.node.type.name === 'raw_markdown_block') attributes.text = selected.node.attrs.raw ?? '';
      if (selected.node.type.name.startsWith('math_')) { attributes.text = selected.node.attrs.latex ?? ''; attributes.display = String(selected.node.type.name === 'math_block'); }
    }
    const href = editor.getAttributes('link').href;
    const topIndex = editor.state.selection.$from.depth ? editor.state.selection.$from.index(0) : editor.state.selection.$from.index();
    attributes.canMoveUp = String(topIndex > 0);
    attributes.canMoveDown = String(topIndex < editor.state.doc.childCount - 1);
    attributes.canCopy = attributes.canDelete = String(!editor.isEmpty);
    attributes.canHeading = String(!editor.isActive('tableCell') && !editor.isActive('tableHeader'));
    if (href) attributes.href = String(href);
    const names = ['bold', 'italic', 'strike', 'code', 'link'];
    const marks = names.filter(name => editor.isActive(name));
    const encountered = new Set<string>();
    editor.state.doc.nodesBetween(editor.state.selection.from, editor.state.selection.to, node => { for (const mark of node.marks) encountered.add(mark.type.name); });
    const folded = headingFoldKey.getState(editor.state)?.collapsed;
    const headings: NativeEditorState['headings'] = [];
    editor.state.doc.forEach(node => { if (node.type.name === 'heading') { const id = headings.length; headings.push({ id, title: node.textContent, level: node.attrs.level, collapsed: folded?.has(id) ?? false }); } });
    return { identity, revision: options.revision(), ready: Boolean(identity), editable: editor.isEditable,
      locked: options.locked(), composing: editor.view.composing, focused: editor.isFocused,
      canUndo: editor.can().undo(), canRedo: editor.can().redo(),
      block: editor.isActive('heading') ? `heading${editor.getAttributes('heading').level}` : editor.state.selection.$from.parent.type.name,
      marks, mixedMarks: names.filter(name => encountered.has(name) && !marks.includes(name)),
      nodeType: selected?.node.type.name ?? '', attributes, selectionToken: liveToken, headings,
      ...search.state(), theme: document.documentElement.dataset.theme ?? '',
      fontSize: Number(localStorage.getItem('mobile-font') ?? 17),
      characters: Array.from(editor.state.doc.textContent.replace(/\s/g, '')).length, sourceBytes };
  }
  function publish() {
    if (publishing || editor.isDestroyed) return;
    publishing = true;
    try {
      const next = state(), serialized = JSON.stringify(next);
      if (serialized !== lastPublished) { lastPublished = serialized; options.publish(next); }
    } finally { publishing = false; }
  }
  editor.on('transaction', publish); editor.on('update', publish); editor.on('focus', publish); editor.on('blur', publish);
  editor.on('destroy', () => { search.destroy(); bookmarks.clear(); });
  // Update the automatically advertised token with the actual current selection;
  // explicit capture tokens remain frozen and independently mapped.
  editor.on('selectionUpdate', () => { if (liveToken) bookmarks.delete(liveToken); liveToken = undefined; publish(); });
  const composition = () => setTimeout(publish, 0);
  editor.view.dom.addEventListener('compositionstart', composition);
  editor.view.dom.addEventListener('compositionend', composition);
  function mode(editable: boolean) {
    editor.setEditable(editable);
    document.body.classList.toggle('reading-mode', !editable);
    const toolbar = document.querySelector<HTMLElement>('.mobile-toolbar'); if (toolbar) toolbar.hidden = active || !editable;
    const modeButton = document.querySelector<HTMLButtonElement>('.mobile-reading button');
    if (modeButton) { modeButton.textContent = editable ? '阅读' : '编辑'; modeButton.setAttribute('aria-label', modeButton.textContent); }
    if (!editable && !editor.view.composing) editor.commands.blur();
    publish();
  }
  function restore(token: string) {
    const saved = bookmarks.get(token);
    if (!saved?.valid) throw new Error('选区已失效，请重新选择内容');
    editor.view.dispatch(editor.state.tr.setSelection(saved.bookmark.resolve(editor.state.doc)).setMeta('addToHistory', false));
    return saved;
  }
  function rebindCurrent(token: string | undefined) {
    if (!token) return;
    // Only the initiating command may carry its own logical target forward.
    // All other frozen captures still invalidate on replacement/deletion.
    bookmarks.set(token, { bookmark: editor.state.selection.getBookmark(), target: target(), valid: true });
  }
  function integer(value: string | undefined, min: number, max: number): number {
    const n = Number(value); if (!Number.isInteger(n) || n < min || n > max) throw new Error(`数值应在 ${min}–${max} 之间`); return n;
  }
  function rich(content: JSONContent) { return commitRichNode(editor, content); }
  async function execute(command: NativeEditorCommand): Promise<NativeEditorResult> {
    const reply: NativeEditorResult = { requestId: typeof command?.requestId === 'string' ? command.requestId : '', success: false };
    try {
      if (!command || !reply.requestId || typeof command.identity !== 'string' || !Number.isInteger(command.revision) || typeof command.name !== 'string' || !command.args || typeof command.args !== 'object' || Array.isArray(command.args) || Object.values(command.args).some(value => typeof value !== 'string')) throw new Error('无效的编辑命令');
      if (!commandNames.has(command.name)) throw new Error('不支持的编辑命令');
      if (!identity || command.identity !== identity || command.revision !== options.revision()) throw new Error('文档会话已改变，请重新操作');
      const { name, args: a } = command;
      const write = !readCommands.has(name);
      if (options.locked() && (write || name === 'mode.set' || name === 'focus.restore')) throw new Error('文档正在保护中，请稍后重试');
      if (editor.view.composing && (write || ['keyboard.dismiss', 'focus.restore', 'mode.set', 'search.set', 'search.next', 'search.previous'].includes(name))) throw new Error('正在完成输入，请稍后重试');
      if (write && !editor.isEditable) throw new Error('阅读模式下不能修改文档');
      if (command.selectionToken && editor.view.composing && !['selection.release', 'preview.render'].includes(name)) throw new Error('正在完成输入，请稍后重试');
      if (command.selectionToken && !['selection.release', 'preview.render'].includes(name)) restore(command.selectionToken);
      const contextual = name.startsWith('context.') || (name.startsWith('table.') && name !== 'table.fullscreen');
      if (contextual && !command.selectionToken) throw new Error('请先捕获所选内容');
      let ok = true;
      switch (name) {
        case 'preview.render': {
          const startGeneration = generation;
          reply.data = await renderNativePreview(a);
          if (generation !== startGeneration || command.identity !== identity || command.revision !== options.revision()) throw new Error('文档会话已改变，请重新操作');
          break;
        }
        case 'native.activate':
          active = true; document.body.classList.add('native-controls'); search.setNative(true);
          document.querySelectorAll<HTMLElement>('.mobile-toolbar, .mobile-reading, .donemd-find').forEach(el => { el.hidden = true; });
          document.querySelectorAll('.mobile-panel').forEach(el => el.remove());
          window.dispatchEvent(new Event('resize')); break;
        case 'selection.capture': reply.selectionToken = capture(); break;
        case 'selection.release': if (command.selectionToken) bookmarks.delete(command.selectionToken); break;
        case 'keyboard.dismiss': editor.commands.blur(); break;
        case 'focus.restore':
          if (a.focus !== undefined && !['true', 'false'].includes(a.focus)) throw new Error('无效的焦点设置');
          // Selection restoration above is independent of keyboard activation.
          // Native panel cancellation normally wants the former, not the latter.
          if (a.focus !== 'false') editor.commands.focus(undefined, { scrollIntoView: false });
          break;
        case 'history.undo': ok = editor.commands.undo(); break;
        case 'history.redo': ok = editor.commands.redo(); break;
        case 'mode.set': if (!['true', 'false'].includes(a.editable)) throw new Error('无效的阅读模式'); mode(a.editable === 'true'); break;
        case 'format.paragraph': ok = editor.commands.setParagraph(); break;
        case 'format.heading': {
          if (editor.isActive('tableCell') || editor.isActive('tableHeader')) throw new Error('表格内暂不支持标题');
          ok = editor.commands.setHeading({ level: integer(a.level, 1, 6) as 1 | 2 | 3 | 4 | 5 | 6 }); break;
        }
        case 'format.bold': ok = editor.commands.toggleBold(); break;
        case 'format.italic': ok = editor.commands.toggleItalic(); break;
        case 'format.strike': ok = editor.commands.toggleStrike(); break;
        case 'format.code': ok = editor.commands.toggleCode(); break;
        case 'format.clear': ok = editor.chain().clearNodes().unsetAllMarks().run(); break;
        case 'format.bullet': ok = editor.commands.toggleBulletList(); break;
        case 'format.ordered': ok = editor.commands.toggleOrderedList(); break;
        case 'format.task': ok = editor.commands.toggleTaskList(); break;
        case 'format.indent': ok = editor.commands.sinkListItem(editor.isActive('taskItem') ? 'taskItem' : 'listItem'); break;
        case 'format.outdent': ok = editor.commands.liftListItem(editor.isActive('taskItem') ? 'taskItem' : 'listItem'); break;
        case 'format.quote': ok = editor.commands.toggleBlockquote(); break;
        case 'format.callout': ok = editor.commands.toggleWrap('callout'); break;
        case 'format.link': {
          const href = (a.href ?? '').trim();
          if (href && (!/^(https?:\/\/[^\s]+|mailto:[^\s]+|#[^\s]*)$/i.test(href) || /[\u0000-\u001f]/.test(href))) throw new Error('请输入 https、http、mailto 地址或文内锚点');
          ok = href ? editor.chain().extendMarkRange('link').setLink({ href }).run() : editor.chain().extendMarkRange('link').unsetLink().run(); break;
        }
        case 'insert.rule': ok = rich({ type: 'horizontalRule' }); break;
        case 'insert.table': ok = editor.commands.insertTable({ rows: integer(a.rows ?? '3', 1, 100), cols: integer(a.cols ?? '3', 1, 20), withHeaderRow: true }); break;
        case 'insert.image': case 'insert.video': {
          if (!a.src || /^(?:javascript|data|vbscript):/i.test(a.src) || /[\u0000-\u001f]/.test(a.src)) throw new Error('无效的附件地址');
          const type = name.slice(7), selected = target();
          ok = selected?.node.type.name === type
            ? editor.commands.updateAttributes(type, { src: a.src }) : rich({ type, attrs: { src: a.src } }); break;
        }
        case 'insert.math': if (a.display !== undefined && !['true', 'false'].includes(a.display)) throw new Error('无效的公式类型'); ok = rich({ type: a.display === 'true' ? 'math_block' : 'math_inline', attrs: { latex: a.text ?? '' } }); break;
        case 'insert.code': ok = rich({ type: 'codeBlock', attrs: { language: a.language ?? '' }, content: a.text ? [{ type: 'text', text: a.text }] : [] }); break;
        case 'insert.raw': ok = rich({ type: 'raw_markdown_block', attrs: { raw: a.text ?? '' } }); break;
        case 'context.edit': {
          const saved = bookmarks.get(command.selectionToken!)!, selected = saved.target;
          if (!selected || !saved.valid) throw new Error('先点选要编辑的内容');
          const { node, pos } = selected, type = node.type.name;
          if (type === 'image') {
            editor.view.dispatch(editor.state.tr.setNodeMarkup(pos, undefined, { ...node.attrs, alt: a.alt ?? a.text ?? '' }));
            editor.view.dispatch(editor.state.tr.setSelection(NodeSelection.create(editor.state.doc, pos)).setMeta('addToHistory', false));
            rebindCurrent(command.selectionToken);
          } else {
            const content = type === 'codeBlock' ? { type, attrs: { language: a.language ?? node.attrs.language }, content: a.text ? [{ type: 'text', text: a.text }] : [] }
              : type === 'raw_markdown_block' ? { type, attrs: { raw: a.text ?? '' } }
              : type.startsWith('math_') ? { type: a.display === undefined ? type : a.display === 'true' ? 'math_block' : 'math_inline', attrs: { latex: a.text ?? '' } } : undefined;
            if (!content) throw new Error('所选内容不能在此编辑');
            if (type.startsWith('math_') && a.display !== undefined && !['true', 'false'].includes(a.display)) throw new Error('无效的公式类型');
            ok = content.type === type ? commitRichNode(editor, content, pos)
              : editor.commands.insertContentAt({ from: pos, to: pos + node.nodeSize }, content);
          }
          break;
        }
        case 'context.preview': case 'context.deleteReference': {
          const selected = bookmarks.get(command.selectionToken!)?.target;
          if (!selected || !['image', 'video'].includes(selected.node.type.name)) throw new Error('先点选附件');
          if (name === 'context.preview') options.preview(String(selected.node.attrs.src));
          else editor.view.dispatch(editor.state.tr.delete(selected.pos, selected.pos + selected.node.nodeSize));
          break;
        }
        case 'table.rowBefore': ok = editor.commands.addRowBefore(); break;
        case 'table.rowAfter': ok = editor.commands.addRowAfter(); break;
        case 'table.columnBefore': ok = editor.commands.addColumnBefore(); break;
        case 'table.columnAfter': ok = editor.commands.addColumnAfter(); break;
        case 'table.deleteRow': ok = editor.commands.deleteRow(); break;
        case 'table.deleteColumn': ok = editor.commands.deleteColumn(); break;
        case 'table.delete': ok = editor.commands.deleteTable(); break;
        case 'table.fullscreen': {
          const selected = target(); if (selected?.node.type.name !== 'table') throw new Error('先点选表格');
          const dom = editor.view.nodeDOM(selected.pos) as HTMLElement | null;
          const wrapper = dom?.closest('.mobile-table') ?? dom;
          if (!wrapper) throw new Error('表格尚未就绪');
          wrapper.classList.toggle('is-fullscreen');
          const toggle = wrapper.querySelector<HTMLButtonElement>(':scope > button');
          if (toggle) { toggle.textContent = wrapper.classList.contains('is-fullscreen') ? '退出全屏表格' : '全屏表格'; toggle.setAttribute('aria-label', toggle.textContent); }
          break;
        }
        case 'block.up': case 'block.down': {
          if (editor.isEmpty) throw new Error('当前没有可操作的段落');
          const before = editor.state.selection;
          const blocks: { pos: number; node: PMNode }[] = [];
          editor.state.doc.forEach((node, pos) => blocks.push({ node, pos }));
          const index = blocks.findIndex(({ pos, node }) => before.from >= pos && before.from < pos + node.nodeSize);
          const block = blocks[index], next = blocks[name === 'block.up' ? index - 1 : index + 1];
          if (!block || !next) { ok = false; break; }
          const destination = name === 'block.up' ? next.pos : block.pos + next.node.nodeSize;
          ok = changeBlock(editor, name === 'block.up' ? 'up' : 'down');
          if (ok) {
            const doc = editor.state.doc;
            const offset = (position: number) => destination + Math.max(0, Math.min(block.node.nodeSize - 1, position - block.pos));
            const selection = before instanceof NodeSelection ? NodeSelection.create(doc, destination)
              : TextSelection.between(doc.resolve(offset(before.anchor)), doc.resolve(offset(before.head)));
            editor.view.dispatch(editor.state.tr.setSelection(selection).setMeta('addToHistory', false));
            rebindCurrent(command.selectionToken);
          }
          break;
        }
        case 'block.copy': case 'block.delete':
          if (editor.isEmpty) throw new Error('当前没有可操作的段落');
          ok = changeBlock(editor, name.slice(6) as 'copy' | 'delete'); break;
        case 'search.set': search.setQuery(a.query ?? ''); break;
        case 'search.next': search.navigate(1); break;
        case 'search.previous': search.navigate(-1); break;
        case 'search.close': search.close(false); break;
        case 'search.replace': {
          if (!['true', 'false'].includes(a.all)) throw new Error('无效的替换方式');
          const count = replaceMatches(editor, a.query ?? '', a.replacement ?? '', a.all === 'true');
          search.setQuery(a.query ?? ''); reply.data = { replaced: String(count) }; reply.message = `已替换${count}处，可撤销`; break;
        }
        case 'source.get': throw new Error('请通过原生安全快照获取 Markdown 源码');
        case 'outline.jump': case 'outline.toggle': {
          const headings: { pos: number }[] = []; editor.state.doc.forEach((node, pos) => { if (node.type.name === 'heading') headings.push({ pos }); });
          const id = integer(a.id, 0, headings.length - 1);
          const folded = new Set(headingFoldKey.getState(editor.state)?.collapsed ?? []);
          if (name === 'outline.toggle') { if (folded.has(id)) folded.delete(id); else folded.add(id); }
          else folded.clear();
          applyFoldState(editor.view, [...folded]);
          if (name === 'outline.jump') (editor.view.nodeDOM(headings[id].pos) as HTMLElement | null)?.scrollIntoView?.({ block: 'start' }); break;
        }
        case 'reader.set': {
          if (a.theme !== undefined && !['', 'paper', 'night'].includes(a.theme)) throw new Error('无效的阅读主题');
          if (a.fontSize !== undefined && ![15, 17, 19, 22, 26].includes(Number(a.fontSize))) throw new Error('无效的字号');
          if (a.theme !== undefined) { document.documentElement.dataset.theme = a.theme; localStorage.setItem('mobile-theme', a.theme); }
          if (a.fontSize !== undefined) { editor.view.dom.style.fontSize = `${a.fontSize}px`; localStorage.setItem('mobile-font', a.fontSize); } break;
        }
        case 'reader.info': break;
      }
      if (!ok) throw new Error('当前选区不支持此操作');
      reply.success = true;
    } catch (error) { reply.message = error instanceof Error ? error.message : '操作失败'; }
    publish(); reply.state = state(); options.result(reply); return reply;
  }
  return { search, state, publish, mode,
    info(info: { identity: string; source: string }) {
      sourceBytes = new TextEncoder().encode(info.source).length;
      if (identity !== info.identity) { identity = info.identity; reset(); }
      publish();
    },
    // Even synchronous editor actions go through one FIFO, including failures.
    receive(value: unknown): Promise<NativeEditorResult> {
      const result = queued.then(() => execute(value as NativeEditorCommand));
      queued = result.then(() => undefined, () => undefined); return result;
    },
  };
}
