/** A single minimal replacement maps CodeMirror selection and fold ranges around unchanged text. */
export function minimalSourceChange(before: string, after: string): { from: number; to: number; insert: string } | undefined {
  if (before === after) return undefined;
  let from = 0, endBefore = before.length, endAfter = after.length;
  while (from < endBefore && from < endAfter && before[from] === after[from]) from++;
  while (endBefore > from && endAfter > from && before[endBefore - 1] === after[endAfter - 1]) { endBefore--; endAfter--; }
  // Avoid cutting a UTF-16 pair in half (CodeMirror uses UTF-16 offsets).
  if (from > 0 && /[\uD800-\uDBFF]/.test(before[from - 1])) from--;
  return { from, to: endBefore, insert: after.slice(from, endAfter) };
}
