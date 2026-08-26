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
  late final TerminalController _terminalController;

  /// Whether herdr copy mode has been entered for the current scroll gesture.
  bool _inCopyMode = false;

  /// Accumulated scroll line delta while not in copy mode; a light flick
  /// below the entry threshold does not enter copy mode.
  int _pendingLines = 0;

  /// Auto-exits herdr copy mode after this long without further scrolling.
  Timer? _copyModeExitTimer;

  /// Minimum accumulated scroll lines before entering copy mode.
  static const _copyModeEnterThreshold = 3;

  /// Cap for a single scroll burst, so a drag fling cannot flood the PTY.
  static const _maxCopyModeScrollLines = 40;

  static const _copyModeExitDelay = Duration(milliseconds: 1500);

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
    _copyModeExitTimer?.cancel();
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
  }

  double get _pinchDistance {
    final points = _pinchPointers.values.take(2).toList();
    return points.length < 2 ? 0 : (points[0] - points[1]).distance;
  }

  // ── herdr copy mode 滚动映射 ──

  /// 备用屏触摸滚动回调，由 conduit_vt 的 [TerminalView.onTouchScroll] 转发
  /// 行数增量。把行增量翻译成按键发给 pty，让 herdr 自己的 copy mode 滚动
  /// （字节切片 overlay 方案已废弃）。conduit_vt 约定：手指上滑（看更旧
  /// 内容）delta 为正，手指下滑（回新内容）delta 为负。
  /// 上滑 → 'k'（copy mode 光标上移，看更旧），下滑 → 'j'。
  void _onTerminalTouchScroll(int lines) {
    final terminal = widget.session.terminal;

    if (!_inCopyMode) {
      _pendingLines += lines;
      if (_pendingLines.abs() < _copyModeEnterThreshold) {
        return;
      }
      // 进入 herdr copy mode：prefix（默认 ctrl+b，控制字符 \x02）然后 '['。
      terminal.textInput('\x02');
      terminal.textInput('[');
      _inCopyMode = true;
      lines = _pendingLines;
      _pendingLines = 0;
    }

    final absLines = lines.abs();
    final n = absLines > _maxCopyModeScrollLines
        ? _maxCopyModeScrollLines
        : absLines;
    final key = lines > 0 ? 'k' : 'j';
    for (var i = 0; i < n; i++) {
      terminal.textInput(key);
    }

    // 每次滚动重置退出计时；1.5s 无滚动后发 'q' 退出 copy mode。
    _copyModeExitTimer?.cancel();
    _copyModeExitTimer = Timer(_copyModeExitDelay, () {
      terminal.textInput('q');
      _inCopyMode = false;
      _pendingLines = 0;
    });
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
            );
          },
        ),
      ),
    );
  }
}