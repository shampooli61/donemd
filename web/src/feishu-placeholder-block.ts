import { Node, mergeAttributes } from '@tiptap/core';

/**
 * Tiptap atom node for "飞书占位块" (Feishu placeholder block) — the local
 * projection of a Feishu-native block (sheet / mindnote / board / bitable /
 * attachment / video / 3rd-party embed) that has no Markdown equivalent.
 *
 * Disk format: `<!-- feishu-placeholder ... -->` HTML comment with key:value
 * lines. ADR-0007 is the single source of truth for the protocol; the parse
 * and serialize sides live in Swift (FeishuPlaceholder.swift). This file is
 * the editor-side render contract only.
 *
 * Design promises (CONTEXT.md § 飞书占位块):
 *   - Atom block — no internal editing on the Visual side; users move /
 *     delete the block as a whole, but content lives only in Feishu.
 *   - Card style: light-grey background, type emoji on the left, title and
 *     summary, "在飞书中编辑 ↗" affordance on the right.
 *   - `unknown_fields` is opaque passthrough — invisible in the UI, only
 *     present so future Feishu metadata extensions round-trip untouched.
 */

const TYPE_LABEL: Record<string, { emoji: string; label: string }> = {
  sheet: { emoji: '📊', label: '飞书电子表格' },
  mindnote: { emoji: '🧠', label: '飞书思维笔记' },
  board: { emoji: '🎨', label: '飞书画板' },
  bitable: { emoji: '📋', label: '飞书多维表格' },
  attachment: { emoji: '📎', label: '飞书附件' },
  video: { emoji: '🎥', label: '飞书视频' },
  embed: { emoji: '🔗', label: '飞书嵌入' },
};

function describeType(type: string): { emoji: string; label: string } {
  return TYPE_LABEL[type] ?? TYPE_LABEL.embed;
}

export const FeishuPlaceholderBlock = Node.create({
  name: 'feishu_placeholder_block',
  group: 'block',
  atom: true,
  selectable: true,
  draggable: true,

  addAttributes() {
    return {
      type: {
        default: 'embed',
        parseHTML: (el) => el.getAttribute('data-feishu-type') ?? 'embed',
        renderHTML: (attrs) => ({ 'data-feishu-type': attrs.type }),
      },
      block_id: {
        default: '',
        parseHTML: (el) => el.getAttribute('data-feishu-block-id') ?? '',
        renderHTML: (attrs) => ({ 'data-feishu-block-id': attrs.block_id }),
      },
      block_token: {
        default: null,
        parseHTML: (el) => el.getAttribute('data-feishu-block-token'),
        renderHTML: (attrs) =>
          attrs.block_token ? { 'data-feishu-block-token': attrs.block_token } : {},
      },
      title: {
        default: '',
        parseHTML: (el) => el.getAttribute('data-feishu-title') ?? '',
        renderHTML: (attrs) => ({ 'data-feishu-title': attrs.title }),
      },
      summary: {
        default: null,
        parseHTML: (el) => el.getAttribute('data-feishu-summary'),
        renderHTML: (attrs) =>
          attrs.summary ? { 'data-feishu-summary': attrs.summary } : {},
      },
      url: {
        default: '',
        parseHTML: (el) => el.getAttribute('data-feishu-url') ?? '',
        renderHTML: (attrs) => ({ 'data-feishu-url': attrs.url }),
      },
      created_in_feishu_at: {
        default: null,
        parseHTML: (el) => el.getAttribute('data-feishu-created-at'),
        renderHTML: (attrs) =>
          attrs.created_in_feishu_at
            ? { 'data-feishu-created-at': attrs.created_in_feishu_at }
            : {},
      },
      // Opaque passthrough — never rendered, only kept so unknown fields
      // survive parse → edit → save without loss.
      unknown_fields: {
        default: [],
        // Tiptap's parseHTML default works fine for arrays since this attr
        // never appears as a DOM attribute (it's only ever set by Swift).
      },
    };
  },

  parseHTML() {
    return [{ tag: 'div[data-feishu-placeholder]' }];
  },

  renderHTML({ HTMLAttributes }) {
    // ProseMirror also asks for a fallback static rendering (e.g. for
    // copy/paste serialization). The NodeView below is what users actually
    // see. Keep the static rendering minimal but parse-able.
    return [
      'div',
      mergeAttributes(HTMLAttributes, {
        'data-feishu-placeholder': '',
        class: 'donemd-feishu-placeholder',
      }),
    ];
  },

  /** Custom DOM so we can render the typed card (icon + title + summary +
   *  open-in-feishu link). ProseMirror sees this as an atom — clicks
   *  select the whole block, no caret enters. */
  addNodeView() {
    return ({ node }) => {
      const dom = document.createElement('div');
      dom.className = 'donemd-feishu-placeholder';
      dom.setAttribute('data-feishu-placeholder', '');
      dom.setAttribute('data-feishu-type', String(node.attrs.type ?? 'embed'));
      dom.setAttribute('contenteditable', 'false');

      const header = document.createElement('div');
      header.className = 'donemd-feishu-placeholder__header';

      const meta = describeType(String(node.attrs.type ?? 'embed'));
      const icon = document.createElement('span');
      icon.className = 'donemd-feishu-placeholder__icon';
      icon.textContent = meta.emoji;
      header.appendChild(icon);

      const typeLabel = document.createElement('span');
      typeLabel.className = 'donemd-feishu-placeholder__type';
      typeLabel.textContent = meta.label;
      header.appendChild(typeLabel);

      const url = String(node.attrs.url ?? '');
      if (url.length > 0) {
        const open = document.createElement('a');
        open.className = 'donemd-feishu-placeholder__open';
        open.href = url;
        open.target = '_blank';
        open.rel = 'noopener noreferrer';
        open.textContent = '在飞书中编辑 ↗';
        // Anchor inside an atom node: explicitly let the click hit the
        // browser's link handler instead of being eaten by ProseMirror's
        // node-select gesture.
        open.addEventListener('mousedown', (event) => {
          event.stopPropagation();
        });
        header.appendChild(open);
      }

      dom.appendChild(header);

      const title = document.createElement('div');
      title.className = 'donemd-feishu-placeholder__title';
      title.textContent = String(node.attrs.title ?? '');
      dom.appendChild(title);

      const summaryText = node.attrs.summary;
      if (typeof summaryText === 'string' && summaryText.length > 0) {
        const summary = document.createElement('div');
        summary.className = 'donemd-feishu-placeholder__summary';
        summary.textContent = summaryText;
        dom.appendChild(summary);
      }

      return { dom };
    };
  },
});
