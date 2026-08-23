import Foundation

/// Production `AssetReader` that bridges `FeishuImageUploadStage` to
/// `AssetsManager`. Lives in `donemd/Assets/` next to the manager so the
/// dependency direction stays Feishu → Assets, not the reverse.
///
/// Wired in `FeishuPushCommand` (and, eventually, the v2-10 Settings
/// panel) — every place that constructs a real push pipeline.
final class AssetsManagerAssetReader: FeishuImageUploadStage.AssetReader {
    private let manager: AssetsManager

    init(manager: AssetsManager) {
        self.manager = manager
    }

    func readAsset(filename: String) -> (data: Data, mimeType: String)? {
        guard let url = manager.storedFileURL(forFilename: filename),
              let data = try? Data(contentsOf: url) else {
            return nil
        }
        return (data, AssetURLSchemeHandler.mimeType(forFilename: filename))
    }
}
