import 'dart:async';

import 'package:conduit/core/theme/app_palette.dart';
import 'package:conduit/features/terminal/presentation/terminal_session_controller.dart';
import 'package:conduit_vt/conduit_vt.dart';
import 'package:flutter/gestures.dart';
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
  // 用于手动转发 tap 时拿到实时终端的 RenderTerminal（与 TerminalView 内部同一条换算路径）
  final _terminalViewKey = GlobalKey<TerminalViewState>();
  double _scrollOffset = 0;
  bool _isScrolling = false;

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

  // ── 双指缩放（Listener 被动监听，不参与竞技场）──

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

  // ── 垂直拖拽滚动（RawGestureDetector 主动竞争，opaque 独占）──

  void _onDragStart(DragStartDetails details) {
    if (_pinchPointers.length > 1) return;
    _scrollReturnTimer?.cancel();
  }

  void _onDragUpdate(DragUpdateDetails details) {
    if (_pinchPointers.length > 1) return;
    // 向上滑（负 dy）= 看更旧的历史（offset 增大）
    final scrollLines = (details.delta.dy / 2).round();
    final scrollBytes =
        scrollLines * _visibleHistoryBytes ~/ widget.session.terminal.viewHeight;
    _scrollOffset = (_scrollOffset - scrollBytes).clamp(0, _maxScrollOffset);
    _scrollReturnTimer?.cancel();
    _scrollReturnTimer = Timer(const Duration(milliseconds: 1500), _returnToLive);
    if (!_isScrolling) {
      setState(() => _isScrolling = true);
    }
    _rebuildScrollTerminal();
  }

  void _onDragEnd(DragEndDetails details) {
    // 保留 timer，松手 1.5 秒后自动回实时
  }

  // ── Tap 手动转发（opaque 阻止 TerminalView 收 tap，需手动发 SGR 鼠标点击）──

  void _onTapUp(TapUpDetails details) {
    if (!widget.terminalMouseInput) return;
    // shouldSendPointerInput 是 conduit_vt 的 @internal 成员，用公开的
    // suspendedPointerInputs + pointerInput 复现同一判定逻辑。
    if (_terminalController.suspendedPointerInputs ||
        !_terminalController.pointerInput.inputs.contains(PointerInput.tap)) {
      return;
    }
    // conduit_vt 的 Terminal 没有 mouseEvent；与 TerminalView 内部手势处理器一致，
    // 走 RenderTerminal.mouseEvent（内部完成 Offset→CellOffset 换算）。
    final terminalView = _terminalViewKey.currentState;
    if (terminalView == null) return;
    terminalView.renderTerminal.mouseEvent(
      TerminalMouseButton.left,
      TerminalMouseButtonState.down,
      details.localPosition,
    );
    terminalView.renderTerminal.mouseEvent(
      TerminalMouseButton.left,
      TerminalMouseButtonState.up,
      details.localPosition,
    );
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
    // 多读 512 字节余量，在前面找 ANSI 序列边界
    final readLen = (_visibleHistoryBytes + 512).clamp(0, end);
    final start = (end - readLen).clamp(0, end);
    final bytes = widget.session.outputCache.readRange(start, end - start);

    // 从这批字节前面找最近的 ANSI 序列起始边界
    int actualStart = 0;
    for (int i = 0; i < bytes.length && i < 512; i++) {
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
      child: Stack(
        children: [
          // 底层：实时终端。opaque 手势层在上，TerminalView 不参与竞技场。
          // AbsorbPointer 仍保留：滚动 overlay 期间彻底阻止误触。
          AbsorbPointer(
            absorbing: _isScrolling || _scrollTerminal != null,
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
                );
              },
            ),
          ),
          // 手势层：opaque 独占所有手势。
          // VerticalDrag → 滚动缓存历史
          // Tap → 手动转发 SGR 鼠标点击给 terminal（切 pane）
          // 双指缩放由内部 Listener 被动监听
          Positioned.fill(
            child: RawGestureDetector(
              behavior: HitTestBehavior.opaque,
              excludeFromSemantics: true,
              gestures: <Type, GestureRecognizerFactory>{
                VerticalDragGestureRecognizer:
                    GestureRecognizerFactoryWithHandlers<
                        VerticalDragGestureRecognizer>(
                  () => VerticalDragGestureRecognizer(
                    supportedDevices: const <PointerDeviceKind>{
                      PointerDeviceKind.touch,
                    },
                  ),
                  (VerticalDragGestureRecognizer instance) {
                    instance
                      ..onStart = _onDragStart
                      ..onUpdate = _onDragUpdate
                      ..onEnd = _onDragEnd;
                  },
                ),
                TapGestureRecognizer:
                    GestureRecognizerFactoryWithHandlers<TapGestureRecognizer>(
                  () => TapGestureRecognizer(
                    supportedDevices: const <PointerDeviceKind>{
                      PointerDeviceKind.touch,
                    },
                  ),
                  (TapGestureRecognizer instance) {
                    instance.onTapUp = _onTapUp;
                  },
                ),
              },
              child: Listener(
                behavior: HitTestBehavior.translucent,
                onPointerDown: _handlePointerDown,
                onPointerMove: _handlePointerMove,
                onPointerUp: _handlePointerEnd,
                onPointerCancel: _handlePointerEnd,
                child: const SizedBox.expand(),
              ),
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
    );
  }
}
