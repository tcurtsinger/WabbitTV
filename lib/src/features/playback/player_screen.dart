// THESIS: One calm Broadcast Deck presents a shell-owned PlaybackManager
// session; widget rebuilds never create or replace a native transport.

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

import '../../cinema.dart';
import '../browse/playback_handoff.dart';
import '../guide/guide_data.dart';
import '../library/library_organization_service.dart';
import '../sources/credential_store.dart';
import '../sources/epg_models.dart';
import '../sources/source_catalog_database.dart';
import '../sources/source_models.dart';
import 'playback_manager.dart';
import 'playback_runtime_adapters.dart';
import 'playback_transport.dart';

export 'playback_runtime_adapters.dart' show resolveXtreamPlaybackUri;

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
    this.windowControls,
    this.organization,
    this.onOrganizationChanged,
    this.guide,
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

  /// Mute, volume and fullscreen; off on Android, where the TV remote owns
  /// volume and the app is always fullscreen.
  final bool? windowControls;

  /// Reads and saves the playing item's Favorite flag; null hides the star.
  final LibraryOrganizationPort? organization;
  final VoidCallback? onOrganizationChanged;

  /// Cached now/next for Xtream live channels; null or no data hides it.
  final EpgWindowPort? guide;
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
  final _favoriteNode = FocusNode(debugLabel: 'player favorite');
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
  PersonalLibraryOrganization? _organization;
  int _organizationGeneration = 0;
  EpgNowNext? _nowNext;
  Timer? _guideTimer;
  int _guideGeneration = 0;
  bool _favoriteBusy = false;

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
      unawaited(_loadOrganization());
      unawaited(_loadGuide());
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
      unawaited(_loadOrganization());
      unawaited(_loadGuide());
    } else if (widget.variantPort != oldWidget.variantPort) {
      _resetVariants();
    }
    _changed();
  }

  @override
  void dispose() {
    _chromeTimer?.cancel();
    _guideTimer?.cancel();
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
      _favoriteNode,
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

  Future<void> _loadOrganization() async {
    final port = widget.organization;
    final id = _handoff.libraryItemId;
    final generation = ++_organizationGeneration;
    setState(() => _organization = null);
    if (port == null || id == null) return;
    PersonalLibraryOrganization? value;
    try {
      value = await port.loadItem(id);
    } catch (_) {}
    if (mounted && generation == _organizationGeneration) {
      setState(() => _organization = value);
    }
  }

  String? get _guideCatalogId {
    final handoff = _handoff;
    return handoff is LivePlaybackHandoff
        ? catalogItemId(
            handoff.sourceId,
            SourceMediaKind.live,
            handoff.providerItemId,
          )
        : null;
  }

  Future<void> _loadGuide() async {
    _guideTimer?.cancel();
    final port = widget.guide;
    final id = _guideCatalogId;
    final generation = ++_guideGeneration;
    if (_nowNext != null) setState(() => _nowNext = null);
    if (port == null || id == null) return;
    Future<EpgNowNext?> read() async {
      final now = DateTime.now().toUtc();
      final windows = await port.loadEpgWindow(
        catalogItemIds: [id],
        windowStartUtc: now.subtract(const Duration(hours: 2)),
        windowEndUtc: now.add(const Duration(hours: 12)),
        atUtc: now,
      );
      for (final window in windows) {
        if (window.catalogItemId == id) return window.nowNext;
      }
      return null;
    }

    try {
      var nowNext = await read();
      if (nowNext?.current == null && generation == _guideGeneration) {
        await port.refreshCatalogItems([id]);
        nowNext = await read();
      }
      if (!mounted || generation != _guideGeneration) return;
      setState(() => _nowNext = nowNext);
      // Read again once this program ends so the line moves along.
      final end = nowNext?.current?.endUtc;
      final wait = end == null
          ? const Duration(minutes: 15)
          : end.difference(DateTime.now().toUtc()) + const Duration(seconds: 1);
      _guideTimer = Timer(
        wait.isNegative ? const Duration(minutes: 1) : wait,
        () => unawaited(_loadGuide()),
      );
    } catch (_) {
      // Now/next is optional; playback stays primary.
    }
  }

  Future<void> _toggleFavorite() async {
    final port = widget.organization;
    final current = _organization;
    if (port == null || current == null || _favoriteBusy) return;
    final generation = _organizationGeneration;
    setState(() {
      _favoriteBusy = true;
      _organization = PersonalLibraryOrganization(
        libraryItemId: current.libraryItemId,
        isFavorite: !current.isFavorite,
        groups: current.groups,
      );
    });
    var saved = false;
    try {
      saved = (await port.saveItem(
        libraryItemId: current.libraryItemId,
        favorite: !current.isFavorite,
        // Saving replaces the whole organization, so keep the groups.
        customGroupIds: {
          for (final group in current.groups)
            if (group.selected) group.groupId,
        },
      )).succeeded;
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      _favoriteBusy = false;
      if (!saved && generation == _organizationGeneration) {
        _organization = current;
        _message = "Couldn't update Favorites.";
      }
    });
    if (saved) widget.onOrganizationChanged?.call();
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
        unawaited(_loadOrganization());
        unawaited(_loadGuide());
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

  Future<void> _toggleMute() async {
    final id = _sessionId;
    if (id == null) return;
    await _manager.setMuted(id, _snapshot?.isAudible == true);
  }

  Future<void> _toggleFullscreen() async =>
      _fullscreen.setFullscreen(!(await _fullscreen.isFullscreen));

  Future<void> _startOver() async {
    final id = _sessionId;
    if (id == null || _live) return;
    final outcome = await _manager.startOverWithOutcome(id);
    if (!mounted) return;
    setState(() {
      _message = !outcome.seekSucceeded
          ? 'Could not start over.'
          : !outcome.progressSaved
          ? 'Started over · progress not saved'
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
    // Holding an arrow keeps seeking; every other stage key acts once.
    final step = switch (event.logicalKey) {
      LogicalKeyboardKey.arrowLeft => -10,
      LogicalKeyboardKey.arrowRight => 10,
      _ => null,
    };
    if (step != null && event is! KeyUpEvent && !_live && !_failed) {
      _showChrome();
      unawaited(_seek(_boundedSeek(_state, step)));
      return KeyEventResult.handled;
    }
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
    // Stage-only so Space still presses a focused deck control and the
    // arrows still move focus once the deck has it.
    if (event.logicalKey == LogicalKeyboardKey.space) {
      unawaited(_togglePlay());
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
        const SingleActivator(
          LogicalKeyboardKey.keyK,
          includeRepeats: false,
        ): () =>
            unawaited(_togglePlay()),
        const SingleActivator(
          LogicalKeyboardKey.mediaPlayPause,
          includeRepeats: false,
        ): () =>
            unawaited(_togglePlay()),
        const SingleActivator(
          LogicalKeyboardKey.keyF,
          includeRepeats: false,
        ): () =>
            unawaited(_toggleFullscreen()),
        const SingleActivator(
          LogicalKeyboardKey.keyM,
          includeRepeats: false,
        ): () =>
            unawaited(_toggleMute()),
      },
      child: FocusTraversalGroup(
        child: MouseRegion(
          key: const ValueKey('player-pointer'),
          cursor: _chromeVisible || _starting || _failed || _tracksOpen
              ? MouseCursor.defer
              : SystemMouseCursors.none,
          onHover: (_) => _showChrome(),
          child: Focus(
            focusNode: _stage,
            autofocus: true,
            onKeyEvent: _stageKey,
            child: Material(
              color: Cinema.ink,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  GestureDetector(
                    key: const ValueKey('player-video-stage'),
                    behavior: HitTestBehavior.opaque,
                    onDoubleTap: () => unawaited(_toggleFullscreen()),
                    child: RepaintBoundary(child: video),
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
                          if (_failed)
                            const Positioned.fill(
                              child: ColoredBox(color: Color(0x99050507)),
                            ),
                          Positioned(
                            top: 0,
                            left: 0,
                            right: 0,
                            child: _IdentityBand(
                              handoff: _handoff,
                              now: _nowNext?.current,
                              focusNode: _back,
                              onBack: () => unawaited(_backOut()),
                              onDown: _returnToStage,
                            ),
                          ),
                          if (snapshot != null &&
                              (snapshot.resume.didResume ||
                                  snapshot.resume.loadFailed ||
                                  snapshot.progressSaveFailed ||
                                  _message != null))
                            Positioned(
                              top: 96,
                              left: 0,
                              right: 0,
                              child: _Notice(
                                _message ??
                                    (snapshot.progressSaveFailed
                                        ? 'Progress could not be saved.'
                                        : snapshot.resume.loadFailed
                                        ? "Couldn't load progress · playing from the start"
                                        : 'Resumed at ${_time(snapshot.resume.appliedPosition)}.'),
                              ),
                            ),
                          Positioned(
                            left: 0,
                            right: 0,
                            bottom: 0,
                            top: _failed ? 0 : null,
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
                                    nowNext: _nowNext,
                                    windowControls:
                                        widget.windowControls ??
                                        !Platform.isAndroid,
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
                                      favorite: _favoriteNode,
                                      fullscreen: _fullscreenNode,
                                    ),
                                    favorite:
                                        widget.organization == null ||
                                            _handoff.libraryItemId == null
                                        ? null
                                        : _organization?.isFavorite ?? false,
                                    onFavorite: () =>
                                        unawaited(_toggleFavorite()),
                                    onPlay: () => unawaited(_togglePlay()),
                                    onSeek: (value) => unawaited(_seek(value)),
                                    onMute: () => unawaited(_toggleMute()),
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
                                    onFullscreen: () =>
                                        unawaited(_toggleFullscreen()),
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
    required this.favorite,
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
      favorite,
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
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: Cinema.amber,
            ),
          ),
          const SizedBox(width: 10),
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Cinema.text,
                fontSize: 15,
                fontWeight: FontWeight.w600,
                shadows: [Shadow(color: Color(0xCC000000), blurRadius: 12)],
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
    child: Center(
      child: Container(
        key: const ValueKey('player-playback-notice'),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          color: Cinema.card,
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text(
          message,
          style: const TextStyle(color: Cinema.quiet, fontSize: 13),
        ),
      ),
    ),
  );
}

class _IdentityBand extends StatelessWidget {
  const _IdentityBand({
    required this.handoff,
    required this.now,
    required this.focusNode,
    required this.onBack,
    required this.onDown,
  });
  final PlaybackHandoff handoff;

  /// The program on now, when the guide knows it.
  final EpgProgram? now;
  final FocusNode focusNode;
  final VoidCallback onBack, onDown;
  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(gradient: Cinema.scrim(fromTop: true)),
    child: SafeArea(
      bottom: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(28, 20, 32, 44),
        child: Row(
          children: [
            _DeckAction(
              key: const ValueKey('player-back'),
              focusNode: focusNode,
              icon: Icons.arrow_back_rounded,
              label: 'Back',
              onPressed: onBack,
              onDown: onDown,
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    handoff.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Cinema.text,
                      fontFamily: Cinema.display,
                      fontSize: 23,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  if (now case final now?) ...[
                    const SizedBox(height: 3),
                    Text.rich(
                      key: const ValueKey('player-guide-now'),
                      TextSpan(
                        children: [
                          TextSpan(
                            text: now.title,
                            style: const TextStyle(
                              color: Cinema.text,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          TextSpan(
                            text:
                                '   ${_clockTime(context, now.startUtc)} – '
                                '${_clockTime(context, now.endUtc)}',
                          ),
                        ],
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Cinema.quiet, fontSize: 13),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 16),
            const _Clock(),
          ],
        ),
      ),
    ),
  );
}

class _Clock extends StatefulWidget {
  const _Clock();
  @override
  State<_Clock> createState() => _ClockState();
}

class _ClockState extends State<_Clock> {
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _schedule();
  }

  void _schedule() {
    _tick = Timer(Duration(seconds: 60 - DateTime.now().second), () {
      if (!mounted) return;
      setState(() {});
      _schedule();
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Text(
    MaterialLocalizations.of(context).formatTimeOfDay(
      TimeOfDay.now(),
      alwaysUse24HourFormat: MediaQuery.alwaysUse24HourFormatOf(context),
    ),
    style: const TextStyle(
      color: Cinema.text,
      fontFamily: Cinema.display,
      fontSize: 20,
      fontWeight: FontWeight.w600,
    ),
  );
}

class _BroadcastDeck extends StatelessWidget {
  const _BroadcastDeck({
    required this.live,
    required this.state,
    required this.audible,
    required this.nowNext,
    required this.windowControls,
    required this.nodes,
    required this.favorite,
    required this.onFavorite,
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
  final bool live, audible, windowControls;
  final EpgNowNext? nowNext;
  final PlaybackTransportState state;
  final _DeckNodes nodes;

  /// Whether the item is a Favorite; null hides the star.
  final bool? favorite;
  final VoidCallback onFavorite;
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

  // Play sits dead center; the smaller actions split evenly around it,
  // with the seek buttons next to Play for movies and episodes.
  Widget _transport({Widget? trailing}) {
    final tracks = _DeckAction(
      focusNode: nodes.tracks,
      icon: Icons.subtitles_outlined,
      label: 'Audio & subtitles',
      onPressed: onTracks,
      onDown: onDown,
    );
    final pip = onPip == null
        ? null
        : _DeckAction(
            focusNode: nodes.pip,
            icon: Icons.picture_in_picture_alt_outlined,
            label: 'Picture in picture',
            onPressed: onPip!,
            onDown: onDown,
          );
    final star = favorite == null
        ? null
        : _DeckAction(
            focusNode: nodes.favorite,
            icon: favorite! ? Icons.star_rounded : Icons.star_outline_rounded,
            label: favorite! ? 'Remove from Favorites' : 'Add to Favorites',
            onPressed: onFavorite,
            onDown: onDown,
          );
    final fullscreen = windowControls && _fullscreenInRow
        ? _fullscreenAction()
        : null;
    final List<Widget> left, right;
    if (live) {
      final small = [
        tracks,
        ?star,
        ?pip,
        if (onAdd != null)
          _DeckAction(
            focusNode: nodes.add,
            icon: Icons.splitscreen_outlined,
            iconTurns: 1,
            label: 'Watch two channels',
            onPressed: onAdd!,
            onDown: onDown,
          ),
      ];
      if (fullscreen != null) small.add(fullscreen);
      final split = small.length ~/ 2;
      left = small.sublist(0, split);
      right = small.sublist(split);
    } else {
      left = [
        tracks,
        _DeckAction(
          focusNode: nodes.startOver,
          icon: Icons.restart_alt_rounded,
          label: 'Start over',
          onPressed: onStartOver,
          onDown: onDown,
        ),
        _DeckAction(
          focusNode: nodes.back10,
          icon: Icons.replay_10_rounded,
          label: 'Back 10 seconds',
          onPressed: () => onSeek(_boundedSeek(state, -10)),
          onDown: onDown,
        ),
      ];
      right = [
        _DeckAction(
          focusNode: nodes.forward10,
          icon: Icons.forward_10_rounded,
          label: 'Forward 10 seconds',
          onPressed: () => onSeek(_boundedSeek(state, 10)),
          onDown: onDown,
        ),
        ?pip,
        ?star,
      ];
      if (fullscreen != null) right.add(fullscreen);
    }
    return Row(
      children: [
        Expanded(
          child: Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: _spaced(left),
          ),
        ),
        const SizedBox(width: 18),
        KeyedSubtree(
          key: const ValueKey('player-primary-controls'),
          child: _DeckAction(
            key: const ValueKey('player-play-pause'),
            focusNode: nodes.play,
            icon: state.isPlaying
                ? Icons.pause_rounded
                : Icons.play_arrow_rounded,
            label: state.isPlaying ? 'Pause' : 'Play',
            primary: true,
            onPressed: onPlay,
            onDown: onDown,
          ),
        ),
        const SizedBox(width: 18),
        Expanded(
          child: Row(
            children: [
              ..._spaced(right),
              if (trailing != null) ...[const Spacer(), trailing],
            ],
          ),
        ),
      ],
    );
  }

  // Fullscreen joins the centered row only when it evens the sides;
  // otherwise it sits with mute and volume.
  bool get _fullscreenInRow {
    final extras = (onPip == null ? 0 : 1) + (favorite == null ? 0 : 1);
    return live ? (1 + extras + (onAdd == null ? 0 : 1)).isOdd : extras < 2;
  }

  _DeckAction _fullscreenAction() => _DeckAction(
    key: const ValueKey('player-fullscreen'),
    focusNode: nodes.fullscreen,
    icon: Icons.fullscreen_rounded,
    label: 'Fullscreen',
    onPressed: onFullscreen,
    onBack: onBack,
    onDown: onDown,
  );

  Widget _utilities() => Row(
    key: const ValueKey('player-utility-controls'),
    mainAxisSize: MainAxisSize.min,
    children: [
      _DeckAction(
        focusNode: nodes.mute,
        icon: audible ? Icons.volume_up_rounded : Icons.volume_off_rounded,
        label: audible ? 'Mute' : 'Unmute',
        onPressed: onMute,
        onDown: onDown,
      ),
      const SizedBox(width: 10),
      SizedBox(
        width: 112,
        child: _Volume(
          focusNode: nodes.volume,
          value: state.volume,
          onChanged: onVolume,
          onDown: onDown,
        ),
      ),
      if (!_fullscreenInRow) ...[
        const SizedBox(width: 10),
        _fullscreenAction(),
      ],
    ],
  );

  @override
  Widget build(BuildContext context) => DecoratedBox(
    key: const ValueKey('player-broadcast-deck'),
    decoration: BoxDecoration(gradient: Cinema.scrim(fromTop: false)),
    child: SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(36, 48, 36, 16),
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
              const SizedBox(height: 12),
            ] else if (nowNext?.current != null) ...[
              _GuideProgress(nowNext: nowNext!),
              const SizedBox(height: 12),
            ],
            LayoutBuilder(
              builder: (context, constraints) {
                // Volume only means something in a window; a TV remote
                // owns it (and the app is always fullscreen there).
                if (!windowControls) return _transport();
                if (constraints.maxWidth >= 900) {
                  return _transport(trailing: _utilities());
                }
                return Column(
                  children: [
                    _transport(),
                    const SizedBox(height: 10),
                    _utilities(),
                  ],
                );
              },
            ),
          ],
        ),
      ),
    ),
  );
}

class _GuideProgress extends StatefulWidget {
  const _GuideProgress({required this.nowNext});
  final EpgNowNext nowNext;
  @override
  State<_GuideProgress> createState() => _GuideProgressState();
}

class _GuideProgressState extends State<_GuideProgress> {
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 30), (_) => setState(() {}));
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final current = widget.nowNext.current!;
    final next = widget.nowNext.next;
    final length = current.endUtc.difference(current.startUtc).inSeconds;
    final elapsed = DateTime.now()
        .toUtc()
        .difference(current.startUtc)
        .inSeconds;
    return Row(
      key: const ValueKey('player-guide-progress'),
      children: [
        Text(_clockTime(context, current.startUtc), style: _timeStyle),
        const SizedBox(width: 12),
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(2),
            child: LinearProgressIndicator(
              value: length <= 0 ? 0 : (elapsed / length).clamp(0.0, 1.0),
              minHeight: 4,
              color: Cinema.amber,
              backgroundColor: const Color(0x2EF5F1E8),
            ),
          ),
        ),
        const SizedBox(width: 12),
        Text(_clockTime(context, current.endUtc), style: _timeStyle),
        if (next != null) ...[
          const SizedBox(width: 16),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 280),
            child: Text.rich(
              TextSpan(
                children: [
                  const TextSpan(text: 'Up next · '),
                  TextSpan(
                    text: next.title,
                    style: const TextStyle(
                      color: Cinema.text,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Cinema.quiet, fontSize: 12),
            ),
          ),
        ],
      ],
    );
  }
}

String _clockTime(BuildContext context, DateTime utc) =>
    MaterialLocalizations.of(context).formatTimeOfDay(
      TimeOfDay.fromDateTime(utc.toLocal()),
      alwaysUse24HourFormat: MediaQuery.alwaysUse24HourFormatOf(context),
    );

List<Widget> _spaced(List<Widget> actions) => [
  for (var index = 0; index < actions.length; index++) ...[
    if (index > 0) const SizedBox(width: 12),
    actions[index],
  ],
];

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
      color: const Color(0x99050507),
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
              padding: const EdgeInsets.fromLTRB(32, 24, 32, 24),
              decoration: const BoxDecoration(
                color: Cinema.card,
                borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
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
                            'Audio & subtitles',
                            style: TextStyle(
                              color: Cinema.text,
                              fontFamily: Cinema.display,
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
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 10,
                      runSpacing: 10,
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
                    const SizedBox(height: 20),
                    const Text('Subtitles', style: _ledgerHeading),
                    if (state.subtitleTracks.isEmpty)
                      const Padding(
                        padding: EdgeInsets.only(top: 8),
                        child: Text(
                          'No subtitle tracks reported',
                          style: _ledgerEmpty,
                        ),
                      ),
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 10,
                      runSpacing: 10,
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
  color: Cinema.text,
  fontSize: 14,
  fontWeight: FontWeight.w700,
);
const _ledgerEmpty = TextStyle(color: Cinema.faint, fontSize: 13);

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

  String get title => switch (handoff.mediaKind) {
    PlaybackMediaKind.live => "Can't play this channel",
    PlaybackMediaKind.movie => "Can't play this movie",
    PlaybackMediaKind.episode => "Can't play this episode",
  };

  String get failureMessage => switch (failure) {
    PlaybackSessionFailure.credentialsUnavailable =>
      "Sign in to this source again.",
    PlaybackSessionFailure.unavailable => "The stream isn't available.",
    PlaybackSessionFailure.timedOut => 'The stream took too long to start.',
  };

  @override
  Widget build(BuildContext context) => Center(
    child: SingleChildScrollView(
      child: Container(
        key: const ValueKey('player-failure-deck'),
        width: 420,
        margin: const EdgeInsets.all(24),
        padding: const EdgeInsets.fromLTRB(28, 28, 28, 18),
        decoration: BoxDecoration(
          color: Cinema.card,
          borderRadius: BorderRadius.circular(22),
          boxShadow: const [
            BoxShadow(
              color: Color(0x8C000000),
              blurRadius: 60,
              offset: Offset(0, 24),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 48,
              height: 48,
              decoration: const BoxDecoration(
                color: Color(0x24FFB547),
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.error_outline_rounded,
                color: Cinema.amber,
                size: 24,
              ),
            ),
            const SizedBox(height: 14),
            Text(
              title,
              style: const TextStyle(
                color: Cinema.text,
                fontFamily: Cinema.display,
                fontSize: 22,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              failureMessage,
              style: const TextStyle(
                color: Cinema.quiet,
                fontSize: 14,
                height: 1.45,
              ),
            ),
            const SizedBox(height: 20),
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
                  label:
                      failure == PlaybackSessionFailure.credentialsUnavailable
                      ? 'Open Settings'
                      : 'Try again',
                  onPressed: onPrimary,
                  onDown: onDown,
                  onLeft: detailsFocus.requestFocus,
                  onRight: backFocus.requestFocus,
                ),
                _TextAction(
                  key: const ValueKey('player-recovery-back'),
                  focusRingKey: const ValueKey(
                    'player-recovery-back-focus-ring',
                  ),
                  focusNode: backFocus,
                  label: 'Back',
                  onPressed: onBack,
                  onDown: onDown,
                  onLeft: primaryFocus.requestFocus,
                  onRight: detailsFocus.requestFocus,
                ),
                for (final variant in variants)
                  _TextAction(
                    label: 'Try ${variant.label}',
                    onPressed: () => onVariant(variant),
                    onDown: onDown,
                  ),
              ],
            ),
            const SizedBox(height: 8),
            _TextAction(
              key: const ValueKey('player-recovery-details'),
              focusRingKey: const ValueKey(
                'player-recovery-details-focus-ring',
              ),
              focusNode: detailsFocus,
              quiet: true,
              label: detailsVisible ? 'Hide details' : 'Details',
              onPressed: onDetails,
              onDown: onDown,
              onLeft: backFocus.requestFocus,
              onRight: primaryFocus.requestFocus,
            ),
            if (message != null) ...[
              const SizedBox(height: 10),
              Text(message!, style: _ledgerEmpty),
            ],
            if (detailsVisible)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  'Category: ${failure.name}\nMedia: ${handoff.mediaKind.name}\nAttempts: $attempts\nLocal time: ${_localTime()}',
                  key: const ValueKey('player-technical-details'),
                  style: const TextStyle(
                    color: Cinema.faint,
                    fontSize: 13,
                    height: 1.4,
                  ),
                ),
              ),
          ],
        ),
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
  // A drag previews here and seeks once on release, not once per frame.
  // Changes outside a drag (screen-reader increase/decrease) seek at once,
  // because they never get an onChangeEnd.
  Duration? dragging;
  bool dragActive = false;
  @override
  Widget build(BuildContext context) {
    final maximum = widget.duration.inMilliseconds.toDouble();
    final position = dragging ?? widget.position;
    final value = maximum <= 0
        ? 0.0
        : position.inMilliseconds.clamp(0, maximum).toDouble();
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
        value: '${_time(position)} of ${_time(widget.duration)}',
        child: AnimatedContainer(
          key: const ValueKey('player-timeline'),
          duration: const Duration(milliseconds: 120),
          height: 32,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: focused ? Cinema.glass : Colors.transparent,
            borderRadius: BorderRadius.circular(16),
            boxShadow: focused ? Cinema.focusGlow : null,
          ),
          child: Row(
            children: [
              Text(_time(position), style: _timeStyle),
              Expanded(
                child: SliderTheme(
                  data: SliderThemeData(
                    trackHeight: 4,
                    activeTrackColor: Cinema.amber,
                    inactiveTrackColor: const Color(0x2EF5F1E8),
                    thumbColor: Cinema.amber,
                    thumbShape: RoundSliderThumbShape(
                      enabledThumbRadius: focused ? 8 : 6,
                    ),
                    overlayShape: SliderComponentShape.noOverlay,
                  ),
                  child: Slider(
                    value: value,
                    max: maximum <= 0 ? 1 : maximum,
                    onChangeStart: (_) => dragActive = true,
                    onChanged: maximum <= 0
                        ? null
                        : (value) {
                            final target = Duration(
                              milliseconds: value.round(),
                            );
                            if (!dragActive) return widget.onChanged(target);
                            setState(() => dragging = target);
                          },
                    onChangeEnd: (value) {
                      dragActive = false;
                      setState(() => dragging = null);
                      widget.onChanged(Duration(milliseconds: value.round()));
                    },
                  ),
                ),
              ),
              Text(_time(widget.duration), style: _timeStyle),
            ],
          ),
        ),
      ),
    );
  }
}

const _timeStyle = TextStyle(
  color: Cinema.faint,
  fontSize: 12,
  fontFeatures: [FontFeature.tabularFigures()],
);

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
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        height: 44,
        padding: const EdgeInsets.symmetric(horizontal: 6),
        decoration: BoxDecoration(
          color: focused ? Cinema.glassFocused : Cinema.glass,
          borderRadius: BorderRadius.circular(22),
          boxShadow: focused ? Cinema.focusGlow : null,
        ),
        child: SliderTheme(
          data: SliderThemeData(
            trackHeight: 4,
            activeTrackColor: Cinema.text,
            inactiveTrackColor: const Color(0x33F5F1E8),
            thumbColor: Cinema.text,
            thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
            overlayShape: SliderComponentShape.noOverlay,
          ),
          child: Slider(
            value: widget.value.clamp(0, 100),
            max: 100,
            onChanged: widget.onChanged,
          ),
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
    this.primary = false,
    this.iconTurns = 0,
    this.onBack,
    this.onDown,
  });
  final IconData icon;
  final String label;
  final VoidCallback onPressed;
  final FocusNode? focusNode;

  /// The one amber, larger action in a row: Play/Pause.
  final bool primary;
  final int iconTurns;
  final VoidCallback? onBack, onDown;
  @override
  State<_DeckAction> createState() => _DeckActionState();
}

class _DeckActionState extends State<_DeckAction> {
  bool focused = false;
  @override
  Widget build(BuildContext context) {
    final size = widget.primary ? 56.0 : 44.0;
    return Focus(
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
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 120),
              width: size,
              height: size,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: widget.primary
                    ? Cinema.amber
                    : focused
                    ? Cinema.glassFocused
                    : Cinema.glass,
                boxShadow: focused ? Cinema.focusGlow : null,
              ),
              child: RotatedBox(
                quarterTurns: widget.iconTurns,
                child: Icon(
                  widget.icon,
                  color: widget.primary ? Cinema.amberInk : Cinema.text,
                  size: widget.primary ? 28 : 22,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _TextAction extends StatefulWidget {
  const _TextAction({
    super.key,
    required this.label,
    required this.onPressed,
    this.focusNode,
    this.primary = false,
    this.quiet = false,
    this.onDown,
    this.focusRingKey,
    this.onLeft,
    this.onRight,
  });
  final String label;
  final VoidCallback? onPressed;
  final FocusNode? focusNode;

  /// Amber fill for the main choice; [quiet] is a bare text link.
  final bool primary, quiet;
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
      child: GestureDetector(
        onTap: widget.onPressed,
        child: AnimatedContainer(
          key: widget.focusRingKey,
          duration: const Duration(milliseconds: 120),
          height: 44,
          padding: EdgeInsets.symmetric(horizontal: widget.quiet ? 12 : 22),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: widget.primary
                ? Cinema.amber
                : widget.quiet && !focused
                ? Colors.transparent
                : focused
                ? Cinema.glassFocused
                : Cinema.glass,
            borderRadius: BorderRadius.circular(22),
            boxShadow: focused ? Cinema.focusGlow : null,
          ),
          child: Text(
            widget.label,
            style: TextStyle(
              color: widget.primary
                  ? Cinema.amberInk
                  : widget.quiet
                  ? Cinema.faint
                  : Cinema.text,
              fontSize: widget.quiet ? 13 : 14,
              fontWeight: widget.primary ? FontWeight.w700 : FontWeight.w600,
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
