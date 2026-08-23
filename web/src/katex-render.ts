import katex from 'katex';

/**
 * Shared KaTeX rendering for the inline / block math NodeViews (Phase 5 M2).
 *
 * KaTeX runs ONLY here, in the display layer — parse/serialize on the Swift
 * side stores the raw LaTeX verbatim, so a formula round-trips byte-for-byte
 * whether or not KaTeX can render it.
 *
 * `throwOnError: false` lets KaTeX draw a partial/red result for recoverable
 * errors; the surrounding try/catch mirrors the mermaid failure pattern
 * (red border + first error line + the raw LaTeX kept visible) for hard
 * throws, so the user can always read and fix the source.
 */
export interface MathRenderResult {
  html: string;
  error: string | null;
}

export function renderMath(latex: string, displayMode: boolean): MathRenderResult {
  try {
    const html = katex.renderToString(latex, {
      displayMode,
      throwOnError: false,
      errorColor: '#cc0000',
      output: 'htmlAndMathml',
    });
    return { html, error: null };
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    return { html: '', error: message.split('\n')[0]?.trim() || '公式渲染失败' };
  }
}

/**
 * Whether KaTeX considers this LaTeX broken. Distinct from `renderMath`'s
 * error field: the display path uses `throwOnError: false`, which for
 * recoverable errors (`\frac{1}{`, unbalanced braces, unknown commands)
 * returns a *partial* render with a red `katex-error` span rather than
 * throwing — so `renderMath(...).error` stays null even though the formula
 * is visibly wrong. To decide "is this broken" (for red-flagging in the
 * source pane, S9 M2) we re-run with `throwOnError: true`, which surfaces
 * those recoverable errors as throws. This is display-only; the raw LaTeX
 * still round-trips to disk verbatim regardless.
 */
export function isMathBroken(latex: string, displayMode: boolean): boolean {
  if (latex.length === 0) return false;
  try {
    katex.renderToString(latex, { displayMode, throwOnError: true });
    return false;
  } catch {
    return true;
  }
}
