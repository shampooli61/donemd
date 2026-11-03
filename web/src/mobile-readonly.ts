import { Extension } from '@tiptap/core';
import { Plugin } from '@tiptap/pm/state';

/** contenteditable alone doesn't stop custom NodeViews from dispatching edits. */
export const MobileReadOnlyGuard = Extension.create({
  name: 'mobileReadOnlyGuard',
  addProseMirrorPlugins() {
    const editor = this.editor;
    return [new Plugin({ filterTransaction: transaction => !transaction.docChanged || editor.isEditable })];
  },
});
