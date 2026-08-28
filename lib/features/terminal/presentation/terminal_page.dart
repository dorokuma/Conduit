import 'dart:async';

import 'package:conduit/core/presentation/conduit_brand.dart';
import 'package:conduit/core/presentation/system_navigation_insets.dart';
import 'package:conduit/core/theme/app_palette.dart';
import 'package:conduit/core/theme/terminal_appearance.dart';
import 'package:conduit/core/theme/theme_controller.dart';
import 'package:conduit/features/terminal/domain/security_key_interaction.dart';
import 'package:conduit/features/terminal/presentation/security_key_picker_dialog.dart';
import 'package:conduit/features/terminal/presentation/security_key_pin_dialog.dart';
import 'package:conduit/features/terminal/presentation/terminal_keyboard_bar.dart';
import 'package:conduit/features/terminal/presentation/terminal_session_controller.dart';
import 'package:conduit/features/terminal/presentation/terminal_workspace_controller.dart';
import 'package:conduit/features/terminal/presentation/widgets/empty_terminal_state.dart';
import 'package:conduit/features/terminal/presentation/widgets/session_tabs.dart';
import 'package:conduit/features/terminal/presentation/widgets/terminal_header.dart';
import 'package:conduit/features/terminal/presentation/widgets/terminal_surface.dart';
import 'package:conduit_vt/conduit_vt.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

class TerminalPage extends StatefulWidget {
  const TerminalPage({
    required this.workspace,
    required this.themeController,
    super.key,
  });

  final TerminalWorkspaceController workspace;
  final ThemeController themeController;

  @override
  State<TerminalPage> createState() => _TerminalPageState();
}

class _TerminalPageState extends State<TerminalPage> {
  final _focusNode = FocusNode();
  TerminalSessionController? _focusedSession;
  bool _fullscreen = false;
  bool _composeMode = false;
  // Compose recall: recently SENT lines (deduped, oldest first, capped) so a
  // line sent into a mode that discarded it can be recalled; plus the current
  // UNSENT draft, preserved across close so closing compose can't lose it.
  static const int _composeHistoryLimit = 20;
  final List<String> _composeHistory = <String>[];
  String _composeDraft = '';

  // Per-session [GlobalKey<TerminalViewState>] for the toolbar keyboard
  // button. The page needs to call show/hide on the *active* terminal's
  // view state, but [TerminalView] is a child of [TerminalSurface] and
  // lives inside an [IndexedStack] of surfaces. We allocate one key per
  // session host id and pass it down so the surface forwards it to the
  // underlying [TerminalView]. Keys are stable across rebuilds (the
  // backing map is keyed by host id) so the active surface's view
  // state is always addressable from the toolbar.
  final Map<String, GlobalKey<TerminalViewState>> _terminalViewKeys =
      <String, GlobalKey<TerminalViewState>>{};

  @override
  void initState() {
    super.initState();
    unawaited(WakelockPlus.enable());
    SecurityKeyInteraction.instance.registerPinPrompt(_promptSecurityKeyPin);
    SecurityKeyInteraction.instance.registerSelectionPrompt(
      _promptSecurityKeySelection,
    );
    widget.workspace.addListener(_handleWorkspaceChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _focusedSession = widget.workspace.activeSession;
      _focusNode.requestFocus();
    });
  }

  @override
  void dispose() {
    unawaited(WakelockPlus.disable());
    _setSystemUiFullscreen(false);
    SecurityKeyInteraction.instance.unregisterPinPrompt(_promptSecurityKeyPin);
    SecurityKeyInteraction.instance.unregisterSelectionPrompt(
      _promptSecurityKeySelection,
    );
    widget.workspace.removeListener(_handleWorkspaceChanged);
    _focusNode.dispose();
    super.dispose();
  }

  Future<String?> _promptSecurityKeyPin(SecurityKeyPinRequest request) {
    if (!mounted) {
      return Future<String?>.value();
    }
    return showSecurityKeyPinDialog(context, request);
  }

  Future<int?> _promptSecurityKeySelection(
    SecurityKeySelectionRequest request,
  ) {
    if (!mounted) {
      return Future<int?>.value();
    }
    return showSecurityKeyPickerDialog(context, request);
  }

  void _handleWorkspaceChanged() {
    final active = widget.workspace.activeSession;
    if (active == null || active == _focusedSession) return;
    _focusedSession = active;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focusNode.requestFocus();
    });
  }

  void _toggleFullscreen() {
    setState(() => _fullscreen = !_fullscreen);
    _setSystemUiFullscreen(_fullscreen);
  }

  void _setSystemUiFullscreen(bool fullscreen) {
    SystemChrome.setEnabledSystemUIMode(
      fullscreen ? SystemUiMode.immersiveSticky : SystemUiMode.edgeToEdge,
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.themeController,
      builder: (context, _) {
        final palette = widget.themeController.palette;
        return Scaffold(
          body: ListenableBuilder(
            listenable: widget.workspace,
            builder: (context, _) {
              final activeSession = widget.workspace.activeSession;
              final brightness = Theme.of(context).brightness;
              if (activeSession == null) {
                return ConduitBackdrop(
                  palette: palette,
                  child: SafeArea(
                    bottom: shouldApplyBottomSafeArea(context),
                    child: EmptyTerminalState(
                      onBack: () => Navigator.of(context).pop(),
                    ),
                  ),
                );
              }

              final landscape =
                  MediaQuery.orientationOf(context) == Orientation.landscape;
              final gestureNavigation = usesAndroidGestureNavigation(context);
              // Per-session [TerminalView] state for the active session.
              // Lifted out of the [TerminalKeyboardBar] constructor so the
              // [keyboardVisible] expression and [onToggleKeyboard] handler
              // both observe the same live [TextInputConnection] state.
              // Using [hasInputConnection] (instead of viewInsets) makes
              // the toolbar icon flip synchronously with the platform
              // connection — the viewInsets gradient is still > 0 during
              // the IME dismiss animation, so an inset-based check
              // mis-classifies the visible state for the entire close
              // window.
              final viewKey = _terminalViewKeys[activeSession.host.id];
              final view = viewKey?.currentState;
              final keyboardVisible = view?.hasInputConnection ?? false;
              return SafeArea(
                top: !_fullscreen,
                bottom: shouldApplyBottomSafeArea(context),
                left: !_fullscreen && (!landscape || !gestureNavigation),
                right: !_fullscreen && (!landscape || !gestureNavigation),
                child: Column(
                  children: [
                    if (!_fullscreen) ...[
                      TerminalHeader(
                        session: activeSession,
                        palette: palette,
                        brightness: brightness,
                        onBack: () => Navigator.of(context).pop(),
                        onReconnect: () async {
                          await activeSession.disconnect();
                          await activeSession.connect();
                          _focusNode.requestFocus();
                        },
                      ),
                      SessionTabs(
                        workspace: widget.workspace,
                        activeSession: activeSession,
                        palette: palette,
                        brightness: brightness,
                        onChanged: _focusNode.requestFocus,
                      ),
                    ],
                    Expanded(
                      child: Container(
                        color: palette.terminalBackgroundFor(brightness),
                        child: IndexedStack(
                          index: widget.workspace.sessions.indexOf(
                            activeSession,
                          ),
                          children: [
                            for (final session in widget.workspace.sessions)
                              TerminalSurface(
                                key: ValueKey(session.host.id),
                                session: session,
                                palette: palette,
                                brightness: brightness,
                                fontFamily: widget
                                    .themeController
                                    .terminalFont
                                    .fontFamily,
                                fontSize:
                                    widget.themeController.terminalFontSize,
                                onFontSizeChanged: (fontSize) {
                                  unawaited(
                                    widget.themeController.setTerminalFontSize(
                                      fontSize,
                                    ),
                                  );
                                },
                                predictiveEchoEnabled:
                                    session.host.predictiveEchoEnabled,
                                terminalMouseInput:
                                    session.host.startHerdrOnConnect,
                                focusNode: session == activeSession
                                    ? _focusNode
                                    : null,
                                terminalViewKey: _terminalViewKeys.putIfAbsent(
                                  session.host.id,
                                  GlobalKey<TerminalViewState>.new,
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                    _composeMode
                        ? _ComposeInputBar(
                            palette: palette,
                            brightness: brightness,
                            history: _composeHistory,
                            initialText: _composeDraft,
                            onSend: (line) {
                              // Send the line, then deliver Enter as a SEPARATE write a
                              // short moment later. Some remote TUIs (e.g. Claude Code
                              // and other Ink/readline apps) classify a single terminal
                              // read that contains a long line ending in CR as a *paste*
                              // and insert the trailing CR as a literal newline instead
                              // of submitting — so a wrapping compose line silently fails
                              // to send. Delivering Enter in its own read makes it an
                              // isolated keypress that submits regardless of line length.
                              activeSession.sendText(line);
                              Future.delayed(
                                const Duration(milliseconds: 120),
                                () {
                                  activeSession.sendKey(TerminalKey.enter);
                                },
                              );
                              setState(() {
                                // De-duplicate: drop any earlier identical entry so the
                                // ring keeps distinct lines (re-sending a recalled line
                                // can't churn duplicates that evict good older ones).
                                _composeHistory.remove(line);
                                _composeHistory.add(line);
                                if (_composeHistory.length >
                                    _composeHistoryLimit) {
                                  _composeHistory.removeAt(0);
                                }
                                _composeDraft = '';
                              });
                            },
                            onClose: (draft) {
                              setState(() {
                                _composeMode = false;
                                _composeDraft = draft;
                              });
                              _focusNode.requestFocus();
                            },
                          )
                        : TerminalKeyboardBar(
                            controller: activeSession,
                            focusNode: _focusNode,
                            palette: palette,
                            brightness: brightness,
                            rows: widget.themeController.terminalKeyboardRows,
                            globalSnippets:
                                widget.themeController.terminalSnippets,
                            fullscreen: _fullscreen,
                            onToggleFullscreen: _toggleFullscreen,
                            composeActive: _composeMode,
                            onToggleCompose: () =>
                                setState(() => _composeMode = !_composeMode),
                            herdrPrefixKey: activeSession.host.herdrPrefixKey,
                            // Soft-keyboard visibility: drive the icon off
                            // the live [TextInputConnection] state on the
                            // view, not off [MediaQuery.viewInsets]. The
                            // viewInsets gradient is still > 0 during the
                            // IME dismiss animation, so a viewInsets-based
                            // check shows the wrong icon for the entire
                            // close animation. [hasInputConnection] is the
                            // actual platform connection, which closes
                            // synchronously with [dismissSoftKeyboard].
                            keyboardVisible: keyboardVisible,
                            onToggleKeyboard: () {
                              // Drive the soft keyboard through the active
                              // [TerminalView] state rather than the focus
                              // node: programmatic [FocusNode.requestFocus]
                              // never produces a keyboard token, so the
                              // focus listener inside the terminal would
                              // silently no-op (the IME never opens).
                              // [TerminalViewState.showSoftKeyboard] /
                              // [dismissSoftKeyboard] open / close the
                              // input connection directly and unfocus on
                              // dismiss, which is the only reliable path
                              // for a toolbar button. We deliberately use
                              // [hasInputConnection] (not viewInsets) as
                              // the toggle condition: while the IME
                              // dismiss animation is in flight, viewInsets
                              // is still > 0, so an inset-based check
                              // would mis-classify the visible state and
                              // route the second tap to showSoftKeyboard
                              // instead of dismiss.
                              if (view == null) return;
                              if (view.hasInputConnection) {
                                if (kDebugMode) {
                                  debugPrint(
                                    'TerminalPage.onToggleKeyboard: dismiss (hasInputConnection=${view.hasInputConnection}, hasFocus=${_focusNode.hasFocus}, viewInsets=${MediaQuery.viewInsetsOf(context).bottom})',
                                  );
                                }
                                view.dismissSoftKeyboard();
                                // Defend against the platform reopening
                                // the IME: after a successful dismiss,
                                // hand focus to a throwaway node so no
                                // focusable widget in this subtree still
                                // owns a focus that would re-trigger the
                                // focus-listener path inside the terminal
                                // (which would immediately call
                                // requestKeyboard() and re-open the
                                // connection we just closed).
                                FocusScope.of(
                                  context,
                                ).requestFocus(FocusNode());
                              } else {
                                if (kDebugMode) {
                                  debugPrint(
                                    'TerminalPage.onToggleKeyboard: show (hasInputConnection=${view.hasInputConnection}, hasFocus=${_focusNode.hasFocus}, viewInsets=${MediaQuery.viewInsetsOf(context).bottom})',
                                  );
                                }
                                _focusNode.requestFocus();
                                view.showSoftKeyboard();
                                WidgetsBinding.instance.addPostFrameCallback((
                                  _,
                                ) {
                                  if (mounted) {
                                    viewKey?.currentState?.showSoftKeyboard();
                                  }
                                });
                              }
                              setState(() {});
                            },
                          ),
                  ],
                ),
              );
            },
          ),
        );
      },
    );
  }
}

class _ComposeInputBar extends StatefulWidget {
  const _ComposeInputBar({
    required this.palette,
    required this.brightness,
    required this.onSend,
    required this.onClose,
    this.history = const <String>[],
    this.initialText = '',
  });

  final AppPalette palette;
  final Brightness brightness;
  final ValueChanged<String> onSend;

  /// Called on close with the current (unsent) field text so the caller can
  /// preserve it — closing compose must not silently discard a draft.
  final ValueChanged<String> onClose;

  /// Recently sent lines, oldest first; shown most-recent-first in the recall
  /// menu. Deduplicated by the caller.
  final List<String> history;

  /// Draft text to restore into the field when compose reopens.
  final String initialText;

  @override
  State<_ComposeInputBar> createState() => _ComposeInputBarState();
}

class _ComposeInputBarState extends State<_ComposeInputBar> {
  final _controller = TextEditingController();
  final _focusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    if (widget.initialText.isNotEmpty) {
      _controller.value = TextEditingValue(
        text: widget.initialText,
        selection: TextSelection.collapsed(offset: widget.initialText.length),
      );
    }
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _focusNode.requestFocus(),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _send() {
    final text = _controller.text.replaceAll(RegExp(r'[\r\n]'), '');
    _controller.clear();
    if (text.isEmpty) {
      return;
    }
    widget.onSend(text);
    _focusNode.requestFocus();
  }

  void _recall(String line) {
    _controller.value = TextEditingValue(
      text: line,
      selection: TextSelection.collapsed(offset: line.length),
    );
    _focusNode.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: widget.palette.panelFor(widget.brightness),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(2, 6, 4, 6),
        child: Row(
          children: [
            PopupMenuButton<String>(
              icon: const Icon(Icons.history_rounded),
              tooltip: 'Recall a sent line',
              color: widget.palette.panelFor(widget.brightness),
              enabled: widget.history.isNotEmpty,
              onSelected: _recall,
              // Opening the menu takes focus off the field (hiding the soft
              // keyboard). _recall restores focus on select; do the same on
              // cancel so the keyboard always returns after the menu closes.
              onCanceled: _focusNode.requestFocus,
              itemBuilder: (context) => [
                for (final line in widget.history.reversed)
                  PopupMenuItem<String>(
                    value: line,
                    child: Text(
                      line,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
            ),
            Expanded(
              child: TextField(
                controller: _controller,
                focusNode: _focusNode,
                autofocus: true,
                autocorrect: true,
                keyboardType: TextInputType.text,
                textInputAction: TextInputAction.send,
                onSubmitted: (_) => _send(),
                inputFormatters: [
                  // Gboard's action key is inconsistent: sometimes 'Send' (fires
                  // onSubmitted), sometimes 'Enter' (inserts a newline into the
                  // field). Catch the newline-insert path here so submitting is
                  // deterministic regardless of which the IME chooses.
                  TextInputFormatter.withFunction((oldValue, newValue) {
                    if (newValue.text.contains('\n') ||
                        newValue.text.contains('\r')) {
                      WidgetsBinding.instance.addPostFrameCallback(
                        (_) => _send(),
                      );
                      final clean = newValue.text.replaceAll(
                        RegExp(r'[\r\n]'),
                        '',
                      );
                      return TextEditingValue(
                        text: clean,
                        selection: TextSelection.collapsed(
                          offset: clean.length,
                        ),
                      );
                    }
                    return newValue;
                  }),
                ],
                decoration: const InputDecoration(
                  isDense: true,
                  hintText: 'Compose a line, Enter to send …',
                  border: OutlineInputBorder(),
                  contentPadding: EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 8,
                  ),
                ),
              ),
            ),
            IconButton(
              icon: const Icon(Icons.close_rounded),
              tooltip: 'Close compose',
              onPressed: () => widget.onClose(_controller.text),
            ),
          ],
        ),
      ),
    );
  }
}
