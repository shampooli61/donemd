import AppKit
import UniformTypeIdentifiers

/// Shows the standard macOS video-picker open panel (#88).
///
/// The picker is filtered to WebKit-inline-playable containers only
/// (MP4 / MOV / M4V / WebM) — formats WKWebView's `<video>` can't play
/// (Ogg / MKV / AVI / WMV) are blocked at the source so the user never
/// inserts a clip that won't play. The picked URL is handed to
/// `DonemdDocument.insertVideo(from:)`, which copies bytes via
/// `AssetsManager.importVideo` and inserts a `video` node over the bridge.
enum InsertVideoCommand {
    /// Content types the Visual pane can actually play inline. `.webm` has no
    /// standard `UTType` constant, so resolve it by filename extension; skip
    /// it if the system can't map it rather than widening to all movies.
    private static var playableContentTypes: [UTType] {
        var types: [UTType] = [.mpeg4Movie, .quickTimeMovie]
        if let m4v = UTType(filenameExtension: "m4v") { types.append(m4v) }
        if let webm = UTType(filenameExtension: "webm") { types.append(webm) }
        return types
    }

    /// Run the open panel synchronously and return the picked video URL, or
    /// `nil` if the user cancelled. Main-thread only (menu / button callbacks).
    static func presentOpenPanel() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "选择视频"
        panel.message = "选一个视频插入到当前文档（仅支持可内联播放的格式）"
        panel.prompt = "插入"
        panel.allowedContentTypes = playableContentTypes
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }
}
