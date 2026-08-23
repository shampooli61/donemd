import AppKit
import UniformTypeIdentifiers

/// Shows the standard macOS image-picker open panel.
///
/// Slice 9 (#5) only verifies that the panel comes up under `Cmd+Shift+I`.
/// Slice 11 (#6) wires the picked URL through `AssetsManager` and inserts
/// an image node into the document via the bridge.
enum InsertImageCommand {
    /// Run the open panel synchronously and return the picked image URL,
    /// or `nil` if the user cancelled. Must be called from the main thread —
    /// menu actions and SwiftUI button callbacks already satisfy that.
    static func presentOpenPanel() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "选择图片"
        panel.message = "选一张图片插入到当前文档"
        panel.prompt = "插入"
        panel.allowedContentTypes = [UTType.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }
}
