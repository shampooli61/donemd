import { Extension } from '@tiptap/core';
import type { Editor } from '@tiptap/core';
import {
  CellSelection,
  selectionCell,
  selectedRect,
  isInTable,
} from '@tiptap/pm/tables';

/**
 * 表格整块选中与删除 (Table whole-block selection & deletion) — Feishu-style.
 *
 * Two behaviors the default prosemirror-tables keymap doesn't give us:
 *
 *  1. Progressive ⌘/Ctrl+A: inside a cell, the 1st press selects the current
 *     cell (a single-cell CellSelection), the 2nd selects the whole table
 *     (a full-rect CellSelection), and a 3rd falls through to the editor's
 *     default whole-document select. Outside a table this extension is inert
 *     (returns false), so ⌘A still selects the whole doc as usual.
 *
 *  2. Delete/Backspace on a whole-table CellSelection deletes the entire table
 *     (`deleteTable`, the same command the 表格工具条 "删表" button runs). A
 *     partial CellSelection falls through to the default, which just clears the
 *     selected cells' content — behavior unchanged.
 *
 * Combined, ⌘A ⌘A Delete removes a table entirely from the keyboard, and a
 * mouse marquee across every cell + Delete does the same.
 */

/** True when a table Rect covers the whole table (top-left to bottom-right). */
export function isWholeTableRect(
  rect: { left: number; top: number; right: number; bottom: number },
  width: number,
  height: number,
): boolean {
  return rect.left === 0 && rect.top === 0 && rect.right === width && rect.bottom === height;
}

export type SelectAllStage = 'cell' | 'table' | 'doc';

/**
 * The next stage of progressive ⌘A given what's selected now. Pure so it can be
 * unit-tested without a ProseMirror instance:
 *  - not a cell selection (caret / text in a cell)  → select the cell
 *  - a cell selection that isn't the whole table    → select the whole table
 *  - already the whole table                        → hand off to whole-doc
 */
export function nextSelectAllStage(isCellSelection: boolean, isWholeTable: boolean): SelectAllStage {
  if (!isCellSelection) return 'cell';
  return isWholeTable ? 'doc' : 'table';
}

/** Select just the cell the caret is in, as a single-cell CellSelection. */
function selectCurrentCell(editor: Editor): boolean {
  return editor.commands.command(({ state, dispatch, tr }) => {
    const $cell = selectionCell(state);
    if (!$cell) return false;
    if (dispatch) {
      dispatch(tr.setSelection(CellSelection.create(state.doc, $cell.pos)));
    }
    return true;
  });
}

/** Select every cell of the current table (top-left cell → bottom-right cell). */
function selectWholeTable(editor: Editor): boolean {
  return editor.commands.command(({ state, dispatch, tr }) => {
    const { map, tableStart } = selectedRect(state);
    const cells = map.map;
    if (cells.length === 0) return false;
    const first = tableStart + cells[0];
    const last = tableStart + cells[cells.length - 1];
    if (dispatch) {
      dispatch(tr.setSelection(CellSelection.create(state.doc, first, last)));
    }
    return true;
  });
}

export const DonemdTableSelection = Extension.create({
  name: 'donemdTableSelection',

  addKeyboardShortcuts() {
    // Delete the whole table only when the selection is the full-table rect;
    // otherwise let the default handle it (clears the selected cells).
    const deleteWholeTableIfSelected = (): boolean => {
      const { state } = this.editor;
      if (!isInTable(state)) return false;
      if (!(state.selection instanceof CellSelection)) return false;
      const rect = selectedRect(state);
      if (!isWholeTableRect(rect, rect.map.width, rect.map.height)) return false;
      return this.editor.commands.deleteTable();
    };

    return {
      'Mod-a': () => {
        const { state } = this.editor;
        if (!isInTable(state)) return false; // outside a table → default whole-doc
        const isCell = state.selection instanceof CellSelection;
        const isWhole =
          isCell &&
          (() => {
            const rect = selectedRect(state);
            return isWholeTableRect(rect, rect.map.width, rect.map.height);
          })();
        const stage = nextSelectAllStage(isCell, isWhole);
        if (stage === 'doc') return false; // hand off to default select-all
        if (stage === 'table') return selectWholeTable(this.editor);
        return selectCurrentCell(this.editor);
      },
      Backspace: deleteWholeTableIfSelected,
      Delete: deleteWholeTableIfSelected,
    };
  },
});
