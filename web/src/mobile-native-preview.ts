import mermaid from 'mermaid';
import { isMathBroken, renderMath } from './katex-render';
import { syncMermaidTheme } from './mermaid-codeblock';
import katexCSS from 'katex/dist/katex.min.css?inline';

let previewId = 0;
const escape = (value: string) => value.replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]!);

/** Pure draft rendering: never touches editor selection/content, never fetches
 * a script/style/font from the network. Strict Mermaid also sanitizes SVG. */
export async function renderNativePreview(args: Record<string, string>): Promise<Record<string, string>> {
  if (!['math', 'code', 'raw'].includes(args.type)) throw new Error('无效的预览类型');
  const text = args.text ?? '';
  let html = '', error: string | undefined;
  if (args.type === 'math') {
    if (args.display !== undefined && !['true', 'false'].includes(args.display)) throw new Error('无效的公式类型');
    const result = renderMath(text, args.display === 'true'); html = result.html;
    if (result.error || isMathBroken(text, args.display === 'true')) error = '预览暂不可用，原文会保留';
  } else if (args.type === 'code' && args.language?.trim().toLowerCase() === 'mermaid') {
    try {
      syncMermaidTheme();
      const result = await mermaid.render(`native-preview-${++previewId}`, text); html = result.svg;
    } catch { error = '预览暂不可用，原文会保留'; }
  } else html = `<pre><code>${escape(text)}</code></pre>`;
  if (error && !html) html = `<p>${escape(error)}</p><pre>${escape(text)}</pre>`;
  return {
    html: `<!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1"><meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; font-src data:; img-src data:;"><style>${katexCSS}\n:root{color-scheme:light dark}body{font:17px -apple-system,sans-serif;margin:12px;overflow-wrap:anywhere}pre{white-space:pre-wrap;font:15px monospace}svg{max-width:100%;height:auto}.katex-display{overflow:auto;padding-block:8px}</style></head><body>${html}</body></html>`,
    ...(error ? { error } : {}),
  };
}
