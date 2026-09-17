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
