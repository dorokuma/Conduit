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
## Release Policy / 发布规范

本节是本仓库发版的强制规则。仓库已有的更具体版本、构建或发布渠道规则优先，但不得降低以下底线。

1. **版本与变更记录**：遵循 Semantic Versioning，正式版本使用 `vX.Y.Z`。破坏性变更升 MAJOR，新功能升 MINOR，兼容修复升 PATCH。任何用户可见行为、运行时/API/包接口、依赖、安全性或分发产物变化，都必须在同一发版提交中更新版本元数据并写入 CHANGELOG/Release Notes；纯文档且不产生可分发产物时可免升版，但须在规则或 Release Notes 中明确说明。
2. **发布门禁**：发版前工作树必须干净，版本号、CHANGELOG 与发布说明必须一致；必须运行仓库规定的测试、构建、lint、类型检查及必要的安全检查，且全部通过。若仓库提供 `release-check`、`make release-check`、版本检查脚本或同等门禁，必须原样通过，不得绕过。
3. **发布顺序**：先提交并推送发布提交到目标分支 → 在该发布提交上创建 Tag（默认使用带注解的 `git tag -a vX.Y.Z -m "vX.Y.Z"`；仅当现有发布工具明确要求轻量 Tag 时可例外）→ 推送 Tag → 创建**非草稿** GitHub Release → 再发布 npm、PyPI、容器镜像等关联分发渠道。不得只推分支或只打 Tag 就宣称发版完成。
4. **GitHub Release 产物**：标题使用 `vX.Y.Z`，正文必须包含实质性变更摘要、升级/破坏性变更说明及验证结果；二进制、安装包、插件包等适用产物必须作为 Release assets 上传，并提供校验和（如适用）。**Tag 本身不等于完整发版，必须同时存在可访问的 GitHub Release。**
5. **发布后验收**：至少执行并确认 `git ls-remote --tags origin refs/tags/vX.Y.Z`、Tag 指向发布提交、`gh release view vX.Y.Z` 可访问且不是 draft；若发布到包仓库/镜像仓库，还必须核验对应版本、摘要或安装链接可用。
6. **不可变性**：已发布 Tag 不得复用、移动或删除，不得 force push 发布分支或 Tag，不得从未提交、未经测试或未通过门禁的树发布。发布后发现问题须通过新的 patch 版本修复，禁止覆盖历史 Release。
7. **例外必须显式化**：归档、已停用、被替代、仅文档或无可分发产物的仓库，必须在项目规则中明确写出“不发新版本”及历史 Tag/Release 的处置方式；例外不能用于绕过上述发布闭环。

### Repository-specific release contract

- 本仓的具体检查命令以 README、CONTRIBUTING、AGENTS 既有条款及 CI 配置为准。
- **本仓发版边界**：本仓是上游集成缓冲仓；正式产品版本与 Release 由 `Conduit-feat` 负责。除非用户明确批准，不在本仓创建新的产品发布 Tag 或 Release。
