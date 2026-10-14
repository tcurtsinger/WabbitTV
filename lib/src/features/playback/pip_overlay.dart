import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../cinema.dart';
import 'playback_manager.dart';

const _surface = Color(0xFF141419);
const _raised = Color(0xFF1E1E23);
const _warmWhite = Cinema.text;
const _quietText = Cinema.faint;
const _amber = Cinema.amber;

enum PipCorner { topLeft, topRight, bottomRight, bottomLeft }

extension PipCornerPlacement on PipCorner {
  PipCorner get next => PipCorner.values[(index + 1) % PipCorner.values.length];

  Alignment get alignment => switch (this) {
    PipCorner.topLeft => Alignment.topLeft,
    PipCorner.topRight => Alignment.topRight,
    PipCorner.bottomRight => Alignment.bottomRight,
    PipCorner.bottomLeft => Alignment.bottomLeft,
  };

  String get label => switch (this) {
    PipCorner.topLeft => 'top left',
    PipCorner.topRight => 'top right',
    PipCorner.bottomRight => 'bottom right',
    PipCorner.bottomLeft => 'bottom left',
  };
}

Rect pipCornerRect({
  required PipCorner corner,
  required Rect bounds,
  required Size surfaceSize,
  double inset = 20,
}) {
  final left = switch (corner) {
    PipCorner.topLeft || PipCorner.bottomLeft => bounds.left + inset,
    PipCorner.topRight ||
    PipCorner.bottomRight => bounds.right - inset - surfaceSize.width,
  };
  final top = switch (corner) {
    PipCorner.topLeft || PipCorner.topRight => bounds.top + inset,
    PipCorner.bottomLeft ||
    PipCorner.bottomRight => bounds.bottom - inset - surfaceSize.height,
  };
  return Rect.fromLTWH(left, top, surfaceSize.width, surfaceSize.height);
}

PipCorner pipCornerAvoidingTarget({
  required PipCorner requested,
  required Rect bounds,
  required Size surfaceSize,
  required Rect target,
}) {
  var candidate = requested;
  for (var index = 0; index < PipCorner.values.length; index++) {
    if (!pipCornerRect(
      corner: candidate,
      bounds: bounds,
      surfaceSize: surfaceSize,
    ).overlaps(target)) {
      return candidate;
    }
    candidate = candidate.next;
  }
  return requested;
}

/// The fixed in-app Corner Signal. The owning shell removes the full player
/// before mounting this surface, so a session's native video is never mounted
/// in two widget locations at once.
class PipOverlay extends StatelessWidget {
  const PipOverlay({
    super.key,
    required this.manager,
    required this.sessionId,
    required this.corner,
    this.surfaceKey,
    required this.restoreFocus,
    required this.moveFocus,
    required this.muteFocus,
    required this.closeFocus,
    required this.onRestore,
    required this.onMove,
    required this.onToggleMute,
    required this.onClose,
    this.statusMessage,
    this.busy = false,
  });

  final PlaybackManager manager;
  final PlaybackSessionId sessionId;
  final PipCorner corner;
  final Key? surfaceKey;
  final FocusNode restoreFocus;
  final FocusNode moveFocus;
  final FocusNode muteFocus;
  final FocusNode closeFocus;
  final VoidCallback onRestore;
  final VoidCallback onMove;
  final VoidCallback onToggleMute;
  final VoidCallback onClose;
  final String? statusMessage;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final snapshot = manager.session(sessionId);
    if (snapshot == null) return const SizedBox.shrink();
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth < 760 ? 256.0 : 320.0;
        return Align(
          alignment: corner.alignment,
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: SizedBox(
              key: surfaceKey,
              width: width,
              child: Semantics(
                container: true,
                label:
                    'Now playing ${snapshot.title}, picture in picture, ${corner.label}',
                child: Container(
                  key: const ValueKey('corner-signal-pip'),
                  decoration: BoxDecoration(
                    color: _surface,
                    borderRadius: BorderRadius.circular(18),
                    boxShadow: const [
                      BoxShadow(
                        color: Color(0x66000000),
                        blurRadius: 16,
                        offset: Offset(0, 8),
                      ),
                    ],
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: FocusTraversalGroup(
                    policy: WidgetOrderTraversalPolicy(),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        AspectRatio(
                          aspectRatio: 16 / 9,
                          child: Stack(
                            fit: StackFit.expand,
                            children: [
                              ColoredBox(
                                color: Colors.black,
                                child: RepaintBoundary(
                                  key: const ValueKey('corner-signal-video'),
                                  child: manager.videoFor(sessionId),
                                ),
                              ),
                              if (snapshot.phase ==
                                      PlaybackSessionPhase.opening ||
                                  snapshot.phase ==
                                      PlaybackSessionPhase.buffering)
                                const Center(
                                  child: _PipStatus(label: 'Buffering'),
                                ),
                              if (snapshot.phase == PlaybackSessionPhase.failed)
                                const Center(
                                  child: _PipStatus(
                                    label: 'Playback unavailable',
                                  ),
                                ),
                              Positioned(
                                left: 0,
                                right: 0,
                                bottom: 0,
                                child: Container(
                                  padding: const EdgeInsets.fromLTRB(
                                    12,
                                    20,
                                    12,
                                    8,
                                  ),
                                  decoration: BoxDecoration(
                                    gradient: Cinema.scrim(fromTop: false),
                                  ),
                                  child: Text(
                                    snapshot.title,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      color: _warmWhite,
                                      fontSize: 14,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        if (statusMessage != null)
                          Container(
                            key: const ValueKey('corner-signal-status'),
                            width: double.infinity,
                            padding: const EdgeInsets.fromLTRB(12, 7, 12, 6),
                            color: _raised,
                            child: Text(
                              statusMessage!,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: _quietText,
                                fontSize: 12,
                                height: 1.25,
                              ),
                            ),
                          ),
                        Container(
                          color: _surface,
                          padding: const EdgeInsets.all(8),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              _PipAction(
                                key: const ValueKey('corner-signal-return'),
                                focusNode: restoreFocus,
                                icon: Icons.open_in_full,
                                label: 'Return',
                                enabled: !busy,
                                onPressed: onRestore,
                              ),
                              _PipAction(
                                key: const ValueKey('corner-signal-move'),
                                focusNode: moveFocus,
                                icon: Icons.flip_camera_android_outlined,
                                label: 'Move corner',
                                onPressed: onMove,
                              ),
                              _PipAction(
                                key: const ValueKey('corner-signal-mute'),
                                focusNode: muteFocus,
                                icon: snapshot.isAudible
                                    ? Icons.volume_up
                                    : Icons.volume_off,
                                label: snapshot.isAudible ? 'Mute' : 'Unmute',
                                enabled: !busy,
                                onPressed: onToggleMute,
                              ),
                              _PipAction(
                                key: const ValueKey('corner-signal-close'),
                                focusNode: closeFocus,
                                icon: Icons.close,
                                label: 'Close',
                                enabled: !busy,
                                onPressed: onClose,
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _PipAction extends StatefulWidget {
  const _PipAction({
    super.key,
    required this.focusNode,
    required this.icon,
    required this.label,
    required this.onPressed,
    this.enabled = true,
  });

  final FocusNode focusNode;
  final IconData icon;
  final String label;
  final VoidCallback onPressed;
  final bool enabled;

  @override
  State<_PipAction> createState() => _PipActionState();
}

class _PipActionState extends State<_PipAction> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) => Focus(
    focusNode: widget.focusNode,
    canRequestFocus: widget.enabled,
    onFocusChange: (value) => setState(() => _focused = value),
    onKeyEvent: (_, event) {
      if (widget.enabled &&
          event is KeyDownEvent &&
          (event.logicalKey == LogicalKeyboardKey.enter ||
              event.logicalKey == LogicalKeyboardKey.select)) {
        widget.onPressed();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    },
    child: Semantics(
      button: true,
      enabled: widget.enabled,
      label: widget.label,
      child: Tooltip(
        message: widget.label,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.enabled
              ? () {
                  widget.focusNode.requestFocus();
                  widget.onPressed();
                }
              : null,
          child: Container(
            width: 44,
            height: 44,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: _focused ? _amber : Colors.transparent,
              shape: BoxShape.circle,
            ),
            child: Icon(
              widget.icon,
              size: 20,
              color: _focused
                  ? Cinema.amberInk
                  : widget.enabled
                  ? _warmWhite
                  : _quietText,
            ),
          ),
        ),
      ),
    ),
  );
}

class _PipStatus extends StatelessWidget {
  const _PipStatus({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: Cinema.card,
      borderRadius: BorderRadius.circular(999),
    ),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
      child: Text(
        label,
        style: const TextStyle(
          color: _warmWhite,
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
      ),
    ),
  );
}

/// Focus-contained confirmation used before entering Settings or a management
/// continuation while in-app playback is active.
class PipStopConfirmation extends StatelessWidget {
  const PipStopConfirmation({
    super.key,
    required this.focusScopeNode,
    required this.cancelFocus,
    required this.stopFocus,
    required this.onCancel,
    required this.onStop,
    this.busy = false,
  });

  final FocusScopeNode focusScopeNode;
  final FocusNode cancelFocus;
  final FocusNode stopFocus;
  final VoidCallback onCancel;
  final VoidCallback onStop;
  final bool busy;

  @override
  Widget build(BuildContext context) => Positioned.fill(
    child: ColoredBox(
      color: const Color(0xA6000000),
      child: FocusScope.withExternalFocusNode(
        focusScopeNode: focusScopeNode,
        child: FocusTraversalGroup(
          policy: WidgetOrderTraversalPolicy(),
          child: CallbackShortcuts(
            bindings: <ShortcutActivator, VoidCallback>{
              const SingleActivator(LogicalKeyboardKey.escape): onCancel,
              const SingleActivator(LogicalKeyboardKey.browserBack): onCancel,
            },
            child: Center(
              child: Semantics(
                container: true,
                label: 'Stop playback and continue confirmation',
                child: Container(
                  key: const ValueKey('pip-stop-confirmation'),
                  width: 420,
                  constraints: const BoxConstraints(maxWidth: 420),
                  padding: const EdgeInsets.all(24),
                  decoration: BoxDecoration(
                    color: _raised,
                    borderRadius: BorderRadius.circular(22),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Stop playback and continue?',
                        style: TextStyle(
                          color: _warmWhite,
                          fontFamily: Cinema.display,
                          fontSize: 20,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 20),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          _ConfirmationAction(
                            key: const ValueKey('pip-stop-cancel'),
                            focusNode: cancelFocus,
                            label: 'Cancel',
                            enabled: !busy,
                            onPressed: onCancel,
                          ),
                          const SizedBox(width: 10),
                          _ConfirmationAction(
                            key: const ValueKey('pip-stop-confirm'),
                            focusNode: stopFocus,
                            label: busy ? 'Stopping…' : 'Stop playback',
                            primary: true,
                            enabled: !busy,
                            onPressed: onStop,
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

class _ConfirmationAction extends StatefulWidget {
  const _ConfirmationAction({
    super.key,
    required this.focusNode,
    required this.label,
    required this.onPressed,
    required this.enabled,
    this.primary = false,
  });

  final FocusNode focusNode;
  final String label;
  final VoidCallback onPressed;
  final bool enabled;
  final bool primary;

  @override
  State<_ConfirmationAction> createState() => _ConfirmationActionState();
}

class _ConfirmationActionState extends State<_ConfirmationAction> {
  bool _focused = false;

  bool get _filled => widget.primary || _focused;

  @override
  Widget build(BuildContext context) => Focus(
    focusNode: widget.focusNode,
    canRequestFocus: widget.enabled,
    onFocusChange: (value) => setState(() => _focused = value),
    onKeyEvent: (_, event) {
      if (widget.enabled &&
          event is KeyDownEvent &&
          (event.logicalKey == LogicalKeyboardKey.enter ||
              event.logicalKey == LogicalKeyboardKey.select)) {
        widget.onPressed();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    },
    child: Semantics(
      button: true,
      enabled: widget.enabled,
      label: widget.label,
      child: GestureDetector(
        onTap: widget.enabled
            ? () {
                widget.focusNode.requestFocus();
                widget.onPressed();
              }
            : null,
        child: Container(
          constraints: const BoxConstraints(minWidth: 96, minHeight: 44),
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(horizontal: 20),
          decoration: BoxDecoration(
            color: _filled ? _amber : Cinema.glass,
            // A constant width so focus never resizes the pill.
            border: Border.all(
              color: _focused ? _warmWhite : const Color(0x00000000),
              width: 2,
            ),
            borderRadius: BorderRadius.circular(22),
            boxShadow: _focused ? [Cinema.focusGlow.last] : null,
          ),
          child: Text(
            widget.label,
            style: TextStyle(
              color: _filled ? Cinema.amberInk : _warmWhite,
              fontSize: 14,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ),
    ),
  );
}
