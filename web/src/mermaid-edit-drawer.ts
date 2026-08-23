import { EditorView, basicSetup } from 'codemirror';
import { EditorState } from '@codemirror/state';
import { keymap } from '@codemirror/view';
import mermaid from 'mermaid';
import { attachPanZoom, type PanZoomHandle } from './pan-zoom';
import { syncMermaidTheme } from './mermaid-codeblock';

/**
 * MermaidEditDrawer — Slice 4b modal for editing a single mermaid block.
 *
 * Layout matches mermaid.live: CodeMirror left, live SVG right with a
 * 300ms debounce. Done / Cmd+S commits via `onCommit(text)`; Esc / × /
 * overlay-click closes (with a confirm if the source has been edited).
 *
 * Mermaid rendering reuses the same `mermaid.parse` + `mermaid.render`
 * path as MermaidCodeBlock so a syntax error in the drawer paints the
 * same red-bordered fallback the user already recognizes from the
 * inline view.
 */

let drawerIdCounter = 0;
const nextDrawerRenderId = (): string => `donemd-mermaid-drawer-${++drawerIdCounter}`;

const RENDER_DEBOUNCE_MS = 300;

export interface MermaidDrawerOptions {
  initialSource: string;
  onCommit: (newSource: string) => void;
  /** Called after the drawer is fully torn down. Optional. */
  onClose?: () => void;
}

interface DrawerHandle {
  close: (skipDirtyCheck?: boolean) => void;
}

let activeDrawer: DrawerHandle | null = null;

export function openMermaidEditDrawer(opts: MermaidDrawerOptions): void {
  // Only one drawer at a time. If the user somehow triggers another
  // open, snap the previous one shut without committing.
  if (activeDrawer) {
    activeDrawer.close(true);
  }

  const overlay = document.createElement('div');
  overlay.className = 'donemd-mermaid-drawer-overlay';

  const modal = document.createElement('div');
  modal.className = 'donemd-mermaid-drawer';
  overlay.appendChild(modal);

  // --- Header
  const header = document.createElement('div');
  header.className = 'donemd-mermaid-drawer__header';
  const title = document.createElement('div');
  title.className = 'donemd-mermaid-drawer__title';
  title.textContent = 'Mermaid 编辑';
  const actions = document.createElement('div');
  actions.className = 'donemd-mermaid-drawer__actions';
  const doneBtn = document.createElement('button');
  doneBtn.className = 'donemd-mermaid-drawer__btn donemd-mermaid-drawer__btn--primary';
  doneBtn.type = 'button';
  doneBtn.textContent = '完成';
  const closeBtn = document.createElement('button');
  closeBtn.className = 'donemd-mermaid-drawer__btn donemd-mermaid-drawer__btn--icon';
  closeBtn.type = 'button';
  closeBtn.setAttribute('aria-label', '关闭');
  closeBtn.textContent = '×';
  actions.appendChild(doneBtn);
  actions.appendChild(closeBtn);
  header.appendChild(title);
  header.appendChild(actions);
  modal.appendChild(header);

  // --- Body: left CodeMirror, right preview
  const body = document.createElement('div');
  body.className = 'donemd-mermaid-drawer__body';
  modal.appendChild(body);

  const codePane = document.createElement('div');
  codePane.className = 'donemd-mermaid-drawer__code';
  body.appendChild(codePane);

  const previewPane = document.createElement('div');
  previewPane.className = 'donemd-mermaid-drawer__preview';
  body.appendChild(previewPane);

  const previewTarget = document.createElement('div');
  previewTarget.className = 'donemd-mermaid-drawer__preview-target';
  previewPane.appendChild(previewTarget);

  document.body.appendChild(overlay);

  // --- CodeMirror
  // Cmd+S commits without bubbling to the host page (where it would
  // trigger Done.md's Save).
  const commitKeymap = keymap.of([
    {
      key: 'Mod-s',
      run: () => {
        commitAndClose();
        return true;
      },
    },
    {
      key: 'Escape',
      run: () => {
        attemptClose();
        return true;
      },
    },
  ]);

  const cmView = new EditorView({
    parent: codePane,
    state: EditorState.create({
      doc: opts.initialSource,
      extensions: [
        basicSetup,
        EditorView.lineWrapping,
        commitKeymap,
        // Re-render on every doc change with a 300ms tail.
        EditorView.updateListener.of((u) => {
          if (u.docChanged) {
            scheduleRender();
          }
        }),
      ],
    }),
  });

  // Auto-focus + select-all so the user can immediately retype if they
  // wanted to scrap the diagram.
  queueMicrotask(() => {
    cmView.focus();
    cmView.dispatch({ selection: { anchor: 0, head: cmView.state.doc.length } });
  });

  // --- Live preview
  const renderId = nextDrawerRenderId();
  let renderTimer: number | null = null;

  const clearError = (): void => {
    previewPane.classList.remove('is-error');
  };

  const showError = (message: string): void => {
    // Error class sits on previewPane (not previewTarget) so it isn't
    // affected by pan/zoom transforms — same shape as the inline view.
    previewPane.classList.add('is-error');
    previewTarget.innerHTML = '';
    const head = document.createElement('div');
    head.className = 'donemd-mermaid__error-line';
    head.textContent = message.split('\n')[0]?.trim() || '渲染失败';
    previewTarget.appendChild(head);
  };

  const renderNow = async (): Promise<void> => {
    const text = cmView.state.doc.toString();
    const trimmed = text.trim();
    if (trimmed.length === 0) {
      clearError();
      previewTarget.innerHTML = '<div class="donemd-mermaid__empty">空 mermaid 块</div>';
      return;
    }
    try {
      await mermaid.parse(trimmed);
      syncMermaidTheme(); // match diagram theme to the writing background
      const { svg } = await mermaid.render(renderId, trimmed);
      // Bail if the user kept typing while we were rendering — the next
      // tick's render call will catch up against the latest source.
      if (cmView.state.doc.toString() !== text) return;
      clearError();
      previewTarget.innerHTML = svg;
    } catch (err) {
      if (cmView.state.doc.toString() !== text) return;
      const msg = err instanceof Error ? err.message : String(err);
      showError(msg);
    }
  };

  const scheduleRender = (): void => {
    if (renderTimer !== null) {
      clearTimeout(renderTimer);
    }
    renderTimer = window.setTimeout(() => {
      renderTimer = null;
      void renderNow();
    }, RENDER_DEBOUNCE_MS);
  };

  // First paint without debounce so the preview is populated immediately.
  void renderNow();

  // --- Pan/zoom on the preview (no onClick — clicking the preview
  // shouldn't open another drawer-in-drawer).
  const panZoom: PanZoomHandle = attachPanZoom(previewPane, previewTarget);

  // --- Close logic
  let closed = false;
  const teardown = (): void => {
    if (closed) return;
    closed = true;
    if (renderTimer !== null) clearTimeout(renderTimer);
    panZoom.detach();
    cmView.destroy();
    overlay.remove();
    document.removeEventListener('keydown', onKeyDown, true);
    if (activeDrawer && activeDrawer.close === close) {
      activeDrawer = null;
    }
    opts.onClose?.();
  };

  const isDirty = (): boolean => cmView.state.doc.toString() !== opts.initialSource;

  const close = (skipDirtyCheck?: boolean): void => {
    if (!skipDirtyCheck && isDirty()) {
      // window.confirm is OK for a dialog inside an already-modal context;
      // a custom popover would be polish for Phase 5.
      const ok = window.confirm('未保存的改动会丢失，确定关闭吗？');
      if (!ok) return;
    }
    teardown();
  };

  const attemptClose = (): void => close();

  const commitAndClose = (): void => {
    const text = cmView.state.doc.toString();
    if (text !== opts.initialSource) {
      opts.onCommit(text);
    }
    teardown();
  };

  doneBtn.addEventListener('click', commitAndClose);
  closeBtn.addEventListener('click', attemptClose);

  // Click on the dim overlay (outside the modal box) closes too.
  overlay.addEventListener('mousedown', (e) => {
    if (e.target === overlay) attemptClose();
  });

  const onKeyDown = (e: KeyboardEvent): void => {
    if (e.key === 'Escape') {
      // CodeMirror swallows Escape via the keymap above when CM has
      // focus; this captures the case where focus moved to e.g. the
      // Done button.
      e.preventDefault();
      attemptClose();
      return;
    }
    if ((e.metaKey || e.ctrlKey) && e.key === 's') {
      // Same — capture Cmd+S when focus is outside CodeMirror so the
      // host page's save shortcut doesn't fire instead.
      e.preventDefault();
      e.stopPropagation();
      commitAndClose();
    }
  };
  document.addEventListener('keydown', onKeyDown, true);

  activeDrawer = { close };
}
