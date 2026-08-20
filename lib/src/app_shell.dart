import 'dart:async';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';

import 'features/artwork/artwork_loader.dart';
import 'features/artwork/source_artwork.dart';
import 'features/browse/basic_browse_screen.dart';
import 'features/browse/catalog_scope_controller.dart';
import 'features/browse/playback_handoff.dart';
import 'features/home/home_screen.dart';
import 'features/guide/guide_data.dart';
import 'features/guide/guide_screen.dart';
import 'features/library/library_group_manager.dart';
import 'features/library/my_library_screen.dart';
import 'features/library/my_library_service.dart';
import 'features/library/library_organization_service.dart';
import 'features/library/library_organizer.dart';
import 'features/playback/player_screen.dart';
import 'features/playback/multiview_screen.dart';
import 'features/playback/pip_overlay.dart';
import 'features/playback/playback_manager.dart';
import 'features/playback/playback_runtime_adapters.dart';
import 'features/search/local_search_screen.dart';
import 'features/settings/startup_preferences_controller.dart';
import 'features/sources/credential_store.dart';
import 'features/sources/library_visibility_screen.dart';
import 'features/sources/library_visibility_service.dart';
import 'features/sources/source_editor.dart';
import 'features/sources/source_models.dart';
import 'features/sources/source_catalog_database.dart';
import 'features/sources/source_management_service.dart';
import 'features/sources/source_setup_controller.dart';
import 'features/sources/source_setup_screen.dart';
import 'features/sources/source_management_screen.dart';
import 'features/sources/startup_models.dart';
import 'features/sources/xtream_epg_service.dart';
import 'home_fixture_mode.dart';

const _rail = Color(0xFF171818);
const _raised = Color(0xFF222321);
const _railSelected = Color(0xFF262624);
const _railSelectedHover = Color(0xFF2A2B29);
const _line = Color(0xFF343534);
const _warmWhite = Color(0xFFF4F0E7);
const _quietText = Color(0xFFAAA8A2);
const _amber = Color(0xFFFFB347);
const _lastChannelUnavailableNotice =
    'Last channel is unavailable. Wabbit opened Home instead.';

enum ShellDestination {
  home,
  live,
  guide,
  movies,
  series,
  search,
  library,
  settings,
}

enum _PlaybackSurfaceMode { full, pip, selectingSecondChannel, multiview }

extension ShellDestinationLabel on ShellDestination {
  String get label => switch (this) {
    ShellDestination.home => 'Home',
    ShellDestination.live => 'Live',
    ShellDestination.guide => 'Guide',
    ShellDestination.movies => 'Movies',
    ShellDestination.series => 'Series',
    ShellDestination.search => 'Search',
    ShellDestination.library => 'My Library',
    ShellDestination.settings => 'Settings',
  };

  IconData get icon => switch (this) {
    ShellDestination.home => Icons.home_outlined,
    ShellDestination.live => Icons.live_tv_outlined,
    ShellDestination.guide => Icons.view_week_outlined,
    ShellDestination.movies => Icons.movie_outlined,
    ShellDestination.series => Icons.tv_outlined,
    ShellDestination.search => Icons.search,
    ShellDestination.library => Icons.bookmark_border,
    ShellDestination.settings => Icons.settings_outlined,
  };
}

class WabbitShell extends StatefulWidget {
  const WabbitShell({
    super.key,
    required this.fixtureMode,
    this.sourceController,
    this.sourceManagementController,
    this.browseSource,
    this.browseData,
    this.scopedBrowseData,
    this.catalogScopeController,
    this.localSearchData,
    this.homeController,
    this.artworkProvider,
    this.myLibraryData,
    this.playbackSourceResolver,
    this.initialDestination,
    this.onPlaybackHandoff,
    this.credentialStore,
    this.playbackTransportFactory,
    this.fullscreenPort,
    this.m3uFilePicker,
    this.libraryVisibilityPort,
    this.libraryOrganizationPort,
    this.playbackManager,
    this.startupPreferencesController,
    this.guideData,
  });

  final HomeFixtureMode fixtureMode;
  final SourceSetupController? sourceController;
  final SourceManagementController? sourceManagementController;
  final PersistedSource? browseSource;
  final BasicBrowseData? browseData;
  final ScopedBrowseData? scopedBrowseData;
  final CatalogScopeController? catalogScopeController;
  final LocalSearchData? localSearchData;
  final HomeController? homeController;

  /// Optional bounded artwork provider for tests. Production owns one shared
  /// loader so Browse, Search, Home, and My Library reuse the same cache.
  final ArtworkProvider? artworkProvider;
  final MyLibraryData? myLibraryData;

  /// Optional exact-source resolver for player integration tests. Production
  /// uses the app-owned catalog scope controller's local database port.
  final FutureOr<PersistedSource?> Function(String sourceId)?
  playbackSourceResolver;
  final ShellDestination? initialDestination;

  /// Optional test seam; normal app flow opens the shaped production player.
  final ValueChanged<PlaybackHandoff>? onPlaybackHandoff;
  final CredentialStore? credentialStore;
  final PlaybackTransportFactory? playbackTransportFactory;
  final FullscreenPort? fullscreenPort;

  /// Test seam for the Windows-native local M3U picker.
  final M3uFilePicker? m3uFilePicker;

  /// Test seam for the credential-free local visibility ledger. Production
  /// shares the app-owned catalog database below.
  final LibraryVisibilityPort? libraryVisibilityPort;
  final LibraryOrganizationPort? libraryOrganizationPort;

  /// One shell-lifetime playback owner. Tests may inject a manager with fake
  /// ports; production creates the direct database-backed manager below.
  final PlaybackManager? playbackManager;

  /// Test seam for the one app-level startup settings owner. Production uses
  /// the same local catalog database as the rest of the shell.
  final StartupPreferencesController? startupPreferencesController;

  /// Shared shell-lifetime Guide/Now-Next seam. Production creates one
  /// database-backed instance with one bounded Xtream coordinator.
  final GuideDataPort? guideData;

  @override
  State<WabbitShell> createState() => _WabbitShellState();
}

class _WabbitShellState extends State<WabbitShell> {
  final FocusNode _railFocus = FocusNode(debugLabel: 'navigation rail');
  final FocusNode _firstContentFocus = FocusNode(debugLabel: 'home first item');
  final FocusScopeNode _personalTransientFocusScope = FocusScopeNode(
    debugLabel: 'personal library transient',
    traversalEdgeBehavior: TraversalEdgeBehavior.closedLoop,
    directionalTraversalEdgeBehavior: TraversalEdgeBehavior.closedLoop,
  );
  final FocusScopeNode _pipStopFocusScope = FocusScopeNode(
    debugLabel: 'stop picture in picture confirmation',
    traversalEdgeBehavior: TraversalEdgeBehavior.closedLoop,
    directionalTraversalEdgeBehavior: TraversalEdgeBehavior.closedLoop,
  );
  final FocusNode _pipStopCancelFocus = FocusNode(
    debugLabel: 'cancel stopping picture in picture',
  );
  final FocusNode _pipStopConfirmFocus = FocusNode(
    debugLabel: 'confirm stopping picture in picture',
  );
  final FocusNode _pipRestoreFocus = FocusNode(
    debugLabel: 'picture in picture return',
  );
  final FocusNode _pipMoveFocus = FocusNode(
    debugLabel: 'picture in picture move corner',
  );
  final FocusNode _pipMuteFocus = FocusNode(
    debugLabel: 'picture in picture mute',
  );
  final FocusNode _pipCloseFocus = FocusNode(
    debugLabel: 'picture in picture close',
  );
  final FocusNode _nowPlayingFocus = FocusNode(
    debugLabel: 'now playing navigation',
  );
  final GlobalKey _pipBoundsKey = GlobalKey(debugLabel: 'corner signal bounds');
  final GlobalKey _pipSurfaceKey = GlobalKey(
    debugLabel: 'corner signal surface',
  );
  late final Map<ShellDestination, FocusNode> _navigationFocus = {
    for (final destination in ShellDestination.values)
      destination: FocusNode(debugLabel: '${destination.label} navigation'),
  };

  late ShellDestination _destination;
  bool _railHovered = false;
  PlaybackHandoff? _playback;
  FocusNode? _playbackOrigin;
  PlaybackSessionId? _primaryPlaybackSessionId;
  PlaybackHandoff? _secondPlayback;
  PlaybackSessionId? _secondPlaybackSessionId;
  _PlaybackSurfaceMode? _playbackMode;
  PipCorner _pipCorner = PipCorner.bottomRight;
  bool _playbackStarting = false;
  int _playbackRequestGeneration = 0;
  PlaybackHandoff? _pendingPlayback;
  String? _pendingPlaybackTitle;
  bool _secondChannelBusy = false;
  String? _secondChannelMessage;
  VoidCallback? _pipStopContinuation;
  FocusNode? _pipStopOrigin;
  bool _pipStopBusy = false;
  bool _sourceSetupFromHome = false;
  bool _sourceSetupOpen = false;
  SourceEditorRequest? _sourceEditorRequest;
  Completer<void>? _sourceEditorCompletion;
  Future<void>? _destinationTransition;
  bool _restoreSourceManagementSelectedRowFocus = false;
  bool _restoreSourceManagementVisibilityFocus = false;
  SourceRosterEntry? _libraryVisibilitySource;
  bool _libraryVisibilityBusy = false;
  LibraryOrganizerRequest? _organizerRequest;
  FocusNode? _organizerOrigin;
  bool _organizerBusy = false;
  LibraryGroupManagementRequest? _groupManagementRequest;
  FocusNode? _groupManagementOrigin;
  bool _groupManagementBusy = false;
  int _organizationRevision = 0;
  late bool _startupResolving;
  bool _startupNoticeVisible = false;
  FocusNode? _lastContentFocus;
  final BasicBrowseSession _browseSession = BasicBrowseSession();
  final LocalSearchSession _searchSession = LocalSearchSession();
  final HomeSession _homeSession = HomeSession();
  final GuideSession _guideSession = GuideSession();
  MyLibrarySession _myLibrarySession = MyLibrarySession();
  bool _myLibraryNeedsRefresh = false;
  late final SourceCatalogDatabase _catalogDatabase = SourceCatalogDatabase();
  late final CredentialStore _playbackCredentialStore =
      widget.credentialStore ?? SecureCredentialStore();
  late final XtreamEpgService _epgService = XtreamEpgService(
    database: _catalogDatabase,
    credentialStore: _playbackCredentialStore,
  );
  late final GuideDataPort _guideData =
      widget.guideData ??
      DatabaseGuideDataPort(
        database: _catalogDatabase,
        epgService: _epgService,
      );
  bool get _ownsEpgService => widget.guideData == null;
  late final PlaybackManager _playbackManager =
      widget.playbackManager ??
      PlaybackManager(
        targetResolver: SourcePlaybackTargetResolver(
          sourceResolver: _resolvePlaybackSource,
          credentialStore: _playbackCredentialStore,
        ),
        admissionPort: DatabasePlaybackAdmissionPort(_catalogDatabase),
        progressPort: DatabasePlaybackProgressPort(_catalogDatabase),
        transportFactory: widget.playbackTransportFactory,
      );
  bool get _ownsPlaybackManager => widget.playbackManager == null;
  late final ArtworkProvider _artworkProvider =
      widget.artworkProvider ?? ArtworkLoader();
  bool get _ownsArtworkProvider => widget.artworkProvider == null;
  late final HomeController _homeController =
      widget.homeController ??
      HomeController(data: DatabaseHomeData(_catalogDatabase));
  bool get _ownsHomeController => widget.homeController == null;
  late final MyLibraryData _myLibraryData =
      widget.myLibraryData ?? DatabaseMyLibraryData(_catalogDatabase);
  late final LibraryVisibilityPort _libraryVisibilityPort =
      widget.libraryVisibilityPort ??
      DatabaseLibraryVisibilityPort(_catalogDatabase);
  late final LibraryOrganizationPort _libraryOrganizationPort =
      widget.libraryOrganizationPort ??
      DatabaseLibraryOrganizationPort(_catalogDatabase);
  late final CatalogScopeController _catalogScopeController =
      widget.catalogScopeController ??
      CatalogScopeController(port: DatabaseCatalogScopePort(_catalogDatabase));
  bool get _ownsCatalogScopeController => widget.catalogScopeController == null;
  late final ScopedBrowseData _scopedBrowseData =
      widget.scopedBrowseData ?? DatabaseBasicBrowseData(_catalogDatabase);
  late final LocalSearchData _localSearchData =
      widget.localSearchData ?? DatabaseLocalSearchData(_catalogDatabase);
  late final SourceSetupController _sourceController =
      widget.sourceController ?? SourceSetupController();
  bool get _ownsSourceController => widget.sourceController == null;
  late final SourceManagementService _sourceManagementService =
      SourceManagementService(
        sourceController: _sourceController,
        onEditAndRefresh: _openSourceEditor,
      );
  late final SourceManagementController _sourceManagementController =
      widget.sourceManagementController ??
      SourceManagementController(port: _sourceManagementService);
  bool get _ownsSourceManagementController =>
      widget.sourceManagementController == null;
  late final StartupPreferencesController _startupPreferencesController =
      widget.startupPreferencesController ??
      StartupPreferencesController(
        port: DatabaseStartupPreferencesPort(_catalogDatabase),
      );
  bool get _ownsStartupPreferencesController =>
      widget.startupPreferencesController == null;

  /// Explicit Phase 1 browse seams still exercise the named-source directory.
  /// Scope-aware integration begins only when a scope controller is supplied.
  bool get _usesLegacyBrowse =>
      widget.catalogScopeController == null &&
      (widget.fixtureMode != HomeFixtureMode.runtime ||
          widget.browseData != null ||
          widget.browseSource != null);

  /// Explicit destinations are fixture/test instructions and must never be
  /// replaced by durable startup behavior.
  bool get _startupPreferencesEnabled =>
      widget.fixtureMode == HomeFixtureMode.runtime &&
      widget.initialDestination == null &&
      !_usesLegacyBrowse;

  bool get _railExpanded =>
      _railHovered ||
      _railFocus.hasFocus ||
      _nowPlayingFocus.hasFocus ||
      _navigationFocus.values.any((node) => node.hasFocus);

  bool get _personalTransientOpen =>
      _organizerRequest != null || _groupManagementRequest != null;

  bool get _pipActive =>
      _playbackMode == _PlaybackSurfaceMode.pip ||
      _playbackMode == _PlaybackSurfaceMode.selectingSecondChannel;

  bool get _multiviewActive => _playbackMode == _PlaybackSurfaceMode.multiview;

  bool get _playbackSurfaceOpen =>
      _playbackMode == _PlaybackSurfaceMode.full ||
      _playbackMode == _PlaybackSurfaceMode.multiview;

  bool get _pipStopConfirmationOpen => _pipStopContinuation != null;

  PipCorner get _presentedPipCorner => _railExpanded
      ? switch (_pipCorner) {
          PipCorner.topLeft => PipCorner.topRight,
          PipCorner.bottomLeft => PipCorner.bottomRight,
          PipCorner.topRight || PipCorner.bottomRight => _pipCorner,
        }
      : _pipCorner;

  @override
  void initState() {
    super.initState();
    _destination = widget.initialDestination ?? ShellDestination.home;
    _startupResolving = _startupPreferencesEnabled;
    _railFocus.addListener(_refreshShell);
    _nowPlayingFocus.addListener(_refreshShell);
    for (final node in _navigationFocus.values) {
      node.addListener(_refreshShell);
    }
    _sourceController.addListener(_refreshShell);
    _sourceManagementController.addListener(_sourceManagementChanged);
    _playbackManager.addListener(_playbackManagerChanged);
    unawaited(_initializeRuntimeState());
  }

  @override
  void dispose() {
    _railFocus
      ..removeListener(_refreshShell)
      ..dispose();
    _personalTransientFocusScope.dispose();
    _pipStopFocusScope.dispose();
    _pipStopCancelFocus.dispose();
    _pipStopConfirmFocus.dispose();
    _pipRestoreFocus.dispose();
    _pipMoveFocus.dispose();
    _pipMuteFocus.dispose();
    _pipCloseFocus.dispose();
    _nowPlayingFocus
      ..removeListener(_refreshShell)
      ..dispose();
    _playbackManager.removeListener(_playbackManagerChanged);
    if (_ownsPlaybackManager) _playbackManager.dispose();
    if (_ownsEpgService) _epgService.cancel();
    _sourceController.removeListener(_refreshShell);
    _sourceManagementController.removeListener(_sourceManagementChanged);
    if (_ownsSourceController) _sourceController.dispose();
    if (_ownsSourceManagementController) _sourceManagementController.dispose();
    if (_ownsStartupPreferencesController) {
      _startupPreferencesController.dispose();
    }
    if (_ownsCatalogScopeController) _catalogScopeController.dispose();
    if (_ownsHomeController) _homeController.dispose();
    if (_ownsArtworkProvider) (_artworkProvider as ArtworkLoader).close();
    _firstContentFocus.dispose();
    for (final node in _navigationFocus.values) {
      node.removeListener(_refreshShell);
      node.dispose();
    }
    super.dispose();
  }

  void _refreshShell() {
    if (!mounted) return;
    setState(() {});
    if (_pipActive && _railExpanded) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _avoidExpandedRailWithPip();
      });
    }
  }

  void _setRailHovered(bool hovered) {
    if (_railHovered == hovered) return;
    setState(() => _railHovered = hovered);
    if (hovered && _pipActive) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _avoidExpandedRailWithPip();
      });
    }
  }

  void _playbackManagerChanged() {
    if (!mounted) return;
    if (_playbackStarting &&
        _primaryPlaybackSessionId == null &&
        _pendingPlayback != null &&
        _playbackManager.sessions.isNotEmpty) {
      final opening = _playbackManager.sessions.last;
      setState(() {
        _playback = _pendingPlayback;
        _primaryPlaybackSessionId = opening.id;
        _playbackMode = _PlaybackSurfaceMode.full;
        _playbackStarting = false;
        _pendingPlaybackTitle = null;
      });
      return;
    }
    final primary = _primaryPlaybackSessionId;
    if (primary != null && _playbackManager.session(primary) == null) {
      _clearPlaybackPresentation();
      return;
    }
    final second = _secondPlaybackSessionId;
    if (second != null && _playbackManager.session(second) == null) {
      _secondPlaybackSessionId = null;
      _secondPlayback = null;
      _playbackMode = primary == null ? null : _PlaybackSurfaceMode.full;
    }
    setState(() {});
  }

  void _sourceManagementChanged() {
    _myLibraryNeedsRefresh = true;
  }

  /// Both controllers touch the same local catalog on a fresh installation.
  /// Sequence their startup migration work without delaying the first frame.
  Future<void> _initializeRuntimeState() async {
    try {
      if (!_usesLegacyBrowse) await _catalogScopeController.initialize();
      if (widget.fixtureMode == HomeFixtureMode.runtime) {
        try {
          await _sourceController.initialize();
        } catch (_) {
          // Home reads its own local truth and must leave the initializing
          // state even when credential recovery fails independently.
        } finally {
          await _homeController.initialize();
        }
      }
      if (_startupPreferencesEnabled) {
        await _startupPreferencesController.initialize();
        await _resolvePersistedStartup();
      }
    } catch (_) {
      // A missing/corrupt settings read or an independent local initialization
      // failure must never strand the first focus plane.
      if (_startupPreferencesEnabled) {
        _finishStartupAt(ShellDestination.home);
      }
    } finally {
      if (mounted && _startupResolving) {
        _finishStartupAt(ShellDestination.home);
      }
    }
  }

  Future<void> _resolvePersistedStartup() async {
    StartupResolution resolution;
    try {
      resolution = await _startupPreferencesController
          .resolveStartupDestination();
    } catch (_) {
      _finishStartupAt(ShellDestination.home);
      return;
    }
    if (!mounted) return;
    final requestedLastChannel =
        _startupPreferencesController.preference.target ==
        StartupTarget.lastChannel;
    final item = resolution.lastLiveItem;
    if (resolution.opensLastChannel && item != null) {
      try {
        final handoff = playbackHandoffForLibrary(item);
        if (handoff.mediaKind != PlaybackMediaKind.live) {
          _fallbackFromUnavailableLastChannel();
          return;
        }
        _finishStartupAt(ShellDestination.live, requestFocus: false);
        unawaited(_savePreviousDestination(ShellDestination.live));
        await _startPrimaryPlayback(
          handoff,
          originOverride: _firstContentFocus,
        );
        return;
      } catch (_) {
        _fallbackFromUnavailableLastChannel();
        return;
      }
    }
    if (requestedLastChannel &&
        resolution.destination == StartupDestinationSlug.home) {
      _fallbackFromUnavailableLastChannel();
      return;
    }
    _finishStartupAt(_shellDestinationFor(resolution.destination));
  }

  void _fallbackFromUnavailableLastChannel() {
    _finishStartupAt(ShellDestination.home);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _destination != ShellDestination.home) return;
      final messenger = ScaffoldMessenger.maybeOf(context);
      if (messenger == null) return;
      _startupNoticeVisible = true;
      final controller = messenger.showSnackBar(
        SnackBar(
          key: const ValueKey('startup-last-channel-unavailable'),
          duration: const Duration(seconds: 6),
          content: Semantics(
            liveRegion: true,
            label: _lastChannelUnavailableNotice,
            child: const Text(_lastChannelUnavailableNotice),
          ),
        ),
      );
      unawaited(
        controller.closed.whenComplete(() {
          _startupNoticeVisible = false;
        }),
      );
    });
  }

  void _clearStartupNotice() {
    if (!_startupNoticeVisible) return;
    _startupNoticeVisible = false;
    ScaffoldMessenger.maybeOf(context)?.hideCurrentSnackBar();
  }

  ShellDestination _shellDestinationFor(StartupDestinationSlug slug) =>
      switch (slug) {
        StartupDestinationSlug.home => ShellDestination.home,
        StartupDestinationSlug.live => ShellDestination.live,
        StartupDestinationSlug.guide => ShellDestination.guide,
        StartupDestinationSlug.movies => ShellDestination.movies,
        StartupDestinationSlug.series => ShellDestination.series,
        StartupDestinationSlug.search => ShellDestination.search,
        StartupDestinationSlug.library => ShellDestination.library,
        StartupDestinationSlug.settings => ShellDestination.settings,
      };

  StartupDestinationSlug _startupSlugFor(ShellDestination destination) =>
      switch (destination) {
        ShellDestination.home => StartupDestinationSlug.home,
        ShellDestination.live => StartupDestinationSlug.live,
        ShellDestination.guide => StartupDestinationSlug.guide,
        ShellDestination.movies => StartupDestinationSlug.movies,
        ShellDestination.series => StartupDestinationSlug.series,
        ShellDestination.search => StartupDestinationSlug.search,
        ShellDestination.library => StartupDestinationSlug.library,
        ShellDestination.settings => StartupDestinationSlug.settings,
      };

  void _finishStartupAt(
    ShellDestination destination, {
    bool requestFocus = true,
  }) {
    if (!mounted) return;
    setState(() {
      _destination = destination;
      _startupResolving = false;
    });
    if (!requestFocus) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _lastContentFocus = _firstContentFocus;
      _firstContentFocus.requestFocus();
    });
  }

  Future<void> _savePreviousDestination(ShellDestination destination) async {
    if (!_startupPreferencesEnabled || _startupResolving) return;
    try {
      await _startupPreferencesController.savePreviousDestination(
        _startupSlugFor(destination),
      );
    } catch (_) {
      // Navigation remains authoritative when a background preference write
      // fails; the prior durable destination is left unchanged.
    }
  }

  void _openRail() {
    _navigationFocus[_destination]!.requestFocus();
  }

  void _handleMenu() {
    if (_startupResolving ||
        _personalTransientOpen ||
        _playbackSurfaceOpen ||
        _playbackStarting ||
        _pipStopConfirmationOpen) {
      return;
    }
    if (_nowPlayingFocus.hasFocus ||
        _navigationFocus.values.any((node) => node.hasFocus)) {
      return;
    }
    _openRail();
  }

  void _closeRail() {
    final target =
        _lastContentFocus?.parent != null && _lastContentFocus!.canRequestFocus
        ? _lastContentFocus
        : _firstContentFocus;
    target!.requestFocus();
  }

  void _handleBack() {
    if (_startupResolving || _playbackStarting) return;
    if (_pipStopConfirmationOpen) {
      _cancelPipStopConfirmation();
      return;
    }
    if (_groupManagementRequest != null) {
      _closeGroupManagement();
      return;
    }
    if (_organizerRequest != null) {
      _closeOrganizer();
      return;
    }
    if (_playbackMode == _PlaybackSurfaceMode.selectingSecondChannel) {
      _cancelSecondChannelSelection();
      return;
    }
    if (_playbackMode == _PlaybackSurfaceMode.pip) {
      _restorePipToFullPlayer();
      return;
    }
    if (_multiviewActive) {
      unawaited(_collapseMultiview());
      return;
    }
    if (_railExpanded) {
      _closeRail();
    } else {
      _openRail();
    }
  }

  void _selectDestination(ShellDestination destination) {
    if (_startupResolving || _playbackStarting) return;
    if (_organizerRequest != null || _groupManagementRequest != null) return;
    if (_pipStopConfirmationOpen || _pipStopBusy) return;
    if (_pipActive && destination == ShellDestination.settings) {
      _navigationFocus[destination]!.requestFocus();
      _requestPipStopThen(() => _applyDestination(destination));
      return;
    }
    if (_playbackMode == _PlaybackSurfaceMode.selectingSecondChannel &&
        destination != ShellDestination.live) {
      return;
    }
    if (_playbackSurfaceOpen) return;
    if (_libraryVisibilitySource != null && _libraryVisibilityBusy) return;
    if (_sourceSetupOpen && _sourceEditorRequest != null) {
      if (_destinationTransition != null) return;
      final transition = _closeEditorAndSelectDestination(destination);
      _destinationTransition = transition;
      unawaited(
        transition.whenComplete(() {
          if (identical(_destinationTransition, transition)) {
            _destinationTransition = null;
          }
        }),
      );
      return;
    }
    _applyDestination(destination);
  }

  Future<void> _closeEditorAndSelectDestination(
    ShellDestination destination,
  ) async {
    await _closeSourceSetup();
    if (mounted) _applyDestination(destination);
  }

  void _applyDestination(ShellDestination destination) {
    _clearStartupNotice();
    if (destination == ShellDestination.library && _myLibraryNeedsRefresh) {
      _myLibrarySession = MyLibrarySession();
      _myLibraryNeedsRefresh = false;
    }
    setState(() {
      _destination = destination;
      _sourceSetupFromHome = false;
      _sourceSetupOpen = false;
      _libraryVisibilitySource = null;
      _libraryVisibilityBusy = false;
      _restoreSourceManagementSelectedRowFocus = false;
      _restoreSourceManagementVisibilityFocus = false;
    });
    unawaited(_savePreviousDestination(destination));
    if (!_usesLegacyBrowse && _isCatalogDestination(destination)) {
      // Source operations are durable, not event-streamed into the shell.
      // Refresh only at a destination boundary so disabled/removed scopes fall
      // back before the next catalog settles, without requerying on focus.
      unawaited(_catalogScopeController.refresh());
    }
    if (widget.fixtureMode == HomeFixtureMode.runtime &&
        destination == ShellDestination.home) {
      unawaited(_homeController.refresh());
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // This shared node is attached to the selected destination's visible
      // first target after rebuild; never retain a detached Home card target.
      _lastContentFocus = _firstContentFocus;
      _firstContentFocus.requestFocus();
    });
  }

  void _captureContentFocus(FocusNode node) {
    _lastContentFocus = node;
    if (_pipActive) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _avoidFocusedTargetWithPip(node);
      });
    }
  }

  void _movePipCorner() {
    if (!_pipActive) return;
    final resolved = _pipCornerAvoiding(_pipCorner.next, _lastContentFocus);
    _relocatePip(resolved);
  }

  void _avoidFocusedTargetWithPip(FocusNode? target) {
    if (!_pipActive || target == null) return;
    final targetRect = _focusRect(target);
    final currentRect = _pipRectFor(_pipCorner);
    if (targetRect == null ||
        currentRect == null ||
        !currentRect.overlaps(targetRect.inflate(8))) {
      return;
    }
    final resolved = _pipCornerAvoiding(_pipCorner.next, target);
    if (resolved != _pipCorner) _relocatePip(resolved);
  }

  void _avoidExpandedRailWithPip() {
    if (!_pipActive || !_railExpanded) return;
    final requested = switch (_pipCorner) {
      PipCorner.topLeft => PipCorner.topRight,
      PipCorner.bottomLeft => PipCorner.bottomRight,
      PipCorner.topRight || PipCorner.bottomRight => _pipCorner,
    };
    if (requested != _pipCorner) _relocatePip(requested);
  }

  PipCorner _pipCornerAvoiding(PipCorner requested, FocusNode? target) {
    final targetRect = target == null ? null : _focusRect(target)?.inflate(8);
    final geometry = _pipGeometry();
    if (targetRect == null || geometry == null) return requested;
    return pipCornerAvoidingTarget(
      requested: requested,
      bounds: geometry.$1,
      surfaceSize: geometry.$2,
      target: targetRect,
    );
  }

  Rect? _pipRectFor(PipCorner corner) {
    final geometry = _pipGeometry();
    if (geometry == null) return null;
    return pipCornerRect(
      corner: corner,
      bounds: geometry.$1,
      surfaceSize: geometry.$2,
    );
  }

  (Rect, Size)? _pipGeometry() {
    final boundsBox = _pipBoundsKey.currentContext?.findRenderObject();
    final surfaceBox = _pipSurfaceKey.currentContext?.findRenderObject();
    if (boundsBox is! RenderBox ||
        surfaceBox is! RenderBox ||
        !boundsBox.attached ||
        !surfaceBox.attached ||
        !boundsBox.hasSize ||
        !surfaceBox.hasSize) {
      return null;
    }
    final boundsOrigin = boundsBox.localToGlobal(Offset.zero);
    final bounds = boundsOrigin & boundsBox.size;
    return (bounds, surfaceBox.size);
  }

  Rect? _focusRect(FocusNode node) {
    final renderObject = node.context?.findRenderObject();
    if (renderObject is! RenderBox ||
        !renderObject.attached ||
        !renderObject.hasSize) {
      return null;
    }
    return renderObject.localToGlobal(Offset.zero) & renderObject.size;
  }

  void _relocatePip(PipCorner corner) {
    if (!_pipActive || corner == _pipCorner) return;
    setState(() => _pipCorner = corner);
    unawaited(
      SemanticsService.sendAnnouncement(
        View.of(context),
        'Corner Signal moved to ${corner.label}.',
        Directionality.of(context),
      ),
    );
  }

  void _openOrganizer(LibraryOrganizerRequest request) {
    if (_playbackStarting) return;
    if (_pipActive) {
      _requestPipStopThen(() => _openOrganizer(request));
      return;
    }
    if (_organizerRequest != null ||
        _groupManagementRequest != null ||
        _playback != null) {
      return;
    }
    setState(() {
      _organizerOrigin = FocusManager.instance.primaryFocus;
      _organizerRequest = request;
      _organizerBusy = false;
    });
  }

  void _organizerBusyChanged(bool busy) {
    if (!mounted || _organizerRequest == null) return;
    _organizerBusy = busy;
  }

  void _closeOrganizer() {
    if (_organizerRequest == null || _organizerBusy) return;
    final origin = _organizerOrigin;
    setState(() {
      _organizerRequest = null;
      _organizerOrigin = null;
      _organizerBusy = false;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final target = origin?.parent != null && origin!.canRequestFocus
          ? origin
          : _firstContentFocus.parent != null &&
                _firstContentFocus.canRequestFocus
          ? _firstContentFocus
          : null;
      target?.requestFocus();
    });
  }

  void _organizerSaved() {
    if (!mounted) return;
    _organizationRevision += 1;
    _organizerBusy = false;
    _closeOrganizer();
    unawaited(_homeController.refresh());
  }

  void _openGroupManagement(LibraryGroupManagementRequest request) {
    if (_playbackStarting) return;
    if (_pipActive) {
      _requestPipStopThen(() => _openGroupManagement(request));
      return;
    }
    if (_organizerRequest != null ||
        _groupManagementRequest != null ||
        _playback != null) {
      return;
    }
    setState(() {
      _groupManagementOrigin = FocusManager.instance.primaryFocus;
      _groupManagementRequest = request;
      _groupManagementBusy = false;
    });
  }

  void _groupManagementBusyChanged(bool busy) {
    if (!mounted || _groupManagementRequest == null) return;
    _groupManagementBusy = busy;
  }

  void _groupManagementChanged() {
    if (!mounted) return;
    setState(() => _organizationRevision += 1);
    unawaited(_homeController.refresh());
  }

  void _closeGroupManagement() {
    if (_groupManagementRequest == null || _groupManagementBusy) return;
    final origin = _groupManagementOrigin;
    setState(() {
      _groupManagementRequest = null;
      _groupManagementOrigin = null;
      _groupManagementBusy = false;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final target = origin?.parent != null && origin!.canRequestFocus
          ? origin
          : _firstContentFocus.parent != null &&
                _firstContentFocus.canRequestFocus
          ? _firstContentFocus
          : null;
      target?.requestFocus();
    });
  }

  void _beginPlayback(PlaybackHandoff handoff) {
    _clearStartupNotice();
    if (_playbackMode == _PlaybackSurfaceMode.selectingSecondChannel) {
      unawaited(_selectSecondChannel(handoff));
      return;
    }
    final external = widget.onPlaybackHandoff;
    if (external != null) {
      external(handoff);
      return;
    }
    unawaited(_startPrimaryPlayback(handoff));
  }

  Future<void> _startPrimaryPlayback(
    PlaybackHandoff handoff, {
    FocusNode? originOverride,
  }) async {
    if (_playbackStarting || _secondChannelBusy) return;
    final generation = ++_playbackRequestGeneration;
    final origin = originOverride ?? FocusManager.instance.primaryFocus;
    _clearPlaybackFields(preserveOrigin: true);
    setState(() {
      _playbackStarting = true;
      _pendingPlayback = handoff;
      _pendingPlaybackTitle = handoff.title;
      _playbackOrigin = origin;
    });
    if (_playbackManager.sessions.isNotEmpty) {
      await _playbackManager.stopAll();
      if (!mounted || generation != _playbackRequestGeneration) return;
    }
    final result = await _playbackManager.start(handoff);
    if (!mounted || generation != _playbackRequestGeneration) return;
    final sessionId = _startedSessionId(result);
    if (sessionId == null) {
      setState(() {
        _playbackStarting = false;
        _pendingPlayback = null;
        _pendingPlaybackTitle = null;
      });
      _showPlaybackNotice(_blockMessage(result));
      _restoreFocus(origin);
      return;
    }
    setState(() {
      _playbackStarting = false;
      _pendingPlayback = null;
      _pendingPlaybackTitle = null;
      _playbackOrigin = origin;
      _playback = handoff;
      _primaryPlaybackSessionId = sessionId;
      _playbackMode = _PlaybackSurfaceMode.full;
    });
  }

  Future<void> _exitPlayback() async {
    if (!mounted) return;
    _playbackRequestGeneration += 1;
    _pendingPlayback = null;
    _playbackStarting = false;
    final origin = _playbackOrigin;
    _clearPlaybackFields();
    await _playbackManager.stopAll();
    if (mounted) _restoreFocus(origin);
  }

  Future<void> _openPlaybackSettings() async {
    await _exitPlayback();
    if (mounted) _selectDestination(ShellDestination.settings);
  }

  void _enterPip() {
    if (_primaryPlaybackSessionId == null || _playback == null) return;
    setState(() => _playbackMode = _PlaybackSurfaceMode.pip);
    final origin = _lastContentFocus ?? _playbackOrigin;
    _restoreFocus(origin);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _avoidFocusedTargetWithPip(origin);
    });
  }

  void _restorePipToFullPlayer() {
    if (!_pipActive ||
        _primaryPlaybackSessionId == null ||
        _secondChannelBusy) {
      return;
    }
    setState(() {
      _playbackMode = _PlaybackSurfaceMode.full;
      _secondChannelBusy = false;
      _secondChannelMessage = null;
    });
  }

  void _beginSecondChannelSelection() {
    final handoff = _playback;
    if (handoff == null ||
        handoff.mediaKind != PlaybackMediaKind.live ||
        _primaryPlaybackSessionId == null) {
      return;
    }
    setState(() {
      _destination = ShellDestination.live;
      _playbackMode = _PlaybackSurfaceMode.selectingSecondChannel;
      _secondChannelBusy = false;
      _secondChannelMessage = null;
    });
    unawaited(_savePreviousDestination(ShellDestination.live));
    if (!_usesLegacyBrowse) unawaited(_catalogScopeController.refresh());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _lastContentFocus = _firstContentFocus;
      _firstContentFocus.requestFocus();
    });
  }

  void _cancelSecondChannelSelection() {
    if (_playbackMode != _PlaybackSurfaceMode.selectingSecondChannel ||
        _secondChannelBusy) {
      return;
    }
    setState(() {
      _playbackMode = _PlaybackSurfaceMode.full;
      _secondChannelMessage = null;
    });
  }

  Future<void> _selectSecondChannel(PlaybackHandoff handoff) async {
    if (_playbackMode != _PlaybackSurfaceMode.selectingSecondChannel ||
        _secondChannelBusy ||
        handoff.mediaKind != PlaybackMediaKind.live) {
      return;
    }
    final original = _playback;
    if (original == null || _samePlaybackIdentity(original, handoff)) {
      setState(
        () =>
            _secondChannelMessage = 'Already playing. Choose another channel.',
      );
      return;
    }
    setState(() {
      _secondChannelBusy = true;
      _secondChannelMessage = null;
    });
    final result = await _playbackManager.start(
      handoff,
      requestAudioFocus: false,
    );
    if (!mounted) return;
    final secondId = _startedSessionId(result);
    if (secondId == null) {
      setState(() {
        _secondChannelBusy = false;
        _secondChannelMessage = _blockMessage(result);
      });
      return;
    }
    if (result is PlaybackStartFailed) {
      await _playbackManager.stop(secondId);
      if (!mounted) return;
      setState(() {
        _secondChannelBusy = false;
        _secondChannelMessage = 'The second channel could not start. The current channel is still playing.';
      });
      return;
    }
    setState(() {
      _secondChannelBusy = false;
      _secondChannelMessage = null;
      _secondPlayback = handoff;
      _secondPlaybackSessionId = secondId;
      _playbackMode = _PlaybackSurfaceMode.multiview;
    });
  }

  Future<void> _togglePipMute() async {
    if (_secondChannelBusy) return;
    final id = _primaryPlaybackSessionId;
    final snapshot = id == null ? null : _playbackManager.session(id);
    if (id == null || snapshot == null) return;
    await _playbackManager.setMuted(id, snapshot.isAudible);
  }

  Future<void> _closePip() async {
    if (_secondChannelBusy) return;
    final origin = _lastContentFocus ?? _playbackOrigin;
    final id = _primaryPlaybackSessionId;
    _clearPlaybackFields();
    if (id != null) await _playbackManager.stop(id);
    if (mounted) _restoreFocus(origin);
  }

  Future<void> _openMultiviewFullPlayer(PlaybackSessionId id) async {
    if (!_multiviewActive || _playbackManager.session(id) == null) return;
    final primaryId = _primaryPlaybackSessionId;
    final secondId = _secondPlaybackSessionId;
    if (primaryId == null || secondId == null) return;
    final selectedHandoff = id == primaryId ? _playback : _secondPlayback;
    final otherId = id == primaryId ? secondId : primaryId;
    if (selectedHandoff == null) return;
    setState(() {
      _playback = selectedHandoff;
      _primaryPlaybackSessionId = id;
      _secondPlayback = null;
      _secondPlaybackSessionId = null;
      _playbackMode = _PlaybackSurfaceMode.full;
    });
    await _playbackManager.stop(otherId);
  }

  Future<void> _closeMultiviewSession(PlaybackSessionId id) async {
    if (!_multiviewActive) return;
    final primaryId = _primaryPlaybackSessionId;
    final secondId = _secondPlaybackSessionId;
    if (primaryId == null || secondId == null) return;
    if (id == secondId) {
      await _collapseMultiview();
      return;
    }
    if (id != primaryId) return;
    final promoted = _secondPlayback;
    if (promoted == null) return;
    setState(() {
      _playback = promoted;
      _primaryPlaybackSessionId = secondId;
      _secondPlayback = null;
      _secondPlaybackSessionId = null;
      _playbackMode = _PlaybackSurfaceMode.full;
    });
    await _playbackManager.stop(primaryId);
    await _playbackManager.setAudioOwner(secondId);
  }

  Future<void> _collapseMultiview() async {
    if (!_multiviewActive) return;
    final originalId = _primaryPlaybackSessionId;
    final secondId = _secondPlaybackSessionId;
    if (originalId == null) return;
    setState(() {
      _secondPlayback = null;
      _secondPlaybackSessionId = null;
      _playbackMode = _PlaybackSurfaceMode.full;
    });
    if (secondId != null) await _playbackManager.stop(secondId);
    await _playbackManager.setAudioOwner(originalId);
  }

  void _requestPipStopThen(VoidCallback continuation) {
    if (!_pipActive || _pipStopConfirmationOpen || _secondChannelBusy) {
      return;
    }
    setState(() {
      _pipStopOrigin = FocusManager.instance.primaryFocus;
      _pipStopContinuation = continuation;
      _pipStopBusy = false;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _pipStopCancelFocus.requestFocus();
    });
  }

  void _cancelPipStopConfirmation() {
    if (!_pipStopConfirmationOpen || _pipStopBusy) return;
    final origin = _pipStopOrigin;
    setState(() {
      _pipStopContinuation = null;
      _pipStopOrigin = null;
    });
    _restoreFocus(origin);
  }

  Future<void> _confirmPipStop() async {
    final continuation = _pipStopContinuation;
    if (continuation == null || _pipStopBusy) return;
    setState(() => _pipStopBusy = true);
    await _playbackManager.stopAll();
    if (!mounted) return;
    setState(() {
      _clearPlaybackFields();
      _pipStopContinuation = null;
      _pipStopOrigin = null;
      _pipStopBusy = false;
    });
    continuation();
  }

  PlaybackSessionId? _startedSessionId(PlaybackStartResult result) =>
      switch (result) {
        PlaybackStarted(:final sessionId) => sessionId,
        PlaybackStartFailed(:final sessionId) => sessionId,
        PlaybackBlocked() => null,
      };

  String _blockMessage(PlaybackStartResult result) => switch (result) {
    PlaybackBlocked(
      reason: PlaybackBlockReason.sourceLimit,
      :final effectiveLimit,
    ) =>
      'This source currently allows ${effectiveLimit ?? 1} stream${effectiveLimit == 1 ? '' : 's'}. Cancel adding a second channel, then open Settings to change the local limit.',
    PlaybackBlocked(reason: PlaybackBlockReason.globalMaximum) =>
      'Two streams are already active. Close one before adding another.',
    PlaybackBlocked(reason: PlaybackBlockReason.managerClosed) =>
      'Playback is unavailable until Wabbit TV restarts.',
    _ => 'Playback could not start.',
  };

  void _showPlaybackNotice(String message) {
    final messenger = ScaffoldMessenger.maybeOf(context);
    messenger
      ?..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  void _clearPlaybackFields({bool preserveOrigin = false}) {
    _playback = null;
    _primaryPlaybackSessionId = null;
    _secondPlayback = null;
    _secondPlaybackSessionId = null;
    _playbackMode = null;
    _secondChannelBusy = false;
    _secondChannelMessage = null;
    if (!preserveOrigin) _playbackOrigin = null;
  }

  void _clearPlaybackPresentation() {
    if (!mounted) return;
    final origin = _lastContentFocus ?? _playbackOrigin;
    setState(() => _clearPlaybackFields());
    _restoreFocus(origin);
  }

  void _restoreFocus(FocusNode? preferred) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final target = preferred?.parent != null && preferred!.canRequestFocus
          ? preferred
          : _firstContentFocus.parent != null &&
                _firstContentFocus.canRequestFocus
          ? _firstContentFocus
          : null;
      target?.requestFocus();
    });
  }

  void _openSourceSetupFromHome() {
    if (_playbackStarting) return;
    if (_pipActive) {
      _requestPipStopThen(_openSourceSetupFromHome);
      return;
    }
    if (!_sourceController.prepareForAddSource()) return;
    setState(() {
      _destination = ShellDestination.settings;
      _sourceSetupFromHome = true;
      _sourceSetupOpen = true;
      _libraryVisibilitySource = null;
      _libraryVisibilityBusy = false;
      _restoreSourceManagementSelectedRowFocus = false;
      _restoreSourceManagementVisibilityFocus = false;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _firstContentFocus.requestFocus();
    });
  }

  void _openSourceSetupFromManagement() {
    if (!_sourceController.prepareForAddSource()) return;
    setState(() {
      _sourceSetupFromHome = false;
      _sourceSetupOpen = true;
      _sourceEditorRequest = null;
      _restoreSourceManagementSelectedRowFocus = false;
      _restoreSourceManagementVisibilityFocus = false;
      _libraryVisibilitySource = null;
      _libraryVisibilityBusy = false;
    });
  }

  Future<void> _openSourceEditor(String sourceId) {
    final entry = _sourceManagementController.entries
        .where((candidate) => candidate.id == sourceId)
        .firstOrNull;
    if (entry == null || _sourceEditorCompletion != null) {
      return Future<void>.error(StateError('Source editor is unavailable.'));
    }
    final completion = Completer<void>();
    _sourceEditorCompletion = completion;
    setState(() {
      _sourceSetupFromHome = false;
      _sourceSetupOpen = true;
      _sourceEditorRequest = SourceEditorRequest(
        sourceId: entry.id,
        sourceName: entry.name,
        databaseKind: entry.kind,
      );
      _restoreSourceManagementSelectedRowFocus = false;
      _restoreSourceManagementVisibilityFocus = false;
      _libraryVisibilitySource = null;
      _libraryVisibilityBusy = false;
    });
    return completion.future;
  }

  void _exitSourceSetup() {
    unawaited(_closeSourceSetup());
  }

  Future<void> _closeSourceSetup() async {
    final wasEditor = _sourceEditorRequest;
    final completion = _sourceEditorCompletion;
    _sourceEditorCompletion = null;
    if (!_sourceSetupOpen) {
      if (completion != null && !completion.isCompleted) completion.complete();
      return;
    }
    if (_sourceSetupFromHome) {
      setState(() {
        _sourceSetupOpen = false;
        _sourceEditorRequest = null;
      });
      if (!_usesLegacyBrowse) unawaited(_catalogScopeController.refresh());
      _selectDestination(ShellDestination.home);
      return;
    }

    // A durable refresh can finish before the Source Ledger exits. Refresh the
    // directory before rebuilding it, preserving the source id across rename.
    await _sourceManagementController.initialize();
    if (wasEditor != null) {
      _sourceManagementController.select(wasEditor.sourceId);
    }
    if (!mounted) {
      if (completion != null && !completion.isCompleted) completion.complete();
      return;
    }
    setState(() {
      _sourceSetupOpen = false;
      _sourceEditorRequest = null;
      _restoreSourceManagementSelectedRowFocus = true;
      _restoreSourceManagementVisibilityFocus = false;
    });
    if (!_usesLegacyBrowse) unawaited(_catalogScopeController.refresh());
    if (completion != null && !completion.isCompleted) completion.complete();
  }

  void _sourceEditorSaved() {
    unawaited(_closeSourceSetup());
  }

  void _openLibraryVisibility(SourceRosterEntry source) {
    if (_libraryVisibilitySource != null) return;
    setState(() {
      _libraryVisibilitySource = source;
      _libraryVisibilityBusy = false;
      _sourceSetupFromHome = false;
      _sourceSetupOpen = false;
      _restoreSourceManagementSelectedRowFocus = false;
      _restoreSourceManagementVisibilityFocus = false;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _firstContentFocus.requestFocus();
    });
  }

  void _exitLibraryVisibility() {
    unawaited(_closeLibraryVisibility());
  }

  void _libraryVisibilityBusyChanged(bool busy) {
    if (_libraryVisibilitySource == null) return;
    _libraryVisibilityBusy = busy;
  }

  Future<void> _closeLibraryVisibility() async {
    if (_libraryVisibilitySource == null || _libraryVisibilityBusy) return;
    // Visibility writes are already durable in the ledger. One shared scope
    // refresh at this continuation boundary invalidates Browse/Search without
    // reloading the global catalog after every individual toggle.
    _myLibraryNeedsRefresh = true;
    setState(() {
      _libraryVisibilitySource = null;
      _libraryVisibilityBusy = false;
      _restoreSourceManagementSelectedRowFocus = false;
      _restoreSourceManagementVisibilityFocus = true;
    });
    if (!_usesLegacyBrowse) await _catalogScopeController.refresh();
  }

  bool _isCatalogDestination(ShellDestination destination) =>
      destination == ShellDestination.live ||
      destination == ShellDestination.guide ||
      destination == ShellDestination.movies ||
      destination == ShellDestination.series ||
      destination == ShellDestination.search;

  Future<PersistedSource?> _resolvePlaybackSource(String sourceId) async {
    final resolver = widget.playbackSourceResolver;
    if (resolver != null) return await resolver(sourceId);
    if (!_usesLegacyBrowse) {
      return await _catalogScopeController.resolveReadySource(sourceId);
    }

    // Fixtures never enter the production database. Only use this fallback
    // when it is the exact source carried by the handoff.
    final fallback = widget.browseSource ?? _sourceController.persisted;
    return fallback?.id == sourceId ? fallback : null;
  }

  Future<void> _recordUsableVideo(PlaybackHandoff handoff) async {
    final libraryItemId = handoff.libraryItemId;
    if (libraryItemId == null) return;
    if (handoff.mediaKind == PlaybackMediaKind.live &&
        _startupPreferencesEnabled) {
      try {
        await _startupPreferencesController.saveLastLiveLibraryItem(
          libraryItemId,
        );
      } catch (_) {
        // Recently watched and playback stay usable when this preference-only
        // write fails. The prior exact last channel remains durable.
      }
    }
    try {
      final recorded = await _catalogDatabase.recordRecentlyWatched(
        libraryItemId,
      );
      if (recorded) await _homeController.refresh();
    } catch (_) {
      // Watch history and startup preference are independent local ledgers.
    }
  }

  void _recordAudibleMultiviewSession(PlaybackSessionId id) {
    final handoff = id == _primaryPlaybackSessionId
        ? _playback
        : id == _secondPlaybackSessionId
        ? _secondPlayback
        : null;
    if (handoff != null) unawaited(_recordUsableVideo(handoff));
  }

  Widget _buildPlaybackSurface() {
    final mode = _playbackMode;
    final originalId = _primaryPlaybackSessionId;
    final original = _playback;
    if (mode == _PlaybackSurfaceMode.multiview) {
      final secondId = _secondPlaybackSessionId;
      if (originalId == null || secondId == null) {
        return const SizedBox.expand();
      }
      return MultiviewScreen(
        manager: _playbackManager,
        originalSessionId: originalId,
        secondSessionId: secondId,
        onOpenFullPlayer: (id) => unawaited(_openMultiviewFullPlayer(id)),
        onCloseSession: (id) => unawaited(_closeMultiviewSession(id)),
        onCollapse: () => unawaited(_collapseMultiview()),
        onAudibleUsableVideo: _recordAudibleMultiviewSession,
      );
    }
    if (mode == _PlaybackSurfaceMode.full) {
      final selectedId = originalId;
      final selectedHandoff = original;
      if (selectedId == null || selectedHandoff == null) {
        return const SizedBox.expand();
      }
      return PlayerScreen(
        manager: _playbackManager,
        sessionId: selectedId,
        handoff: selectedHandoff,
        variantPort: DatabasePlaybackExactVariantPort(_catalogDatabase),
        fullscreenPort: widget.fullscreenPort,
        onExit: _exitPlayback,
        onOpenSettings: _openPlaybackSettings,
        onUsableVideo: _recordUsableVideo,
        onEnterPip: _enterPip,
        onAddChannel: selectedHandoff.mediaKind == PlaybackMediaKind.live
            ? _beginSecondChannelSelection
            : null,
      );
    }
    return const SizedBox.expand();
  }

  @override
  Widget build(BuildContext context) {
    final presentedPipCorner = _presentedPipCorner;
    final blockShellSemantics =
        _startupResolving ||
        _playbackSurfaceOpen ||
        _playbackStarting ||
        _pipStopConfirmationOpen;
    if (presentedPipCorner != _pipCorner) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _relocatePip(presentedPipCorner);
      });
    }
    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.escape): _handleBack,
        const SingleActivator(LogicalKeyboardKey.browserBack): _handleBack,
        const SingleActivator(LogicalKeyboardKey.contextMenu): _handleMenu,
      },
      child: FocusTraversalGroup(
        policy: WidgetOrderTraversalPolicy(),
        child: Scaffold(
          body: Stack(
            children: [
              // The body always reserves only the collapsed rail width. The expanded
              // rail is an overlay, so mouse/focus expansion cannot shift content.
              Positioned.fill(
                left: 72,
                child: ExcludeSemantics(
                  excluding: blockShellSemantics,
                  child: ExcludeFocus(
                    excluding:
                        _startupResolving ||
                        _personalTransientOpen ||
                        _playbackSurfaceOpen ||
                        _playbackStarting ||
                        _pipStopConfirmationOpen,
                    child: _ShellBody(
                      destination: _destination,
                      fixtureMode: widget.fixtureMode,
                      initialContentFocus: _firstContentFocus,
                      onContentFocus: _captureContentFocus,
                      onOpenRail: _openRail,
                      onSelectDestination: _selectDestination,
                      sourceSetupFromHome: _sourceSetupFromHome,
                      sourceSetupOpen: _sourceSetupOpen,
                      onOpenSourceSetupFromManagement:
                          _openSourceSetupFromManagement,
                      onOpenSourceSetupFromHome: _openSourceSetupFromHome,
                      onExitSourceSetup: _exitSourceSetup,
                      sourceEditorRequest: _sourceEditorRequest,
                      onSourceEditorSaved: _sourceEditorSaved,
                      restoreSourceManagementSelectedRowFocus:
                          _restoreSourceManagementSelectedRowFocus,
                      restoreSourceManagementVisibilityFocus:
                          _restoreSourceManagementVisibilityFocus,
                      libraryVisibilitySource: _libraryVisibilitySource,
                      libraryVisibilityPort: _libraryVisibilityPort,
                      onOpenLibraryVisibility: _openLibraryVisibility,
                      onExitLibraryVisibility: _exitLibraryVisibility,
                      onLibraryVisibilityBusyChanged:
                          _libraryVisibilityBusyChanged,
                      m3uFilePicker: widget.m3uFilePicker ?? _pickM3uFile,
                      sourceController: _sourceController,
                      sourceManagementController: _sourceManagementController,
                      startupPreferencesController: _startupPreferencesEnabled
                          ? _startupPreferencesController
                          : null,
                      browseSource: widget.browseSource,
                      browseData: widget.browseData,
                      scopedBrowseData: _scopedBrowseData,
                      catalogScopeController: _catalogScopeController,
                      useLegacyBrowse: _usesLegacyBrowse,
                      localSearchData: _localSearchData,
                      browseSession: _browseSession,
                      guideSession: _guideSession,
                      guideData: _guideData,
                      searchSession: _searchSession,
                      homeController: _homeController,
                      homeSession: _homeSession,
                      artworkProvider: _artworkProvider,
                      myLibraryData: _myLibraryData,
                      myLibrarySession: _myLibrarySession,
                      credentialStore: widget.credentialStore,
                      onPlaybackHandoff: _beginPlayback,
                      selectingSecondChannel:
                          _playbackMode ==
                          _PlaybackSurfaceMode.selectingSecondChannel,
                      secondChannelMessage: _secondChannelMessage,
                      secondChannelBusy: _secondChannelBusy,
                      onCancelSecondChannel: _cancelSecondChannelSelection,
                      onOrganizeItem: _openOrganizer,
                      onCreateGroup: () => _openGroupManagement(
                        const LibraryGroupManagementRequest.create(),
                      ),
                      onManageGroup: (group) => _openGroupManagement(
                        LibraryGroupManagementRequest.manage(group),
                      ),
                      organizationRevision: _organizationRevision,
                    ),
                  ),
                ),
              ),
              Positioned(
                left: 0,
                top: 0,
                bottom: 0,
                child: IgnorePointer(
                  ignoring:
                      _startupResolving ||
                      _personalTransientOpen ||
                      _playbackSurfaceOpen ||
                      _playbackStarting ||
                      _pipStopConfirmationOpen,
                  child: ExcludeSemantics(
                    excluding: blockShellSemantics,
                    child: ExcludeFocus(
                      excluding:
                          _startupResolving ||
                          _personalTransientOpen ||
                          _playbackSurfaceOpen ||
                          _playbackStarting ||
                          _pipStopConfirmationOpen,
                      child: Focus(
                        focusNode: _railFocus,
                        skipTraversal: true,
                        child: MouseRegion(
                          onEnter: (_) => _setRailHovered(true),
                          onExit: (_) => _setRailHovered(false),
                          child: _NavigationRail(
                            selected: _destination,
                            isExpanded: _railExpanded,
                            showFixtureLabel:
                                widget.fixtureMode != HomeFixtureMode.runtime ||
                                widget.browseData != null,
                            focusNodes: _navigationFocus,
                            onSelected: _selectDestination,
                            showNowPlaying: _pipActive,
                            nowPlayingFocus: _nowPlayingFocus,
                            onNowPlaying: () {
                              _pipRestoreFocus.requestFocus();
                            },
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              if (_playbackSurfaceOpen)
                Positioned.fill(
                  child: BlockSemantics(child: _buildPlaybackSurface()),
                ),
              if (_startupResolving)
                const Positioned.fill(
                  child: BlockSemantics(child: _StartupPreparingSurface()),
                ),
              if (_playbackStarting)
                Positioned.fill(
                  child: BlockSemantics(
                    child: ColoredBox(
                      key: const ValueKey('playback-starting-surface'),
                      color: const Color(0xFF111212),
                      child: Center(
                        child: Semantics(
                          liveRegion: true,
                          label: 'Starting playback',
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 14,
                              vertical: 10,
                            ),
                            decoration: BoxDecoration(
                              color: const Color(0xFF191A1A),
                              border: Border.all(color: _line),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              'Starting ${_pendingPlaybackTitle ?? 'playback'}',
                              style: const TextStyle(
                                color: _warmWhite,
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              if (_pipActive && _primaryPlaybackSessionId != null)
                Positioned.fill(
                  left: 72,
                  child: PipOverlay(
                    key: _pipBoundsKey,
                    surfaceKey: _pipSurfaceKey,
                    manager: _playbackManager,
                    sessionId: _primaryPlaybackSessionId!,
                    corner: presentedPipCorner,
                    restoreFocus: _pipRestoreFocus,
                    moveFocus: _pipMoveFocus,
                    muteFocus: _pipMuteFocus,
                    closeFocus: _pipCloseFocus,
                    statusMessage: _secondChannelBusy
                        ? 'Checking stream allowance…'
                        : null,
                    busy: _secondChannelBusy,
                    onRestore: _restorePipToFullPlayer,
                    onMove: _movePipCorner,
                    onToggleMute: () => unawaited(_togglePipMute()),
                    onClose: () => unawaited(_closePip()),
                  ),
                ),
              if (_organizerRequest != null && _playback == null)
                Positioned.fill(
                  left: 72,
                  child: FocusScope.withExternalFocusNode(
                    focusScopeNode: _personalTransientFocusScope,
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        final narrow = constraints.maxWidth < 760;
                        final drawerWidth = narrow
                            ? constraints.maxWidth
                            : 360.0;
                        return Stack(
                          children: [
                            Positioned.fill(
                              right: drawerWidth,
                              child: ModalBarrier(
                                color: Colors.transparent,
                                dismissible: !_organizerBusy,
                                onDismiss: _closeOrganizer,
                              ),
                            ),
                            Align(
                              alignment: Alignment.centerRight,
                              child: SizedBox(
                                width: drawerWidth,
                                child: LibraryOrganizerPane(
                                  request: _organizerRequest!,
                                  port: _libraryOrganizationPort,
                                  artworkLoader: _artworkProvider,
                                  onClose: _closeOrganizer,
                                  onSaved: _organizerSaved,
                                  onBusyChanged: _organizerBusyChanged,
                                ),
                              ),
                            ),
                          ],
                        );
                      },
                    ),
                  ),
                ),
              if (_groupManagementRequest != null && _playback == null)
                Positioned.fill(
                  left: 72,
                  child: FocusScope.withExternalFocusNode(
                    focusScopeNode: _personalTransientFocusScope,
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        final narrow = constraints.maxWidth < 760;
                        final paneWidth = narrow ? constraints.maxWidth : 460.0;
                        return Stack(
                          children: [
                            Positioned.fill(
                              right: paneWidth,
                              child: ModalBarrier(
                                color: Colors.transparent,
                                dismissible: !_groupManagementBusy,
                                onDismiss: _closeGroupManagement,
                              ),
                            ),
                            Align(
                              alignment: Alignment.centerRight,
                              child: SizedBox(
                                width: paneWidth,
                                child: LibraryGroupManagerPane(
                                  request: _groupManagementRequest!,
                                  port: _libraryOrganizationPort,
                                  onClose: _closeGroupManagement,
                                  onChanged: _groupManagementChanged,
                                  onBusyChanged: _groupManagementBusyChanged,
                                ),
                              ),
                            ),
                          ],
                        );
                      },
                    ),
                  ),
                ),
              if (_pipStopConfirmationOpen)
                Positioned.fill(
                  child: BlockSemantics(
                    child: Stack(
                      children: [
                        PipStopConfirmation(
                          focusScopeNode: _pipStopFocusScope,
                          cancelFocus: _pipStopCancelFocus,
                          stopFocus: _pipStopConfirmFocus,
                          busy: _pipStopBusy,
                          onCancel: _cancelPipStopConfirmation,
                          onStop: () => unawaited(_confirmPipStop()),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

Future<String?> _pickM3uFile() async {
  const playlistType = XTypeGroup(
    label: 'M3U playlists',
    extensions: <String>['m3u', 'm3u8'],
  );
  final selected = await openFile(
    acceptedTypeGroups: const <XTypeGroup>[playlistType],
  );
  return selected?.path;
}

class _StartupPreparingSurface extends StatelessWidget {
  const _StartupPreparingSurface();

  @override
  Widget build(BuildContext context) => ColoredBox(
    key: const ValueKey('startup-preparing-surface'),
    color: const Color(0xFF111212),
    child: Center(
      child: Semantics(
        liveRegion: true,
        label: 'Opening Wabbit TV',
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: const Color(0xFF191A1A),
            border: Border.all(color: _line),
            borderRadius: BorderRadius.circular(6),
          ),
          child: const Text(
            'Opening Wabbit TV…',
            style: TextStyle(
              color: _warmWhite,
              fontSize: 14,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ),
    ),
  );
}

bool _samePlaybackIdentity(PlaybackHandoff first, PlaybackHandoff second) {
  if (first.runtimeType != second.runtimeType ||
      first.sourceId != second.sourceId) {
    return false;
  }
  if (first.libraryItemId != null && second.libraryItemId != null) {
    return first.libraryItemId == second.libraryItemId;
  }
  if (first is XtreamPlaybackHandoff && second is XtreamPlaybackHandoff) {
    return first.providerItemId == second.providerItemId &&
        first.extension == second.extension;
  }
  if (first is M3uLivePlaybackHandoff && second is M3uLivePlaybackHandoff) {
    return first.uri == second.uri;
  }
  return false;
}

class _ShellBody extends StatelessWidget {
  const _ShellBody({
    required this.destination,
    required this.fixtureMode,
    required this.initialContentFocus,
    required this.onContentFocus,
    required this.onOpenRail,
    required this.onSelectDestination,
    required this.sourceSetupFromHome,
    required this.sourceSetupOpen,
    required this.onOpenSourceSetupFromManagement,
    required this.onOpenSourceSetupFromHome,
    required this.onExitSourceSetup,
    required this.sourceEditorRequest,
    required this.onSourceEditorSaved,
    required this.restoreSourceManagementSelectedRowFocus,
    required this.restoreSourceManagementVisibilityFocus,
    required this.libraryVisibilitySource,
    required this.libraryVisibilityPort,
    required this.onOpenLibraryVisibility,
    required this.onExitLibraryVisibility,
    required this.onLibraryVisibilityBusyChanged,
    required this.m3uFilePicker,
    required this.sourceController,
    required this.sourceManagementController,
    required this.startupPreferencesController,
    required this.browseSource,
    required this.browseData,
    required this.scopedBrowseData,
    required this.catalogScopeController,
    required this.useLegacyBrowse,
    required this.localSearchData,
    required this.browseSession,
    required this.guideSession,
    required this.guideData,
    required this.searchSession,
    required this.homeController,
    required this.homeSession,
    required this.artworkProvider,
    required this.myLibraryData,
    required this.myLibrarySession,
    required this.credentialStore,
    required this.onPlaybackHandoff,
    required this.selectingSecondChannel,
    required this.secondChannelMessage,
    required this.secondChannelBusy,
    required this.onCancelSecondChannel,
    required this.onOrganizeItem,
    required this.onCreateGroup,
    required this.onManageGroup,
    required this.organizationRevision,
  });

  final ShellDestination destination;
  final HomeFixtureMode fixtureMode;
  final FocusNode initialContentFocus;
  final ValueChanged<FocusNode> onContentFocus;
  final VoidCallback onOpenRail;
  final ValueChanged<ShellDestination> onSelectDestination;
  final bool sourceSetupFromHome;
  final bool sourceSetupOpen;
  final VoidCallback onOpenSourceSetupFromManagement;
  final VoidCallback onOpenSourceSetupFromHome;
  final VoidCallback onExitSourceSetup;
  final SourceEditorRequest? sourceEditorRequest;
  final VoidCallback onSourceEditorSaved;
  final bool restoreSourceManagementSelectedRowFocus;
  final bool restoreSourceManagementVisibilityFocus;
  final SourceRosterEntry? libraryVisibilitySource;
  final LibraryVisibilityPort libraryVisibilityPort;
  final ValueChanged<SourceRosterEntry> onOpenLibraryVisibility;
  final VoidCallback onExitLibraryVisibility;
  final ValueChanged<bool> onLibraryVisibilityBusyChanged;
  final M3uFilePicker m3uFilePicker;
  final SourceSetupController sourceController;
  final SourceManagementController sourceManagementController;
  final StartupPreferencesController? startupPreferencesController;
  final PersistedSource? browseSource;
  final BasicBrowseData? browseData;
  final ScopedBrowseData scopedBrowseData;
  final CatalogScopeController catalogScopeController;
  final bool useLegacyBrowse;
  final LocalSearchData localSearchData;
  final BasicBrowseSession browseSession;
  final GuideSession guideSession;
  final GuideDataPort guideData;
  final LocalSearchSession searchSession;
  final HomeController homeController;
  final HomeSession homeSession;
  final ArtworkProvider artworkProvider;
  final MyLibraryData myLibraryData;
  final MyLibrarySession myLibrarySession;
  final CredentialStore? credentialStore;
  final ValueChanged<PlaybackHandoff>? onPlaybackHandoff;
  final bool selectingSecondChannel;
  final String? secondChannelMessage;
  final bool secondChannelBusy;
  final VoidCallback onCancelSecondChannel;
  final ValueChanged<LibraryOrganizerRequest> onOrganizeItem;
  final VoidCallback onCreateGroup;
  final ValueChanged<PersonalLibraryDirectoryEntry> onManageGroup;
  final int organizationRevision;

  @override
  Widget build(BuildContext context) {
    if (destination == ShellDestination.home) {
      return HomeScreen(
        fixtureMode: fixtureMode,
        showFixtureCopy: fixtureMode != HomeFixtureMode.runtime,
        initialFocus: initialContentFocus,
        onContentFocus: onContentFocus,
        onOpenRail: onOpenRail,
        onBrowseLive: () => onSelectDestination(ShellDestination.live),
        onBrowseMovies: () => onSelectDestination(ShellDestination.movies),
        onBrowseSeries: () => onSelectDestination(ShellDestination.series),
        onAddSource: onOpenSourceSetupFromHome,
        controller: fixtureMode == HomeFixtureMode.runtime
            ? homeController
            : null,
        session: fixtureMode == HomeFixtureMode.runtime ? homeSession : null,
        artworkBuilder: fixtureMode == HomeFixtureMode.runtime
            ? (context, item, focused) => LayoutBuilder(
                builder: (context, constraints) => SourceArtwork(
                  locator: item.item.artworkLocator,
                  kind: item.item.kind,
                  loader: artworkProvider,
                  focused: focused,
                  loadWhenVisible: true,
                  width: constraints.maxWidth,
                  height: constraints.maxHeight,
                ),
              )
            : null,
        artworkLoader: artworkProvider,
        onPlaybackHandoff: onPlaybackHandoff,
        onOrganizeItem: (item) => onOrganizeItem(
          LibraryOrganizerRequest(
            libraryItemId: item.libraryItemId,
            title: item.title,
            kind: item.kind,
            artworkLocator: item.artworkLocator,
          ),
        ),
        onOrganizePersonalItem: (item) => onOrganizeItem(
          LibraryOrganizerRequest(
            libraryItemId: item.libraryItemId,
            title: item.title,
            kind: item.kind,
            artworkLocator: item.isAvailable ? item.artworkLocator : null,
          ),
        ),
        credentialStore: credentialStore,
        initializeController: false,
      );
    }

    if (destination == ShellDestination.settings && sourceSetupOpen) {
      return SourceSetupScreen(
        initialFocus: initialContentFocus,
        onContentFocus: onContentFocus,
        onExit: onExitSourceSetup,
        controller: sourceController,
        editRequest: sourceEditorRequest,
        onEditorSaved: onSourceEditorSaved,
        m3uFilePicker: m3uFilePicker,
        onBrowse: (kind) => onSelectDestination(switch (kind) {
          SourceMediaKind.live => ShellDestination.live,
          SourceMediaKind.movies => ShellDestination.movies,
          SourceMediaKind.series => ShellDestination.series,
        }),
      );
    }

    final visibilitySource = libraryVisibilitySource;
    if (destination == ShellDestination.settings && visibilitySource != null) {
      return LibraryVisibilityScreen(
        sourceId: visibilitySource.id,
        sourceName: visibilitySource.name,
        port: libraryVisibilityPort,
        initialFocus: initialContentFocus,
        onContentFocus: onContentFocus,
        onBack: onExitLibraryVisibility,
        onBusyChanged: onLibraryVisibilityBusyChanged,
      );
    }

    if (destination == ShellDestination.settings) {
      return SourceManagementScreen(
        initialFocus: initialContentFocus,
        onContentFocus: onContentFocus,
        onOpenRail: onOpenRail,
        onAddSource: onOpenSourceSetupFromManagement,
        onManageVisibility: onOpenLibraryVisibility,
        controller: sourceManagementController,
        startupPreferencesController: startupPreferencesController,
        restoreSelectedFocusOnEntry: restoreSourceManagementSelectedRowFocus,
        restoreVisibilityFocusOnEntry: restoreSourceManagementVisibilityFocus,
      );
    }

    if (destination == ShellDestination.guide) {
      return GuideScreen(
        initialFocus: initialContentFocus,
        onContentFocus: onContentFocus,
        onOpenRail: onOpenRail,
        session: guideSession,
        onPlaybackHandoff: onPlaybackHandoff ?? (_) {},
        data: guideData,
        onBrowseLive: () => onSelectDestination(ShellDestination.live),
        onOpenSettings: () => onSelectDestination(ShellDestination.settings),
      );
    }

    if (destination == ShellDestination.live ||
        destination == ShellDestination.movies ||
        destination == ShellDestination.series) {
      return BasicBrowseScreen(
        kind: switch (destination) {
          ShellDestination.live => SourceMediaKind.live,
          ShellDestination.movies => SourceMediaKind.movies,
          ShellDestination.series => SourceMediaKind.series,
          _ => throw StateError('Not a catalog destination'),
        },
        source: useLegacyBrowse
            ? (browseSource ?? sourceController.persisted)
            : null,
        initialFocus: initialContentFocus,
        onContentFocus: onContentFocus,
        onOpenRail: onOpenRail,
        onOpenSourceSetup: () => onSelectDestination(ShellDestination.settings),
        session: browseSession,
        data: browseData,
        scopedData: scopedBrowseData,
        scopeController: useLegacyBrowse ? null : catalogScopeController,
        onPlaybackHandoff: onPlaybackHandoff,
        selectingSecondChannel:
            destination == ShellDestination.live && selectingSecondChannel,
        secondChannelMessage: secondChannelMessage,
        secondChannelBusy: secondChannelBusy,
        onCancelSecondChannel: onCancelSecondChannel,
        onOrganizeItem: useLegacyBrowse
            ? null
            : (item) {
                final libraryItemId = item.libraryItemId;
                if (libraryItemId == null) return;
                onOrganizeItem(
                  LibraryOrganizerRequest(
                    libraryItemId: libraryItemId,
                    title: item.title,
                    kind: item.kind,
                    artworkLocator: item.artworkLocator,
                  ),
                );
              },
        credentialStore: credentialStore,
        artworkLoader: artworkProvider,
        epgWindowPort: destination == ShellDestination.live ? guideData : null,
      );
    }

    if (destination == ShellDestination.search) {
      return LocalSearchScreen(
        scopeController: catalogScopeController,
        initialFocus: initialContentFocus,
        onContentFocus: onContentFocus,
        onOpenRail: onOpenRail,
        session: searchSession,
        data: localSearchData,
        onPlaybackHandoff: onPlaybackHandoff,
        onOrganizeItem: (item) => onOrganizeItem(
          LibraryOrganizerRequest(
            libraryItemId: item.libraryItemId,
            title: item.title,
            kind: item.kind,
            artworkLocator: item.artworkLocator,
          ),
        ),
        credentialStore: credentialStore,
        artworkLoader: artworkProvider,
      );
    }

    if (destination == ShellDestination.library) {
      return MyLibraryScreen(
        data: myLibraryData,
        initialFocus: initialContentFocus,
        onContentFocus: onContentFocus,
        onOpenRail: onOpenRail,
        session: myLibrarySession,
        organizationRevision: organizationRevision,
        onPlaybackHandoff: onPlaybackHandoff,
        onOrganizeItem: (item) {
          final data = myLibraryData;
          final locator =
              item.artworkKey != null && data is DatabaseMyLibraryData
              ? data.artworkLocatorFor(item.id)
              : null;
          onOrganizeItem(
            LibraryOrganizerRequest(
              libraryItemId: item.id,
              title: item.title,
              kind: switch (item.kind) {
                MyLibraryMediaKind.live => SourceMediaKind.live,
                MyLibraryMediaKind.movie => SourceMediaKind.movies,
                MyLibraryMediaKind.series => SourceMediaKind.series,
              },
              artworkLocator: locator,
            ),
          );
        },
        onCreateGroup: onCreateGroup,
        onManageGroup: (section) {
          onManageGroup(
            PersonalLibraryDirectoryEntry(
              kind: section.kind == MyLibrarySectionKind.favorites
                  ? PersonalLibraryDirectoryKind.favorites
                  : PersonalLibraryDirectoryKind.customGroup,
              collectionId: section.kind == MyLibrarySectionKind.favorites
                  ? null
                  : section.id,
              name: section.name,
              itemCount: section.itemCount,
              directoryOrdinal: section.directoryOrdinal,
              homeOrdinal: section.homeOrdinal,
            ),
          );
        },
        credentialStore: credentialStore,
        continuationArtworkLoader: artworkProvider,
        artworkBuilder: (context, item, focused) {
          final data = myLibraryData;
          final locator =
              item.artworkKey != null && data is DatabaseMyLibraryData
              ? data.artworkLocatorFor(item.id)
              : null;
          return SourceArtwork(
            locator: locator,
            kind: switch (item.kind) {
              MyLibraryMediaKind.live => SourceMediaKind.live,
              MyLibraryMediaKind.movie => SourceMediaKind.movies,
              MyLibraryMediaKind.series => SourceMediaKind.series,
            },
            loader: artworkProvider,
            focused: focused,
            loadWhenVisible: true,
          );
        },
      );
    }

    return _DeferredDestination(
      destination: destination,
      initialFocus: initialContentFocus,
      onContentFocus: onContentFocus,
      onOpenRail: onOpenRail,
    );
  }
}

class _NavigationRail extends StatelessWidget {
  const _NavigationRail({
    required this.selected,
    required this.isExpanded,
    required this.showFixtureLabel,
    required this.focusNodes,
    required this.onSelected,
    required this.showNowPlaying,
    required this.nowPlayingFocus,
    required this.onNowPlaying,
  });

  final ShellDestination selected;
  final bool isExpanded;
  final bool showFixtureLabel;
  final Map<ShellDestination, FocusNode> focusNodes;
  final ValueChanged<ShellDestination> onSelected;
  final bool showNowPlaying;
  final FocusNode nowPlayingFocus;
  final VoidCallback onNowPlaying;

  @override
  Widget build(BuildContext context) {
    final railWidth = isExpanded ? 224.0 : 72.0;
    final motionDuration = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : const Duration(milliseconds: 150);
    return AnimatedContainer(
      duration: motionDuration,
      curve: Curves.easeOutCubic,
      width: railWidth,
      color: _rail,
      child: ClipRect(
        child: OverflowBox(
          alignment: Alignment.topLeft,
          minWidth: 224,
          maxWidth: 224,
          child: SizedBox(
            width: 224,
            child: DecoratedBox(
              decoration: const BoxDecoration(
                border: Border(right: BorderSide(color: _line)),
              ),
              child: SafeArea(
                child: Column(
                  children: [
                    const SizedBox(height: 12),
                    ConstrainedBox(
                      constraints: const BoxConstraints(minHeight: 52),
                      child: Row(
                        children: [
                          const SizedBox(width: 22),
                          const Icon(
                            Icons.play_circle_outline,
                            color: _quietText,
                            size: 27,
                          ),
                          if (isExpanded) ...[
                            const SizedBox(width: 12),
                            const Expanded(
                              child: Padding(
                                padding: EdgeInsets.symmetric(vertical: 8),
                                child: Text(
                                  'Wabbit TV',
                                  style: TextStyle(
                                    color: _warmWhite,
                                    fontSize: 18,
                                    fontWeight: FontWeight.w700,
                                    letterSpacing: -0.2,
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(width: 16),
                          ],
                        ],
                      ),
                    ),
                    const SizedBox(height: 20),
                    Expanded(
                      child: LayoutBuilder(
                        builder: (context, constraints) {
                          return SingleChildScrollView(
                            child: ConstrainedBox(
                              constraints: BoxConstraints(
                                minHeight: constraints.maxHeight,
                              ),
                              child: IntrinsicHeight(
                                child: Column(
                                  children: [
                                    for (final destination
                                        in ShellDestination.values.where(
                                          (candidate) =>
                                              candidate !=
                                              ShellDestination.settings,
                                        ))
                                      _RailDestination(
                                        destination: destination,
                                        isSelected: destination == selected,
                                        expanded: isExpanded,
                                        focusNode: focusNodes[destination]!,
                                        onPressed: () =>
                                            onSelected(destination),
                                      ),
                                    if (showNowPlaying)
                                      _RailNowPlaying(
                                        expanded: isExpanded,
                                        focusNode: nowPlayingFocus,
                                        onPressed: onNowPlaying,
                                      ),
                                    const Spacer(),
                                    if (isExpanded && showFixtureLabel)
                                      const Padding(
                                        padding: EdgeInsets.fromLTRB(
                                          20,
                                          12,
                                          16,
                                          12,
                                        ),
                                        child: Text(
                                          'Local fixture preview',
                                          style: TextStyle(
                                            color: _quietText,
                                            fontSize: 12,
                                          ),
                                        ),
                                      ),
                                    const Padding(
                                      key: ValueKey('rail-settings-separator'),
                                      padding: EdgeInsets.fromLTRB(
                                        18,
                                        8,
                                        18,
                                        6,
                                      ),
                                      child: Divider(
                                        height: 1,
                                        thickness: 1,
                                        color: _line,
                                      ),
                                    ),
                                    _RailDestination(
                                      destination: ShellDestination.settings,
                                      isSelected:
                                          selected == ShellDestination.settings,
                                      expanded: isExpanded,
                                      focusNode:
                                          focusNodes[ShellDestination
                                              .settings]!,
                                      onPressed: () =>
                                          onSelected(ShellDestination.settings),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          );
                        },
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
  }
}

class _RailDestination extends StatefulWidget {
  const _RailDestination({
    required this.destination,
    required this.isSelected,
    required this.expanded,
    required this.focusNode,
    required this.onPressed,
  });

  final ShellDestination destination;
  final bool isSelected;
  final bool expanded;
  final FocusNode focusNode;
  final VoidCallback onPressed;

  @override
  State<_RailDestination> createState() => _RailDestinationState();
}

class _RailDestinationState extends State<_RailDestination> {
  bool _hovered = false;

  void _keepVisible(bool focused) {
    if (!focused) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      Scrollable.ensureVisible(
        context,
        duration: Duration.zero,
        alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    return FocusableActionDetector(
      key: ValueKey('shell-destination-${widget.destination.name}'),
      focusNode: widget.focusNode,
      mouseCursor: SystemMouseCursors.click,
      shortcuts: const <ShortcutActivator, Intent>{
        SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
        SingleActivator(LogicalKeyboardKey.select): ActivateIntent(),
      },
      actions: <Type, Action<Intent>>{
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (_) {
            widget.onPressed();
            return null;
          },
        ),
      },
      onFocusChange: _keepVisible,
      onShowHoverHighlight: (hovered) {
        if (_hovered == hovered) return;
        setState(() => _hovered = hovered);
      },
      child: Builder(
        builder: (context) {
          final focused = Focus.of(context).hasFocus;
          return Semantics(
            button: true,
            selected: widget.isSelected,
            label: widget.destination.label,
            onTap: widget.onPressed,
            excludeSemantics: true,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: widget.onPressed,
              child: AnimatedContainer(
                duration: MediaQuery.disableAnimationsOf(context)
                    ? Duration.zero
                    : const Duration(milliseconds: 130),
                curve: Curves.easeOutCubic,
                constraints: const BoxConstraints(minHeight: 48),
                margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
                decoration: BoxDecoration(
                  color: widget.isSelected
                      ? _hovered
                            ? _railSelectedHover
                            : _railSelected
                      : _hovered
                      ? _raised
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(6),
                  border: focused
                      ? Border.all(color: _amber, width: 2)
                      : Border.all(color: Colors.transparent, width: 2),
                ),
                child: Stack(
                  alignment: Alignment.centerLeft,
                  children: [
                    if (widget.isSelected && !focused)
                      const Positioned(
                        left: 5,
                        top: 0,
                        bottom: 0,
                        child: Center(
                          child: ColoredBox(
                            key: ValueKey('rail-selected-location-marker'),
                            color: _quietText,
                            child: SizedBox(width: 2, height: 20),
                          ),
                        ),
                      ),
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 10,
                      ),
                      child: Row(
                        children: [
                          Icon(
                            widget.destination.icon,
                            key: ValueKey(
                              'shell-destination-icon-${widget.destination.name}',
                            ),
                            size: 22,
                            color: widget.isSelected || _hovered
                                ? _warmWhite
                                : _quietText,
                          ),
                          if (widget.expanded) ...[
                            const SizedBox(width: 14),
                            Expanded(
                              child: Text(
                                widget.destination.label,
                                softWrap: true,
                                style: TextStyle(
                                  color: widget.isSelected || _hovered
                                      ? _warmWhite
                                      : _quietText,
                                  fontSize: 15,
                                  fontWeight: widget.isSelected
                                      ? FontWeight.w700
                                      : FontWeight.w500,
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _RailNowPlaying extends StatefulWidget {
  const _RailNowPlaying({
    required this.expanded,
    required this.focusNode,
    required this.onPressed,
  });

  final bool expanded;
  final FocusNode focusNode;
  final VoidCallback onPressed;

  @override
  State<_RailNowPlaying> createState() => _RailNowPlayingState();
}

class _RailNowPlayingState extends State<_RailNowPlaying> {
  bool _hovered = false;

  void _keepVisible(bool focused) {
    if (!focused) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      Scrollable.ensureVisible(
        context,
        duration: Duration.zero,
        alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
      );
    });
  }

  @override
  Widget build(BuildContext context) => FocusableActionDetector(
    key: const ValueKey('shell-now-playing'),
    focusNode: widget.focusNode,
    mouseCursor: SystemMouseCursors.click,
    shortcuts: const <ShortcutActivator, Intent>{
      SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
      SingleActivator(LogicalKeyboardKey.select): ActivateIntent(),
    },
    actions: <Type, Action<Intent>>{
      ActivateIntent: CallbackAction<ActivateIntent>(
        onInvoke: (_) {
          widget.onPressed();
          return null;
        },
      ),
    },
    onFocusChange: _keepVisible,
    onShowHoverHighlight: (hovered) {
      if (_hovered == hovered) return;
      setState(() => _hovered = hovered);
    },
    child: Builder(
      builder: (context) {
        final focused = Focus.of(context).hasFocus;
        return Semantics(
          button: true,
          label: 'Now Playing',
          onTap: widget.onPressed,
          excludeSemantics: true,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onPressed,
            child: AnimatedContainer(
              duration: MediaQuery.disableAnimationsOf(context)
                  ? Duration.zero
                  : const Duration(milliseconds: 130),
              curve: Curves.easeOutCubic,
              constraints: const BoxConstraints(minHeight: 48),
              margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: _hovered ? _railSelectedHover : _railSelected,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(
                  color: focused ? _amber : Colors.transparent,
                  width: 2,
                ),
              ),
              child: Row(
                children: [
                  const Icon(
                    Icons.picture_in_picture_alt_outlined,
                    size: 22,
                    color: _warmWhite,
                  ),
                  if (widget.expanded) ...[
                    const SizedBox(width: 14),
                    const Expanded(
                      child: Text(
                        'Now Playing',
                        softWrap: true,
                        style: TextStyle(
                          color: _warmWhite,
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        );
      },
    ),
  );
}

class _DeferredDestination extends StatelessWidget {
  const _DeferredDestination({
    required this.destination,
    required this.initialFocus,
    required this.onContentFocus,
    required this.onOpenRail,
  });

  final ShellDestination destination;
  final FocusNode initialFocus;
  final ValueChanged<FocusNode> onContentFocus;
  final VoidCallback onOpenRail;

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: initialFocus,
      autofocus: true,
      onFocusChange: (focused) {
        if (focused) onContentFocus(initialFocus);
      },
      onKeyEvent: (_, event) {
        if (event is KeyDownEvent &&
            event.logicalKey == LogicalKeyboardKey.arrowLeft) {
          onOpenRail();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: Semantics(
        label: '${destination.label} is planned for a later shaped phase',
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(48),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 540),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    destination.label,
                    style: const TextStyle(
                      color: _warmWhite,
                      fontWeight: FontWeight.w700,
                      fontSize: 30,
                      letterSpacing: -0.6,
                    ),
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'This destination is present for app-shell navigation. Its browsing surface will be shaped before it is built.',
                    style: TextStyle(
                      color: _quietText,
                      fontSize: 16,
                      height: 1.45,
                    ),
                  ),
                  const SizedBox(height: 26),
                  const Text(
                    'Press Escape or Left to open navigation.',
                    style: TextStyle(color: _amber, fontSize: 14),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
