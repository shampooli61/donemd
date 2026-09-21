# Done.md — 本地构建

## 正式签名与自动更新

已在 Xcode 登录付费开发者团队、并安装 Developer ID Application 证书时，
可直接复用 Xcode 账号提交 Apple 公证，无需另外提供 App 专用密码：

```bash
security find-identity -v -p codesigning
export DEVELOPMENT_TEAM="你的 Team ID"
export DEVELOPER_ID_APP="Developer ID Application 证书的 SHA-1"
bash scripts/build-release-xcode.sh
# 若 Apple 仍在处理，稍后继续，不重复构建或上传：
bash scripts/build-release-xcode.sh --resume
```

每次发布先递增 `project.yml` 的 `CURRENT_PROJECT_VERSION`；已有正式版本也需
递增 `MARKETING_VERSION`。保留原有 `SUPublicEDKey` 和 `SUFeedURL`。
脚本校验公证票据、Gatekeeper 和 Sparkle 公钥，再生成 ZIP、DMG、校验和与更新清单。
`dist/` 保留本次归档，`--resume` 会核对归档版本，避免把旧包误标为新版本。

上传 ZIP、DMG、校验和到对应的 `v<版本>` GitHub Release；将
`dist/releases/appcast.xml` 部署到 `https://shampooli61.github.io/donemd/appcast.xml`。
更新清单上线前必须确认其中的 ZIP 下载链接有效。证书私钥、Apple 凭据和
Sparkle 私钥始终保留在本机钥匙串，不提交到仓库。

原 `scripts/build-release.sh --release` 使用 `notarytool` 钥匙串凭据的路径仍可使用。

## 前提条件

- macOS 13+（Ventura 或更新）
- Xcode 14+（从 Mac App Store 下载）
- **Node.js 18+** + npm（Web bundle 构建用，从 [nodejs.org](https://nodejs.org/) 或 `brew install node`）
- Homebrew + xcodegen（仅在改 `project.yml` 时需要）：
  ```bash
  brew install xcodegen
  ```

## 第一次拉到本机

```bash
cd ~/donemd
cd web && npm install && cd ..    # 装 web 依赖（Tiptap、Vite、TypeScript 等）
xcodegen generate                 # 从 project.yml 生成 .xcodeproj
open donemd.xcodeproj
```

Xcode 里 Cmd+R 即可 build & run。首次运行需要在 *Signing & Capabilities* 里选 Team（"Personal Team" 也 OK，Apple ID 即可，免费）。

> 国内网络如果 npm 装不动：`npm install --registry=https://registry.npmmirror.com`

## 修改工程结构

工程结构由 `project.yml` 描述，**不**直接改 `donemd.xcodeproj`——它是衍生产物，已加进 `.gitignore`。流程：

```bash
# 1. 编辑 project.yml（加文件、加 framework、改 build settings 等）
# 2. 重新生成 .xcodeproj
xcodegen generate
# 3. Xcode 里会自动重载工程
```

如果忘了走这条路、直接在 Xcode UI 里改了工程设置，下次 `xcodegen generate` 会覆盖你的改动——记得把改动反向写回 `project.yml`。

## 发布验收

`bash scripts/check.sh` 必须通过 TypeScript 类型检查、前端行为测试和 Swift 测试。正式归档脚本会先执行这一检查；公证续跑不重复测试。另需按 `docs/quality-1.1.0.md` 核对原生界面操作，不能以静态检查替代真机验收。

## 命令行 build & test

```bash
# 仅编译
xcodebuild -project donemd.xcodeproj -scheme donemd -configuration Debug build

# 跑单元测试
xcodebuild -project donemd.xcodeproj -scheme donemd test
```

## 工程结构

```
~/donemd/
├─ project.yml             # 工程结构真相源（git 跟踪）
├─ donemd.xcodeproj/       # 生成的 Xcode 工程（.gitignore，不进 git）
├─ donemd/                 # App 主 target
│  ├─ donemdApp.swift      # @main 入口
│  ├─ ContentView.swift    # 根视图
│  ├─ VisualWebView.swift  # WKWebView 包装，加载 visual.html
│  └─ Assets.xcassets/     # 资源目录
├─ donemdTests/            # 单元测试 target
│  └─ DonemdTests.swift
├─ web/                    # JS 源码（Vite + TS + Tiptap）
│  ├─ visual.html          # Vite 多页入口（Phase 1 唯一）
│  ├─ src/main.ts          # Tiptap 编辑器初始化
│  ├─ src/visual.css       # 编辑器样式
│  └─ vite.config.ts       # 输出到 ../Resources/Web/
├─ Resources/Web/          # Vite 构建产物（.gitignore，由 pre-build 脚本生成）
└─ BUILD.md                # 本文件
```

## Web bundle 构建流程

`project.yml` 配的 `preBuildScripts` 会让 Xcode 每次 build 前自动跑 `cd web && npm run build`：

- 首次 build：自动跑 `npm install`（如果 `node_modules` 不存在）
- Vite 用内容 hash 做增量缓存，没改时 ~50–100ms 退出
- 输出：`Resources/Web/visual.html`（CSS + JS 全 inline 的单文件，~290 KB）
- 这个文件以 folder reference 方式被打进 `.app/Contents/Resources/Web/`
