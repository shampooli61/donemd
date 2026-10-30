import type { Editor, JSONContent } from '@tiptap/core';
import { Plugin, PluginKey } from '@tiptap/pm/state';
import { loadMobileDocument } from './mobile-document-session';

/** JS owns the lock: acquiring it and taking the final snapshot are one event-loop turn. */
export function createSnapshotProtection(editor: Editor, getRevision: () => number, setRevision: (revision: number) => void,
  nextSequence: () => number = (() => { let sequence = 0; return () => ++sequence; })()) {
  let token: string | undefined;
  let wasEditable = false;
  const viewport = editor.view.dom.closest<HTMLElement>('#mobile-viewport');
  let wasInert = false;
  let pendingPause = false;
  let pausedForRetry = false;
  let resumeEditable = false;
  editor.registerPlugin(new Plugin({
    key: new PluginKey('mobileSnapshotProtection'),
    // contenteditable=false alone doesn't stop custom node controls or queued commands.
    filterTransaction: transaction => (!token && !pausedForRetry) || !transaction.docChanged,
  }));
  function unlock() {
    token = undefined;
    editor.setEditable(wasEditable);
    if (viewport) viewport.inert = wasInert;
  }
  return {
    isLocked: () => Boolean(token) || pendingPause || pausedForRetry,
    pauseUntilRetry() {
      if (pendingPause || pausedForRetry) return true;
      resumeEditable = editor.isEditable;
      pendingPause = true;
      const pause = () => {
        if (!pendingPause || token || editor.isDestroyed) return;
        pendingPause = false;
        pausedForRetry = true;
        editor.setEditable(false);
      };
      // Do not filter or disable the IME's final commit. Pause in the following task.
      if (editor.view.composing) editor.view.dom.addEventListener('compositionend', () => setTimeout(pause, 0), { once: true });
      else pause();
      return true;
    },
    begin(request: string) {
      if (token || editor.view.composing || !request) return null;
      wasEditable = pausedForRetry || pendingPause ? resumeEditable : editor.isEditable;
      pendingPause = false;
      pausedForRetry = false;
      token = request;
      if (viewport) { wasInert = viewport.inert; viewport.inert = true; }
      editor.setEditable(false);
      return { token, locked: true, composing: false, revision: getRevision(), body: editor.getJSON(), sequence: nextSequence() };
    },
    finish(request: string, body: JSONContent, revision: number) {
      if (request !== token) return false;
      try {
        // No replacement on backup failure: retain the final acknowledged draft and undo.
        if (revision !== getRevision()) {
          loadMobileDocument(editor, body);
          setRevision(revision);
        }
        return true;
      } catch {
        // Native has already advanced this revision. Keep the acknowledged old body
        // editable under that revision; unlock's update mirrors it back, not stale text.
        setRevision(revision);
        return false;
      } finally {
        unlock();
      }
    },
    abort(request: string) {
      if (request !== token) return false;
      unlock();
      return true;
    },
  };
}

declare global {
  interface Window { donemdMobileProtection: ReturnType<typeof createSnapshotProtection> }
}
