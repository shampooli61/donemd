import SwiftUI

/// Side-by-side diff view shown when the user clicks "看看改了哪些" on the
/// first-save prompt.
///
/// Top: a "格式整理报告" header listing the categories of changes
/// (the trust-building promise visualized).
/// Below: two scrollable monospaced panes — left = bytes currently on
/// disk, right = canonical bytes Done.md is about to write. Changed
/// lines are highlighted (red on the left for removed, green on the
/// right for added).
struct FirstSaveDiffView: View {
    let before: String
    let after: String
    /// Called with `true` when the user confirms the save, `false` on cancel.
    let onChoice: (Bool) -> Void

    private var lineDiff: LineDiff {
        LineDiffComputer.compute(before: before, after: after)
    }

    private var formatReport: FormatReport {
        FormatReportComputer.compute(originalMarkdown: before)
    }

    var body: some View {
        VStack(spacing: 0) {
            reportHeader

            Divider()

            HStack(spacing: 0) {
                diffPane(title: "磁盘上的原文", lines: lineDiff.beforeLines, isRemovalSide: true)
                Divider()
                diffPane(title: "Done.md 即将写出的内容", lines: lineDiff.afterLines, isRemovalSide: false)
            }

            Divider()

            HStack(spacing: 12) {
                Spacer()
                Button("取消") { onChoice(false) }
                    .keyboardShortcut(.cancelAction)
                Button("保存") { onChoice(true) }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(minWidth: 800, minHeight: 500)
    }

    // MARK: Report header

    @ViewBuilder
    private var reportHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            if formatReport.hasAnyChange {
                Text("✍️ 格式已整理")
                    .font(.headline)
                ForEach(formatReport.summaryItems, id: \.self) { item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("•")
                            .foregroundColor(.secondary)
                        Text(item)
                    }
                    .font(.subheadline)
                }
                Text("内容零改动")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .padding(.top, 4)
            } else {
                Text("✓ 文档已是标准格式")
                    .font(.headline)
                Text("没有需要整理的地方。内容零改动。")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
    }

    // MARK: Diff pane

    @ViewBuilder
    private func diffPane(
        title: String,
        lines: [LineDiff.AnnotatedLine],
        isRemovalSide: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(NSColor.windowBackgroundColor))

            Divider()

            ScrollView([.vertical, .horizontal]) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { idx, line in
                        Text(line.text.isEmpty ? " " : line.text)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 1)
                            .background(backgroundColor(for: line.status, isRemovalSide: isRemovalSide))
                    }
                }
                .padding(.vertical, 8)
            }
            .background(Color(NSColor.textBackgroundColor))
        }
        .frame(maxWidth: .infinity)
    }

    private func backgroundColor(
        for status: LineDiff.Status,
        isRemovalSide: Bool
    ) -> Color {
        switch status {
        case .unchanged:
            return .clear
        case .removed:
            // Only show on the left pane (removal side).
            return isRemovalSide ? Color.red.opacity(0.12) : .clear
        case .added:
            // Only show on the right pane.
            return isRemovalSide ? .clear : Color.green.opacity(0.14)
        }
    }
}
