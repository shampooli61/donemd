import { describe, it, expect } from 'vitest';
import { linkHrefFromClickTarget } from './link-open';

// Pure predicate behind single-click link following. The DOM wiring
// (addEventListener on view.dom, send over the bridge) and the native open are
// verified by hand on-device per project convention; here we lock the click
// decision. Targets are duck-typed fakes so the test runs without a DOM.

function fakeTarget(href: string | null): unknown {
  const anchor = href === null ? null : { getAttribute: () => href };
  return { closest: (sel: string) => (sel === 'a' ? anchor : null) };
}

describe('linkHrefFromClickTarget', () => {
  it('returns the href on a single click inside an <a>', () => {
    expect(linkHrefFromClickTarget(fakeTarget('https://example.com'), 1)).toBe(
      'https://example.com',
    );
  });

  it('ignores double / triple clicks so word-select still works for editing', () => {
    expect(linkHrefFromClickTarget(fakeTarget('https://example.com'), 2)).toBeNull();
    expect(linkHrefFromClickTarget(fakeTarget('https://example.com'), 3)).toBeNull();
  });

  it('returns null when the click is not inside an <a>', () => {
    expect(linkHrefFromClickTarget({ closest: () => null }, 1)).toBeNull();
  });

  it('returns null for an <a> without an href (or an empty one)', () => {
    expect(linkHrefFromClickTarget(fakeTarget(null), 1)).toBeNull();
    expect(linkHrefFromClickTarget(fakeTarget(''), 1)).toBeNull();
  });

  it('returns null for a target that is not element-like', () => {
    expect(linkHrefFromClickTarget(null, 1)).toBeNull();
    expect(linkHrefFromClickTarget({}, 1)).toBeNull();
  });
});
