import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

/// System picker grants only the selected media; no photo-library-wide permission.
struct MediaPicker: UIViewControllerRepresentable {
    var onPick: (Result<URL, Error>) -> Void
    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration()
        config.selectionLimit = 1
        config.filter = .any(of: [.images, .videos])
        config.preferredAssetRepresentationMode = .current
        let controller = PHPickerViewController(configuration: config)
        controller.delegate = context.coordinator
        return controller
    }
    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }
    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let onPick: (Result<URL, Error>) -> Void
        init(onPick: @escaping (Result<URL, Error>) -> Void) { self.onPick = onPick }
        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            picker.dismiss(animated: true)
            guard let provider = results.first?.itemProvider else { return }
            let type = provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier) ? UTType.movie.identifier : UTType.image.identifier
            provider.loadFileRepresentation(forTypeIdentifier: type) { url, error in
                do {
                    guard let url else { throw error ?? CocoaError(.fileReadUnknown) }
                    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension(url.pathExtension)
                    try FileManager.default.copyItem(at: url, to: temporary)
                    DispatchQueue.main.async { self.onPick(.success(temporary)) }
                } catch { DispatchQueue.main.async { self.onPick(.failure(error)) } }
            }
        }
    }
}

struct MediaPreview: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController(); controller.dataSource = context.coordinator; return controller
    }
    func updateUIViewController(_ uiViewController: QLPreviewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(url: url) }
    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let url: URL
        init(url: URL) { self.url = url }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem { url as NSURL }
    }
}
import QuickLook
