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

  // ── herdr 滚动映射（PageUp/PageDown 双场景）──

  /// 触摸滚动回调，由 conduit_vt 的 [TerminalView.onTouchScroll] 转发
  /// 行数增量。方向约定与 conduit_vt onTouchScroll 一致（见
  /// terminal_surface_test.dart 的方向断言）：手指上滑（看更旧内容）
  /// delta 为正，手指下滑（回新内容）delta 为负。
  ///
  /// 把增量翻译成 PageUp/PageDown 序列发给 pty，由 herdr 决定滚动行为：
  /// - bash pane：herdr 自己持有 scrollback，直接吃掉 PageUp/PageDown 滚
  ///   自己的 scrollback；
  /// - pi pane：herdr 的 scrollback 为空，把 PageUp/PageDown 转发给 pane
  ///   里的 pi，由 pi 翻页到对话开头。
  /// 上滑（看更旧）→ PageUp（\x1b[5~），下滑（回新）→ PageDown（\x1b[6~）。
  /// 增量小于 4 行忽略（防误触）；每约 35 行算一页，单次事件最多发 4 个
  /// 序列，防止快速拖拽洪泛 PTY。
  void _onTerminalTouchScroll(int lines) {
    final abs = lines.abs();
    if (abs < 4) {
      return;
    }
    final pages = (abs / 35).ceil();
    final count = pages > 4 ? 4 : pages;
    final sequence = lines > 0 ? '\x1b[5~' : '\x1b[6~';
    widget.session.terminal.textInput(sequence * count);
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
