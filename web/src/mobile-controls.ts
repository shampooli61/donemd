import type { Editor } from '@tiptap/core';
import { changeBlock, replaceMatches } from './mobile-commands';
import { createDocumentSearch } from './document-search';

export function button(label: string, action: () => void): HTMLButtonElement {
  const item = document.createElement('button');
  item.type = 'button'; item.textContent = label; item.setAttribute('aria-label', label);
  item.addEventListener('pointerdown', event => event.preventDefault());
  item.addEventListener('click', action);
  return item;
}

export function panel(title: string): { dialog: HTMLDialogElement; close: () => void } {
  const dialog = document.createElement('dialog');
  dialog.className = 'mobile-panel'; dialog.setAttribute('aria-label', title);
  const heading = document.createElement('h2'); heading.textContent = title;
  const close = () => dialog.remove();
  dialog.append(heading, button('关闭', close));
  dialog.addEventListener('cancel', () => close());
  document.body.append(dialog); dialog.showModal();
  return { dialog, close };
}

export function field(label: string, value = '', multiline = false): HTMLInputElement | HTMLTextAreaElement {
  const input = document.createElement(multiline ? 'textarea' : 'input');
  input.value = value; input.setAttribute('aria-label', label); input.placeholder = label;
  return input;
}

export function attachWritingControls(editor: Editor, unfold: (ordinal: number) => void) {
  const search = createDocumentSearch(editor, unfold);
  const toolbar = document.createElement('nav'); toolbar.className = 'mobile-toolbar'; toolbar.setAttribute('aria-label', '写作工具');
  const choices = (title: string, actions: [string, () => void][]) => {
    const { dialog, close } = panel(title);
    for (const [label, action] of actions) dialog.append(button(label, () => { close(); action(); }));
  };
  toolbar.append(button('撤销', () => editor.commands.undo()), button('重做', () => editor.commands.redo()),
    button('格式', () => choices('文字与段落格式', [
      ['正文', () => editor.chain().focus().setParagraph().run()],
      ...([1, 2, 3, 4, 5, 6] as const).map(level => [`标题 ${level}`, () => {
        if (!editor.isActive('tableCell') && !editor.isActive('tableHeader')) editor.chain().focus().toggleHeading({ level }).run();
      }] as [string, () => void]),
      ['加粗', () => editor.chain().focus().toggleBold().run()], ['斜体', () => editor.chain().focus().toggleItalic().run()],
      ['删除线', () => editor.chain().focus().toggleStrike().run()], ['行内代码', () => editor.chain().focus().toggleCode().run()],
      ['清除格式', () => editor.chain().focus().clearNodes().unsetAllMarks().run()],
      ['无序列表', () => editor.chain().focus().toggleBulletList().run()], ['有序列表', () => editor.chain().focus().toggleOrderedList().run()],
      ['任务列表', () => editor.chain().focus().toggleTaskList().run()],
      ['增加缩进', () => editor.chain().focus().sinkListItem(editor.isActive('taskItem') ? 'taskItem' : 'listItem').run()],
      ['减少缩进', () => editor.chain().focus().liftListItem(editor.isActive('taskItem') ? 'taskItem' : 'listItem').run()],
      ['引用', () => editor.chain().focus().toggleBlockquote().run()],
      ['分隔线', () => editor.chain().focus().setHorizontalRule().run()],
      ['提示块', () => editor.chain().focus().toggleWrap('callout').run()],
      ['链接', () => {
        const { dialog, close } = panel('编辑链接');
        const input = field('链接地址', editor.getAttributes('link').href ?? '');
        const error = document.createElement('p'); error.setAttribute('role', 'alert');
        dialog.append(input, error, button('应用链接', () => {
          const url = input.value.trim();
          if (url && !/^(https?:|mailto:|#)/i.test(url)) { error.textContent = '请输入 https、http、mailto 地址或文内锚点'; return; }
          if (url) editor.chain().focus().extendMarkRange('link').setLink({ href: url }).run();
          else editor.chain().focus().extendMarkRange('link').unsetLink().run();
          close();
        })); input.focus();
      }],
    ])),
    button('段落', () => choices('当前整块操作', [
      ['上移', () => changeBlock(editor, 'up')], ['下移', () => changeBlock(editor, 'down')],
      ['复制段落', () => changeBlock(editor, 'copy')], ['删除段落', () => changeBlock(editor, 'delete')],
    ])),
    button('查找', () => search.open()),
    button('替换', () => {
      const { dialog } = panel('查找替换');
      const query = field('查找内容'), replacement = field('替换为');
      const status = document.createElement('p'); status.setAttribute('role', 'status');
      dialog.append(query, replacement, button('替换第一处', () => { status.textContent = `已替换 ${replaceMatches(editor, query.value, replacement.value, false)} 处`; }),
        button('全部替换', () => { status.textContent = `已替换 ${replaceMatches(editor, query.value, replacement.value, true)} 处，可撤销`; }), status);
      query.focus();
    }));
  document.body.append(toolbar);
  function position() {
    const viewport = window.visualViewport;
    toolbar.style.bottom = `${Math.max(0, window.innerHeight - (viewport?.height ?? window.innerHeight) - (viewport?.offsetTop ?? 0))}px`;
  }
  window.visualViewport?.addEventListener('resize', position);
  window.visualViewport?.addEventListener('scroll', position);
  return toolbar;
}
