import CodeBlockLowlight from '@tiptap/extension-code-block-lowlight';
import { common, createLowlight } from 'lowlight';
import mermaid from 'mermaid';
import { attachPanZoom, type PanZoomHandle } from './pan-zoom';

// Phase 5 M1 — syntax highlighting. lowlight paints tokens via a ProseMirror
// Decoration plugin (PM's own view.updateState), NOT by NodeView-authored DOM
// writes, so it coexists with the mermaid NodeView + `ignoreMutation` filter
// below without re-triggering the WebKit rebuild loop (see ignoreMutation doc).
//
// `common` (~37 grammars) already covers our target set incl. swift; only
// `html` needs an alias onto the `xml` grammar. Unknown languages fall back to
// plain text silently (no throw) — auto-detection stays OFF so a mislabeled
// fence never gets re-colored as some other language. Highlight is display-only:
// the `language` attr and disk round-trip are untouched.
const lowlight = createLowlight(common);
lowlight.registerAlias('xml', 'html');

/**
 * Mermaid-aware code block. Same Tiptap node as Tiptap's standard
 * `codeBlock` (so disk format is unchanged — ` ```mermaid ` fence stays
 * as-is, and parse/serialize don't go through any new node type), but
 * the NodeView paints the rendered SVG in place of the source for
 * `language === "mermaid"`.
 *
 * Slice 4b (Phase 2): the rendered diagram supports inline pan/zoom
 * (wheel = scale 0.25–4×, drag = pan, double-click = reset) so the user
 * can read big flowcharts without leaving the document. Single-click on
 * the diagram opens the **Mermaid 编辑抽屉** ([[mermaid-编辑抽屉]]) — a
 * modal with CodeMirror left + live preview right that writes the new
 * source back into this codeBlock node when the user hits 完成 / Cmd+S.
 *
 * Non-mermaid code blocks render exactly like before — the wrapper
 * shows only the inner `<pre><code>` source.
 *
 * Error state: when mermaid.parse rejects the source we paint the
 * render container red-bordered with the first error line + "点击编辑"
 * hint. Click still opens the drawer so the user can fix the syntax in
 * the same place that already showed them what's broken.
 */

const MERMAID_FONT =
  '-apple-system, BlinkMacSystemFont, "SF Pro Text", "PingFang SC", sans-serif';

mermaid.initialize({
  startOnLoad: false,
  // Strict-mode is the default but spelling it out: no inline
  // <script>/<foreignObject> escape hatch from rendered SVG. Sources are
  // user-authored, but they often paste from chat tools / docs, and we
  // never want a rogue `<script>` to execute inside the editor's CSP.
  securityLevel: 'strict',
  theme: 'default',
  // Mermaid's font defaults to the page font; the editor uses SF Pro,
  // which renders narrow text well at the diagram's small label sizes.
  fontFamily: MERMAID_FONT,
});

/**
 * Pick the mermaid theme for the current writing background (#80 S8) and
 * re-initialize mermaid with it. Mermaid config is global and only applies at
 * render time, so callers MUST invoke this right before `mermaid.render` — for
 * both the inline code block and the edit drawer preview.
 *
 * - 赛博夜色 (data-theme="night") → blue-leaning dark palette
 * - 纸质 (data-theme="paper")     → 'neutral' (warm-neutral, no cold blue nodes)
 * - 跟随系统 dark                 → a muted dark palette on the #15171A canvas
 *   (mermaid's stock 'dark' theme has bright grey nodes that "jump" against the
 *   deep background — we darken node fills to sit calmly on it)
 * - 跟随系统 light / 纸质          → 'default' / 'neutral'
 */
export function syncMermaidTheme(): void {
  const attr = document.documentElement.dataset.theme;

  // 赛博夜色: a blue-leaning dark diagram theme. Built on mermaid's 'base'
  // theme with custom themeVariables (dark's palette is neutral-grey; we push
  // backgrounds/nodes/lines toward the same deep blue family as the canvas).
  if (attr === 'night') {
    mermaid.initialize({
      startOnLoad: false,
      securityLevel: 'strict',
      fontFamily: MERMAID_FONT,
      theme: 'base',
      themeVariables: {
        darkMode: true,
        background: '#12171F',
        primaryColor: '#1c2c47',        // node fill — deep blue
        primaryBorderColor: '#3a5680',  // node border — steel blue
        primaryTextColor: '#c9d8ec',    // node text — pale blue
        secondaryColor: '#22344f',
        tertiaryColor: '#182338',
        lineColor: '#5c7aa6',           // edges — muted blue
        textColor: '#b8c8e0',           // labels — cool light blue
        mainBkg: '#1c2c47',
        clusterBkg: '#161f30',
        clusterBorder: '#33496e',
        nodeBorder: '#3a5680',
        titleColor: '#cddcf0',
        edgeLabelBackground: '#12171F',
      },
    });
    return;
  }

  if (attr === 'paper') {
    mermaid.initialize({
      startOnLoad: false,
      securityLevel: 'strict',
      theme: 'neutral',
      fontFamily: MERMAID_FONT,
    });
    return;
  }

  // 跟随系统: light = stock 'default'. Dark = a muted charcoal palette so the
  // diagram sits calmly on the #15171A canvas (stock 'dark' nodes are too
  // bright and read as jumpy). Neutral grey, not tinted — matches the neutral
  // github-dark chrome of code blocks.
  const prefersDark =
    window.matchMedia?.('(prefers-color-scheme: dark)').matches ?? false;
  if (prefersDark) {
    mermaid.initialize({
      startOnLoad: false,
      securityLevel: 'strict',
      fontFamily: MERMAID_FONT,
      theme: 'base',
      themeVariables: {
        darkMode: true,
        background: '#15171A',
        primaryColor: '#242830',        // node fill — muted charcoal
        primaryBorderColor: '#454b57',  // node border — soft grey
        primaryTextColor: '#c9d1d9',    // node text — light grey
        secondaryColor: '#2b3039',
        tertiaryColor: '#1c1f25',
        lineColor: '#6b7280',           // edges — mid grey
        textColor: '#c9d1d9',
        mainBkg: '#242830',
        clusterBkg: '#1a1d22',
        clusterBorder: '#3a3f48',
        nodeBorder: '#454b57',
        titleColor: '#e0e4ea',
        edgeLabelBackground: '#15171A',
      },
    });
    return;
  }

  mermaid.initialize({
    startOnLoad: false,
    securityLevel: 'strict',
    theme: 'default',
    fontFamily: MERMAID_FONT,
  });
}

let mermaidIdCounter = 0;
const nextMermaidId = (): string => `donemd-mermaid-${++mermaidIdCounter}`;

/**
 * Registry of live mermaid re-render callbacks (#80 S8). Mermaid bakes theme
 * colors into the SVG at render time, so an already-rendered diagram doesn't
 * change when the writing theme switches. On theme change we call every
 * registered callback to repaint. Exposed on `window` so the Swift theme
 * broadcast (VisualWebView) can trigger it right after flipping data-theme.
 */
const mermaidRerenderers = new Set<() => void>();
export function rerenderAllMermaid(): void {
  mermaidRerenderers.forEach((fn) => {
    try {
      fn();
    } catch (err) {
      console.warn('[mermaid] re-render failed:', err);
    }
  });
}
// Global hook for the Swift bridge: window.__donemdRerenderMermaid().
(window as unknown as { __donemdRerenderMermaid?: () => void })
  .__donemdRerenderMermaid = rerenderAllMermaid;

// Repaint on system light/dark flip (#80 S8). Under 跟随系统 (data-theme unset),
// switching macOS appearance re-tints all the CSS via media queries, but
// mermaid bakes theme colors into the SVG at render time — so without this the
// diagram keeps its old (light) colors on the now-dark canvas. This path never
// goes through the Swift theme broadcast (writingTheme stays .system), so we
// listen for the media-query change directly in the page.
window
  .matchMedia?.('(prefers-color-scheme: dark)')
  .addEventListener('change', () => {
    // Only 跟随系统 depends on the OS appearance; paper/night are fixed.
    if (!document.documentElement.dataset.theme) rerenderAllMermaid();
  });

// The drawer pulls in CodeMirror; load it lazily on first open so editor
// boot doesn't block on it, and so a drawer-module init error can't take
// down the whole editor mount. Cached after first successful load.
type DrawerModule = typeof import('./mermaid-edit-drawer');
let drawerModuleP: Promise<DrawerModule | null> | null = null;
const loadDrawerModule = (): Promise<DrawerModule | null> => {
  if (drawerModuleP === null) {
    drawerModuleP = import('./mermaid-edit-drawer').catch((err) => {
      console.warn('[mermaid] edit drawer module failed to load:', err);
      return null;
    });
  }
  return drawerModuleP;
};

declare module '@tiptap/core' {
  interface Commands<ReturnType> {
    mermaidCodeBlock: {
      /**
       * Toggle a code block, but merge a multi-textblock selection into a
       * SINGLE code block (joined by "\n") instead of one block per paragraph.
       */
      setMergedCodeBlock: () => ReturnType;
    };
  }
}

export const MermaidCodeBlock = CodeBlockLowlight.extend({
  // Bake the lowlight instance into the default options so main.ts can keep
  // using `MermaidCodeBlock` bare (no `.configure({ lowlight })` needed).
  addOptions() {
    return {
      ...this.parent?.(),
      lowlight,
    };
  },
  addCommands() {
    return {
      ...this.parent?.(),
      // Merge-aware code block toggle for the selection bubble menu.
      //
      // Tiptap's stock `toggleCodeBlock` runs `setBlockType` over the range,
      // which flips *each* paragraph the selection touches into its own
      // codeBlock — so wrapping 5 lines yields 5 separate blocks. Users expect
      // a multi-line selection to land in ONE code block (matching Notion /
      // Typora). When the selection spans more than one textblock we collect
      // their text, join with "\n", and replace the whole range with a single
      // codeBlock node. Single-block selections fall through to the stock
      // behavior. Toggling OFF is made symmetric: a merged code block splits
      // back into one paragraph PER line (by "\n"), not a single paragraph
      // with embedded newlines — otherwise the un-merged "paragraph" would be
      // one giant block, and re-selecting a single visual line would wrap the
      // whole thing again.
      setMergedCodeBlock:
        () =>
        ({ editor, state, chain, commands }) => {
          if (editor.isActive(this.name)) {
            // Already a code block → split it back into per-line paragraphs.
            const { $from } = state.selection;
            // Walk up to the enclosing codeBlock node (the selection may sit at
            // any inline offset inside it).
            let depth = $from.depth;
            while (depth > 0 && $from.node(depth).type.name !== this.name) {
              depth -= 1;
            }
            const codeNode = $from.node(depth);
            if (depth === 0 || codeNode.type.name !== this.name) {
              // Defensive: not actually inside our node — stock toggle.
              return commands.toggleCodeBlock();
            }

            const paraType = state.schema.nodes.paragraph;
            if (!paraType) return commands.toggleCodeBlock();

            const blockStart = $from.before(depth);
            const blockEnd = $from.after(depth);
            const lines = codeNode.textContent.split('\n');
            const paragraphs = lines.map((line) =>
              paraType.create(null, line.length ? state.schema.text(line) : null),
            );

            return chain()
              .focus()
              .command(({ tr, dispatch }) => {
                if (dispatch) {
                  tr.replaceWith(blockStart, blockEnd, paragraphs);
                }
                return true;
              })
              .run();
          }

          const { from, to } = state.selection;

          // Count the textblocks the selection actually spans.
          const blockTexts: string[] = [];
          state.doc.nodesBetween(from, to, (node) => {
            if (node.isTextblock) {
              blockTexts.push(node.textContent);
              return false; // don't descend into inline content
            }
            return true;
          });

          if (blockTexts.length <= 1) {
            // Single paragraph (or empty selection): stock toggle is correct.
            return commands.toggleCodeBlock();
          }

          const codeType = state.schema.nodes[this.name];
          if (!codeType) return false;

          // schema.text('') throws, so only attach a text node when non-empty.
          const joined = blockTexts.join('\n');
          const codeBlock = codeType.create(
            null,
            joined.length ? state.schema.text(joined) : null,
          );

          return chain()
            .focus()
            .command(({ tr, dispatch }) => {
              if (dispatch) {
                tr.replaceRangeWith(from, to, codeBlock);
              }
              return true;
            })
            .run();
        },
    };
  },
  addKeyboardShortcuts() {
    // Route the code-block shortcut through the merge-aware command too, so
    // Cmd+Option+C on a multi-line selection also yields one block (matching
    // the bubble menu). Keep any other inherited shortcuts intact.
    return {
      ...this.parent?.(),
      'Mod-Alt-c': () => this.editor.commands.setMergedCodeBlock(),
    };
  },
  addNodeView() {
    return ({ node, getPos, editor }) => {
      const dom = document.createElement('div');
      dom.className = 'donemd-codeblock';

      const source = document.createElement('pre');
      source.className = 'donemd-codeblock__source';
      const code = document.createElement('code');
      source.appendChild(code);
      dom.appendChild(source);

      // Copy button (Phase 5 M1). Sibling of `source`, child of `dom` — never
      // inside `code` (contentDOM), so its class/text toggles are mutations
      // *outside* code → `!code.contains(target)` ignores them, no rebuild
      // loop. contenteditable=false marks it non-content (like the render div);
      // mousedown preventDefault keeps the caret/selection from jumping when
      // the user clicks it.
      const copyBtn = document.createElement('button');
      copyBtn.className = 'donemd-codeblock__copy';
      copyBtn.setAttribute('contenteditable', 'false');
      copyBtn.type = 'button';
      copyBtn.title = '复制代码';
      const copyDefaultLabel = '复制';
      copyBtn.textContent = copyDefaultLabel;
      dom.appendChild(copyBtn);

      let copyResetTimer: number | null = null;
      copyBtn.addEventListener('mousedown', (e) => e.preventDefault());
      copyBtn.addEventListener('click', () => {
        const text = code.textContent ?? '';
        const flashCopied = (): void => {
          copyBtn.classList.add('is-copied');
          copyBtn.textContent = '已复制';
          if (copyResetTimer !== null) window.clearTimeout(copyResetTimer);
          copyResetTimer = window.setTimeout(() => {
            copyBtn.classList.remove('is-copied');
            copyBtn.textContent = copyDefaultLabel;
            copyResetTimer = null;
          }, 1200);
        };
        // Prefer the async Clipboard API (WKWebView grants writeText on a user
        // gesture without a prompt); fall back to execCommand for older WebKit
        // or when the promise rejects.
        const fallbackCopy = (): void => {
          try {
            const ta = document.createElement('textarea');
            ta.value = text;
            ta.style.position = 'fixed';
            ta.style.opacity = '0';
            document.body.appendChild(ta);
            ta.select();
            document.execCommand('copy');
            document.body.removeChild(ta);
            flashCopied();
          } catch (err) {
            console.warn('[codeblock] copy failed:', err);
          }
        };
        if (navigator.clipboard?.writeText) {
          navigator.clipboard.writeText(text).then(flashCopied, fallbackCopy);
        } else {
          fallbackCopy();
        }
      });

      // Render container is the event surface for pan/zoom + click.
      // panTarget receives the CSS transform so wheel/drag don't fight
      // ProseMirror's selection inside the source <pre>.
      const render = document.createElement('div');
      render.className = 'donemd-mermaid__render';
      render.setAttribute('contenteditable', 'false');
      render.style.display = 'none';
      dom.appendChild(render);

      const panTarget = document.createElement('div');
      panTarget.className = 'donemd-mermaid__pan-target';
      render.appendChild(panTarget);

      // Error UI lives outside panTarget so zoom/pan transforms don't
      // distort the message.
      const errorBox = document.createElement('div');
      errorBox.className = 'donemd-mermaid__error-box';
      errorBox.style.display = 'none';
      const errorHead = document.createElement('div');
      errorHead.className = 'donemd-mermaid__error-line';
      const errorHint = document.createElement('span');
      errorHint.className = 'donemd-mermaid__hint';
      errorHint.textContent = '点击编辑';
      errorBox.appendChild(errorHead);
      errorBox.appendChild(errorHint);
      render.appendChild(errorBox);

      let currentLang: string | null = null;
      let lastRenderedSource: string | null = null;
      let panZoom: PanZoomHandle | null = null;
      const renderId = nextMermaidId();

      const writeBackSource = (newSource: string): void => {
        try {
          if (typeof getPos !== 'function') {
            console.warn('[mermaid] writeBack: getPos not function');
            return;
          }
          const pos = getPos();
          if (typeof pos !== 'number' || pos < 0) {
            console.warn('[mermaid] writeBack: invalid pos', pos);
            return;
          }
          const { state } = editor;
          const target = state.doc.nodeAt(pos);
          if (!target) {
            console.warn('[mermaid] writeBack: no node at pos', pos);
            return;
          }
          const from = pos + 1;
          const to = pos + target.nodeSize - 1;
          const tr = state.tr;
          if (newSource.length > 0) {
            tr.replaceWith(from, to, state.schema.text(newSource));
          } else {
            tr.delete(from, to);
          }
          editor.view.dispatch(tr);
        } catch (err) {
          console.error('[mermaid] writeBack failed:', err);
        }
      };

      const openDrawer = (): void => {
        void loadDrawerModule().then((mod) => {
          if (!mod) return;
          mod.openMermaidEditDrawer({
            initialSource: code.textContent ?? '',
            onCommit: writeBackSource,
          });
        });
      };

      const showError = (message: string): void => {
        render.classList.add('is-error');
        // Mermaid errors are often verbose — show the first line so the
        // user gets the immediate cause without the diagram dumping its
        // whole stack inline.
        errorHead.textContent = message.split('\n')[0]?.trim() || '渲染失败';
        errorBox.style.display = '';
        panTarget.style.display = 'none';
      };

      const clearError = (): void => {
        render.classList.remove('is-error');
        errorBox.style.display = 'none';
        panTarget.style.display = '';
      };

      const renderMermaid = async (text: string): Promise<void> => {
        const trimmed = text.trim();
        // Track the source up-front so concurrent transactions don't
        // re-trigger us against the same input.
        lastRenderedSource = text;
        if (trimmed.length === 0) {
          clearError();
          panTarget.innerHTML = '<div class="donemd-mermaid__empty">空 mermaid 块</div>';
          return;
        }
        try {
          // parse first — gives a clean syntax-error path before render()
          // mounts anything (and before mermaid logs to console).
          await mermaid.parse(trimmed);
          syncMermaidTheme(); // match diagram theme to the writing background
          const { svg } = await mermaid.render(renderId, trimmed);
          // Source could've changed while the async render was in flight;
          // skip stale paints.
          if ((code.textContent ?? '') !== text) return;
          clearError();
          // Replacing innerHTML on panTarget keeps the current pan/zoom
          // transform intact (it's on panTarget itself, not the SVG), so
          // re-rendering after a drawer commit doesn't snap to identity.
          panTarget.innerHTML = svg;
        } catch (err) {
          if ((code.textContent ?? '') !== text) return;
          const msg = err instanceof Error ? err.message : String(err);
          showError(msg);
        }
      };

      const applyLanguage = (lang: string | null): void => {
        currentLang = lang;
        // Stable safe-token for the language class name.
        const safe = lang && /^[a-zA-Z0-9_-]+$/.test(lang) ? lang : null;
        code.className = safe ? `language-${safe}` : '';
        if (safe === 'mermaid') {
          dom.setAttribute('data-mermaid', '');
          // Rendered mermaid shows no source, so there's nothing to copy.
          copyBtn.style.display = 'none';
          // Hide the source pre and show the render container. The pre
          // stays in the DOM (display:none) so ProseMirror's contentDOM
          // tracking keeps working — text changes still propagate, the
          // user just can't put a caret into the hidden `<code>`.
          source.style.display = 'none';
          render.style.display = '';
          if (panZoom === null) {
            panZoom = attachPanZoom(render, panTarget, {
              onClick: openDrawer,
              // Treat zoom/pan as a transient inspect gesture: clicking any
              // blank area outside the diagram re-fits it to the frame.
              resetOnOutsideClick: true,
            });
          }
          // Register for theme-switch repaint (force re-render even though the
          // source is unchanged, since only the theme moved).
          mermaidRerenderers.add(rerender);
          void renderMermaid(code.textContent ?? '');
        } else {
          dom.removeAttribute('data-mermaid');
          mermaidRerenderers.delete(rerender);
          if (panZoom !== null) {
            panZoom.detach();
            panZoom = null;
          }
          render.style.display = 'none';
          panTarget.innerHTML = '';
          source.style.display = '';
          copyBtn.style.display = '';
          lastRenderedSource = null;
        }
      };

      // Theme-switch repaint: re-render current source ignoring the
      // same-source guard (the source didn't change, the theme did).
      const rerender = (): void => {
        lastRenderedSource = null;
        void renderMermaid(code.textContent ?? '');
      };

      // Defer one tick so contentDOM is populated by ProseMirror before
      // we read code.textContent for the first render.
      queueMicrotask(() => {
        applyLanguage((node.attrs.language as string | null) ?? null);
      });

      return {
        dom,
        contentDOM: code,
        update: (updatedNode) => {
          if (updatedNode.type.name !== 'codeBlock') return false;
          const nextLang = (updatedNode.attrs.language as string | null) ?? null;
          if (nextLang !== currentLang) {
            applyLanguage(nextLang);
            return true;
          }
          // Source text changed (drawer commit, paste replace, etc.) →
          // re-render. Read from the *new node* — at this point in PM's
          // update flow `code.textContent` is still the OLD text (PM
          // syncs contentDOM AFTER nodeView.update returns true). The
          // node argument is already the post-transaction value.
          if (currentLang === 'mermaid') {
            const text = updatedNode.textContent;
            if (text !== lastRenderedSource) {
              void renderMermaid(text);
            }
          }
          return true;
        },
        destroy: () => {
          mermaidRerenderers.delete(rerender);
          if (panZoom !== null) {
            panZoom.detach();
            panZoom = null;
          }
          if (copyResetTimer !== null) {
            window.clearTimeout(copyResetTimer);
            copyResetTimer = null;
          }
        },
        // ProseMirror's MutationObserver fires for every DOM change inside
        // dom — including ones the NodeView itself does (className,
        // style.display, innerHTML on the render sibling). Without
        // filtering, PM treats those as "the user/script edited the
        // content" and on macOS 26 / WebKit 26+ it leads to a NodeView
        // rebuild loop that crashes the renderer process. Rules:
        //   - selection mutations: PM normally never asks NodeView to
        //     ignore those (it routes them through its own selection
        //     system), but keep the explicit check for clarity.
        //   - attribute mutations (className/style/data-*): always ignore
        //     — those are NodeView-internal state, never content.
        //   - childList / characterData: only let through ones whose
        //     target is a *descendant* of `code`. `code.contains(code)` is
        //     true, but `code` itself can never be the target of a
        //     childList/characterData mutation (those fire on parents
        //     when children change, or on a text node when its data
        //     changes), so the descendant check works without a special
        //     case for `code` itself.
        ignoreMutation: (mutation) => {
          if (mutation.type === 'selection') return false;
          if (mutation.type === 'attributes') return true;
          return !code.contains(mutation.target as Node);
        },
      };
    };
  },
});
