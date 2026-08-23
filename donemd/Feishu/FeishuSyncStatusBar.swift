import SwiftUI
import AppKit

/// Compact Feishu action group for the Visual column's top bar (Phase 5
/// chrome). The four Feishu actions (打开飞书 / 拉取 / 推送 / 解绑) sit in one
/// capsule so they read as a single Feishu-related group, while each stays
/// independently clickable. Replaces the old full-width `FeishuSyncStatusBar`
/// row that used to steal the traffic-light row. Only shown when the doc is
/// bound (`DonemdDocumentRootView` gates on `feishu.docToken != nil`).
///
/// The binding status text ("已绑定 · 刚刚同步 · doxc…") is demoted to the
/// group's help tooltip — it's reference info, not something that needs a
/// permanent row.
struct FeishuActionCapsule: View {
    let document: DonemdDocument
    let feishu: FeishuFrontmatter

    var body: some View {
        HStack(spacing: 2) {
            Button(action: openOnFeishu) {
                Image(systemName: "arrow.up.right.square")
            }
            .buttonStyle(.plain)
            .help("打开飞书")
            .disabled(feishu.docToken == nil)

            capsuleDivider
            Button("拉取") { FeishuPullCommand.run() }
                .buttonStyle(.plain)
                .help("从飞书拉取")

            capsuleDivider
            Button("推送") { FeishuPushCommand.run() }
                .buttonStyle(.plain)
                .help("推送到飞书")

            capsuleDivider
            Button("解绑", action: unbind)
                .buttonStyle(.plain)
                .help("解除飞书绑定")
        }
        .font(.system(size: 12, weight: .medium))
        // The capsule chrome comes from the system toolbar item's glass
        // background (this view is hosted as its own NSToolbarItem), so no
        // self-drawn material/stroke here — just a little horizontal inset so
        // the buttons don't sit flush against the capsule edges.
        .padding(.horizontal, 6)
        .help(statusTooltip)
    }

    private var capsuleDivider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.12))
            .frame(width: 0.5, height: 14)
    }

    private var statusTooltip: String {
        let tokenSuffix = feishu.docToken.map { "doxc \($0.rawValue)" } ?? "未知"
        if let pushed = feishu.lastPushedAt {
            return "已绑定飞书 · \(FeishuSyncStatusBar.relativeText(from: pushed))同步 · \(tokenSuffix)"
        } else if feishu.lastPulledRevision != nil {
            return "已绑定飞书 · 仅拉取过 · \(tokenSuffix)"
        } else {
            return "已绑定飞书 · 还未同步过 · \(tokenSuffix)"
        }
    }

    private func openOnFeishu() {
        guard let token = feishu.docToken else { return }
        let urlString = "https://feishu.cn/docx/\(token.rawValue)"
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }

    private func unbind() {
        FeishuSyncStatusBar.runUnbind(document: document)
    }
}

/// Top-edge status bar shown when the current document is bound to a
/// Feishu doc. Single line — icon + "5 分钟前同步" + 4 actions
/// [打开飞书 ↗] [拉取] [推送] [解绑]. Non-modal; doesn't take editor
/// focus.
///
/// (Legacy — no longer placed in the layout after the Phase 5 chrome
/// restructure moved the actions into `FeishuActionCapsule`. Kept for its
/// shared `relativeText` / `runUnbind` helpers and as a fallback.)
///
/// Reads `feishu: FeishuFrontmatter` directly rather than observing
/// the document — the wrapping `if let` already gates on the binding
/// existing, and a value-typed pull-through means the bar redraws
/// when the document's BindingStateContainer republishes.
struct FeishuSyncStatusBar: View {

    let document: DonemdDocument
    let feishu: FeishuFrontmatter

    init(document: DonemdDocument, feishu: FeishuFrontmatter) {
        self.document = document
        self.feishu = feishu
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "link")
                .foregroundStyle(.tint)
                .accessibilityHidden(true)

            Text(headlineText)
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 8) {
                Button(action: openOnFeishu) {
                    Label("打开飞书", systemImage: "arrow.up.right.square")
                        .labelStyle(.titleAndIcon)
                }
                .controlSize(.small)
                .disabled(feishu.docToken == nil)

                Button("拉取") { FeishuPullCommand.run() }
                    .controlSize(.small)

                Button("推送") { FeishuPushCommand.run() }
                    .controlSize(.small)

                Button(action: unbind) {
                    Text("解绑")
                }
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.regularMaterial)
        .overlay(alignment: .bottom) {
            Rectangle()
                .frame(height: 0.5)
                .foregroundStyle(.separator)
        }
    }

    // MARK: - status text

    private var headlineText: String {
        let tokenSuffix = feishu.docToken.map { "doxc \($0.rawValue)" } ?? "未知"
        if let pushed = feishu.lastPushedAt {
            return "已绑定飞书 · \(relativeText(from: pushed))同步 · \(tokenSuffix)"
        } else if feishu.lastPulledRevision != nil {
            // Pulled but never pushed back — common after #58 createNew
            // import or fresh ⌘⌥O onto a doc the user never edited.
            return "已绑定飞书 · 仅拉取过 · \(tokenSuffix)"
        } else {
            return "已绑定飞书 · 还未同步过 · \(tokenSuffix)"
        }
    }

    /// Lightweight relative-time formatter — Cocoa's RelativeDateTimeFormatter
    /// lives in Foundation but its locale is fully system-dependent. For a
    /// status bar that wants Chinese copy ("5 分钟前 / 2 小时前 / 3 天前 /
    /// 长时间未同步") we hand-roll the few buckets we care about. Sub-minute
    /// is "刚刚" — anything finer than that is noise on a status bar.
    static func relativeText(from date: Date) -> String {
        let seconds = max(0, Int(Date().timeIntervalSince(date)))
        switch seconds {
        case 0..<60: return "刚刚"
        case 60..<3600: return "\(seconds / 60) 分钟前"
        case 3600..<86400: return "\(seconds / 3600) 小时前"
        case 86400..<604800: return "\(seconds / 86400) 天前"
        default:
            // Past a week, the rough bucket stops being useful — show the
            // ISO date instead so the user can tell stale bindings apart.
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            return formatter.string(from: date)
        }
    }

    private func relativeText(from date: Date) -> String {
        Self.relativeText(from: date)
    }

    // MARK: - actions

    private func openOnFeishu() {
        guard let token = feishu.docToken else { return }
        // Use the Feishu canonical docx URL. We don't carry the host
        // domain in frontmatter — Feishu's open-apis treats it as a
        // single tenant from the app's perspective and the open
        // redirector at feishu.cn routes to the user's actual tenant
        // (<tenant>.feishu.cn / lark.com / etc) on click.
        let urlString = "https://feishu.cn/docx/\(token.rawValue)"
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }

    private func unbind() {
        Self.runUnbind(document: document)
    }

    /// Shared unbind flow — used by both the legacy bar and `FeishuActionCapsule`.
    static func runUnbind(document: DonemdDocument) {
        let alert = NSAlert()
        alert.messageText = "解除飞书绑定"
        alert.informativeText = """
        解绑后，本地 .md 文件会移除 frontmatter 里的 feishu 命名空间。\
        飞书侧的文档**不会**被删除——只是本地不再认这条绑定。

        想再次同步同一份飞书文档时，可以从「飞书 → 从 URL 导入…」（⌘⌥I）重新绑定。
        """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "解绑")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        var newFrontmatter = document.parsedDocument.frontmatter
        newFrontmatter.feishu = nil
        // Keep feishuOriginalIndex around for now — when feishu is nil
        // the serializer drops the namespace anyway, so the saved
        // markdown won't carry stale state. If the user re-binds later
        // we'd lose the original ordering, but that's the semantic of
        // "unbind" — reset.
        newFrontmatter.feishuOriginalIndex = nil
        document.applyUpdatedFrontmatterAndSave(newFrontmatter) { err in
            switch err {
            case nil:
                break
            case .untitled:
                let a = NSAlert()
                a.messageText = "解绑成功（仅在内存中）"
                a.informativeText = "当前文档还没保存到磁盘，请按 Cmd+S 保存使解绑结果落盘。"
                a.runModal()
            case .saveFailed(let error):
                let a = NSAlert()
                a.messageText = "解绑后写盘失败"
                a.informativeText = error.localizedDescription
                a.alertStyle = .warning
                a.runModal()
            }
        }
    }
}
