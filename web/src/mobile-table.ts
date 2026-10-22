import Table from '@tiptap/extension-table';

/** A scrollable touch surface; the full-screen switch changes presentation only. */
export const MobileTable = Table.extend({
  addNodeView() {
    return () => {
      const dom = document.createElement('div'); dom.className = 'mobile-table';
      const toggle = document.createElement('button'); toggle.type = 'button'; toggle.contentEditable = 'false';
      toggle.textContent = '全屏表格'; toggle.setAttribute('aria-label', '全屏表格');
      toggle.addEventListener('pointerdown', event => event.preventDefault());
      toggle.addEventListener('click', () => {
        const full = dom.classList.toggle('is-fullscreen');
        toggle.textContent = full ? '退出全屏表格' : '全屏表格';
        toggle.setAttribute('aria-label', toggle.textContent);
      });
      const scroller = document.createElement('div'); scroller.className = 'mobile-table-scroll';
      const table = document.createElement('table'); const contentDOM = document.createElement('tbody');
      table.append(contentDOM); scroller.append(table); dom.append(toggle, scroller);
      return {
        dom, contentDOM,
        update: node => node.type.name === 'table',
        stopEvent: event => toggle.contains(event.target as Node),
        ignoreMutation: mutation => mutation.type !== 'selection' && !contentDOM.contains(mutation.target),
      };
    };
  },
});
