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
  final _pinchPointers = <int, Offset>{};
  double? _pinchStartDistance;
  double? _pinchStartFontSize;
  Timer? _scrollReturnTimer;
  Terminal? _scrollTerminal;
  late final TerminalController _terminalController;
  late final TerminalController _scrollTerminalController;
  double _scrollOffset = 0;
  bool _isScrolling = false;
  Offset? _lastMovePosition;
  Offset? _dragStart;
  bool _dragThresholdMet = false;
  static const double _dragThreshold = 12.0;

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

  // ── Pointer 事件（Listener 不参与手势竞技场，总能收到）──

  void _handlePointerDown(PointerDownEvent event) {
    _pinchPointers[event.pointer] = event.localPosition;
    if (_pinchPointers.length == 1) {
      _dragStart = event.localPosition;
      _lastMovePosition = event.localPosition;
      _dragThresholdMet = false;
    }
    if (_pinchPointers.length == 2) {
      _pinchStartDistance = _pinchDistance;
      _pinchStartFontSize = widget.fontSize;
      _dragStart = null;
      _dragThresholdMet = false;
    }
  }

  void _handlePointerMove(PointerMoveEvent event) {
    if (!_pinchPointers.containsKey(event.pointer)) return;
    _pinchPointers[event.pointer] = event.localPosition;

    // 双指缩放
    if (_pinchPointers.length == 2) {
      final startDistance = _pinchStartDistance;
      final startFontSize = _pinchStartFontSize;
      if (startDistance == null || startDistance == 0 || startFontSize == null) {
        return;
      }
      widget.onFontSizeChanged(startFontSize * (_pinchDistance / startDistance));
      return;
    }

    // 单指拖拽滚动
    if (_pinchPointers.length == 1 && _lastMovePosition != null) {
      final start = _dragStart;
      if (start == null) return;

      // 阈值判断
      if (!_dragThresholdMet) {
        final totalDist = (event.localPosition - start).dy.abs();
        if (totalDist < _dragThreshold) return;
        _dragThresholdMet = true;
      }

      final dy = event.localPosition.dy - _lastMovePosition!.dy;
      _lastMovePosition = event.localPosition;

      // dy > 0 = 向下滑 = 看更新的历史（offset 减小）
      // dy < 0 = 向上滑 = 看更旧的历史（offset 增大）
      final bytesPerLine = widget.session.terminal.viewWidth * 8.0;
      final scrollBytes = (-dy * bytesPerLine / _lineHeightPixels).round();

      _scrollOffset = (_scrollOffset + scrollBytes).clamp(0, _maxScrollOffset);
      _scrollReturnTimer?.cancel();
      _scrollReturnTimer = Timer(const Duration(milliseconds: 1500), _returnToLive);

      if (!_isScrolling) {
        setState(() => _isScrolling = true);
      }
      _rebuildScrollTerminal();
    }
  }

  void _handlePointerEnd(PointerEvent event) {
    _pinchPointers.remove(event.pointer);
    if (_pinchPointers.length < 2) {
      _pinchStartDistance = null;
      _pinchStartFontSize = null;
    }
    if (_pinchPointers.isEmpty) {
      _dragStart = null;
      _lastMovePosition = null;
      _dragThresholdMet = false;
      // 松手后不立即回实时，等 timer
    }
  }

  double get _pinchDistance {
    final points = _pinchPointers.values.take(2).toList();
    return points.length < 2 ? 0 : (points[0] - points[1]).distance;
  }

  // ── 滚动辅助 ──

  double get _lineHeightPixels => widget.fontSize * 1.2;

  double get _maxScrollOffset =>
      (widget.session.outputCache.length - _visibleHistoryBytes)
          .clamp(0, double.infinity)
          .toDouble();

  int get _visibleHistoryBytes =>
      widget.session.terminal.viewWidth *
      widget.session.terminal.viewHeight *
      8;

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

    // 多读 4096 字节余量找完整 ANSI 边界
    final readLen = (_visibleHistoryBytes + 4096).clamp(0, end);
    final start = (end - readLen).clamp(0, end);
    final bytes = widget.session.outputCache.readRange(start, end - start);

    // 找最近的 ANSI 序列边界
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
        child: Stack(
          children: [
            // TerminalView 正常处理所有手势（tap/键盘/选择/Scrollable）
            // 滚动 overlay 期间用 AbsorbPointer 阻止误触
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
                    simulateScroll: !isHerdr,
                  );
                },
              ),
            ),
            // 历史画面 overlay
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
    );
  }
}
