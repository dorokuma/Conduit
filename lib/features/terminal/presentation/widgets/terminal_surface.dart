import 'dart:async';

import 'package:conduit/core/theme/app_palette.dart';
import 'package:conduit/features/terminal/presentation/terminal_session_controller.dart';
import 'package:conduit/features/terminal/presentation/widgets/touch_scroll_coalescer.dart';
import 'package:conduit_vt/conduit_vt.dart';
import 'package:flutter/material.dart';

class TerminalSurface extends StatefulWidget {
  const TerminalSurface({
    required this.session,
    required this.palette,
    required this.brightness,
    required this.fontFamily,
    required this.fontSize,
    required this.onFontSizeChanged,
    required this.predictiveEchoEnabled,
    required this.terminalMouseInput,
    required this.focusNode,
    this.terminalViewKey,
    super.key,
  });

  final TerminalSessionController session;
  final AppPalette palette;
  final Brightness brightness;
  final String fontFamily;
  final double fontSize;
  final ValueChanged<double> onFontSizeChanged;
  final bool predictiveEchoEnabled;
  final bool terminalMouseInput;
  final FocusNode? focusNode;

  /// Optional externally-owned key for the inner [TerminalView] state.
  /// Pass this when the parent needs to call
  /// [TerminalViewState.showSoftKeyboard] / [hideSoftKeyboard] (e.g. the
  /// toolbar keyboard button) — otherwise the surface allocates its own.
  final GlobalKey<TerminalViewState>? terminalViewKey;

  @override
  State<TerminalSurface> createState() => TerminalSurfaceState();
}

/// Public state for [TerminalSurface] so the page (and tests) can
/// reach the soft-keyboard show/hide methods without depending on a
/// private name.
class TerminalSurfaceState extends State<TerminalSurface> {
  final _pinchPointers = <int, Offset>{};
  double? _pinchStartDistance;
  double? _pinchStartFontSize;
  late final TerminalController _terminalController;

  // Allows the page to drive the toolbar keyboard button: the page has
  // no direct reference to the [TerminalView] state, so it calls
  // [showSoftKeyboard] / [hideSoftKeyboard] on this State and we forward
  // to the underlying [TerminalViewState]. The surface allocates its own
  // key by default; the parent may pass in [widget.terminalViewKey] to
  // share a single key across surfaces (one per session) so the toolbar
  // can always reach the *active* terminal's view state.
  late final GlobalKey<TerminalViewState> _terminalViewKey =
      widget.terminalViewKey ?? GlobalKey<TerminalViewState>();

  // ── Touch-scroll coalescing ──
  // conduit_vt 转发给我们的 onTouchScroll 回调，在原实现里 “1–3 行” 的
  // 小增量会被 `abs < 4` 丢掉，但一旦快速拖动产生单个 ≥4 行增量就发
  // ceil(abs/35) 页（最少 1 整页 35 行）。慢速划全忽略、快速划每事件
  // 送一整页 → 一次手扫发出十几个 PageUp，PTY/远端 pi 被排成队列，
  // 延迟从 5 秒堆到 90 秒，且迟到的 PageUp 风暴把用户的 PageDown
  // 盖过，卡死在顶部滚不下来。
  //
  // 修复：纯逻辑抽出到 [TouchScrollCoalescer]（无副作用、可单元
  // 测试），Widget 只负责累计行增量 + 周期冲刷 timer + 手势结束
  // 补冲。回调只累加到 [_pendingScrollLines]（带方向符号，clamp
  // 到 ±96 防积压失控），由 160ms 周期 timer 按当前待发页数冲刷
  // （单次冲刷最多 3 页，≈450 行/秒上限，远低于远端 pi TUI 洪泛线），
  // 手势结束时再补冲一次。
  static const TouchScrollCoalescer _scrollCoalescer = TouchScrollCoalescer();
  static const Duration _scrollFlushInterval = Duration(milliseconds: 160);
  Timer? _scrollFlushTimer;
  int _pendingScrollLines = 0; // 带方向符号的累计行数

  static PointerInputs _pointerInputsFor(bool terminalMouseInput) {
    return terminalMouseInput
        ? const PointerInputs({PointerInput.tap})
        : const PointerInputs.none();
  }

  @override
  void initState() {
    super.initState();
    _terminalController = TerminalController(
      pointerInputs: _pointerInputsFor(widget.terminalMouseInput),
    );
    widget.session.predictiveEchoEnabled = widget.predictiveEchoEnabled;
    WidgetsBinding.instance.addPostFrameCallback((_) => _connectIfNeeded());
  }

  @override
  void didUpdateWidget(covariant TerminalSurface oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.predictiveEchoEnabled != widget.predictiveEchoEnabled ||
        oldWidget.session != widget.session) {
      widget.session.predictiveEchoEnabled = widget.predictiveEchoEnabled;
    }
    if (oldWidget.terminalMouseInput != widget.terminalMouseInput) {
      _terminalController.setPointerInputs(
        _pointerInputsFor(widget.terminalMouseInput),
      );
    }
    if (oldWidget.session != widget.session) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _connectIfNeeded());
    }
  }

  @override
  void dispose() {
    _terminalController.dispose();
    _scrollFlushTimer?.cancel();
    _scrollFlushTimer = null;
    super.dispose();
  }

  Future<void> _connectIfNeeded() async {
    if (!mounted || !widget.session.shouldConnect) return;
    await widget.session.connect();
  }

  // ── Pointer 事件（Listener 不参与手势竞技场，总能收到）──

  void _handlePointerDown(PointerDownEvent event) {
    _pinchPointers[event.pointer] = event.localPosition;
    if (_pinchPointers.length == 2) {
      _pinchStartDistance = _pinchDistance;
      _pinchStartFontSize = widget.fontSize;
    }
  }

  void _handlePointerMove(PointerMoveEvent event) {
    if (!_pinchPointers.containsKey(event.pointer)) return;
    _pinchPointers[event.pointer] = event.localPosition;

    // 双指缩放
    if (_pinchPointers.length != 2) return;
    final startDistance = _pinchStartDistance;
    final startFontSize = _pinchStartFontSize;
    if (startDistance == null || startDistance == 0 || startFontSize == null) {
      return;
    }
    widget.onFontSizeChanged(startFontSize * (_pinchDistance / startDistance));
  }

  void _handlePointerEnd(PointerEvent event) {
    _pinchPointers.remove(event.pointer);
    if (_pinchPointers.length < 2) {
      _pinchStartDistance = null;
      _pinchStartFontSize = null;
    }
    // 手势结束：把还没冲刷完的剩余行量一次性补发一页，然后取消 timer。
    // 门槛 4 行（与原 `abs < 4 return` 同步）避免轻微抖动触发额外页面，
    // 同时保证任何有意义的滚动都能在离手后即时生效。
    if (_pendingScrollLines != 0) {
      final endPages = _scrollCoalescer.endFlush(_pendingScrollLines);
      if (endPages != 0) {
        _emitScrollPages(endPages);
      }
      _pendingScrollLines = 0;
    }
    _scrollFlushTimer?.cancel();
    _scrollFlushTimer = null;
  }

  double get _pinchDistance {
    final points = _pinchPointers.values.take(2).toList();
    return points.length < 2 ? 0 : (points[0] - points[1]).distance;
  }

  // ── herdr 滚动映射（PageUp/PageDown 双场景）──

  /// 触摸滚动回调，由 conduit_vt 的 [TerminalView.onTouchScroll] 转发
  /// 行数增量。方向约定与 conduit_vt onTouchScroll 一致（见
  /// terminal_surface_test.dart 的方向断言）：手指上滑（看新内容）
  /// delta 为正，手指下滑（回旧内容）delta 为负。
  ///
  /// 把增量翻译成 PageUp/PageDown 序列发给 pty，由 herdr 决定滚动行为：
  /// - bash pane：herdr 自己持有 scrollback，直接吃掉 PageUp/PageDown 滚
  ///   自己的 scrollback；
  /// - pi pane：herdr 的 scrollback 为空，把 PageUp/PageDown 转发给 pane
  ///   里的 pi，由 pi 翻页到对话开头。
  /// 上滑（看新）→ PageDown（\x1b[6~），下滑（回旧）→ PageUp（\x1b[5~）。
  /// 方向约定 v1.4.30 翻面（v1.4.29 之前为“手指上滑→PageUp”，
  /// 倒置用户的阅读习惯；本版改为“手指上滑→PageDown”，匹配手机
  /// 触控主流约定）。
  ///
  /// 原实现（“abs < 4 丢小增量，|abs/35|.ceil() 整页送出”）会被一次
  /// 手扫产生十几个 PageUp，PTY/远端 pi 被排成队列延迟上卷；改为
  /// “累计+节流冲刷”：回调只累加到 [_pendingScrollLines]（带方向
  /// 符号，clamp 到 ±96 防积压失控），由 160ms 周期 timer 按当前
  /// 待发页数冲刷（单次冲刷最多 3 页，≈450 行/秒上限，远低于远端
  /// pi TUI 洪泛线），手势结束时再补冲一次。
  void _onTerminalTouchScroll(int lines) {
    if (lines == 0) return;
    // 累计到带方向符号的计数器，超过防积压上限则截断（保留方向）。
    _pendingScrollLines = _scrollCoalescer
        .clampPending(_pendingScrollLines + lines);
    // 启动周期冲刷 timer（如果还没在跑）。多次连续增量复用同一个
    // timer，避免反复创建/销毁。
    _scrollFlushTimer ??= Timer.periodic(
      _scrollFlushInterval,
      (_) => _flushPendingScroll(),
    );
  }

  /// 冲刷 [_pendingScrollLines]：按当前待发页数送出页序列，从计数器
  /// 减掉已发送的页量。
  void _flushPendingScroll() {
    final pending = _pendingScrollLines;
    if (pending == 0) {
      _scrollFlushTimer?.cancel();
      _scrollFlushTimer = null;
      return;
    }
    final emit = _scrollCoalescer.periodicFlush(pending);
    if (emit == 0) {
      // 本周期内累计还不够 1 页，留给下个周期（或者手势结束补冲）。
      return;
    }
    _emitScrollPages(emit);
    _pendingScrollLines -= _scrollCoalescer.linesConsumedByFlush(emit);
    if (_pendingScrollLines == 0) {
      _scrollFlushTimer?.cancel();
      _scrollFlushTimer = null;
    }
  }

  /// 实际发送 [pages] 个同方向 PageUp/PageDown 序列到 PTY。
  /// [pages] 为正发 PageDown（看新），为负发 PageUp（回旧），
  /// 0 不动作。
  void _emitScrollPages(int pages) {
    if (pages == 0) return;
    // v1.4.30 方向翻转：之前 pages>0（上滑）发 PageUp，现改为发
    // PageDown 以匹配用户“手指上滑看新内容”的直觉。
    final sequence = pages > 0 ? '\x1b[6~' : '\x1b[5~';
    widget.session.terminal.textInput(sequence * pages.abs());
  }

  // ── build ──

  @override
  Widget build(BuildContext context) {
    final isHerdr = widget.session.host.startHerdrOnConnect;
    return ClipRect(
      child: Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: _handlePointerDown,
        onPointerMove: _handlePointerMove,
        onPointerUp: _handlePointerEnd,
        onPointerCancel: _handlePointerEnd,
        child: ListenableBuilder(
          listenable: widget.session.terminalPaintListenable,
          builder: (context, _) {
            final overlays = widget.session.overlays;
            return TerminalView(
              widget.session.terminal,
              key: _terminalViewKey,
              controller: _terminalController,
              focusNode: widget.focusNode,
              autofocus: widget.focusNode != null,
              deleteDetection: true,
              keyboardType: TextInputType.visiblePassword,
              theme: widget.palette.terminalThemeFor(widget.brightness),
              overlays: overlays,
              textStyle: TerminalStyle(
                fontFamily: widget.fontFamily,
                fontSize: widget.fontSize,
              ),
              padding: const EdgeInsets.fromLTRB(0, 6, 0, 4),
              cursorType: overlays.isEmpty
                  ? TerminalCursorType.block
                  : TerminalCursorType.verticalBar,
              alwaysShowCursor: true,
              simulateScroll: !isHerdr,
              onTouchScroll: isHerdr ? _onTerminalTouchScroll : null,
              // herdr 会话主要是 TUI 交互：点选词、点链接、点按钮。默认
              // 点终端会弹软键盘，遮住 TUI、抢焦点。这里传 true 让
              // TerminalView 跳过 _onTapUp 里的 focus + openInputConnection，
              // 需要打字时走工具栏的键盘按钮唤出 IME。
              keepKeyboardHiddenOnTap: isHerdr,
            );
          },
        ),
      ),
    );
  }

  // ── Soft-keyboard API (called by the page's toolbar toggle) ──

  /// Show the soft keyboard for this terminal.
  ///
  /// Forwards to [TerminalViewState.showSoftKeyboard], which opens the
  /// input connection regardless of the [FocusNode.consumeKeyboardToken]
  /// path — needed because the toolbar button's programmatic
  /// [FocusNode.requestFocus] never produces a token, so the focus
  /// listener inside the terminal would silently no-op. Schedules a
  /// post-frame retry so the show also works when the focus node is
  /// not yet focused on the first tap (focus changes are async).
  void showSoftKeyboard() {
    final view = _terminalViewKey.currentState;
    if (view == null) return;
    view.showSoftKeyboard();
    // requestFocus() is async: if the focus node was not yet focused
    // when showSoftKeyboard() ran, the freshly focused node may need a
    // second pass once the focus chain has settled. The retry is a
    // no-op when the keyboard is already open, so the cost is bounded.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _terminalViewKey.currentState?.showSoftKeyboard();
    });
  }

  /// Hide the soft keyboard and drop terminal focus.
  ///
  /// Forwards to [TerminalViewState.hideSoftKeyboard], which closes the
  /// input connection directly and unfocuses the focus node so a later
  /// tap on the terminal does not immediately re-open the IME.
  void hideSoftKeyboard() {
    _terminalViewKey.currentState?.hideSoftKeyboard();
  }
}
