import SwiftUI
import AppKit

/// [[AI 状态徽标]] — the permanent, low-key AI discoverability entry in every
/// document window's top status area (Phase 3 #62, PRD user stories 48/52/53).
///
/// Four-ish states collapse to three (PRD CONTEXT.md table): 未配置 / 已配置
/// (names the provider) / 调用中… (S2+). Clicking always opens Settings →
/// AI Provider. Deliberately understated — a first-time user notices "there's
/// an AI thing" without being nagged; a markdown-only user can ignore it.
struct AIStatusBadge: View {
    @ObservedObject var manager: AIProviderManager

    var body: some View {
        Button(action: openSettings) {
            HStack(spacing: 4) {
                Image(systemName: "sparkles")
                    .font(.caption2)
                Text(label)
                    .font(.caption)
                if case .inFlight = manager.badgeState {
                    ProgressView().controlSize(.mini)
                }
            }
            // Horizontal inset so the content doesn't sit flush against the
            // edges of the system toolbar-item glass capsule (which otherwise
            // hugs the text with no breathing room). Primary (not secondary)
            // foreground so it reads as tappable, not disabled.
            .padding(.horizontal, 6)
            .foregroundStyle(.primary)
        }
        .buttonStyle(.plain)
        .help("AI 助手 — 点击打开 设置 → AI Provider")
    }

    private var isConfigured: Bool {
        if case .configured = manager.badgeState { return true }
        return false
    }

    private var label: String {
        switch manager.badgeState {
        case .unconfigured:                return "AI: 未配置"
        case .configured(let name):        return "AI: \(name)"
        case .inFlight:                    return "AI: 调用中…"
        }
    }

    private func openSettings() {
        // Shared robust opener (activates the app first, then sends on the
        // next tick) — `sendAction(to: nil)` alone is unreliable when the
        // WKWebView holds first responder. The selected tab can't be forced
        // via public API; the panel opens on the last-shown tab.
        VisualWebView.Coordinator.openSettings()
    }
}
