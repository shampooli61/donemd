import SwiftUI
import AppKit

/// Settings → AI Provider panel (Phase 3 #62).
///
/// Five provider cards (PRD user story 37), DeepSeek tagged 推荐. One card
/// expands at a time. DeepSeek's card is the only one with a live save path
/// in S1 — the OpenAI-compatible family is wired; the others render but their
/// save lands in S7 (#68).
///
/// The card body for any OpenAI-compatible provider works today (DeepSeek /
/// OpenAI / MiMo share `OpenAIClient`); Anthropic / Google save is gated with
/// a "本切片暂未接入" note rather than a broken button.
public struct AIProviderSettingsView: View {

    @ObservedObject var manager: AIProviderManager
    @State private var expandedProvider: AIProvider? = .deepseek

    public init(manager: AIProviderManager) {
        self.manager = manager
    }

    public var body: some View {
        Form {
            defaultProviderSection
            contextRangeSection
            providerCardsSection
        }
        .formStyle(.grouped)
        .frame(minWidth: 540, minHeight: 540)
        .padding()
    }

    // MARK: - 默认 Provider

    private var defaultProviderSection: some View {
        Section {
            Picker("默认 Provider", selection: Binding(
                get: { manager.registry.defaultProvider },
                set: { manager.setDefaultProvider($0) }
            )) {
                ForEach(AIProvider.allCases, id: \.self) { provider in
                    Text(provider.displayName).tag(provider)
                }
            }
            Text("所有 AI 助手调用都走这个 Provider。一次设一个，不按命令切换。")
                .font(.caption)
                .foregroundStyle(.secondary)
        } header: {
            Text("默认 Provider")
        }
    }

    // MARK: - Context 窗口前后段落数

    private var contextRangeSection: some View {
        Section {
            Picker("前后段落数", selection: Binding(
                get: { manager.registry.contextRange },
                set: { manager.registry.contextRange = $0; manager.configDidChange() }
            )) {
                Text("0（仅选区所在段）").tag(0)
                Text("1（默认）").tag(1)
                Text("2").tag(2)
                Text("3").tag(3)
            }
            Text("改写 / 转换类命令随选区一起发送的上下文范围。翻译只发选区、续写发整篇，不受此项影响。文档过长时自动降级为仅选区。")
                .font(.caption)
                .foregroundStyle(.secondary)
        } header: {
            Text("AI 上下文")
        }
    }

    // MARK: - 6 张卡片

    private var providerCardsSection: some View {
        Section {
            ForEach(AIProvider.allCases, id: \.self) { provider in
                AIProviderCard(
                    provider: provider,
                    manager: manager,
                    isExpanded: Binding(
                        get: { expandedProvider == provider },
                        set: { expandedProvider = $0 ? provider : nil }
                    )
                )
            }
        } header: {
            Text("Provider 配置")
        }
    }
}

// MARK: - 单张 Provider 卡片

/// One provider's expandable card: API key field, model dropdown, endpoint
/// advanced disclosure, test-connection + delete + re-fetch.
struct AIProviderCard: View {
    let provider: AIProvider
    @ObservedObject var manager: AIProviderManager
    @Binding var isExpanded: Bool

    @State private var keyDraft: String = ""
    @State private var endpointDraft: String = ""
    @State private var endpointExpanded = false
    @State private var isTesting = false
    @State private var statusMessage: String?
    @State private var statusIsError = false

    private var registry: ProviderRegistry { manager.registry }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 10) {
                apiKeyField
                modelDropdown
                endpointDisclosure
                actionRow
                if let statusMessage {
                    Text(statusMessage)
                        .font(.caption)
                        .foregroundStyle(statusIsError ? Color.red : Color.secondary)
                }
            }
            .padding(.top, 4)
            .onAppear(perform: loadDrafts)
        } label: {
            HStack(spacing: 6) {
                Text(provider.displayName).font(.headline)
                if provider.isRecommendedDefault {
                    Text("推荐")
                        .font(.caption2).bold()
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.15))
                        .clipShape(Capsule())
                }
                Spacer()
                if registry.isConfigured(provider) {
                    statusDot
                }
            }
        }
    }

    @ViewBuilder private var statusDot: some View {
        // Configured = green dot, meaning a key is stored (all providers
        // require one).
        if (try? registry.apiKey(for: provider))?.isEmpty == false {
            Image(systemName: "checkmark.circle.fill").font(.caption).foregroundStyle(.green)
        }
    }

    private var apiKeyField: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("API Key").font(.caption).foregroundStyle(.secondary)
            SecureField("粘贴 API Key", text: $keyDraft)
                .textFieldStyle(.roundedBorder)
        }
    }

    private var modelDropdown: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Model").font(.caption).foregroundStyle(.secondary)
            let models = registry.cachedModelList(for: provider)
            if models.isEmpty {
                // No fetched list yet → greyed fallback (PRD user story 45).
                Picker("", selection: .constant(registry.selectedModel(for: provider))) {
                    Text(registry.selectedModel(for: provider)).tag(registry.selectedModel(for: provider))
                }
                .labelsHidden()
                .disabled(true)
            } else {
                Picker("", selection: Binding(
                    get: { registry.selectedModel(for: provider) },
                    set: { registry.setSelectedModel($0, for: provider); manager.configDidChange() }
                )) {
                    ForEach(models, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
            }
        }
    }

    private var endpointDisclosure: some View {
        DisclosureGroup("高级：Endpoint", isExpanded: $endpointExpanded) {
            VStack(alignment: .leading, spacing: 4) {
                TextField(provider.defaultEndpoint, text: $endpointDraft)
                    .textFieldStyle(.roundedBorder)
                Text("留空使用官方默认。可改以对接 Azure / 代理 / 自建网关。")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .padding(.top, 4)
        }
    }

    private var actionRow: some View {
        HStack {
            Button("测试连接 + 保存") {
                Task { await testAndSave() }
            }
            .disabled(isTesting || (provider.requiresAPIKey && keyDraft.isEmpty))

            if !registry.cachedModelList(for: provider).isEmpty {
                Button("重新拉模型列表") {
                    Task { await refetch() }
                }
                .font(.caption)
                .buttonStyle(.borderless)
                .disabled(isTesting)
            }

            Spacer()

            if isTesting { ProgressView().controlSize(.small) }

            if registry.isConfigured(provider) && provider.requiresAPIKey {
                Button(role: .destructive) {
                    manager.clearKey(for: provider)
                    keyDraft = ""
                    statusMessage = "已删除配置"
                    statusIsError = false
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
            }
        }
    }

    // MARK: - actions

    private func loadDrafts() {
        keyDraft = (try? registry.apiKey(for: provider)) ?? ""
        // Show the override if set; placeholder shows the default otherwise.
        let resolved = registry.endpoint(for: provider).absoluteString
        endpointDraft = resolved == provider.defaultEndpoint ? "" : resolved
    }

    private func testAndSave() async {
        isTesting = true
        statusMessage = nil
        defer { isTesting = false }

        registry.setEndpointOverride(endpointDraft, for: provider)
        let result = await manager.saveKeyAndRefresh(keyDraft, for: provider)
        applyResult(result)
    }

    private func refetch() async {
        isTesting = true
        defer { isTesting = false }
        applyResult(await manager.refreshModelList(for: provider))
    }

    private func applyResult(_ result: ProviderRegistry.ModelListResult) {
        switch result {
        case .fetched(let models):
            statusIsError = false
            statusMessage = "已保存 · 拉到 \(models.count) 个 model"
        case .degraded(let fallback, let error):
            statusIsError = true
            statusMessage = "已保存，但无法拉模型列表（\(Self.describe(error))），使用默认 model \(fallback)"
        }
    }

    private static func describe(_ error: AIProviderError) -> String {
        switch error {
        case .unauthorized: return "未授权 / key 无效"
        case .insufficientBalance: return "账户余额不足"
        case .forbidden: return "无权限"
        case .rateLimited: return "限流"
        case .badRequest(let s, _): return "请求错误 \(s)"
        case .serverError(let s, _): return "服务端错误 \(s)"
        case .networkUnreachable: return "网络不可达"
        case .decodeFailed: return "响应解析失败"
        case .notImplemented: return "暂未接入"
        }
    }
}
