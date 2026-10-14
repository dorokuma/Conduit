---
status: active
superseded_by: ""
supersedes: ""
模块: core # core | terminal | hosts | sftp | local_shell | snippets | app_lock | backup | build
---

# 核心模块审计观察项与边界决策登记

## 一句话结论
记录本次核心模块审计确认的 10 项设计边界与架构权衡（SFTP 上传直接 truncate、主机密钥 TOFU 单条记录模型、无锁屏设备显式跳过认证、SSH keyboard-interactive 单隐藏提示应答、远端 git 固定版本的 `conduit_vt` 手势与粘贴行为、全屏重连按钮状态可见性与直接 `connect()` 行为、`HttpRootfsDownloader` 单次实例使用契约、`HostsController._serializeWrite` 不可重入约束、`TerminalSessionController._closeSessionSafely` 吞异常权衡、以及 `TerminalKeyboardBar` 重复按键配置切换行为），明确暂不改动主仓行为的原因与后续演进边界。

## 背景
在 `fix/core-bugs-and-leaks` 分支修复 8 项核心缺陷与资源泄漏的同时，结合提交前双审（reviewer + oracle）对跨模块边界行为进行了系统性复核。以下 10 项属于有意的兼容性权衡、特定场景交互取舍、已显式文档化的契约约束或受限于外部锁定依赖仓库（`conduit_vt`）的观察项，不应在本次最小修复中盲目扩展改动。

## 决策

### 1. SFTP 上传直接 `truncate` 与 POSIX rename 兼容性权衡
- **现状**：`DartSshSftpSession.write`（`lib/features/sftp/data/dart_ssh_sftp_repository.dart`）使用 `SftpFileOpenMode.create | SftpFileOpenMode.write | SftpFileOpenMode.truncate` 直接打开目标路径写入，若中途断流会留下截断文件。
- **决策**：维持直接覆盖写入，不在客户端强推临时文件加 `sftp.rename` 替换。
- **原因**：标准 SFTP v3 `SSH_FXP_RENAME` 在目标文件已存在时语义并非原子覆盖（许多服务端直接返回 `SSH_FX_FILE_ALREADY_EXISTS`），而 OpenSSH `posix-rename@openssh.com` 扩展并非所有 SFTP 服务端均支持；此外直接改为新建临时文件再 rename 会丢失原目标文件的权限位（mode）、属主（uid/gid）及硬链接关系。

### 2. 主机密钥 TOFU 单条 `(host, port)` 记录模型
- **现状**：`SecureHostKeyVerifier`（`lib/features/terminal/data/secure_host_key_verifier.dart`）以 `host:port`（`HostKeyRecord.key`）作为唯一键存储单条受信任主机密钥记录；当服务端返回不同算法类型（`type`）或不同指纹（`fingerprint`）时，触发 `HostKeyPromptKind.mismatch` 告警并在用户确认后覆写该条目。
- **决策**：保留每个 `host:port` 单条活跃主机密钥的 TOFU（Trust On First Use）模型。
- **原因**：同一 SSH 实例在固定客户端密钥交换算法协商顺序下通常固定协商出同一主机密钥算法；将同端口多算法拆分为多条并存记录会改变 `conduit.trusted_host_keys.v1` 存储契约与 Trusted Keys 管理界面的展示语义，当前单条替换模型已能准确覆盖密钥轮换与中间人告警场景。

### 3. 无锁屏设备提供 `Continue without auth` 显式放行入口
- **现状**：`AppLockController.unlock` 与 `LockPage`（`lib/features/app_lock/presentation/app_lock_controller.dart`、`lib/features/app_lock/presentation/lock_page.dart`）在 `canAuthenticate()` 返回 `false` 或认证器返回 `AppAuthenticationResult.unavailable` 时进入 `AppLockStatus.unavailable` 状态，展示告警文案并提供 `Continue without auth` 按钮（调用 `continueWithoutAuth()` 解锁）。
- **决策**：保留无系统锁屏/生物识别设备上的显式 `Continue without auth` 降级入口，仅允许在 `AppLockStatus.unavailable` 状态下调用（用户取消认证 `AppLockStatus.locked` 时不展示且拒绝调用）。
- **原因**：Conduit 未内置独立应用级密码体系，完全依赖操作系统凭据（生物识别或设备锁屏 PIN/图案）。若在未配置系统锁屏的设备（如测试机、部分定制平板或开发模拟器）上彻底阻断进入，会导致应用完全不可用；通过红色错误提示告知风险并由用户显式点击确认进入，是可用性与安全性之间的合理折中。

### 4. SSH `keyboard-interactive` 认证单隐藏提示应答策略
- **现状**：`SshClientFactory._userInfoRequestFor`（`lib/features/terminal/data/ssh_client_factory.dart`）在 `SshAuthMethod.password` 模式下处理服务端 `SSH_MSG_USERAUTH_INFO_REQUEST` 时，仅向首个 `echo == false` 的提示项填充已保存的 `host.password`，其余提示项返回空字符串 `''`。
- **决策**：保持仅对首个不回显提示自动填充主机密码的保守策略。
- **原因**：防止恶意或配置异常的服务端通过回显提示（`echo == true`）诱导客户端泄露密码明文，同时避免在多步 PAM 交互（如密码 + OTP 动态口令）中将静态密码错误填入后续挑战字段。完整交互式多提示弹窗涉及新建认证交互通道，归入后续功能演进而非本次缺陷修复。

### 5. 远端 git 固定依赖 `conduit_vt` 的手势 Timer 与粘贴行为观察项
- **现状**：`pubspec.yaml` 将终端核心库 `conduit_vt` 固定在远端 git 仓库 `https://github.com/gwitko/conduit_vt.git`（commit `b486b894ea12b18b2ad76339ccd8c6ae3c12416f`），按仓库分歧维护规范（见 `fork-delta.md`）不在本仓直接替换为其他依赖源。
- **观察项记录**：
  - `conduit_vt` 内部手势识别器与长按/双击选择逻辑存在内部 `Timer` 生命周期管理细节，以及终端层剪贴板粘贴与括号粘贴模式（bracketed paste）的处理约定，均位于外部 `conduit_vt` 仓库源码内。
  - Conduit 主仓在 `TerminalSessionController` 与 `TerminalKeyboardBar`（`_KeySurfaceState`）层已完成自身 `Timer`（`_resizeTimer`、`_delayTimer`、`_repeatTimer`）与流订阅的完整生命周期收口；涉及 `conduit_vt` 包内部的改动需在 `conduit_vt` 独立仓库演进并经验证后再更新 git commit 锁定值。

### 6. 全屏重连按钮在 `connecting` 态隐藏及直接调用 `connect()` 的行为说明
- **现状**：`TerminalPage`（`lib/features/terminal/presentation/terminal_page.dart`）在 `_fullscreen` 模式下仅当 `activeSession.status == TerminalConnectionStatus.disconnected || activeSession.status == TerminalConnectionStatus.failed` 时渲染右上角浮动重连按钮，点击时直接调用 `await activeSession.connect()`；而非全屏顶栏 `TerminalHeader` 的 `onReconnect` 则调用 `await activeSession.disconnect(); await activeSession.connect();`。
- **决策**：保持全屏重连按钮仅在 `disconnected` / `failed` 态显示且点击时直接调用 `activeSession.connect()`。
- **原因**：
  - 非全屏 `TerminalHeader` 在 `connected` / `connecting` 态同样可见，因此其重连回调需先 `disconnect()` 中断当前活跃连接再发起 `connect()`；
  - 全屏浮动按钮仅在会话已断开（`disconnected`）或失败（`failed`）时才渲染，一旦点击触发 `connect()`，状态立即同步切为 `connecting`，浮动按钮自动从视图树移除，不存在 `connecting` 态重复点击问题；且 `connect()` 入口自身已包含递增 `_connectionGeneration`、`await _cancelSessionSubscriptions()` 与 `await _closeSessionSafely(previousSession)` 的完整清理守卫，在此状态下先调 `disconnect()`（对 `disconnected` 态直接 return）属于冗余无操作。

### 7. `HttpRootfsDownloader` 单次实例使用契约
- **现状**：`HttpRootfsDownloader`（`lib/features/local_shell/data/rootfs_downloader.dart`）在未传入外部 `http.Client` 时自建内部 `_client`（`_ownsClient = true`），并在 `download()` 的 `finally` 块中调用 `_client.close()`。
- **决策**：保持 `_ownsClient` 在 `download()` 结束时自动关闭内部 `http.Client`，并在类文档注释中明确标注“使用默认构造器时每次下载应新建实例，不可在同一实例上二次调用 `download()`”。
- **原因**：生产代码中每次 rootfs 下载均按需调用一次 `download()`（或由调用方注入外部托管的 `http.Client`），在 `finally` 中关闭自建 client 能直接杜绝下载完成或失败后的底层套接字泄漏，无需为单次下载器引入额外的 `dispose()` 生命周期负担。

### 8. `HostsController._serializeWrite` 不可重入约束
- **现状**：`HostsController`（`lib/features/hosts/presentation/hosts_controller.dart`）通过单链 `Future<void> _writeQueue`（`_serializeWrite`）串行化 `load`、`setSortMode`、`reorderManual`、`upsert`、`mergeImported`、`remove`、`markConnected`。
- **决策**：保持基于 `_writeQueue` 的非重入（non-reentrant）FIFO 串行队列设计，并在 `_serializeWrite` 注释中明确禁止在队列 `action` 内部重入调用公开序列化方法。
- **原因**：Dart 单线程事件循环下非重入 `Future` 链实现简洁且零锁开销，同时通过 `onError` 恢复与 `try/catch` 确保单次异常不会卡死后续队列；内部跨方法逻辑复用（如 `upsert` 与 `markConnected` 共用 `_upsertNow` / `_save`）已全部下沉至不入队的私有方法，不存在重入需求。

### 9. `TerminalSessionController._closeSessionSafely` 吞异常的设计权衡
- **现状**：`TerminalSessionController._closeSessionSafely`（`lib/features/terminal/presentation/terminal_session_controller.dart`）在调用 `await session.close()` 时使用 `try { ... } catch (_) {}` 静默忽略底层关闭异常。
- **决策**：保持 `_closeSessionSafely` 静默兜底关闭异常的行为。
- **原因**：`_closeSessionSafely` 服务于连接失败回滚（`_cleanupFailedConnect`）、流错误中断（`_handleStreamError`）、远端断开（`_doneSubscription`）、重连清理及控制器销毁（`dispose`）。在这些路径中，底层 SSH/Mosh 传输通道或本地 shell 进程往往已提前断开或处于异常状态；若允许 `close()` 抛出的次生异常向外传播，会掩盖初始连接/流错误或中断后续状态通知。

### 10. `TerminalKeyboardBar`（`_KeySurfaceState`）重复按键配置切换行为
- **现状**：`_KeySurfaceState.didUpdateWidget`（`lib/features/terminal/presentation/terminal_keyboard_bar.dart`）在 `!widget.repeat || widget.onPressed == null` 时调用 `_stopRepeat()` 停止 `_delayTimer` 与 `_repeatTimer`。
- **决策**：仅当按键变为不可重复（`!widget.repeat`）或禁用（`widget.onPressed == null`）以及组件 `dispose` 时强制终止连发定时器；当父组件常规 rebuild 但按键仍为有效可重复按键时，不重置正在按住的连发定时器。
- **原因**：终端软键盘栏监听 `controller.keyboard` 等状态变化，在用户按住方向键/翻页键连发期间父级可能触发常规 rebuild（此时 `onPressed` 闭包实例虽重新生成，但语义仍是同一按键）；若每次 `didUpdateWidget` 无条件取消定时器，会导致按住连发被常规 UI 刷新意外打断。`_pressOnce()` 每次回调均动态读取当前最新的 `widget.onPressed`，既保证了常规 rebuild 不打断连发，又在按键切换为非重复或卸载时彻底清理 Timer。

## 被放弃的方案（必填）
- **在 SFTP 上传中强制改用 `.tmp` 临时文件 + `sftp.rename`**：放弃，因标准 SFTP `rename` 在目标存在时普遍报错且会破坏原文件权限与硬链接属性。
- **在 `AppLockStatus.unavailable` 时禁止进入应用**：放弃，会导致未设置系统锁屏的设备永久死锁在锁屏页。
- **在 `keyboard-interactive` 中将保存的密码填入所有提示项**：放弃，存在向 `echo == true` 明文提示或非密码字段泄露凭据的风险。
- **在 Conduit 主仓内直接 vendoring 或改动 `conduit_vt` 锁定源**：放弃，违反 `fork-delta.md` 对 `conduit_vt` 独立维护的分歧约束。
- **在 `_KeySurfaceState.didUpdateWidget` 中只要 `onPressed` 闭包引用变化就调用 `_stopRepeat()`**：放弃，因 `TerminalKeyboardBar` 重建时会生成新的匿名闭包，若按引用相等判断会导致正常按住连发在 UI 刷新时中断。

## 来源
- 代码路径：
  - `lib/features/sftp/data/dart_ssh_sftp_repository.dart`
  - `lib/features/terminal/data/secure_host_key_verifier.dart`
  - `lib/features/app_lock/presentation/app_lock_controller.dart`
  - `lib/features/app_lock/presentation/lock_page.dart`
  - `lib/features/terminal/data/ssh_client_factory.dart`
  - `lib/features/terminal/presentation/terminal_page.dart`
  - `lib/features/terminal/presentation/terminal_session_controller.dart`
  - `lib/features/terminal/presentation/terminal_keyboard_bar.dart`
  - `lib/features/hosts/presentation/hosts_controller.dart`
  - `lib/features/local_shell/data/rootfs_downloader.dart`
  - `pubspec.yaml` / `.agents/notes/fork-delta.md`
