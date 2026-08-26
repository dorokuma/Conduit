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
  Offset? _lastPointerPosition;
  Offset? _scrollStart;

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

  void _handlePointerDown(PointerDownEvent event) {
    _pinchPointers[event.pointer] = event.localPosition;
    _lastPointerPosition = event.localPosition;
    if (_pinchPointers.length == 1) _scrollStart = event.localPosition;
    if (_pinchPointers.length == 2) {
      _pinchStartDistance = _pinchDistance;
      _pinchStartFontSize = widget.fontSize;
    }
  }

  void _handlePointerMove(PointerMoveEvent event) {
    if (!_pinchPointers.containsKey(event.pointer)) return;
    _pinchPointers[event.pointer] = event.localPosition;
    final previous = _lastPointerPosition;
    _lastPointerPosition = event.localPosition;
    if (_pinchPointers.length == 1 && previous != null) {
      final start = _scrollStart;
      if (start != null && (event.localPosition.dy - start.dy).abs() > 8) {
        final dy = event.localPosition.dy - previous.dy;
        _scrollOffset = (_scrollOffset - dy).clamp(0, _maxScrollOffset);
        _scrollReturnTimer?.cancel();
        _scrollReturnTimer = Timer(
          const Duration(milliseconds: 1500),
          _returnToLive,
        );
        _rebuildScrollTerminal();
      }
    }
    final startDistance = _pinchStartDistance;
    final startFontSize = _pinchStartFontSize;
    if (_pinchPointers.length != 2 ||
        startDistance == null ||
        startDistance == 0 ||
        startFontSize == null) {
      return;
    }
    widget.onFontSizeChanged(startFontSize * (_pinchDistance / startDistance));
  }

  void _handlePointerEnd(PointerEvent event) {
    _pinchPointers.remove(event.pointer);
    _lastPointerPosition = null;
    if (_pinchPointers.length < 2) {
      _pinchStartDistance = null;
      _pinchStartFontSize = null;
    }
  }

  double get _maxScrollOffset =>
      (widget.session.outputCache.length - _visibleHistoryBytes)
          .clamp(0, double.infinity)
          .toDouble();

  int get _visibleHistoryBytes =>
      widget.session.terminal.viewWidth *
      widget.session.terminal.viewHeight *
      8;

  double get _pinchDistance {
    final points = _pinchPointers.values.take(2).toList();
    return points.length < 2 ? 0 : (points[0] - points[1]).distance;
  }

  void _returnToLive() {
    if (!mounted) return;
    setState(() {
      _scrollOffset = 0;
      _scrollTerminal = null;
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
    final start = (end - _visibleHistoryBytes).clamp(0, end);
    final bytes = widget.session.outputCache.readRange(start, end - start);
    terminal.write(String.fromCharCodes(bytes));
    setState(() => _scrollTerminal = terminal);
  }

  @override
  Widget build(BuildContext context) {
    return ClipRect(
      child: Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: _handlePointerDown,
        onPointerMove: _handlePointerMove,
        onPointerUp: _handlePointerEnd,
        onPointerCancel: _handlePointerEnd,
        child: Stack(
          children: [
            ListenableBuilder(
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
                  simulateScroll: !widget.session.host.startHerdrOnConnect,
                );
              },
            ),
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
