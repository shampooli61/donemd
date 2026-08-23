import AppKit
import SwiftUI
import Combine

/// NSDocument subclass for a single `.md` file (one window per document).
///
/// Slice 2 reads the file, parses it via MarkdownEngine, and pushes the
/// resulting Tiptap JSON to the embedded WebView once it signals editorReady.
/// Save flow is added in Slice 3 (#7); first-save prompt in Slice 7 (#14).
final class DonemdDocument: NSDocument {
    /// The parsed document — body (Tiptap JSON) plus optional YAML
    /// frontmatter. Updated by `read(from:ofType:)` and read by
    /// `VisualWebView` when the JS editor signals it is ready. Only the
    /// body is sent to the WebView; frontmatter rides along untouched
    /// until v2 metadata UI lands.
    private(set) var parsedDocument: MarkdownEngine.ParsedDocument =
        MarkdownEngine.ParsedDocument(frontmatter: .empty, body: .emptyDoc)

    /// Body-only accessor for callers that don't care about frontmatter
    /// (the WebView bridge, mainly). Mirrors the pre-v2-1 surface.
    var tiptapDocument: TiptapNode { parsedDocument.body }

    /// Per-document image asset store. Resolves the document's adjacent
    /// `assets/` folder lazily from the current `fileURL` so that an
    /// untitled doc (no fileURL) gets temp staging until Save As lands.
    private(set) lazy var assetsManager = AssetsManager(
        documentDirectoryProvider: { [weak self] in
            self?.fileURL?.deletingLastPathComponent()
        }
    )

    /// State driving the bottom-edge progress bar (#57 step5). Set by
    /// FeishuPushCommand / FeishuPullCommand at the start of a sync,
    /// cleared after the alert dismisses. Boxed in
    /// `SyncProgressContainer` (an ObservableObject) so the SwiftUI
    /// root view can observe both the swap-in/swap-out and the
    /// nested model's per-event @Published changes — a bare
    /// `@Published var` of an optional ObservableObject only fires
    /// the outer view on the swap, not on inner edits.
    public let syncProgress = SyncProgressContainer()

    /// Drives the top-edge `FeishuSyncStatusBar` (#53). Republished
    /// whenever the document's `parsedDocument.frontmatter.feishu`
    /// changes — push success / pull success / unbind / createNew
    /// import. The bar reads the current value via the binding `if let
    /// feishu = bindingState.feishu` in DonemdDocumentRootView; nil
    /// means the doc isn't bound and the bar is hidden entirely.
    ///
    /// Same pattern as `SyncProgressContainer` — separate
    /// ObservableObject so the SwiftUI root view re-renders on every
    /// publish, not just on document open.
    public let bindingState = BindingStateContainer()

    /// Drives the 大纲 sidebar (#78). Updated from the `outlineChanged`
    /// bridge message on every edit (~300ms debounce on the JS side) and
    /// on document open. Observed by `DonemdDocumentRootView`.
    public let outlineStore = OutlineStore()

    /// Drives the source-pane top-bar AI-readability readout (#82): a color dot
    /// + ≈token estimate + a plain-language verdict telling the user whether
    /// this .md is feasible to feed an AI. Recomputed from the body markdown
    /// every time we push to the source pane (i.e. after each Visual edit).
    /// Observed by `MarkdownSourceTopBar`.
    public let documentSizeStore = DocumentSizeStore()

    /// Boxes the current `DocumentSizeEstimate` so SwiftUI re-renders the top-bar
    /// readout when the document's size/token estimate changes. Same
    /// ObservableObject-per-concern pattern as `OutlineStore` / the containers
    /// above. Nil until the first push (fresh document before content arrives).
    public final class DocumentSizeStore: ObservableObject {
        @Published public var estimate: DocumentSizeEstimate?

        /// Recompute from body markdown and publish. Always on main —
        /// `pushCurrentMarkdownToSource` can be reached from off-main sync
        /// completions (mirrors the other stores' main-hop discipline).
        func update(bodyMarkdown: String) {
            let next = DocumentSizeEstimate.compute(bodyMarkdown: bodyMarkdown)
            if Thread.isMainThread {
                if estimate != next { estimate = next }
            } else {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    if self.estimate != next { self.estimate = next }
                }
            }
        }
    }

    /// Per-document 大纲 sidebar open/closed state (方案 A). Each window owns
    /// its OWN instance, so toggling the outline in one document no longer
    /// drags every other open window with it (the previous global
    /// `@AppStorage("donemd.outlineVisible")` behavior). Observed by
    /// `DonemdDocumentRootView`; flipped by the ⌃⌘S monitor and the 显示文档大纲
    /// menu, both routed to the frontmost document's store.
    public let outlineVisibility = OutlineVisibilityStore()

    /// Holds one document window's 大纲 sidebar visibility, independent of every
    /// other window. Seeded from — and written back to — the shared
    /// `donemd.outlineVisible` UserDefaults key, but ONLY as the default for the
    /// NEXT new window: existing windows each observe their own instance, so a
    /// write here never moves another open window. This is the whole difference
    /// from the old global `@AppStorage` binding (方案 A: per-document state,
    /// last choice remembered as the new-window default).
    public final class OutlineVisibilityStore: ObservableObject {
        static let defaultsKey = "donemd.outlineVisible"

        @Published public var isVisible: Bool {
            didSet {
                // Persist as the seed for future windows only. Already-open
                // windows own separate stores, so this doesn't touch them.
                UserDefaults.standard.set(isVisible, forKey: Self.defaultsKey)
            }
        }

        public init() {
            // Default collapsed. A brand-new (untitled) document never reaches
            // `read(from:)`, so it keeps this collapsed default — a blank page
            // with no headings shouldn't pop an empty 大纲 panel. Opening an
            // existing file DOES hit `read(from:)`, which calls
            // `seedFromStickyDefault()` to restore the 方案 A behavior (remember
            // the last window's open/closed choice). Seeding in `init` directly
            // is deliberately avoided so untitled windows don't inherit the seed.
            self.isVisible = false
        }

        /// Restore the remembered open/closed choice (方案 A sticky default).
        /// Called from `read(from:)` only, so it applies when opening an
        /// existing file but never to a fresh untitled window (which stays
        /// collapsed). Idempotent — the didSet write-back is the same value.
        public func seedFromStickyDefault() {
            isVisible = UserDefaults.standard.bool(forKey: Self.defaultsKey)
        }

        /// Flip this document's sidebar. Called by the ⌃⌘S monitor and the
        /// 显示文档大纲 menu item after they resolve the frontmost document.
        public func toggle() {
            isVisible.toggle()
        }
    }

    /// Delegate for the window's unified NSToolbar. Held strongly here since
    /// NSToolbar keeps only a weak reference. Builds the sidebar toggle + title
    /// + Feishu capsule + AI badge toolbar items.
    private lazy var documentToolbarDelegate = DocumentToolbarDelegate(document: self)

    /// Drives the centered title in the transparent chrome (Phase 5 polish).
    /// `displayName` / `isDocumentEdited` are NSDocument properties but
    /// SwiftUI doesn't observe them, so we mirror them into a published box
    /// and refresh it from the single `updateChangeCount` override below
    /// (which every dirty/clean transition already funnels through) plus on
    /// open / fileURL change. Same pattern as `BindingStateContainer`.
    public let titleState = TitleStateContainer()

    public final class TitleStateContainer: ObservableObject {
        @Published public var title: String = ""
        @Published public var isEdited: Bool = false

        /// Refresh from the document's current display name + dirty flag.
        /// Always publishes on main — `updateChangeCount` can be reached
        /// from off-main sync completions.
        public func update(title: String, isEdited: Bool) {
            if Thread.isMainThread {
                self.title = title
                self.isEdited = isEdited
            } else {
                DispatchQueue.main.async { [weak self] in
                    self?.title = title
                    self?.isEdited = isEdited
                }
            }
        }
    }

    public final class BindingStateContainer: ObservableObject {
        @Published public var feishu: FeishuFrontmatter? = nil
        /// Whether the document currently carries a frontmatter fence at all
        /// (user fields and/or Done.md-managed `feishu:` metadata). Drives the
        /// MD-source "frontmatter" collapse entry — shown only when there's
        /// actually a fence to reveal.
        @Published public var hasFrontmatter: Bool = false

        /// Republish from the document's current frontmatter. Always
        /// hops to main if not already there — `@ObservedObject`
        /// receivers expect main-thread publishes, and NSDocument's
        /// `read(from:)` can run off-main on initial open.
        public func update(from frontmatter: Frontmatter) {
            let feishuSnapshot = frontmatter.feishu
            let hasFence = frontmatter.hasFence
            if Thread.isMainThread {
                self.feishu = feishuSnapshot
                self.hasFrontmatter = hasFence
            } else {
                DispatchQueue.main.async { [weak self] in
                    self?.feishu = feishuSnapshot
                    self?.hasFrontmatter = hasFence
                }
            }
        }
    }

    public final class SyncProgressContainer: ObservableObject {
        @Published public var model: FeishuSyncProgressViewModel? = nil
        private var cancellable: AnyCancellable? = nil

        @MainActor
        public func start(direction: FeishuSyncDirection) -> FeishuSyncProgressViewModel {
            let m = FeishuSyncProgressViewModel(direction: direction)
            self.model = m
            // Bridge the inner model's published changes up to ourselves
            // so views that observe the container re-render on every
            // status line / progress tick. Without this, only the
            // initial set + final clear cause a re-render.
            self.cancellable = m.objectWillChange.sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            return m
        }

        @MainActor
        public func stop() {
            self.cancellable = nil
            self.model = nil
        }
    }

    /// Set by the WebView's coordinator during makeNSView so app-level
    /// commands (e.g. `Cmd+Shift+I`) can route insertions back into the
    /// right WebView. Weak so the document doesn't keep the coordinator
    /// alive once the window goes away.
    private weak var visualCoordinator: VisualWebView.Coordinator?

    func attachVisualCoordinator(_ coordinator: VisualWebView.Coordinator) {
        visualCoordinator = coordinator
    }

    /// Set by MarkdownSourceWebView's coordinator during makeNSView so the
    /// document can push serialized markdown into the right pane after
    /// every Visual edit.
    private weak var markdownSourceCoordinator: MarkdownSourceWebView.Coordinator?

    func attachMarkdownSourceCoordinator(_ coordinator: MarkdownSourceWebView.Coordinator) {
        markdownSourceCoordinator = coordinator
    }

    /// Jump both panes to the Nth heading (#79). Clicking a 大纲 row calls this;
    /// the ordinal matches HeadingExtractor's document order, so both the Visual
    /// (Tiptap) and Markdown-source (CodeMirror) panes scroll to the same
    /// heading — anchored by "the Nth heading", not by pixel row.
    /// `smooth` picks the scroll animation: `true` for an outline-row click
    /// (a deliberate navigation the user follows with their eyes) and `false`
    /// for a sidebar-toggle re-anchor, which must snap instantly — a smooth
    /// glide there rides on top of WebKit's own resize reflow and reads as a
    /// violent double-scroll (the "剧烈" the user reported).
    func scrollToHeading(index: Int, smooth: Bool = true) {
        visualCoordinator?.send(
            envelopeOfType: "scrollToHeading",
            payload: .object(["index": .integer(index), "smooth": .bool(smooth)])
        )
        markdownSourceCoordinator?.sendScrollToHeading(index: index, smooth: smooth)
    }

    /// Latest set of broken-formula LaTeX strings reported by the Visual pane
    /// (S9 M2). Cached so a later source-pane refresh can re-send it (bridge
    /// messages are one-shot; if the source pane reloads we'd otherwise lose
    /// the flags).
    private var badMathFormulas: [String] = []

    /// Relay the broken-formula list to the source pane so it red-flags the
    /// matching text (S9 M2). Called from Visual's `badMathFormulas` handler.
    func setBadMathFormulas(_ latexes: [String]) {
        badMathFormulas = latexes
        markdownSourceCoordinator?.sendBadMathFormulas(latexes)
    }

    // MARK: 标题折叠 (heading fold) — 富文本 ↔ md 源双向联动

    /// Single source of truth for which heading sections are collapsed, keyed by
    /// the ordinal of the Nth top-level heading (same ordinal the panes speak).
    /// Pure ephemeral VIEW state — never serialized to `.md` (folding has no
    /// Markdown representation and the disk format is Swift's alone). Reset per
    /// document, so reopening shows everything expanded.
    private var collapsedHeadingOrdinals: Set<Int> = []

    /// A pane reported a user-driven fold/unfold (`foldToggled`). Update the
    /// authoritative set, then broadcast the new set to BOTH panes so they land
    /// in lockstep. Panes apply `applyFold` passively (never re-emit), so this
    /// can't loop (A → Swift → B, never B → Swift → A). Fans out exactly like
    /// `scrollToHeading`.
    func setFold(ordinal: Int, collapsed: Bool) {
        if collapsed {
            collapsedHeadingOrdinals.insert(ordinal)
        } else {
            collapsedHeadingOrdinals.remove(ordinal)
        }
        broadcastFoldState()
    }

    /// Replace the whole collapsed set (a folded-heading section was dragged, so
    /// the Visual pane recomputed every folded heading's new ordinal). Same
    /// fan-out as `setFold`: broadcast so both panes renumber in lockstep.
    func setFoldSet(ordinals: [Int]) {
        collapsedHeadingOrdinals = Set(ordinals)
        broadcastFoldState()
    }

    /// Re-feed the current collapsed set to the panes after a pane (re)loads and
    /// its content has just been (re)pushed — mirrors the `badMathFormulas`
    /// re-send. No-op when nothing is collapsed (the common case, so a fresh
    /// document doesn't emit a redundant empty `applyFold`). Called from both
    /// panes' `editorReady` paths.
    func resendFoldStateIfNeeded() {
        if !collapsedHeadingOrdinals.isEmpty {
            broadcastFoldState()
        }
    }

    /// Push the current collapsed set to both panes. Called after every
    /// `setFold`, and on pane reload (re-feed, mirroring `badMathFormulas`) so a
    /// pane that reloads catches up.
    private func broadcastFoldState() {
        let ordinals = collapsedHeadingOrdinals.sorted()
        visualCoordinator?.send(
            envelopeOfType: "applyFold",
            payload: .object(["collapsed": .array(ordinals.map { .integer($0) })])
        )
        markdownSourceCoordinator?.sendApplyFold(ordinals: ordinals)
    }

    // MARK: Visual → Markdown 源 sync (Phase 1: one-way)

    /// Whether the MD-source pane includes the frontmatter fence. Default
    /// false: the source pane shows body only, so the Done.md-managed `feishu:`
    /// metadata (a machine-bookkeeping blob, not user prose) doesn't eat the
    /// top of the reading area. The MD-source top bar's "frontmatter" entry
    /// toggles this to reveal it on demand. Display-only — disk always keeps
    /// the full document (save serializes `parsedDocument`), so hiding it in
    /// the preview never drops it from the file.
    private(set) var sourceShowsFrontmatter = false

    /// Push the current document serialized to canonical Markdown into the
    /// source pane. Body-only by default (see `sourceShowsFrontmatter`).
    func pushCurrentMarkdownToSource() {
        // Body-only serialization drives the AI-readability estimate (#82)
        // regardless of the frontmatter toggle: frontmatter is Feishu sync
        // metadata, not content you'd feed an AI, so it never inflates the
        // token readout. Computed here (not only when the pane shows body) so
        // the readout stays correct even while frontmatter is revealed.
        let body = MarkdownEngine.serialize(document: tiptapDocument)
        documentSizeStore.update(bodyMarkdown: body)

        guard let coordinator = markdownSourceCoordinator else { return }
        let markdown = sourceShowsFrontmatter
            ? MarkdownEngine.serialize(document: parsedDocument)
            : body
        coordinator.sendMarkdownSource(markdown)
    }

    /// Toggle whether the MD-source pane shows the frontmatter fence, then
    /// re-render the pane. Called by the MD-source top bar's entry.
    func setSourceShowsFrontmatter(_ show: Bool) {
        sourceShowsFrontmatter = show
        pushCurrentMarkdownToSource()
    }

    /// The current document body serialized to canonical Markdown, *without*
    /// frontmatter. Used by the [[AI 助手]] 续写 path as whole-document context
    /// ([[Context 窗口]] = 整篇文档) — frontmatter is sync metadata, not voice.
    func currentBodyMarkdown() -> String {
        MarkdownEngine.serialize(document: tiptapDocument)
    }

    /// Pull the latest doc state from Visual, replace the in-memory doc,
    /// serialize, and push to the source pane. Called from Visual's
    /// `documentChanged` bridge handler so the source pane mirrors
    /// edits in real time.
    func syncFromVisualToSource() {
        guard let visual = visualCoordinator else { return }
        visual.fetchCurrentDocumentState { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let body):
                self.parsedDocument.body = body
            case .failure(let error):
                debugLog("[sync] Visual fetch failed; using last-known state: \(error)")
            }
            self.pushCurrentMarkdownToSource()
        }
    }

    /// Push the in-memory `tiptapDocument` to BOTH panes. Used after an
    /// external-modification revert — Swift just re-read the file from disk
    /// so its in-memory copy is the truth source; the WebViews need to
    /// catch up.
    private func reloadAllPanesFromCurrentDocument() {
        visualCoordinator?.pushDocumentFromSwift()
        pushCurrentMarkdownToSource()
    }

    // MARK: External modification handling (Slice 12)

    /// Last on-disk modification date we've actually consumed (either by
    /// reading the file or by writing it ourselves via save). Used as the
    /// gate inside `presentedItemDidChange`: if the file's current mtime
    /// equals what we already know about, the callback is a false-positive
    /// (most commonly: macOS firing `presentedItemDidChange` every ~1s on
    /// idle docs in some Finder/iCloud configurations) and we ignore it
    /// rather than calling revert in a tight loop.
    ///
    /// `nil` until the first read/write completes — first
    /// `presentedItemDidChange` after open seeds it from the disk mtime.
    private var knownDiskModificationDate: Date?

    /// NSDocument is itself an `NSFilePresenter`; this method fires when
    /// the file the document is showing changes on disk (`git pull`, vim
    /// save, etc.). We branch on dirty state:
    ///   clean → silently re-read the file and push the new content into
    ///           both panes.
    ///   dirty → present a three-button choice in Chinese.
    override func presentedItemDidChange() {
        // NSFilePresenter callbacks come in on `presentedItemOperationQueue`.
        // Hop to main for UI / NSAlert work.
        DispatchQueue.main.async { [weak self] in
            self?.handleExternalModification()
        }
    }

    private func handleExternalModification() {
        guard let url = fileURL else { return }

        // mtime gate: if the disk file hasn't actually changed since we
        // last consumed it, this callback is noise (macOS / iCloud /
        // FSEvents over-firing). Bailing here avoids the read storm
        // observed during real-device verification on 2026-05-29.
        let currentMtime = (try? FileManager.default
            .attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
        if let known = knownDiskModificationDate,
           let current = currentMtime,
           known == current {
            return
        }
        if let current = currentMtime {
            knownDiskModificationDate = current
        }

        if isDocumentEdited {
            promptUserAboutExternalChange(url: url)
        } else {
            silentlyRevert(to: url)
        }
    }

    private func silentlyRevert(to url: URL) {
        let typeName = fileType ?? "net.daringfireball.markdown"
        do {
            try revert(toContentsOf: url, ofType: typeName)
            reloadAllPanesFromCurrentDocument()
        } catch {
            debugLog("[external] silent revert failed: \(error)")
        }
    }

    private func promptUserAboutExternalChange(url: URL) {
        let alert = NSAlert()
        alert.messageText = "「\(url.lastPathComponent)」已被外部修改"
        alert.informativeText = "你还有未保存的改动。要保留正在编辑的版本，还是加载磁盘上的新内容？"
        alert.addButton(withTitle: "保留我的修改")
        alert.addButton(withTitle: "加载磁盘版本")
        alert.addButton(withTitle: "取消")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            // Keep my changes — do nothing. The next Cmd+S overwrites disk.
            break
        case .alertSecondButtonReturn:
            silentlyRevert(to: url)
        default:
            // 取消 — do nothing. User can decide later.
            break
        }
    }

    override class var autosavesInPlace: Bool {
        // Stay false on purpose: in-place autosave would write to the user's
        // file every minute, and our stable-normalization model would push
        // canonical edits back to disk on each tick — surprising. Cmd+S
        // remains the only path that touches the user's actual file.
        return false
    }

    // Note: we previously set `autosavesDrafts = true` to enable
    // ~/Library/Autosave Information/ drafts and the standard dirty
    // indicator on untitled docs. That broke NSDocumentController's
    // "open from panel" path on the user's machine — picking a file in
    // the panel never reached `read(from:ofType:)`, suggesting the
    // draft-recovery / autosaving-file-type setup wasn't complete enough
    // for NSDocument's panel-pick code path. We default back to
    // autosavesDrafts == autosavesInPlace == false; revisit when Phase 5
    // wires the full autosave story.

    override func read(from data: Data, ofType typeName: String) throws {
        debugLog("[doc] read \(typeName), \(data.count) bytes")
        guard let markdown = String(data: data, encoding: .utf8) else {
            throw NSError(
                domain: NSCocoaErrorDomain,
                code: NSFileReadInapplicableStringEncodingError,
                userInfo: [NSLocalizedDescriptionKey: "文件不是 UTF-8 文本"]
            )
        }
        parsedDocument = MarkdownEngine.parseDocument(source: markdown)
        // Opening an existing file → restore the remembered 大纲 open/closed
        // choice (方案 A sticky default). New untitled windows never reach here,
        // so they keep the collapsed default from OutlineVisibilityStore.init.
        // `read` can run off-main on initial open; the store's didSet only
        // touches UserDefaults, and isVisible is observed via @Published, so
        // hop to main to publish the seeded value cleanly.
        if Thread.isMainThread {
            outlineVisibility.seedFromStickyDefault()
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.outlineVisibility.seedFromStickyDefault()
            }
        }
        // #53 status bar — publish the binding state so the SwiftUI
        // status bar shows up immediately on file open, not only after
        // the first push/pull.
        bindingState.update(from: parsedDocument.frontmatter)
        // Seed the centered-title chrome on open (updateChangeCount won't
        // fire for a clean open).
        titleState.update(title: displayName, isEdited: isDocumentEdited)
        debugLog(
            "[doc] parsed -> \(parsedDocument.body.content?.count ?? 0) blocks, "
            + "frontmatter=\(parsedDocument.frontmatter.hasFence ? "present" : "none")"
        )
        // Seed the mtime gate the first chance we get — once `fileURL` is
        // available, read its mtime so the first `presentedItemDidChange`
        // callback has a baseline to compare against. Without this seed,
        // the gate fires through one redundant revert before catching up.
        if let url = fileURL,
           let mtime = (try? FileManager.default
            .attributesOfItem(atPath: url.path)[.modificationDate]) as? Date {
            knownDiskModificationDate = mtime
        }
        // Record into the launch session: any document that reaches read(from:)
        // has a fileURL (Finder double-click / Cmd+O / session restore itself).
        // note(opened:) is idempotent, so re-opening a restored file is a no-op.
        if let url = fileURL {
            Task { @MainActor in
                AppDelegate.openSessionStore.note(opened: url)
            }
        }
    }

    /// Single funnel for the centered-title chrome (Phase 5 polish). Every
    /// dirty transition — typing (`documentChanged` bridge), sync writebacks,
    /// and save (which calls `.changeCleared`) — passes through here, so one
    /// override keeps `titleState.isEdited` in sync without patching each
    /// call site. `displayName` is re-read here too because Save As can
    /// rename the document.
    override func updateChangeCount(_ change: NSDocument.ChangeType) {
        super.updateChangeCount(change)
        titleState.update(title: displayName, isEdited: isDocumentEdited)
    }

    /// The window's proxy icon — and with it the native title-bar rename
    /// dropdown (click the title → editable "名称" field) — only appears when
    /// `representedURL` points at the file. NSDocument normally syncs this via
    /// `synchronizeWindowTitleWithDocumentName`, but our `.fullSizeContentView`
    /// + manually-assigned `window.title` chrome suppresses that automatic
    /// path, so the dropdown never shows unless we set it ourselves. Kept in
    /// sync on open and on Save-As rename via the `fileURL` override below.
    override var fileURL: URL? {
        didSet { syncWindowRepresentedURLs() }
    }

    /// Point every window's proxy icon at the current file (nil for untitled
    /// docs, which correctly have no rename affordance). Marshals to main —
    /// `fileURL` can be assigned off-main during initial open.
    private func syncWindowRepresentedURLs() {
        let url = fileURL
        let apply = { [weak self] in
            guard let self else { return }
            for controller in self.windowControllers {
                controller.window?.representedURL = url
            }
        }
        if Thread.isMainThread {
            apply()
        } else {
            DispatchQueue.main.async(execute: apply)
        }
    }

    override func data(ofType typeName: String) throws -> Data {
        let markdown = MarkdownEngine.serialize(document: parsedDocument)
        guard let data = markdown.data(using: .utf8) else {
            throw NSError(
                domain: "com.shampoo.donemd",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "序列化结果不是合法 UTF-8"]
            )
        }
        return data
    }

    /// Override the async save entry point so we can pull current Tiptap
    /// state from the WebView before NSDocument's machinery calls
    /// `data(ofType:)`. The default Cmd+S → save chain is synchronous and
    /// `data(ofType:)` alone has no opportunity to wait on `evaluateJavaScript`.
    override func save(
        to url: URL,
        ofType typeName: String,
        for saveOperation: NSDocument.SaveOperationType,
        completionHandler: @escaping (Error?) -> Void
    ) {
        guard let coordinator = visualCoordinator else {
            // No WebView attached. Fall back to the existing in-memory
            // tiptapDocument (the one read from disk).
            super.save(to: url, ofType: typeName, for: saveOperation, completionHandler: completionHandler)
            return
        }
        coordinator.fetchCurrentDocumentState { [weak self] result in
            guard let self else {
                completionHandler(nil)
                return
            }
            switch result {
            case .success(let body):
                self.parsedDocument.body = body
            case .failure(let error):
                debugLog("[save] fetch from JS FAILED; using last-known state: \(error)")
                // Don't fail — fall back to in-memory state so the user
                // doesn't lose data on a transient bridge hiccup.
            }

            // First-save prompt: only on a user-initiated normal save of
            // an existing file path that hasn't been prompted yet. Save As
            // (untitled → named, or relocation) and any autosave variant
            // skip the dialog.
            let needsFirstSavePrompt =
                saveOperation == .saveOperation &&
                FirstSavePromptCoordinator.shared.shouldPrompt(forFileAt: url)

            if needsFirstSavePrompt {
                self.runFirstSavePrompt(
                    to: url, ofType: typeName,
                    for: saveOperation, completionHandler: completionHandler
                )
            } else {
                self.proceedWithSuperSave(
                    to: url, ofType: typeName,
                    for: saveOperation, completionHandler: completionHandler
                )
            }
        }
    }

    // MARK: First-save prompt (Slice 7)

    private func runFirstSavePrompt(
        to url: URL,
        ofType typeName: String,
        for saveOperation: NSDocument.SaveOperationType,
        completionHandler: @escaping (Error?) -> Void
    ) {
        // Pre-compute disk-form before & canonical after so the
        // "看看改了哪些" diff sheet renders instantly when requested.
        let originalText = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let canonicalText = MarkdownEngine.serialize(document: parsedDocument)

        DispatchQueue.main.async { [weak self] in
            guard let self else {
                completionHandler(nil)
                return
            }
            let alert = NSAlert()
            alert.messageText = "第一次保存这份文档"
            alert.informativeText =
                "Done.md 会顺手把格式过一遍，标题、列表、空行这些细节会统一💪。放心❤️，内容不会动。\n\n"
                + "之后每次保存都会跟这次保持一致的风格。"
            // NSAlert button order: first-added is rightmost (default),
            // subsequent stack to the left. PRD wants:
            //   [ 看看改了哪些 ] [ 取消 ] [ 好的，保存 ]
            // → add 好的，保存 first, then 取消, then 看看改了哪些.
            alert.addButton(withTitle: "好的，保存")
            alert.addButton(withTitle: "取消")
            alert.addButton(withTitle: "看看改了哪些")

            let response = alert.runModal()
            // ALL three buttons (including 取消) silence the prompt for
            // this file on future saves — per PRD.
            FirstSavePromptCoordinator.shared.markPrompted(forFileAt: url)

            switch response {
            case .alertFirstButtonReturn: // 好的，保存
                self.proceedWithSuperSave(
                    to: url, ofType: typeName,
                    for: saveOperation, completionHandler: completionHandler
                )
            case .alertSecondButtonReturn: // 取消
                completionHandler(nil)
            case .alertThirdButtonReturn: // 看看改了哪些
                self.presentDiffSheet(before: originalText, after: canonicalText) { proceed in
                    if proceed {
                        self.proceedWithSuperSave(
                            to: url, ofType: typeName,
                            for: saveOperation, completionHandler: completionHandler
                        )
                    } else {
                        completionHandler(nil)
                    }
                }
            default:
                completionHandler(nil)
            }
        }
    }

    private func presentDiffSheet(
        before: String,
        after: String,
        completion: @escaping (Bool) -> Void
    ) {
        guard let parentWindow = windowControllers.first?.window else {
            // No window to attach to — fall back to silently confirming.
            completion(true)
            return
        }

        // Hold the sheet window strongly while it's up; the closure
        // resolves the user's choice and dismisses the sheet.
        var sheetWindow: NSWindow?
        var settled = false
        let resolve: (Bool) -> Void = { proceed in
            guard !settled else { return }
            settled = true
            if let sheet = sheetWindow {
                parentWindow.endSheet(sheet)
            }
            completion(proceed)
        }

        let view = FirstSaveDiffView(before: before, after: after) { proceed in
            resolve(proceed)
        }
        let hosting = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hosting)
        window.setContentSize(NSSize(width: 900, height: 560))
        sheetWindow = window
        parentWindow.beginSheet(window)
    }

    /// Helper extracted so `super.save(...)` doesn't sit inside a closure
    /// that explicitly captures `self` — Swift currently disallows that
    /// combination.
    ///
    /// Pipes through asset migration on success, AND marks the file as
    /// "first-save prompted" so subsequent saves of the same path don't
    /// re-fire the dialog. Idempotent — safe regardless of whether the
    /// prompt path already called markPrompted.
    private func proceedWithSuperSave(
        to url: URL,
        ofType typeName: String,
        for saveOperation: NSDocument.SaveOperationType,
        completionHandler: @escaping (Error?) -> Void
    ) {
        super.save(to: url, ofType: typeName, for: saveOperation) { error in
            if error == nil {
                let docDir = url.deletingLastPathComponent()
                do {
                    try self.assetsManager.migrateAssets(to: docDir)
                } catch {
                    debugLog("[save] asset migration failed (non-fatal): \(error)")
                }
                FirstSavePromptCoordinator.shared.markPrompted(forFileAt: url)
                // Record into the launch session now that this document has a
                // fileURL on disk — covers untitled→named (Save As), Feishu
                // import → Cmd+S, and Cmd+N → Cmd+S. note(opened:) is idempotent.
                Task { @MainActor in
                    AppDelegate.openSessionStore.note(opened: url)
                }
                // Seed the mtime gate so the next presentedItemDidChange
                // (which super.save can itself trigger) doesn't read this
                // exact write back as an "external modification".
                if let mtime = (try? FileManager.default
                    .attributesOfItem(atPath: url.path)[.modificationDate]) as? Date {
                    self.knownDiskModificationDate = mtime
                }
            }
            completionHandler(error)
        }
    }

    /// Replace the document's frontmatter in memory and refresh the source
    /// pane so the user sees the YAML change immediately. Used by sync
    /// coordinators (v2-9 push, v2-8 pull) that need to write back fields
    /// like `feishu.doc_token` / `feishu.last_pushed_at` after a remote
    /// round-trip. Marks the document dirty so a subsequent Cmd+S persists
    /// the change to disk.
    func applyUpdatedFrontmatter(_ frontmatter: Frontmatter) {
        parsedDocument.frontmatter = frontmatter
        updateChangeCount(.changeDone)
        pushCurrentMarkdownToSource()
    }

    /// Like `applyUpdatedFrontmatter`, but follows the in-memory update
    /// with an immediate save to disk so the new frontmatter (e.g. the
    /// `feishu.doc_token` minted by the push that just succeeded) is
    /// durable. Required after a remote round-trip — leaving it in memory
    /// means the next push can't see the binding and would create a
    /// duplicate Feishu doc, and a window close / app quit could lose
    /// the binding entirely.
    ///
    /// Returns `nil` on success, or:
    ///   - `.untitled` if the document has no fileURL yet (the user
    ///     never saved the file). Caller should prompt the user to save.
    ///   - `.saveFailed(error)` if `super.save` returned an error.
    func applyUpdatedFrontmatterAndSave(
        _ frontmatter: Frontmatter,
        completion: @escaping (FrontmatterPersistError?) -> Void
    ) {
        parsedDocument.frontmatter = frontmatter
        bindingState.update(from: frontmatter)
        updateChangeCount(.changeDone)
        pushCurrentMarkdownToSource()

        guard let url = fileURL else {
            // Untitled doc — there's nothing to save into. The frontmatter
            // is held in memory; the Save dialog the user sees on first
            // Cmd+S will write it out alongside the body.
            completion(.untitled)
            return
        }
        let typeName = fileType ?? "net.daringfireball.markdown"
        // Save through the document's own override so the WebView body
        // fetch + first-save prompt + asset migration logic all run.
        // First-save prompt won't fire here normally because by the time
        // the user hits "同步到飞书" they've already saved at least once
        // for the file to have a URL — but if it does fire, the user
        // gets the standard prompt and the save proceeds on confirm.
        save(to: url, ofType: typeName, for: .saveOperation) { error in
            if let error {
                completion(.saveFailed(error))
            } else {
                completion(nil)
            }
        }
    }

    enum FrontmatterPersistError {
        case untitled
        case saveFailed(Error)
    }

    /// Replace the entire in-memory `parsedDocument` (body + frontmatter)
    /// with `updated` and immediately persist to disk. Used by the v2-8
    /// pull flow: a Feishu pull rebuilds the body from remote blocks, so
    /// unlike push (which only stamps frontmatter) the body itself
    /// changes too — both panes must catch up and the change must hit
    /// disk before the next external-modification check fires.
    ///
    /// Bypasses the standard `save(to:ofType:)` override path because
    /// that path fetches the latest body from the Visual WebView
    /// (correct for user-driven Cmd+S; wrong here — `parsedDocument` is
    /// already the truth, freshly built from Feishu, and must not be
    /// overwritten by whatever the WebView is still showing).
    ///
    /// Replace the document's body+frontmatter in memory only — used by
    /// the #58 createNew import path, where the user pastes a Feishu URL
    /// into a fresh untitled window. We don't want to save automatically
    /// because the user hasn't picked a location yet; the standard
    /// NSDocument flow (Cmd+S → NSSavePanel) does that. Marks the doc
    /// dirty so closing the window prompts to save.
    ///
    /// `applyUpdatedDocumentAndSave` returns `.untitled` for this case.
    /// The two helpers share the body-replacement core; this one stops
    /// before the disk write.
    func applyUpdatedDocumentInMemory(_ updated: MarkdownEngine.ParsedDocument) {
        parsedDocument = updated
        bindingState.update(from: updated.frontmatter)
        // #58 URL import fills a fresh untitled window with a full document
        // (content + headings), so it's a "content document" for the 大纲
        // sticky-default rule, not a blank new page — restore the remembered
        // open/closed choice like `read(from:)` does. (This runs on main, from
        // the import command handler.)
        outlineVisibility.seedFromStickyDefault()
        updateChangeCount(.changeDone)
        reloadAllPanesFromCurrentDocument()
    }

    /// Returns `.untitled` if there's no fileURL — used by the #49 pull
    /// path which is always called against an already-saved document.
    /// The #58 createNew path goes through `applyUpdatedDocumentInMemory`
    /// instead.
    func applyUpdatedDocumentAndSave(
        _ updated: MarkdownEngine.ParsedDocument,
        completion: @escaping (FrontmatterPersistError?) -> Void
    ) {
        parsedDocument = updated
        bindingState.update(from: updated.frontmatter)
        updateChangeCount(.changeDone)
        reloadAllPanesFromCurrentDocument()

        guard let url = fileURL else {
            completion(.untitled)
            return
        }
        let typeName = fileType ?? "net.daringfireball.markdown"
        proceedWithSuperSave(
            to: url, ofType: typeName, for: .saveOperation
        ) { error in
            if let error {
                completion(.saveFailed(error))
            } else {
                completion(nil)
            }
        }
    }

    /// Read an image file from disk, hand it to AssetsManager, and tell the
    /// attached WebView to insert the image at the current selection.
    /// Used by the `Cmd+Shift+I` flow.
    func insertImage(from sourceURL: URL) {
        let mime = AssetURLSchemeHandler.mimeType(forFilename: sourceURL.lastPathComponent)
        let bytes: Data
        do {
            bytes = try Data(contentsOf: sourceURL)
        } catch {
            debugLog("[insert-image] failed to read \(sourceURL.path): \(error)")
            return
        }
        let imported: ImportedImage
        do {
            imported = try assetsManager.importImage(data: bytes, mimeType: mime)
        } catch {
            debugLog("[insert-image] AssetsManager failed: \(error)")
            return
        }
        visualCoordinator?.send(
            envelopeOfType: "insertImage",
            payload: .object(["src": .string(imported.assetURL.absoluteString)])
        )
    }

    /// Read a local video file from disk, hand it to AssetsManager, and tell
    /// the attached WebView to insert a `video` node at the current selection
    /// (#88). Mirrors `insertImage(from:)`; the picker (InsertVideoCommand)
    /// only offers WebKit-playable formats, so the imported bytes are always
    /// inline-playable.
    func insertVideo(from sourceURL: URL) {
        let mime = AssetURLSchemeHandler.mimeType(forFilename: sourceURL.lastPathComponent)
        let bytes: Data
        do {
            bytes = try Data(contentsOf: sourceURL)
        } catch {
            debugLog("[insert-video] failed to read \(sourceURL.path): \(error)")
            return
        }
        let imported: ImportedImage
        do {
            imported = try assetsManager.importVideo(data: bytes, mimeType: mime)
        } catch {
            debugLog("[insert-video] AssetsManager failed: \(error)")
            return
        }
        visualCoordinator?.send(
            envelopeOfType: "insertVideo",
            payload: .object(["src": .string(imported.assetURL.absoluteString)])
        )
    }

    /// Insert a table at the caret (插入 menu → 表格, and ⌘⌥T). A 3×3 table
    /// with a header row — Done.md's other table entry (the ⌘⌥T shortcut in
    /// main.ts) uses the same shape. Row/column editing is then done via the
    /// in-editor table toolbar.
    func insertTable() {
        visualCoordinator?.send(envelopeOfType: "insertTable", payload: .null)
    }

    /// Run a text-format command from the native 格式 menu (加粗 / 斜体 / 引用 /
    /// 代码块 …). Forwards the command name to the WebView, which maps it back to
    /// the SAME action the selection floater's button of that name runs
    /// (`runFormatCommand` in bubble-menu.ts — one shared action map, so the
    /// menu and the floater can't drift). The editor applies it to the current
    /// selection / block. Mirrors `insertTable()` above.
    func runFormatCommand(_ command: String) {
        visualCoordinator?.send(
            envelopeOfType: "formatCommand",
            payload: .object(["cmd": .string(command)])
        )
    }

    override func makeWindowControllers() {
        debugLog("[doc] makeWindowControllers")

        let contentSize = computeInitialContentSize()
        let rootView = DonemdDocumentRootView(document: self)
        let hostingController = NSHostingController(rootView: rootView)
        // Don't pin preferredContentSize — that's what was preventing the
        // window from resizing freely after the initial frame. Titlebar
        // alignment is now the system's job (unified NSToolbar below +
        // NavigationSplitView in the root view), so the old safe-area pull
        // hacks are gone.

        let window = NSWindow(contentViewController: hostingController)
        // Standard document-window controls. No `.fullSizeContentView` — we
        // want the system's native titlebar back so a unified NSToolbar can
        // give us the taller titlebar (traffic lights auto-center lower),
        // matching modern macOS sidebar apps (Notes / Icon Composer).
        // `.fullSizeContentView` lets the NavigationSplitView sidebar run
        // full-height up to the window's top edge (like Notes): the sidebar
        // panel visually reaches behind the titlebar row, and the transparent
        // titlebar (traffic lights + toolbar) floats on top of it. Paired with
        // the unified toolbar below for the taller titlebar + centered lights.
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        // Allow the green-button full-screen path.
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.setContentSize(contentSize)
        window.title = displayName
        // Proxy icon → enables the native title-bar rename dropdown. The
        // `fileURL` didSet may have fired before this window existed (initial
        // open reads the file first), so seed it here too. See `fileURL`
        // override for why NSDocument's automatic sync doesn't cover us.
        window.representedURL = fileURL

        // Unified toolbar → taller titlebar. The system centers the traffic
        // lights in the taller area, giving the lower traffic-light line we
        // want everything to align to (Step 1 tracer: verify this moves the
        // lights down before migrating chrome content into the toolbar).
        let toolbar = NSToolbar(identifier: "DonemdDocumentToolbar")
        toolbar.delegate = documentToolbarDelegate
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar
        if #available(macOS 11.0, *) {
            window.toolbarStyle = .unified
        }
        // Keep the Feishu toolbar item present only while the doc is bound.
        documentToolbarDelegate.startObserving(toolbar: toolbar)
        // Seed the centered-title chrome for untitled docs that never hit
        // `read(from:)` (fresh New / createNew import windows).
        titleState.update(title: displayName, isEdited: isDocumentEdited)

        // Compute a sensible default frame BEFORE the autosave restore, so
        // first-launch (no saved frame) lands somewhere reasonable.
        window.setFrame(computeDefaultFrame(for: window), display: false)

        // Restore the user's last-moved frame, if any. This makes the window
        // "sticky" — drag it to a different monitor once, it stays there next
        // launch. Falls back to our computed default if the saved frame is
        // off-screen now (monitor unplugged, resolution changed, …).
        let autosaveName = "DonemdDocumentWindow"
        window.setFrameAutosaveName(autosaveName)
        if !isFrameOnScreen(window.frame) {
            debugLog("[doc] saved window frame off-screen, resetting")
            window.setFrame(computeDefaultFrame(for: window), display: false)
        }

        let controller = NSWindowController(window: window)
        addWindowController(controller)

        // Remove this document's file from the launch session when the user
        // closes its window (but NOT when windows tear down during app quit —
        // AppDelegate.isTerminating guards that, so a normal quit keeps the
        // snapshot written in applicationWillTerminate). Only saved documents
        // (fileURL != nil) are in the session, so untitled closes are no-ops.
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            guard let self, let url = self.fileURL else { return }
            Task { @MainActor in
                if AppDelegate.isTerminating { return }
                AppDelegate.openSessionStore.note(closed: url)
            }
        }

        // macOS 14+ deprecated NSApp.activate(ignoringOtherApps:) and the
        // new no-arg activate() can be ignored by the system. NSRunningApplication
        // with .activateAllWindows is the reliable hammer.
        NSRunningApplication.current.activate(options: [.activateAllWindows])
        controller.showWindow(self)
        window.makeKeyAndOrderFront(self)
        debugLog("[doc] window shown frame=\(window.frame) screen=\(window.screen?.frame ?? .zero) isVisible=\(window.isVisible) isKey=\(window.isKeyWindow)")
    }

    private func computeInitialContentSize() -> NSSize {
        let mouseLocation = NSEvent.mouseLocation
        let target =
            NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
        let visible = target?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let inset: CGFloat = 80
        let width = min(1000, max(640, visible.width - inset * 2))
        let height = min(720, max(480, visible.height - inset * 2))
        return NSSize(width: width, height: height)
    }

    private func computeDefaultFrame(for window: NSWindow) -> NSRect {
        // Pick the screen under the cursor first; fall back to main / any.
        let mouseLocation = NSEvent.mouseLocation
        let target =
            NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
        let visible = target?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let size = window.frame.size
        let centered = NSRect(
            x: visible.midX - size.width / 2,
            y: visible.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
        // Clamp inside the visible area with an 8pt margin.
        return NSRect(
            x: max(visible.minX + 8, min(centered.minX, visible.maxX - size.width - 8)),
            y: max(visible.minY + 8, min(centered.minY, visible.maxY - size.height - 8)),
            width: size.width,
            height: size.height
        )
    }

    /// True if the frame's center sits inside any currently-attached screen.
    private func isFrameOnScreen(_ frame: NSRect) -> Bool {
        let center = NSPoint(x: frame.midX, y: frame.midY)
        return NSScreen.screens.contains(where: { $0.visibleFrame.contains(center) })
    }
}

/// Delegate for the document window's unified NSToolbar. Lays out, left→right:
/// the system sidebar toggle, a tracking separator (aligns the toggle over the
/// sidebar column), a flexible space, then the Feishu action capsule + AI
/// status badge on the trailing side. The document title is the window's own
/// native title (not a toolbar item). The capsule / badge are SwiftUI views
/// hosted via `NSHostingView`; they observe the document's ObservableObject
/// containers so they refresh on their own.
private final class DocumentToolbarDelegate: NSObject, NSToolbarDelegate {
    private weak var document: DonemdDocument?

    init(document: DonemdDocument) {
        self.document = document
    }

    static let feishuItem = NSToolbarItem.Identifier("donemd.feishu")
    static let aiItem = NSToolbarItem.Identifier("donemd.ai")

    /// Cancellable for the bind-state subscription that inserts / removes the
    /// Feishu item so it reads as its own capsule (present only when bound).
    private var bindingObservation: AnyCancellable?

    // The document title is NOT a custom toolbar item — it's the window's
    // native title (see makeWindowControllers), which the system renders as
    // plain text in the unified titlebar with correct placement, rename
    // tracking, and edited state. A view-based title item would pick up the
    // macOS 26 glass "button" background (an unwanted pill) and fight the
    // sidebar tracking separator for placement.
    //
    // The Feishu actions and the AI badge are SEPARATE items so each gets its
    // own system glass capsule (not one shared pill). The Feishu item is only
    // in the default set when the doc is bound; `startObserving` inserts /
    // removes it live on bind / unbind so there's never an empty capsule.
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        // A flexible space BEFORE the toggle (still on the sidebar side of the
        // tracking separator) pushes the sidebar toggle to the sidebar column's
        // right edge — i.e. the panel's top-right — while the sidebar is open.
        // When the sidebar collapses, that region shrinks and the toggle slides
        // back to the far left (next to the traffic lights), all animated by the
        // system. Same button, position driven by the tracking separator.
        var ids: [NSToolbarItem.Identifier] =
            [.flexibleSpace, .toggleSidebar, .sidebarTrackingSeparator, .flexibleSpace]
        if isBound { ids.append(Self.feishuItem) }
        ids.append(Self.aiItem)
        return ids
    }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, .toggleSidebar, .sidebarTrackingSeparator, Self.feishuItem, Self.aiItem]
    }

    private var isBound: Bool {
        guard let feishu = document?.bindingState.feishu else { return false }
        return feishu.docToken != nil
    }

    /// Keep the Feishu item's presence in sync with the binding. Call once the
    /// toolbar is attached to the window.
    func startObserving(toolbar: NSToolbar) {
        guard let document else { return }
        bindingObservation = document.bindingState.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self, weak toolbar] in
                guard let self, let toolbar else { return }
                // objectWillChange fires just before the value updates, so defer.
                DispatchQueue.main.async { self.syncFeishuItem(in: toolbar) }
            }
    }

    private func syncFeishuItem(in toolbar: NSToolbar) {
        let hasItem = toolbar.items.contains { $0.itemIdentifier == Self.feishuItem }
        if isBound && !hasItem {
            // Insert just before the AI item (which is always last).
            let aiIndex = toolbar.items.firstIndex { $0.itemIdentifier == Self.aiItem }
            toolbar.insertItem(withItemIdentifier: Self.feishuItem, at: aiIndex ?? toolbar.items.count)
        } else if !isBound && hasItem {
            if let idx = toolbar.items.firstIndex(where: { $0.itemIdentifier == Self.feishuItem }) {
                toolbar.removeItem(at: idx)
            }
        }
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        guard let document else { return nil }
        switch itemIdentifier {
        case Self.feishuItem:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.view = NSHostingView(
                rootView: ToolbarFeishuView(
                    document: document,
                    bindingState: document.bindingState
                )
            )
            item.visibilityPriority = .high
            return item
        case Self.aiItem:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.view = NSHostingView(rootView: AIStatusBadge(manager: AppDelegate.aiProviderManager))
            item.visibilityPriority = .high
            return item
        default:
            return nil  // .toggleSidebar / separators / spaces are system-provided
        }
    }
}

/// The Feishu action group as its own toolbar item — the capsule chrome is the
/// system's (glass toolbar-item background), so this view is just the four
/// buttons + hairline dividers with a little horizontal inset.
private struct ToolbarFeishuView: View {
    let document: DonemdDocument
    @ObservedObject var bindingState: DonemdDocument.BindingStateContainer

    var body: some View {
        if let feishu = bindingState.feishu, feishu.docToken != nil {
            FeishuActionCapsule(document: document, feishu: feishu)
        }
    }
}


/// SwiftUI root view for a Donemd document window: the dual-pane editor
/// + an optional bottom-edge sync progress bar (#57 step5). Observing
/// `document.syncProgress` rebuilds the layout when push/pull starts
/// or finishes so the bar appears/disappears automatically.
private struct DonemdDocumentRootView: View {
    let document: DonemdDocument
    @ObservedObject var syncProgress: DonemdDocument.SyncProgressContainer
    @ObservedObject var bindingState: DonemdDocument.BindingStateContainer
    @ObservedObject var outlineStore: OutlineStore

    /// 大纲 sidebar open/closed (#78, 方案 A). PER-DOCUMENT now: each window
    /// observes its own document's `outlineVisibility` store instead of a shared
    /// `@AppStorage` key, so toggling one window's sidebar leaves the others
    /// alone. The store still seeds from / writes back the `donemd.outlineVisible`
    /// UserDefaults key — but only as the default for the next new window. The
    /// ⌃⌘S monitor and 显示文档大纲 menu now flip the frontmost document's store
    /// (see AppDelegate / donemdApp). Two-way bridged to `columnVisibility` below.
    @ObservedObject var outlineVisibility: DonemdDocument.OutlineVisibilityStore

    /// Writing background theme (#80 S8). Per-app, display-only — NEVER written
    /// to `.md` disk (story 34). Default `.system` = the pre-S8 transparent look
    /// following the system appearance. Set from the 写作背景 menu.
    @AppStorage("donemd.writingTheme") private var writingThemeRaw = WritingTheme.system.rawValue

    private var writingTheme: WritingTheme {
        WritingTheme(rawValue: writingThemeRaw) ?? .system
    }

    /// Native split-view column visibility. Kept in two-way sync with
    /// `outlineVisible` so the ⌃⌘S UserDefaults contract (AppDelegate) and the
    /// system's own sidebar toggle both drive the same state.
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic

    /// Absolute width (pt) of the right-hand Markdown 源 column. Persisted so
    /// the user's dragged size sticks across launches. The source column is a
    /// FIXED-width inspector (native Xcode / Notes pattern): Visual takes all
    /// remaining width, so opening the 大纲 sidebar shrinks Visual only, never
    /// the source column. We drive this by hand (GeometryReader + a draggable
    /// divider) instead of HSplitView because HSplitView seeds its divider from
    /// child ideal-widths, which a bare WKWebView representable doesn't report —
    /// so it always fell back to a 1:1 split regardless of `idealWidth`.
    @AppStorage("donemd.sourcePaneWidth") private var sourcePaneWidth = 340.0

    /// True while the user is actively dragging the pane divider. Keeps the
    /// resize cursor pinned even when the pointer momentarily leaves the 8pt
    /// grab zone mid-drag (see the divider's `.onHover` / gesture).
    @State private var isDraggingDivider = false

    /// Bounds for the source column drag, also used to clamp on window resize.
    private let sourcePaneMinWidth: CGFloat = 240
    private let sourcePaneMaxWidth: CGFloat = 620
    private let visualMinWidth: CGFloat = 360

    init(document: DonemdDocument) {
        self.document = document
        self.syncProgress = document.syncProgress
        self.bindingState = document.bindingState
        self.outlineStore = document.outlineStore
        self.outlineVisibility = document.outlineVisibility
    }

    var body: some View {
        // Native chrome: a NavigationSplitView gives us the system sidebar
        // (frosted, edge-to-edge, its own toggle + animation) and — paired with
        // the window's unified NSToolbar (see makeWindowControllers) — the taller
        // titlebar with correctly-centered traffic lights. No more hand-drawn
        // top bars or safe-area pull hacks; the system owns the alignment.
        NavigationSplitView(columnVisibility: $columnVisibility) {
            OutlineSidebar(store: outlineStore) { index in
                document.scrollToHeading(index: index)
            }
            // Thin theme wash over the system sidebar material so it picks up the
            // writing-background tint (#80). `.system` → `.clear`, no wash. Behind
            // the sidebar's own material so the frost still reads.
            .background(writingTheme.sidebarWash)
            .navigationSplitViewColumnWidth(min: 200, ideal: 250, max: 360)
        } detail: {
            // Editor panes keep their draggable divider. The bottom sync
            // progress bar rides as a safe-area inset so it never overlaps the
            // editor content.
            GeometryReader { geo in
                // Clamp the source width to what actually fits: it must leave at
                // least visualMinWidth for the Visual column, and stay within its
                // own bounds. This keeps the layout sane at any window/​sidebar
                // size — the source column holds its width, Visual takes the rest.
                let maxSource = max(sourcePaneMinWidth,
                                    min(sourcePaneMaxWidth, geo.size.width - visualMinWidth))
                let sourceW = min(max(sourcePaneWidth, sourcePaneMinWidth), maxSource)

                HStack(spacing: 0) {
                    // Visual is the FLEXIBLE column — it takes all width the
                    // fixed source column doesn't, so opening the 大纲 sidebar
                    // shrinks Visual only.
                    VisualWebView(document: document, webDataTheme: writingTheme.webDataThemeValue)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                    // Draggable divider — replaces HSplitView's built-in handle.
                    // A real 8pt-wide hit target in the HStack flow (not a 1pt
                    // Divider's overlay, whose wider hit area got clipped to the
                    // 1pt frame and never received the drag). A 1pt hairline is
                    // painted in the middle; the surrounding transparent width is
                    // the grab zone. `.onHover` swaps to the resize cursor.
                    // Cursor is managed by an AppKit tracking area
                    // (`.cursorUpdate`, see ResizeCursorStrip), NOT SwiftUI
                    // `.onHover` + `NSCursor.set()`: the adjacent WKWebViews own
                    // tracking areas that reassert the arrow on the next
                    // mouse-moved, so a hover-set cursor got clobbered the
                    // instant the pointer settled — it only "held" mid-drag
                    // because the drag re-set it every frame. AppKit's cursor
                    // rects are the system-level mechanism WebKit can't override.
                    // The VISIBLE seam is only 2pt of tinted canvas showing
                    // through — the ResizeCursorStrip here occupies just 2pt of
                    // layout width (it paints nothing; it only carries the resize
                    // cursor rect). The DRAG hit area is widened to 12pt by a
                    // pure-SwiftUI transparent overlay that does NOT consume
                    // layout width, so grabbing stays easy without fattening the
                    // seam. (Earlier the strip itself was 8pt wide, which is what
                    // read as the fat canvas-colored band the user saw.)
                    ResizeCursorStrip()
                        .frame(width: 2)
                        .overlay(
                            Color.clear
                                .frame(width: 12)
                                .contentShape(Rectangle())
                                .gesture(
                                    DragGesture()
                                        .onChanged { value in
                                            isDraggingDivider = true
                                            NSCursor.resizeLeftRight.set()
                                            // Divider sits at the source column's
                                            // left edge; dragging left widens it.
                                            let proposed = sourceW - value.translation.width
                                            sourcePaneWidth = min(max(proposed, sourcePaneMinWidth), maxSource)
                                        }
                                        .onEnded { _ in
                                            isDraggingDivider = false
                                        }
                                )
                        )

                    VStack(spacing: 0) {
                        MarkdownSourceTopBar(
                            document: document,
                            hasFrontmatter: bindingState.hasFrontmatter,
                            height: 28
                        )
                        MarkdownSourceWebView(document: document, webDataTheme: writingTheme.webDataThemeValue)
                    }
                    // Fixed-width source column (native inspector pattern).
                    .frame(width: sourceW)
                    // Frosted-glass backing for the Markdown 源 pane, matching the
                    // Icon Composer inspector: the source WKWebView is transparent
                    // (drawsBackground=false + CSS transparent), so this material
                    // shows through and blurs the Visual pane / tinted canvas
                    // behind it — a distinct, recessed "source" surface. (#75)
                    .background(.ultraThinMaterial)
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if let model = syncProgress.model {
                    FeishuSyncProgressBar(model: model)
                }
            }
        }
        // Two-way bridge between THIS document's sidebar visibility store and
        // the split view's own visibility (方案 A). The ⌃⌘S monitor and the
        // 显示文档大纲 menu flip the frontmost document's store; the system's own
        // sidebar toggle button writes back through columnVisibility. Both
        // entry points now move only this window, never the others.
        .onAppear { columnVisibility = outlineVisibility.isVisible ? .all : .detailOnly }
        .onChange(of: outlineVisibility.isVisible) { visible in
            let target: NavigationSplitViewVisibility = visible ? .all : .detailOnly
            if columnVisibility != target { columnVisibility = target }
        }
        .onChange(of: columnVisibility) { vis in
            let visible = (vis != .detailOnly)
            if outlineVisibility.isVisible != visible { outlineVisibility.isVisible = visible }
            // Re-anchor both panes after a sidebar toggle. Toggling changes the
            // detail-column width → both WKWebViews resize → WebKit's own scroll
            // anchoring reflows them back to a pre-jump position (the reported
            // bug: outline jump "forgets" its spot when the sidebar closes).
            // There is no persisted scroll offset to lean on, but scrollspy keeps
            // `outlineStore.activeIndex` pointing at the heading currently at the
            // top of the viewport. Capture it NOW, synchronously — a late
            // scrollspy fire during the reflow would otherwise clobber it with the
            // reverted position — then re-issue the same ordinal jump both panes
            // already understand.
            guard let anchor = outlineStore.activeIndex else { return }
            // Fire IMMEDIATELY, not after the animation. `smooth: false` starts a
            // per-frame "pin" loop in the Visual pane (see main.ts) that re-nails
            // the heading to the top on every reflow frame for the animation's
            // duration — so WebKit's frame-by-frame drift is undone as it happens,
            // instead of being watched for 0.45s and yanked back only at the end.
            document.scrollToHeading(index: anchor, smooth: false)
        }
        // Writing-background theme (#80 S8). Painted at the window root so it
        // shows through BOTH transparent WKWebViews (Visual canvas + Markdown 源)
        // and tints the frosted 源 pane material sitting on top of it. Ignoring
        // the safe area lets it run full-bleed under the unified titlebar.
        // `.paper` forces light and `.night` forces dark so chrome/text stay
        // legible on the fixed surface; `.system` leaves appearance to the OS.
        .background(writingTheme.backgroundColor.ignoresSafeArea())
        .preferredColorScheme(writingTheme.forcedColorScheme)
    }

}

/// The Markdown 源 column's transparent top strip. Keeps the source pane's
/// first line aligned with the Visual editor, and — when the document has a
/// frontmatter fence — offers a small grey "frontmatter" entry that toggles
/// whether the `feishu:` machine-metadata block is shown in the source. Default
/// hidden so the source pane opens on real prose, not a `--- feishu: … ---`
/// blob; disk always keeps the full document regardless.
private struct MarkdownSourceTopBar: View {
    let document: DonemdDocument
    let hasFrontmatter: Bool
    let height: CGFloat

    @State private var showFrontmatter = false
    /// AI-readability readout (#82) — recomputed on every push to the source
    /// pane, so the token estimate tracks edits live.
    @ObservedObject var sizeStore: DonemdDocument.DocumentSizeStore

    init(document: DonemdDocument, hasFrontmatter: Bool, height: CGFloat) {
        self.document = document
        self.hasFrontmatter = hasFrontmatter
        self.height = height
        self.sizeStore = document.documentSizeStore
    }

    var body: some View {
        HStack(spacing: 6) {
            if hasFrontmatter {
                Button {
                    showFrontmatter.toggle()
                    document.setSourceShowsFrontmatter(showFrontmatter)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: showFrontmatter ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                        Text("frontmatter")
                            .font(.system(size: 11))
                    }
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(showFrontmatter ? "隐藏文档元数据" : "显示文档元数据（feishu 同步信息等）")
            }
            Spacer()
            if let estimate = sizeStore.estimate {
                DocumentSizeReadout(estimate: estimate)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: height)
    }
}

/// The source-pane AI-readability readout (#82): a color dot (green/yellow/red
/// tier signal, no text label), the ≈token estimate, and a plain-language
/// verdict. Byte size + 字数 live in the hover tooltip so the narrow top bar
/// stays legible. The dot carries the tier strength; the sentence carries the
/// meaning — no abstract "等级词" the user would have to decode.
private struct DocumentSizeReadout: View {
    let estimate: DocumentSizeEstimate

    private var tierColor: Color {
        if estimate.tierColorIsGreen { return Color(red: 0.20, green: 0.72, blue: 0.35) }
        if estimate.tierColorIsYellow { return Color(red: 0.95, green: 0.68, blue: 0.10) }
        return Color(red: 0.90, green: 0.24, blue: 0.22)
    }

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(tierColor)
                .frame(width: 7, height: 7)
            Text(estimate.tokensCompact)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            Text("·")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            Text(estimate.tier.verdict)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .help(
            """
            \(estimate.tier.verdict)
            \(estimate.tokensCompact)（估算，按中英文加权）
            体积 \(estimate.bytesReadable) · \(estimate.charactersReadable)
            """
        )
    }
}

/// A thin AppKit-backed strip that shows the horizontal-resize cursor
/// (`NSCursor.resizeLeftRight`) while the pointer is over it. Used for the
/// Visual ↔ Markdown 源 divider (#78/S9).
///
/// Why AppKit and not SwiftUI `.onHover` + `NSCursor.set()`: the divider sits
/// between two WKWebViews, each of which installs its own tracking areas and
/// reasserts the arrow cursor on `cursorUpdate` / mouse-moved. A cursor set
/// from SwiftUI's hover callback was overwritten the moment the pointer
/// settled. An `NSTrackingArea` with `.cursorUpdate` participates in AppKit's
/// own cursor-rect arbitration, which WebKit can't stomp — so the resize
/// cursor holds on plain hover, not just during a drag.
private struct ResizeCursorStrip: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { CursorView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class CursorView: NSView {
        override func resetCursorRects() {
            super.resetCursorRects()
            addCursorRect(bounds, cursor: .resizeLeftRight)
        }

        // `.cursorUpdate` is the belt to resetCursorRects' suspenders: it fires
        // as the pointer enters and keeps the resize cursor set even when a
        // neighboring view's tracking area would otherwise reassert the arrow.
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(
                rect: bounds,
                options: [.cursorUpdate, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                owner: self,
                userInfo: nil
            ))
        }

        override func cursorUpdate(with event: NSEvent) {
            NSCursor.resizeLeftRight.set()
        }

        override func mouseEntered(with event: NSEvent) {
            NSCursor.resizeLeftRight.set()
        }
    }
}
