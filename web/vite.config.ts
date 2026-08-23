import { defineConfig, type Plugin } from 'vite';
import { viteSingleFile } from 'vite-plugin-singlefile';
import { resolve } from 'path';
import { fileURLToPath } from 'url';

const __dirname = fileURLToPath(new URL('.', import.meta.url));

// vite-plugin-singlefile sets `output.inlineDynamicImports = true` which
// rollup forbids when there are multiple inputs. Workaround: build each
// entry as its own pass, selected by the VITE_ENTRY env var. The
// `build` npm script chains them via &&.
const entry = process.env.VITE_ENTRY || 'visual';

// KaTeX's CSS declares each font in three formats (woff2 → woff → ttf). With
// `assetsInlineLimit: Infinity` all three would base64-inline, tripling the
// font payload (~1.1MB) for no benefit — WKWebView always picks woff2. Strip
// the woff/ttf `src` entries from KaTeX's @font-face blocks before asset
// resolution so only the woff2 files inline (~1MB saved). Scoped to the
// katex CSS by id; leaves every other stylesheet untouched.
const katexWoff2Only = (): Plugin => ({
  name: 'katex-woff2-only',
  enforce: 'pre',
  transform(code, id) {
    if (!id.includes('katex') || !id.endsWith('.css')) return null;
    // Drop `,url(...woff) format("woff")` and `,url(...ttf) format("truetype")`
    // (they always follow the woff2 entry, so the leading comma is safe to eat).
    const stripped = code.replace(
      /,url\([^)]*\.(?:woff|ttf)\)\s*format\("(?:woff|truetype)"\)/g,
      ''
    );
    return stripped === code ? null : { code: stripped, map: null };
  },
});

export default defineConfig({
  plugins: [katexWoff2Only(), viteSingleFile()],
  build: {
    outDir: '../Resources/Web',
    emptyOutDir: false,
    // The output is a single self-contained HTML loaded from the app bundle
    // (no sibling asset dir is served by the WKWebView). KaTeX's CSS
    // references its woff2/woff/ttf fonts via relative url(fonts/...); those
    // MUST be base64-inlined or glyphs 404 at runtime. A very high inline
    // limit forces every referenced asset (incl. the KaTeX fonts) into the
    // CSS as data URIs before vite-plugin-singlefile folds it into the HTML.
    assetsInlineLimit: Number.MAX_SAFE_INTEGER,
    rollupOptions: {
      input: { [entry]: resolve(__dirname, `${entry}.html`) },
    },
  },
});
