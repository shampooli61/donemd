import SwiftUI
import UIKit

/// Panel state belongs to the session, not to a size-class branch.
final class MobileEditorPanelDraft: ObservableObject {
    @Published var route: String?
    @Published var format = false
    @Published var formatSheet = false
    @Published var token: String?
    @Published var text = ""
    @Published var language = ""
    @Published var display = false
    @Published var rows = 3
    @Published var columns = 3
    @Published var query = ""
    @Published var searchComposing = false
    @Published var replacement = ""
    @Published var source = ""
    @Published var feedback: String?
    @Published var editing = false
    @Published var restoreBookmark = true
}

struct MobileEditorWorkspace: View {
    @ObservedObject var document: MobileDocument
    @ObservedObject var editor: MobileEditorController
    let saving: Bool
    let sharing: Bool
    let save: (Bool) -> Void
    let recover: () -> Void
    let share: (Bool) -> Void
    let media: (Bool, String?, String?) -> Void
    @EnvironmentObject private var session: DocumentOpenCoordinator
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.verticalSizeClass) private var verticalSize
    @StateObject private var panel = MobileEditorPanelDraft()
    @State private var resolvingConflict = false
    @State private var keyboardVisible = false
    @State private var availableHeight: CGFloat = 0

    private var writable: Bool { editor.state.ready && editor.state.editable && !editor.state.locked && !editor.state.composing && !editor.busy }
    var body: some View {
        VStack(spacing: 0) {
            notices
            if document.importing { ProgressView("正在导入附件…") }
            if sharing { ProgressView("正在准备分享…") }
            MobileWebView(document: document)
        }
        .navigationTitle(document.fileURL.deletingPathExtension().lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in keyboardVisible = true }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidHideNotification)) { _ in keyboardVisible = false }
        .background {
            GeometryReader { geometry in
                Color.clear
                    .onAppear { availableHeight = geometry.size.height }
                    .onChange(of: geometry.size.height) { _, height in availableHeight = height }
            }
        }
        .sheet(isPresented: $panel.formatSheet) {
            MobileEditorFormatPanel(editor: editor, draft: panel)
                .presentationDetents([.large])
        }
        .popover(isPresented: Binding(get: { panel.route != nil }, set: { if !$0 { panel.route = nil } })) {
            MobileEditorPanel(editor: editor, draft: panel, media: media)
                .frame(idealWidth: 340, idealHeight: 540)
                .presentationCompactAdaptation(.sheet)
                .presentationDetents([.large])
        }
        .onChange(of: panel.route) { old, new in if old != nil && new == nil { restoreSelection() } }
        .modifier(MobileEditorSubtitle(value: subtitle))
        .onChange(of: panel.format) { _, showing in if !showing { restoreSelection() } }
        .onChange(of: panel.formatSheet) { _, showing in if !showing { restoreSelection() } }
    }

    private var subtitle: String {
        if saving { return "正在保存…" }
        if editor.state.searchActive { return "\(editor.state.searchCurrent)/\(editor.state.searchCount)" }
        if !editor.state.editable && editor.state.ready { return "只读" }
        return ""
    }
    @ViewBuilder private var notices: some View {
        if session.pendingURL != nil || session.error != nil || document.conflict || blockingMessage != nil || document.needsNormalization || editor.error != nil {
            VStack(alignment: .leading, spacing: 8) {
                if let pending = session.pendingURL {
                    Label("待打开：" + pending.lastPathComponent, systemImage: "doc.text").labelStyle(.titleAndIcon).font(.callout.bold())
                    Text("请先保存并返回目录，再打开这份文档。")
                    Button("保存并返回目录后继续") { save(true) }.disabled(saving)
                    Button("取消待打开文档") { session.cancelPending() }
                } else if document.conflict {
                    Label("发现其他版本", systemImage: "doc.on.doc").labelStyle(.titleAndIcon).font(.callout.bold())
                    if resolvingConflict { ProgressView("正在保留版本并加载磁盘内容…") }
                    Button("保留所有版本并加载磁盘内容") {
                        guard !resolvingConflict else { return }
                        resolvingConflict = true
                        Task {
                            defer { resolvingConflict = false }
                            do { try await document.preserveConflictsAndReload() }
                            catch { editor.error = error.localizedDescription }
                        }
                    }.disabled(resolvingConflict || editor.state.composing || editor.busy)
                    if let error = editor.error { Text(error).foregroundStyle(.red) }
                } else if let error = editor.error ?? session.error ?? blockingMessage {
                    Label("操作未完成", systemImage: "exclamationmark.triangle").labelStyle(.titleAndIcon).font(.callout.bold())
                    Text(error).accessibilityIdentifier("document-status")
                    if editor.error != nil { Button("关闭提示") { editor.error = nil } }
                } else if document.needsNormalization {
                    Label("首次保存需要确认", systemImage: "info.circle").labelStyle(.titleAndIcon).font(.callout.bold())
                    Button("查看说明并保存") { save(false) }.disabled(saving)
                }
                if session.pendingURL != nil || document.conflict {
                    DisclosureGroup("详情") {
                        if let message = document.message { Text(message) }
                        if let error = session.error { Text(error) }
                        if let error = editor.error { Text(error) }
                    }
                }
            }.font(.callout).padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
        }
    }
    private var blockingMessage: String? {
        guard let value = document.message else { return nil }
        let routine = ["与已保存版本一致", "有未保存修改", "有新的未保存修改", "已保存到本机 · iCloud 由系统同步", "保存前需确认 Markdown 格式规范化", "附件已写入，正在插入正文", "附件已插入正文", "已载入恢复版本，请保存", "已加载磁盘版本；各版本均保留为同目录冲突副本"]
        return routine.contains(value) ? nil : value
    }
    private var returnButton: some View {
        Button { save(true) } label: {
            Label("保存并返回目录", systemImage: "chevron.backward").labelStyle(.iconOnly)
        }.labelStyle(.iconOnly).disabled(saving)
    }
    private var dismissKeyboardButton: some View {
        Button { command("keyboard.dismiss") } label: {
            Label("收起键盘", systemImage: "checkmark").labelStyle(.iconOnly)
        }
        .labelStyle(.iconOnly)
        .accessibilityIdentifier("native-keyboard-dismiss")
        .disabled(editor.state.composing)
        .accessibilityHint(editor.state.composing ? "请先完成中文选字" : "")
    }
    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        if #available(iOS 27.0, *) {
            ToolbarItem(placement: .topBarLeading) { returnButton }
                .visibilityPriority(ToolbarItemVisibilityPriority(higherThan: .high))
            if editor.state.focused || keyboardVisible {
                // The system owns placement. Pinned trailing prevents the current
                // keyboard task from being hidden by lower-priority edit tools.
                ToolbarItem(placement: .topBarPinnedTrailing) { dismissKeyboardButton }
                    .visibilityPriority(.high)
            }
        } else {
            ToolbarItem(placement: .topBarLeading) { returnButton }
            if editor.state.focused || keyboardVisible {
                ToolbarItem(placement: .confirmationAction) { dismissKeyboardButton }
            }
        }
        if editor.state.searchActive {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { command("search.previous") } label: { Label("上一处", systemImage: "chevron.up").labelStyle(.iconOnly) }.labelStyle(.iconOnly).disabled(editor.state.searchCount == 0)
                Button { command("search.next") } label: { Label("下一处", systemImage: "chevron.down").labelStyle(.iconOnly) }.labelStyle(.iconOnly).disabled(editor.state.searchCount == 0)
                Button { command("search.close") } label: { Label("关闭查找", systemImage: "xmark").labelStyle(.iconOnly) }.labelStyle(.iconOnly)
            }
        } else if editor.state.editable {
            if #available(iOS 27.0, *) {
                ToolbarItem(placement: .primaryAction) { history }.visibilityPriority(.automatic)
                ToolbarItem(placement: .primaryAction) { format }.visibilityPriority(.high)
                ToolbarItem(placement: .primaryAction) { insert }.visibilityPriority(.low)
            } else {
                ToolbarItem(placement: .primaryAction) { history }
                ToolbarItem(placement: .primaryAction) { format }
                ToolbarItem(placement: .primaryAction) { insert }
            }
        } else {
            ToolbarItem(placement: .primaryAction) {
                Button { command("mode.set", ["editable": "true"]) } label: { Label("编辑", systemImage: "square.and.pencil").labelStyle(.iconOnly) }.labelStyle(.iconOnly).disabled(editor.state.locked)
            }
        }
        if #available(iOS 27.0, *) {
            ToolbarOverflowMenu { more }
        } else {
            ToolbarItem(placement: .primaryAction) {
                Menu { more } label: { Label("更多操作", systemImage: "ellipsis").labelStyle(.iconOnly) }.labelStyle(.iconOnly).accessibilityIdentifier("native-more")
            }
        }
    }
    private var history: some View {
        Menu {
            Button { command("history.undo") } label: { Label("撤销", systemImage: "arrow.uturn.backward").labelStyle(.titleAndIcon) }.disabled(!writable || !editor.state.canUndo)
            Button { command("history.redo") } label: { Label("重做", systemImage: "arrow.uturn.forward").labelStyle(.titleAndIcon) }.disabled(!writable || !editor.state.canRedo)
        } label: { Label("撤销与重做", systemImage: "arrow.uturn.backward").labelStyle(.iconOnly) }.labelStyle(.iconOnly).accessibilityIdentifier("native-history")
    }
    private var format: some View {
        Button {
            Task {
                guard !editor.state.composing, let token = await editor.captureSelection(), !editor.state.composing else { return }
                panel.token = token
                panel.text = editor.state.attributes["href"] ?? ""
                panel.restoreBookmark = true
                // A short popover above the keyboard can expose only its first row.
                // Preserve the captured bookmark and let a native sheet manage keyboard
                // adaptation rather than blurring/committing composition ourselves.
                if keyboardVisible || editor.state.focused || verticalSize == .compact || typeSize.isAccessibilitySize || (availableHeight > 0 && availableHeight < 502) {
                    panel.formatSheet = true
                } else {
                    panel.format = true
                }
            }
        } label: { Label("格式", systemImage: "textformat").labelStyle(.iconOnly) }
        .labelStyle(.iconOnly).accessibilityIdentifier("native-format").disabled(!writable)
        .popover(isPresented: $panel.format) {
            MobileEditorFormatPanel(editor: editor, draft: panel)
                .frame(idealWidth: 340, idealHeight: 470)
                .presentationCompactAdaptation(.popover)
        }
    }
    private var insert: some View {
        Menu {
            Section("图片与视频") {
                Button { chooseMedia(true) } label: { Label("从照片选择", systemImage: "photo.on.rectangle").labelStyle(.titleAndIcon) }
                Button { chooseMedia(false) } label: { Label("从文件选择", systemImage: "folder").labelStyle(.titleAndIcon) }
            }
            Section("内容") {
                panelButton("表格", "tablecells", "table")
                panelButton("链接", "link", "link")
                Button { withSelection { command("insert.rule", token: $0) } } label: { Label("分隔线", systemImage: "minus").labelStyle(.titleAndIcon) }
                Menu {
                    Button("行内公式") { open("math", display: false) }
                    Button("独立公式") { open("math", display: true) }
                } label: { Label("公式", systemImage: "function").labelStyle(.titleAndIcon) }
                panelButton("代码或图表", "curlybraces", "code")
                panelButton("原文块", "doc.plaintext", "raw")
            }
        } label: { Label("插入", systemImage: "paperclip").labelStyle(.iconOnly) }.labelStyle(.iconOnly).accessibilityIdentifier("native-insert").disabled(!writable || document.importing)
    }
    @ViewBuilder private var more: some View {
        Section {
            panelButton("查找与替换", "magnifyingglass", "search")
            panelButton("文档大纲", "list.bullet.indent", "outline")
            Button { command("mode.set", ["editable": editor.state.editable ? "false" : "true"]) } label: { Label(editor.state.editable ? "阅读模式" : "编辑", systemImage: editor.state.editable ? "book" : "square.and.pencil").labelStyle(.titleAndIcon) }
            panelButton("查看 Markdown 源码", "chevron.left.forwardslash.chevron.right", "source")
        }
        Section {
            Menu {
                Button { share(false) } label: { Label("Markdown 文件", systemImage: "doc.text").labelStyle(.titleAndIcon) }
                Button { share(true) } label: { Label("文档与附件", systemImage: "paperclip").labelStyle(.titleAndIcon) }
            } label: { Label("分享", systemImage: "square.and.arrow.up").labelStyle(.titleAndIcon) }.disabled(sharing)
            Button { save(false) } label: { Label("保存", systemImage: "tray.and.arrow.down").labelStyle(.titleAndIcon) }.disabled(saving)
            Button(action: recover) { Label("恢复版本", systemImage: "clock.arrow.circlepath").labelStyle(.titleAndIcon) }.disabled(!editor.state.ready || editor.state.locked || editor.busy)
        }
        Section {
            panelButton("段落", "paragraphsign", "paragraph")
            Button { openContext() } label: { Label("编辑所选内容", systemImage: "pencil").labelStyle(.titleAndIcon) }.disabled(editor.state.nodeType.isEmpty)
            panelButton("阅读设置与统计", "textformat.size", "reader")
        }
    }
    private func panelButton(_ title: String, _ symbol: String, _ route: String) -> some View {
        Button { open(route) } label: { Label(title, systemImage: symbol).labelStyle(.titleAndIcon) }
    }
    private func command(_ name: String, _ args: [String: String] = [:], token: String? = nil) {
        Task { _ = await editor.perform(name, args: args, selectionToken: token) }
    }
    private func withSelection(_ action: @escaping (String) -> Void) {
        Task { if let token = await editor.captureSelection() { action(token) } }
    }
    private func chooseMedia(_ photos: Bool) { withSelection { media(photos, $0, nil) } }
    private func openContext() {
        let type = editor.state.nodeType.lowercased()
        let route = type.contains("code") ? "code" : type.contains("math") ? "math" : type.contains("raw") ? "raw" : type.contains("table") ? "tableContext" : "attachment"
        open(route, editing: true)
    }
    private func open(_ route: String, editing: Bool = false, display: Bool = false) {
        Task {
            guard let token = await editor.captureSelection() else { return }
            panel.token = token; panel.feedback = nil; panel.editing = editing
            panel.restoreBookmark = !["search", "outline", "source", "reader"].contains(route)
            panel.text = editing ? (editor.state.attributes["text"] ?? editor.state.attributes["alt"] ?? "") : (route == "link" ? editor.state.attributes["href"] ?? "" : "")
            panel.language = editing ? editor.state.attributes["language"] ?? "" : ""
            panel.display = editing ? editor.state.attributes["display"] == "true" : display
            panel.query = editor.state.searchQuery
            panel.searchComposing = false
            if route == "source" {
                let result = await editor.perform("source.get")
                guard result.success, let source = result.data?["source"] else { return }
                panel.source = source
            }
            panel.route = route
        }
    }
    private func restoreSelection() {
        // Restores the JS bookmark without forcing keyboard focus.
        if panel.restoreBookmark, let token = panel.token { command("focus.restore", ["focus": "false"], token: token) }
    }
}

/// Availability is stable for the session; resizing never chooses a new editor branch.
private struct MobileEditorSubtitle: ViewModifier {
    let value: String
    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 26.0, *) { content.navigationSubtitle(Text(value)) }
        else { content.accessibilityValue(value) }
    }
}
