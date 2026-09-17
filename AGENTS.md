# Agent Guidelines

## 铁律
1. **构建与检查**：静态检查 `flutter analyze`；测试 `flutter test`；依 CI 构建 APK `flutter build apk --debug --flavor full`；版本 bump 遵从 `pubspec.yaml` `versionName+versionCode`（tag: `vX.Y.Z`）。
2. **提交规范**：提交规范——commit message 须过全局 commit-msg hook：Conventional Commits 类型白名单、≤72 字、冒号后一空格、禁噪声词与密钥。
3. **决策留痕**：决策/踩坑须记 .agents/notes/，且满足触发条件任一即写。
4. **Fork 与签名隔离**：与上游故意分歧见 [.agents/notes/fork-delta.md](.agents/notes/fork-delta.md)；`conduit-signing` 签名材料存仓外严禁入库。

## 索引与文档
- **现状文档**：[README.md](README.md) 与 [README.zh.md](README.zh.md)
- **决策笔记**：[.agents/notes/README.md](.agents/notes/README.md)（写完笔记刷新索引：scripts/notes-index.sh（本地生成 INDEX.md，不入 git））

## 关联仓库
- **Conduit**（开发仓，origin: `dorokuma/Conduit`，upstream: `gwitko/Conduit`）
- **conduit_vt**（经 git 依赖的终端核心库：`https://github.com/dorokuma/conduit_vt`）
- **conduit-signing**（仓外签名材料，严禁入库）
