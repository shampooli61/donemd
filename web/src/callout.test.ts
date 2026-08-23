import { describe, it, expect } from 'vitest';
import { calloutBackspaceAction, calloutDeleteEmptied } from './callout';

// Pure decision tables behind the Feishu two-stage callout deletion. The
// ProseMirror wiring (NodeSelection promotion, deleteRange) is verified by hand
// on-device per project convention; here we lock the branch logic.

describe('calloutBackspaceAction', () => {
  it('empty callout → delete the whole block (skips the select stage)', () => {
    // isEmpty wins even if the caret is (trivially) at the start.
    expect(calloutBackspaceAction(true, true)).toBe('delete-empty');
    expect(calloutBackspaceAction(true, false)).toBe('delete-empty');
  });

  it('caret at start of a non-empty callout → select the whole block', () => {
    expect(calloutBackspaceAction(false, true)).toBe('select-block');
  });

  it('caret mid-content → default backspace', () => {
    expect(calloutBackspaceAction(false, false)).toBe('default');
  });

  it('models the two-stage flow: start → select, then next press deletes selection', () => {
    // 1st backspace at start of a non-empty callout selects the block…
    expect(calloutBackspaceAction(false, true)).toBe('select-block');
    // …the 2nd press runs against a NodeSelection (not an empty caret), so this
    // handler returns false at the `selection.empty` guard and the default
    // deleteSelection removes the block — no branch here handles it, by design.
  });
});

describe('calloutDeleteEmptied (forward Delete)', () => {
  it('removes an already-empty callout', () => {
    expect(calloutDeleteEmptied(true)).toBe(true);
  });

  it('leaves a non-empty callout to the default forward delete', () => {
    expect(calloutDeleteEmptied(false)).toBe(false);
  });
});
