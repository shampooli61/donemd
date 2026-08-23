import { EditorView, basicSetup } from 'codemirror';
import { Decoration } from '@codemirror/view';
import type { DecorationSet } from '@codemirror/view';
import { EditorState, StateField, StateEffect, Annotation } from '@codemirror/state';
import { markdown } from '@codemirror/lang-markdown';
import {
  HighlightStyle,
  syntaxHighlighting,
  codeFolding,
  foldService,
  foldEffect,
  unfoldEffect,
  foldedRanges,
} from '@codemirror/language';
import { tags as t } from '@lezer/highlight';
import './markdown-source.css';
import { on, send } from './bridge';

// Markdown syntax coloring for the source pane (Phase 5 S3 / #75). We assign
// CSS CLASS NAMES per lezer tag (not inline colors) so the actual palette
// lives in markdown-source.css and can follow the system theme via
// `prefers-color-scheme` — same approach as the Visual pane's hljs tokens.
// This overrides basicSetup's `defaultHighlightStyle` (a later
// syntaxHighlighting wins), which was light-only and washed out on dark.
const markdownHighlight = HighlightStyle.define([
  { tag: [t.heading, t.heading1, t.heading2, t.heading3, t.heading4, t.heading5, t.heading6], class: 'cmd-md-heading' },
  { tag: t.strong, class: 'cmd-md-strong' },
  { tag: t.emphasis, class: 'cmd-md-emphasis' },
  { tag: t.strikethrough, class: 'cmd-md-strike' },
  { tag: [t.link, t.url], class: 'cmd-md-link' },
  // Inline code + fenced code content both come through as monospace.
  { tag: [t.monospace], class: 'cmd-md-code' },
  { tag: t.quote, class: 'cmd-md-quote' },
  { tag: [t.list], class: 'cmd-md-list' },
  // The `#`, `*`, `>`, backticks, list bullets etc. — punctuation that marks
  // up the structure. Dimmed so the prose reads first.
  { tag: [t.processingInstruction, t.punctuation, t.meta], class: 'cmd-md-mark' },
]);

// Broken-formula red-flagging (S9 M2). The Visual pane runs KaTeX and ships
// the raw LaTeX of formulas it can't render; we match each verbatim against the
// document text and mark the ranges. This pane has no KaTeX and no `$`-parser,
// so it never decides validity itself — it only paints what Visual reports.
//
// A StateField holds the DecorationSet; a StateEffect carries the latest LaTeX
// list in. The field recomputes matches whenever the effect arrives OR the doc
// changes (a `setMarkdownSource` replace), so flags stay aligned after edits.
const setBadMath = StateEffect.define<string[]>();
const badMathMark = Decoration.mark({ class: 'cmd-md-math-error' });

function computeBadMathDecorations(doc: string, latexes: string[]): DecorationSet {
  if (latexes.length === 0) return Decoration.none;
  const ranges: ReturnType<typeof badMathMark.range>[] = [];
  for (const latex of latexes) {
    if (!latex) continue;
    // Every textual occurrence of this exact LaTeX is flagged: identical LaTeX
    // renders identically, so if one is broken they all are. Substring search
    // (not `$`-delimited) keeps us from duplicating Swift's recognition rules —
    // the LaTeX body is serialized verbatim inside `$…$` / `$$…$$`.
    let from = doc.indexOf(latex);
    while (from !== -1) {
      ranges.push(badMathMark.range(from, from + latex.length));
      from = doc.indexOf(latex, from + latex.length);
    }
  }
  // Decoration.set requires ascending order; matches from different needles can
  // interleave, so sort by start position.
  ranges.sort((a, b) => a.from - b.from);
  return Decoration.set(ranges, true);
}

let currentBadMath: string[] = [];
const badMathField = StateField.define<DecorationSet>({
  create() {
    return Decoration.none;
  },
  update(deco, tr) {
    for (const effect of tr.effects) {
      if (effect.is(setBadMath)) {
        currentBadMath = effect.value;
        return computeBadMathDecorations(tr.state.doc.toString(), currentBadMath);
      }
    }
    if (tr.docChanged) {
      // Doc was replaced (source refresh) — recompute against the new text.
      return computeBadMathDecorations(tr.state.doc.toString(), currentBadMath);
    }
    return deco.map(tr.changes);
  },
  provide: (f) => EditorView.decorations.from(f),
});

// --- 标题折叠 (heading fold) shared scan -------------------------------------
// One ATX heading found in the document, by the SAME rules the Visual pane and
// scrollToHeading use: column-0 `#{1,6} ` lines, skipping fenced code blocks.
// `ordinal` matches the Visual pane's top-level heading ordinal, so an applyFold
// broadcast keyed by ordinal folds the same section on both sides.
interface SourceHeading {
  ordinal: number;
  level: number;
  /** 1-based line number of the heading line. */
  lineNo: number;
}

function scanHeadings(doc: import('@codemirror/state').Text): SourceHeading[] {
  const out: SourceHeading[] = [];
  const headingRe = /^(#{1,6})\s/;
  let ordinal = 0;
  let inFence = false;
  for (let lineNo = 1; lineNo <= doc.lines; lineNo++) {
    const line = doc.line(lineNo);
    if (/^\s*(```|~~~)/.test(line.text)) {
      inFence = !inFence;
      continue;
    }
    if (inFence) continue;
    const m = headingRe.exec(line.text);
    if (m) {
      out.push({ ordinal, level: m[1].length, lineNo });
      ordinal += 1;
    }
  }
  return out;
}

// The fold region for the Nth heading: from the end of the heading line down to
// the end of the line *before* the next heading of same-or-higher level (or the
// document end). Returns null when the section is empty (nothing to fold) — the
// same "adjacent/trailing heading isn't foldable" rule as computeFoldRanges.
function foldRegionForOrdinal(
  doc: import('@codemirror/state').Text,
  ordinal: number
): { from: number; to: number } | null {
  const headings = scanHeadings(doc);
  const idx = headings.findIndex((h) => h.ordinal === ordinal);
  if (idx === -1) return null;
  const self = headings[idx];
  let endLineNo = doc.lines; // default: fold to end of document
  for (let j = idx + 1; j < headings.length; j++) {
    if (headings[j].level <= self.level) {
      endLineNo = headings[j].lineNo - 1; // last line of this section
      break;
    }
  }
  const headingLine = doc.line(self.lineNo);
  if (endLineNo <= self.lineNo) return null; // empty section — not foldable
  const endLine = doc.line(endLineNo);
  // Fold from just after the heading text to the end of the section, so the
  // heading line itself stays visible (CodeMirror hides [from, to)).
  return { from: headingLine.to, to: endLine.to };
}

// Distinguishes fold changes we apply in response to Swift's broadcast (which
// must NOT echo back out) from ones the user drives via the gutter (which must
// report to Swift). Tagged on the applying transaction; the update listener
// checks it before emitting `foldToggled`.
const fromSwift = Annotation.define<boolean>();

// A foldService so CodeMirror's gutter markers appear exactly on heading lines
// with a non-empty section — clicking one folds that heading's region. The
// service is asked per line; we answer only for heading lines.
const headingFoldService = foldService.of((state, lineStart, lineEnd) => {
  const doc = state.doc;
  const line = doc.lineAt(lineStart);
  if (line.to !== lineEnd) return null; // only judge whole-line requests
  const headings = scanHeadings(doc);
  const h = headings.find((x) => x.lineNo === line.number);
  if (!h) return null;
  return foldRegionForOrdinal(doc, h.ordinal);
});

// --- 飞书占位块折叠 (feishu placeholder fold) -------------------------------
// A `<!-- feishu-placeholder ... -->` comment carries sync metadata (block_id /
// block_token / url) a human reader never needs — ADR-0007 already keeps these
// off the Visual card. In the source pane we fold the whole comment into a
// one-line chip (「🖌️ 画板：架构图」) by default. The bytes on disk are
// untouched, so sync / round-trip / the "在飞书中编辑 ↗" jump are unaffected.
// The user can click a chip to expand the raw fields and re-fold via the gutter
// arrow. Purely a view-layer projection — never synced to Swift.

const PLACEHOLDER_OPENER = '<!-- feishu-placeholder';
const PLACEHOLDER_CLOSER = '-->';

// type → (icon, 中文名). Mirrors the placeholder subtypes in ADR-0007 /
// CONTEXT. An unknown type falls back to a generic block label so a future
// Feishu block type still folds cleanly instead of leaking its raw comment.
const PLACEHOLDER_LABELS: Record<string, { icon: string; name: string }> = {
  video: { icon: '🎬', name: '视频' },
  board: { icon: '🖌️', name: '画板' },
  sheet: { icon: '📊', name: '电子表格' },
  bitable: { icon: '🗂️', name: '多维表格' },
  mindnote: { icon: '🧠', name: '思维笔记' },
  attachment: { icon: '📎', name: '附件' },
  embed: { icon: '🔗', name: '第三方嵌入' },
};

function chipLabel(type: string, title: string): string {
  const meta = PLACEHOLDER_LABELS[type] ?? { icon: '📦', name: '飞书块' };
  return title ? `${meta.icon} ${meta.name}：${title}` : `${meta.icon} ${meta.name}`;
}

interface PlaceholderRange {
  from: number;
  to: number;
  type: string;
  title: string;
}

// Locate every placeholder comment block. Same opener/closer contract as
// FeishuPlaceholderEngine (each on its own line); `type` / `title` are read for
// the chip label only. This never validates the block — the Swift parser owns
// that — it just finds a foldable region and a display name.
function scanPlaceholders(doc: import('@codemirror/state').Text): PlaceholderRange[] {
  const out: PlaceholderRange[] = [];
  let openLineNo = 0;
  let type = '';
  let title = '';
  for (let lineNo = 1; lineNo <= doc.lines; lineNo++) {
    const text = doc.line(lineNo).text.trim();
    if (openLineNo === 0) {
      if (text === PLACEHOLDER_OPENER) {
        openLineNo = lineNo;
        type = '';
        title = '';
      }
      continue;
    }
    if (text === PLACEHOLDER_CLOSER) {
      out.push({
        from: doc.line(openLineNo).from,
        to: doc.line(lineNo).to,
        type,
        title,
      });
      openLineNo = 0;
      continue;
    }
    const colon = text.indexOf(':');
    if (colon !== -1) {
      const key = text.slice(0, colon).trim();
      const value = text.slice(colon + 1).trim();
      if (key === 'type') type = value;
      else if (key === 'title') title = value;
    }
  }
  return out;
}

// Fold-gutter arrow on a placeholder opener line, so a chip can be re-folded
// after the user expands it (same per-line foldService contract as headings).
const placeholderFoldService = foldService.of((state, lineStart, lineEnd) => {
  const doc = state.doc;
  const line = doc.lineAt(lineStart);
  if (line.to !== lineEnd) return null; // only judge whole-line requests
  if (line.text.trim() !== PLACEHOLDER_OPENER) return null;
  const p = scanPlaceholders(doc).find((r) => r.from === line.from);
  return p ? { from: p.from, to: p.to } : null;
});

const mountPoint = document.getElementById('source');
if (!mountPoint) {
  throw new Error('Markdown source mount point #source not found');
}

const view = new EditorView({
  parent: mountPoint,
  state: EditorState.create({
    doc: '',
    extensions: [
      basicSetup,
      markdown(),
      // Class-based Markdown coloring; added after basicSetup so it wins over
      // its bundled defaultHighlightStyle (#75).
      syntaxHighlighting(markdownHighlight),
      // Broken-formula red-flagging (S9 M2). Holds decorations for LaTeX the
      // Visual pane reported as unrenderable.
      badMathField,
      // 标题折叠 (heading fold): fold the region under a heading. codeFolding()
      // provides the fold state + hidden-range decorations; basicSetup already
      // installs ONE foldGutter() (a second, hand-added one produced a duplicate
      // arrow column), so we only supply headingFoldService to decide the
      // foldable region per heading line. Folds stay in lockstep with the Visual
      // pane via Swift.
      codeFolding({
        // Custom folded-region rendering. A feishu-placeholder block collapses
        // to a labeled chip; every other fold (heading sections) keeps the
        // default "…" via the existing .cm-foldPlaceholder styling.
        preparePlaceholder(state, range) {
          const line = state.doc.lineAt(range.from);
          // Heading folds start mid-line (after the heading text); placeholder
          // folds start at column 0 of the opener line. Cheap reject first.
          if (line.from !== range.from) return null;
          if (line.text.trim() !== PLACEHOLDER_OPENER) return null;
          const p = scanPlaceholders(state.doc).find((r) => r.from === range.from);
          return p ? { label: chipLabel(p.type, p.title) } : null;
        },
        placeholderDOM(_view, onclick, prepared) {
          const label = (prepared as { label?: string } | null)?.label;
          const span = document.createElement('span');
          if (label) {
            span.className = 'cmd-feishu-chip';
            span.textContent = label;
            span.title = '飞书占位块 · 点击展开源码';
          } else {
            // Default heading-fold placeholder — reuse the existing "…" look.
            span.className = 'cm-foldPlaceholder';
            span.textContent = '…';
            span.title = '展开';
          }
          span.setAttribute('aria-label', span.textContent);
          span.onclick = onclick;
          return span;
        },
      }),
      headingFoldService,
      placeholderFoldService,
      // Soft-wrap long lines to the pane width so users don't have to
      // horizontally scroll. CodeMirror's default is no-wrap.
      EditorView.lineWrapping,
      // Phase 1 the source pane is read-only; bidirectional sync is Phase 5.
      // (readOnly blocks TEXT edits, not fold gutter interaction — folding a
      // section is a view action and still works while the doc is read-only.)
      EditorState.readOnly.of(true),
      EditorView.editable.of(false),
      // Report user-driven folds/unfolds (gutter clicks) to Swift, which is the
      // single source of truth and re-broadcasts to both panes. Folds we apply
      // FROM Swift carry the `fromSwift` annotation and are skipped here, so no
      // A→Swift→B→Swift loop.
      EditorView.updateListener.of((update) => {
        for (const tr of update.transactions) {
          if (tr.annotation(fromSwift)) continue;
          for (const effect of tr.effects) {
            if (effect.is(foldEffect) || effect.is(unfoldEffect)) {
              const ordinal = ordinalForFoldLine(tr.startState.doc, effect.value.from);
              if (ordinal !== null) {
                send('foldToggled', { ordinal, collapse: effect.is(foldEffect) });
              }
            }
          }
        }
      }),
    ],
  }),
});

// Given the `from` position of a fold effect, find which heading ordinal it
// belongs to (the heading whose line contains or precedes `from`). Used to
// translate a gutter click back into the ordinal Swift speaks.
function ordinalForFoldLine(
  doc: import('@codemirror/state').Text,
  from: number
): number | null {
  const headingLineNo = doc.lineAt(from).number;
  const headings = scanHeadings(doc);
  // A fold region starts at the end of the heading line, so `from` sits on the
  // heading line itself.
  const h = headings.find((x) => x.lineNo === headingLineNo);
  return h ? h.ordinal : null;
}

// Fold every placeholder block into its chip. Called after each source refresh:
// the doc is fully replaced, so any prior folds are gone and must be re-applied.
// Placeholder folds start at column 0 of the opener line, so ordinalForFoldLine
// returns null for them — the updateListener never echoes these to Swift.
function foldPlaceholders() {
  const doc = view.state.doc;
  const ranges = scanPlaceholders(doc);
  if (ranges.length === 0) return;
  const already = new Set<number>();
  foldedRanges(view.state).between(0, doc.length, (from) => {
    already.add(from);
  });
  const effects = ranges
    .filter((r) => !already.has(r.from))
    .map((r) => foldEffect.of({ from: r.from, to: r.to }));
  if (effects.length > 0) view.dispatch({ effects });
}

// Inbound: Swift pushes the latest serialized Markdown after every Visual
// edit (and once at startup right after editorReady).
on('setMarkdownSource', (payload) => {
  const text =
    typeof payload === 'string'
      ? payload
      : ((payload as { text?: string }).text ?? '');
  // Replace the entire document. CodeMirror will diff internally and
  // preserve scroll position when the change is small.
  view.dispatch({
    changes: { from: 0, to: view.state.doc.length, insert: text },
  });
  // Re-fold placeholder blocks into chips (view.state already reflects the new
  // doc — dispatch is synchronous).
  foldPlaceholders();
});

// Broken-formula list from the Visual pane (S9 M2). Dispatch it as a StateEffect
// so the field recomputes decorations against the current document text. Order-
// independent vs setMarkdownSource: if the text arrives later, the field's
// docChanged branch re-matches using the cached list.
on('badMathFormulas', (payload) => {
  const raw = (payload as { latex?: unknown } | null)?.latex;
  const latexes = Array.isArray(raw)
    ? raw.filter((x): x is string => typeof x === 'string')
    : [];
  view.dispatch({ effects: setBadMath.of(latexes) });
});

// Outline jump (#79). Swift sends the ordinal of a clicked heading; scroll the
// Nth ATX heading line to the top of the viewport. Counting `#`-prefixed lines
// in document order matches HeadingExtractor's ordinal (fenced code blocks
// aside — headings the Visual pane recognizes are ATX lines here too). The
// source may be body-only (frontmatter hidden), but frontmatter has no `#`
// headings, so the ordinal still lines up.
on('scrollToHeading', (payload) => {
  const index = (payload as { index?: number } | null)?.index;
  if (typeof index !== 'number' || index < 0) return;

  // scanHeadings uses the same fence-aware `#`-line rules this handler used
  // before it was factored out (headings inside ``` / ~~~ are skipped, matching
  // the Visual parser).
  const doc = view.state.doc;
  const target = scanHeadings(doc).find((h) => h.ordinal === index);
  if (!target) return;
  const line = doc.line(target.lineNo);
  view.dispatch({
    selection: { anchor: line.from },
    effects: EditorView.scrollIntoView(line.from, { y: 'start' }),
  });
});

// 标题折叠 (heading fold): Swift broadcasts the authoritative set of collapsed
// heading ordinals. Diff it against what's currently folded here and dispatch
// the minimal fold/unfold effects — tagged `fromSwift` so the updateListener
// doesn't echo them back. This is the ONLY writer of fold state from outside,
// mirroring the Visual pane's applyFoldState (anti-loop invariant).
on('applyFold', (payload) => {
  const raw = (payload as { collapsed?: unknown } | null)?.collapsed;
  const wanted = new Set(
    Array.isArray(raw) ? raw.filter((x): x is number => typeof x === 'number') : []
  );
  const doc = view.state.doc;
  const headings = scanHeadings(doc);

  // Which ordinals are folded right now: match each existing folded range back
  // to the heading whose region starts at that range's `from`.
  // foldedRanges returns a RangeSet — iterate with .between(), not for...of.
  const current = new Set<number>();
  foldedRanges(view.state).between(0, doc.length, (from) => {
    const ord = ordinalForFoldLine(doc, from);
    if (ord !== null) current.add(ord);
  });

  const effects = [];
  // Fold newly-wanted ordinals.
  for (const h of headings) {
    if (wanted.has(h.ordinal) && !current.has(h.ordinal)) {
      const region = foldRegionForOrdinal(doc, h.ordinal);
      if (region) effects.push(foldEffect.of(region));
    }
    // Unfold ordinals no longer wanted.
    if (!wanted.has(h.ordinal) && current.has(h.ordinal)) {
      const region = foldRegionForOrdinal(doc, h.ordinal);
      if (region) effects.push(unfoldEffect.of(region));
    }
  }
  if (effects.length > 0) {
    view.dispatch({ effects, annotations: fromSwift.of(true) });
  }
});

// Outbound: tell Swift this pane's editor is ready to receive the initial
// Markdown source (Swift's handler then triggers the first push).
send('editorReady');
