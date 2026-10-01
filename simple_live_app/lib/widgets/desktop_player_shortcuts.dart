import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class DesktopPlayerShortcuts extends StatefulWidget {
  const DesktopPlayerShortcuts({
    required this.child,
    required this.onTogglePlay,
    required this.onToggleFullScreen,
    required this.onToggleMute,
    required this.onVolumeUp,
    required this.onVolumeDown,
    required this.onEscape,
    this.onSeekBackward,
    this.onSeekForward,
    super.key,
  });

  final Widget child;
  final FutureOr<void> Function() onTogglePlay;
  final FutureOr<void> Function() onToggleFullScreen;
  final FutureOr<double> Function() onToggleMute;
  final FutureOr<double> Function() onVolumeUp;
  final FutureOr<double> Function() onVolumeDown;
  final FutureOr<void> Function() onEscape;
  final FutureOr<void> Function()? onSeekBackward;
  final FutureOr<void> Function()? onSeekForward;

  @override
  State<DesktopPlayerShortcuts> createState() => _DesktopPlayerShortcutsState();
}

class _DesktopPlayerShortcutsState extends State<DesktopPlayerShortcuts> {
  final FocusNode _focusNode = FocusNode();
  Timer? _feedbackTimer;
  String? _volumeFeedback;

  bool get _isDesktop =>
      Platform.isWindows || Platform.isLinux || Platform.isMacOS;

  bool get _editingText {
    var context = FocusManager.instance.primaryFocus?.context;
    return context?.widget is EditableText ||
        context?.findAncestorWidgetOfExactType<EditableText>() != null;
  }

  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    if (!_isDesktop || event is! KeyDownEvent || _editingText) {
      return KeyEventResult.ignored;
    }

    if (event.logicalKey == LogicalKeyboardKey.space) {
      unawaited(Future.sync(widget.onTogglePlay));
    } else if (event.logicalKey == LogicalKeyboardKey.keyF) {
      unawaited(Future.sync(widget.onToggleFullScreen));
    } else if (event.logicalKey == LogicalKeyboardKey.keyM) {
      _runVolumeAction(widget.onToggleMute);
    } else if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
      _runVolumeAction(widget.onVolumeUp);
    } else if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
      _runVolumeAction(widget.onVolumeDown);
    } else if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
      var action = widget.onSeekBackward;
      if (action == null) {
        return KeyEventResult.ignored;
      }
      unawaited(Future.sync(action));
    } else if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
      var action = widget.onSeekForward;
      if (action == null) {
        return KeyEventResult.ignored;
      }
      unawaited(Future.sync(action));
    } else if (event.logicalKey == LogicalKeyboardKey.escape) {
      unawaited(Future.sync(widget.onEscape));
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  void _runVolumeAction(FutureOr<double> Function() action) {
    unawaited(
      Future.sync(action).then((volume) {
        if (!mounted) {
          return;
        }
        _feedbackTimer?.cancel();
        setState(() {
          _volumeFeedback = volume == 0 ? "已静音" : "音量 ${volume.round()}%";
        });
        _feedbackTimer = Timer(const Duration(milliseconds: 1200), () {
          if (mounted) {
            setState(() => _volumeFeedback = null);
          }
        });
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: _focusNode,
      autofocus: true,
      onKeyEvent: _onKeyEvent,
      child: Stack(
        fit: StackFit.expand,
        children: [
          widget.child,
          if (_volumeFeedback case final feedback?)
            IgnorePointer(
              child: Center(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: Colors.black87,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 20,
                      vertical: 12,
                    ),
                    child: Text(
                      feedback,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _feedbackTimer?.cancel();
    _focusNode.dispose();
    super.dispose();
  }
}
