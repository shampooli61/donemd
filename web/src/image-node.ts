import Image from '@tiptap/extension-image';
import { send } from './bridge';

/**
 * Done.md image node. Extends `@tiptap/extension-image` with a NodeView so a
 * document image reads as one selectable object:
 *   - single click selects the whole node (blue `ProseMirror-selectednode`
 *     outline via CSS) so the user can see it's picked and press Delete;
 *   - a magnifier badge fades in on hover (top-right) — clicking *that* opens
 *     the native QuickLook preview (#77). Preview is thus opt-in, split from
 *     selection, so clicking the image no longer hijacks the caret.
 *
 * The NodeView only rewrites editor-side DOM; the ProseMirror doc model and
 * Swift-side serialization (which never look at the DOM) are untouched, and
 * `renderHTML` still emits a plain `<img>` for copy / paste.
 */
const ZOOM_ICON =
  '<svg width="15" height="15" viewBox="0 0 24 24" fill="none" ' +
  'stroke="currentColor" stroke-width="2" stroke-linecap="round" ' +
  'stroke-linejoin="round" aria-hidden="true">' +
  '<circle cx="11" cy="11" r="7"></circle>' +
  '<line x1="16.5" y1="16.5" x2="21" y2="21"></line></svg>';

export const DonemdImage = Image.extend({
  addNodeView() {
    return ({ node }) => {
      // `width: fit-content; margin: auto` shrinks the frame to the image so
      // the selection outline hugs the picture (not the whole line) while the
      // block still centers like the old bare <img>.
      const frame = document.createElement('div');
      frame.className = 'donemd-image-frame';
      frame.setAttribute('contenteditable', 'false');

      const img = document.createElement('img');
      const applySrc = (attrs: Record<string, unknown>): void => {
        const src = typeof attrs.src === 'string' ? attrs.src : '';
        if (img.getAttribute('src') !== src) img.setAttribute('src', src);
        const alt = typeof attrs.alt === 'string' ? attrs.alt : '';
        if (alt) img.setAttribute('alt', alt);
        else img.removeAttribute('alt');
        const title = typeof attrs.title === 'string' ? attrs.title : '';
        if (title) img.setAttribute('title', title);
        else img.removeAttribute('title');
      };
      applySrc(node.attrs);

      const zoom = document.createElement('button');
      zoom.type = 'button';
      zoom.className = 'donemd-image-zoom';
      zoom.setAttribute('aria-label', '放大预览');
      zoom.title = '放大预览';
      zoom.innerHTML = ZOOM_ICON;
      // Fire the preview and keep the event away from ProseMirror so clicking
      // the badge never doubles as a caret move / drag start.
      const openPreview = (event: Event): void => {
        event.preventDefault();
        event.stopPropagation();
        const src = img.getAttribute('src');
        if (src) send('previewImage', { src });
      };
      zoom.addEventListener('mousedown', (e) => e.preventDefault());
      zoom.addEventListener('click', openPreview);

      frame.append(img, zoom);

      return {
        dom: frame,
        update: (updatedNode) => {
          if (updatedNode.type.name !== node.type.name) return false;
          applySrc(updatedNode.attrs);
          return true;
        },
        // Let ProseMirror own selection/drag on the image itself, but swallow
        // events originating inside the zoom badge so its click stays private.
        stopEvent: (event) => zoom.contains(event.target as globalThis.Node),
        // Leaf node, no contentDOM: the NodeView owns all inner DOM, so no
        // mutation here is ever a user text edit.
        ignoreMutation: () => true,
      };
    };
  },
});
