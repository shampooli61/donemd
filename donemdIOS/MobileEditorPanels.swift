import SwiftUI
import UIKit

struct MobileEditorFormatPanel: View {
    @ObservedObject var editor: MobileEditorController
    @ObservedObject var draft: MobileEditorPanelDraft
    @Environment(\.dynamicTypeSize) private var typeSize
    private var enabled: Bool { editor.state.ready && editor.state.editable && !editor.state.locked && !editor.state.composing && !editor.busy }
    var body: some View {
        NavigationStack {
            Form {
                if !enabled { Text(editor.state.composing ? "正在完成输入" : "当前为只读或受保护状态，不能修改。") }
                Section("文本样式") {
                    action("正文", "paragraphsign", "paragraph", selected: editor.state.block == "paragraph")
                    heading(1); heading(2)
                    DisclosureGroup("更多标题") { ForEach(3...6, id: \.self) { heading($0) } }
                    if editor.state.nodeType.lowercased().contains("table") { Text("表格内暂不支持标题").font(.footnote) }
                }
                Section("字符样式") {
                    if typeSize.isAccessibilitySize {
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                            characterStyles
                        }
                    } else {
                        HStack(spacing: 8) { characterStyles }
                    }
                }
                Section("列表") {
                    action("无序列表", "list.bullet", "bullet")
                    action("有序列表", "list.number", "ordered")
                    action("待办列表", "checklist", "task")
                }
                Section("段落") {
                    action("增加缩进", "increase.indent", "indent")
                    action("减少缩进", "decrease.indent", "outdent")
                    action("引用", "text.quote", "quote")
                    action("提示块", "info.bubble", "callout")
                }
                Section {
                    action("清除格式", "textformat", "clear")
                    NavigationLink {
                        MobileEditorLinkForm(editor: editor, draft: draft)
                    } label: { Label("编辑链接", systemImage: "link") }.disabled(!enabled)
                }
                if let error = editor.error { Text(error).foregroundStyle(.red) }
            }
            .navigationTitle("格式").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { draft.format = false; draft.formatSheet = false } label: { Label("关闭", systemImage: "xmark") }.accessibilityIdentifier("native-format-close")
                }
            }
        }
    }
    @ViewBuilder private var characterStyles: some View {
        character("粗体", "bold", "bold")
        character("斜体", "italic", "italic")
        character("删除线", "strikethrough", "strike")
        character("行内代码", "chevron.left.forwardslash.chevron.right", "code")
    }
    private func character(_ title: String, _ symbol: String, _ mark: String) -> some View {
        let active = editor.state.marks.contains(mark)
        let mixed = editor.state.mixedMarks.contains(mark)
        return Button {
            Task { _ = await editor.perform("format." + mark, selectionToken: draft.token) }
        } label: {
            Group {
                if typeSize.isAccessibilitySize {
                    Label(title, systemImage: symbol).labelStyle(.titleAndIcon)
                } else {
                    Label(title, systemImage: symbol).labelStyle(.iconOnly)
                }
            }
            .frame(minWidth: 44, maxWidth: .infinity, minHeight: 44)
            .overlay(alignment: .topTrailing) {
                if active || mixed {
                    Image(systemName: mixed ? "minus" : "checkmark")
                        .font(.caption2).accessibilityHidden(true)
                }
            }
        }
        .buttonStyle(.bordered)
        .tint(active ? Color.accentColor : Color.secondary)
        .accessibilityLabel(title)
        .accessibilityValue(mixed ? "混合" : active ? "已选中" : "未选中")
        .accessibilityAddTraits(active ? .isSelected : [])
        .disabled(!enabled)
    }
    private func heading(_ level: Int) -> some View {
        Button {
            Task { _ = await editor.perform("format.heading", args: ["level": String(level)], selectionToken: draft.token) }
        } label: {
            Label("标题 \(level)", systemImage: editor.state.block == "heading\(level)" ? "checkmark" : "textformat.size")
        }.disabled(!enabled || editor.state.attributes["canHeading"] == "false" || editor.state.nodeType.lowercased().contains("table"))
    }
    private func action(_ title: String, _ symbol: String, _ command: String, selected: Bool = false, mark: String = "") -> some View {
        let active = selected || (!mark.isEmpty && editor.state.marks.contains(mark))
        let mixed = !mark.isEmpty && editor.state.mixedMarks.contains(mark)
        return Button {
            Task { _ = await editor.perform("format." + command, selectionToken: draft.token) }
        } label: {
            Label(title + (mixed ? "（混合）" : ""), systemImage: active ? "checkmark" : symbol)
        }.listRowBackground(active ? Color.accentColor.opacity(0.12) : Color(uiColor: .secondarySystemGroupedBackground))
            .accessibilityAddTraits(active ? .isSelected : [])
            .disabled(!enabled)
    }
}

struct MobileEditorLinkForm: View {
    @ObservedObject var editor: MobileEditorController
    @ObservedObject var draft: MobileEditorPanelDraft
    @Environment(\.dismiss) private var dismiss
    private var valid: Bool {
        let value = draft.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty || value.hasPrefix("#") { return true }
        guard let url = URL(string: value), let scheme = url.scheme?.lowercased() else { return false }
        return ["http", "https", "mailto"].contains(scheme) && (scheme == "mailto" || url.host != nil)
    }
    var body: some View {
        Form {
            TextField("链接地址", text: $draft.text).textInputAutocapitalization(.never).autocorrectionDisabled()
            Text("支持 http、https、mailto 和 #；留空应用将移除链接。").font(.footnote)
            if !valid { Text("请输入有效的链接地址。").foregroundStyle(.red) }
            if let feedback = draft.feedback { Text(feedback) }
        }.navigationTitle("链接")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task {
                            let result = await editor.perform("format.link", args: ["href": draft.text], selectionToken: draft.token)
                            if result.success { dismiss() } else { draft.feedback = result.message }
                        }
                    } label: { Label("应用", systemImage: "checkmark") }.disabled(!valid || editor.busy || !editor.state.editable || editor.state.locked || editor.state.composing)
                }
            }
    }
}

struct MobileEditorPanel: View {
    @ObservedObject var editor: MobileEditorController
    @ObservedObject var draft: MobileEditorPanelDraft
    let media: (Bool, String?, String?) -> Void
    @Environment(\.dismiss) private var dismiss
    private var route: String { draft.route ?? "" }
    private var writable: Bool { editor.state.ready && editor.state.editable && !editor.state.locked && !editor.state.composing && !editor.busy }
    private var title: String {
        switch route {
        case "search": "查找与替换"
        case "outline": "文档大纲"
        case "source": "Markdown 源码"
        case "reader": "阅读设置与统计"
        case "table": "表格"
        case "code": "代码与图表"
        case "math": "公式"
        case "raw": "原文块"
        case "paragraph": "段落"
        case "tableContext": "表格操作"
        case "attachment": "附件"
        default: "链接"
        }
    }
    var body: some View {
        NavigationStack {
            content
                .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button { dismiss() } label: { Label(route == "source" ? "关闭" : "取消", systemImage: "xmark") }
                            .accessibilityIdentifier(route == "source" ? "native-source-close" : "native-panel-close")
                    }
                    if route == "source" {
                        ToolbarItem(placement: .primaryAction) {
                            Button { UIPasteboard.general.string = draft.source; draft.feedback = "已复制源码" } label: { Label("复制", systemImage: "doc.on.doc") }
                        }
                    }
                    if ["table", "code", "math", "raw"].contains(route) {
                        ToolbarItem(placement: .confirmationAction) {
                            Button { apply() } label: { Label(route == "table" ? "创建" : "保存内容", systemImage: "checkmark") }
                                .accessibilityIdentifier(route == "table" ? "native-table-create" : "native-content-apply")
                                .disabled(!writable || (route == "table" && (!(1...100).contains(draft.rows) || !(1...20).contains(draft.columns))))
                        }
                    }
                }
        }
    }
    @ViewBuilder private var content: some View {
        switch route {
        case "source":
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("仅供查看，不能在此编辑。").font(.callout)
                    if let feedback = draft.feedback { Text(feedback).font(.callout) }
                    Text(draft.source).font(.system(.subheadline, design: .monospaced)).textSelection(.enabled)
                        .accessibilityIdentifier("native-source-text").frame(maxWidth: .infinity, alignment: .leading)
                }.padding()
            }
        case "search": search
        case "outline": outline
        case "reader": reader
        case "link": MobileEditorLinkForm(editor: editor, draft: draft)
        case "table", "paragraph", "tableContext", "attachment", "code", "math", "raw":
            Form {
                if let feedback = draft.feedback { Text(feedback).foregroundStyle(.red) }
                if !writable { Text("当前为只读、输入中或受保护状态，不能修改。") }
                switch route {
                case "table":
                    Section {
                        Stepper("行：\(draft.rows)", value: $draft.rows, in: 1...100)
                        TextField("行数", value: $draft.rows, format: .number).keyboardType(.numberPad)
                        Stepper("列：\(draft.columns)", value: $draft.columns, in: 1...20)
                        TextField("列数", value: $draft.columns, format: .number).keyboardType(.numberPad)
                        Text("首行为表头").font(.footnote)
                    }
                case "paragraph": paragraph
                case "tableContext": tableContext
                case "attachment": attachment
                case "code", "math", "raw":
                    Section("输入") {
                        if route == "code" { TextField("代码语言（mermaid 为图表）", text: $draft.language).textInputAutocapitalization(.never).autocorrectionDisabled() }
                        if route == "math" { Toggle("独立公式", isOn: $draft.display) }
                        TextEditor(text: $draft.text).font(.system(.subheadline, design: .monospaced)).frame(minHeight: 220)
                            .accessibilityIdentifier("native-content-text")
                    }
                    Section("预览") {
                        MobileEditorRichPreview(editor: editor, type: route, text: draft.text, language: draft.language, display: draft.display)
                    }
                default:
                    EmptyView()
                }
            }
        default:
            // Presentation bindings become nil before dismissal animations finish.
            // An absent/unknown route is not a rich-content editing route.
            EmptyView()
        }
    }
    private var searchResultsCurrent: Bool {
        !draft.searchComposing && editor.state.searchQuery == draft.query
    }
    private var search: some View {
        Form {
            MobileEditorSearchField(text: $draft.query, composing: $draft.searchComposing) { searchAndNavigate(nil) }
                .frame(minHeight: 44)
            if draft.query.isEmpty {
                Text("输入要查找的文字")
            } else if draft.searchComposing {
                Text("正在完成输入")
            } else if !searchResultsCurrent {
                ProgressView("正在查找…")
            } else {
                Text(editor.state.searchCount == 0 ? "没有匹配内容" : "\(editor.state.searchCurrent)/\(editor.state.searchCount)")
            }
            Button { searchAndNavigate("search.previous") } label: { Label("上一处", systemImage: "chevron.up") }
                .disabled(!searchResultsCurrent || editor.state.searchCount == 0)
            Button { searchAndNavigate("search.next") } label: { Label("下一处", systemImage: "chevron.down") }
                .disabled(!searchResultsCurrent || editor.state.searchCount == 0)
            Button { searchAndNavigate(nil) } label: { Label("查找并返回正文", systemImage: "magnifyingglass") }
                .disabled(draft.query.isEmpty || draft.searchComposing)
            if editor.state.editable {
                DisclosureGroup("替换") {
                    TextField("替换为", text: $draft.replacement).accessibilityIdentifier("native-search-replacement")
                    Button("替换第一处") { replace(all: false) }.disabled(!writable || draft.query.isEmpty || draft.searchComposing)
                    Button("全部替换") { replace(all: true) }.disabled(!writable || draft.query.isEmpty || draft.searchComposing)
                }
            }
            if let feedback = draft.feedback { Text(feedback) }
        }
        .task(id: [draft.query, String(draft.searchComposing)]) {
            let query = draft.query
            guard !draft.searchComposing else { return }
            do { try await Task.sleep(nanoseconds: 250_000_000) }
            catch { return }
            guard !Task.isCancelled else { return }
            // As with previews, cancellation of the view task must not cancel an
            // already submitted ordered bridge command and quarantine transport.
            let operation = Task { @MainActor in
                await editor.perform("search.set", args: ["query": query])
            }
            let result = await operation.value
            guard !Task.isCancelled, !draft.searchComposing, draft.query == query else { return }
            if !result.success { draft.feedback = result.message ?? "查找未完成，请重试。" }
        }
    }
    private var outline: some View {
        List {
            if editor.state.headings.isEmpty {
                ContentUnavailableView("文档还没有标题", systemImage: "list.bullet.indent")
            }
            ForEach(editor.state.headings, id: \.id) { heading in
                HStack {
                    Button {
                        Task {
                            let result = await editor.perform("outline.jump", args: ["id": String(heading.id)])
                            if result.success { dismiss() }
                        }
                    } label: { Text(heading.title.isEmpty ? "空标题" : heading.title).frame(maxWidth: .infinity, alignment: .leading) }
                        .accessibilityLabel("\(heading.level)级标题，\(heading.title.isEmpty ? "空标题" : heading.title)")
                    Button { run("outline.toggle", ["id": String(heading.id)]) } label: { Label(heading.collapsed ? "展开标题" : "折叠标题", systemImage: heading.collapsed ? "chevron.right" : "chevron.down") }
                        .labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44)
                }.buttonStyle(.borderless).padding(.leading, CGFloat(min(4, max(0, heading.level - 1))) * 12)
            }
        }
    }
    private var reader: some View {
        Form {
            Section("外观") {
                Picker("主题", selection: Binding(get: { editor.state.theme == "system" ? "" : editor.state.theme }, set: { run("reader.set", ["theme": $0]) })) {
                    Text("跟随系统").tag("")
                    Text("纸质").tag("paper")
                    Text("赛博夜色").tag("night")
                }
            }
            Section("字号") {
                Picker("正文字号", selection: Binding(get: { editor.state.fontSize }, set: { run("reader.set", ["fontSize": String($0)]) })) {
                    ForEach([15, 17, 19, 22, 26], id: \.self) { Text("\($0)").tag($0) }
                }
            }
            Section("统计") {
                LabeledContent("正文非空白字符数", value: String(editor.state.characters))
                LabeledContent("源码 UTF-8 字节数", value: String(editor.state.sourceBytes))
                Text("已保存到本机后，云同步由系统处理。").font(.footnote)
            }
        }
    }
    @ViewBuilder private var paragraph: some View {
        action("上移段落", "arrow.up", "block.up", disabled: editor.state.attributes["canMoveUp"] == "false")
        action("下移段落", "arrow.down", "block.down", disabled: editor.state.attributes["canMoveDown"] == "false")
        action("创建段落副本", "plus.square.on.square", "block.copy", disabled: editor.state.attributes["canCopy"] == "false")
        action("删除段落", "trash", "block.delete", destructive: true, disabled: editor.state.attributes["canDelete"] == "false")
    }
    @ViewBuilder private var tableContext: some View {
        Section {
            action("在前面插入行", "arrow.up", "table.rowBefore")
            action("在后面插入行", "arrow.down", "table.rowAfter")
            action("在前面插入列", "arrow.left", "table.columnBefore")
            action("在后面插入列", "arrow.right", "table.columnAfter")
            Button { Task { let result = await editor.perform("table.fullscreen", selectionToken: draft.token); if result.success { dismiss() } } } label: { Label("切换表格全屏", systemImage: "arrow.up.left.and.arrow.down.right") }
        }
        Section {
            action("删除当前行", "trash", "table.deleteRow", destructive: true)
            action("删除当前列", "trash", "table.deleteColumn", destructive: true)
            action("删除表格", "trash", "table.delete", destructive: true)
        }
    }
    @ViewBuilder private var attachment: some View {
        Button { Task { let result = await editor.perform("context.preview", selectionToken: draft.token); if result.success { dismiss() } } } label: { Label("预览", systemImage: "eye") }
        if editor.state.nodeType.lowercased().contains("image") {
            TextField("图片描述", text: $draft.text)
            Button("保存图片描述") { run("context.edit", ["alt": draft.text, "text": draft.text]) }.disabled(!writable)
        }
        Menu {
            Button("从照片选择") { let token = draft.token; let expectedType = editor.state.nodeType; dismiss(); media(true, token, expectedType) }
            Button("从文件选择") { let token = draft.token; let expectedType = editor.state.nodeType; dismiss(); media(false, token, expectedType) }
        } label: { Label("替换", systemImage: "arrow.triangle.2.circlepath") }.disabled(!writable)
        action("删除此引用", "trash", "context.deleteReference", destructive: true)
        Text("删除引用不会删除磁盘附件。").font(.footnote)
    }
    private func action(_ title: String, _ symbol: String, _ name: String, destructive: Bool = false, disabled: Bool = false) -> some View {
        Button(role: destructive ? .destructive : nil) { run(name) } label: { Label(title, systemImage: symbol) }.disabled(!writable || disabled)
    }
    private func run(_ name: String, _ args: [String: String] = [:]) {
        Task {
            let result = await editor.perform(name, args: args, selectionToken: draft.token)
            if !result.success { draft.feedback = result.message ?? "操作未完成，请重试。" }
        }
    }
    private func apply() {
        var args: [String: String] = ["text": draft.text]
        let name: String
        if route == "table" { name = "insert.table"; args = ["rows": String(draft.rows), "cols": String(draft.columns)] }
        else {
            name = draft.editing ? "context.edit" : "insert." + route
            if route == "code" { args["language"] = draft.language }
            if route == "math" { args["display"] = String(draft.display) }
        }
        Task {
            let result = await editor.perform(name, args: args, selectionToken: draft.token)
            if result.success { dismiss() } else { draft.feedback = result.message ?? "保存内容失败，输入已保留。" }
        }
    }
    private func searchAndNavigate(_ command: String?) {
        Task {
            let result = await editor.perform("search.set", args: ["query": draft.query])
            guard result.success else { draft.feedback = result.message; return }
            if let command { _ = await editor.perform(command) }
            dismiss()
        }
    }
    private func replace(all: Bool) {
        Task {
            let result = await editor.perform("search.replace", args: ["query": draft.query, "replacement": draft.replacement, "all": String(all)], selectionToken: draft.token)
            draft.feedback = result.message ?? (result.success ? "已替换，可撤销" : "替换失败")
        }
    }
}
