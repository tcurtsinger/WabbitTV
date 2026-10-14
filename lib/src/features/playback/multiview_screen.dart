import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../cinema.dart';
import 'playback_manager.dart';

const _warmWhite = Cinema.text;
const _quietText = Cinema.faint;
const _amber = Cinema.amber;

/// Fixed two-stream Live multiview. Each native video is mounted exactly once;
/// the shared deck commands sessions through the shell-lifetime manager.
class MultiviewScreen extends StatefulWidget {
  const MultiviewScreen({
    super.key,
    required this.manager,
    required this.originalSessionId,
    required this.secondSessionId,
    required this.onOpenFullPlayer,
    required this.onCloseSession,
    required this.onCollapse,
    this.onAudibleUsableVideo,
  });

  final PlaybackManager manager;
  final PlaybackSessionId originalSessionId;
  final PlaybackSessionId secondSessionId;
  final ValueChanged<PlaybackSessionId> onOpenFullPlayer;
  final ValueChanged<PlaybackSessionId> onCloseSession;
  final VoidCallback onCollapse;

  /// Reports only a completed audio-owner change whose selected Live session
  /// already has usable video. Merely opening a muted second tile never counts
  /// as the viewer's last channel.
  final ValueChanged<PlaybackSessionId>? onAudibleUsableVideo;

  @override
  State<MultiviewScreen> createState() => _MultiviewScreenState();
}

class _MultiviewScreenState extends State<MultiviewScreen> {
  final _firstFocus = FocusNode(debugLabel: 'multiview original stream');
  final _secondFocus = FocusNode(debugLabel: 'multiview second stream');
  final _audioFocus = FocusNode(debugLabel: 'multiview make audible');
  final _fullFocus = FocusNode(debugLabel: 'multiview full player');
  final _closeFocus = FocusNode(debugLabel: 'multiview close selected');
  final _collapseFocus = FocusNode(debugLabel: 'multiview collapse');
  late PlaybackSessionId _deckTarget;
  PlaybackSessionId? _lastAudioOwner;
  bool _changingAudio = false;
  String? _audioTransferMessage;

  @override
  void initState() {
    super.initState();
    _lastAudioOwner = _audibleOwner();
    _deckTarget = _lastAudioOwner ?? widget.originalSessionId;
    widget.manager.addListener(_managerChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focusFor(_lastAudioOwner ?? _deckTarget).requestFocus();
    });
  }

  @override
  void didUpdateWidget(covariant MultiviewScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.manager != oldWidget.manager) {
      oldWidget.manager.removeListener(_managerChanged);
      widget.manager.addListener(_managerChanged);
    }
    _reconcileFromManager();
  }

  @override
  void dispose() {
    widget.manager.removeListener(_managerChanged);
    _firstFocus.dispose();
    _secondFocus.dispose();
    _audioFocus.dispose();
    _fullFocus.dispose();
    _closeFocus.dispose();
    _collapseFocus.dispose();
    super.dispose();
  }

  Future<void> _makeAudible(PlaybackSessionId id) async {
    if (_changingAudio) return;
    final previous = _audibleOwner();
    final previousTarget = _deckTarget;
    setState(() {
      _changingAudio = true;
      _audioTransferMessage = null;
    });
    bool transferred;
    try {
      transferred = await widget.manager.setAudioOwner(id);
    } catch (_) {
      transferred = false;
    }
    if (!mounted) return;
    _reconcileFromManager(
      transferSucceeded: transferred,
      previousOwner: previous,
      fallbackTarget: previousTarget,
      restoreFocus: true,
    );
  }

  PlaybackSessionId? _audibleOwner() {
    for (final id in [widget.originalSessionId, widget.secondSessionId]) {
      if (widget.manager.session(id)?.isAudible ?? false) return id;
    }
    return null;
  }

  FocusNode _focusFor(PlaybackSessionId id) =>
      id == widget.secondSessionId ? _secondFocus : _firstFocus;

  bool get _ownsFocus => [
    _firstFocus,
    _secondFocus,
    _audioFocus,
    _fullFocus,
    _closeFocus,
    _collapseFocus,
  ].any((node) => node.hasFocus);

  void _managerChanged() {
    if (!mounted || _changingAudio) return;
    // The manager notifies on every position tick; only pull focus back when
    // it has left this screen, never away from a deck control.
    _reconcileFromManager(restoreFocus: !_ownsFocus);
  }

  void _reconcileFromManager({
    bool? transferSucceeded,
    PlaybackSessionId? previousOwner,
    PlaybackSessionId? fallbackTarget,
    bool restoreFocus = false,
  }) {
    if (!mounted) return;
    final actual = _audibleOwner();
    final prior = previousOwner ?? _lastAudioOwner;
    final target = actual ?? prior ?? fallbackTarget ?? _deckTarget;
    final message =
        actual != null && transferSucceeded == false && actual == prior
        ? "Couldn't switch audio."
        : null;
    final ownerChanged = actual != _lastAudioOwner;
    setState(() {
      _changingAudio = false;
      _lastAudioOwner = actual;
      _deckTarget = target;
      _audioTransferMessage = message;
    });
    if (ownerChanged &&
        actual != null &&
        widget.manager.session(actual)?.transportState.hasVideo == true) {
      widget.onAudibleUsableVideo?.call(actual);
    }
    if (restoreFocus || ownerChanged) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final focus = _focusFor(actual ?? target);
        if (focus.canRequestFocus) focus.requestFocus();
      });
    }
  }

  @override
  Widget build(BuildContext context) => CallbackShortcuts(
    bindings: <ShortcutActivator, VoidCallback>{
      const SingleActivator(LogicalKeyboardKey.escape): widget.onCollapse,
      const SingleActivator(LogicalKeyboardKey.browserBack): widget.onCollapse,
    },
    child: AnimatedBuilder(
      animation: widget.manager,
      builder: (context, _) {
        final first = widget.manager.session(widget.originalSessionId);
        final second = widget.manager.session(widget.secondSessionId);
        if (first == null || second == null) return const SizedBox.expand();
        final selected = first.isAudible
            ? first
            : second.isAudible
            ? second
            : null;
        final target = _deckTarget == second.id ? second : first;
        return FocusTraversalGroup(
          policy: WidgetOrderTraversalPolicy(),
          child: Material(
            key: const ValueKey('live-multiview'),
            color: Cinema.ink,
            child: SafeArea(
              top: false,
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final tiles = <Widget>[
                    Expanded(
                      child: AspectRatio(
                        aspectRatio: 16 / 9,
                        child: _MultiviewTile(
                          key: const ValueKey('multiview-original-tile'),
                          manager: widget.manager,
                          snapshot: first,
                          focusNode: _firstFocus,
                          selected: first.isAudible,
                          onSelected: () => _makeAudible(first.id),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: AspectRatio(
                        aspectRatio: 16 / 9,
                        child: _MultiviewTile(
                          key: const ValueKey('multiview-second-tile'),
                          manager: widget.manager,
                          snapshot: second,
                          focusNode: _secondFocus,
                          selected: second.isAudible,
                          onSelected: () => _makeAudible(second.id),
                        ),
                      ),
                    ),
                  ];
                  return Column(
                    children: [
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                          child: Row(children: tiles),
                        ),
                      ),
                      _MultiviewDeck(
                        selected: selected,
                        target: target,
                        changingAudio: _changingAudio,
                        audioTransferMessage: _audioTransferMessage,
                        audioFocus: _audioFocus,
                        fullFocus: _fullFocus,
                        closeFocus: _closeFocus,
                        collapseFocus: _collapseFocus,
                        onMakeAudible: () => _makeAudible(target.id),
                        onOpenFull: () => widget.onOpenFullPlayer(target.id),
                        onClose: () => widget.onCloseSession(target.id),
                        onCollapse: widget.onCollapse,
                      ),
                    ],
                  );
                },
              ),
            ),
          ),
        );
      },
    ),
  );
}

class _MultiviewTile extends StatefulWidget {
  const _MultiviewTile({
    super.key,
    required this.manager,
    required this.snapshot,
    required this.focusNode,
    required this.selected,
    required this.onSelected,
  });

  final PlaybackManager manager;
  final PlaybackSessionSnapshot snapshot;
  final FocusNode focusNode;
  final bool selected;
  final VoidCallback onSelected;

  @override
  State<_MultiviewTile> createState() => _MultiviewTileState();
}

class _MultiviewTileState extends State<_MultiviewTile> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) => Focus(
    focusNode: widget.focusNode,
    onFocusChange: (value) => setState(() => _focused = value),
    onKeyEvent: (_, event) {
      if (event is KeyDownEvent &&
          (event.logicalKey == LogicalKeyboardKey.enter ||
              event.logicalKey == LogicalKeyboardKey.select)) {
        widget.onSelected();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    },
    child: Semantics(
      button: true,
      selected: widget.selected,
      label:
          '${widget.snapshot.title}, ${widget.snapshot.isAudible ? 'audible' : 'muted'}',
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          widget.focusNode.requestFocus();
          widget.onSelected();
        },
        child: Container(
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: Colors.black,
            borderRadius: BorderRadius.circular(14),
            boxShadow: _focused ? Cinema.focusGlow : null,
          ),
          child: Stack(
            fit: StackFit.expand,
            children: [
              RepaintBoundary(
                key: ValueKey(
                  widget.snapshot.id == widget.manager.sessions.first.id
                      ? 'multiview-original-video'
                      : 'multiview-second-video',
                ),
                child: widget.manager.videoFor(widget.snapshot.id),
              ),
              if (widget.snapshot.phase == PlaybackSessionPhase.opening ||
                  widget.snapshot.phase == PlaybackSessionPhase.buffering)
                const Center(child: _TileStatus(label: 'Buffering')),
              if (widget.snapshot.phase == PlaybackSessionPhase.failed)
                const Center(child: _TileStatus(label: 'Playback unavailable')),
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: Container(
                  padding: const EdgeInsets.fromLTRB(14, 28, 14, 12),
                  decoration: BoxDecoration(
                    gradient: Cinema.scrim(fromTop: false),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        widget.snapshot.isAudible
                            ? Icons.volume_up
                            : Icons.volume_off,
                        size: 18,
                        color: widget.snapshot.isAudible ? _amber : _quietText,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          widget.snapshot.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: _warmWhite,
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

class _MultiviewDeck extends StatelessWidget {
  const _MultiviewDeck({
    required this.selected,
    required this.target,
    required this.changingAudio,
    required this.audioTransferMessage,
    required this.audioFocus,
    required this.fullFocus,
    required this.closeFocus,
    required this.collapseFocus,
    required this.onMakeAudible,
    required this.onOpenFull,
    required this.onClose,
    required this.onCollapse,
  });

  final PlaybackSessionSnapshot? selected;
  final PlaybackSessionSnapshot target;
  final bool changingAudio;
  final String? audioTransferMessage;
  final FocusNode audioFocus;
  final FocusNode fullFocus;
  final FocusNode closeFocus;
  final FocusNode collapseFocus;
  final VoidCallback onMakeAudible;
  final VoidCallback onOpenFull;
  final VoidCallback onClose;
  final VoidCallback onCollapse;

  @override
  Widget build(BuildContext context) => Container(
    key: const ValueKey('multiview-shared-deck'),
    constraints: const BoxConstraints(minHeight: 76),
    padding: const EdgeInsets.fromLTRB(20, 14, 20, 16),
    child: LayoutBuilder(
      builder: (context, constraints) {
        final narrow = constraints.maxWidth < 800;
        final title = Row(
          children: [
            Icon(
              selected == null ? Icons.volume_off : Icons.volume_up,
              size: 20,
              color: selected == null ? _quietText : _amber,
            ),
            const SizedBox(width: 10),
            Flexible(
              child: Text(
                selected?.title ?? 'Muted. Pick a channel to hear it.',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: _warmWhite,
                  fontFamily: selected == null ? null : Cinema.display,
                  fontSize: selected == null ? 15 : 18,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            if (audioTransferMessage != null) ...[
              const SizedBox(width: 12),
              Semantics(
                liveRegion: true,
                child: Text(
                  audioTransferMessage!,
                  key: const ValueKey('multiview-audio-transfer-error'),
                  maxLines: 1,
                  style: const TextStyle(
                    color: Color(0xFFFF8D83),
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ],
        );
        final actions = Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _DeckButton(
              key: const ValueKey('multiview-audio'),
              focusNode: audioFocus,
              icon: selected == null ? Icons.hearing : Icons.volume_up,
              label: selected == null ? 'Restore audio' : 'Audible',
              compact: narrow,
              enabled: !changingAudio && selected == null,
              onPressed: onMakeAudible,
            ),
            const SizedBox(width: 8),
            _DeckButton(
              key: const ValueKey('multiview-full-player'),
              focusNode: fullFocus,
              icon: Icons.open_in_full,
              label: 'Full player',
              compact: narrow,
              onPressed: onOpenFull,
            ),
            const SizedBox(width: 8),
            _DeckButton(
              key: const ValueKey('multiview-close-selected'),
              focusNode: closeFocus,
              icon: Icons.close,
              label: 'Close tile',
              compact: narrow,
              onPressed: onClose,
            ),
            const SizedBox(width: 8),
            _DeckButton(
              key: const ValueKey('multiview-collapse'),
              focusNode: collapseFocus,
              icon: Icons.filter_1_outlined,
              label: 'Collapse',
              compact: narrow,
              onPressed: onCollapse,
            ),
          ],
        );
        return narrow
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  title,
                  const SizedBox(height: 10),
                  Align(alignment: Alignment.centerRight, child: actions),
                ],
              )
            : Row(
                children: [
                  Expanded(child: title),
                  const SizedBox(width: 20),
                  actions,
                ],
              );
      },
    ),
  );
}

class _DeckButton extends StatefulWidget {
  const _DeckButton({
    super.key,
    required this.focusNode,
    required this.icon,
    required this.label,
    required this.onPressed,
    this.enabled = true,
    this.compact = false,
  });

  final FocusNode focusNode;
  final IconData icon;
  final String label;
  final VoidCallback onPressed;
  final bool enabled;
  final bool compact;

  @override
  State<_DeckButton> createState() => _DeckButtonState();
}

class _DeckButtonState extends State<_DeckButton> {
  bool _focused = false;

  Color get _content => _focused
      ? Cinema.amberInk
      : widget.enabled
      ? _warmWhite
      : _quietText;

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
            width: widget.compact ? 44 : null,
            height: 44,
            padding: EdgeInsets.symmetric(horizontal: widget.compact ? 0 : 18),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: _focused ? _amber : Cinema.glass,
              borderRadius: BorderRadius.circular(22),
              boxShadow: _focused ? [Cinema.focusGlow.last] : null,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(widget.icon, size: 18, color: _content),
                if (!widget.compact) ...[
                  const SizedBox(width: 7),
                  Text(
                    widget.label,
                    style: TextStyle(
                      color: _content,
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

class _TileStatus extends StatelessWidget {
  const _TileStatus({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: Cinema.card,
      borderRadius: BorderRadius.circular(999),
    ),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Text(
        label,
        style: const TextStyle(
          color: _warmWhite,
          fontSize: 13,
          fontWeight: FontWeight.w600,
        ),
      ),
    ),
  );
}
