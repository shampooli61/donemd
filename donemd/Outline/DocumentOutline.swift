import Foundation

/// One heading in the 文档大纲 (document outline) — the Swift mirror of the
/// web-side `OutlineHeading` (`web/src/heading-extractor.ts`). Populated from
/// the `outlineChanged` bridge message (#78 M5).
///
/// `index` is the 0-based ordinal of the heading in document order; it doubles
/// as the stable `id` so duplicate heading text still yields distinct rows
/// (SwiftUI `List` needs unique ids). Anchoring the outline by ordinal — not
/// by pixel row — is what lets the S7/#79 jump alignment survive normalization
/// reflow (CONTEXT.md §文档大纲).
struct OutlineHeading: Identifiable, Equatable {
    let index: Int
    let level: Int
    let text: String

    var id: Int { index }
}

/// Holds the current document's heading list for the 大纲 sidebar. Separate
/// `ObservableObject` (same pattern as `DonemdDocument.BindingStateContainer`)
/// so the SwiftUI root view re-renders whenever the outline changes, not only
/// on document open.
final class OutlineStore: ObservableObject {
    @Published var headings: [OutlineHeading] = []

    /// The ordinal of the heading whose section is currently at the top of the
    /// Visual pane's viewport — driven by scrollspy (#79). `nil` above the
    /// first heading. The 大纲 sidebar highlights this row in the brand color.
    @Published var activeIndex: Int?

    /// Replace the outline. Always publishes on the main thread —
    /// `@ObservedObject` receivers expect it, and the bridge callback can
    /// arrive off-main.
    func update(_ headings: [OutlineHeading]) {
        if Thread.isMainThread {
            self.headings = headings
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.headings = headings
            }
        }
    }

    /// Set the scrollspy-active heading ordinal (`nil` = none). Publishes on
    /// the main thread — the `activeHeadingChanged` bridge callback can arrive
    /// off-main.
    func setActive(_ index: Int?) {
        if Thread.isMainThread {
            self.activeIndex = index
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.activeIndex = index
            }
        }
    }
}
