# Done.md Web

JS/TypeScript bundle that runs inside the macOS app's `WKWebView`.

- **Phase 1**: Visual 视图 (Tiptap-based rich text editor, StarterKit only)
- **Phase 4**: + Markdown 源 pane (CodeMirror)

## Stack

- **Vite 5** — bundler with built-in TypeScript support
- **TypeScript 5** — strict mode
- **Tiptap 2** + **StarterKit** — rich text editor (CommonMark subset)
- **vite-plugin-singlefile** — inlines all CSS/JS/assets into one self-contained HTML for WKWebView embedding

## File layout

```
web/
├─ visual.html              # Phase 1 entry HTML (Vite multi-page)
├─ src/
│  ├─ main.ts               # Tiptap editor setup
│  └─ visual.css            # editor styles
├─ vite.config.ts           # outputs to ../Resources/Web/
├─ tsconfig.json
├─ package.json
└─ README.md (you are here)
```

## Dev (in browser, with HMR)

```bash
npm install         # first time
npm run dev         # opens http://localhost:5173/visual.html
```

Open `http://localhost:5173/visual.html` in any browser — Tiptap behaves the same as inside the macOS app, just no native bridge yet.

## Build

```bash
npm run build       # outputs ../Resources/Web/visual.html (single self-contained file)
```

This is automatically run as a pre-build script by Xcode (see `project.yml` `preBuildScripts`). You only need to run it manually if you want to verify the bundled output, or on a fresh clone before the first `xcodegen generate`.

## Phase progression

Future entries will be added to `vite.config.ts` `rollupOptions.input`:

- Phase 4: `markdown-source.html` (CodeMirror, read-only)
- Phase 5+: bidirectional sync, more Tiptap extensions, themes
