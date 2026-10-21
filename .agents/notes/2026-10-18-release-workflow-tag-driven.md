---
status: active # active | superseded
superseded_by: ""
supersedes: ""
模块: ci # 真实模块名: core, core/logging, core/presentation, core/theme, features/terminal, features/hosts, features/snippets, features/sftp, features/local_shell, features/backup, features/app_lock, ci, build, deps
---

# Tag 触发的发版流程

## 一句话结论

`release.yml` 与 `release-apk.yml` 只在 `v*` tag push 时触发；由 `release.yml` 唯一创建 GitHub Release，两个 workflow 共用 `release-${{ github.ref }}` concurrency 组，补发用 `gh workflow run --ref <tag>` 对该 tag 重跑。

## 背景

旧描述把发版写成分支 push 或 `workflow_dispatch`，且允许 dispatch 输入 tag。`release-apk.yml` 的 dispatch 跑在分支 ref 上时，concurrency 组是 `release-refs/heads/...`，与 tag push 的 `release-refs/tags/vX.Y.Z` 不相交，两个 workflow 可以同时改同一个 Release。`release.yml` 的 preflight 默认检出与 release job 也没有钉同一 ref。

本笔记取代 `.agents/notes/fork-delta.md` 里对 `release.yml` / `release-apk.yml` 的旧分支 push 描述（含 workflow_dispatch、触发分支与打 tag 职责分工）。该文件当前有未提交的规则治理清理，本次不改它。

## 决策

- 触发：两个 workflow 只保留 `push.tags: ['v*']`。`release-apk.yml` 移除 `workflow_dispatch` 与 `inputs.tag_name`，preflight 统一从 `GITHUB_REF_NAME` 取 tag，并要求等于 `pubspec.yaml` 的 `v<versionName>`。
- 单一创建者：只有 `release.yml` 创建 GitHub Release；`release-apk.yml` 只在 Release 已存在时上传 arm64 APK，不创建 tag 或 Release。
- bump 强制：不接受 tag 覆盖。版本必须先写进 `pubspec.yaml` 的 `versionName+versionCode`，再推 `vX.Y.Z` tag。
- concurrency：两个 workflow 都是 `group: release-${{ github.ref }}`、`cancel-in-progress: false`。tag push 与对该 tag 的重跑落在同一组，后者排队而不取消。
- 检出：`release.yml` 的 release job 使用 `actions/checkout@v4` 的 `ref: ${{ github.ref }}`（仍保留 `fetch-depth: 0`）。tag push 下 preflight 与 release job 检出同一 tag；不可变 tag 下消除 force-move 窗口。
- 补发：不用手工输入 tag 的 dispatch。对已有 tag 重跑：`gh workflow run <workflow> --ref <tag>`。此时 `github.ref` 就是该 tag，concurrency 组与 tag push 对齐。

## 被放弃的方案（必填）

- **保留 `workflow_dispatch` 并把 concurrency 组改成输入 tag**：输入与 `github.ref` 仍可能不一致，错组并发依然存在；删除 dispatch 是唯一没有锁争议的方案。
- **继续用分支 push 触发发版**：分支 ref 与 tag ref 的 concurrency 组不相交，且检出的 commit 不一定是发版 tag。
- **直接改写 `fork-delta.md`**：该文件是未提交的规则治理清理，本次任务禁止触碰；用本笔记取代其过期发版描述。

## 来源

- oracle 第二轮复审：must fix（dispatch 与 tag push 的 concurrency 组不相交）、should fix（`release.yml` preflight 与 release job 检出不 pin 同一 SHA）、观察项（`fork-delta.md` 过期描述）。
- 工作区基线 HEAD：`85d66ad`（分支 `feat/alt-buffer-scroll-simulate`）。
