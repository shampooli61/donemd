import SwiftUI

/// Bottom-edge progress bar shown while a Feishu sync (push or pull)
/// is in flight. Non-modal — the user can keep reading the doc while
/// the sync runs; the bar disappears automatically when the sync
/// completes or is cancelled.
///
/// Bound to a `FeishuSyncProgressViewModel` that PushCommand / PullCommand
/// drive from their Progress callbacks. The model owns the cancel
/// signal — the bar's Cancel button just flips `signal.cancel()`.
public struct FeishuSyncProgressBar: View {

    @ObservedObject var model: FeishuSyncProgressViewModel

    public init(model: FeishuSyncProgressViewModel) {
        self.model = model
    }

    public var body: some View {
        HStack(spacing: 12) {
            Image(systemName: model.direction.iconName)
                .foregroundStyle(.tint)

            VStack(alignment: .leading, spacing: 2) {
                Text(model.statusLine)
                    .font(.callout)
                if let total = model.subTotal, total > 0 {
                    ProgressView(value: Double(model.subDone), total: Double(total))
                        .progressViewStyle(.linear)
                        .controlSize(.small)
                } else {
                    ProgressView()
                        .progressViewStyle(.linear)
                        .controlSize(.small)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button("取消") {
                model.userPressedCancel()
            }
            .disabled(model.cancelDisabled)
            .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.regularMaterial)
        .overlay(alignment: .top) {
            Rectangle()
                .frame(height: 0.5)
                .foregroundStyle(.separator)
        }
    }
}

/// Direction of the sync — drives the icon + the localized stage
/// strings. Keeping push and pull on one model keeps the bar
/// implementation single-source.
public enum FeishuSyncDirection {
    case push
    case pull

    var iconName: String {
        switch self {
        case .push: return "arrow.up.doc"
        case .pull: return "arrow.down.doc"
        }
    }
}

/// View model the progress bar binds to. Push/PullCommand instantiates
/// one per sync attempt, hands the cancel signal to the coordinator,
/// and updates `currentStage` etc. from inside the Progress callback.
@MainActor
public final class FeishuSyncProgressViewModel: ObservableObject {

    @Published public var direction: FeishuSyncDirection
    @Published public var statusLine: String
    @Published public var subDone: Int = 0
    @Published public var subTotal: Int? = nil
    @Published public var cancelDisabled: Bool = false

    public let signal: FeishuSyncCancellationSignal

    public init(direction: FeishuSyncDirection) {
        self.direction = direction
        self.statusLine = direction == .push ? "准备推送…" : "准备拉取…"
        self.signal = FeishuSyncCancellationSignal()
    }

    public func userPressedCancel() {
        signal.cancel()
        cancelDisabled = true
        statusLine = direction == .push ? "正在取消推送…" : "正在取消拉取…"
    }

    // MARK: - push event handling

    public func apply(push event: FeishuPushCoordinator.Progress) {
        switch event {
        case .imageStageStarted(let total):
            subDone = 0
            subTotal = total > 0 ? total : nil
            statusLine = total > 0 ? "上传图片…" : "扫描图片…"
        case .imageUploaded(let index, let total):
            subDone = index
            subTotal = total
            statusLine = "上传图片 \(index)/\(total)"
        case .imageStageFinished:
            subTotal = nil
            statusLine = "图片上传完成"
        case .creatingDocument:
            subTotal = nil
            statusLine = "在飞书侧创建新文档…"
        case .updatingTitle:
            subTotal = nil
            statusLine = "同步文档标题…"
        case .writingBody:
            subTotal = nil
            statusLine = "推送正文到飞书…"
        case .segmentStarted(let index, let total):
            subDone = index - 1
            subTotal = total
            statusLine = "推送段 \(index)/\(total)…"
        case .segmentFinished(let index, let total):
            subDone = index
            subTotal = total
            statusLine = "已完成段 \(index)/\(total)"
        case .done:
            subTotal = nil
            statusLine = "推送完成"
            cancelDisabled = true
        }
    }

    // MARK: - pull event handling

    public func apply(pull event: FeishuPullCoordinator.Progress) {
        switch event {
        case .pullingDocument:
            statusLine = "从飞书读取正文…"
        case .imageStageStarted(let total):
            subDone = 0
            subTotal = total > 0 ? total : nil
            statusLine = total > 0 ? "下载飞书图片…" : "扫描图片…"
        case .imageDownloaded(let index, let total):
            subDone = index
            subTotal = total
            statusLine = "下载图片 \(index)/\(total)"
        case .imageStageFinished:
            subTotal = nil
            statusLine = "图片下载完成"
        case .done:
            subTotal = nil
            statusLine = "拉取完成"
            cancelDisabled = true
        }
    }
}
