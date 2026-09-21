import { Node, mergeAttributes } from '@tiptap/core';

/**
 * Tiptap node for "原文块 (raw markdown block)" — content Phase 1's
 * Visual 视图 doesn't yet know how to render natively (block-level HTML,
 * BlockDirectives / callouts, anything else swift-markdown surfaces as
 * a non-renderable block).
 *
 * Design promises (CONTEXT.md):
 *   - Atom block (no internal editing on the Visual side; user has to
 *     open its dedicated raw editor).
 *   - Holds the original Markdown source verbatim in attrs.raw so
 *     Cmd+S writes it back byte-for-byte.
 *   - Visual rendering: light-grey monospace block with a discreet
 *     "编辑原文" hint in the corner.
 */
export const RawMarkdownBlock = Node.create({
  name: 'raw_markdown_block',
  group: 'block',
  atom: true,
  selectable: true,

  addAttributes() {
    return {
      raw: {
        default: '',
        parseHTML: (element) => element.getAttribute('data-raw') ?? '',
        renderHTML: (attrs) => ({ 'data-raw': attrs.raw }),
      },
    };
  },

  parseHTML() {
    return [{ tag: 'div[data-raw-markdown-block]' }];
  },

  renderHTML({ HTMLAttributes, node }) {
    return [
      'div',
      mergeAttributes(HTMLAttributes, {
        'data-raw-markdown-block': '',
        class: 'donemd-raw-block',
      }),
      node.attrs.raw as string,
    ];
  },

  /** Edit raw syntax in a dedicated dialog; the source mirror stays read-only. */
  addNodeView() {
    return ({ node, editor, getPos }) => {
      const dom = document.createElement('div');
      dom.className = 'donemd-raw-block'; dom.contentEditable = 'false'; dom.setAttribute('data-raw-markdown-block', '');
      const pre = document.createElement('pre'); pre.className = 'donemd-raw-block__content';
      pre.textContent = node.attrs.raw ?? '';
      const edit = document.createElement('button'); edit.type = 'button';
      edit.className = 'donemd-raw-block__hint'; edit.textContent = '编辑原文'; edit.setAttribute('aria-label', '编辑原文');
      dom.append(pre, edit);
      let dialog: HTMLDialogElement | undefined;
      const close = () => { dialog?.remove(); dialog = undefined; editor.commands.focus(); };
      edit.addEventListener('click', () => {
        if (dialog) return;
        dialog = document.createElement('dialog'); dialog.className = 'donemd-raw-editor';
        dialog.setAttribute('aria-label', '编辑原文块');
        const title = document.createElement('h2'); title.textContent = '编辑原文';
        const help = document.createElement('p'); help.textContent = '按原文保存，不执行 HTML。修改仅影响这个内容块。';
        const field = document.createElement('textarea'); field.setAttribute('aria-label', '原文内容');
        field.value = pre.textContent ?? ''; field.spellcheck = false;
        const cancel = document.createElement('button'); cancel.type = 'button'; cancel.textContent = '取消'; cancel.setAttribute('data-raw-cancel', '');
        const save = document.createElement('button'); save.type = 'button'; save.textContent = '保存修改'; save.setAttribute('data-raw-save', '');
        cancel.addEventListener('click', close);
        save.addEventListener('click', () => {
          const pos = getPos();
          if (typeof pos !== 'number') { close(); return; }
          const current = editor.state.doc.nodeAt(pos);
          if (current?.type.name !== 'raw_markdown_block') { close(); return; }
          editor.view.dispatch(editor.state.tr.setNodeMarkup(pos, undefined, { ...current.attrs, raw: field.value }));
          close();
        });
        dialog.addEventListener('cancel', e => { e.preventDefault(); close(); });
        dialog.append(title, help, field, cancel, save); document.body.append(dialog);
        if (typeof dialog.showModal === 'function') dialog.showModal(); else dialog.open = true;
        field.focus();
      });
      return {
        dom,
        update(updated) {
          if (updated.type.name !== 'raw_markdown_block') return false;
          pre.textContent = updated.attrs.raw ?? ''; return true;
        },
        stopEvent(event) { return edit.contains(event.target as globalThis.Node); },
        destroy() { dialog?.remove(); },
      };
    };
  },
});
