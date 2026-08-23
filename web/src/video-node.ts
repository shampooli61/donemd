import { Node, mergeAttributes } from '@tiptap/core';
import { NodeSelection } from '@tiptap/pm/state';

/**
 * Done.md local-video node (#88). A block-level atom that renders a native
 * `<video controls>` in the Visual pane, playing bytes served over the
 * `donemd-asset://` scheme (AssetURLSchemeHandler answers HTTP Range/206 so
 * seeking works). This is the document's OWN video file — distinct from a
 * 飞书 placeholder video (占位跳转卡), which stays an inert jump card and is
 * never turned into a real `<video>`.
 *
 * Disk form is a canonical single-line `<video controls src="./assets/…">`
 * emitted by the Swift Serializer; parseHTML here lets the Visual pane
 * reconstruct the node when the doc is loaded. renderHTML emits the same
 * `<video>` for copy / paste.
 */
export const DonemdVideo = Node.create({
  name: 'video',
  group: 'block',
  atom: true,
  selectable: true,
  // NOT draggable at the node level. A draggable atom makes ProseMirror mark
  // the whole NodeView DOM as a native drag source, so *any* mousedown-drag on
  // the video body starts a block move — which collides with the player's own
  // scrubber / volume drags. Reordering is done only through the left grip
  // (block-drag-handle.ts sets `view.dragging` by hand and never consults this
  // flag), so the video stays "stable like an image": handle-drag to move,
  // player-drag to seek, no conflict.
  draggable: false,

  addAttributes() {
    return {
      src: {
        default: null,
        parseHTML: (element) => element.getAttribute('src'),
        renderHTML: (attributes) =>
          attributes.src ? { src: attributes.src as string } : {},
      },
      // Always controls-on in v1 — the reader needs play/seek. Kept as an
      // attribute so the canonical serialized form (`<video controls …>`)
      // round-trips through parseHTML without dropping it.
      controls: {
        default: true,
        parseHTML: (element) => element.hasAttribute('controls'),
        renderHTML: (attributes) =>
          attributes.controls ? { controls: 'controls' } : {},
      },
    };
  },

  // Deleting a selected video needs to pin the viewport. The inner `<video>`
  // is a focusable interactive element; when ProseMirror removes the node, DOM
  // focus escapes to `<body>`, WebKit then refocuses the editable, and with
  // `autofocus: 'end'` the untouched caret sits at the doc end — so the whole
  // pane jumps to the bottom (the same window-scroller hazard the link-nav and
  // AI-insert paths guard against in main.ts). We delete the node ourselves,
  // keep focus on the editor, and restore the scroll position across the async
  // refocus. Only fires when THIS video is the whole selection; otherwise we
  // return false and let the default Backspace/Delete handling run.
  addKeyboardShortcuts() {
    const removeSelected = (): boolean => {
      const sel = this.editor.state.selection;
      if (!(sel instanceof NodeSelection) || sel.node.type.name !== this.name) {
        return false;
      }
      const prevScrollX = window.scrollX;
      const prevScrollY = window.scrollY;
      const restore = (): void => window.scrollTo(prevScrollX, prevScrollY);
      const ok = this.editor.chain().deleteSelection().focus().run();
      restore();
      requestAnimationFrame(restore);
      return ok;
    };
    return { Backspace: removeSelected, Delete: removeSelected };
  },

  parseHTML() {
    return [{ tag: 'video' }];
  },

  renderHTML({ HTMLAttributes }) {
    return ['video', mergeAttributes(HTMLAttributes)];
  },

  addNodeView() {
    return ({ node }) => {
      // `.donemd-video-frame` (visual.css) fills the reading column and carries
      // the `.ProseMirror-selectednode` outline, exactly like the image frame —
      // so the video reads as one selectable block object at a unified width.
      const frame = document.createElement('div');
      frame.className = 'donemd-video-frame';
      frame.setAttribute('contenteditable', 'false');

      const video = document.createElement('video');
      video.setAttribute('controls', 'controls');
      video.setAttribute('preload', 'metadata');
      video.setAttribute('playsinline', 'true');

      const applySrc = (attrs: Record<string, unknown>): void => {
        const src = typeof attrs.src === 'string' ? attrs.src : '';
        if (video.getAttribute('src') !== src) video.setAttribute('src', src);
      };
      applySrc(node.attrs);

      frame.append(video);

      return {
        dom: frame,
        update: (updatedNode) => {
          if (updatedNode.type.name !== node.type.name) return false;
          applySrc(updatedNode.attrs);
          return true;
        },
        // Let the native controls own play/pause/seek clicks — swallow events
        // that originate inside the <video> so a tap on the scrubber never
        // doubles as a caret move or drag start. ProseMirror still owns
        // selection/drag on the frame chrome around it.
        stopEvent: (event) => video.contains(event.target as globalThis.Node),
        // Atom leaf, no contentDOM: the NodeView owns all inner DOM, so no
        // mutation here is ever a user text edit.
        ignoreMutation: () => true,
      };
    };
  },
});
