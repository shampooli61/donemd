# iOS 文档与 iCloud Drive
状态：采用。2026-10-19。

选择 SwiftUI + WKWebView，复用 Visual 与 Markdown 引擎。iOS 17+；共享源文件而非复制解析器。新增移动文档层，使用 UIDocument；Mac 保留 NSDocument。直接打开用户授权目录中的文件，书签失效须重新授权。

文件仍是 `.md` 和相邻 `assets/`，不打包成专有文档，不新增服务端。iCloud Drive 负责传输。写入完成只证明本地保存；不声称其他设备已接收。每份文档保留原始输入，首次实际规范化时提示；仅阅读不写回。

冲突必须保留版本；恢复副本先写入成功再覆盖。目录授权、下载、冲突、保存失败是可见状态。取消授权不删除原目录。附件先落盘再插入引用，失败不插入死链接；删除节点不自动删除可能被其他文档引用的附件。

首版源码只读；移动端不启用 AI/飞书操作，但保留元数据与占位内容。手机单栏完整写作，文件浏览仅反映用户目录，不演变为笔记库。

## 外部文件打开（#113，2026-10-20）

通过 SwiftUI `onOpenURL` 接收 Files/其他应用传入的本地 Markdown URL，与应用内列表共用一个文档会话。保留原位编辑；不把外部文件静默复制成应用内副本。仅声明 Markdown 文档类型，关闭不匹配当前自建目录列表的 `UISupportsDocumentBrowser` 声明，保留 `LSSupportsOpeningDocumentsInPlace` 与文件共享。

外部单文件权限不等于相邻目录权限。已授权目录及其子目录可直接打开；未知目录先明确请求选择文档所在文件夹，供正文和 assets 共用访问权限。待处理 URL 的安全作用域由会话持有，并在实际打开后转交当前文档会话，取消/失败无待处理请求/关闭后释放。打开失败保留请求供重试或取消。

当前文档未返回目录时，外部请求不得替换编辑器；只保留一个待打开请求，重复请求合并，新的不同请求明确提示先处理原请求。保存并关闭后再打开待处理文件；取消待处理请求不会丢弃当前编辑。

Apple 参考：[onOpenURL](https://developer.apple.com/documentation/swiftui/view/onopenurl(perform:))、[document browser 的 root view controller 要求](https://developer.apple.com/documentation/uikit/adding-a-document-browser-to-your-app)。
