import { Node, mergeAttributes } from '@tiptap/core';
import { renderMath } from './katex-render';

/**
 * Inline math node `$...$` (Phase 5 M2). Atom node whose `latex` attr holds
 * the raw LaTeX; the NodeView renders it with KaTeX inline (displayMode
 * false). Parse/serialize live in Swift (ASTConverter / Serializer) — this
 * file is the editor-side render contract only.
 *
 * Atom = no caret enters, clicks select the whole node (render-only this
 * slice; editing is done in the Markdown 源 pane / by reopening).
 */
export const MathInline = Node.create({
  name: 'math_inline',
  group: 'inline',
  inline: true,
  atom: true,
  selectable: true,

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
    return [{ tag: 'span[data-math-inline]' }];
  },

  renderHTML({ HTMLAttributes }) {
    // Static fallback for copy/paste serialization; the NodeView is what
    // users actually see.
    return [
      'span',
      mergeAttributes(HTMLAttributes, {
        'data-math-inline': '',
        class: 'donemd-math-inline',
      }),
    ];
  },

  addNodeView() {
    return ({ node }) => {
      const dom = document.createElement('span');
      dom.className = 'donemd-math-inline';
      dom.setAttribute('data-math-inline', '');
      dom.setAttribute('contenteditable', 'false');

      let currentLatex: string | null = null;

      const paint = (latex: string): void => {
        currentLatex = latex;
        const { html, error } = renderMath(latex, false);
        if (error !== null) {
          dom.classList.add('is-error');
          dom.textContent = latex;
          dom.title = error;
        } else {
          dom.classList.remove('is-error');
          dom.removeAttribute('title');
          dom.innerHTML = html;
        }
      };

      paint(String(node.attrs.latex ?? ''));

      return {
        dom,
        update: (updatedNode) => {
          if (updatedNode.type.name !== 'math_inline') return false;
          const next = String(updatedNode.attrs.latex ?? '');
          if (next !== currentLatex) paint(next);
          return true;
        },
        // Atom with no contentDOM: the NodeView owns all inner DOM, so treat
        // every mutation as internal (never a user edit) to avoid the WebKit
        // NodeView rebuild loop the mermaid NodeView documents.
        ignoreMutation: (mutation) => mutation.type !== 'selection',
      };
    };
  },
});
