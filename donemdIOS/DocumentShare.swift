import Foundation
import ZIPFoundation
import SwiftUI

enum DocumentShare {
    /// Exports a snapshot, never the live source. Only referenced local assets are included.
    static func prepare(source: String, name: String, assets: AssetsManager, bundled: Bool) throws -> URL {
        let manager = FileManager.default
        let workspace = manager.temporaryDirectory.appendingPathComponent("share-" + UUID().uuidString)
        let staging = workspace.appendingPathComponent("document")
        try manager.createDirectory(at: staging, withIntermediateDirectories: true)
        let document = staging.appendingPathComponent(name)
        do {
            try Data(source.utf8).write(to: document, options: .atomic)
            guard bundled else { return document }
            var referenced = Set<String>()
            func visit(_ node: TiptapNode) throws {
                if let value = node.attrs?["src"], case .string(let src) = value, src.hasPrefix("donemd-asset://") {
                    referenced.insert(String(src.dropFirst("donemd-asset://".count)))
                }
                if node.type == "raw_markdown_block", let raw = node.attrs?["raw"], case .string(let text) = raw, text.contains("assets/") {
                    // Opaque syntax is not safely enumerable; don't claim this bundle is complete.
                    throw NSError(domain: "DoneShare", code: 1, userInfo: [NSLocalizedDescriptionKey: "原文块包含附件路径，请用文件 App 分享整个文件夹，以免遗漏。"])
                }
                for child in node.content ?? [] { try visit(child) }
            }
            try visit(MarkdownEngine.parseDocument(source: source).body)
            for filename in referenced {
                guard let input = assets.storedFileURL(forFilename: filename) else {
                    throw NSError(domain: "DoneShare", code: 2, userInfo: [NSLocalizedDescriptionKey: "附件尚未下载或不存在：\(filename)。请下载后重试。"])
                }
                let folder = staging.appendingPathComponent("assets")
                try manager.createDirectory(at: folder, withIntermediateDirectories: true)
                var coordinationError: NSError?, copyError: Error?
                NSFileCoordinator().coordinate(readingItemAt: input, options: [], error: &coordinationError) { url in
                    do { try manager.copyItem(at: url, to: folder.appendingPathComponent(filename)) } catch { copyError = error }
                }
                if let error = copyError ?? coordinationError { throw error }
            }
            let archive = workspace.appendingPathComponent((name as NSString).deletingPathExtension + ".zip")
            try manager.zipItem(at: staging, to: archive, shouldKeepParent: false)
            try manager.removeItem(at: staging)
            return archive
        } catch { try? manager.removeItem(at: workspace); throw error }
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
