import { Node, mergeAttributes } from '@tiptap/core';
import { renderMath } from './katex-render';

/**
 * Block math node `$$...$$` (Phase 5 M2). Atom node whose `latex` attr holds
 * the raw LaTeX; the NodeView renders it centered with KaTeX (displayMode
 * true). Parse/serialize live in Swift (ASTConverter / Serializer) — this
 * file is the editor-side render contract only.
 *
 * Failure UI follows the mermaid pattern: red border + error line + the raw
 * LaTeX kept visible so the user can read/fix the source in the Markdown 源
 * pane.
 */
export const MathBlock = Node.create({
  name: 'math_block',
  group: 'block',
  atom: true,
  selectable: true,
  draggable: true,

  addAttributes() {
    return {
      latex: {
        default: '',
        parseHTML: (el) => el.getAttribute('data-latex') ?? '',
        renderHTML: (attrs) => ({ 'data-latex': attrs.latex }),
      },
    };
  },

  parseHTML() {
    return [{ tag: 'div[data-math-block]' }];
  },

  renderHTML({ HTMLAttributes }) {
    return [
      'div',
      mergeAttributes(HTMLAttributes, {
        'data-math-block': '',
        class: 'donemd-math-block',
      }),
    ];
  },

  addNodeView() {
    return ({ node }) => {
      const dom = document.createElement('div');
      dom.className = 'donemd-math-block';
      dom.setAttribute('data-math-block', '');
      dom.setAttribute('contenteditable', 'false');

      let currentLatex: string | null = null;

      const paint = (latex: string): void => {
        currentLatex = latex;
        const { html, error } = renderMath(latex, true);
        if (error !== null) {
          dom.classList.add('is-error');
          const head = document.createElement('div');
          head.className = 'donemd-math-block__error-line';
          head.textContent = error;
          const raw = document.createElement('pre');
          raw.className = 'donemd-math-block__raw';
          raw.textContent = latex;
          dom.replaceChildren(head, raw);
        } else {
          dom.classList.remove('is-error');
          dom.innerHTML = html;
        }
      };

      paint(String(node.attrs.latex ?? ''));

      return {
        dom,
        update: (updatedNode) => {
          if (updatedNode.type.name !== 'math_block') return false;
          const next = String(updatedNode.attrs.latex ?? '');
          if (next !== currentLatex) paint(next);
          return true;
        },
        // Atom with no contentDOM: NodeView owns all inner DOM. Ignore every
        // non-selection mutation to avoid the WebKit rebuild loop.
        ignoreMutation: (mutation) => mutation.type !== 'selection',
      };
    };
  },
});
