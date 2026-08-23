/**
 * Shared pan/zoom for SVG-bearing containers — used by both the inline
 * mermaid render in MermaidCodeBlock and the modal preview in
 * MermaidEditDrawer (Slice 4b).
 *
 * Transform target lives inside the event-bound container so that:
 *   .container        ← receives wheel/mouse/click events
 *     .panTarget      ← gets `transform: translate() scale()` applied
 *       <svg>         ← rendered diagram (replaceable on re-render)
 *
 * Replacing the SVG inside panTarget preserves the current transform —
 * which matches user expectation: editing the source via the drawer and
 * coming back shouldn't snap zoom/pan to identity unless the user
 * double-clicks.
 *
 * Click vs drag: tracked by a 3px movement threshold. Single click only
 * fires `onClick` if no drag occurred. Click is also delayed 220ms so a
 * double-click can cancel it (otherwise opening the drawer would race
 * with reset). 220ms is a touch above the standard browser dblclick
 * window so we rarely miss a real double-click.
 */

export interface PanZoomOptions {
  /** Fired on a single click (not after drag, not on dblclick). */
  onClick?: (event: MouseEvent) => void;
  /** Min scale (default 0.25). */
  minScale?: number;
  /** Max scale (default 4). */
  maxScale?: number;
  /**
   * When true, a mousedown anywhere outside the container snaps the diagram
   * back to fit (identity transform) — but only if it's currently zoomed or
   * panned. Lets the inline mermaid block treat zoom/pan as a transient
   * "inspect" gesture: click away and it re-fits the frame automatically.
   * The modal drawer preview leaves this off.
   */
  resetOnOutsideClick?: boolean;
}

export interface PanZoomHandle {
  detach: () => void;
  reset: () => void;
}

const DRAG_THRESHOLD_PX = 3;
const CLICK_DELAY_MS = 220;
const ZOOM_STEP = 1.1;

export function attachPanZoom(
  container: HTMLElement,
  panTarget: HTMLElement,
  opts: PanZoomOptions = {},
): PanZoomHandle {
  const minScale = opts.minScale ?? 0.25;
  const maxScale = opts.maxScale ?? 4;

  let scale = 1;
  let tx = 0;
  let ty = 0;

  let dragging = false;
  let didDrag = false;
  let dragStartX = 0;
  let dragStartY = 0;
  let panStartX = 0;
  let panStartY = 0;

  let pendingClickTimer: number | null = null;

  const apply = (): void => {
    panTarget.style.transform = `translate(${tx}px, ${ty}px) scale(${scale})`;
  };

  const reset = (): void => {
    scale = 1;
    tx = 0;
    ty = 0;
    apply();
  };

  // True when the diagram is no longer at its fit-the-frame baseline.
  const isTransformed = (): boolean => scale !== 1 || tx !== 0 || ty !== 0;

  apply();

  const onWheel = (e: WheelEvent): void => {
    // Trap scroll inside the diagram so the document doesn't scroll past
    // it while the user zooms.
    e.preventDefault();
    const factor = e.deltaY < 0 ? ZOOM_STEP : 1 / ZOOM_STEP;
    const next = Math.max(minScale, Math.min(maxScale, scale * factor));
    if (next === scale) return;
    scale = next;
    apply();
  };

  const onMouseDown = (e: MouseEvent): void => {
    if (e.button !== 0) return;
    dragging = true;
    didDrag = false;
    dragStartX = e.clientX;
    dragStartY = e.clientY;
    panStartX = tx;
    panStartY = ty;
    container.classList.add('is-grabbing');
  };

  const onMouseMove = (e: MouseEvent): void => {
    if (!dragging) return;
    const dx = e.clientX - dragStartX;
    const dy = e.clientY - dragStartY;
    if (!didDrag && Math.abs(dx) + Math.abs(dy) > DRAG_THRESHOLD_PX) {
      didDrag = true;
    }
    if (didDrag) {
      tx = panStartX + dx;
      ty = panStartY + dy;
      apply();
    }
  };

  const onMouseUp = (): void => {
    if (!dragging) return;
    dragging = false;
    container.classList.remove('is-grabbing');
  };

  const onClick = (e: MouseEvent): void => {
    if (didDrag) {
      // The click that follows a drag should be swallowed — the user was
      // panning, not selecting.
      didDrag = false;
      return;
    }
    if (pendingClickTimer !== null) return;
    pendingClickTimer = window.setTimeout(() => {
      pendingClickTimer = null;
      opts.onClick?.(e);
    }, CLICK_DELAY_MS);
  };

  const onDblClick = (): void => {
    // Cancel the deferred single-click — a double-click means the user
    // wanted to reset, not to invoke the click handler.
    if (pendingClickTimer !== null) {
      clearTimeout(pendingClickTimer);
      pendingClickTimer = null;
    }
    reset();
  };

  // Outside-click auto-fit: pressing anywhere outside the diagram snaps it
  // back to fit-the-frame, so zoom/pan behaves like a transient "inspect"
  // gesture. Only fires when actually transformed (so a plain click in the
  // document never runs a no-op reset), and never while the user is
  // mid-drag with the cursor happening to be outside the frame.
  const onOutsidePointerDown = (e: MouseEvent): void => {
    if (dragging) return;
    if (!isTransformed()) return;
    if (container.contains(e.target as Node)) return;
    reset();
  };

  container.addEventListener('wheel', onWheel, { passive: false });
  container.addEventListener('mousedown', onMouseDown);
  // mousemove/mouseup on window so dragging keeps working when the
  // cursor leaves the diagram while panning.
  window.addEventListener('mousemove', onMouseMove);
  window.addEventListener('mouseup', onMouseUp);
  container.addEventListener('click', onClick);
  container.addEventListener('dblclick', onDblClick);
  // Capture phase so we re-fit before the click lands elsewhere (e.g. moves
  // the caret into another paragraph) — the reset itself has no bearing on
  // that click, it just restores the diagram's resting size.
  if (opts.resetOnOutsideClick) {
    document.addEventListener('mousedown', onOutsidePointerDown, true);
  }

  return {
    detach: () => {
      container.removeEventListener('wheel', onWheel);
      container.removeEventListener('mousedown', onMouseDown);
      window.removeEventListener('mousemove', onMouseMove);
      window.removeEventListener('mouseup', onMouseUp);
      container.removeEventListener('click', onClick);
      container.removeEventListener('dblclick', onDblClick);
      if (opts.resetOnOutsideClick) {
        document.removeEventListener('mousedown', onOutsidePointerDown, true);
      }
      if (pendingClickTimer !== null) clearTimeout(pendingClickTimer);
    },
    reset,
  };
}
