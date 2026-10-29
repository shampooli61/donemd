import SwiftUI
import UniformTypeIdentifiers

@main
struct DoneMobileApp: App {
    @StateObject private var folders: FolderStore
    @StateObject private var session: DocumentOpenCoordinator
    init() {
        let folders = FolderStore()
        _folders = StateObject(wrappedValue: folders)
        _session = StateObject(wrappedValue: DocumentOpenCoordinator(folders: folders))
    }
    var body: some Scene {
        WindowGroup {
            NavigationStack { FolderView(folders: folders, folder: nil) }
                .environmentObject(session)
                .onOpenURL { url in Task { await session.receiveExternal(url) } }
                .fullScreenCover(item: $session.opened, onDismiss: {
                    Task { await session.didDismiss() }
                }) { document in
                    MobileEditorScreen(document: document)
                        .environmentObject(session)
                        .interactiveDismissDisabled()
                }
        }
    }
}

struct FolderView: View {
    @ObservedObject var folders: FolderStore
    @EnvironmentObject private var session: DocumentOpenCoordinator
    let folder: URL?
    @State private var entries: [URL] = []
    @State private var choosing = false
    @State private var query = ""
    @State private var renaming: URL?
    @State private var newName = ""
    var current: URL? { folder ?? folders.root }
    var body: some View {
        List {
            if current == nil {
                ContentUnavailableView("接着写你的文档", systemImage: "doc.text", description: Text("选择 iCloud Drive 中的文件夹，在 Mac 和手机上使用同一份 Markdown。"))
                if session.pendingURL == nil {
                    Button("选择文档文件夹") { choosing = true }
                }
            }
            if let error = folders.error { Text(error).foregroundStyle(.red) }
            if let error = session.error { Text(error).foregroundStyle(.red) }
            if let pending = session.pendingURL {
                Section("来自文件 App") {
                    Text(pending.lastPathComponent)
                    if session.needsFolderAuthorization {
                        Text("进入此文档所在的文件夹后，点右上角“打开”授予访问权限。完成后将自动打开这份文档，无需再次选择文件。")
                        Button("选择文档所在文件夹") { choosing = true }
                    } else {
                        Button("重试打开文档") { Task { await session.openPending() } }
                        if session.canReauthorizePending {
                            Button("重新授权文档所在文件夹") { choosing = true }
                        }
                    }
                    Button("取消打开", role: .cancel) { session.cancelPending() }
                }.disabled(session.loading)
            }
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
            if session.loading { ProgressView("正在打开文档…") }
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
                        Button("下载文件夹供离线使用") {
                            do { try folders.requestOfflineDownload(in: current); folders.error = "已向系统请求下载。请在文件 App 确认文档和附件已下载后再离线使用。" }
                            catch { folders.error = error.localizedDescription }
                        }
                        Button("刷新") { reload() }
                    }
                } label: { Label("文件操作", systemImage: "plus.circle") }
            }
        }
        .fileImporter(isPresented: $choosing, allowedContentTypes: [.folder]) { result in
            switch result {
            case .success(let url): Task { await session.selectFolder(url); reload() }
            case .failure(let error): session.error = "无法选择文件夹：\(error.localizedDescription)。请重试。"
            }
        }
        .alert("重命名文档", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("文档名称", text: $newName)
            Button("取消", role: .cancel) { renaming = nil }
            Button("确定") { if let url = renaming { do { _ = try folders.rename(url, to: newName); reload() } catch { folders.error = error.localizedDescription } }; renaming = nil }
        }
        .refreshable { reload() }
        .task { reload() }
        .onChange(of: folders.root) { _, _ in reload() }
        .onChange(of: session.opened == nil) { _, closed in if closed { reload() } }
    }
    func reload() {
        guard let current else { return }
        do { entries = try folders.entries(in: current) } catch { folders.error = error.localizedDescription }
    }
    func open(_ url: URL) {
        Task { await session.open(url) }
    }
}

extension MobileDocument: Identifiable { var id: URL { fileURL } }

struct MobileEditorScreen: View {
    @ObservedObject var document: MobileDocument
    @EnvironmentObject private var session: DocumentOpenCoordinator
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var phase
    @State private var photos = false
    @State private var mediaFiles = false
    @State private var shareURL: URL?
    @State private var sharing = false
    @State private var recovery = false
    @State private var saving = false
    @State private var confirmingNormalization = false
    @State private var returnAfterConfirmation = false
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let pending = session.pendingURL {
                    VStack(alignment: .leading) {
                        Text("待打开：" + pending.lastPathComponent).font(.headline)
                        Text("请先保存并返回目录，再打开这份文档。")
                        Button("取消待打开文档") { session.cancelPending() }
                    }.font(.callout).padding()
                }
                if let error = session.error { Text(error).foregroundStyle(.red).font(.callout) }
                if let message = document.message { Text(message).font(.caption).padding(6).accessibilityIdentifier("document-status") }
                if document.conflict {
                    Button("保留所有版本并加载磁盘内容") {
                        Task {
                            do { try await document.preserveConflictsAndReload() }
                            catch { /* The document keeps the conflict and exposes the failure message. */ }
                        }
                    }.padding()
                }
                if document.needsNormalization {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("首次保存需要确认", systemImage: "info.circle").font(.headline)
                        Text("保存会统一 Markdown 格式。请确认后保存，或继续编辑。")
                            .font(.callout)
                        Button("确认格式并保存") { requestSave(returnToList: false) }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                            .disabled(saving)
                        Text("这是保存格式确认，不是 iCloud 同步开关。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding()
                        .background(Color.accentColor.opacity(0.08))
                }
                if document.importing { ProgressView("正在导入附件…") }
                if sharing { ProgressView("正在准备分享…") }
                MobileWebView(document: document)
            }
            .navigationTitle(document.fileURL.deletingPathExtension().lastPathComponent)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { requestSave(returnToList: true) } label: {
                        Label("返回", systemImage: "chevron.backward")
                    }
                        .disabled(saving)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("保存") { requestSave(returnToList: false) }.disabled(saving)
                        Button("恢复版本") { document.refreshRecovery(); recovery = true }
                        Button("分享 Markdown") { share(bundled: false) }
                        Button("打包分享文档与附件") { share(bundled: true) }
                        Button("从照片插入图片或视频") { photos = true }.disabled(document.isReadOnly || document.importing)
                        Button("从文件插入图片或视频") { mediaFiles = true }.disabled(document.isReadOnly || document.importing)
                    } label: { Label("文档操作", systemImage: "ellipsis.circle") }
                }
            }
            .alert("确认首次保存", isPresented: $confirmingNormalization) {
                Button(returnAfterConfirmation ? "保存并返回" : "确认并保存") {
                    document.acceptNormalization()
                    requestSave(returnToList: returnAfterConfirmation)
                }
                Button("继续编辑", role: .cancel) { }
            } message: {
                Text("首次保存会统一此文档的 Markdown 格式。确认后才会写入文件；选择继续编辑会保留当前内容。这不是 iCloud 同步授权。")
            }
            .sheet(isPresented: $recovery) {
                NavigationStack {
                    List(document.recoveryVersions) { version in
                        VStack(alignment: .leading) {
                            Text(version.date.formatted()).font(.headline)
                            Text(version.reason)
                            Text(String(version.markdown.prefix(300))).font(.caption)
                            Button("载入此版本（先备份当前内容）") {
                                Task {
                                    do { try await document.restore(version); recovery = false }
                                    catch { /* Keep the sheet open; the document exposes the failure message. */ }
                                }
                            }
                        }
                    }.navigationTitle("恢复版本").toolbar {
                        Button { recovery = false } label: {
                            Label("关闭", systemImage: "xmark")
                        }
                    }
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
    /// Only explicit save/return actions ask for consent; background autosave never presents a dialog.
    func requestSave(returnToList: Bool) {
        guard !saving else { return }
        saving = true
        Task { @MainActor in
            defer { saving = false }
            // Flush before deciding: the newest editor snapshot may introduce the first change.
            guard await document.saveNow() else {
                if document.needsNormalization {
                    returnAfterConfirmation = returnToList
                    confirmingNormalization = true
                }
                return
            }
            if returnToList {
                if await document.close() { dismiss() }
                else { document.message = "关闭文档失败，当前内容已保留，请重试。" }
            }
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
