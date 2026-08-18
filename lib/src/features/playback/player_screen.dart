// THESIS: Playback is one calm Broadcast Deck over the user's own video, refusing
// floating control cards, provider branding, and a persistent application rail.
// OWN-WORLD: Solid graphite bands, warm-white text, neutral seams, and crisp
// signal-amber focus extend Quiet Broadcast into the viewing stage.
// STORY: A deliberate handoff starts once, yields to unobstructed video, and
// returns safely to the exact catalog context when the user backs out.
// FIRST VIEWPORT: Contained video fills the client; a thin identity band sits
// above it and one full-width transport deck anchors the lower edge.
// FORM: Broadcast Deck (approved composition A), seed quiet-broadcast-player-a.
// FINISH: unreviewed and undocumented is unfinished; this build ends with the finish review, the verdict, and DESIGN.md

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

import '../browse/playback_handoff.dart';
import '../sources/credential_store.dart';
import '../sources/source_catalog_database.dart';
import 'playback_transport.dart';

const _graphite = Color(0xFF111212);
const _surface = Color(0xFF191A1A);
const _raised = Color(0xFF222321);
const _line = Color(0xFF343534);
const _warmWhite = Color(0xFFF4F0E7);
const _quietText = Color(0xFFAAA8A2);
const _amber = Color(0xFFFFB347);
const _amberInk = Color(0xFF17120A);

const productionPlayerStartupDeadline = Duration(seconds: 20);
const _chromeDuration = Duration(seconds: 4);

typedef PlaybackTransportFactory = PlaybackTransport Function();

class _PlaybackTarget {
  const _PlaybackTarget(this.uri, this.httpHeaders);

  final Uri uri;
  final Map<String, String> httpHeaders;
}

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
          rethrow;
        }
      } else {
        await windowManager.setFullScreen(false);
        await windowManager.setTitleBarStyle(TitleBarStyle.normal);
      }
    } catch (_) {
      // Fullscreen is an optional window affordance; playback remains usable.
    }
  }
}

enum PlaybackFailureKind { credentialsUnavailable, unavailable, timedOut }

@visibleForTesting
Future<PlaybackFailureKind?> waitForPlaybackStartup(
  Future<PlaybackFailureKind?> outcome,
  Duration deadline,
) => outcome.timeout(deadline, onTimeout: () => PlaybackFailureKind.timedOut);

extension PlaybackFailureCopy on PlaybackFailureKind {
  String get message => switch (this) {
    PlaybackFailureKind.credentialsUnavailable =>
      'This source needs its saved account details restored in Settings.',
    PlaybackFailureKind.unavailable => 'Playback is unavailable right now.',
    PlaybackFailureKind.timedOut => 'Playback did not start in time.',
  };
}

/// Resolves an Xtream stream only at the moment a transport is opened.
/// Nothing returned from this method belongs in logs, diagnostics, or widget
/// state; callers hold it only long enough to call [PlaybackTransport.open].
Uri resolveXtreamPlaybackUri({
  required XtreamPlaybackHandoff handoff,
  required StoredCredential credential,
}) {
  final server = credential.serverUrl?.trim();
  if (server == null || server.isEmpty) throw const FormatException();
  final endpoint = Uri.parse(
    server.contains('://') ? server : 'https://$server',
  );
  if ((endpoint.scheme != 'http' && endpoint.scheme != 'https') ||
      endpoint.host.isEmpty ||
      credential.username.trim().isEmpty ||
      credential.password.isEmpty) {
    throw const FormatException();
  }
  final mediaType = switch (handoff) {
    LivePlaybackHandoff() => 'live',
    MoviePlaybackHandoff() => 'movie',
    EpisodePlaybackHandoff() => 'series',
  };
  final extension = handoff.extension.trim().isEmpty
      ? (handoff is LivePlaybackHandoff ? 'ts' : 'mp4')
      : handoff.extension.trim();
  final baseSegments = endpoint.pathSegments
      .where((segment) => segment.isNotEmpty)
      .toList();
  if (baseSegments.lastOrNull == 'player_api.php') baseSegments.removeLast();
  return endpoint.replace(
    pathSegments: [
      ...baseSegments,
      mediaType,
      credential.username,
      credential.password,
      '${handoff.providerItemId}.$extension',
    ],
    query: null,
    fragment: null,
  );
}

class PlayerScreen extends StatefulWidget {
  const PlayerScreen({
    super.key,
    required this.handoff,
    required this.source,
    required this.onExit,
    this.onOpenSettings,
    this.credentialStore,
    this.sourceResolver,
    this.transportFactory,
    this.fullscreenPort,
    this.startupDeadline = productionPlayerStartupDeadline,
  });

  final PlaybackHandoff handoff;
  final PersistedSource? source;
  final FutureOr<void> Function() onExit;
  final FutureOr<void> Function()? onOpenSettings;
  final CredentialStore? credentialStore;

  /// Resolves the handoff's exact source when its result originated outside
  /// the shell's current source view. When supplied, it is authoritative.
  final FutureOr<PersistedSource?> Function(String sourceId)? sourceResolver;
  final PlaybackTransportFactory? transportFactory;
  final FullscreenPort? fullscreenPort;
  final Duration startupDeadline;

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> {
  final _stageFocus = FocusNode(debugLabel: 'player video stage');
  final _chromeFocus = FocusScopeNode(debugLabel: 'player chrome controls');
  final _backFocus = FocusNode(debugLabel: 'player back');
  final _backTenFocus = FocusNode(debugLabel: 'player back 10 seconds');
  final _playFocus = FocusNode(debugLabel: 'player play pause');
  final _forwardTenFocus = FocusNode(debugLabel: 'player forward 10 seconds');
  final _muteFocus = FocusNode(debugLabel: 'player mute');
  final _timelineFocus = FocusNode(debugLabel: 'player timeline');
  final _volumeFocus = FocusNode(debugLabel: 'player volume');
  final _fullscreenFocus = FocusNode(debugLabel: 'player fullscreen');
  final _recoveryPrimaryFocus = FocusNode(
    debugLabel: 'player recovery primary',
  );
  final _recoveryBackFocus = FocusNode(debugLabel: 'player recovery back');
  final _recoveryDetailsFocus = FocusNode(
    debugLabel: 'player recovery technical details',
  );

  PlaybackTransport? _transport;
  StreamSubscription<PlaybackTransportState>? _states;
  Future<void>? _teardown;
  Timer? _chromeTimer;
  PlaybackTransportState _state = const PlaybackTransportState();
  PlaybackFailureKind? _failure;
  int _attempts = 0;
  bool _chromeVisible = true;
  bool _detailsVisible = false;
  bool _leaving = false;
  bool _opening = false;
  bool _recovering = false;
  int _generation = 0;
  (int, PlaybackTransport)? _pendingRuntimeError;

  bool get _isLive =>
      widget.handoff is LivePlaybackHandoff ||
      widget.handoff is M3uLivePlaybackHandoff;
  bool get _isVod => !_isLive;
  bool get _isStarting => _opening && _failure == null && !_state.hasVideo;
  bool get _isFailure => _failure != null;
  CredentialStore get _credentials =>
      widget.credentialStore ?? SecureCredentialStore();
  FullscreenPort get _fullscreen =>
      widget.fullscreenPort ?? const WindowFullscreenPort();

  @override
  void initState() {
    super.initState();
    _stageFocus.addListener(_onFocusChanged);
    _chromeFocus.addListener(_onChromeFocusChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _stageFocus.requestFocus();
      _showChrome();
      unawaited(_startCycle());
    });
  }

  @override
  void dispose() {
    _chromeTimer?.cancel();
    unawaited(_disposeTransport());
    _stageFocus
      ..removeListener(_onFocusChanged)
      ..dispose();
    _chromeFocus.removeListener(_onChromeFocusChanged);
    _chromeFocus.dispose();
    _backFocus.dispose();
    _backTenFocus.dispose();
    _playFocus.dispose();
    _forwardTenFocus.dispose();
    _muteFocus.dispose();
    _timelineFocus.dispose();
    _volumeFocus.dispose();
    _fullscreenFocus.dispose();
    _recoveryPrimaryFocus.dispose();
    _recoveryBackFocus.dispose();
    _recoveryDetailsFocus.dispose();
    super.dispose();
  }

  void _onFocusChanged() {
    if (_stageFocus.hasFocus) {
      _armChromeHide();
    }
  }

  void _onChromeFocusChanged() {
    if (!_chromeFocus.hasFocus) _armChromeHide();
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
          _hasControlFocus ||
          _isFailure ||
          _state.isBuffering ||
          !_state.hasVideo) {
        return;
      }
      setState(() => _chromeVisible = false);
    });
  }

  bool get _hasControlFocus => _chromeFocus.hasFocus;

  KeyEventResult _chromeKey(FocusNode _, KeyEvent event) {
    if (event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.arrowDown) {
      _stageFocus.requestFocus();
      setState(() => _chromeVisible = false);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  Future<void> _startCycle() async {
    if (_opening || _leaving) return;
    setState(() {
      _opening = true;
      _failure = null;
      _detailsVisible = false;
      _attempts = 0;
      _chromeVisible = true;
    });
    final generation = ++_generation;
    for (var retry = 0; retry < 2 && mounted && !_leaving; retry++) {
      setState(() {
        _attempts = retry + 1;
        _state = const PlaybackTransportState();
      });
      final failure = await _openOnce(generation);
      if (!mounted || _leaving) return;
      if (failure == null) {
        _finishSuccessfulOpen(generation);
        return;
      }
      if (failure == PlaybackFailureKind.credentialsUnavailable) {
        setState(() {
          _opening = false;
          _failure = failure;
        });
        _focusRecoveryPrimary();
        return;
      }
      if (retry == 1) {
        await _disposeTransport();
        if (!mounted || _leaving) return;
        setState(() {
          _opening = false;
          _failure = failure;
        });
        _focusRecoveryPrimary();
        return;
      }
    }
  }

  void _finishSuccessfulOpen(int generation) {
    if (!mounted || _leaving || generation != _generation) return;
    setState(() => _opening = false);
    _armChromeHide();
    final pending = _pendingRuntimeError;
    _pendingRuntimeError = null;
    if (pending != null &&
        pending.$1 == generation &&
        identical(pending.$2, _transport)) {
      unawaited(_recoverAfterPlaybackError(generation, pending.$2));
    }
  }

  Future<PlaybackFailureKind?> _openOnce(int generation) async {
    await _disposeTransport();
    _PlaybackTarget? target;
    try {
      target = await _resolvePlaybackTarget();
    } catch (_) {
      return PlaybackFailureKind.unavailable;
    }
    final resolvedTarget = target;
    if (resolvedTarget == null || _leaving) {
      return widget.handoff is M3uLivePlaybackHandoff
          ? PlaybackFailureKind.unavailable
          : PlaybackFailureKind.credentialsUnavailable;
    }
    try {
      final transport =
          (widget.transportFactory ?? MediaKitPlaybackTransport.create)();
      _transport = transport;
      final usable = Completer<PlaybackFailureKind?>();
      _states = transport.states.listen((next) {
        if (!mounted || _transport != transport || generation != _generation) {
          return;
        }
        final bufferingEnded = _state.isBuffering && !next.isBuffering;
        setState(() => _state = next);
        if (bufferingEnded && !_hasControlFocus) _armChromeHide();
        if (next.hasError) {
          if (!usable.isCompleted) {
            usable.complete(PlaybackFailureKind.unavailable);
          } else if (_opening) {
            // The first usable frame and a later engine error can arrive in
            // adjacent events. Let the opener clear its transient state, then
            // recover exactly once from the transport that is still current.
            _pendingRuntimeError = (generation, transport);
          } else {
            unawaited(_recoverAfterPlaybackError(generation, transport));
          }
        } else if (next.hasVideo && !usable.isCompleted) {
          usable.complete(null);
        }
      });
      unawaited(() async {
        try {
          await transport.open(
            resolvedTarget.uri,
            httpHeaders: resolvedTarget.httpHeaders,
          );
        } catch (_) {
          if (mounted &&
              _transport == transport &&
              generation == _generation &&
              !usable.isCompleted) {
            usable.complete(PlaybackFailureKind.unavailable);
          }
        }
      }());
      return await waitForPlaybackStartup(
        usable.future,
        widget.startupDeadline,
      );
    } catch (_) {
      return PlaybackFailureKind.unavailable;
    }
  }

  Future<_PlaybackTarget?> _resolvePlaybackTarget() async {
    final handoff = widget.handoff;
    final source = await _resolveSource(handoff.sourceId);
    if (source == null || source.id != handoff.sourceId || _leaving) {
      return null;
    }
    if (handoff is M3uLivePlaybackHandoff) {
      return _PlaybackTarget(handoff.uri, handoff.httpHeaders);
    }
    if (handoff is! XtreamPlaybackHandoff) return null;
    final credential = await _credentials.read(source.credentialKey);
    if (credential == null || _leaving) return null;
    try {
      return _PlaybackTarget(
        resolveXtreamPlaybackUri(handoff: handoff, credential: credential),
        const {},
      );
    } catch (_) {
      return null;
    }
  }

  Future<PersistedSource?> _resolveSource(String sourceId) async {
    final resolver = widget.sourceResolver;
    if (resolver != null) return await resolver(sourceId);
    final source = widget.source;
    return source != null && source.id == sourceId ? source : null;
  }

  Future<void> _recoverAfterPlaybackError(
    int generation,
    PlaybackTransport transport,
  ) async {
    if (!mounted ||
        _leaving ||
        _recovering ||
        generation != _generation ||
        _transport != transport) {
      return;
    }
    _recovering = true;
    final retryGeneration = ++_generation;
    if (_attempts >= 2) {
      await _disposeTransport();
      if (!mounted || _leaving || retryGeneration != _generation) {
        _recovering = false;
        return;
      }
      setState(() {
        _opening = false;
        _failure = PlaybackFailureKind.unavailable;
        _chromeVisible = true;
      });
      _focusRecoveryPrimary();
      _recovering = false;
      return;
    }
    setState(() {
      _opening = true;
      _chromeVisible = true;
      _state = const PlaybackTransportState();
    });
    _attempts += 1;
    final failure = await _openOnce(retryGeneration);
    if (!mounted || _leaving || retryGeneration != _generation) {
      _recovering = false;
      return;
    }
    if (failure == null) {
      _recovering = false;
      _finishSuccessfulOpen(retryGeneration);
      return;
    }
    await _disposeTransport();
    if (!mounted || _leaving || retryGeneration != _generation) {
      _recovering = false;
      return;
    }
    setState(() {
      _opening = false;
      _failure = failure;
      _chromeVisible = true;
    });
    _focusRecoveryPrimary();
    _recovering = false;
  }

  void _focusRecoveryPrimary() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _isFailure && !_leaving) {
        _recoveryPrimaryFocus.requestFocus();
      }
    });
  }

  Future<void> _disposeTransport() {
    final active = _teardown;
    if (active != null) return active;

    final subscription = _states;
    final transport = _transport;
    _states = null;
    _transport = null;
    _pendingRuntimeError = null;

    if (subscription == null && transport == null) {
      return Future<void>.value();
    }

    late final Future<void> teardown;
    teardown =
        Future.wait<void>([
          if (subscription != null) subscription.cancel(),
          if (transport != null) transport.dispose(),
        ]).whenComplete(() {
          if (identical(_teardown, teardown)) _teardown = null;
        });
    _teardown = teardown;
    return teardown;
  }

  Future<void> _leave() async {
    if (_leaving) return;
    if (await _fullscreen.isFullscreen) {
      await _fullscreen.setFullscreen(false);
      return;
    }
    _leaving = true;
    _chromeTimer?.cancel();
    await _disposeTransport();
    if (mounted) await widget.onExit();
  }

  Future<void> _openSettings() async {
    _leaving = true;
    await _disposeTransport();
    if (mounted) await (widget.onOpenSettings?.call() ?? widget.onExit());
  }

  Future<void> _togglePlay() async {
    final transport = _transport;
    if (transport == null) return;
    _showChrome();
    if (_state.isPlaying) {
      await transport.pause();
    } else {
      await transport.play();
    }
  }

  Future<void> _seekBy(int seconds) async {
    final transport = _transport;
    if (transport == null || !_isVod) return;
    _showChrome();
    final maximum = _state.duration;
    final target = _state.position + Duration(seconds: seconds);
    await transport.seek(
      target < Duration.zero
          ? Duration.zero
          : (target > maximum ? maximum : target),
    );
  }

  Future<void> _setVolume(double value) async {
    final transport = _transport;
    if (transport == null) return;
    _showChrome();
    await transport.setVolume(value.clamp(0, 100));
  }

  Future<void> _toggleMute() async {
    final transport = _transport;
    if (transport == null) return;
    _showChrome();
    await transport.setMuted(!_state.muted);
  }

  Future<void> _toggleFullscreen() async {
    _showChrome();
    await _fullscreen.setFullscreen(!(await _fullscreen.isFullscreen));
  }

  KeyEventResult _stageKey(FocusNode _, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.escape ||
        event.logicalKey == LogicalKeyboardKey.browserBack) {
      unawaited(_leave());
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
      _showChrome();
      _backFocus.requestFocus();
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
      _chromeVisible = false;
      setState(() {});
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.enter ||
        event.logicalKey == LogicalKeyboardKey.select) {
      _showChrome();
      (_isStarting
              ? _backFocus
              : _isFailure
              ? _recoveryPrimaryFocus
              : _playFocus)
          .requestFocus();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final video = _transport?.buildVideo() ?? const SizedBox.expand();
    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.escape): () =>
            unawaited(_leave()),
        const SingleActivator(LogicalKeyboardKey.browserBack): () =>
            unawaited(_leave()),
      },
      child: FocusTraversalGroup(
        policy: WidgetOrderTraversalPolicy(),
        child: MouseRegion(
          onHover: (_) => _showChrome(),
          child: Focus(
            focusNode: _stageFocus,
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
                    const Align(
                      alignment: Alignment.center,
                      child: _StatusMark(label: 'Buffering'),
                    ),
                  if (_isStarting)
                    Align(
                      alignment: Alignment.center,
                      child: _StatusMark(
                        label: 'Starting ${widget.handoff.title}',
                      ),
                    ),
                  if (_chromeVisible || _isFailure || _isStarting)
                    Positioned.fill(
                      child: FocusScope(
                        node: _chromeFocus,
                        onKeyEvent: _chromeKey,
                        child: Stack(
                          children: [
                            _IdentityBand(
                              handoff: widget.handoff,
                              focusNode: _backFocus,
                              onBack: () => unawaited(_leave()),
                              onDown: _returnToStage,
                            ),
                            Align(
                              alignment: Alignment.bottomCenter,
                              child: _isFailure
                                  ? _FailureDeck(
                                      failure: _failure!,
                                      handoff: widget.handoff,
                                      attempts: _attempts,
                                      detailsVisible: _detailsVisible,
                                      primaryFocus: _recoveryPrimaryFocus,
                                      backFocus: _recoveryBackFocus,
                                      detailsFocus: _recoveryDetailsFocus,
                                      onToggleDetails: () => setState(
                                        () =>
                                            _detailsVisible = !_detailsVisible,
                                      ),
                                      onPrimary:
                                          _failure ==
                                              PlaybackFailureKind
                                                  .credentialsUnavailable
                                          ? () => unawaited(_openSettings())
                                          : () => unawaited(_startCycle()),
                                      onBack: () => unawaited(_leave()),
                                      onDownToStage: _returnToStage,
                                    )
                                  : _BroadcastDeck(
                                      live: _isLive,
                                      state: _state,
                                      backTenFocus: _backTenFocus,
                                      playFocus: _playFocus,
                                      forwardTenFocus: _forwardTenFocus,
                                      muteFocus: _muteFocus,
                                      timelineFocus: _timelineFocus,
                                      volumeFocus: _volumeFocus,
                                      fullscreenFocus: _fullscreenFocus,
                                      onPlayPause: () =>
                                          unawaited(_togglePlay()),
                                      onBackTen: () => unawaited(_seekBy(-10)),
                                      onForwardTen: () =>
                                          unawaited(_seekBy(10)),
                                      onSeek: (value) => unawaited(
                                        _transport?.seek(
                                              Duration(
                                                milliseconds: value.round(),
                                              ),
                                            ) ??
                                            Future<void>.value(),
                                      ),
                                      onMute: () => unawaited(_toggleMute()),
                                      onVolume: _setVolume,
                                      onFullscreen: () =>
                                          unawaited(_toggleFullscreen()),
                                      onBack: () => unawaited(_leave()),
                                      onDownToStage: _returnToStage,
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
      ),
    );
  }

  void _returnToStage() {
    _stageFocus.requestFocus();
    setState(() => _chromeVisible = false);
  }
}

class _StatusMark extends StatelessWidget {
  const _StatusMark({required this.label});
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
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: _amber,
              backgroundColor: _line,
            ),
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

class _IdentityBand extends StatelessWidget {
  const _IdentityBand({
    required this.handoff,
    required this.focusNode,
    required this.onBack,
    required this.onDown,
  });
  final PlaybackHandoff handoff;
  final FocusNode focusNode;
  final VoidCallback onBack;
  final VoidCallback onDown;
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
          const SizedBox(width: 12),
          Text(
            handoff is LivePlaybackHandoff || handoff is M3uLivePlaybackHandoff
                ? 'LIVE'
                : handoff is MoviePlaybackHandoff
                ? 'MOVIE'
                : 'EPISODE',
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
    required this.backTenFocus,
    required this.playFocus,
    required this.forwardTenFocus,
    required this.muteFocus,
    required this.timelineFocus,
    required this.volumeFocus,
    required this.fullscreenFocus,
    required this.onPlayPause,
    required this.onBackTen,
    required this.onForwardTen,
    required this.onSeek,
    required this.onMute,
    required this.onVolume,
    required this.onFullscreen,
    required this.onBack,
    required this.onDownToStage,
  });
  final bool live;
  final PlaybackTransportState state;
  final FocusNode backTenFocus,
      playFocus,
      forwardTenFocus,
      muteFocus,
      timelineFocus,
      volumeFocus,
      fullscreenFocus;
  final VoidCallback onPlayPause,
      onBackTen,
      onForwardTen,
      onMute,
      onFullscreen,
      onBack,
      onDownToStage;
  final ValueChanged<double> onSeek, onVolume;

  Widget _primaryControls() => KeyedSubtree(
    key: const ValueKey('player-primary-controls'),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (!live) ...[
          _DeckAction(
            icon: Icons.replay_10,
            label: 'Back 10 seconds',
            focusNode: backTenFocus,
            onPressed: onBackTen,
            onDown: onDownToStage,
          ),
          const SizedBox(width: 8),
        ],
        _DeckAction(
          key: const ValueKey('player-play-pause'),
          focusNode: playFocus,
          icon: state.isPlaying ? Icons.pause : Icons.play_arrow,
          label: state.isPlaying ? 'Pause' : 'Play',
          onPressed: onPlayPause,
          onDown: onDownToStage,
        ),
        if (!live) ...[
          const SizedBox(width: 8),
          _DeckAction(
            icon: Icons.forward_10,
            label: 'Forward 10 seconds',
            focusNode: forwardTenFocus,
            onPressed: onForwardTen,
            onDown: onDownToStage,
          ),
        ],
      ],
    ),
  );

  Widget _utilityControls() => KeyedSubtree(
    key: const ValueKey('player-utility-controls'),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _DeckAction(
          icon: state.muted ? Icons.volume_off : Icons.volume_up,
          label: state.muted ? 'Unmute' : 'Mute',
          focusNode: muteFocus,
          onPressed: onMute,
          onDown: onDownToStage,
        ),
        const SizedBox(width: 8),
        SizedBox(
          width: 112,
          child: _Volume(
            focusNode: volumeFocus,
            value: state.volume,
            onChanged: onVolume,
            onDown: onDownToStage,
          ),
        ),
        const SizedBox(width: 8),
        _DeckAction(
          key: const ValueKey('player-fullscreen'),
          focusNode: fullscreenFocus,
          icon: Icons.fullscreen,
          label: 'Fullscreen',
          onPressed: onFullscreen,
          onBack: onBack,
          onDown: onDownToStage,
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final wide = constraints.maxWidth >= 1265;
      return SafeArea(
        top: false,
        child: Container(
          key: const ValueKey('player-broadcast-deck'),
          constraints: const BoxConstraints(minHeight: 78),
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
          decoration: const BoxDecoration(
            color: _surface,
            border: Border(top: BorderSide(color: _line)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (!live)
                _Timeline(
                  focusNode: timelineFocus,
                  position: state.position,
                  duration: state.duration,
                  onChanged: onSeek,
                  onDown: onDownToStage,
                ),
              if (!live) const SizedBox(height: 8),
              if (wide)
                Row(
                  children: [
                    const Expanded(
                      key: ValueKey('player-left-balance-zone'),
                      child: SizedBox.shrink(),
                    ),
                    _primaryControls(),
                    Expanded(
                      child: Align(
                        alignment: Alignment.centerRight,
                        child: _utilityControls(),
                      ),
                    ),
                  ],
                )
              else
                Row(
                  children: [
                    _primaryControls(),
                    const Spacer(),
                    _utilityControls(),
                  ],
                ),
            ],
          ),
        ),
      );
    },
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
  final ValueChanged<double> onChanged;
  final VoidCallback onDown;
  @override
  State<_Timeline> createState() => _TimelineState();
}

class _TimelineState extends State<_Timeline> {
  bool _focused = false;
  @override
  Widget build(BuildContext context) {
    final maximum = widget.duration.inMilliseconds.toDouble();
    final value = maximum <= 0
        ? 0.0
        : widget.position.inMilliseconds.clamp(0, maximum).toDouble();
    return KeyedSubtree(
      key: const ValueKey('player-timeline'),
      child: Focus(
        focusNode: widget.focusNode,
        onFocusChange: (value) => setState(() => _focused = value),
        onKeyEvent: (_, event) {
          if (event is! KeyDownEvent) return KeyEventResult.ignored;
          if (event.logicalKey == LogicalKeyboardKey.arrowLeft ||
              event.logicalKey == LogicalKeyboardKey.arrowRight) {
            final delta = event.logicalKey == LogicalKeyboardKey.arrowLeft
                ? -10000
                : 10000;
            widget.onChanged((value + delta).clamp(0, maximum));
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
            height: 28,
            decoration: BoxDecoration(
              border: Border.all(
                color: _focused ? _amber : _line,
                width: _focused ? 2 : 1,
              ),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Row(
              children: [
                SizedBox(
                  width: 58,
                  child: Center(
                    child: Text(
                      _time(widget.position),
                      style: const TextStyle(color: _quietText, fontSize: 12),
                    ),
                  ),
                ),
                Expanded(
                  child: Slider(
                    value: value,
                    max: maximum <= 0 ? 1 : maximum,
                    onChanged: maximum <= 0 ? null : widget.onChanged,
                    activeColor: _amber,
                    inactiveColor: _raised,
                  ),
                ),
                SizedBox(
                  width: 58,
                  child: Center(
                    child: Text(
                      _time(widget.duration),
                      style: const TextStyle(color: _quietText, fontSize: 12),
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
  bool _focused = false;
  @override
  Widget build(BuildContext context) => Focus(
    focusNode: widget.focusNode,
    onFocusChange: (value) => setState(() => _focused = value),
    onKeyEvent: (_, event) {
      if (event is KeyDownEvent &&
          event.logicalKey == LogicalKeyboardKey.arrowDown) {
        widget.onDown();
        return KeyEventResult.handled;
      }
      if (event is KeyDownEvent &&
          (event.logicalKey == LogicalKeyboardKey.arrowLeft ||
              event.logicalKey == LogicalKeyboardKey.arrowRight)) {
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
            color: _focused ? _amber : _line,
            width: _focused ? 2 : 1,
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
  final VoidCallback? onBack;
  final VoidCallback? onDown;
  @override
  State<_DeckAction> createState() => _DeckActionState();
}

class _DeckActionState extends State<_DeckAction> {
  bool _focused = false;
  @override
  Widget build(BuildContext context) => Focus(
    focusNode: widget.focusNode,
    onFocusChange: (value) => setState(() => _focused = value),
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
            color: _focused ? _raised : Colors.transparent,
            border: Border.all(
              color: _focused ? _amber : _line,
              width: _focused ? 2 : 1,
            ),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Icon(widget.icon, color: _warmWhite, size: 22),
        ),
      ),
    ),
  );
}

class _FailureDeck extends StatelessWidget {
  const _FailureDeck({
    required this.failure,
    required this.handoff,
    required this.attempts,
    required this.detailsVisible,
    required this.primaryFocus,
    required this.backFocus,
    required this.detailsFocus,
    required this.onToggleDetails,
    required this.onPrimary,
    required this.onBack,
    required this.onDownToStage,
  });
  final PlaybackFailureKind failure;
  final PlaybackHandoff handoff;
  final int attempts;
  final bool detailsVisible;
  final FocusNode primaryFocus, backFocus, detailsFocus;
  final VoidCallback onToggleDetails;
  final VoidCallback onPrimary;
  final VoidCallback onBack;
  final VoidCallback onDownToStage;
  @override
  Widget build(BuildContext context) => SafeArea(
    top: false,
    child: Container(
      key: const ValueKey('player-failure-deck'),
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
            failure.message,
            style: const TextStyle(
              color: _warmWhite,
              fontSize: 16,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 14),
          FocusTraversalGroup(
            policy: WidgetOrderTraversalPolicy(),
            child: Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                _RecoveryAction(
                  key: const ValueKey('player-recovery-primary'),
                  focusRingKey: const ValueKey(
                    'player-recovery-primary-focus-ring',
                  ),
                  focusNode: primaryFocus,
                  label: failure == PlaybackFailureKind.credentialsUnavailable
                      ? 'Open Settings'
                      : 'Try again',
                  primary: true,
                  onPressed: onPrimary,
                  onLeft: detailsFocus.requestFocus,
                  onRight: backFocus.requestFocus,
                  onDown: onDownToStage,
                  onBack: onBack,
                ),
                _RecoveryAction(
                  key: const ValueKey('player-recovery-back'),
                  focusRingKey: const ValueKey(
                    'player-recovery-back-focus-ring',
                  ),
                  focusNode: backFocus,
                  label: 'Back',
                  onPressed: onBack,
                  onLeft: primaryFocus.requestFocus,
                  onRight: detailsFocus.requestFocus,
                  onDown: onDownToStage,
                  onBack: onBack,
                ),
                _RecoveryAction(
                  key: const ValueKey('player-recovery-details'),
                  focusRingKey: const ValueKey(
                    'player-recovery-details-focus-ring',
                  ),
                  focusNode: detailsFocus,
                  label: detailsVisible
                      ? 'Hide technical details'
                      : 'Technical details',
                  subordinate: true,
                  onPressed: onToggleDetails,
                  onLeft: backFocus.requestFocus,
                  onRight: primaryFocus.requestFocus,
                  onDown: onDownToStage,
                  onBack: onBack,
                ),
              ],
            ),
          ),
          if (detailsVisible)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Text(
                'Category: ${failure.name}\nMedia: ${handoff is LivePlaybackHandoff || handoff is M3uLivePlaybackHandoff
                    ? 'Live'
                    : handoff is MoviePlaybackHandoff
                    ? 'Movie'
                    : 'Episode'}\nAttempts: $attempts\nLocal time: ${_localTime()}',
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

class _RecoveryAction extends StatefulWidget {
  const _RecoveryAction({
    super.key,
    this.focusRingKey,
    required this.focusNode,
    required this.label,
    required this.onPressed,
    required this.onLeft,
    required this.onRight,
    required this.onDown,
    required this.onBack,
    this.primary = false,
    this.subordinate = false,
  });
  final Key? focusRingKey;
  final FocusNode focusNode;
  final String label;
  final VoidCallback onPressed;
  final VoidCallback onLeft, onRight, onDown, onBack;
  final bool primary;
  final bool subordinate;

  @override
  State<_RecoveryAction> createState() => _RecoveryActionState();
}

class _RecoveryActionState extends State<_RecoveryAction> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) => Focus(
    focusNode: widget.focusNode,
    onFocusChange: (value) => setState(() => _focused = value),
    onKeyEvent: (_, event) {
      if (event is! KeyDownEvent) return KeyEventResult.ignored;
      if (event.logicalKey == LogicalKeyboardKey.escape ||
          event.logicalKey == LogicalKeyboardKey.browserBack) {
        widget.onBack();
        return KeyEventResult.handled;
      }
      if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
        widget.onLeft();
        return KeyEventResult.handled;
      }
      if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
        widget.onRight();
        return KeyEventResult.handled;
      }
      if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
        widget.onDown();
        return KeyEventResult.handled;
      }
      if (event.logicalKey == LogicalKeyboardKey.enter ||
          event.logicalKey == LogicalKeyboardKey.select) {
        widget.onPressed();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    },
    child: Semantics(
      button: true,
      label: widget.label,
      excludeSemantics: true,
      child: GestureDetector(
        onTap: () {
          widget.focusNode.requestFocus();
          widget.onPressed();
        },
        child: DecoratedBox(
          key: widget.focusRingKey,
          decoration: BoxDecoration(
            color: _surface,
            border: Border.all(
              color: _focused ? _amber : Colors.transparent,
              width: 2,
            ),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Padding(
            padding: const EdgeInsets.all(2),
            child: Container(
              constraints: BoxConstraints(
                minWidth: widget.subordinate ? 142 : 106,
                minHeight: 40,
              ),
              padding: const EdgeInsets.symmetric(horizontal: 12),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: widget.subordinate
                    ? Colors.transparent
                    : widget.primary
                    ? _amber
                    : _raised,
                border: Border.all(
                  color: widget.subordinate ? Colors.transparent : _line,
                ),
                borderRadius: BorderRadius.circular(3),
              ),
              child: Text(
                widget.label,
                style: TextStyle(
                  color: widget.subordinate
                      ? (_focused ? _warmWhite : _quietText)
                      : widget.primary
                      ? _amberInk
                      : _warmWhite,
                  fontSize: 14,
                  fontWeight: widget.subordinate
                      ? FontWeight.w600
                      : FontWeight.w700,
                ),
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
