---
status: active
superseded_by: ""
supersedes: ""
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

#### CI 现状差距（登记，未在本轮修改）
- `.github/workflows/release-apk.yml:21/74/81/88` 硬编码 `v1.4.45` 且 `gh release upload` 使用 `--clobber`，推 `feat/alt-buffer-scroll-simulate` 分支即触发，不读 `pubspec` 版本——下一次 `1.4.45+71` 发版若不改工作流，新 APK 会覆盖 `v1.4.45` 旧 Release。
- `.github/workflows/release.yml` 只在 `master` push / `workflow_dispatch` 打 `v${versionName}` tag，与「tag 只打在发版分支」的既定规则不一致。
- **处置结论**：这两处 CI 差距为已知登记项，下次发版前须先改工作流（如改为读 `pubspec` 或参数化 tag），本轮仅登记不改码。

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

## 审查观察项（非契约破坏，供后续参考）

- 与 `Conduit` 仓重复的审查观察项（README 上游链接与本分支 fork 依赖源差异、双工作树笔记索引脚本对齐）已移除，统一参见 `/root/workspace/Conduit/.agents/notes/fork-delta.md`。
