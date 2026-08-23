import { describe, it, expect } from 'vitest';
import { isWholeTableRect, nextSelectAllStage } from './table-selection';

// Pure predicates behind the Feishu-style table selection. The ProseMirror
// wiring (CellSelection creation, deleteTable) is verified by hand on-device
// per project convention; here we lock the decision logic.

describe('isWholeTableRect', () => {
  it('is true when the rect spans the entire table', () => {
    // A 3×3 table selected corner-to-corner.
    expect(isWholeTableRect({ left: 0, top: 0, right: 3, bottom: 3 }, 3, 3)).toBe(true);
  });

  it('is false for a single cell', () => {
    expect(isWholeTableRect({ left: 1, top: 1, right: 2, bottom: 2 }, 3, 3)).toBe(false);
  });

  it('is false when only some columns are covered', () => {
    expect(isWholeTableRect({ left: 0, top: 0, right: 2, bottom: 3 }, 3, 3)).toBe(false);
  });

  it('is false when only some rows are covered', () => {
    expect(isWholeTableRect({ left: 0, top: 0, right: 3, bottom: 2 }, 3, 3)).toBe(false);
  });

  it('is false when the top-left corner is not included', () => {
    expect(isWholeTableRect({ left: 1, top: 0, right: 3, bottom: 3 }, 3, 3)).toBe(false);
  });
});

describe('nextSelectAllStage (progressive ⌘A)', () => {
  it('a caret / text selection in a cell → selects the cell', () => {
    expect(nextSelectAllStage(false, false)).toBe('cell');
  });

  it('a single-cell selection → escalates to the whole table', () => {
    expect(nextSelectAllStage(true, false)).toBe('table');
  });

  it('a whole-table selection → hands off to whole-document select', () => {
    expect(nextSelectAllStage(true, true)).toBe('doc');
  });

  it('drives the full cell → table → doc progression', () => {
    // 1st ⌘A from a caret.
    expect(nextSelectAllStage(false, false)).toBe('cell');
    // 2nd ⌘A, now a single-cell CellSelection.
    expect(nextSelectAllStage(true, false)).toBe('table');
    // 3rd ⌘A, now the whole-table CellSelection.
    expect(nextSelectAllStage(true, true)).toBe('doc');
  });
});
