import SwiftUI
import UIKit
import UniformTypeIdentifiers

@main
struct DoneMobileApp: App {
    @StateObject private var folders: FolderStore
    @StateObject private var session: DocumentOpenCoordinator
    init() {
        #if DEBUG
        // Explicit UI-test profile avoids simulator menu-animation idling; no behavior is bypassed.
        if ProcessInfo.processInfo.arguments.contains("--uitest-no-animations") {
            UIView.setAnimationsEnabled(false)
        }
        #endif
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
    @State private var renameError: String?
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
                    NavigationLink { FolderView(folders: folders, folder: url) } label: { Label(url.lastPathComponent, systemImage: "folder").frame(minHeight: 44) }
                } else {
                    Button { open(url) } label: { Label(url.deletingPathExtension().lastPathComponent, systemImage: "doc.text").frame(minHeight: 44) }
                        .contextMenu {
                            Button("重命名") { renameError = nil; newName = url.deletingPathExtension().lastPathComponent; renaming = url }
                            Button("创建副本") { do { _ = try folders.duplicate(url); reload() } catch { folders.error = error.localizedDescription } }
                            ShareLink(item: url) { Text("分享 Markdown 文件") }
                        }
                }
            }
            if current != nil && !session.loading {
                if entries.isEmpty {
                    ContentUnavailableView {
                        Label("文件夹里还没有文档", systemImage: "doc")
                    } actions: {
                        Button("新建文档") { createDocument() }
                    }
                } else if !query.isEmpty && !entries.contains(where: { $0.lastPathComponent.localizedCaseInsensitiveContains(query) }) {
                    ContentUnavailableView("没有匹配的文件名", systemImage: "magnifyingglass")
                }
            }
            if session.loading { ProgressView("正在打开文档…") }
        }
        .navigationTitle(current?.lastPathComponent ?? "马上做完")
        .searchable(text: $query, prompt: "按文件名查找")
        .toolbar {
            if current != nil {
                ToolbarItem(placement: .primaryAction) {
                    Button { createDocument() } label: { Label("新建文档", systemImage: "square.and.pencil") }.disabled(session.loading)
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { choosing = true } label: { Label("选择文档文件夹", systemImage: "folder") }
                    if let current {
                        Button {
                            do { try folders.requestOfflineDownload(in: current); folders.error = "已向系统请求下载。请在文件 App 确认文档和附件已下载后再离线使用。" }
                            catch { folders.error = error.localizedDescription }
                        } label: { Label("下载文件夹供离线使用", systemImage: "icloud.and.arrow.down") }
                        Button { reload() } label: { Label("刷新", systemImage: "arrow.clockwise") }
                    }
                } label: { Label("更多操作", systemImage: "ellipsis") }
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
            Button("确定") {
                guard let url = renaming else { return }
                do { _ = try folders.rename(url, to: newName); reload(); renaming = nil }
                catch {
                    renameError = error.localizedDescription
                    renaming = nil
                    DispatchQueue.main.async { renaming = url }
                }
            }.disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } message: { Text(renameError ?? "输入新的文档名称。") }
        .refreshable { reload() }
        .task { reload() }
        .onChange(of: folders.root) { _, _ in reload() }
        .onChange(of: session.opened == nil) { _, closed in if closed { reload() } }
    }
    func createDocument() {
        guard let current, !session.loading else { return }
        do { let url = try folders.newDocument(in: current); reload(); open(url) }
        catch { folders.error = error.localizedDescription }
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
    @State private var mediaSelectionToken: String?
    @State private var mediaExpectedType: String?
    @State private var photos = false
    @State private var mediaFiles = false
    @State private var shareURL: URL?
    @State private var sharing = false
    @State private var recovery = false
    @State private var restoring = false
    @State private var recoveryError: String?
    @State private var saving = false
    @State private var confirmingNormalization = false
    @State private var returnAfterConfirmation = false
    var body: some View {
        NavigationStack {
            MobileEditorWorkspace(document: document, editor: document.editor,
                saving: saving, sharing: sharing,
                save: { requestSave(returnToList: $0) },
                recover: { refreshRecovery(); recovery = true },
                share: { share(bundled: $0) },
                media: { usePhotos, token, expectedType in
                    mediaSelectionToken = token
                    mediaExpectedType = expectedType
                    if usePhotos { photos = true } else { mediaFiles = true }
                })
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
                    List {
                        if let recoveryError {
                            Text(recoveryError).foregroundStyle(.red)
                            Button("重试读取恢复版本") { refreshRecovery() }.disabled(restoring)
                        }
                        if document.recoveryVersions.isEmpty && recoveryError == nil {
                            ContentUnavailableView("暂无可恢复版本", systemImage: "clock.arrow.circlepath", description: Text("不代表原文已丢失。"))
                        }
                        ForEach(document.recoveryVersions) { version in
                            NavigationLink {
                                ScrollView {
                                    VStack(alignment: .leading, spacing: 16) {
                                        Text(version.date.formatted()).font(.headline)
                                        Text(version.reason).font(.callout)
                                        Text(version.markdown).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                                        if let recoveryError { Text(recoveryError).foregroundStyle(.red) }
                                        if restoring { ProgressView("正在保护当前内容并载入版本…") }
                                        Button("载入此版本（先备份当前内容）") {
                                            guard !restoring else { return }
                                            restoring = true; recoveryError = nil
                                            Task {
                                                defer { restoring = false }
                                                do { try await document.restore(version); recovery = false }
                                                catch { recoveryError = document.message ?? error.localizedDescription }
                                            }
                                        }.disabled(restoring || document.isReadOnly)
                                    }.padding()
                                }.navigationTitle("版本预览")
                            } label: {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(version.date.formatted()).font(.headline)
                                    Text(version.reason).font(.callout)
                                    Text(String(version.markdown.prefix(300))).font(.caption)
                                }
                            }.disabled(restoring)
                        }
                    }.navigationTitle("恢复版本").toolbar {
                        Button { recovery = false } label: {
                            Label("关闭", systemImage: "xmark")
                        }.disabled(restoring)
                    }
                }.interactiveDismissDisabled(restoring)
            }
            .sheet(isPresented: Binding(get: { shareURL != nil }, set: { if !$0 { shareURL = nil } })) {
                if let url = shareURL { ShareSheet(url: url) }
            }
            .sheet(isPresented: $photos, onDismiss: { mediaSelectionToken = nil; mediaExpectedType = nil }) { MediaPicker { result in
                let token = mediaSelectionToken
                let expectedType = mediaExpectedType
                photos = false
                switch result {
                case .success(let url): Task { await document.importMedia(url, removeTemporary: true, selectionToken: token, expectedType: expectedType) }
                case .failure(let error):
                    if (error as NSError).code != CocoaError.Code.userCancelled.rawValue { document.message = error.localizedDescription }
                }
            } }
            .sheet(isPresented: Binding(get: { document.previewURL != nil }, set: { if !$0 { document.previewURL = nil } })) {
                if let url = document.previewURL { MediaPreview(url: url) }
            }
            .fileImporter(isPresented: $mediaFiles, allowedContentTypes: [.image, .movie]) { result in
                let token = mediaSelectionToken
                let expectedType = mediaExpectedType
                mediaSelectionToken = nil
                mediaExpectedType = nil
                switch result {
                case .success(let url): Task { await document.importMedia(url, selectionToken: token, expectedType: expectedType) }
                case .failure(let error):
                    if (error as NSError).code != CocoaError.Code.userCancelled.rawValue { document.message = error.localizedDescription }
                }
            }
            .onChange(of: phase) { _, phase in if phase != .active { Task { _ = await document.saveNow() } } }
        }
    }
    private func refreshRecovery() {
        recoveryError = nil
        if !document.refreshRecovery() {
            recoveryError = document.message ?? "无法读取恢复版本，请重试。"
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
