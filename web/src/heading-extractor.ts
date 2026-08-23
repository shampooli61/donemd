// HeadingExtractor (M5) — the pure data source for the 文档大纲 sidebar
// (#78) and, later, scrollspy / jump alignment (#79).
//
// Input is a ProseMirror doc JSON object (the shape `editor.getJSON()`
// returns: `{ type: 'doc', content: [...] }`). Output is a flat list of
// headings in document order. Kept deliberately free of any Tiptap /
// ProseMirror runtime dependency so it's a plain, unit-testable function:
// feed it a hand-written doc literal, assert on the array.
//
// Why `index` and not a ProseMirror `pos`: the outline is anchored by
// "the Nth heading", not by pixel row — normalization reflow and block
// height differences must not affect alignment (CONTEXT.md §文档大纲, and
// the S7/#79 jump-alignment contract). The ordinal also gives every row a
// stable unique id even when two headings share the same text.

/** One heading in the document outline. */
export interface OutlineHeading {
  /** Heading level 1–6 (from the node's `attrs.level`). */
  level: number;
  /** Plain text of the heading — inline formatting (bold/link/…) stripped. */
  text: string;
  /** 0-based ordinal in document order. Doubles as a stable unique id. */
  index: number;
  /** `String(index)` — a stable list id even for duplicate heading text. */
  id: string;
}

/** A minimal structural view of a ProseMirror doc-JSON node. */
interface DocNode {
  type?: string;
  attrs?: Record<string, unknown> | null;
  content?: unknown;
  text?: unknown;
}

/** Depth-first concatenation of every descendant text node's `text`. This
 *  flattens inline formatting: a heading like `**Bold** and [link](x)`
 *  yields "Bold and link". */
function collectText(node: DocNode): string {
  let out = '';
  if (typeof node.text === 'string') out += node.text;
  const children = node.content;
  if (Array.isArray(children)) {
    for (const child of children) {
      if (child && typeof child === 'object') {
        out += collectText(child as DocNode);
      }
    }
  }
  return out;
}

/**
 * Extract all headings from a ProseMirror doc-JSON object, in document
 * order. Recurses through the whole tree so headings nested inside other
 * blocks (e.g. a callout — `callout.ts` allows heading content) are found
 * too. Non-object / empty / heading-free input returns `[]`.
 */
export function extractHeadings(doc: unknown): OutlineHeading[] {
  const headings: OutlineHeading[] = [];

  const walk = (node: DocNode): void => {
    if (node.type === 'heading') {
      const rawLevel = node.attrs?.level;
      const level = typeof rawLevel === 'number' ? rawLevel : 1;
      const index = headings.length;
      headings.push({
        level,
        text: collectText(node).trim(),
        index,
        id: String(index),
      });
      // Headings don't nest inside headings; no need to recurse further in.
      return;
    }
    const children = node.content;
    if (Array.isArray(children)) {
      for (const child of children) {
        if (child && typeof child === 'object') {
          walk(child as DocNode);
        }
      }
    }
  };

  if (doc && typeof doc === 'object') {
    walk(doc as DocNode);
  }
  return headings;
}
