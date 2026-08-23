import { Node, mergeAttributes } from '@tiptap/core';

/**
 * Tiptap node for "原文块 (raw markdown block)" — content Phase 1's
 * Visual 视图 doesn't yet know how to render natively (block-level HTML,
 * BlockDirectives / callouts, anything else swift-markdown surfaces as
 * a non-renderable block).
 *
 * Design promises (CONTEXT.md):
 *   - Atom block (no internal editing on the Visual side; user has to
 *     drop into the Markdown 源 pane to change it — Phase 5).
 *   - Holds the original Markdown source verbatim in attrs.raw so
 *     Cmd+S writes it back byte-for-byte.
 *   - Visual rendering: light-grey monospace block with a discreet
 *     "在 Markdown 源 编辑" hint in the corner.
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

  /** Custom DOM node so we can render the raw text exactly as-is plus
   *  the "在 Markdown 源 编辑" affordance.  ProseMirror sees this as an
   *  atom — clicks select the whole block instead of dropping a caret. */
  addNodeView() {
    return ({ node }) => {
      const dom = document.createElement('div');
      dom.className = 'donemd-raw-block';
      dom.setAttribute('data-raw-markdown-block', '');

      const pre = document.createElement('pre');
      pre.className = 'donemd-raw-block__content';
      pre.textContent = (node.attrs.raw as string) ?? '';
      dom.appendChild(pre);

      const hint = document.createElement('span');
      hint.className = 'donemd-raw-block__hint';
      hint.textContent = '在 Markdown 源 编辑';
      dom.appendChild(hint);

      return { dom };
    };
  },
});
