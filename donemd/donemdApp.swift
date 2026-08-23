import SwiftUI

@main
struct DonemdApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    /// Writing background theme (#80 S8). Same `@AppStorage` key the document
    /// root view reads, so picking from the 写作背景 menu re-tints every open
    /// window. Per-app, display-only — never touches `.md` disk (story 34).
    @AppStorage("donemd.writingTheme") private var writingThemeRaw = WritingTheme.system.rawValue

    /// Forward a 格式-menu format command to the frontmost document's WebView.
    /// No-ops (with a log) when there's no current document — the same graceful
    /// degradation the 插入 entries use. The command name maps 1:1 to the
    /// selection floater's `cmd` values (bold / italic / blockquote / …).
    private func runFormat(_ command: String) {
        if let document = NSDocumentController.shared.currentDocument as? DonemdDocument {
            document.runFormatCommand(command)
        } else {
            debugLog("[format] no current document for \(command)")
        }
    }

    var body: some Scene {
        // The app is NSDocument-driven; document windows are created by
        // DonemdDocument.makeWindowControllers, not by SwiftUI scenes.
        // Settings is a TabView: 飞书同步 (v2-10 — login / sync roots /
        // quota) + AI Provider (Phase 3 #62 — provider config / onboarding).
        Settings {
            TabView {
                FeishuSyncSettingsView(manager: AppDelegate.feishuSyncManager)
                    .tabItem { Label("飞书同步", systemImage: "link") }
                AIProviderSettingsView(manager: AppDelegate.aiProviderManager)
                    .tabItem { Label("AI Provider", systemImage: "sparkles") }
            }
        }
            .commands {
                // Custom menus go through SwiftUI .commands so they survive
                // SwiftUI's menu-bar reconciliation (any NSMenu we insert
                // manually via AppDelegate gets overwritten on the next pass).
                // The keyboard shortcut here is for *display* in the menu;
                // actual key handling is done by AppDelegate's NSEvent monitor
                // because WKWebView swallows key events before they reach
                // NSMenu's performKeyEquivalent.

                // 检查更新… — Sparkle auto-update. Sits right under 关于 in the
                // application (Done.md) menu, the macOS-standard home for it.
                // Triggers the standard Sparkle "checking / up to date / update
                // available" flow against the signed appcast.
                CommandGroup(after: .appInfo) {
                    Button("检查更新…") {
                        UpdaterManager.shared.checkForUpdates()
                    }
                }

                // File menu entries. The SwiftUI App with only a Settings
                // scene generates no standard File menu, so without these the
                // only way to new/open/save was the bare ⌘N/⌘O/⌘S keystrokes
                // (real-machine feedback #1). The NSEvent monitor still does
                // the actual key handling; these give clickable menu items +
                // shortcut display. Same display-only pattern as 插入 below.
                CommandGroup(replacing: .newItem) {
                    Button("新建") {
                        NSDocumentController.shared.newDocument(nil)
                    }
                    .keyboardShortcut("n", modifiers: [.command])
                    Button("打开…") {
                        NSDocumentController.shared.openDocument(nil)
                    }
                    .keyboardShortcut("o", modifiers: [.command])
                }
                CommandGroup(replacing: .saveItem) {
                    Button("存储") {
                        NSDocumentController.shared.currentDocument?.save(nil)
                    }
                    .keyboardShortcut("s", modifiers: [.command])

                    // 重命名 / 移动到 — the native title-bar rename dropdown never
                    // shows because our .fullSizeContentView + unified-toolbar
                    // chrome suppresses the proxy icon it hangs off of. These call
                    // NSDocument's built-in `renameDocument:` / `moveDocument:`
                    // directly, which give the same inline-rename (the window
                    // title turns into an editable field) without depending on the
                    // proxy dropdown. Routed through the responder chain so they
                    // hit the frontmost document; disabled when there's none.
                    Button("重命名…") {
                        NSApp.sendAction(
                            Selector(("renameDocument:")), to: nil, from: nil
                        )
                    }
                    .disabled(NSDocumentController.shared.currentDocument == nil)
                    Button("移动到…") {
                        NSApp.sendAction(
                            Selector(("moveDocument:")), to: nil, from: nil
                        )
                    }
                    .disabled(NSDocumentController.shared.currentDocument == nil)
                }

                // 显示 menu additions. Until now this menu had nothing of ours;
                // placing entries after .sidebar puts them in the standard 显示
                // menu next to macOS's own sidebar controls.
                //   • 显示文档大纲 — previously only had the ⌃⌘S shortcut (handled
                //     by AppDelegate's NSEvent monitor) with no clickable home.
                //   • 主题模式 — folded in here as a submenu (was a top-level
                //     "写作背景" CommandMenu). A single-item theme picker felt too
                //     thin for its own menu-bar slot, and 主题/外观 belongs
                //     conceptually under 显示. A `Picker` bound to the same
                //     @AppStorage key renders the standard macOS single-choice
                //     submenu — the system draws a checkmark on ONLY the active
                //     theme automatically (the earlier hand-rolled opacity-0
                //     checkmark trick failed in AppKit menus and put a check on
                //     every row). Selecting re-tints every open window live;
                //     display-only, never reaches `.md` disk (story 34).
                CommandGroup(after: .sidebar) {
                    Button("显示文档大纲") {
                        // 方案 A: toggle only the frontmost document's per-window
                        // sidebar store, so other open windows are unaffected.
                        if let doc = NSDocumentController.shared.currentDocument as? DonemdDocument {
                            doc.outlineVisibility.toggle()
                        }
                    }
                    .keyboardShortcut("s", modifiers: [.command, .control])

                    Picker("主题模式", selection: $writingThemeRaw) {
                        ForEach(WritingTheme.allCases) { theme in
                            Text(theme.displayName).tag(theme.rawValue)
                        }
                    }
                }

                // 格式 menu — the native home for every text-format action that
                // otherwise only lived in the selection floater (备忘录 puts these
                // same actions under its 格式 menu). Three sections mirror the
                // floater's three groups: 文字样式 / 段落块 / 插入. Each item shows
                // its real shortcut and, on click, runs the exact same editor
                // action the floater button runs — via the `formatCommand` bridge
                // (marks/blocks) or the existing insert bridges (图片/表格).
                //
                // Shortcuts here are for *display*; WKWebView holds focus and its
                // own keymap does the real key handling (same display-only pattern
                // the File entries above use). 图片… still routes through the
                // NSEvent monitor for ⌘⇧I.
                CommandMenu("格式") {
                    // 文字样式 (inline marks)
                    Button("加粗") { runFormat("bold") }
                        .keyboardShortcut("b", modifiers: [.command])
                    Button("斜体") { runFormat("italic") }
                        .keyboardShortcut("i", modifiers: [.command])
                    Button("删除线") { runFormat("strike") }
                        .keyboardShortcut("x", modifiers: [.command, .shift])
                    Button("行内代码") { runFormat("code") }
                        .keyboardShortcut("e", modifiers: [.command])
                    Button("链接…") { runFormat("link") }
                        .keyboardShortcut("k", modifiers: [.command])

                    Divider()

                    // 段落块 (block conversions)
                    Button("清除格式") { runFormat("clear") }
                        .keyboardShortcut("\\", modifiers: [.command])
                    Button("引用") { runFormat("blockquote") }
                        .keyboardShortcut("b", modifiers: [.command, .shift])
                    Button("代码块") { runFormat("codeBlock") }
                        .keyboardShortcut("c", modifiers: [.command, .option])
                    Button("无序列表") { runFormat("bulletList") }
                        .keyboardShortcut("8", modifiers: [.command, .shift])
                    Button("有序列表") { runFormat("orderedList") }
                        .keyboardShortcut("7", modifiers: [.command, .shift])
                    // 任务列表 (checkbox list) — no floater button, so the menu is
                    // its only discoverable entry point (real-machine feedback:
                    // the feature existed but had no trigger). Routes through the
                    // same formatCommand bridge → runFormatCommand('taskList').
                    Button("任务列表") { runFormat("taskList") }
                    Button("高亮块") { runFormat("callout") }

                    Divider()

                    // 插入 (merged in from the former 插入 menu)
                    Button("图片…") {
                        guard let url = InsertImageCommand.presentOpenPanel() else { return }
                        if let document = NSDocumentController.shared.currentDocument as? DonemdDocument {
                            document.insertImage(from: url)
                        } else {
                            debugLog("[insert-image] no current document for \(url.path)")
                        }
                    }
                    .keyboardShortcut("i", modifiers: [.command, .shift])
                    // 视频… (#88). No shortcut — ⌘⇧I is taken by 图片, and video
                    // insertion is low-frequency; the menu entry is enough.
                    Button("视频…") {
                        guard let url = InsertVideoCommand.presentOpenPanel() else { return }
                        if let document = NSDocumentController.shared.currentDocument as? DonemdDocument {
                            document.insertVideo(from: url)
                        } else {
                            debugLog("[insert-video] no current document for \(url.path)")
                        }
                    }
                    Button("表格") {
                        if let document = NSDocumentController.shared.currentDocument as? DonemdDocument {
                            document.insertTable()
                        } else {
                            debugLog("[insert-table] no current document")
                        }
                    }
                    // Display-only; the ⌘⌥T keystroke is handled by the editor's
                    // own keymap (WKWebView has focus).
                    .keyboardShortcut("t", modifiers: [.command, .option])
                }

                // User-facing 飞书 menu. The push entry adapts its title
                // to whether the current doc is bound to a Feishu doc
                // (frontmatter.feishu.docToken present) or not — but the
                // CommandMenu API doesn't easily reflect mutable per-doc
                // state, so we keep the title generic and let the actual
                // command branch internally.
                CommandMenu("飞书") {
                    Button("同步到飞书…") {
                        FeishuPushCommand.run()
                    }
                    .keyboardShortcut("s", modifiers: [.command, .option])
                    Button("从飞书同步…") {
                        FeishuPullCommand.run()
                    }
                    .keyboardShortcut("o", modifiers: [.command, .option])
                    // 撤销上次拉取 — safety net for the "pull overwrote my
                    // content" hazard (GH #84/#85). Enabled only while a
                    // fresh (≤10 min) pre-pull snapshot exists for the
                    // current document; restores it. Same currentDocument
                    // responder pattern as 重命名 above.
                    Button("撤销上次拉取") {
                        FeishuUndoPullCommand.run()
                    }
                    .disabled(!FeishuUndoPullCommand.isAvailable(
                        for: NSDocumentController.shared.currentDocument as? DonemdDocument
                    ))
                    Divider()
                    Button("从 URL 导入…") {
                        FeishuImportCommand.run()
                    }
                    .keyboardShortcut("i", modifiers: [.command, .option])
                }

                // 主题模式 (was 写作背景) folded into 显示 as a submenu (see
                // CommandGroup(after: .sidebar) above); no top-level slot anymore.

                // v2-10 ship deleted the #DEBUG 调试 menu (飞书登录测试 /
                // 飞书登出). Login / logout / sync root management are now in
                // the system Settings panel under 飞书同步, accessible via
                // ⌘, (Done.md → 设置).
            }
    }
}
