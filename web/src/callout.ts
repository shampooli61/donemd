import { Node, mergeAttributes } from '@tiptap/core';
import { NodeSelection } from '@tiptap/pm/state';
import type { ResolvedPos } from '@tiptap/pm/model';

/**
 * GitHub callout — `> [!TYPE]\n> body` source form, rendered in the Visual
 * 视图 as a colored card with an icon. 5 types, each mapped to a SF
 * Symbol-style inline SVG + Feishu-aligned background palette (PRD §
 * 飞书 callout 类型映射表).
 *
 * Schema constraint: callout body may only contain paragraphs, lists,
 * and nested blockquotes. Pasting a code block / table / image / hr
 * inside is rejected by ProseMirror's content expression — this is the
 * Phase 2 hard limit (Feishu callout's own restriction, see CONTEXT.md
 * 高亮块 entry).
 *
 * Disk format is locked at the engine layer (ASTConverter / Serializer):
 * always uppercase `[!TYPE]`. The NodeView only deals with rendering and
 * type switching — switching to a new type updates `attrs.type` and the
 * serializer emits the correct uppercase token on next save.
 */

export const CALLOUT_TYPES = ['note', 'tip', 'important', 'warning', 'caution'] as const;
export type CalloutType = (typeof CALLOUT_TYPES)[number];

const TYPE_LABELS: Record<CalloutType, string> = {
  note: '说明',
  tip: '提示',
  important: '重要',
  warning: '警告',
  caution: '危险',
};

const ICONS: Record<CalloutType, string> = {
  note:
    '<svg viewBox="0 0 16 16" width="16" height="16" aria-hidden="true">'
    + '<path fill="currentColor" d="M8 1.5a6.5 6.5 0 1 0 0 13 6.5 6.5 0 0 0 0-13zM7 4.75a1 1 0 1 1 2 0 1 1 0 0 1-2 0zm.75 2.5a.75.75 0 0 0 0 1.5h.25v3h-.25a.75.75 0 0 0 0 1.5h2a.75.75 0 0 0 0-1.5h-.25V8a.75.75 0 0 0-.75-.75h-1z"/>'
    + '</svg>',
  tip:
    '<svg viewBox="0 0 16 16" width="16" height="16" aria-hidden="true">'
    + '<path fill="currentColor" d="M8 1.5a4.5 4.5 0 0 0-2.85 7.99c.32.26.6.66.6 1.13v.13c0 .55.45 1 1 1h2.5c.55 0 1-.45 1-1v-.13c0-.47.28-.87.6-1.13A4.5 4.5 0 0 0 8 1.5zM6.25 12.5a.75.75 0 0 0 0 1.5h3.5a.75.75 0 0 0 0-1.5h-3.5z"/>'
    + '</svg>',
  important:
    '<svg viewBox="0 0 16 16" width="16" height="16" aria-hidden="true">'
    + '<path fill="currentColor" d="M8 1.5a6.5 6.5 0 1 0 0 13 6.5 6.5 0 0 0 0-13zM8 4a.75.75 0 0 1 .75.75v3.5a.75.75 0 0 1-1.5 0v-3.5A.75.75 0 0 1 8 4zm0 8a1 1 0 1 1 0-2 1 1 0 0 1 0 2z"/>'
    + '</svg>',
  warning:
    '<svg viewBox="0 0 16 16" width="16" height="16" aria-hidden="true">'
    + '<path fill="currentColor" d="M6.86 1.96a1.3 1.3 0 0 1 2.28 0l5.69 10.27a1.3 1.3 0 0 1-1.14 1.93H2.31a1.3 1.3 0 0 1-1.14-1.93L6.86 1.96zM8 5.5a.75.75 0 0 0-.75.75v3.5a.75.75 0 0 0 1.5 0v-3.5A.75.75 0 0 0 8 5.5zm0 7a1 1 0 1 0 0-2 1 1 0 0 0 0 2z"/>'
    + '</svg>',
  caution:
    '<svg viewBox="0 0 16 16" width="16" height="16" aria-hidden="true">'
    + '<path fill="currentColor" d="M5.05 1.5a1 1 0 0 0-.71.3L1.8 4.34a1 1 0 0 0-.3.7v5.92a1 1 0 0 0 .3.71l2.54 2.54a1 1 0 0 0 .71.3h5.92a1 1 0 0 0 .71-.3l2.54-2.54a1 1 0 0 0 .3-.71V5.04a1 1 0 0 0-.3-.71L11.66 1.8a1 1 0 0 0-.71-.3H5.05zM5.78 5.78a.75.75 0 0 1 1.06 0L8 6.94l1.16-1.16a.75.75 0 1 1 1.06 1.06L9.06 8l1.16 1.16a.75.75 0 0 1-1.06 1.06L8 9.06l-1.16 1.16a.75.75 0 0 1-1.06-1.06L6.94 8 5.78 6.84a.75.75 0 0 1 0-1.06z"/>'
    + '</svg>',
};

function isCalloutType(value: unknown): value is CalloutType {
  return typeof value === 'string' && (CALLOUT_TYPES as readonly string[]).includes(value);
}

interface PickerHost {
  anchor: HTMLElement;
  current: CalloutType;
  onPick: (next: CalloutType) => void;
}

let activePicker: HTMLElement | null = null;
let activeOutsideHandler: ((e: MouseEvent) => void) | null = null;

function dismissPicker(): void {
  if (activePicker) {
    activePicker.remove();
    activePicker = null;
  }
  if (activeOutsideHandler) {
    document.removeEventListener('mousedown', activeOutsideHandler, true);
    activeOutsideHandler = null;
  }
}

function showPicker(host: PickerHost): void {
  dismissPicker();

  const picker = document.createElement('div');
  picker.className = 'donemd-callout-picker';
  picker.setAttribute('role', 'menu');

  for (const type of CALLOUT_TYPES) {
    const btn = document.createElement('button');
    btn.type = 'button';
    btn.className = `donemd-callout-picker__item donemd-callout-picker__item--${type}`;
    if (type === host.current) {
      btn.classList.add('is-current');
    }
    btn.setAttribute('data-callout-type', type);
    btn.setAttribute('role', 'menuitem');
    btn.setAttribute('aria-label', TYPE_LABELS[type]);
    btn.title = TYPE_LABELS[type];
    btn.innerHTML = ICONS[type];

    btn.addEventListener('mousedown', (e) => {
      // mousedown rather than click — the outside handler runs on mousedown
      // capture and would dismiss the picker before click fires.
      e.preventDefault();
      e.stopPropagation();
      host.onPick(type);
      dismissPicker();
    });

    picker.appendChild(btn);
  }

  document.body.appendChild(picker);

  // Position below the anchor, aligned to its left edge. Flip up if it
  // would overflow the viewport's bottom.
  const rect = host.anchor.getBoundingClientRect();
  const pickerRect = picker.getBoundingClientRect();
  const margin = 4;
  let top = rect.bottom + margin;
  if (top + pickerRect.height > window.innerHeight - 8) {
    top = rect.top - margin - pickerRect.height;
  }
  let left = rect.left;
  if (left + pickerRect.width > window.innerWidth - 8) {
    left = window.innerWidth - 8 - pickerRect.width;
  }
  picker.style.top = `${Math.max(8, top)}px`;
  picker.style.left = `${Math.max(8, left)}px`;

  activePicker = picker;
  activeOutsideHandler = (e: MouseEvent) => {
    if (picker.contains(e.target as Node)) return;
    dismissPicker();
  };
  // Capture phase so we beat the editor's own handlers.
  document.addEventListener('mousedown', activeOutsideHandler, true);
}

/**
 * Depth of the nearest `callout` ancestor of a resolved position, or -1 if the
 * position isn't inside a callout. Used by the Backspace/Delete handlers to
 * locate the callout node to select or remove.
 */
function calloutDepth($pos: ResolvedPos): number {
  for (let d = $pos.depth; d >= 0; d--) {
    if ($pos.node(d).type.name === 'callout') return d;
  }
  return -1;
}

export type CalloutBackspaceAction = 'delete-empty' | 'select-block' | 'default';

/**
 * Feishu two-stage backspace inside a callout, as a pure decision (unit-tested
 * without ProseMirror):
 *  - callout is empty (only an empty paragraph left)  → delete the whole block
 *    (matches "把文字都删除之后再删一下，整块删除")
 *  - caret at the very start of a non-empty callout    → select the whole block;
 *    the *next* backspace then deletes it via the default deleteSelection
 *    (matches "退到开头再退一次 → 先全选整块，再删连文字整块删除")
 *  - otherwise                                         → default backspace
 */
export function calloutBackspaceAction(isEmpty: boolean, atStart: boolean): CalloutBackspaceAction {
  if (isEmpty) return 'delete-empty';
  if (atStart) return 'select-block';
  return 'default';
}

/**
 * Forward Delete inside a callout: only steps in to remove an already-empty
 * callout (symmetry with backspace's "delete emptied block" path); non-empty
 * content deletes normally.
 */
export function calloutDeleteEmptied(isEmpty: boolean): boolean {
  return isEmpty;
}

export const Callout = Node.create({
  name: 'callout',
  group: 'block',
  // Schema constraint locked by PRD § Tiptap schema: callout body is
  // restricted to text-flow blocks + headings. Pasting a code block /
  // table / image / hr is rejected by ProseMirror's content expression
  // at edit time. Heading is allowed because Feishu callout accepts
  // h1-h6 as children (verified via feishu-mcp-pro syntax doc).
  content: '(paragraph | heading | bulletList | orderedList | blockquote)+',
  defining: true,
  // Treat callout as a structural boundary: selections can't cross it
  // and lift/clearNodes can't escape it. Without this, clicking 清除
  // (or Cmd+\) inside the callout body unwraps the callout itself, and
  // pressing Enter on an empty list item lifts past the callout instead
  // of stopping at a plain paragraph inside the card.
  isolating: true,

  addKeyboardShortcuts() {
    return {
      // `isolating: true` makes ProseMirror's default Enter→splitListItem
      // unable to lift an empty list item across the callout boundary; the
      // command silently fails and the empty item collapses back into the
      // previous one. Intercept that exact case and lift the empty item to
      // a plain paragraph at the callout's content level — what every
      // editor does on "double Enter to exit list".
      Enter: () => {
        const { state } = this.editor;
        const { selection } = state;
        if (!selection.empty) return false;
        const { $from } = selection;

        let inCallout = false;
        let listItemDepth = -1;
        let listItemTypeName: string | null = null;
        for (let d = $from.depth; d >= 0; d--) {
          const node = $from.node(d);
          if (node.type.name === 'callout') {
            inCallout = true;
            break;
          }
          if (
            (node.type.name === 'listItem' || node.type.name === 'taskItem')
            && listItemDepth < 0
          ) {
            listItemDepth = d;
            listItemTypeName = node.type.name;
          }
        }
        if (!inCallout || listItemDepth < 0 || !listItemTypeName) return false;

        const item = $from.node(listItemDepth);
        // Only intervene on truly empty items (single empty paragraph).
        if (item.textContent.length > 0) return false;

        return this.editor.commands.liftListItem(listItemTypeName);
      },

      // Feishu two-stage callout deletion via Backspace. `isolating: true`
      // blocks the default joinBackward from crossing the callout boundary, so
      // without this a backspace at the start of a callout does nothing. See
      // `calloutBackspaceAction` for the decision table.
      Backspace: () => {
        const { state } = this.editor;
        const { selection } = state;
        if (!selection.empty) return false;
        const { $from } = selection;
        const dCallout = calloutDepth($from);
        if (dCallout < 0) return false;

        const calloutNode = $from.node(dCallout);
        const calloutPos = $from.before(dCallout);
        // Caret sits at the very start of the callout iff it's at offset 0 of
        // its textblock AND that textblock is the callout's first child (its
        // start coincides with the callout's content start). A caret at the
        // start of a *nested* block (2nd paragraph, a list item) fails this and
        // falls through to the default backspace, which joins within the block.
        const atStart =
          $from.parentOffset === 0 && $from.before($from.depth) === $from.start(dCallout);

        const action = calloutBackspaceAction(calloutNode.textContent.length === 0, atStart);
        if (action === 'delete-empty') {
          return this.editor.commands.deleteRange({
            from: calloutPos,
            to: calloutPos + calloutNode.nodeSize,
          });
        }
        if (action === 'select-block') {
          return this.editor.commands.command(({ tr, dispatch }) => {
            if (dispatch) dispatch(tr.setSelection(NodeSelection.create(tr.doc, calloutPos)));
            return true;
          });
        }
        return false;
      },

      // Forward Delete symmetry: once the callout's text is emptied, one more
      // Delete removes the whole block. Non-empty content deletes normally.
      Delete: () => {
        const { state } = this.editor;
        const { selection } = state;
        if (!selection.empty) return false;
        const { $from } = selection;
        const dCallout = calloutDepth($from);
        if (dCallout < 0) return false;

        const calloutNode = $from.node(dCallout);
        if (!calloutDeleteEmptied(calloutNode.textContent.length === 0)) return false;
        const calloutPos = $from.before(dCallout);
        return this.editor.commands.deleteRange({
          from: calloutPos,
          to: calloutPos + calloutNode.nodeSize,
        });
      },
    };
  },

  addAttributes() {
    return {
      type: {
        default: 'note' as CalloutType,
        parseHTML: (element) => {
          const value = element.getAttribute('data-callout');
          return isCalloutType(value) ? value : 'note';
        },
        renderHTML: (attrs) => ({ 'data-callout': attrs.type as string }),
      },
    };
  },

  parseHTML() {
    return [{ tag: 'div[data-callout]' }];
  },

  renderHTML({ HTMLAttributes, node }) {
    const type = isCalloutType(node.attrs.type) ? node.attrs.type : 'note';
    return [
      'div',
      mergeAttributes(HTMLAttributes, {
        class: `donemd-callout donemd-callout--${type}`,
      }),
      0,
    ];
  },

  addNodeView() {
    return ({ node, getPos, editor }) => {
      const dom = document.createElement('div');
      const initialType = isCalloutType(node.attrs.type) ? node.attrs.type : 'note';
      dom.className = `donemd-callout donemd-callout--${initialType}`;
      dom.setAttribute('data-callout', initialType);

      const iconBtn = document.createElement('button');
      iconBtn.type = 'button';
      iconBtn.className = 'donemd-callout__icon';
      iconBtn.setAttribute('aria-label', '切换 callout 类型');
      iconBtn.setAttribute('contenteditable', 'false');
      iconBtn.innerHTML = ICONS[initialType];

      const contentEl = document.createElement('div');
      contentEl.className = 'donemd-callout__content';

      dom.appendChild(iconBtn);
      dom.appendChild(contentEl);

      const switchType = (next: CalloutType): void => {
        const pos = typeof getPos === 'function' ? getPos() : null;
        if (pos === null || pos === undefined) return;
        editor
          .chain()
          .focus()
          .command(({ tr }) => {
            tr.setNodeAttribute(pos, 'type', next);
            return true;
          })
          .run();
      };

      iconBtn.addEventListener('mousedown', (e) => {
        // Prevent ProseMirror from grabbing focus / starting a selection.
        e.preventDefault();
        e.stopPropagation();
      });

      iconBtn.addEventListener('click', (e) => {
        e.preventDefault();
        e.stopPropagation();
        const currentType = isCalloutType(node.attrs.type) ? node.attrs.type : 'note';
        showPicker({
          anchor: iconBtn,
          current: currentType,
          onPick: switchType,
        });
      });

      dom.addEventListener('contextmenu', (e) => {
        e.preventDefault();
        e.stopPropagation();
        const currentType = isCalloutType(node.attrs.type) ? node.attrs.type : 'note';
        // Synthesize a 1×1 anchor at the cursor so the picker pops where
        // the user actually clicked rather than next to the icon.
        const cursorAnchor = document.createElement('div');
        cursorAnchor.style.position = 'fixed';
        cursorAnchor.style.left = `${e.clientX}px`;
        cursorAnchor.style.top = `${e.clientY}px`;
        cursorAnchor.style.width = '1px';
        cursorAnchor.style.height = '1px';
        cursorAnchor.style.pointerEvents = 'none';
        document.body.appendChild(cursorAnchor);
        showPicker({
          anchor: cursorAnchor,
          current: currentType,
          onPick: switchType,
        });
        // Picker positions itself synchronously off the anchor's rect, so
        // we can drop it now — picker is already placed.
        cursorAnchor.remove();
      });

      return {
        dom,
        contentDOM: contentEl,
        update: (updatedNode) => {
          if (updatedNode.type.name !== 'callout') return false;
          const next = isCalloutType(updatedNode.attrs.type) ? updatedNode.attrs.type : 'note';
          dom.className = `donemd-callout donemd-callout--${next}`;
          dom.setAttribute('data-callout', next);
          iconBtn.innerHTML = ICONS[next];
          return true;
        },
        destroy: () => {
          dismissPicker();
        },
        // Type-switch attribute changes happen on the wrapper, not on the
        // editable content — tell ProseMirror to ignore mutations there
        // so they don't re-trigger a NodeView rebuild.
        ignoreMutation: (mutation) => {
          if (mutation.type === 'selection') return false;
          return !contentEl.contains(mutation.target as Node);
        },
      };
    };
  },
});
