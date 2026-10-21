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

## 决策：已确认与待确认分歧清单

### 1. 终端核心依赖 (`conduit_vt`)
- **现状**：`pubspec.yaml` 引用定制 git 仓库 `https://github.com/gwitko/conduit_vt.git` (commit `b486b894ea12b18b2ad76339ccd8c6ae3c12416f`)。
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

### 6. 其他待确认分歧项
- **发版分支与同步策略**：*待维护者确认*（与 `Conduit-feat` 发版仓库的同步周期与 Cherry-pick 规则）。
- **本地 shell 二进制分发打包**：*待维护者确认*（termux-packages 构建产物更新策略）。

## 被放弃的方案（必填）
- **直接 rebase/merge 上游 master 覆盖定制**：放弃，会破坏 `herdr` 终端集成、主题预设及离线构建能力。
- **将签名材料随源码保存在 repo 内部**：放弃，存在严重密钥泄露安全风险。

## 来源
- Git commit 历史：`7f3037b` (feat: migrate tmux to herdr), `c9da878` (build: offline maven seed)
- 仓库配置文件：`pubspec.yaml`, `android/build.gradle.kts`
模块: build # 真实模块名: build, ci, deps, features/terminal
---

# 相对上游 Conduit 的故意分歧清单

## 一句话结论

本仓（`dorokuma/Conduit`）作为上游 `gwitko/Conduit` 的功能演进与自定义发版分支仓，维护了一套独立的核心终端依赖、自动化 APK 构建发布流和分支演进线。

## 背景

上游项目 `gwitko/Conduit` 是一个纯净的移动终端工具。为了验证并引入特定终端特性（如 Alt-Buffer 滚动模拟优化等）、支持自建 CI 自动编译分发 Android arm64 Release APK，本仓在保留上游核心能力的同时建立了受控的分歧点。

## 决策

### 1. 自定义 `conduit_vt` 依赖注入
- **实现方式**：在 `pubspec.yaml` 中将终端模拟核心库 `conduit_vt` 覆盖为 Git 依赖，指向 `https://github.com/dorokuma/conduit_vt.git`（`feat/alt-buffer-scroll-simulate` 分支已将 `conduit_vt` git ref 对齐至 commit `63d870d8f70131ea1edddc0693524a65d0016885`）。
- **目的**：承载自定义终端功能演进与特定滚动模拟交互。

### 2. APK 自动化构建与发布链
- **工作流增加**：
  - `.github/workflows/release-apk.yml`：在分支推送或手动触发时，针对 Android arm64 自动完成 Flutter Release APK 打包，并利用 GitHub CLI 将 APK 上传到对应的 GitHub Release。
  - `.github/workflows/ci-test.yml`：在 `feat/alt-buffer-scroll-simulate` 等分支推送及 PR 时执行 `flutter analyze`、`flutter test` 及 debug APK 打包验证。
- **与上游区别**：上游主要走完整的多架构构建及应用商店分发流程，本仓侧重独立构建 arm64-v8a 快速迭代包。

### 3. 仓外签名材料与敏感配置隔离
- **规范**：签名材料统一保存在仓外专用位置（`conduit-signing`），在 CI 中通过 GitHub Secrets（`ANDROID_KEYSTORE_BASE64`、`ANDROID_KEY_ALIAS`、`ANDROID_KEY_PASSWORD`、`ANDROID_STORE_PASSWORD`）注入解码生成临时 `android/app/upload-keystore.jks` 与 `android/key.properties`。
- **铁律**：严禁将任何 `.jks` 证书或 `key.properties` 签名配置提交入库（已在 `.gitignore` 配置）。

### 4. 版本系列与分支策略
- **当前版本**：`1.4.45+70`（`pubspec.yaml` 遵从 `versionName+versionCode` 规范）。
- **主工作分支**：`feat/alt-buffer-scroll-simulate`。
- **发版 Tag 规则（已确认）**：以 `vX.Y.Z` 命名，其中 `X.Y` 跟随所同步的上游版本系列，`Z` 由本地发版独立递增、不复用不回填，`versionCode` 单调递增（现 `1.4.45+70`，下一版 `1.4.45+71`），tag 只打在 `Conduit-feat` 发版分支（`feat/alt-buffer-scroll-simulate`）且不依赖上游 tag 是否存在。

#### CI 现状差距（已在 fix/release-ci-version-source 修复）
- `.github/workflows/release-apk.yml`：已移除硬编码版本 `v1.4.45` 与旧 tag 检出，动态从 `pubspec.yaml` 解析 `versionName` 与 `versionCode`（亦支持 `workflow_dispatch` 参数覆盖）；移除 `--clobber`，并新增产物存在性前置与上传校验，若同名 Release 已存在产物则直接报错退出（不覆盖）；Release 创建显式绑定 `--target "${GITHUB_SHA}"`，确保发版 tag 准确落在发版分支（`feat/alt-buffer-scroll-simulate`）。
- `.github/workflows/release.yml`：触发分支已从 `master` 对齐至发版分支 `feat/alt-buffer-scroll-simulate`，并支持 `workflow_dispatch` 参数化输入；新增前置产物存在性校验以防覆盖；发版打 tag 职责收敛由 `release-apk.yml` 单一负责，`release.yml` 仅复用该 tag 挂载全架构 APK 产物。
- **处置结论**：已知 CI 差距已修复并收敛发版职责，下次发版仅需在 `pubspec.yaml` 递增版本号并推送至发版分支即可安全自动发布。

## 被放弃的方案（必填）

- **直接使用上游 `conduit_vt` 依赖**：无法及时验证和合入终端交互定制补丁，放弃。
- **将签名密钥文件提交到私有分支**：存在泄漏风险和维护成本，放弃；必须使用仓外 `conduit-signing` 配合 CI secrets。
- **全平台多架构一揽子重构 CI**：当前重点在 Android 平台验证与自用分发，避免过度引入未使用的平台构建开销。
- **复用/回填补丁号 `Z` 或依赖上游同名 Tag 才打标**：放弃，会阻碍本地定制版本独立迭代并造成版本号与构建产物映射混乱。

## 来源

- `pubspec.yaml`（`conduit_vt` git 引用）
- `.github/workflows/release-apk.yml`、`.github/workflows/release.yml` 与 `.github/workflows/ci-test.yml`
- Git 远程配置：`origin`（`dorokuma/Conduit`）与 `upstream`（`gwitko/Conduit`）
- `README.md`（上游链接保留现状）
