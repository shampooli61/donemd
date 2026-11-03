// @vitest-environment jsdom
import { afterEach, describe, expect, it, vi } from 'vitest';
import { applyWritingTheme } from './writing-theme';

afterEach(() => { document.documentElement.removeAttribute('data-theme'); vi.unstubAllGlobals(); });
describe('shared writing theme presentation', () => {
  it('removes system attribute so shared dark selectors match and redraws existing Mermaid', () => {
    const redraw = vi.fn();
    (window as Window & { __donemdRerenderMermaid?: () => void }).__donemdRerenderMermaid = redraw;
    for (const value of ['paper', 'night', '', 'system']) {
      applyWritingTheme(value);
      if (!value || value === 'system') expect(document.documentElement.hasAttribute('data-theme')).toBe(false);
      else expect(document.documentElement.dataset.theme).toBe(value);
    }
    expect(redraw).toHaveBeenCalledTimes(4);
    delete (window as Window & { __donemdRerenderMermaid?: () => void }).__donemdRerenderMermaid;
  });
  it('rejects invalid themes before touching display or storage', () => {
    applyWritingTheme('paper');
    const before = document.documentElement.outerHTML;
    expect(() => applyWritingTheme('other')).toThrow();
    expect(document.documentElement.outerHTML).toBe(before);
  });
});
