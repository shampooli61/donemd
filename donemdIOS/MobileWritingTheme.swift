import SwiftUI
import Combine
import UIKit

enum MobileWritingTheme: String, CaseIterable, Identifiable {
    case system, paper, night
    var id: String { rawValue }
    var title: String {
        switch self { case .system: return "跟随系统"; case .paper: return "纸质"; case .night: return "赛博夜色" }
    }
    var webValue: String { self == .system ? "" : rawValue }
    var interfaceStyle: UIUserInterfaceStyle {
        switch self { case .system: return .unspecified; case .paper: return .light; case .night: return .dark }
    }
    private func color(_ hex: UInt32) -> Color {
        Color(red: Double((hex >> 16) & 255) / 255, green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255)
    }
    var background: Color {
        switch self { case .system: return Color(uiColor: .systemBackground); case .paper: return color(0xF8F4EE); case .night: return color(0x171C26) }
    }
    var foreground: Color {
        switch self { case .system: return Color(uiColor: .label); case .paper: return color(0x3A332B); case .night: return color(0xB8C0CC) }
    }
    /// Text-safe accent; paper's stronger fill color is not used for small text.
    var accent: Color {
        switch self {
        case .system: return Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 85/255, green: 197/255, blue: 147/255, alpha: 1) : UIColor(red: 8/255, green: 127/255, blue: 80/255, alpha: 1) })
        case .paper: return color(0xA8492C)
        case .night: return color(0x61B3BF)
        }
    }
}

/// Display-only authority. Neither this store nor its transports access document data.
@MainActor
final class MobileThemeStore: ObservableObject {
    static let shared = MobileThemeStore()
    static let preferenceKey = "donemd.mobile.writingTheme"
    @Published private(set) var theme: MobileWritingTheme
    @Published private(set) var applying = false
    @Published private(set) var error: String?
    private let defaults: UserDefaults
    private var hasPreference: Bool
    // Capture once before any display command can replace the legacy web state.
    // Failed initial source readiness/ACK must not turn a rollback into migration input.
    private var legacyCandidate: MobileWritingTheme?
    private weak var pendingReconcileController: MobileEditorController?
    private var pendingReconcileIdentity: String?
    private var pendingReconcileRevision: Int?
    private var sourcesEpoch = 0
    private var sources: [UUID: @MainActor (MobileWritingTheme) async -> Bool] = [:]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let saved = defaults.string(forKey: Self.preferenceKey).flatMap(MobileWritingTheme.init(rawValue:))
        theme = saved ?? .system
        hasPreference = saved != nil
    }

    func attachSource(owner: UUID, apply: @escaping @MainActor (MobileWritingTheme) async -> Bool) {
        sourcesEpoch += 1
        sources[owner] = apply
    }
    func detachSource(owner: UUID) { sourcesEpoch += 1; sources.removeValue(forKey: owner) }

    @discardableResult
    func apply(_ next: MobileWritingTheme, using controller: MobileEditorController) async -> Bool {
        guard !applying else { return false }
        captureLegacyCandidate(using: controller)
        guard controller.state.ready, !sources.isEmpty else {
            error = "主题未能切换，请重试"; return false
        }
        applying = true
        defer { finishApply() }
        error = nil
        let previous = theme
        let identity = controller.state.identity, revision = controller.state.revision
        let participants = sources
        let epoch = sourcesEpoch
        // Capture participants so replacing/disconnecting a source invalidates this transaction.
        func sameSession() -> Bool {
            controller.state.identity == identity && controller.state.revision == revision && controller.state.ready && sourcesEpoch == epoch
        }
        let body = await controller.perform("reader.set", args: ["theme": next.webValue])
        var accepted = body.success && sameSession()
        if accepted {
            for (_, source) in participants {
                let ack = await source(next)
                accepted = accepted && ack && sameSession()
            }
        }
        if accepted {
            theme = next
            defaults.set(next.rawValue, forKey: Self.preferenceKey)
            hasPreference = true
            legacyCandidate = nil
            return true
        }
        // Always roll back both displays: a failed ACK may mean it executed but its reply was lost.
        // Never send an old session's rollback into a replacement document.
        if controller.state.identity == identity && controller.state.revision == revision {
            _ = await controller.perform("reader.set", args: ["theme": previous.webValue])
        }
        for (_, source) in participants { _ = await source(previous) }
        error = "主题未能切换，请重试"
        return false
    }

    private func captureLegacyCandidate(using controller: MobileEditorController) {
        guard !hasPreference, legacyCandidate == nil, controller.state.ready else { return }
        legacyCandidate = MobileWritingTheme(rawValue: controller.state.theme) ?? .system
    }

    /// Coalesce readiness signals received while an ACK/rollback is suspended.
    /// Drain once, only when signalled; failure alone never schedules a retry loop.
    private func finishApply() {
        applying = false
        let controller = pendingReconcileController
        let identity = pendingReconcileIdentity, revision = pendingReconcileRevision
        pendingReconcileController = nil
        pendingReconcileIdentity = nil
        pendingReconcileRevision = nil
        guard let controller else { return }
        Task { @MainActor [weak self, weak controller] in
            guard let self, let controller, controller.state.ready,
                  controller.state.identity == identity, controller.state.revision == revision else { return }
            await self.reconcile(using: controller)
        }
    }

    func reconcile(using controller: MobileEditorController) async {
        guard controller.state.ready else { return }
        captureLegacyCandidate(using: controller)
        if applying {
            pendingReconcileController = controller
            pendingReconcileIdentity = controller.state.identity
            pendingReconcileRevision = controller.state.revision
            return
        }
        let desired = hasPreference ? theme : (legacyCandidate ?? .system)
        _ = await apply(desired, using: controller)
    }
}

/// Own the UIKit presentation's override rather than a nullable SwiftUI
/// preference. Observe the WINDOW's system traits independently of this override:
/// an already-open popover may otherwise retain its presentation-time environment.
@MainActor
struct MobileWritingAppearance: UIViewRepresentable {
    let theme: MobileWritingTheme
    let systemStyleChanged: (UIUserInterfaceStyle) -> Void

    func makeUIView(context: Context) -> AppearanceView { AppearanceView() }

    func updateUIView(_ view: AppearanceView, context: Context) {
        view.style = theme.interfaceStyle
        view.systemStyleChanged = systemStyleChanged
        view.apply()
    }

    static func dismantleUIView(_ view: AppearanceView, coordinator: ()) {
        view.releaseAppearance()
    }

    final class AppearanceView: UIView {
        var style: UIUserInterfaceStyle = .unspecified
        var systemStyleChanged: ((UIUserInterfaceStyle) -> Void)?
        private weak var appearanceOwner: UIViewController?
        private weak var observedWindow: UIWindow?
        private var registration: (any UITraitChangeRegistration)?
        private var reportedStyle: UIUserInterfaceStyle?

        init() {
            super.init(frame: .zero)
            isUserInteractionEnabled = false
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window == nil { releaseAppearance() } else { apply() }
        }

        override func didMoveToSuperview() {
            super.didMoveToSuperview()
            if superview == nil { releaseAppearance() } else { apply() }
        }

        func apply() {
            // SwiftUI may call update before attaching the representable. The
            // view/window callbacks above retry after the responder chain exists.
            var responder = next
            while responder != nil && !(responder is UIViewController) { responder = responder?.next }
            guard var owner = responder as? UIViewController else { return }
            // Containment does not cross a sheet/popover's presenter boundary.
            while let ancestor = owner.parent { owner = ancestor }
            if appearanceOwner !== owner { releaseOwner(); appearanceOwner = owner }
            owner.overrideUserInterfaceStyle = style
            observeWindow()
        }

        private func observeWindow() {
            guard let window else { return }
            if observedWindow !== window {
                stopObservingWindow()
                observedWindow = window
                registration = window.registerForTraitChanges([UITraitUserInterfaceStyle.self]) { [weak self] (window: UIWindow, _: UITraitCollection) in
                    self?.reportSystemStyle(window.traitCollection.userInterfaceStyle)
                }
            }
            reportSystemStyle(window.traitCollection.userInterfaceStyle)
        }

        private func reportSystemStyle(_ style: UIUserInterfaceStyle) {
            guard reportedStyle != style, let systemStyleChanged else { return }
            reportedStyle = style
            // Never publish SwiftUI state from inside updateUIView/layout.
            DispatchQueue.main.async { systemStyleChanged(style) }
        }

        private func releaseOwner() {
            appearanceOwner?.overrideUserInterfaceStyle = .unspecified
            appearanceOwner = nil
        }

        private func stopObservingWindow() {
            if let registration { observedWindow?.unregisterForTraitChanges(registration) }
            registration = nil
            observedWindow = nil
            reportedStyle = nil
        }

        func releaseAppearance() {
            stopObservingWindow()
            releaseOwner()
        }
    }
}
