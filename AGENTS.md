# Agent 协作指南

## 铁律
1. 构建与检查：依赖 `flutter pub get`；静态分析 `flutter analyze`；测试 `flutter test`；构建 `flutter build apk --release --flavor full --split-per-abi`。
2. 提交规范——commit message 须过全局 commit-msg hook：Conventional Commits 类型白名单、≤72 字、冒号后一空格、禁噪声词与密钥。
3. 决策/踩坑须记 .agents/notes/。
4. 签名安全：签名材料在仓外 `conduit-signing` 目录、严禁入库。
5. 分歧维护：勿向上游对齐自定义改造（conduit_vt、herdr、主题等，详见 [.agents/notes/fork-delta.md](.agents/notes/fork-delta.md)）。

## 索引与文档
- 现状文档：[README.md](README.md) | [中文说明](README.zh.md)
- 决策记录：[.agents/notes/README.md](.agents/notes/README.md)（写完笔记刷新索引：scripts/notes-index.sh，本地生成 INDEX.md，不入 git）

## 关联仓库
- 上游主仓：`gwitko/Conduit`（`origin` 即上游；`dorokuma` 为 fork remote）
- 发版仓库：`Conduit-feat`（发版 fork）
- 终端核心：`conduit_vt`（自定义终端核心库）
- 仓外签名：`conduit-signing`（仓外签名材料，勿入库）
