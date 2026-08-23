// Table toolbar (#16 / #76 follow-up) — a small floating bar that appears
// above the table whenever the caret sits inside one, giving row/column
// add-delete + delete-table controls. Done.md has no table-editing UI
// otherwise (only ⌘⌥T to insert), so a table's shape was un-editable after
// creation. This is a caret-driven floater, NOT the selection bubble menu:
// it shows on cursor-in-table (no text selection needed), so it can't ride
// the BubbleMenu plugin (which requires a non-empty selection).
//
// Positioning mirrors the callout picker: a position:fixed element appended
// to <body>, placed off the table DOM node's bounding rect and re-placed on
// scroll/resize while visible.

import type { Editor } from '@tiptap/core';

interface ToolbarAction {
  label: string;
  title: string;
  run: (editor: Editor) => void;
  /** Whether the command is currently applicable (greys out / hides if not). */
  enabled: (editor: Editor) => boolean;
}

const ACTIONS: ToolbarAction[] = [
  {
    label: '+列',
    title: '在右侧插入一列',
    run: (e) => e.chain().focus().addColumnAfter().run(),
    enabled: (e) => e.can().addColumnAfter(),
  },
  {
    label: '＋行',
    title: '在下方插入一行',
    run: (e) => e.chain().focus().addRowAfter().run(),
    enabled: (e) => e.can().addRowAfter(),
  },
  {
    label: '删列',
    title: '删除当前列',
    run: (e) => e.chain().focus().deleteColumn().run(),
    enabled: (e) => e.can().deleteColumn(),
  },
  {
    label: '删行',
    title: '删除当前行',
    run: (e) => e.chain().focus().deleteRow().run(),
    enabled: (e) => e.can().deleteRow(),
  },
  {
    label: '删表',
    title: '删除整个表格',
    run: (e) => e.chain().focus().deleteTable().run(),
    enabled: (e) => e.can().deleteTable(),
  },
];

export interface TableToolbarHandle {
  element: HTMLElement;
  /** Wire the toolbar to an editor: builds buttons, subscribes to selection
   *  changes, and manages show/hide + positioning. */
  attach(editor: Editor): void;
}

export function createTableToolbar(): TableToolbarHandle {
  const root = document.createElement('div');
  root.className = 'donemd-table-toolbar';
  root.style.visibility = 'hidden';
  root.style.position = 'fixed';

  const buttons: { el: HTMLButtonElement; action: ToolbarAction }[] = [];

  return {
    element: root,
    attach(editor) {
      for (const action of ACTIONS) {
        const el = document.createElement('button');
        el.type = 'button';
        el.className = 'donemd-table-toolbar__btn';
        el.textContent = action.label;
        el.title = action.title;
        el.setAttribute('aria-label', action.title);
        // Keep the editor selection intact: mousedown inside the toolbar must
        // not blur the editor (which would collapse the caret out of the cell
        // and disable the command before click fires).
        el.addEventListener('mousedown', (ev) => ev.preventDefault());
        el.addEventListener('click', (ev) => {
          ev.preventDefault();
          if (!action.enabled(editor)) return;
          action.run(editor);
          // The command moved the doc; re-place against the (possibly resized)
          // table on the next frame.
          requestAnimationFrame(() => reposition(editor));
        });
        buttons.push({ el, action });
        root.appendChild(el);
      }
      document.body.appendChild(root);

      const inTable = (): boolean =>
        editor.isActive('tableCell') || editor.isActive('tableHeader');

      const hide = (): void => {
        root.style.visibility = 'hidden';
      };

      const reposition = (ed: Editor): void => {
        if (!ed.isEditable || !inTable()) {
          hide();
          return;
        }
        // Find the DOM node of the enclosing <table> from the caret position.
        const domAt = ed.view.domAtPos(ed.state.selection.from);
        let node: Node | null = domAt.node;
        let tableEl: HTMLElement | null = null;
        while (node && node !== document.body) {
          if (node instanceof HTMLElement && node.tagName === 'TABLE') {
            tableEl = node;
            break;
          }
          node = node.parentNode;
        }
        if (!tableEl) {
          hide();
          return;
        }
        // Refresh enabled/disabled state before measuring (width may change).
        for (const b of buttons) {
          b.el.disabled = !b.action.enabled(ed);
        }
        root.style.visibility = 'hidden';
        // Measure after making it laid-out (visibility:hidden still lays out).
        const tableRect = tableEl.getBoundingClientRect();
        const barRect = root.getBoundingClientRect();
        // Anchor: top-right of the table, sitting just above it.
        let top = tableRect.top - barRect.height - 6;
        // If there's no room above (table at very top), tuck it just inside.
        if (top < 8) top = tableRect.top + 6;
        let left = tableRect.right - barRect.width;
        if (left < 8) left = 8;
        root.style.top = `${Math.round(top)}px`;
        root.style.left = `${Math.round(left)}px`;
        root.style.visibility = 'visible';
      };

      // Re-evaluate on every selection / document change.
      editor.on('selectionUpdate', () => reposition(editor));
      editor.on('transaction', () => reposition(editor));
      editor.on('blur', () => {
        // Hide unless focus moved into the toolbar itself (a button click).
        window.setTimeout(() => {
          if (!root.contains(document.activeElement)) hide();
        }, 0);
      });

      // Keep it glued to the table while the page scrolls / resizes.
      window.addEventListener(
        'scroll',
        () => {
          if (root.style.visibility === 'visible') reposition(editor);
        },
        { passive: true, capture: true }
      );
      window.addEventListener('resize', () => {
        if (root.style.visibility === 'visible') reposition(editor);
      });
    },
  };
}
