import { describe, expect, it } from 'vitest';
import { EditorState } from '@codemirror/state';
import { minimalSourceChange } from './markdown-source-update';

describe('source mirror incremental updates', () => {
  it('does not replace an unchanged source', () => expect(minimalSourceChange('same', 'same')).toBeUndefined());
  it('keeps unchanged copy selection mapped around a small insertion', () => {
    const state = EditorState.create({ doc: '# Title\n\nselected text', selection: { anchor: 9, head: 17 } });
    const change = minimalSourceChange(state.doc.toString(), '# Title!\n\nselected text')!;
    expect(change).toEqual({ from: 7, to: 7, insert: '!' });
    const next = state.update({ changes: change }).state;
    expect(next.sliceDoc(next.selection.main.from, next.selection.main.to)).toBe('selected');
  });
  it('round trips inserts/deletions and surrogate changes without whole-document replacement', () => {
    for (const [before, after] of [['ab尾', 'a中b尾'], ['ab尾', 'a尾'], ['a😀z', 'a😁z'], ['', '# heading'], ['text', '']]) {
      const change = minimalSourceChange(before, after)!;
      expect(before.slice(0, change.from) + change.insert + before.slice(change.to)).toBe(after);
    }
  });
});
