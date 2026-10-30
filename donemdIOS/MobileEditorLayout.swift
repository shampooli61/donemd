import Foundation

/// Geometry and view preferences are display-only session state, never document state.
struct MobileEditorLayout: Equatable {
    enum Mode: String, CaseIterable { case body, source, compare }
    let width: Double
    let height: Double
    let accessibility: Bool

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

    func mode(in layout: MobileEditorLayout) -> MobileEditorLayout.Mode {
        layout.supportsCompare ? (wide ?? .compare) : narrow
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
