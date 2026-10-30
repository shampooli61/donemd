// @vitest-environment jsdom
import { readFileSync } from 'node:fs';
import { afterEach, describe, expect, it } from 'vitest';

const visual = readFileSync('src/visual.css', 'utf8');
const mobile = readFileSync('src/mobile.css', 'utf8');
const source = readFileSync('src/markdown-source.css', 'utf8');

afterEach(() => {
  document.head.querySelectorAll('style').forEach(style => style.remove());
  document.documentElement.removeAttribute('data-theme');
  document.documentElement.removeAttribute('data-mobile-source');
  document.body.className = '';
});

// jsdom does not resolve custom properties or prefers-color-scheme. Walk the
// real CSSOM for the root/body token declarations, evaluating the OS query
// explicitly, then resolve inherited var() references on the reading surface.
function tokens(css: string, theme: string, dark: boolean, mobileSource = false) {
  const root = document.documentElement;
  if (theme === 'system') root.removeAttribute('data-theme');
  else root.setAttribute('data-theme', theme);
  root.toggleAttribute('data-mobile-source', mobileSource);
  document.body.className = mobileSource ? 'mobile-source' : '';
  const style = document.createElement('style');
  style.textContent = css;
  document.head.append(style);
  const values: Record<string, string> = {};
  const visit = (rules: CSSRuleList, element: Element) => {
    for (const rule of Array.from(rules)) {
      if (rule.type === CSSRule.MEDIA_RULE) {
        const media = rule as CSSMediaRule;
        if (media.conditionText === '(prefers-color-scheme: dark)' && dark) visit(media.cssRules, element);
      } else if (rule.type === CSSRule.STYLE_RULE) {
        const declaration = rule as CSSStyleRule;
        // Only root/body rules supply these inherited tokens. Ignore content
        // selectors (including WebKit-only pseudo-elements jsdom cannot match).
        if (!declaration.selectorText.split(',').some(selector => /^(?:\s*:root|\s*body(?:\s|\.|,|$))/.test(selector))) continue;
        if (!element.matches(declaration.selectorText)) continue;
        for (let i = 0; i < declaration.style.length; i++) {
          const property = declaration.style[i];
          if (property.startsWith('--')) values[property] = declaration.style.getPropertyValue(property).trim();
        }
      }
    }
  };
  visit(style.sheet!.cssRules, root);
  visit(style.sheet!.cssRules, document.body);
  const resolve = (property: string): string => {
    const value = values[property];
    if (!value) throw new Error(`Missing token ${property}`);
    const reference = /^var\((--[\w-]+)\)$/.exec(value);
    return reference ? resolve(reference[1]) : value;
  };
  return resolve;
}

function normalizeHex(hex: string) {
  expect(hex).toMatch(/^#(?:[0-9a-f]{3}|[0-9a-f]{6})$/i);
  const digits = hex.slice(1).toLowerCase();
  return '#' + (digits.length === 3 ? [...digits].map(channel => channel + channel).join('') : digits);
}

function contrast(foreground: string, background: string) {
  const luminance = (color: string) => {
    const hex = normalizeHex(color);
    const linear = [1, 3, 5].map(offset => {
      const channel = parseInt(hex.slice(offset, offset + 2), 16) / 255;
      return channel <= 0.04045 ? channel / 12.92 : ((channel + 0.055) / 1.055) ** 2.4;
    });
    return linear[0] * 0.2126 + linear[1] * 0.7152 + linear[2] * 0.0722;
  };
  const a = luminance(foreground), b = luminance(background);
  return (Math.max(a, b) + 0.05) / (Math.min(a, b) + 0.05);
}

const palettes = [
  { theme: 'paper', dark: false, background: '#f8f4ee', muted: '#7a6d58' },
  { theme: 'paper', dark: true, background: '#f8f4ee', muted: '#7a6d58' },
  { theme: 'night', dark: false, background: '#171c26', muted: '#929dad' },
  { theme: 'night', dark: true, background: '#171c26', muted: '#929dad' },
  { theme: 'system', dark: false, background: '#ffffff', muted: '#696970' },
  { theme: 'system', dark: true, background: '#000000', muted: '#a0a0aa' },
];

describe('mobile secondary text contrast', () => {
  it('treats shorthand and mixed-case hex as equivalent semantic colors', () => {
    expect(normalizeHex('#fff')).toBe('#ffffff');
    expect(normalizeHex('#000')).toBe('#000000');
    expect(normalizeHex('#AbC')).toBe('#aabbcc');
    expect(normalizeHex('#AaBbCc')).toBe('#aabbcc');
    expect(contrast('#000', '#FFF')).toBe(21);
    expect(contrast('#AbC', '#fff')).toBe(contrast('#aabbcc', '#ffffff'));
    expect(contrast('#696970', '#fff')).toBe(contrast('#696970', '#ffffff'));
  });

  it.each(palettes)('$theme (OS dark=$dark) keeps prose and source muted text at 4.5:1', ({ theme, dark, background, muted }) => {
    const prose = tokens(visual + '\n' + mobile, theme, dark);
    expect(normalizeHex(prose('--md-muted'))).toBe(normalizeHex(muted));
    expect(contrast(prose('--md-muted'), background)).toBeGreaterThanOrEqual(4.5);
    const mirror = tokens(source, theme, dark, true);
    expect(normalizeHex(mirror('--mobile-source-background'))).toBe(normalizeHex(background));
    for (const property of ['--cmd-mark', '--cmd-strike', '--cmd-quote']) {
      expect(normalizeHex(mirror(property))).toBe(normalizeHex(muted));
      expect(contrast(mirror(property), mirror('--mobile-source-background'))).toBeGreaterThanOrEqual(4.5);
    }
  });

  it('keeps small prose consumers connected to the inherited muted token', () => {
    for (const selector of ['.ProseMirror h6', '.ProseMirror blockquote', '.donemd-feishu-placeholder__type', '.donemd-feishu-placeholder__summary']) {
      const blocks = Array.from(visual.matchAll(/([^{}]+)\{([^{}]*)\}/g));
      expect(blocks.some(([, selectors, declarations]) =>
        selectors.split(',').some(value => value.trim().endsWith(selector)) &&
        declarations.includes('color: var(--md-muted)'),
      )).toBe(true);
    }
    expect(mobile).toMatch(/body\s*\{\s*--md-muted:\s*var\(--mobile-muted\);\s*\}/);
  });

  it('does not change desktop prose or source tokens', () => {
    expect(tokens(visual, 'paper', true)('--md-muted')).toBe('#8a7d6a');
    const desktopSource = tokens(source, 'paper', true);
    expect(desktopSource('--cmd-mark')).toBe('#b8ac96');
    expect(desktopSource('--cmd-quote')).toBe('#8a7d6a');
    expect(desktopSource('--cmd-strike')).toBe('#a99e8c');
  });

  it('retains the accepted body margins, reading limit and source fold gutter', () => {
    expect(mobile).toContain('max(18px, env(safe-area-inset-right))');
    expect(mobile).toContain('max(18px, env(safe-area-inset-left))');
    expect(mobile).toContain('.native-controls #editor { max-width: 720px; margin-inline: 0 auto; }');
    expect(mobile).toContain('padding-inline: max(28px, env(safe-area-inset-left)) max(28px, env(safe-area-inset-right))');
    expect(source).toContain('.mobile-source .cm-foldGutter { width: 44px; min-width: 44px; }');
    expect(source).toContain('.cm-gutter.cm-lineNumbers { display: none !important; }');
    expect(source).toContain('caret-color: transparent !important;');
    expect(source).toContain('user-select: text;');
  });
});
