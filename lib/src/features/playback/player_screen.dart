// THESIS: One calm Broadcast Deck presents a shell-owned PlaybackManager
// session; widget rebuilds never create or replace a native transport.

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

import '../browse/playback_handoff.dart';
import '../sources/credential_store.dart';
import '../sources/source_catalog_database.dart';
import 'playback_manager.dart';
import 'playback_runtime_adapters.dart';
import 'playback_transport.dart';

export 'playback_runtime_adapters.dart' show resolveXtreamPlaybackUri;

const _graphite = Color(0xFF111212),
    _surface = Color(0xFF191A1A),
    _raised = Color(0xFF222321),
    _line = Color(0xFF343534),
    _warmWhite = Color(0xFFF4F0E7),
    _quietText = Color(0xFFAAA8A2),
    _amber = Color(0xFFFFB347),
    _amberInk = Color(0xFF17120A);

const productionPlayerStartupDeadline = playbackStartupDeadline;
const _chromeDuration = Duration(seconds: 4);

/// Legacy fixture helper retained while production startup is manager-owned.
enum PlaybackFailureKind { credentialsUnavailable, unavailable, timedOut }

@visibleForTesting
Future<PlaybackFailureKind?> waitForPlaybackStartup(
  Future<PlaybackFailureKind?> outcome,
  Duration deadline,
) => outcome.timeout(deadline, onTimeout: () => PlaybackFailureKind.timedOut);

typedef PlaybackTransportFactory = PlaybackTransport Function();
typedef UsableVideoCallback = FutureOr<void> Function(PlaybackHandoff handoff);

abstract interface class FullscreenPort {
  Future<bool> get isFullscreen;
  Future<void> setFullscreen(bool value);
}

class WindowFullscreenPort implements FullscreenPort {
  const WindowFullscreenPort();
  @override
  Future<bool> get isFullscreen async {
    try {
      return await windowManager.isFullScreen();
    } catch (_) {
      return false;
    }
  }

  @override
  Future<void> setFullscreen(bool value) async {
    try {
      if (!Platform.isWindows) {
        await windowManager.setFullScreen(value);
        return;
      }
      if (value) {
        await windowManager.setTitleBarStyle(TitleBarStyle.hidden);
        try {
          await windowManager.setFullScreen(true);
        } catch (_) {
          await windowManager.setTitleBarStyle(TitleBarStyle.normal);
        }
      } else {
        await windowManager.setFullScreen(false);
        await windowManager.setTitleBarStyle(TitleBarStyle.normal);
      }
    } catch (_) {}
  }
}

class PlayerScreen extends StatefulWidget {
  const PlayerScreen({
    super.key,
    required this.handoff,
    required this.onExit,
    this.manager,
    this.sessionId,
    this.onOpenSettings,
    this.onEnterPip,
    this.onAddChannel,
    this.variantPort,
    this.fullscreenPort,
    this.onUsableVideo,
    this.source,
    this.credentialStore,
    this.sourceResolver,
    this.transportFactory,
    this.startupDeadline = productionPlayerStartupDeadline,
  }) : assert(
         (manager == null && sessionId == null) ||
             (manager != null && sessionId != null),
       );

  final PlaybackHandoff handoff;
  final PlaybackManager? manager;
  final PlaybackSessionId? sessionId;
  final FutureOr<void> Function() onExit;
  final FutureOr<void> Function()? onOpenSettings, onEnterPip, onAddChannel;
  final PlaybackExactVariantPort? variantPort;
  final FullscreenPort? fullscreenPort;
  final UsableVideoCallback? onUsableVideo;

  // Legacy fixture seam. Production passes manager + sessionId.
  final PersistedSource? source;
  final CredentialStore? credentialStore;
  final FutureOr<PersistedSource?> Function(String sourceId)? sourceResolver;
  final PlaybackTransportFactory? transportFactory;
  final Duration startupDeadline;

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> {
  final _stage = FocusNode(debugLabel: 'player video stage');
  final _chrome = FocusScopeNode(debugLabel: 'player chrome');
  final _tracksScope = FocusScopeNode(
    debugLabel: 'tracks ledger',
    traversalEdgeBehavior: TraversalEdgeBehavior.closedLoop,
    directionalTraversalEdgeBehavior: TraversalEdgeBehavior.closedLoop,
  );
  final _back = FocusNode(debugLabel: 'player back');
  final _back10 = FocusNode(debugLabel: 'back ten');
  final _play = FocusNode(debugLabel: 'play pause');
  final _forward10 = FocusNode(debugLabel: 'forward ten');
  final _mute = FocusNode(debugLabel: 'player mute');
  final _timeline = FocusNode(debugLabel: 'player timeline');
  final _volume = FocusNode(debugLabel: 'player volume');
  final _tracks = FocusNode(debugLabel: 'tracks');
  final _startOverNode = FocusNode(debugLabel: 'start over');
  final _pip = FocusNode(debugLabel: 'picture in picture');
  final _add = FocusNode(debugLabel: 'add channel');
  final _fullscreenNode = FocusNode(debugLabel: 'player fullscreen');
  final _trackDone = FocusNode(debugLabel: 'tracks done');
  final _firstTrack = FocusNode(debugLabel: 'first track');
  final _recoveryPrimary = FocusNode(debugLabel: 'player recovery primary');
  final _recoveryBack = FocusNode(debugLabel: 'player recovery back');
  final _recoveryDetails = FocusNode(
    debugLabel: 'player recovery technical details',
  );

  late PlaybackManager _manager;
  late PlaybackHandoff _handoff;
  late bool _ownsManager;
  PlaybackSessionId? _sessionId;
  Timer? _chromeTimer;
  bool _chromeVisible = true,
      _tracksOpen = false,
      _detailsVisible = false,
      _trackBusy = false,
      _leaving = false,
      _legacyStarting = false,
      _usableReported = false;
  bool _wasBuffering = false;
  bool _wasFailed = false;
  bool _variantRequestIssued = false;
  PlaybackBlockReason? _legacyBlock;
  String? _message;
  List<PlaybackVariantCandidate> _variants = const [];
  int _variantGeneration = 0;

  PlaybackSessionSnapshot? get _snapshot =>
      _sessionId == null ? null : _manager.session(_sessionId!);
  PlaybackTransportState get _state =>
      _snapshot?.transportState ?? const PlaybackTransportState();
  bool get _live => _handoff.mediaKind == PlaybackMediaKind.live;
  bool get _starting =>
      _legacyStarting || _snapshot?.phase == PlaybackSessionPhase.opening;
  bool get _failed =>
      _legacyBlock != null || _snapshot?.phase == PlaybackSessionPhase.failed;
  FullscreenPort get _fullscreen =>
      widget.fullscreenPort ?? const WindowFullscreenPort();

  @override
  void initState() {
    super.initState();
    _handoff = widget.handoff;
    _sessionId = widget.sessionId;
    _ownsManager = widget.manager == null;
    _manager = widget.manager ?? _legacyManager();
    _manager.addListener(_changed);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _stage.requestFocus();
      _showChrome();
      if (_sessionId == null) unawaited(_startLegacy());
      _changed();
    });
  }

  PlaybackManager _legacyManager() {
    final resolver =
        widget.sourceResolver ??
        (String id) {
          final source = widget.source;
          return source != null && source.id == id ? source : null;
        };
    return PlaybackManager(
      targetResolver: SourcePlaybackTargetResolver(
        sourceResolver: resolver,
        credentialStore: widget.credentialStore ?? SecureCredentialStore(),
      ),
      transportFactory:
          widget.transportFactory ?? MediaKitPlaybackTransport.create,
      startupDeadline: widget.startupDeadline,
    );
  }

  @override
  void didUpdateWidget(covariant PlayerScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.manager != null && widget.manager != oldWidget.manager) {
      _manager.removeListener(_changed);
      if (_ownsManager) unawaited(_manager.close());
      _manager = widget.manager!;
      _ownsManager = false;
      _manager.addListener(_changed);
    }
    if (widget.sessionId != null && widget.sessionId != oldWidget.sessionId) {
      _sessionId = widget.sessionId;
      _usableReported = false;
      _resetVariants();
    }
    if (widget.handoff != oldWidget.handoff) {
      _handoff = widget.handoff;
      _resetVariants();
    } else if (widget.variantPort != oldWidget.variantPort) {
      _resetVariants();
    }
    _changed();
  }

  @override
  void dispose() {
    _chromeTimer?.cancel();
    _manager.removeListener(_changed);
    if (_ownsManager) unawaited(_manager.close());
    for (final node in [
      _stage,
      _chrome,
      _tracksScope,
      _back,
      _back10,
      _play,
      _forward10,
      _mute,
      _timeline,
      _volume,
      _tracks,
      _startOverNode,
      _pip,
      _add,
      _fullscreenNode,
      _trackDone,
      _firstTrack,
      _recoveryPrimary,
      _recoveryBack,
      _recoveryDetails,
    ]) {
      node.dispose();
    }
    super.dispose();
  }

  Future<void> _startLegacy() async {
    if (_legacyStarting || _leaving) return;
    setState(() {
      _legacyStarting = true;
      _legacyBlock = null;
    });
    final result = await _manager.start(_handoff);
    if (!mounted || _leaving) return;
    setState(() {
      _legacyStarting = false;
      switch (result) {
        case PlaybackStarted(:final sessionId):
        case PlaybackStartFailed(:final sessionId):
          _sessionId = sessionId;
        case PlaybackBlocked(:final reason):
          _legacyBlock = reason;
      }
    });
    _changed();
  }

  void _changed() {
    if (!mounted) return;
    final snapshot = _snapshot;
    final buffering = snapshot?.transportState.isBuffering == true;
    if (_wasBuffering && !buffering && !_chrome.hasFocus) {
      _armChromeHide();
    }
    _wasBuffering = buffering;
    if (!_usableReported && snapshot?.transportState.hasVideo == true) {
      _usableReported = true;
      final callback = widget.onUsableVideo;
      if (callback != null) {
        unawaited(
          Future<void>.sync(() => callback(_handoff)).catchError((_) {}),
        );
      }
    }
    final failed = snapshot?.phase == PlaybackSessionPhase.failed;
    if (failed && !_wasFailed) {
      _resetVariants();
    }
    _wasFailed = failed;
    if (failed) {
      _loadVariants();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _failed) _recoveryPrimary.requestFocus();
      });
    }
    setState(() {});
  }

  void _loadVariants() {
    final port = widget.variantPort;
    if (port == null || _variantRequestIssued) return;
    _variantRequestIssued = true;
    final generation = ++_variantGeneration;
    unawaited(() async {
      List<PlaybackVariantCandidate> values;
      try {
        values = await port.loadExactVariants(_handoff);
      } catch (_) {
        values = const [];
      }
      if (mounted && generation == _variantGeneration && _failed) {
        setState(() => _variants = values);
      }
    }());
  }

  void _resetVariants() {
    _variantGeneration += 1;
    _variantRequestIssued = false;
    _variants = const [];
  }

  void _showChrome() {
    if (!mounted) return;
    setState(() => _chromeVisible = true);
    _armChromeHide();
  }

  void _armChromeHide() {
    _chromeTimer?.cancel();
    _chromeTimer = Timer(_chromeDuration, () {
      if (!mounted ||
          _chrome.hasFocus ||
          _tracksOpen ||
          _failed ||
          _state.isBuffering ||
          !_state.hasVideo) {
        return;
      }
      setState(() => _chromeVisible = false);
    });
  }

  Future<void> _backOut() async {
    if (_tracksOpen) {
      _closeTracks();
      return;
    }
    if (_leaving) return;
    if (await _fullscreen.isFullscreen) {
      await _fullscreen.setFullscreen(false);
      return;
    }
    _leaving = true;
    final id = _sessionId;
    if (id != null) await _manager.stop(id);
    if (mounted) await widget.onExit();
  }

  Future<void> _openSettings() async {
    if (_leaving) return;
    _leaving = true;
    final id = _sessionId;
    if (id != null) await _manager.stop(id);
    if (mounted) await (widget.onOpenSettings?.call() ?? widget.onExit());
  }

  Future<void> _retry() async {
    final id = _sessionId;
    if (id == null) return _startLegacy();
    setState(() {
      _detailsVisible = false;
      _resetVariants();
      _message = null;
    });
    await _manager.retry(id);
  }

  Future<void> _tryVariant(PlaybackVariantCandidate value) async {
    final prior = _sessionId;
    if (prior == null) return;
    final result = await _manager.start(value.handoff, replaceSessionId: prior);
    if (!mounted) return;
    switch (result) {
      case PlaybackStarted(:final sessionId):
      case PlaybackStartFailed(:final sessionId):
        setState(() {
          _sessionId = sessionId;
          _handoff = value.handoff;
          _usableReported = false;
          _resetVariants();
        });
      case PlaybackBlocked():
        setState(() => _message = 'That source variant is unavailable.');
    }
  }

  Future<void> _togglePlay() async {
    final id = _sessionId;
    if (id == null) return;
    _showChrome();
    await (_state.isPlaying ? _manager.pause(id) : _manager.play(id));
  }

  Future<void> _seek(Duration value) async {
    final id = _sessionId;
    if (id != null && !_live) await _manager.seek(id, value);
  }

  Future<void> _startOver() async {
    final id = _sessionId;
    if (id == null || _live) return;
    final outcome = await _manager.startOverWithOutcome(id);
    if (!mounted) return;
    setState(() {
      _message = !outcome.seekSucceeded
          ? 'Could not start over.'
          : !outcome.progressSaved
          ? 'Started over. Progress could not be saved.'
          : 'Started over.';
    });
  }

  Future<void> _selectTrack(bool audio, String trackId) async {
    final id = _sessionId;
    if (id == null || _trackBusy) return;
    setState(() => _trackBusy = true);
    final changed = audio
        ? await _manager.selectAudioTrack(id, trackId)
        : await _manager.selectSubtitleTrack(id, trackId);
    if (mounted) {
      setState(() {
        _trackBusy = false;
        _message = changed ? null : 'Track could not be changed.';
      });
    }
  }

  void _openTracks() {
    setState(() {
      _tracksOpen = true;
      _message = null;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _tracksOpen) _firstTrack.requestFocus();
    });
  }

  void _closeTracks() {
    setState(() => _tracksOpen = false);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _tracks.requestFocus();
    });
  }

  KeyEventResult _stageKey(FocusNode _, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.escape ||
        event.logicalKey == LogicalKeyboardKey.browserBack) {
      unawaited(_backOut());
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
      _showChrome();
      _back.requestFocus();
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.enter ||
        event.logicalKey == LogicalKeyboardKey.select) {
      _showChrome();
      (_failed ? _recoveryPrimary : _play).requestFocus();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final snapshot = _snapshot;
    final video = _sessionId == null
        ? const SizedBox.expand()
        : _manager.videoFor(_sessionId!);
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () =>
            unawaited(_backOut()),
        const SingleActivator(LogicalKeyboardKey.browserBack): () =>
            unawaited(_backOut()),
      },
      child: FocusTraversalGroup(
        child: MouseRegion(
          onHover: (_) => _showChrome(),
          child: Focus(
            focusNode: _stage,
            autofocus: true,
            onKeyEvent: _stageKey,
            child: Material(
              color: _graphite,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  RepaintBoundary(
                    key: const ValueKey('player-video-stage'),
                    child: video,
                  ),
                  if (_state.isBuffering && _state.hasVideo)
                    const Center(child: _StatusMark('Buffering')),
                  if (_starting)
                    Center(child: _StatusMark('Starting ${_handoff.title}')),
                  if (_chromeVisible || _starting || _failed || _tracksOpen)
                    FocusScope(
                      node: _chrome,
                      child: Stack(
                        children: [
                          _IdentityBand(
                            handoff: _handoff,
                            focusNode: _back,
                            onBack: () => unawaited(_backOut()),
                            onDown: _returnToStage,
                          ),
                          if (snapshot != null &&
                              (snapshot.resume.didResume ||
                                  snapshot.resume.loadFailed ||
                                  snapshot.progressSaveFailed ||
                                  _message != null))
                            Positioned(
                              top: 58,
                              left: 0,
                              right: 0,
                              child: _Notice(
                                _message ??
                                    (snapshot.progressSaveFailed
                                        ? 'Progress could not be saved.'
                                        : snapshot.resume.loadFailed
                                        ? 'Saved progress could not be loaded. Playing from the start.'
                                        : 'Resumed at ${_time(snapshot.resume.appliedPosition)}.'),
                              ),
                            ),
                          Align(
                            alignment: Alignment.bottomCenter,
                            child: _failed
                                ? _FailureDeck(
                                    failure:
                                        snapshot?.failure ??
                                        PlaybackSessionFailure.unavailable,
                                    handoff: _handoff,
                                    attempts: snapshot?.metrics.attempts ?? 0,
                                    detailsVisible: _detailsVisible,
                                    primaryFocus: _recoveryPrimary,
                                    backFocus: _recoveryBack,
                                    detailsFocus: _recoveryDetails,
                                    variants: _variants,
                                    message: _message,
                                    onDetails: () => setState(
                                      () => _detailsVisible = !_detailsVisible,
                                    ),
                                    onPrimary:
                                        snapshot?.failure ==
                                            PlaybackSessionFailure
                                                .credentialsUnavailable
                                        ? () => unawaited(_openSettings())
                                        : () => unawaited(_retry()),
                                    onBack: () => unawaited(_backOut()),
                                    onVariant: (value) =>
                                        unawaited(_tryVariant(value)),
                                    onDown: _returnToStage,
                                  )
                                : _BroadcastDeck(
                                    live: _live,
                                    state: _state,
                                    audible: snapshot?.isAudible == true,
                                    nodes: _DeckNodes(
                                      back10: _back10,
                                      play: _play,
                                      forward10: _forward10,
                                      mute: _mute,
                                      timeline: _timeline,
                                      volume: _volume,
                                      tracks: _tracks,
                                      startOver: _startOverNode,
                                      pip: _pip,
                                      add: _add,
                                      fullscreen: _fullscreenNode,
                                    ),
                                    onPlay: () => unawaited(_togglePlay()),
                                    onSeek: (value) => unawaited(_seek(value)),
                                    onMute: () {
                                      final id = _sessionId;
                                      if (id != null) {
                                        unawaited(
                                          _manager.setMuted(
                                            id,
                                            snapshot?.isAudible == true,
                                          ),
                                        );
                                      }
                                    },
                                    onVolume: (value) {
                                      final id = _sessionId;
                                      if (id != null) {
                                        unawaited(
                                          _manager.setVolume(id, value),
                                        );
                                      }
                                    },
                                    onTracks: _openTracks,
                                    onStartOver: () => unawaited(_startOver()),
                                    onPip: widget.onEnterPip == null
                                        ? null
                                        : () => unawaited(
                                            Future<void>.sync(
                                              widget.onEnterPip!,
                                            ),
                                          ),
                                    onAdd: !_live || widget.onAddChannel == null
                                        ? null
                                        : () => unawaited(
                                            Future<void>.sync(
                                              widget.onAddChannel!,
                                            ),
                                          ),
                                    onFullscreen: () => unawaited(() async {
                                      await _fullscreen.setFullscreen(
                                        !(await _fullscreen.isFullscreen),
                                      );
                                    }()),
                                    onBack: () => unawaited(_backOut()),
                                    onDown: _returnToStage,
                                  ),
                          ),
                          if (_tracksOpen)
                            Positioned.fill(
                              child: _TracksLedger(
                                scope: _tracksScope,
                                firstFocus: _firstTrack,
                                doneFocus: _trackDone,
                                state: _state,
                                busy: _trackBusy,
                                message: _message,
                                onDone: _closeTracks,
                                onAudio: (id) =>
                                    unawaited(_selectTrack(true, id)),
                                onSubtitle: (id) =>
                                    unawaited(_selectTrack(false, id)),
                              ),
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
    );
  }

  void _returnToStage() {
    _stage.requestFocus();
    setState(() => _chromeVisible = false);
  }
}

class _DeckNodes {
  const _DeckNodes({
    required this.back10,
    required this.play,
    required this.forward10,
    required this.mute,
    required this.timeline,
    required this.volume,
    required this.tracks,
    required this.startOver,
    required this.pip,
    required this.add,
    required this.fullscreen,
  });
  final FocusNode back10,
      play,
      forward10,
      mute,
      timeline,
      volume,
      tracks,
      startOver,
      pip,
      add,
      fullscreen;
}

class _StatusMark extends StatelessWidget {
  const _StatusMark(this.label);
  final String label;
  @override
  Widget build(BuildContext context) => Semantics(
    liveRegion: true,
    label: label,
    excludeSemantics: true,
    child: SizedBox(
      key: const ValueKey('player-status-mark'),
      width: (MediaQuery.sizeOf(context).width - 48).clamp(0, 520),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const SizedBox.square(
            dimension: 16,
            child: CircularProgressIndicator(strokeWidth: 2, color: _amber),
          ),
          const SizedBox(width: 10),
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: _warmWhite,
                fontSize: 15,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    ),
  );
}

class _Notice extends StatelessWidget {
  const _Notice(this.message);
  final String message;
  @override
  Widget build(BuildContext context) => Semantics(
    liveRegion: true,
    child: Container(
      key: const ValueKey('player-playback-notice'),
      color: _surface,
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
      child: Text(
        message,
        style: const TextStyle(color: _quietText, fontSize: 13),
      ),
    ),
  );
}

class _IdentityBand extends StatelessWidget {
  const _IdentityBand({
    required this.handoff,
    required this.focusNode,
    required this.onBack,
    required this.onDown,
  });
  final PlaybackHandoff handoff;
  final FocusNode focusNode;
  final VoidCallback onBack, onDown;
  @override
  Widget build(BuildContext context) => SafeArea(
    bottom: false,
    child: Container(
      height: 58,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: const BoxDecoration(
        color: _surface,
        border: Border(bottom: BorderSide(color: _line)),
      ),
      child: Row(
        children: [
          _DeckAction(
            key: const ValueKey('player-back'),
            focusNode: focusNode,
            icon: Icons.arrow_back,
            label: 'Back',
            onPressed: onBack,
            onDown: onDown,
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Text(
              handoff.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: _warmWhite,
                fontSize: 18,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          Text(
            handoff.mediaKind.name.toUpperCase(),
            style: const TextStyle(
              color: _quietText,
              fontSize: 12,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    ),
  );
}

class _BroadcastDeck extends StatelessWidget {
  const _BroadcastDeck({
    required this.live,
    required this.state,
    required this.audible,
    required this.nodes,
    required this.onPlay,
    required this.onSeek,
    required this.onMute,
    required this.onVolume,
    required this.onTracks,
    required this.onStartOver,
    required this.onPip,
    required this.onAdd,
    required this.onFullscreen,
    required this.onBack,
    required this.onDown,
  });
  final bool live, audible;
  final PlaybackTransportState state;
  final _DeckNodes nodes;
  final VoidCallback onPlay,
      onMute,
      onTracks,
      onStartOver,
      onFullscreen,
      onBack,
      onDown;
  final VoidCallback? onPip, onAdd;
  final ValueChanged<Duration> onSeek;
  final ValueChanged<double> onVolume;

  Widget _primary() => Row(
    key: const ValueKey('player-primary-controls'),
    mainAxisSize: MainAxisSize.min,
    children: [
      if (!live) ...[
        _DeckAction(
          focusNode: nodes.back10,
          icon: Icons.replay_10,
          label: 'Back 10 seconds',
          onPressed: () => onSeek(_boundedSeek(state, -10)),
          onDown: onDown,
        ),
        const SizedBox(width: 8),
      ],
      _DeckAction(
        key: const ValueKey('player-play-pause'),
        focusNode: nodes.play,
        icon: state.isPlaying ? Icons.pause : Icons.play_arrow,
        label: state.isPlaying ? 'Pause' : 'Play',
        onPressed: onPlay,
        onDown: onDown,
      ),
      if (!live) ...[
        const SizedBox(width: 8),
        _DeckAction(
          focusNode: nodes.forward10,
          icon: Icons.forward_10,
          label: 'Forward 10 seconds',
          onPressed: () => onSeek(_boundedSeek(state, 10)),
          onDown: onDown,
        ),
      ],
    ],
  );

  Widget _utilities() => Row(
    key: const ValueKey('player-utility-controls'),
    mainAxisSize: MainAxisSize.min,
    children: [
      _DeckAction(
        focusNode: nodes.mute,
        icon: audible ? Icons.volume_up : Icons.volume_off,
        label: audible ? 'Mute' : 'Unmute',
        onPressed: onMute,
        onDown: onDown,
      ),
      const SizedBox(width: 8),
      SizedBox(
        width: 112,
        child: _Volume(
          focusNode: nodes.volume,
          value: state.volume,
          onChanged: onVolume,
          onDown: onDown,
        ),
      ),
      const SizedBox(width: 8),
      _DeckAction(
        key: const ValueKey('player-fullscreen'),
        focusNode: nodes.fullscreen,
        icon: Icons.fullscreen,
        label: 'Fullscreen',
        onPressed: onFullscreen,
        onBack: onBack,
        onDown: onDown,
      ),
    ],
  );

  List<Widget> _secondary() => [
    if (!live)
      _DeckAction(
        focusNode: nodes.startOver,
        icon: Icons.restart_alt,
        label: 'Start over',
        onPressed: onStartOver,
        onDown: onDown,
      ),
    _DeckAction(
      focusNode: nodes.tracks,
      icon: Icons.audiotrack,
      label: 'Tracks',
      onPressed: onTracks,
      onDown: onDown,
    ),
    if (onPip != null)
      _DeckAction(
        focusNode: nodes.pip,
        icon: Icons.picture_in_picture_alt,
        label: 'Picture in picture',
        onPressed: onPip!,
        onDown: onDown,
      ),
    if (onAdd != null)
      _DeckAction(
        focusNode: nodes.add,
        icon: Icons.view_week_outlined,
        label: 'Add channel',
        onPressed: onAdd!,
        onDown: onDown,
      ),
  ];

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) => SafeArea(
      top: false,
      child: Container(
        key: const ValueKey('player-broadcast-deck'),
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
        decoration: const BoxDecoration(
          color: _surface,
          border: Border(top: BorderSide(color: _line)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (!live) ...[
              _Timeline(
                focusNode: nodes.timeline,
                position: state.position,
                duration: state.duration,
                onChanged: onSeek,
                onDown: onDown,
              ),
              const SizedBox(height: 8),
            ],
            Wrap(spacing: 8, runSpacing: 8, children: _secondary()),
            const SizedBox(height: 8),
            if (constraints.maxWidth >= 1100)
              Row(
                children: [
                  const Expanded(
                    key: ValueKey('player-left-balance-zone'),
                    child: SizedBox.shrink(),
                  ),
                  _primary(),
                  Expanded(
                    child: Align(
                      alignment: Alignment.centerRight,
                      child: _utilities(),
                    ),
                  ),
                ],
              )
            else
              Row(children: [_primary(), const Spacer(), _utilities()]),
          ],
        ),
      ),
    ),
  );
}

Duration _boundedSeek(PlaybackTransportState state, int seconds) {
  final target = state.position + Duration(seconds: seconds);
  if (target < Duration.zero) return Duration.zero;
  if (state.duration > Duration.zero && target > state.duration) {
    return state.duration;
  }
  return target;
}

class _TracksLedger extends StatelessWidget {
  const _TracksLedger({
    required this.scope,
    required this.firstFocus,
    required this.doneFocus,
    required this.state,
    required this.busy,
    required this.message,
    required this.onDone,
    required this.onAudio,
    required this.onSubtitle,
  });
  final FocusScopeNode scope;
  final FocusNode firstFocus, doneFocus;
  final PlaybackTransportState state;
  final bool busy;
  final String? message;
  final VoidCallback onDone;
  final ValueChanged<String> onAudio, onSubtitle;

  @override
  Widget build(BuildContext context) {
    final audio = [
      if (!state.audioTracks.any((value) => value.id == 'auto'))
        const PlaybackMediaTrack(id: 'auto', label: 'Automatic'),
      ...state.audioTracks,
    ];
    final subtitles = [
      if (!state.subtitleTracks.any((value) => value.id == 'no'))
        const PlaybackMediaTrack(id: 'no', label: 'Off'),
      ...state.subtitleTracks,
    ];
    return ColoredBox(
      color: const Color(0xC9111212),
      child: Align(
        alignment: Alignment.bottomCenter,
        child: FocusScope(
          node: scope,
          child: FocusTraversalGroup(
            policy: WidgetOrderTraversalPolicy(),
            child: Container(
              key: const ValueKey('player-tracks-ledger'),
              width: double.infinity,
              constraints: const BoxConstraints(maxHeight: 420),
              padding: const EdgeInsets.all(18),
              decoration: const BoxDecoration(
                color: _surface,
                border: Border(top: BorderSide(color: _line)),
              ),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Expanded(
                          child: Text(
                            'Tracks',
                            style: TextStyle(
                              color: _warmWhite,
                              fontSize: 20,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        _TextAction(
                          focusNode: doneFocus,
                          label: 'Done',
                          onPressed: onDone,
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    const Text('Audio', style: _ledgerHeading),
                    if (state.audioTracks.isEmpty)
                      const Padding(
                        padding: EdgeInsets.only(top: 8),
                        child: Text(
                          'No alternate audio tracks',
                          style: _ledgerEmpty,
                        ),
                      ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (var index = 0; index < audio.length; index++)
                          _TextAction(
                            focusNode: index == 0 ? firstFocus : null,
                            label: _trackLabel(audio[index]),
                            primary:
                                audio[index].id == state.selectedAudioTrackId,
                            onPressed: busy
                                ? null
                                : () => onAudio(audio[index].id),
                          ),
                      ],
                    ),
                    const SizedBox(height: 18),
                    const Text('Subtitles', style: _ledgerHeading),
                    if (state.subtitleTracks.isEmpty)
                      const Padding(
                        padding: EdgeInsets.only(top: 8),
                        child: Text(
                          'No subtitle tracks reported',
                          style: _ledgerEmpty,
                        ),
                      ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final track in subtitles)
                          _TextAction(
                            label: _trackLabel(track),
                            primary:
                                track.id == state.selectedSubtitleTrackId ||
                                (track.id == 'no' &&
                                    state.selectedSubtitleTrackId == null),
                            onPressed: busy ? null : () => onSubtitle(track.id),
                          ),
                      ],
                    ),
                    if (message != null) ...[
                      const SizedBox(height: 12),
                      Text(
                        message!,
                        key: const ValueKey('player-track-message'),
                        style: _ledgerEmpty,
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

const _ledgerHeading = TextStyle(
  color: _warmWhite,
  fontSize: 14,
  fontWeight: FontWeight.w700,
);
const _ledgerEmpty = TextStyle(color: _quietText, fontSize: 13);

String _trackLabel(PlaybackMediaTrack track) =>
    track.language == null || track.language == track.label
    ? track.label
    : '${track.label} · ${track.language}';

class _FailureDeck extends StatelessWidget {
  const _FailureDeck({
    required this.failure,
    required this.handoff,
    required this.attempts,
    required this.detailsVisible,
    required this.primaryFocus,
    required this.backFocus,
    required this.detailsFocus,
    required this.variants,
    required this.message,
    required this.onDetails,
    required this.onPrimary,
    required this.onBack,
    required this.onVariant,
    required this.onDown,
  });
  final PlaybackSessionFailure failure;
  final PlaybackHandoff handoff;
  final int attempts;
  final bool detailsVisible;
  final FocusNode primaryFocus, backFocus, detailsFocus;
  final List<PlaybackVariantCandidate> variants;
  final String? message;
  final VoidCallback onDetails, onPrimary, onBack, onDown;
  final ValueChanged<PlaybackVariantCandidate> onVariant;

  String get failureMessage => switch (failure) {
    PlaybackSessionFailure.credentialsUnavailable =>
      'This source needs its saved account details restored in Settings.',
    PlaybackSessionFailure.unavailable => 'Playback is unavailable right now.',
    PlaybackSessionFailure.timedOut => 'Playback did not start in time.',
  };

  @override
  Widget build(BuildContext context) => SafeArea(
    top: false,
    child: Container(
      key: const ValueKey('player-failure-deck'),
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 18),
      decoration: const BoxDecoration(
        color: _surface,
        border: Border(top: BorderSide(color: _line)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            failureMessage,
            style: const TextStyle(
              color: _warmWhite,
              fontSize: 16,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              _TextAction(
                key: const ValueKey('player-recovery-primary'),
                focusRingKey: const ValueKey(
                  'player-recovery-primary-focus-ring',
                ),
                focusNode: primaryFocus,
                primary: true,
                label: failure == PlaybackSessionFailure.credentialsUnavailable
                    ? 'Open Settings'
                    : 'Retry',
                onPressed: onPrimary,
                onDown: onDown,
                onLeft: detailsFocus.requestFocus,
                onRight: backFocus.requestFocus,
              ),
              _TextAction(
                key: const ValueKey('player-recovery-back'),
                focusRingKey: const ValueKey('player-recovery-back-focus-ring'),
                focusNode: backFocus,
                label: 'Back',
                onPressed: onBack,
                onDown: onDown,
                onLeft: primaryFocus.requestFocus,
                onRight: detailsFocus.requestFocus,
              ),
              _TextAction(
                key: const ValueKey('player-recovery-details'),
                focusRingKey: const ValueKey(
                  'player-recovery-details-focus-ring',
                ),
                focusNode: detailsFocus,
                label: detailsVisible
                    ? 'Hide technical details'
                    : 'Technical details',
                onPressed: onDetails,
                onDown: onDown,
                onLeft: backFocus.requestFocus,
                onRight: primaryFocus.requestFocus,
              ),
              for (final variant in variants)
                _TextAction(
                  label: 'Try ${variant.label}',
                  onPressed: () => onVariant(variant),
                  onDown: onDown,
                ),
            ],
          ),
          if (message != null) ...[
            const SizedBox(height: 10),
            Text(message!, style: _ledgerEmpty),
          ],
          if (detailsVisible)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Text(
                'Category: ${failure.name}\nMedia: ${handoff.mediaKind.name}\nAttempts: $attempts\nLocal time: ${_localTime()}',
                key: const ValueKey('player-technical-details'),
                style: const TextStyle(
                  color: _quietText,
                  fontSize: 13,
                  height: 1.4,
                ),
              ),
            ),
        ],
      ),
    ),
  );
}

class _Timeline extends StatefulWidget {
  const _Timeline({
    required this.focusNode,
    required this.position,
    required this.duration,
    required this.onChanged,
    required this.onDown,
  });
  final FocusNode focusNode;
  final Duration position, duration;
  final ValueChanged<Duration> onChanged;
  final VoidCallback onDown;
  @override
  State<_Timeline> createState() => _TimelineState();
}

class _TimelineState extends State<_Timeline> {
  bool focused = false;
  @override
  Widget build(BuildContext context) {
    final maximum = widget.duration.inMilliseconds.toDouble();
    final value = maximum <= 0
        ? 0.0
        : widget.position.inMilliseconds.clamp(0, maximum).toDouble();
    return Focus(
      focusNode: widget.focusNode,
      onFocusChange: (value) => setState(() => focused = value),
      onKeyEvent: (_, event) {
        if (event is! KeyDownEvent) return KeyEventResult.ignored;
        if (event.logicalKey == LogicalKeyboardKey.arrowLeft ||
            event.logicalKey == LogicalKeyboardKey.arrowRight) {
          final delta = event.logicalKey == LogicalKeyboardKey.arrowLeft
              ? -10000
              : 10000;
          widget.onChanged(
            Duration(milliseconds: (value + delta).clamp(0, maximum).round()),
          );
          return KeyEventResult.handled;
        }
        if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
          widget.onDown();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: Semantics(
        slider: true,
        label: 'Playback timeline',
        value: '${_time(widget.position)} of ${_time(widget.duration)}',
        child: Container(
          key: const ValueKey('player-timeline'),
          height: 28,
          decoration: BoxDecoration(
            border: Border.all(
              color: focused ? _amber : _line,
              width: focused ? 2 : 1,
            ),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Row(
            children: [
              SizedBox(
                width: 58,
                child: Center(
                  child: Text(_time(widget.position), style: _ledgerEmpty),
                ),
              ),
              Expanded(
                child: Slider(
                  value: value,
                  max: maximum <= 0 ? 1 : maximum,
                  onChanged: maximum <= 0
                      ? null
                      : (value) => widget.onChanged(
                          Duration(milliseconds: value.round()),
                        ),
                  activeColor: _amber,
                  inactiveColor: _raised,
                ),
              ),
              SizedBox(
                width: 58,
                child: Center(
                  child: Text(_time(widget.duration), style: _ledgerEmpty),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Volume extends StatefulWidget {
  const _Volume({
    required this.focusNode,
    required this.value,
    required this.onChanged,
    required this.onDown,
  });
  final FocusNode focusNode;
  final double value;
  final ValueChanged<double> onChanged;
  final VoidCallback onDown;
  @override
  State<_Volume> createState() => _VolumeState();
}

class _VolumeState extends State<_Volume> {
  bool focused = false;
  @override
  Widget build(BuildContext context) => Focus(
    focusNode: widget.focusNode,
    onFocusChange: (value) => setState(() => focused = value),
    onKeyEvent: (_, event) {
      if (event is! KeyDownEvent) return KeyEventResult.ignored;
      if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
        widget.onDown();
        return KeyEventResult.handled;
      }
      if (event.logicalKey == LogicalKeyboardKey.arrowLeft ||
          event.logicalKey == LogicalKeyboardKey.arrowRight) {
        widget.onChanged(
          (widget.value +
                  (event.logicalKey == LogicalKeyboardKey.arrowLeft ? -5 : 5))
              .clamp(0, 100),
        );
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    },
    child: Semantics(
      slider: true,
      label: 'Volume',
      value: '${widget.value.round()} percent',
      child: Container(
        height: 44,
        decoration: BoxDecoration(
          border: Border.all(
            color: focused ? _amber : _line,
            width: focused ? 2 : 1,
          ),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Slider(
          value: widget.value.clamp(0, 100),
          max: 100,
          onChanged: widget.onChanged,
          activeColor: _amber,
          inactiveColor: _raised,
        ),
      ),
    ),
  );
}

class _DeckAction extends StatefulWidget {
  const _DeckAction({
    super.key,
    required this.icon,
    required this.label,
    required this.onPressed,
    this.focusNode,
    this.onBack,
    this.onDown,
  });
  final IconData icon;
  final String label;
  final VoidCallback onPressed;
  final FocusNode? focusNode;
  final VoidCallback? onBack, onDown;
  @override
  State<_DeckAction> createState() => _DeckActionState();
}

class _DeckActionState extends State<_DeckAction> {
  bool focused = false;
  @override
  Widget build(BuildContext context) => Focus(
    focusNode: widget.focusNode,
    onFocusChange: (value) => setState(() => focused = value),
    onKeyEvent: (_, event) {
      if (event is! KeyDownEvent) return KeyEventResult.ignored;
      if ((event.logicalKey == LogicalKeyboardKey.escape ||
              event.logicalKey == LogicalKeyboardKey.browserBack) &&
          widget.onBack != null) {
        widget.onBack!();
        return KeyEventResult.handled;
      }
      if (event.logicalKey == LogicalKeyboardKey.arrowDown &&
          widget.onDown != null) {
        widget.onDown!();
        return KeyEventResult.handled;
      }
      if (event.logicalKey == LogicalKeyboardKey.enter ||
          event.logicalKey == LogicalKeyboardKey.select) {
        widget.onPressed();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    },
    child: Tooltip(
      message: widget.label,
      child: Semantics(
        button: true,
        label: widget.label,
        child: GestureDetector(
          onTap: () {
            widget.focusNode?.requestFocus();
            widget.onPressed();
          },
          child: Container(
            width: 44,
            height: 44,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: focused ? _raised : Colors.transparent,
              border: Border.all(
                color: focused ? _amber : _line,
                width: focused ? 2 : 1,
              ),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Icon(widget.icon, color: _warmWhite, size: 22),
          ),
        ),
      ),
    ),
  );
}

class _TextAction extends StatefulWidget {
  const _TextAction({
    super.key,
    required this.label,
    required this.onPressed,
    this.focusNode,
    this.primary = false,
    this.onDown,
    this.focusRingKey,
    this.onLeft,
    this.onRight,
  });
  final String label;
  final VoidCallback? onPressed;
  final FocusNode? focusNode;
  final bool primary;
  final VoidCallback? onDown;
  final Key? focusRingKey;
  final VoidCallback? onLeft, onRight;
  @override
  State<_TextAction> createState() => _TextActionState();
}

class _TextActionState extends State<_TextAction> {
  bool focused = false;
  @override
  Widget build(BuildContext context) => Focus(
    focusNode: widget.focusNode,
    canRequestFocus: widget.onPressed != null,
    onFocusChange: (value) => setState(() => focused = value),
    onKeyEvent: (_, event) {
      if (event is! KeyDownEvent) return KeyEventResult.ignored;
      if (event.logicalKey == LogicalKeyboardKey.arrowDown &&
          widget.onDown != null) {
        widget.onDown!();
        return KeyEventResult.handled;
      }
      if (event.logicalKey == LogicalKeyboardKey.arrowLeft &&
          widget.onLeft != null) {
        widget.onLeft!();
        return KeyEventResult.handled;
      }
      if (event.logicalKey == LogicalKeyboardKey.arrowRight &&
          widget.onRight != null) {
        widget.onRight!();
        return KeyEventResult.handled;
      }
      if ((event.logicalKey == LogicalKeyboardKey.enter ||
              event.logicalKey == LogicalKeyboardKey.select) &&
          widget.onPressed != null) {
        widget.onPressed!();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    },
    child: Semantics(
      button: true,
      enabled: widget.onPressed != null,
      label: widget.label,
      excludeSemantics: true,
      child: DecoratedBox(
        key: widget.focusRingKey,
        decoration: BoxDecoration(
          border: Border.all(
            color: focused ? _amber : Colors.transparent,
            width: 2,
          ),
          borderRadius: BorderRadius.circular(6),
        ),
        child: GestureDetector(
          onTap: widget.onPressed,
          child: Container(
            constraints: const BoxConstraints(minHeight: 40, minWidth: 92),
            margin: const EdgeInsets.all(2),
            padding: const EdgeInsets.symmetric(horizontal: 14),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: widget.primary ? _amber : _raised,
              border: Border.all(color: _line),
              borderRadius: BorderRadius.circular(3),
            ),
            child: Text(
              widget.label,
              style: TextStyle(
                color: widget.primary ? _amberInk : _warmWhite,
                fontSize: 14,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

String _time(Duration value) {
  final minutes = value.inMinutes.remainder(60).toString().padLeft(2, '0');
  return '${value.inHours}:$minutes:${value.inSeconds.remainder(60).toString().padLeft(2, '0')}';
}

String _localTime() {
  final now = DateTime.now();
  return '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';
}
