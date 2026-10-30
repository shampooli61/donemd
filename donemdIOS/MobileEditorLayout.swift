import Foundation

/// Geometry and view preferences are display-only session state, never document state.
struct MobileEditorLayout: Equatable {
    enum Mode: String, CaseIterable { case body, source, compare }
    let width: Double
    /// Available renderer content height, excluding the measured pane titles.
    let height: Double
    let accessibility: Bool

    init(width: Double, height: Double, accessibility: Bool) {
        self.width = width
        self.height = height
        self.accessibility = accessibility
    }

    init(width: Double, containerHeight: Double, paneTitleHeight: Double?, accessibility: Bool) {
        // Until title measurement is available, fail closed rather than briefly
        // exposing compare with less than the required content viewport.
        self.init(width: width, height: paneTitleHeight.map { max(0, containerHeight - $0) } ?? 0,
                  accessibility: accessibility)
    }

    var supportsCompare: Bool { width >= 760 && height >= 300 && !accessibility }

    func widths(for mode: Mode, divider: Double) -> (body: Double, source: Double) {
        switch mode {
        case .body: return (max(0, width), 0)
        case .source: return (0, max(0, width))
        case .compare:
            let available = max(0, width - divider)
            let source = min(520, max(300, min(available * 0.42, available - 400)))
            return (max(0, available - source), source)
        }
    }
}

struct MobileEditorViewPreference: Equatable {
    private(set) var wide: MobileEditorLayout.Mode?
    private(set) var narrow: MobileEditorLayout.Mode = .body

    func mode(in layout: MobileEditorLayout, focused: Bool = false, composing: Bool = false,
              keyboardVisible: Bool = false) -> MobileEditorLayout.Mode {
        let desired = layout.supportsCompare ? (wide ?? .compare) : narrow
        // Geometry is not an explicit, acknowledged view switch. Never hide the
        // input owner to restore a stale source preference during editing/IME.
        // This is an effective-mode override, not a change to either preference.
        if desired == .source && (focused || composing || keyboardVisible) { return .body }
        return desired
    }

    mutating func select(_ mode: MobileEditorLayout.Mode, in layout: MobileEditorLayout) {
        guard mode != .compare || layout.supportsCompare else { return }
        if layout.supportsCompare { wide = mode }
        if mode != .compare { narrow = mode }
    }
}

/// Check both before and after asynchronous selection capture and keyboard dismissal.
struct MobileEditorViewSwitchGuard {
    let identity: String
    let revision: Int

    func accepts(identity: String, revision: Int, ready: Bool, composing: Bool) -> Bool {
        ready && !composing && self.identity == identity && self.revision == revision
    }
}
