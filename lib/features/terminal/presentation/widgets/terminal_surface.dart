import 'dart:async';

import 'package:conduit/core/theme/app_palette.dart';
import 'package:conduit/features/terminal/presentation/terminal_session_controller.dart';
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

  @override
  State<TerminalSurface> createState() => _TerminalSurfaceState();
}

class _TerminalSurfaceState extends State<TerminalSurface> {
  // 双指缩放
  final _pinchPointers = <int, Offset>{};
  double? _pinchStartDistance;
  double? _pinchStartFontSize;

  // 滚动
  Timer? _scrollReturnTimer;
  Terminal? _scrollTerminal;
  late final TerminalController _terminalController;
  late final TerminalController _scrollTerminalController;
  double _scrollOffset = 0;
  bool _isScrolling = false;
  // 跟踪 TerminalView 内部 Scrollable 的位置变化
  double _lastScrollPosition = 0;

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
    _scrollTerminalController = TerminalController();
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
    _scrollTerminalController.dispose();
    _scrollReturnTimer?.cancel();
    super.dispose();
  }

  Future<void> _connectIfNeeded() async {
    if (!mounted || !widget.session.shouldConnect) return;
    await widget.session.connect();
  }

  // ── 双指缩放 ──

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
  }

  double get _pinchDistance {
    final points = _pinchPointers.values.take(2).toList();
    return points.length < 2 ? 0 : (points[0] - points[1]).distance;
  }

  // ── 滚动：监听 TerminalView 内部 Scrollable 的 ScrollNotification ──

  // TerminalView 在备用屏下用 InfiniteScrollView，它是一个 Scrollable。
  // Scrollable 滚动时发 ScrollUpdateNotification，我们拦截它来做缓存滚动，
  // 不竞争手势，不阻止 TerminalView 的 tap/键盘/选择。
  bool _onScrollNotification(ScrollNotification notification) {
    if (notification is ScrollUpdateNotification) {
      final metrics = notification.metrics;
      final currentPos = metrics.pixels;

      // 在备用屏下 InfiniteScrollView 的 pixels 可正可负（无限滚动）
      // 正数 = 向下滚（看更旧的历史），负数 = 向上滚
      final delta = currentPos - _lastScrollPosition;
      _lastScrollPosition = currentPos;

      if (delta.abs() < 1) return false;

      // delta > 0 = 手指向下滑 = 看更新的历史（offset 减小）
      // delta < 0 = 手指向上滑 = 看更旧的历史（offset 增大）
      final scrollBytes = (-delta * _bytesPerLine).round();
      _scrollOffset = (_scrollOffset + scrollBytes).clamp(0, _maxScrollOffset);

      _scrollReturnTimer?.cancel();
      _scrollReturnTimer = Timer(const Duration(milliseconds: 1500), _returnToLive);

      if (!_isScrolling && _scrollOffset > 0) {
        _isScrolling = true;
      }
      _rebuildScrollTerminal();
    }
    return false; // 不阻止通知继续传播
  }

  // ── 滚动辅助 ──

  double get _maxScrollOffset =>
      (widget.session.outputCache.length - _visibleHistoryBytes)
          .clamp(0, double.infinity)
          .toDouble();

  int get _visibleHistoryBytes =>
      widget.session.terminal.viewWidth *
      widget.session.terminal.viewHeight *
      8;

  double get _bytesPerLine => widget.session.terminal.viewWidth * 8.0;

  void _returnToLive() {
    if (!mounted) return;
    setState(() {
      _scrollOffset = 0;
      _scrollTerminal = null;
      _isScrolling = false;
    });
  }

  void _rebuildScrollTerminal() {
    if (_scrollOffset <= 0) {
      if (_scrollTerminal != null) {
        setState(() => _scrollTerminal = null);
      }
      return;
    }
    final terminal = Terminal();
    terminal.resize(
      widget.session.terminal.viewWidth,
      widget.session.terminal.viewHeight,
    );
    final end = widget.session.outputCache.length - _scrollOffset.round();
    if (end <= 0) {
      setState(() => _scrollTerminal = null);
      return;
    }

    // 多读更多余量来找完整 ANSI 边界——4096 字节，覆盖大多数 SGR 颜色序列
    final readLen = (_visibleHistoryBytes + 4096).clamp(0, end);
    final start = (end - readLen).clamp(0, end);
    final bytes = widget.session.outputCache.readRange(start, end - start);

    // 从头部扫描找最近的 ANSI 序列边界
    // 优先找 \x1b[ (CSI 起始)，其次找 \n (换行)
    // 扫描范围扩大到 4096
    int actualStart = 0;
    for (int i = 0; i < bytes.length && i < 4096; i++) {
      if (bytes[i] == 0x1b && i + 1 < bytes.length && bytes[i + 1] == 0x5b) {
        actualStart = i;
        break;
      }
      if (bytes[i] == 0x0a) {
        actualStart = i + 1;
      }
    }

    final writeBytes = bytes.sublist(actualStart);
    terminal.write(String.fromCharCodes(writeBytes));
    setState(() => _scrollTerminal = terminal);
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
        child: NotificationListener<ScrollNotification>(
          onNotification: _onScrollNotification,
          child: Stack(
            children: [
              // 底层：TerminalView，正常处理所有手势（tap/键盘/选择）
              // 滚动 overlay 显示时用 AbsorbPointer 阻止误触
              AbsorbPointer(
                absorbing: _scrollTerminal != null,
                child: ListenableBuilder(
                  listenable: widget.session.terminalPaintListenable,
                  builder: (context, _) {
                    final overlays = widget.session.overlays;
                    return TerminalView(
                      widget.session.terminal,
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
                      // herdr 会话中关掉 simulateScroll，
                      // 让 InfiniteScrollView 滚动时不发方向键
                      simulateScroll: !isHerdr,
                    );
                  },
                ),
              ),
              // 历史画面 overlay（IgnorePointer 让手势穿透到下面的 TerminalView）
              if (_scrollTerminal != null)
                IgnorePointer(
                  child: TerminalView(
                    _scrollTerminal!,
                    controller: _scrollTerminalController,
                    theme: widget.palette.terminalThemeFor(widget.brightness),
                    textStyle: TerminalStyle(
                      fontFamily: widget.fontFamily,
                      fontSize: widget.fontSize,
                    ),
                    padding: const EdgeInsets.fromLTRB(0, 6, 0, 4),
                    simulateScroll: false,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
