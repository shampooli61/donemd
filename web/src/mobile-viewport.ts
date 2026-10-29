import type { Editor } from '@tiptap/core';

const GAP = 8;

/** Layout only: never focus, dispatch transactions or interfere with marked text. */
export function attachMobileViewport(editor: Editor, toolbar: HTMLElement) {
  const shell = document.querySelector('#mobile-viewport') as HTMLElement;
  const scroller = document.querySelector('#mobile-scroll') as HTMLElement;
  const reading = shell.querySelector('.mobile-reading') as HTMLElement;
  const viewport = window.visualViewport;
  let frame = 0;
  let destroyed = false;

  function revealCaret() {
    if (!editor.isEditable || !editor.view.hasFocus() || document.querySelector('dialog[open]')) return;
    const selection = window.getSelection();
    let rect: { top: number; bottom: number } | undefined;
    // During IME, the DOM selection tracks marked text ahead of editor state.
    if (selection?.focusNode && editor.view.dom.contains(selection.focusNode)) {
      const range = document.createRange();
      range.setStart(selection.focusNode, selection.focusOffset);
      range.collapse(true);
      rect = Array.from(range.getClientRects()).find(r => r.height > 0);
    }
    if (!rect) {
      try { rect = editor.view.coordsAtPos(editor.state.selection.head); } catch { return; }
    }
    // Nested table/code scrolling must happen before the outer document scroll.
    let element = selection?.focusNode?.parentElement ?? editor.view.dom;
    while (element && shell.contains(element)) {
      if (element === scroller || (element.scrollHeight > element.clientHeight && /auto|scroll/.test(getComputedStyle(element).overflowY))) {
        const bounds = element.getBoundingClientRect();
        const delta = rect.bottom > bounds.bottom - GAP
          ? rect.bottom - bounds.bottom + GAP
          : rect.top < bounds.top + GAP ? rect.top - bounds.top - GAP : 0;
        const before = element.scrollTop;
        element.scrollTop += delta;
        const moved = element.scrollTop - before;
        rect = { top: rect.top - moved, bottom: rect.bottom - moved };
      }
      if (element === scroller) break;
      element = element.parentElement!;
    }
  }

  function update() {
    frame = 0;
    if (destroyed) return;
    // Use the current WKWebView's viewport, not screen/keyboard heuristics.
    // This works whether SwiftUI already resized its proposal or WebKit only
    // shrank/panned the visual viewport; no keyboard height is subtracted twice.
    shell.style.top = `${viewport?.offsetTop ?? 0}px`;
    shell.style.left = `${viewport?.offsetLeft ?? 0}px`;
    shell.style.width = `${viewport?.width ?? window.innerWidth}px`;
    shell.style.height = `${viewport?.height ?? window.innerHeight}px`;
    shell.style.setProperty('--mobile-toolbar-height', `${toolbar.hidden ? 0 : toolbar.getBoundingClientRect().height}px`);
    shell.style.setProperty('--mobile-reading-height', `${reading.hidden ? 0 : reading.getBoundingClientRect().height}px`);
    revealCaret();
  }
  function schedule() {
    if (!frame && !destroyed) frame = requestAnimationFrame(update);
  }
  const events = ['input', 'compositionstart', 'compositionupdate', 'compositionend', 'focusin'];
  for (const event of events) editor.view.dom.addEventListener(event, schedule);
  document.addEventListener('selectionchange', schedule);
  window.addEventListener('resize', schedule);
  viewport?.addEventListener('resize', schedule);
  viewport?.addEventListener('scroll', schedule);
  editor.on('transaction', schedule);
  const observer = typeof ResizeObserver === 'undefined' ? undefined : new ResizeObserver(schedule);
  for (const element of [scroller, toolbar, reading]) observer?.observe(element);
  // Hidden toolbar changes may not produce a viewport event (reading mode).
  const visibility = new MutationObserver(schedule);
  visibility.observe(toolbar, { attributes: true, attributeFilter: ['hidden'] });
  visibility.observe(reading, { attributes: true, attributeFilter: ['hidden'] });
  update();
  const destroy = () => {
    destroyed = true;
    cancelAnimationFrame(frame);
    observer?.disconnect(); visibility.disconnect();
    for (const event of events) editor.view.dom.removeEventListener(event, schedule);
    document.removeEventListener('selectionchange', schedule);
    window.removeEventListener('resize', schedule);
    viewport?.removeEventListener('resize', schedule);
    viewport?.removeEventListener('scroll', schedule);
    editor.off('transaction', schedule);
  };
  editor.on('destroy', destroy);
  return destroy;
}
