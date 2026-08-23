import Foundation

/// Cooperative cancellation flag for push / pull pipelines.
///
/// `Task.checkCancellation()` would normally cover this, but
/// FeishuPushCoordinator's segmented push runs through several
/// non-throwing helpers + an `URLSession.data(for:)` per HTTP call
/// — flipping the whole pipeline to inherit task cancellation
/// would be invasive. A standalone signal also lets the UI flip it
/// from a plain Button without holding a `Task` handle.
///
/// Sendable + a simple lock — coordinator and UI share one
/// instance. The coordinator polls at every segment / image
/// boundary; the UI button writes once. No need for the heavier
/// AsyncStream / Continuation machinery.
public final class FeishuSyncCancellationSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var _cancelled = false

    public init() {}

    /// True after `cancel()` has been called at least once.
    /// Coordinator polls this at every safe checkpoint.
    public var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return _cancelled
    }

    /// Idempotent — calling it twice is safe (the UI may bind it
    /// to a button users can mash).
    public func cancel() {
        lock.lock(); defer { lock.unlock() }
        _cancelled = true
    }
}
