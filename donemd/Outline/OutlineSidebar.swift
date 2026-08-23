import SwiftUI

/// The 文档大纲 (document outline) sidebar — the sidebar column of the window's
/// `NavigationSplitView` (#78). Renders the current document's heading tree as
/// an indented list.
///
/// This is a native, edge-to-edge sidebar (the system supplies the frosted
/// material, the toggle button, and the show/hide animation) — matching modern
/// macOS sidebar apps. The earlier floating-card treatment was dropped when the
/// window moved to a native unified-toolbar + NavigationSplitView chrome.
///
/// Rows are clickable (S7/#79): tapping jumps both panes to the heading, and
/// the row that owns the current viewport auto-highlights via scrollspy. An
/// empty / heading-free document shows a centered「无标题」hint rather than
/// collapsing.
struct OutlineSidebar: View {
    @ObservedObject var store: OutlineStore

    /// Jump both panes to the tapped heading (#79). Given the heading's 0-based
    /// document ordinal (`OutlineHeading.index`).
    let onSelect: (Int) -> Void

    /// Active writing theme (#80 S8) — the highlighted row uses the theme's
    /// accent so the outline selection color follows the chosen background
    /// (KV 绿 / paper 橙 / 夜色 青).
    @AppStorage("donemd.writingTheme") private var writingThemeRaw = WritingTheme.system.rawValue
    private var accent: Color {
        (WritingTheme(rawValue: writingThemeRaw) ?? .system).accentColor
    }

    /// Optimistic highlight set the instant a row is tapped, so the selection
    /// feels immediate rather than waiting for the smooth-scroll to settle and
    /// scrollspy to confirm. Cleared once scrollspy publishes a value (which
    /// then becomes the source of truth). `nil` = defer to `store.activeIndex`.
    @State private var pendingIndex: Int?

    /// The row highlighted in the brand color: the optimistic click target if
    /// one is pending, otherwise the scrollspy-active heading.
    private var highlightedIndex: Int? {
        pendingIndex ?? store.activeIndex
    }

    var body: some View {
        Group {
            if store.headings.isEmpty {
                // Empty / no-heading document: centered grey hint.
                VStack {
                    Spacer()
                    Text("无标题")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(store.headings) { heading in
                    Button {
                        pendingIndex = heading.index
                        onSelect(heading.index)
                    } label: {
                        Text(heading.text.isEmpty ? "（无标题）" : heading.text)
                            .font(fontFor(level: heading.level))
                            .foregroundStyle(foreground(for: heading))
                            .lineLimit(1)
                            .truncationMode(.tail)
                            // Indent by heading level: H1 flush-left, each deeper
                            // level steps in 12pt.
                            .padding(.leading, CGFloat(heading.level - 1) * 12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .listStyle(.sidebar)
            }
        }
        .navigationTitle("大纲")
        // Once scrollspy publishes an active heading, drop the optimistic click
        // highlight so the scroll position becomes the single source of truth
        // (e.g. the user then scrolls away from the heading they clicked).
        .onChange(of: store.activeIndex) { _ in
            pendingIndex = nil
        }
    }

    /// Brand green for the highlighted row (click target or scrollspy-active);
    /// otherwise level-based emphasis.
    private func foreground(for heading: OutlineHeading) -> Color {
        if heading.index == highlightedIndex { return accent }
        return heading.level == 1 ? .primary : .secondary
    }

    /// H1 slightly heavier so the top-level structure reads at a glance;
    /// deeper levels use the body size.
    private func fontFor(level: Int) -> Font {
        switch level {
        case 1: return .system(.callout, design: .default).weight(.semibold)
        case 2: return .system(.callout)
        default: return .system(.footnote)
        }
    }
}
