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

  /// Cached herdr history shown by the scrollback overlay. Kept after the
  /// overlay closes so the next trigger can display instantly while a fresh
  /// fetch refreshes it.
  List<String>? _historyLines;
  bool _showHistoryOverlay = false;
  bool _historyLoading = false;
  late final ScrollController _historyScrollController;
  bool _hasScrolledBack = false;

  /// Minimum history lines for the overlay to be worth showing; fewer than a
  /// screenful of text is not scrollable and is dismissed.
  int get _historyMinLines {
    final rows = widget.session.terminal.viewHeight;
    return rows > 0 ? rows : 30;
  }

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
    _historyScrollController = ScrollController()
      ..addListener(_onHistoryScroll);
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
    _historyScrollController.dispose();
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

  // ── herdr 历史滚动（pane read exec 通道 + 原生 ListView overlay）──

  /// 备用屏触摸滚动回调，由 conduit_vt 的 [TerminalView.onTouchScroll] 转发
  /// 行数增量。手指上滑（看更旧内容）实测 delta 为正（见
  /// terminal_surface_test.dart 的方向断言），只在看更旧时拉起历史 overlay；
  /// overlay 打开后直接 return，手势交给 overlay 自己处理。
  void _onTerminalTouchScroll(int lines) {
    if (_showHistoryOverlay) {
      return;
    }
    if (lines <= 0) {
      return;
    }
    setState(() {
      _showHistoryOverlay = true;
      _historyLoading = true;
    });
    _loadHistory();
  }

  Future<void> _loadHistory() async {
    final lines = await widget.session.fetchHerdrHistory();
    if (!mounted) {
      return;
    }
    setState(() {
      _historyLoading = false;
      if (lines == null || lines.length < _historyMinLines) {
        // 历史太少，不值得滚动：直接复位，不开 overlay。
        _showHistoryOverlay = false;
        _hasScrolledBack = false;
        if (_historyScrollController.hasClients) {
          _historyScrollController.jumpTo(0);
        }
      } else {
        _historyLines = lines;
      }
    });
  }

  /// Overlay 打开时的手势驱动。原生 reverse ListView 的触摸方向实测是
  /// “下滑=看更旧、上滑=看更新”，与用户约定的“上滑=看更旧”相反（见
  /// terminal_surface_test.dart 注释），所以这里拦截拖动并反向映射：
  /// 手指上滑（dy < 0）→ offset 增大（回溯更旧），下滑 → offset 减小
  /// （回最新）。
  void _handleHistoryDrag(DragUpdateDetails details) {
    if (_pinchPointers.length >= 2) {
      // 双指缩放进行中，不滚动 overlay。
      return;
    }
    if (!_historyScrollController.hasClients) {
      return;
    }
    final position = _historyScrollController.position;
    final next = position.pixels - details.delta.dy;
    position.jumpTo(next.clamp(0.0, position.maxScrollExtent));
  }

  void _onHistoryScroll() {
    if (!_showHistoryOverlay) {
      return;
    }
    final position = _historyScrollController.position;
    if (position.pixels > 0) {
      _hasScrolledBack = true;
      return;
    }
    if (_hasScrolledBack && position.pixels <= 0) {
      // 滚回最新端（offset 0 = 最新行在底部）→ 自动关 overlay。
      _hasScrolledBack = false;
      setState(() {
        _showHistoryOverlay = false;
        _historyLoading = false;
      });
    }
  }

  Widget _buildHistoryOverlay() {
    final lines = _historyLines;
    return Positioned.fill(
      child: ColoredBox(
        color: widget.palette.terminalBackgroundFor(widget.brightness),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onVerticalDragUpdate: _handleHistoryDrag,
          child: _historyLoading && lines == null
              ? const Center(child: CircularProgressIndicator())
              : ListView.builder(
                  controller: _historyScrollController,
                  reverse: true,
                  physics: const NeverScrollableScrollPhysics(),
                  padding: const EdgeInsets.fromLTRB(0, 6, 0, 4),
                  itemCount: lines?.length ?? 0,
                  itemBuilder: (context, index) {
                    // reverse: offset 0 = 最新行在底部 → index 0 显示最后一行。
                    final text = lines![lines.length - 1 - index];
                    return Text(
                      text,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontFamily: widget.fontFamily,
                        fontSize: widget.fontSize,
                        height: 1.25,
                        color: widget.palette.terminalForegroundFor(
                          widget.brightness,
                        ),
                      ),
                    );
                  },
                ),
        ),
      ),
    );
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
            return Stack(
              children: [
                TerminalView(
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
                ),
                if (_showHistoryOverlay) _buildHistoryOverlay(),
              ],
            );
          },
        ),
      ),
    );
  }
}
