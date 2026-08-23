import SwiftUI
import AppKit

/// [[AI 助手 Onboarding]] modal sheet (Phase 3 #62, PRD user story 49).
///
/// Highlights the recommended provider (DeepSeek): big button straight to the
/// API-key page (not the homepage — saves 2-3 clicks), a key field, and a
/// "测试连接 + 保存" button running the same 4-step chain as the Settings card.
/// Collapsible "其它 Provider…" reveals the five other brands as a hint.
///
/// In S1 this sheet is only triggered explicitly from the Settings button —
/// the real first-AI-call trigger lands in S2/S8. Per user story 50 it can be
/// dismissed with 暂不配置, and once any key-bearing provider is configured it
/// must never auto-show again (gated by `manager.hasKeyBearingProvider` at the
/// call site).
struct AIOnboardingSheet: View {
    @ObservedObject var manager: AIProviderManager
    @Binding var isPresented: Bool

    /// DeepSeek's API-key page — deep-link, not the homepage.
    private static let deepSeekKeyURL = URL(string: "https://platform.deepseek.com/api_keys")!
    private let recommended = AIProvider.deepseek

    @State private var keyDraft = ""
    @State private var isTesting = false
    @State private var statusMessage: String?
    @State private var statusIsError = false
    @State private var othersExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            deepSeekBlock
            othersDisclosure
            Spacer(minLength: 0)
            footerButtons
        }
        .padding(24)
        .frame(width: 460, height: 440)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("配置 AI 助手").font(.title2).bold()
            Text("Done.md 用你自己的 Provider key 调用 AI，内容直达 Provider，不经过任何中转。")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var deepSeekBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text("DeepSeek").font(.headline)
                Text("推荐")
                    .font(.caption2).bold()
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.15))
                    .clipShape(Capsule())
            }
            Text("中文写作质量好 · 手机号注册无需 VPN · 实际成本≈0")
                .font(.caption).foregroundStyle(.secondary)

            Button {
                NSWorkspace.shared.open(Self.deepSeekKeyURL)
            } label: {
                Label("打开 platform.deepseek.com 申请 API Key", systemImage: "safari")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)

            SecureField("粘贴 API Key", text: $keyDraft)
                .textFieldStyle(.roundedBorder)

            HStack {
                Button("测试连接 + 保存") {
                    Task { await testAndSave() }
                }
                .disabled(isTesting || keyDraft.isEmpty)
                if isTesting { ProgressView().controlSize(.small) }
            }

            if let statusMessage {
                Text(statusMessage)
                    .font(.caption)
                    .foregroundStyle(statusIsError ? Color.red : Color.green)
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var othersDisclosure: some View {
        DisclosureGroup("其它 Provider…", isExpanded: $othersExpanded) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(AIProvider.allCases.filter { $0 != recommended }, id: \.self) { provider in
                    HStack {
                        Text(provider.displayName)
                        Spacer()
                    }
                    .font(.callout)
                }
                Text("在 设置 → AI Provider 里展开任意卡片填写。")
                    .font(.caption2).foregroundStyle(.secondary)
                    .padding(.top, 2)
            }
            .padding(.top, 4)
        }
    }

    private var footerButtons: some View {
        HStack {
            Button("暂不配置") { isPresented = false }
            Spacer()
            Button("完成") { isPresented = false }
                .keyboardShortcut(.defaultAction)
                .disabled(!manager.hasKeyBearingProvider)
        }
    }

    private func testAndSave() async {
        isTesting = true
        statusMessage = nil
        defer { isTesting = false }
        let result = await manager.saveKeyAndRefresh(keyDraft, for: recommended)
        switch result {
        case .fetched(let models):
            statusIsError = false
            statusMessage = "连接成功 · 拉到 \(models.count) 个 model。可点完成。"
        case .degraded(let fallback, let error):
            // Key saved regardless — degrade only means the list fetch failed.
            statusIsError = true
            statusMessage = "已保存 key，但拉模型列表失败（\(error)），将用默认 model \(fallback)"
        }
    }
}
