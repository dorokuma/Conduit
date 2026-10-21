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
  - `.github/workflows/release.yml`：在 `v*` Tag 推送时统一完成 Flutter Release APK（含 Android arm64 独立产物）打包，并利用 GitHub CLI 将 APK 上传到对应的 GitHub Release（原 `.github/workflows/release-apk.yml` 已于 `7c0e648` 删除，Release 构建与发布已全部收敛至 `release.yml`）。
  - `.github/workflows/ci-test.yml`：在 `feat/alt-buffer-scroll-simulate` 等分支推送及 PR 时执行 `flutter analyze`、`flutter test` 及 debug APK 打包验证。
- **与上游区别**：上游主要走完整的多架构构建及应用商店分发流程，本仓侧重独立构建 arm64-v8a 快速迭代包。

### 3. 仓外签名材料与敏感配置隔离
- **规范**：签名材料统一保存在仓外专用位置（`conduit-signing`），在 CI 中通过 GitHub Secrets（`ANDROID_KEYSTORE_BASE64`、`ANDROID_KEY_ALIAS`、`ANDROID_KEY_PASSWORD`、`ANDROID_STORE_PASSWORD`）注入解码生成临时 `android/app/upload-keystore.jks` 与 `android/key.properties`。
- **铁律**：严禁将任何 `.jks` 证书或 `key.properties` 签名配置提交入库（已在 `.gitignore` 配置）。

### 4. 版本系列与分支策略
- **当前版本**：`1.4.45+70`（`pubspec.yaml` 遵从 `versionName+versionCode` 规范）。
- **主工作分支**：`feat/alt-buffer-scroll-simulate`。
- **发版 Tag 规则（已确认）**：以 `vX.Y.Z` 命名，其中 `X.Y` 跟随所同步的上游版本系列，`Z` 由本地发版独立递增、不复用不回填，`versionCode` 单调递增（现 `1.4.45+70`，下一版 `1.4.45+71`），tag 只打在 `Conduit-feat` 发版分支（`feat/alt-buffer-scroll-simulate`）且不依赖上游 tag 是否存在。

#### CI 发版工作流收敛（纯 `v*` Tag 驱动，详见 [2026-10-18-release-workflow-tag-driven.md](2026-10-18-release-workflow-tag-driven.md)）
- **现有工作流清单与修订说明（2026-10-21）**：当前 `.github/workflows/` 仅保留 `release.yml`、`ci-test.yml`、`website.yml` 三个工作流文件；2026-10-21 合并提交 `e8477f6` 合入 `7c0e648`（`ci(release): publish portable arm64 APK from release job`），`release-apk.yml` 已于 `7c0e648` 删除，全部 Release 构建与发布收敛至单一的 `.github/workflows/release.yml`。
- **触发与版本校验**：`.github/workflows/release.yml` 仅在 `push.tags: ['v*']` 时触发；`preflight` job 从 `GITHUB_REF_NAME` 读取 tag，强制校验 `pubspec.yaml` 的 `versionName+versionCode` 格式且 tag 必须等于 `v<versionName>`（不接受 tag 覆盖），并在构建前检查目标 Release 及同名 APK 资产状态（Release 不存在时提示将由本工作流创建，已存在时提示将在构建成功后以 `--clobber` 覆盖替换）。
- **产物与上传**：由 `release.yml` 的 `release` job（`Test and release`）在统一完成 `jniLibs` 原生二进制编译与 `flutter build apk --release --flavor full --split-per-abi` 后，收集 `armeabi-v7a`、`arm64-v8a`、`x86_64` 三架构 APK（`app-<abi>-release.apk` 或 `app-<abi>-full-release.apk`），并从含 `jniLibs` 的 full-flavor arm64 产物直接复制生成 portable arm64 产物 `conduit-<version>-arm64-release.apk`；最终通过 `gh release upload "${TAG}" "${files[@]}" --clobber -R "${target_repo}"` 一并上传，`--clobber` 确保同名产物存在时覆盖替换。
- **单一创建者与并发锁**：仅由 `release.yml` 的 `release` job（显式检出 `ref: ${{ github.ref }}`、`fetch-depth: 0`）唯一创建 GitHub Release（当目标 Release 不存在时执行 `gh release create`，`--target` 绑定 `github.sha` 即 tag 指向的 commit）；工作流级并发锁配置为 `group: release-${{ github.ref }}`（`cancel-in-progress: false`）。
- **发版与补发流程**：发版须先在 `pubspec.yaml` 递增 `versionName+versionCode` 并提交，再在发版分支（`feat/alt-buffer-scroll-simulate`）打 `vX.Y.Z` tag 推送触发；如需补发，使用 `gh run rerun <run-id>`（对既有该 tag 的 run 重跑，保持同 ref 同并发组；详见 [2026-10-18-release-workflow-tag-driven.md](2026-10-18-release-workflow-tag-driven.md)）。

## 被放弃的方案（必填）

- **直接使用上游 `conduit_vt` 依赖**：无法及时验证和合入终端交互定制补丁，放弃。
- **将签名密钥文件提交到私有分支**：存在泄漏风险和维护成本，放弃；必须使用仓外 `conduit-signing` 配合 CI secrets。
- **全平台多架构一揽子重构 CI**：当前重点在 Android 平台验证与自用分发，避免过度引入未使用的平台构建开销。
- **复用/回填补丁号 `Z` 或依赖上游同名 Tag 才打标**：放弃，会阻碍本地定制版本独立迭代并造成版本号与构建产物映射混乱。

## 来源

- `pubspec.yaml`（`conduit_vt` git 引用）
- `.github/workflows/release.yml` 与 `.github/workflows/ci-test.yml`
- Git 远程配置：`origin`（`dorokuma/Conduit`）与 `upstream`（`gwitko/Conduit`）
- `README.md`（上游链接保留现状）
