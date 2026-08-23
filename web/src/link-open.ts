// Single-click link following. Tiptap's Link extension runs with
// `openOnClick: false` (otherwise the WKWebView would try to navigate itself
// and blow away the document), so we take over the click: grab the href and
// hand it to Swift, which opens URLs in the default browser and local paths
// in their default app. Classification (URL vs local file) lives on the Swift
// side (see LinkTarget.swift) so the rule isn't duplicated in two languages —
// here we only decide *whether* a click should follow and *which* href.

/**
 * Given a click's target and its `detail` (click count), return the href to
 * follow, or null if the click should NOT trigger navigation.
 *
 *  - Only a true single click (`detail === 1`) follows a link. Double / triple
 *    clicks (`detail >= 2`) return null so ProseMirror's default word /
 *    paragraph selection still runs — that's how the user selects a link's
 *    display text to edit it.
 *  - The target must sit inside an `<a>` that carries a non-empty href.
 *
 * Duck-typed on `closest` / `getAttribute` rather than `instanceof Element` so
 * it stays unit-testable in the node (no-DOM) vitest environment.
 */
export function linkHrefFromClickTarget(target: unknown, detail: number): string | null {
  if (detail !== 1) return null;
  const el = target as {
    closest?: (selector: string) => { getAttribute(name: string): string | null } | null;
  } | null;
  if (!el || typeof el.closest !== 'function') return null;
  const anchor = el.closest('a');
  if (!anchor) return null;
  const href = anchor.getAttribute('href');
  return href && href.length > 0 ? href : null;
}
