/** The same identity/attribute semantics as the Mac writing themes. No editor transaction. */
export type WritingTheme = 'system' | 'paper' | 'night';
export function normalizeWritingTheme(value: unknown): WritingTheme {
  if (value === '' || value === 'system') return 'system';
  if (value === 'paper' || value === 'night') return value;
  throw new Error('无效的阅读主题');
}
export function applyWritingTheme(value: unknown): WritingTheme {
  const theme = normalizeWritingTheme(value);
  if (theme === 'system') document.documentElement.removeAttribute('data-theme');
  else document.documentElement.setAttribute('data-theme', theme);
  document.documentElement.style.colorScheme = theme === 'system' ? 'light dark' : theme === 'paper' ? 'light' : 'dark';
  (window as Window & { __donemdRerenderMermaid?: () => void }).__donemdRerenderMermaid?.();
  return theme;
}
