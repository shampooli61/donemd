import AppKit
import Quartz

/// Presents a document image in the native QuickLook panel (Phase 5 S5 / #77).
///
/// Why native and not a WKWebView DOM overlay: the preview must cover the
/// whole window / screen, but a DOM lightbox is clipped to the Visual pane's
/// webview. `QLPreviewPanel` is the system's own full-screen-capable image
/// viewer (space-bar Finder preview) — native zoom / pan / full-screen /
/// share for free, zero maintenance, and it matches Done.md's "native Mac
/// editor" positioning.
///
/// Usage: `ImagePreviewController.shared.preview(url:)` with the asset's
/// on-disk file URL. The controller is a process-wide singleton because
/// `QLPreviewPanel` itself is a shared panel — only one can be up at a time.
final class ImagePreviewController: NSObject {
    static let shared = ImagePreviewController()

    /// The file currently being previewed. QuickLook shows one item here;
    /// multi-image galleries aren't needed (each click previews one image).
    private var previewURL: URL?

    private override init() { super.init() }

    /// Open (or refocus) the QuickLook panel on `url`. No-ops if the file
    /// doesn't exist — the caller already resolved it from AssetsManager, but
    /// guard anyway so a stale asset never throws a broken panel.
    func preview(url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        previewURL = url
        guard let panel = QLPreviewPanel.shared() else { return }
        panel.dataSource = self
        panel.delegate = self
        if QLPreviewPanel.sharedPreviewPanelExists() && panel.isVisible {
            // Already open (e.g. clicking a different image) — just refresh.
            panel.reloadData()
        } else {
            panel.makeKeyAndOrderFront(nil)
        }
    }
}

// MARK: - QLPreviewPanelDataSource

extension ImagePreviewController: QLPreviewPanelDataSource {
    func numberOfPreviewItems(in panel: QLPreviewPanel) -> Int {
        previewURL == nil ? 0 : 1
    }

    func previewPanel(_ panel: QLPreviewPanel, previewItemAt index: Int) -> QLPreviewItem? {
        // QLPreviewItem is satisfied by NSURL (previewItemURL).
        previewURL as NSURL?
    }
}

// MARK: - QLPreviewPanelDelegate

extension ImagePreviewController: QLPreviewPanelDelegate {
    /// Let the panel handle its own key events (Esc to close, arrows, etc.).
    func previewPanel(_ panel: QLPreviewPanel, handle event: NSEvent) -> Bool {
        false
    }
}
