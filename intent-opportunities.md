# Done.md：首次导入 App Intents 机会评估

## 现有 App Intents 清单

**当前源码声明的 App Intents 动作为 0 项；没有发现声明用于 Shortcuts、App Shortcuts、Spotlight、Siri、Widget 或 Control 的 Intent，也没有发现采用 Apple Intelligence schema 的动作。**

| 业务动作 | Intent / Shortcut / Entity / Query 路径与符号 | 当前接线 | 缺口与证据边界 |
| --- | --- | --- | --- |
| 无 | 全仓检索 `AppIntent`、`AppShortcut`、`AppShortcutsProvider`、`AppEntity`、`EntityQuery`、`IntentDefinition`、`AssistantIntent`、`AssistantEntity`、`import AppIntents`、`@Assistant`，无匹配 | 无 provider、实体查询、schema 声明 | 结论来自可读源码与生成输入；没有安装包元数据或系统运行证据 |

检索覆盖 `donemdIOS`、`donemd`、共享 Swift 文件、Web TS、测试与 `project.yml`；Git 跟踪文件中无 `.intentdefinition`、`.pbxproj`、`.xcconfig`、`.entitlements`。`project.yml` 没有声明 Intent/Widget/Control 扩展 target。文件类型注册和 `DoneMobileApp.onOpenURL` 是现有文件打开入口，**不是** App Intent 集成。没有“已有集成优化项”，也不建议重复建设一套已有 Intent。

## 项目与评估范围

- 日期：2026-10-29。首次导入后的机会评估，不实施系统入口集成。
- 基线：`codex/ios-document-editor`，完整提交 `753e5ce24226958753d340d336dbc5be1841e6ba`；开始时 `git status --short` 为空。根目录原无本报告，故无历史结论或本轮业务代码变更可比较。
- 依据：已读 `AGENTS.md`、`docs/CONTEXT.md`、`docs/prd/ios-document-editor.md`、`docs/adr/ios-document-storage.md`、`project.yml`，以及下列实际 Swift/TS 实现。PRD 写“实施中”，本文逐项以函数体而不是故事列表判定已实现。
- 范围：主要面向 iOS 文档端，macOS 仅用于确认 target 边界、共享源和现有 Intent 清单，不把桌面 AI/飞书服务当作移动端能力。
- 约束：真实 `.md` 文件与相邻 `assets/`，不是笔记库；Visual 写作、源码只读；仅阅读不写回，首次实际规范化须确认；冲突先保留，不能自动合并；本地保存不代表 iCloud 另一设备已收到。

| Target / 配置 | 源码成员与资源 | 最低系统 | SDK / 工具链证据 | 未知项 |
| --- | --- | --- | --- | --- |
| `donemdIOS` / Debug、Release | `donemdIOS/`；共享 `donemd/MarkdownEngine/`、`Assets/AssetsManager.swift`、`Save/DocumentRecoveryStore.swift`、`Bridge/AssetURLSchemeHandler.swift`；`Resources/Web` | `project.yml` 明确 iOS 17.0；iPhone/iPad | 用户明确本次将用 **Xcode 27.1 RC**；不是本机检测结果。全局 `SWIFT_VERSION: 5.9` | 无 Xcode/SDK 实机读取，RC build 号、所带 SDK 版本及生成后有效 build settings 未确认 |
| `donemdIOSTests` | `donemdIOSTests/`，依赖 `donemdIOS` | iOS 17.0 | 同上；只识别测试文件，未运行 | 生成与编译结果未知 |
| `donemdIOSUITests` | `donemdIOSUITests/`，依赖 `donemdIOS` | iOS 17.0 | 同上 | 模拟器和真机结果未知 |
| `donemd` / Debug、Release | `donemd/`、`Resources/Web`；Swift Markdown/Yams/Sparkle | 全局 macOS 13.0 | 同一生成输入；Debug 存在签名和 hardened runtime 覆盖，未执行 | 不作本轮 macOS 接入建议 |
| `donemdTests` | `donemdTests/`，依赖桌面应用 | 全局 macOS 13.0 | 同上 | 不作本轮实施或测试 |

`project.yml` 的 iOS pre-build 调用 `web/package.json` 的构建链；`web/vite.config.ts` 将包括 `mobile` 在内的入口产出至 `Resources/Web`。`web/mobile.html` → `web/src/mobile.ts` → `MobileWebView` 加载 bundle 中的 `Web/mobile.html`，不是仅在仓库中存在但未接线的 TS。

### 实际访问限制

本分析运行在 Linux，`command -v xcodebuild`、`command -v xcrun` 无结果；`/Applications` 不存在。在 `/opt`、`/usr/local`、`/run/airbuild` 深度 5 范围未找到 iPhoneOS SDK、`AppIntents.swiftinterface` 或 `AppIntentSchemas.sqlite`。这是**本次可检查范围内缺少所选 SDK**，不是声称所有远端构建服务均不可用。

网络并非不可用：只读请求 Apple 文档成功，随后实际读取 7 个官方 DocC JSON 的声明及 platform 元数据（A1–A7）。但这不能证明 Xcode 27.1 RC 内有相同声明；尚未逐符号核对参数、结果、初始化器、短语 token、schema member 等完整依赖。本轮未生成 Xcode 工程、未安装依赖、未构建、未启动应用或模拟器、未操作文件业务。指南记录的 iOS 26 starter / Xcode 27 beta 环境不作为本项目事实。

## 决策摘要

**可进入实施的首批：0 项。** 普通 Intent 与可选 schema 路径均不计入 ready batch。原因不是业务没有价值，而是所选 Xcode 27.1 RC SDK 不可读、完整 API 依赖证据不齐，且跨启动文件身份、查询授权及前台会话衔接仍需设计与核验。

| 候选顺序 | 动作 | 业务状态 | 普通路径结论 | 可选 schema 结论 | 估算 |
| --- | --- | --- | --- | --- | --- |
| P1 | 打开指定 Markdown 文档 | 已实现 | **需验证**；优先核验的最高价值入口 | **需验证**，未确定精确 domain/member | M |
| P2 | 按名称查找文档并选择打开 | 已实现（当前目录文件名过滤） | **需验证**；不是全文/全盘搜索 | **需验证**，未确定 member | M |
| P3 | 在授权文件夹新建空白文档 | 已实现（固定内容） | **需验证**；不得宣传为任意文本捕获 | **需验证**，未确定 member | M |
| P4 | 导出 Markdown / 附件包副本 | 已实现 | **需验证**；敏感数据与结果文件契约较多 | **需验证**，未确定 member | L |

以上是**待验证队列，不是已推荐可实现批次**。没有使用率数据，排序是任务价值、减少目录层级跳转、代码就绪度及风险的定性判断。产品应先决定是否仅开放“用户显式选择的目录、前台执行、最小文件名信息”，优先核验 P1，再考虑 P2/P3；导出不与首次打开入口绑定上线。其余实现过但不值得首批接入的任务见排除表。

## 共同的数据、权限和系统入口边界

以下规则适用于全部候选，不在个别动作中悄悄更换身份/歧义策略：

1. **既有数据状态**：`FolderStore.init/select` 将一个目录 bookmark 存入 `UserDefaults` 并恢复安全作用域；不是统一实体库，也没有最近文档数据库。`entries(in:)` 非递归枚举、排除隐藏项/符号链接/`assets`，返回目录或 Markdown，按文件名排序。`FolderView` 当前目录与查询在视图中；`DocumentOpenCoordinator`、`MobileDocument` 和 TS editor 状态在当前进程/视图中。目录 bookmark 可跨启动，但文件 URL/路径不等于已证明在重命名、移动、iCloud 重定位后仍稳定的实体 ID。
2. **提议而非现有能力**：如引入文档/目录实体，其持久身份需设计可重解析的授权引用与映射（可评估 bookmark 与根目录内相对定位，但未证明任一方案足够）；不得仅凭同名文件自动执行。查询与执行均重新检查目录授权、作用域、路径越界/符号链接、文件类型、存在与下载状态。缺失/移动/过期时停止并引导前台重选；名称重复时展示目录上下文供选择，绝不取第一个或静默改选。失权后撤回缓存/索引为新增要求。
3. **访问控制**：移动业务链没有应用账户登录或 owner/ACL 模型；授权来自系统选目录及文件访问，不等于应用能判断 iCloud 共享文档的所有者。设备解锁/Intent 认证策略、应用登录、具体文件权限、动作确认是不同层；当前没有 Intent 认证或确认策略实现。实体查询也会泄露文件名，不能只在 `perform` 才检查；默认不返回正文、frontmatter 或飞书身份，不语音播报路径/内容。是否允许锁屏展示须由产品决定并验证。
4. **执行方向**：首选前台、主会话内执行。`FolderStore` / `DocumentOpenCoordinator` 是主线程对象且在 `DoneMobileApp` 内创建；TS 工作依赖 WKWebView。没有证据证明冷启动、无活跃视图的后台执行可复用这些状态，也没有新增后台服务计划。前台重选授权不能伪装成后台成功。
5. **系统入口分别评估**：下表的入口结论用于每个候选；没有一个入口已接线。

| 入口 | 当前证据与建议边界 |
| --- | --- |
| Shortcuts 普通动作 | A1–A3 只验证基础类型的文档声明；参数、查询要求、结果和认证依赖仍不全。待完整核验、元数据构建及授权/冷启动场景后再决定支持范围 |
| App Shortcuts | A4/A5 只验证 provider/shortcut 类型存在；未验证所需初始化器重载、短语类型及 application-name token，不能因指南示例宣布已就绪。建议将此曝光与普通动作分开验收 |
| Spotlight | 文件类型注册不等于内容索引；动作曝光和具体文档内容检索是两项工作。没有索引/撤回接线；需独立评估索引 API、系统版本、授权失效与隐私，不默认索引整目录正文 |
| Siri | 无 provider/短语及真机证据。普通 Siri 语音入口需独立完成中文短语、歧义、锁屏和前台切换验证；不能由 Shortcuts 列表可见推导可运行 |
| Apple Intelligence | 未确认任何精确 schema 的语义、参数/结果、依赖实体和成组动作要求；不承诺支持。OS、SDK、设备硬件、语言/地区及功能开关条件均需按最终选定功能查证，不以普通 Intent 或宏声明替代 |

## 已评估动作

### P1 打开指定 Markdown 文档——从系统入口直接接着写

- **业务状态：已实现。** `donemdIOS/DoneMobileApp.swift` 的 `FolderView.open` → `DocumentOpenCoordinator.open` → `MobileDocument(fileURL:)` / `open()`，成功后由 `session.opened` 驱动 `MobileEditorScreen`。外部 URL 另走 `DoneMobileApp.onOpenURL` → `receiveExternal` → `openPending`；它校验本地 Markdown，持有安全作用域，检查目录授权，并保留一个待处理请求。
- **完整正文链**：`MobileDocument.load(fromContents:ofType:)` → `donemd/MarkdownEngine/MarkdownEngine.swift` 的 `parseDocument` 保留 frontmatter 与正文；`MobileWebView.Coordinator.load` 发 `loadDocument` → `web/src/mobile.ts` 的 `loadMobileDocument` 加载编辑器。`documentChanged` / `donemdMobileSnapshot` 经 Swift `applySnapshot` → `applyEditorSnapshot`（revision 检查）→ `replaceBody` → `saveNow`。所以“打开后继续写”有真实业务基础，但不能把 Intent 简化为绕过文档层直接写字符串。
- **结论：需验证。** 普通路径是首要核验机会，不是 ready 推荐；现有 Intent 为无。权限、依赖 API 和前台会话桥接尚未闭合。
- **提议方向**：必需参数为一个明确文档；提议薄文档实体与按 ID/名称查询，不是假设现有实体。展示名含目录上下文；身份/歧义遵守共同规则。结果应为“已打开”或“待当前文档保存返回后打开”，不能将排队描述为已打开。重复打开同一活动/打开中的文件，`receiveExternal` 现有逻辑不重复打开；另一个文件不能替换正在编辑的文档。提议 Intent 复用这条受控流程，不能直接调用 guard 不满足就返回的 `open` 并报成功。
- **访问与安全**：`hasFolderAccess` 在外部接收流程中按标准化且解析符号链接后的根目录判断，未知目录需用户授权；普通 `open` 本身不包含相同目录校验。因此新增系统入口也必须经过验证，不可把外部输入视为列表可信 URL。当前文档须先保存/关闭；`saveNow` 保留首次规范化、冲突/备份失败等阻断，不可自动确认。
- **普通路径**：A1/A2/A3/A6 为基础线索；iOS 17 前台方案可调查 A6，不能直接套用 iOS 26+ 示例的 A7。完整参数、结果、查询与路由声明仍属 G1–G3，所选 SDK 属 G4。支持 Shortcuts 为待验证主方向，App Shortcut/Siri/Spotlight 分别依共同表验收。
- **schema 增强**：精确 domain/member **未确定**。文件型文档不自动等同“笔记/账户/笔记夹”；不能为了匹配 schema 改变单文件产品。G5 须检查官方 schema 语义、必要参数/结果、实体依赖、成组动作和最低系统，低系统保留普通入口/原应用流程；当前不设猜测版本 gate。
- **价值/成本**：P1，M；减少跨目录找文件，复用受控打开链，但新增持久身份、冷启动解析、前台请求衔接及失败反馈。假设不做全文索引、不新增扩展。
- **下一步**：先核验 G1–G5；后续授权实施时测试同名、已打开、忙碌/未保存、失效 bookmark、文件删除/迁移、未下载、未知目录及重启。源码证据已读；编译、可见性、模拟器执行、真机执行均未做。

### P2 按名称查找文档并选择打开——不必先逐级浏览

- **业务状态：已实现但范围有限。** `DoneMobileApp.swift` 的 `FolderView.searchable` / `query` → `entries.filter`，匹配当前目录 `lastPathComponent.localizedCaseInsensitiveContains`；列表源为 `FolderStore.entries(in:)`。选择命中后进入 P1 的完整打开链。不是递归搜索，不读正文，不跨用户未授权目录。
- **结论：需验证。** 提议必需查询字符串，目录可选但缺省必须明确为已授权根目录（这是新增契约，不能偷用并不存在于服务层的“当前文件夹”）。结果是有限文件名列表，选择后前台打开；同名必须带目录上下文并让用户选定。无匹配不创建文件；重复查询不修改内容；选择打开的重复行为同 P1。
- **数据/安全**：枚举逻辑可抽取复用，但当前查询留在 SwiftUI 视图，没有独立持久搜索服务；实体 ID、失权、路径约束沿用共同规则。应限制建议数量/枚举规模，不能默认扫描全盘；目录名和标题本身可能敏感。没有应用登录，更没有跨 owner 检索授权。
- **普通路径**：拟用 A1–A3；字符串查询协议/方法与返回列表契约仍未核验（G1/G2），前台呈现走 G3/G4。Shortcuts 搜索与选择有价值；App Shortcut 和 Siri 需另验短语与消歧；Spotlight 内容索引不在该最小路径内。
- **schema 增强**：未确定精确成员，不能因业务名叫“搜索”就声称满足系统搜索 schema；需 G5 证明搜索范围、结果及实体契约，保留普通路径作为未来低版本回退。Apple Intelligence 未验证。
- **价值/成本**：P2，M；与 P1 共用身份/授权建设后边际成本降低。若产品要求递归、全文或最近文档，属于新业务，需重新评估成本，不在本文实现结论内。
- **下一步**：核验相关查询声明，并在后续授权测试中覆盖空字符串、无结果、多结果、大小写、授权撤回和枚举失败。未构建/运行/验证曝光。

### P3 在授权文件夹新建空白文档——快速开始写作

- **业务状态：已实现。** `FolderView` 菜单“新建文档” → `FolderStore.newDocument(in:)` → `Data("# 未命名\n".utf8).write(..., .withoutOverwriting)`；成功后 `reload`、`open(url)`。文件名从 `未命名.md` 起顺延编号，不覆盖已有文件。
- **结论：需验证。** 提议参数为目录（可选，缺省已授权根目录）；本轮最小方向不接收自定义标题、正文或追加内容，因为既有函数没有这些参数。成功结果是新文件引用；创建成功但打开受阻须如实区分，不能称“已打开”。
- **重复与歧义**：每次调用均创建新的文件，非“确保同一文档存在”；系统重试可能产生多个文件。若要幂等请求键、防重复点击或指定标题/文本校验，均是新增业务规则，计入成本。目录只能按共同身份规则解析，同名目录必须选择，失权不得退到别的路径。
- **权限/安全**：既有函数自身不校验根目录范围、无应用登录/owner 判断；入口须新增授权与路径校验。写共享 iCloud 目录可能对其他人可见，需前台明确目标；是否每次确认由产品决定，不能假定 schema 会代办。失败不得写覆盖或自动切换目录；没有撤销/删除函数可直接复用。
- **普通路径**：A1、A6 为前台基础线索；目录参数、结果文档实体、认证/确认完整依赖 G1–G4 未齐。不依赖 WebView 才能写空白文件，但这不证明已有后台冷启动服务，仍建议前台新建并进入既有会话。四个入口分别适用共同表，Spotlight 不自动收录新文件。
- **schema 增强**：未选定 domain/member。不能把单文件编辑器强行包装成笔记账户体系；待 G5 核对必要结果实体及语义后再决定。无增强时保留普通路径，不升 iOS target。
- **价值/成本**：P3，M；任务明确，但自动重试写入与目录身份风险高于打开。估算含新增安全边界和结果状态，不只是包装一个函数。
- **下一步**：核验 API/SDK，再在获授权实施任务中测试同名不覆盖、重复运行、只读目录、空间不足、授权失效、创建成功但已有编辑会话等。未实际创建任何文档。

### P4 导出 Markdown / 附件包副本——把完整写作交给其他应用

- **业务状态：已实现。** `MobileEditorScreen.share(bundled:)` 先 `MobileDocument.saveNow`，再 detached 调用 `donemdIOS/DocumentShare.swift` 的 `DocumentShare.prepare`，最终 `ShareSheet` 呈现系统分享界面。`prepare` 生成临时快照；打包时解析正文、遍历引用附件、协调复制到 staging，再 ZIP。附件缺失报错；原文块含 `assets/` 的不透明引用会拒绝声称完整包。分享前保存可能触发规范化/冲突阻断，并非纯读操作。
- **结论：需验证，后置。** 提议必需文档与可选格式（Markdown/附件 ZIP），前台准备并由用户选择输出目标；“将文件结果返回给 Shortcuts”与“打开系统分享界面”是不同契约，须产品选一种最小路径。现有函数只返回临时 URL，不证明可直接作为系统 Intent 文件结果。
- **身份/重复**：文档按共同规则解析，歧义不自动选。重复运行创建不同临时快照/ZIP，不覆盖源，但可能残留临时目录；成功后的保留时限、接收方读取期间生命周期和清理策略是新增工作。纯 Markdown 不含附件，不能误报完整导出。
- **权限/安全**：正文、frontmatter、飞书身份与附件可能敏感，必须显式用户选择输出目标，不能静默发给联系人/云服务；代码只准备分享，不证明发送完成。设备认证/锁屏披露与共享文件权限仍待设计；保存确认不可跳过。失败准备会清理 workspace，但成功后的清理未见实现。
- **普通路径**：A1/A2/A6 是基础线索，文件输出/传输结果、长耗时与取消机制均未核验（G1/G2/G4）。先考虑前台 Shortcuts 准备导出；Siri/Spotlight 不主动宣读或暴露内容，曝光后置；不假设后台大包可运行。
- **schema 增强**：没有确定精确 domain/member 或证明匹配；文件导出不等于分享已完成。G5 独立核验，Apple Intelligence 无可用性承诺。
- **价值/成本**：P4，L；跨应用价值存在，但授权加载、保存确认、敏感输出、临时结果生命周期、附件体积与失败恢复明显多于 P1。没有使用数据支持优先于打开/查找。
- **下一步**：先选输出契约和核验文件结果符号；后续测试缺附件、原文块引用、首次规范化、并发更新、失败取消、大包及结果寿命。未生成导出文件，未展示或操作分享界面。

## API 与可用性证据

读取日期均为 **2026-10-29**。下表 A 行只将该符号本身的官方文档声明和 iOS/iPadOS availability 记为已读取；不代表其所有依赖、系统曝光或所选 SDK 均已验证。官方 DocC 是实时文档，非 Xcode 27.1 RC 固定快照；最低系统来自各页 `metadata.platforms`，声明来自各页 `primaryContentSections.declarations`。所有 A 行的“所需 SDK/toolchain”均只确认需包含该声明，**未确定最早 Xcode 版本，亦未读取所选 RC 的声明**。

| ID | 精确符号与已读声明 | 文档最低 iOS/iPadOS | 适用范围/限制 | 实际读取来源 | 所选 SDK 与下一步 |
| --- | --- | --- | --- | --- | --- |
| A1 | `AppIntent`，`protocol AppIntent : PersistentlyIdentifiable, _SupportsAppDependencies, Sendable` | 16.0 | 普通动作类型；不是 Siri 可运行证明 | https://developer.apple.com/tutorials/data/documentation/appintents/appintent.json | RC 未读；还需核验执行/结果等要求 |
| A2 | `AppEntity`，`protocol AppEntity : AppValue, DisplayRepresentable, Identifiable ...` | 16.0 | 用户数据实体协议；不等于项目已有稳定实体 ID | https://developer.apple.com/tutorials/data/documentation/appintents/appentity.json | RC 未读；关联要求、展示和查询声明未完整核验 |
| A3 | `EntityQuery`，`protocol EntityQuery : DynamicOptionsProvider, PersistentlyIdentifiable, Sendable` | 16.0 | 实体查询协议本身 | https://developer.apple.com/tutorials/data/documentation/appintents/entityquery.json | RC 未读；不能由协议名推导具体查询方法版本 |
| A4 | `AppShortcutsProvider`，`protocol AppShortcutsProvider : Sendable` | 16.0 | App Shortcut provider 协议本身 | https://developer.apple.com/tutorials/data/documentation/appintents/appshortcutsprovider.json | RC 未读；短语/provider 成员依赖仍缺 |
| A5 | `AppShortcut`，`struct AppShortcut` | 16.0 | App Shortcut 类型本身，不含已验证初始化器重载 | https://developer.apple.com/tutorials/data/documentation/appintents/appshortcut.json | RC 未读；不能据此宣布短语可编译/匹配 |
| A6 | `AppIntent.openAppWhenRun`，`static var openAppWhenRun: Bool { get }` | 16.0；26.0 deprecated，文档建议 `supportedModes` | 调查覆盖 iOS 17 的前台普通路径；仅属性声明已核验 | https://developer.apple.com/tutorials/data/documentation/appintents/appintent/openappwhenrun.json | RC 未读；弃用不等于已删除，仍须在所选 SDK 检查 |
| A7 | `AppIntent.supportedModes`，`static var supportedModes: IntentModes { get }` | 26.0 | 不能作为 iOS 17 无条件路径；这里只验证属性，不验证 `IntentModes` 及其各成员 | https://developer.apple.com/tutorials/data/documentation/appintents/appintent/supportedmodes.json | RC 未读；若选用须核验类型/成员及 runtime 分支、低系统回退 |

**阻断证据，不填造最低版本：**

| ID | 未验证符号/契约 | 最低 OS / SDK | 下一项具体核验 |
| --- | --- | --- | --- |
| G1 | `AppIntent.perform()`、`IntentResult` 及选定 `.result` 重载；参数包装器与所选初始化器；实际采用的认证/确认 API | 本轮未逐项确认 | 阅读每个精确符号自己的官方声明/availability，并对照 RC 中 AppIntents Swift 接口，不能从 A1 或指南示例外推 |
| G2 | `EntityStringQuery`、实际查询方法、实体 default query/display/ID 依赖；导出所需文件结果/传输 API（具体方案未选） | 未确认 | 先选最小参数和结果契约，再逐符号读取，验证重启/重命名后的 ID 解析与授权过滤 |
| G3 | 所选前台导航接线、`AppShortcut` 的具体初始化器、短语类型/application-name token；Spotlight 的索引/删除 API | 未确认 | 分开核验普通前台核心、App Shortcut 曝光与可选索引；不能把高版本指南的导航示例照搬到 iOS 17 |
| G4 | Xcode 27.1 RC 的 AppIntents 接口、宏和 metadata processor；有效 target settings | RC 精确 build / SDK 版本未确认 | 在该 Mac 只读取得 `xcodebuild -version`、`xcrun --sdk iphoneos --show-sdk-path`，读取相关 `.swiftinterface` 和工程生成后的 settings；后续获准实施才编译和验收 |
| G5 | 精确 schema domain/member、必要参数/结果、依赖实体、成组动作及 surface 资格 | **全部未确认** | 在 RC 只读检查 `AppIntentSchemas.sqlite`（immutable 模式）及对应官方符号文档；先确定文件业务语义匹配，再记录每个成员自己的 floor、SDK、gate/fallback；不从宏引入版本推断成员版本 |

参考已读 `/run/airbuild/skills/find-intent/SKILL.md` 与报告模板、`apple-integrations/SKILL.md` 与 `topics/app-intents-reference/GUIDE.md`、`apple-intelligence/SKILL.md` 与 iOS 27 guide 的 availability、schema、entity 和 Siri 相关章节。这些是实施/核验线索，不是本项目 API 证明。指南不同段落对高版本能力的表述不用于推定当前部署要求；本文不建议升最低系统。运行时 guard 也不能让缺少符号的 SDK 编译通过。

## 计划、证据不足与排除项

| 功能 / 用户任务 | 业务状态与真实证据 | 结论与排除理由 | 何时重评 |
| --- | --- | --- | --- |
| 重命名文档 | 已实现：`FolderView` 重命名 alert → `FolderStore.rename`；校验空名/路径字符/隐藏名，文件协调 move，不覆盖同名 | 不建议首批；写入改变文件定位，现有 URL 身份不能证明快捷指令仍稳定；确认 UI 不等于 Intent 确认 | 有稳定身份、共享目录范围及可恢复/重试契约后再评估；不能绕开现有校验 |
| 创建文档副本 | 已实现：列表 context menu → `FolderStore.duplicate`；协调 copy，名称带随机后缀 | 不建议首批；每次产生新文件，不幂等；只复制 Markdown，不复制附件目录，不可包装为完整独立附件包 | 明确副本与共享相邻 assets 的产品含义、重试/清理和身份策略后 |
| 离线下载文件夹 | 已实现：菜单 → `requestOfflineDownload`；递归请求系统下载，跳过符号链接；UI 明说只发请求 | 不建议首批；没有完成/进度保证，不可命名为“文件夹已可离线使用”；体量与后台时间未知 | 有系统完成状态与取消/限流方案及 API 证据后；仍不能许诺 iCloud 跨设备同步完成 |
| 保存、恢复版本、保留冲突再重载 | 已实现：`requestSave` / `MobileDocument.saveNow`、`restore`、`preserveConflictsAndReload` | 不建议作为首批自动化；备份/规范化/冲突/IME 输入和覆盖风险高，恢复需用户对内容负责 | 有明确文档/版本身份、预览、确认与恢复策略后独立任务 |
| 图片/视频导入和选区格式、段落删除/替换 | 已实现：`MobileEditorScreen` 选择器 → `importMedia` 先落盘再 `outgoing`；`MobileWebView` → `mobile.ts` 插入。`mobile-controls.ts` → `mobile-commands.ts` 的 `replaceMatches`/`changeBlock` 依赖 editor 选区 | 不建议首批；当前选区/富节点无跨启动稳定身份，不能外部无歧义定位；替换/删除有内容风险，媒体还需来源授权 | 有明确内容目标、安全写事务及持久定位后；不把任务列表 UI toggle 宣称成可按 ID 完成某任务 |
| 阅读/编辑切换、主题字号、折叠、源码显示 | 已实现：`mobile-reading.ts.attachReadingControls`；`reading = !reading` 是切换而非“设置为阅读”，源码 CodeMirror 明确 readonly | 不推荐；多为 UI 偏好/临时视图操作。可通过 P1 导向有价值文档，不为凑数拆 Intent | 有独立可度量任务价值再评估；不得开放源码双向写入 |
| 递归全文/语义检索、最近文档库、任意正文捕获/追加 | 现有链证据不足：实际文件名过滤非递归；`newDocument` 固定正文；无上述服务 | 不纳入当前业务已实现候选；全文索引/笔记库还超出当前 PRD | 产品另行决定范围并有真实业务服务后；不是加 Intent 即可获得 |
| iOS AI、飞书推拉、后台跨设备“立即同步” | 移动端未实现/明确不在首版：PRD/ADR；桌面文件存在不等于列入 iOS target | 不推荐；`project.yml` 不将 `donemd/AI`、`donemd/Feishu`、`SyncRoot` 编入移动端，iCloud 传输由系统负责 | 单独产品决策及移动业务实现/权限链完成后，不能由 schema 补齐业务 |
| iPad 双栏增强、跨目录移动/删除、自动合并 | PRD 分别为后续增强或明确范围外；当前没有相应移动业务动作 | 计划/范围外，不进候选首批 | 后续产品批准并落地，不从可见目录 UI 推断已具备 |

没有在所读移动实现中发现可据以申报新 Intent 的空 handler/TODO；这不证明整个产品所有故事均完成，更不代表真机验收完成。

## 产品交接

1. **当前首批 0 项**；已有 Intent 0 项。保留 P1 打开、P2 文件名查找、P3 空白新建、P4 导出为有真实代码基础的待验证机会，而非可立即实施承诺。
2. 优先补 Xcode 27.1 RC 精确 SDK 声明、普通路径完整依赖与前台会话方案；产品确认文件身份、根目录范围、锁屏披露及歧义处理后再选择实施任务。缺这些证据时，不能把普通路径改标“推荐”或将验证挪到上线后。
3. schema 是可选增强，先证明精确语义及依赖，再决定是否采用；普通任务不应因为 schema 未知就被否定，也不应因此提高 iOS 17 部署目标。若未来采用更高版本符号，要分别记录 SDK 编译要求、runtime gate 和低系统普通/应用内回退，不能宣称所有 iOS 17 用户均有增强入口。
4. 后续验证按“源码接线 → 编译/元数据 → 系统入口可见 → 模拟器实际执行 → 用户真机 Shortcuts/Spotlight/Siri”分别记证据；Apple Intelligence 另验证硬件、语言地区和开关。真实 iCloud/跨设备、中文输入、共享目录及冲突恢复必须真机，不能用编译或指南模拟器记录代替。
5. **本次只新增本报告，没有修改应用代码、配置、权限、部署目标；没有实施 Intent、运行测试/构建、创建/改名/导出业务文档、发起下载、分享或远端操作。** 实际集成必须在产品选择后另开任务。

## 主流程构建补证（2026-10-29）

本报告上文记录的是独立源码评估当时的证据边界；之后主流程已在 Xcode27.1RC（27A9275）、iOS27.1 SDK 成功构建应用（07e244c9），并在 Duo 与普通 iPhone 安装启动。最低版本17.0保留。最终57项网页、19项文档、5项UI测试通过（0cdcff6a）。这些结果只补证应用构建/运行，不补足上述候选 Intent 的完整 SDK/API、稳定文件身份或系统入口证据，首批0项的结论不变。后续图标/键盘布局变更没有新增业务、权限或 Intents，故本轮复用评估，不另造机会。既有 App Intents 仍为0项。

## 授权恢复与内容保护复核（2026-10-29）

本轮基线已推进至 `91ce6d9`，仍在 `codex/ios-document-editor`；授权恢复和混合列表已分别推送，另有恢复/冲突前最新输入保护的未提交变更。复用本报告的候选身份和结论，不新增 Intent：目录授权失败恢复完善了 P1 既有打开链，仍须用户选择真实父目录，单文件权限仍不代表相邻目录权限；没有扩大可读取的文件范围，没有新增 entitlement、账户、后台执行或部署目标变更。恢复/冲突操作仍须应用内用户操作，仍排除在自动化首批之外。列表修复只保留已有普通/任务条目语义，没有提供可持久查询的任务实体或“按 ID 完成任务”业务服务。

已重新检索 `donemdIOS` 和 `donemd` Swift 源码，未发现 AppIntent / AppShortcutsProvider / AppEntity 新声明，现有 App Intents 仍为 0 项，首批可实施建议仍为 0 项。此前 API/SDK 完整依赖、稳定身份、锁屏隐私和真实系统入口验证缺口不因文档恢复测试通过而消失。本补充不声称整轮构建或真机验收完成；各修复的最终测试记录另附本轮验证报告。
