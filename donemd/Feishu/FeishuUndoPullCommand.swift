import Foundation
import AppKit

/// Undo entry point for the pull safety net (GH #84 / #85, Layer 2).
///
/// A Feishu pull overwrites the local body with the remote content. Before
/// doing so, `FeishuPullCommand` captures a snapshot via
/// `FeishuPullSnapshotStore`. This command restores that snapshot, valid
/// for `FeishuPullSnapshotStore.undoWindow` (30 days) after the pull.
///
/// Wired into the 飞书 command menu as「恢复拉取前版本…」. The menu item stays
/// enabled only while a fresh snapshot exists for the current document —
/// see `isAvailable(for:)`, which the menu binding consults.
enum FeishuUndoPullCommand {

    /// Whether "撤销上次拉取" should be enabled for the current document:
    /// there is a snapshot for this file and it's still inside the undo
    /// window. Bound to the menu item's `disabled` modifier.
    @MainActor
    static func isAvailable(for document: DonemdDocument?) -> Bool {
        guard let url = document?.fileURL else { return false }
        return FeishuPullSnapshotStore.latest(for: url) != nil
    }

    @MainActor
    static func run() {
        guard let document = NSDocumentController.shared.currentDocument as? DonemdDocument else {
            presentAlert(
                title: "没有可撤销的文档",
                message: "请先打开一个 .md 文件。"
            )
            return
        }
        guard let url = document.fileURL else {
            presentAlert(
                title: "无法撤销",
                message: "当前文档没有保存路径。"
            )
            return
        }
        let versions = FeishuPullSnapshotStore.history(for: url)
        guard !versions.isEmpty else {
            presentAlert(title: "没有可恢复的版本", message: "最近 30 天没有找到拉取前备份。")
            return
        }
        let alert = NSAlert()
        alert.messageText = "恢复拉取前版本"
        alert.informativeText = "恢复会替换当前正文。当前内容会先另存为恢复版本，之后仍可找回。"
        let picker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 360, height: 28))
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        for version in versions { picker.addItem(withTitle: "\(formatter.string(from: version.capturedAt)) · \(version.blockCount) 个内容块") }
        alert.accessoryView = picker
        alert.addButton(withTitle: "取消")
        alert.addButton(withTitle: "恢复所选版本")
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        let snapshot = versions[picker.indexOfSelectedItem]
        guard FeishuPullSnapshotStore.save(markdown: MarkdownEngine.serialize(document: document.parsedDocument), for: url, blockCount: document.parsedDocument.body.content?.count ?? 0) else {
            presentAlert(title: "无法备份当前内容", message: "恢复已停止，请检查磁盘空间和文件权限后重试。")
            return
        }

        // Parse the snapshot markdown back into a document and apply it,
        // exactly like a pull applies the remote content — reuse the same
        // body-replacing + save path so both panes reload and disk updates.
        let restored = MarkdownEngine.parseDocument(source: snapshot.markdown)
        document.applyUpdatedDocumentAndSave(restored) { persistError in
            switch persistError {
            case nil:
                // Keep both the selected version and the just-saved current version.
                presentAlert(
                    title: "已恢复所选版本",
                    message: "已还原到拉取前的本地版本（\(snapshot.blockCount) 个内容块）。"
                )
            case .untitled:
                presentAlert(
                    title: "已还原到内存，但未落盘",
                    message: "当前文档没有保存路径，请按 Cmd+S 保存。"
                )
            case .saveFailed(let error):
                presentAlert(
                    title: "还原写盘失败",
                    message: "\(error.localizedDescription)\n请手动按 Cmd+S 重试。"
                )
            }
        }
    }

    @MainActor
    private static func presentAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.runModal()
    }
}
