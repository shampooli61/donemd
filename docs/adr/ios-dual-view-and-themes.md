# iOS 双视图与显示主题

2026-10-30。本决策补齐移动端与 Mac 已有核心的差距，替代旧的“源码仅临时 sheet”“原生外壳固定跟随系统”两项。实施验收记录另见 ios-dual-view-validation.md；本文不是运行通过证明。

## 范围与布局

同一 MobileDocument 提供正文编辑器与 Markdown 源只读镜像。保留 Markdown 标记、既有语义着色、标题折叠和复制，不开放源码输入，不新增连续滚动同步或跨栏选区映射。

以实际可用空间而非设备型号、方向判断：宽度至少 760pt、扣除实际栏标题后的内容高度至少 300pt（随当前字体测量标题，不以固定 36pt 代替），且非辅助功能大字号时可左右对照，默认正文 58%、源码 42%。正文至少 400pt，源码至少 300pt、最多 520pt。窄屏为整页正文或整页只读源码，一级原生视图入口直接切换；宽屏原生菜单支持正文、源码、左右对照。会话偏好按文档保留；新文档宽屏默认对照、窄屏默认正文。

正文与源码各持有长期存续的 WKWebView，调整 frame/可见性而不通过条件分支销毁它们。切视图先保护逻辑选区并结束键盘显示，不强制保存、不重新打开文档；输入法组合期间不丢弃输入；几何自动展开或收窄也不能绕过此保护，不能在仍有正文焦点或组词时恢复旧的宽/窄屏源码偏好并隐藏正文。正文与源码独立滚动，共享标题跳转和折叠。

正文沿用现有18/28pt边距与720pt阅读上限；源码保留20pt右距与既有折叠区，标签保留20pt。此差异经设计复核接受，不移除折叠gutter。

## 镜像与一致性

镜像复用原 MarkdownEngine 序列化和 CodeMirror 展示，不宣称是磁盘逐字原文。仅消费已接受且身份/版本有效的正文事务；不为每次键入往正文命令队列加入 flush。组合输入中的未完成内容不发布到源码。

源码配置与内容更新采用独立序号和 ACK；以文档 identity/revision 拒绝迟到消息。小更新以最小替换保留 CodeMirror 滚动与复制选区；源码自己的选择不反写正文。镜像失败保持正文可用，若显示旧内容必须标注“显示上次内容”，提供独立重试，不清空文件。

## 主题

选项继续使用原有“跟随系统 / 纸质 / 赛博夜色”。一个本机应用偏好是权威状态，迁移旧 mobile-theme 值；阅读设置与主题入口复用它，不承诺 Mac/iPhone 云同步。主题覆盖正文、源码、原生背景/文字/强调色和弹层；系统工具栏保留原生材质。纸质强制浅色，赛博夜色强制深色，跟随系统恢复系统。共享 visual.css / markdown-source.css 为主题语义色来源；移动端提高小号弱化标记及正文引用/caption的对比度，纸质正文在移动作用域使用 `--md-muted: #7A6D58`（对 `#F8F4EE` 至少4.5:1），不改Mac主题。

主题事务等待正文 reader.set 与源码配置 ACK，再发布与持久化。任一侧失败回滚到上个一致主题并显示可重试错误，不能半边新半边旧。system 删除 data-theme 属性而不是写空属性；对已渲染 Mermaid 执行现有换色重绘。显示变更不能修改文件字节、dirty flag、undo 或触发强制保存。

## 保护与验收

保持首次规范化同意、原文块、相邻资源、冲突/恢复/保存、身份/版本/快照保护。新增单元与界面回归覆盖布局边界、身份/版本隔离、只读镜像更新、主题系统深色与回滚、不改文档。真实折叠与输入法/辅助功能检查结果须分开记录；暂停的旧真机验收不因本决策自动通过，普通动画 UI 超时不以关闭动画的结果替代。

### Explicit source switching and completed blur ACK

`keyboard.dismiss` success now means actual DOM/editor blur, not merely that Tiptap scheduled its blur rAF. The deferred side effect and post-await continuation both validate document generation, identity, revision and composition. A suspended/ineffective blur fails after500ms, cancels its pending frame and releases FIFO; native active-body/IME gating remains unchanged. Layout, colors and toolbar arrangement are unchanged. This fixes the proven early-ACK path, not a claim that every fold/foreground lifecycle anomaly has a proven root cause.

## 2026-11-03 目录主题边界纠正

用户真机反馈245显示纸质编辑页返回系统黑底蓝字目录，不能视为符合主题范围。主题现覆盖应用自有根目录/子目录、搜索/空态、原生导航/菜单与重命名提示；目录不铺正文纹理、不改变布局或增加主题入口。目录只观察已提交的 MobileThemeStore，不参与正文/源码 ACK 事务、不形成第二份偏好；稳定的导航根复用 MobileWritingSurface，避免子目录 push/pop 竞争外观所有权。系统文件选择、分享和权限界面保留系统控件，只继承平台支持的外观，不重绘 Files 应用。

目录页面/行面分别为纸质 F8F4EE/EEE7DD、夜色171C26/202733，跟随系统为 systemGroupedBackground/secondarySystemGroupedBackground；文件按钮使用现有主题强调色，文件夹名保持主文字并强调图标。纸质次文字7A6D58在分组行面仅4.12:1，按设计降级为主文字色，不沿用正文纸底的对比结论。导航栏保留原生材质。主题事务、文档保存/权限/身份/版本/组合输入协议不变。

原生重命名 alert 在仅设置承载控制器外观时仍可能采用系统键盘/标题配色。曾尝试向 SwiftUI 发布具体 preferredColorScheme，但真实 WindowGroup 下 Night→System 会反馈锁定深色（托管窗口单元测试不能覆盖此现象），因此此方案撤回，不作为交付实现。重命名外观必须局限于自身原生弹窗，不更改窗口或主题权威。
