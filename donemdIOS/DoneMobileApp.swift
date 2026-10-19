import SwiftUI
import UniformTypeIdentifiers

@main
struct DoneMobileApp: App {
    @StateObject private var folders = FolderStore()
    var body: some Scene {
        WindowGroup {
            NavigationStack { FolderView(folders: folders, folder: nil) }
        }
    }
}

struct FolderView: View {
    @ObservedObject var folders: FolderStore
    let folder: URL?
    @State private var entries: [URL] = []
    @State private var choosing = false
    @State private var opened: MobileDocument?
    @State private var loading = false
    @State private var query = ""
    @State private var renaming: URL?
    @State private var newName = ""
    var current: URL? { folder ?? folders.root }
    var body: some View {
        List {
            if current == nil {
                ContentUnavailableView("接着写你的文档", systemImage: "doc.text", description: Text("选择 iCloud Drive 中的文件夹，在 Mac 和手机上使用同一份 Markdown。"))
                Button("选择文档文件夹") { choosing = true }
            }
            if let error = folders.error { Text(error).foregroundStyle(.red) }
            ForEach(entries.filter { query.isEmpty || $0.lastPathComponent.localizedCaseInsensitiveContains(query) }, id: \.self) { url in
                if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    NavigationLink(url.lastPathComponent) { FolderView(folders: folders, folder: url) }
                } else {
                    Button { open(url) } label: { Label(url.deletingPathExtension().lastPathComponent, systemImage: "doc.text") }
                        .contextMenu {
                            Button("重命名") { newName = url.deletingPathExtension().lastPathComponent; renaming = url }
                            Button("创建副本") { do { _ = try folders.duplicate(url); reload() } catch { folders.error = error.localizedDescription } }
                            ShareLink(item: url) { Text("分享 Markdown 文件") }
                        }
                }
            }
            if loading { ProgressView("正在打开文档…") }
        }
        .navigationTitle(current?.lastPathComponent ?? "马上做完")
        .searchable(text: $query, prompt: "按文件名查找")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("选择文档文件夹") { choosing = true }
                    if let current {
                        Button("新建文档") {
                            do { let url = try folders.newDocument(in: current); reload(); open(url) }
                            catch { folders.error = error.localizedDescription }
                        }
                        Button("刷新") { reload() }
                    }
                } label: { Image(systemName: "plus.circle").accessibilityLabel("文件操作") }
            }
        }
        .fileImporter(isPresented: $choosing, allowedContentTypes: [.folder]) { result in
            do { try folders.select(result.get()); reload() } catch { folders.error = error.localizedDescription }
        }
        .alert("重命名文档", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("文档名称", text: $newName)
            Button("取消", role: .cancel) { renaming = nil }
            Button("确定") { if let url = renaming { do { _ = try folders.rename(url, to: newName); reload() } catch { folders.error = error.localizedDescription } }; renaming = nil }
        }
        .refreshable { reload() }
        .task { reload() }
        .onChange(of: folders.root) { _, _ in reload() }
        .fullScreenCover(item: $opened, onDismiss: { reload() }) { document in MobileEditorScreen(document: document) }
    }
    func reload() {
        guard let current else { return }
        do { entries = try folders.entries(in: current) } catch { folders.error = error.localizedDescription }
    }
    func open(_ url: URL) {
        guard !loading else { return }; loading = true
        Task { @MainActor in
            let document = MobileDocument(fileURL: url)
            if await document.open() { opened = document } else { folders.error = "无法打开。请确认文件已下载，再重试。" }
            loading = false
        }
    }
}

extension MobileDocument: Identifiable { var id: URL { fileURL } }

struct MobileEditorScreen: View {
    @ObservedObject var document: MobileDocument
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var phase
    @State private var photos = false
    @State private var mediaFiles = false
    @State private var shareURL: URL?
    @State private var sharing = false
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let message = document.message { Text(message).font(.caption).padding(6) }
                if document.needsNormalization {
                    VStack {
                        Text("保存会将原文件统一为 Done.md 的 Markdown 写法。正文和元数据仍会保留。")
                        Button("允许规范化并保存") { document.acceptNormalization(); Task { _ = await document.saveNow() } }
                    }.font(.caption).padding()
                }
                if document.importing { ProgressView("正在导入附件…") }
                if sharing { ProgressView("正在准备分享…") }
                MobileWebView(document: document)
            }
            .navigationTitle(document.fileURL.deletingPathExtension().lastPathComponent)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("返回") {
                        Task {
                            guard await document.saveNow() else { return }
                            if await document.close() { dismiss() }
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("保存") { Task { _ = await document.saveNow() } }
                        Button("分享 Markdown") { share(bundled: false) }
                        Button("打包分享文档与附件") { share(bundled: true) }
                        Button("从照片插入图片或视频") { photos = true }
                        Button("从文件插入图片或视频") { mediaFiles = true }
                    } label: { Image(systemName: "ellipsis.circle").accessibilityLabel("文档操作") }
                }
            }
            .sheet(isPresented: Binding(get: { shareURL != nil }, set: { if !$0 { shareURL = nil } })) {
                if let url = shareURL { ShareSheet(url: url) }
            }
            .sheet(isPresented: $photos) { MediaPicker { result in
                photos = false
                switch result {
                case .success(let url): Task { await document.importMedia(url, removeTemporary: true) }
                case .failure(let error): document.message = error.localizedDescription
                }
            } }
            .sheet(isPresented: Binding(get: { document.previewURL != nil }, set: { if !$0 { document.previewURL = nil } })) {
                if let url = document.previewURL { MediaPreview(url: url) }
            }
            .fileImporter(isPresented: $mediaFiles, allowedContentTypes: [.image, .movie]) { result in
                switch result {
                case .success(let url): Task { await document.importMedia(url) }
                case .failure(let error): document.message = error.localizedDescription
                }
            }
            .onChange(of: phase) { _, phase in if phase != .active { Task { _ = await document.saveNow() } } }
        }
    }
    func share(bundled: Bool) {
        guard !sharing else { return }
        sharing = true
        Task { @MainActor in
            defer { sharing = false }
            guard await document.saveNow() else { return }
            do {
                let source = document.source, name = document.fileURL.lastPathComponent, assets = document.assets
                shareURL = try await Task.detached { try DocumentShare.prepare(source: source, name: name, assets: assets, bundled: bundled) }.value
            } catch { document.message = "分享失败：\(error.localizedDescription)" }
        }
    }

}
