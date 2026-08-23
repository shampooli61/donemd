import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var keyEventMonitor: Any?

    /// Process-wide FeishuSyncManager. Lives as long as the app does
    /// (DispatchSource watchers + OAuth state must outlive any
    /// individual document or Settings panel close). The SwiftUI
    /// Settings scene reads it via this singleton — there's no clean
    /// way to inject through @NSApplicationDelegateAdaptor since the
    /// adaptor exposes the delegate type, not specific properties.
    @MainActor public static let feishuSyncManager = FeishuSyncManager()

    /// Process-wide AI provider manager (Phase 3 #62). Owns the
    /// ProviderRegistry + publishes the AI status badge state. Lives as long
    /// as the app so the badge (shown in every document window) and the
    /// Settings § AI Provider panel share one source of truth.
    @MainActor public static let aiProviderManager = AIProviderManager.makeDefault()

    /// Process-wide session store (启动会话恢复). Records the file-backed
    /// document windows open at last quit so a cold launch can re-open them,
    /// independent of the system "Close windows when quitting" preference.
    /// A singleton like the two managers above so `DonemdDocument` can note
    /// open/close as it happens.
    @MainActor public static let openSessionStore = OpenSessionStore()

    /// Set at the very start of `applicationWillTerminate`, before the session
    /// snapshot is written. Document `windowWillClose` observers check this so
    /// that windows torn down *during* quit don't call `note(closed:)` and
    /// erase the snapshot we just recorded. During normal running (close a
    /// window while the app stays alive) it's false, so close is recorded.
    @MainActor public static var isTerminating = false

    /// Cold-launch policy (post #58 / story-47 revision): we manage the
    /// no-document case ourselves in `applicationDidFinishLaunching` — restore
    /// the last session, or open a blank untitled window if there's nothing to
    /// restore. So this returns FALSE: letting AppKit open its own untitled
    /// window here would race our restore and leave a stray blank window
    /// alongside the restored ones. (`applicationShouldHandleReopen` still
    /// opens a blank window on Dock-click-with-no-windows — it doesn't depend
    /// on this hook.)
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        return false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Make sure we're the frontmost app so any window we create gets focus.
        NSRunningApplication.current.activate(options: [.activateAllWindows])

        installKeyEventMonitor()

        // Boot the sync manager: load persisted SyncRoot list, start
        // file system watchers, refresh OAuth state. Runs on the main
        // actor since FeishuSyncManager publishes to SwiftUI.
        AppDelegate.feishuSyncManager.boot()

        // Session restore. Defer to the NEXT runloop turn: by then AppKit has
        // already delivered any openDocument apple event (Finder double-click /
        // CLI `open file`), run State Restoration if the OS chose to, and
        // finished deciding about untitled windows. If `documents` is STILL
        // empty at that point, this is a genuine cold launch with nothing else
        // opening a window — so we restore our recorded session. If a document
        // is already open (double-click / restore / CLI), we leave it alone and
        // do NOT reopen the whole session — the user asked for that one file.
        DispatchQueue.main.async {
            guard NSDocumentController.shared.documents.isEmpty else { return }
            self.restoreLastSessionOrOpenBlank()
        }
    }

    /// Re-open the last session's still-existing files, or fall back to a
    /// blank untitled window. Missing files (deleted / moved / renamed) are
    /// silently skipped; a failed open never blocks the others or shows an
    /// error dialog.
    @MainActor
    private func restoreLastSessionOrOpenBlank() {
        let recorded = AppDelegate.openSessionStore.recordedURLs()
        let existing = OpenSessionStore.existingURLs(from: recorded)

        guard case .restore(let urls) = SessionRestorePlan.decide(recorded: recorded, existing: existing) else {
            NSDocumentController.shared.newDocument(nil)
            return
        }

        let group = DispatchGroup()
        for url in urls {
            group.enter()
            NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, _ in
                // Swallow errors: a file that vanished between the exists-check
                // and here just doesn't open. Other files still restore.
                group.leave()
            }
        }
        group.notify(queue: .main) {
            // If every recorded file failed to open, still give the user a
            // window rather than launching into nothing.
            if NSDocumentController.shared.documents.isEmpty {
                NSDocumentController.shared.newDocument(nil)
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Mark terminating BEFORE anything else, so document windowWillClose
        // observers tearing down during quit skip note(closed:) and don't
        // erase the snapshot we write just below.
        AppDelegate.isTerminating = true
        // Safety-net whole-snapshot rewrite over the incremental note(opened:/
        // closed:) calls DonemdDocument makes. `compactMap { $0.fileURL }`
        // drops untitled drafts (nil fileURL) — we only restore saved files.
        let fileURLs = NSDocumentController.shared.documents.compactMap { $0.fileURL }
        AppDelegate.openSessionStore.replace(with: fileURLs)
        AppDelegate.feishuSyncManager.shutdown()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Document-class macOS apps (TextEdit, BBEdit, Pages, …) stay alive
        // when all document windows close — the user can Cmd+O / Cmd+N or
        // click the Dock icon to come back. Quitting on last-window-close
        // would also kill the app the moment the user cancelled the
        // launch-time open dialog.
        return false
    }

    /// Click the Dock icon when no windows are visible: open a fresh
    /// untitled window — symmetric to the cold-launch behavior above
    /// and consistent with TextEdit / Pages.
    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        if !flag {
            NSDocumentController.shared.newDocument(nil)
        }
        // Default true — let AppKit also do its standard thing (re-show
        // hidden windows, etc.).
        return true
    }

    /// Some keys our menu binds to (notably Cmd+Shift+I) get swallowed by
    /// WKWebView's text input pipeline before NSMenu has a chance to match
    /// them. Catch them via a process-local NSEvent monitor as a fallback.
    private func installKeyEventMonitor() {
        keyEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let chars = event.charactersIgnoringModifiers?.lowercased()
            // Cmd+Shift+I → insert image
            if mods == [.command, .shift] && chars == "i" {
                self.insertImageMenuAction(nil)
                return nil // consume
            }
            // Cmd+S → save current document. We have to do this manually
            // because the SwiftUI App with only a Settings scene doesn't
            // generate the standard File menu, so there's no menu item
            // bound to Cmd+S, and WKWebView ends up swallowing the keystroke.
            if mods == [.command] && chars == "s" {
                if let doc = NSDocumentController.shared.currentDocument {
                    doc.save(nil)
                } else {
                    debugLog("[key] Cmd+S — no current document to save")
                }
                return nil // consume
            }
            // Ctrl+Cmd+S → toggle the 文档大纲 sidebar (#78, 方案 A). Flips ONLY
            // the frontmost document's per-window visibility store, so other
            // open windows keep their own sidebar state. Distinct modifier set
            // from plain Cmd+S above (adds .control), so the two don't collide.
            // WKWebView swallows the keystroke, so like the other shortcuts it
            // has to run through this monitor.
            if mods == [.command, .control] && chars == "s" {
                if let doc = NSDocumentController.shared.currentDocument as? DonemdDocument {
                    doc.outlineVisibility.toggle()
                } else {
                    debugLog("[key] ⌃⌘S — no current document to toggle outline")
                }
                return nil // consume
            }
            // Cmd+N → new untitled document. Same File-menu-absent
            // workaround as Cmd+S. NSDocumentController.newDocument(_:)
            // instantiates DonemdDocument via NSDocumentClass and shows
            // its window via makeWindowControllers.
            if mods == [.command] && chars == "n" {
                NSDocumentController.shared.newDocument(nil)
                return nil // consume
            }
            // Cmd+O → open file dialog. Same File-menu-absent workaround.
            // NSDocumentController.openDocument(_:) is the standard "Open…"
            // action — shows the open panel filtered to our document types.
            if mods == [.command] && chars == "o" {
                NSDocumentController.shared.openDocument(nil)
                return nil // consume
            }
            return event
        }
    }

    @objc private func insertImageMenuAction(_ sender: Any?) {
        guard let url = InsertImageCommand.presentOpenPanel() else { return }
        // Route the picked file through the frontmost document's
        // AssetsManager + WebView. If there's no current document we
        // silently no-op — the user has nowhere to insert it anyway.
        if let document = NSDocumentController.shared.currentDocument as? DonemdDocument {
            document.insertImage(from: url)
        } else {
            debugLog("[insert-image] no current document for \(url.path)")
        }
    }
}
