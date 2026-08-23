import Foundation
import AppKit

/// Undo entry point for the pull safety net (GH #84 / #85, Layer 2).
///
/// A Feishu pull overwrites the local body with the remote content. Before
/// doing so, `FeishuPullCommand` captures a snapshot via
/// `FeishuPullSnapshotStore`. This command restores that snapshot, valid
/// for `FeishuPullSnapshotStore.undoWindow` (10 minutes) after the pull.
///
/// Wired into the 飞书 command menu as「撤销上次拉取」. The menu item stays
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
        guard let snapshot = FeishuPullSnapshotStore.latest(for: url) else {
            presentAlert(
                title: "没有可撤销的拉取",
                message: "没有找到 10 分钟内的拉取备份——可能从未拉取，或撤销时限已过。"
            )
            return
        }

        // Parse the snapshot markdown back into a document and apply it,
        // exactly like a pull applies the remote content — reuse the same
        // body-replacing + save path so both panes reload and disk updates.
        let restored = MarkdownEngine.parseDocument(source: snapshot.markdown)
        document.applyUpdatedDocumentAndSave(restored) { persistError in
            switch persistError {
            case nil:
                // One-shot: consume the snapshot so a second undo can't
                // re-restore stale content on top of newer edits.
                FeishuPullSnapshotStore.clear(for: url)
                presentAlert(
                    title: "已撤销上次拉取",
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
