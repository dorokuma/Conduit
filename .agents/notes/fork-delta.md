---
status: active
superseded_by: ""
supersedes: ""
模块: core # core | terminal | hosts | sftp | local_shell | snippets | app_lock | backup | build
---

# 与上游 (gwitko/Conduit) 的故意分歧登记

## 一句话结论
本仓库作为 fork 衍生版本，保留并维护与上游 `gwitko/Conduit` 的若干故意定制差异（终端核心库、herdr 集成、离线构建配置与主题等），严禁盲目向上游对齐覆盖。

## 背景
为满足特定定制需求、发布流程及离线构建环境支持，本仓在保留上游核心能力的同时引入了多项定制改造。

## 决策：已确认分歧清单

### 1. 终端核心依赖 (`conduit_vt`)
- **现状**：`master` 分支 `pubspec.yaml` 引用定制 git 仓库 `https://github.com/gwitko/conduit_vt.git` (commit `b486b894ea12b18b2ad76339ccd8c6ae3c12416f`)；`feat/alt-buffer-scroll-simulate` 分支指向 `https://github.com/dorokuma/conduit_vt.git`，并已将 `conduit_vt` git ref 对齐至 `63d870d8f70131ea1edddc0693524a65d0016885`。
- **决策**：保留该定制终端依赖，禁止替换回标准 xterm.dart 或未经确认的上游源。

### 2. 终端会话集成迁移至 `herdr`
- **现状**：将上游原有的 tmux 品牌、配置字段及按键栏逻辑改造迁移为 `herdr` 会话集成。
- **决策**：保留 `herdr` 集成相关实现，包括 UI 文本、按键栏动作、数据模型字段等。

### 3. Android 本地离线 Maven Seed 仓库
- **现状**：在 Android Gradle 构建配置中引入本地离线 maven 缓存路径。
- **决策**：保留离线构建兼容配置，避免线上 CI 与特定环境构建断流。

### 4. 终端外观与主题定制
- **现状**：定制了终端主题选择面板与外观预设（Catppuccin, Tokyo Night, Gruvbox 等及相关样式微调）。
- **决策**：保持定制主题配置；新增主题需与现有偏好设置仓库保持一致。

### 5. 仓外签名机制 (`conduit-signing`)
- **现状**：Android/iOS 发布签名凭证由仓外 `conduit-signing` 目录注入，不在仓内存储明文密钥。
- **决策**：严格保持签名资产隔离，严禁入库。

### 6. 发版同步与本地 Shell 二进制分发策略（已确认）
- **发版分支与同步策略（已确认）**：采用单向流——上游 `gwitko/Conduit` → `Conduit`（集成/实验仓，`origin` 即上游，严禁 push）→ 选择性 cherry-pick 到 `Conduit-feat` 的 `feat/alt-buffer-scroll-simulate`（唯一发版仓）；禁止反向整支 merge；同步触发条件为上游每次 release 后一次 + 本仓每轮定制收敛后一次；`Conduit` 不打发版 tag。
- **本地 shell（termux）二进制分发打包策略（已确认）**：termux 本地 shell 二进制的构建 pin 为 `termux-packages` commit `ac296452b8ebec390cad3bce9060577c96099b10`（来源 `tools/build-local-shell-binaries.sh:4` 的 `TERMUX_PACKAGES_COMMIT` 默认值，包校验和快照在 `third_party/source-offer/termux-package-checksums.md` 与 `third_party/source-offer/termux-recipes/`），每次 `Conduit-feat` release 前构建一次并把产物作为该 release 的 assets 发布，在本笔记登记该 `termux-packages` pinned commit；`pubspec.yaml` 所引用的 `conduit_vt` commit `63d870d8f70131ea1edddc0693524a65d0016885` 只是 Dart 终端库依赖 pin（见第 1 节），与 termux 构建无关联，两者须分别登记、不得混写。

## 被放弃的方案（必填）
- **直接 rebase/merge 上游 master 覆盖定制**：放弃，会破坏 `herdr` 终端集成、主题预设及离线构建能力。
- **将签名材料随源码保存在 repo 内部**：放弃，存在严重密钥泄露安全风险。

### 发版与同步被否决方案
- **反向整支 merge**：放弃从 `Conduit-feat` 向 `Conduit`（或跨仓双向）整支合并，避免发版仓专属提交污染集成/实验仓并破坏单向同步流。
- **每仓各自打 tag**：放弃在 `Conduit` 与 `Conduit-feat` 各自打发版 tag，防止版本权威源分裂与产物追溯混乱；仅在唯一发版仓 `Conduit-feat` 打发版 tag。
- **将 termux 本地 shell 构建 pin 与 `pubspec.yaml` 的 `conduit_vt` commit 混写**：放弃，`termux-packages` 构建 pin（`ac296452b8ebec390cad3bce9060577c96099b10`，见 `tools/build-local-shell-binaries.sh:4` 及 `third_party/source-offer/`）与 Dart 终端库依赖 `conduit_vt` pin（`63d870d8f70131ea1edddc0693524a65d0016885`）无关联，须分别登记、不得混写。

## 来源
- Git commit 历史：`7f3037b` (feat: migrate tmux to herdr), `c9da878` (build: offline maven seed)
- 仓库配置文件与构建快照：`pubspec.yaml`, `android/build.gradle.kts`, `README.md`, `tools/build-local-shell-binaries.sh`, `third_party/source-offer/termux-package-checksums.md`, `third_party/source-offer/termux-recipes/`

## 审查观察项（非契约破坏，供后续参考）
- **README 上游链接与本分支 fork 依赖源差异**：`README.md` 顶部徽章及正文中 `[conduit_vt](https://github.com/gwitko/conduit_vt)`、仓库链接仍指向 `gwitko` 上游仓库；而本分支（`feat/alt-buffer-scroll-simulate`）`pubspec.yaml` 实际构建依赖源指向 fork 仓 `https://github.com/dorokuma/conduit_vt.git`（commit `63d870d8f70131ea1edddc0693524a65d0016885`）。保持 `README.md` 原文不改，以减少后续同步上游文档时的合并冲突。
- **笔记脚本与模板跨分支补齐**：`Conduit` 仓 `feat/alt-buffer-scroll-simulate` 分支分叉早于 `master` 引入笔记体系的提交，已从 `master` 检出补齐 `scripts/notes-index.sh`、`.agents/notes/README.md` 与 `.agents/notes/_template.md`。
