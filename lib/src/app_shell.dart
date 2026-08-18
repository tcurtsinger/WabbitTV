import 'dart:async';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'features/browse/basic_browse_screen.dart';
import 'features/browse/catalog_scope_controller.dart';
import 'features/browse/playback_handoff.dart';
import 'features/home/home_screen.dart';
import 'features/playback/player_screen.dart';
import 'features/search/local_search_screen.dart';
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
import 'home_fixture_mode.dart';

const _rail = Color(0xFF171818);
const _line = Color(0xFF343534);
const _warmWhite = Color(0xFFF4F0E7);
const _quietText = Color(0xFFAAA8A2);
const _amber = Color(0xFFFFB347);

enum ShellDestination { home, live, movies, series, search, library, settings }

extension ShellDestinationLabel on ShellDestination {
  String get label => switch (this) {
    ShellDestination.home => 'Home',
    ShellDestination.live => 'Live',
    ShellDestination.movies => 'Movies',
    ShellDestination.series => 'Series',
    ShellDestination.search => 'Search',
    ShellDestination.library => 'My Library',
    ShellDestination.settings => 'Settings',
  };

  IconData get icon => switch (this) {
    ShellDestination.home => Icons.home_outlined,
    ShellDestination.live => Icons.live_tv_outlined,
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
    this.playbackSourceResolver,
    this.initialDestination,
    this.onPlaybackHandoff,
    this.credentialStore,
    this.playbackTransportFactory,
    this.fullscreenPort,
    this.m3uFilePicker,
    this.libraryVisibilityPort,
  });

  final HomeFixtureMode fixtureMode;
  final SourceSetupController? sourceController;
  final SourceManagementController? sourceManagementController;
  final PersistedSource? browseSource;
  final BasicBrowseData? browseData;
  final ScopedBrowseData? scopedBrowseData;
  final CatalogScopeController? catalogScopeController;
  final LocalSearchData? localSearchData;

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

  @override
  State<WabbitShell> createState() => _WabbitShellState();
}

class _WabbitShellState extends State<WabbitShell> {
  final FocusNode _railFocus = FocusNode(debugLabel: 'navigation rail');
  final FocusNode _firstContentFocus = FocusNode(debugLabel: 'home first item');
  late final Map<ShellDestination, FocusNode> _navigationFocus = {
    for (final destination in ShellDestination.values)
      destination: FocusNode(debugLabel: '${destination.label} navigation'),
  };

  late ShellDestination _destination;
  bool _railHovered = false;
  PlaybackHandoff? _playback;
  FocusNode? _playbackOrigin;
  bool _sourceSetupFromHome = false;
  bool _sourceSetupOpen = false;
  SourceEditorRequest? _sourceEditorRequest;
  Completer<void>? _sourceEditorCompletion;
  Future<void>? _destinationTransition;
  bool _restoreSourceManagementSelectedRowFocus = false;
  bool _restoreSourceManagementVisibilityFocus = false;
  SourceRosterEntry? _libraryVisibilitySource;
  bool _libraryVisibilityBusy = false;
  FocusNode? _lastContentFocus;
  final BasicBrowseSession _browseSession = BasicBrowseSession();
  final LocalSearchSession _searchSession = LocalSearchSession();
  late final SourceCatalogDatabase _catalogDatabase = SourceCatalogDatabase();
  late final LibraryVisibilityPort _libraryVisibilityPort =
      widget.libraryVisibilityPort ??
      DatabaseLibraryVisibilityPort(_catalogDatabase);
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

  /// Explicit Phase 1 browse seams still exercise the named-source directory.
  /// Scope-aware integration begins only when a scope controller is supplied.
  bool get _usesLegacyBrowse =>
      widget.catalogScopeController == null &&
      (widget.fixtureMode != HomeFixtureMode.runtime ||
          widget.browseData != null ||
          widget.browseSource != null);

  bool get _railExpanded =>
      _railHovered ||
      _railFocus.hasFocus ||
      _navigationFocus.values.any((node) => node.hasFocus);

  @override
  void initState() {
    super.initState();
    _destination = widget.initialDestination ?? ShellDestination.home;
    _railFocus.addListener(_refreshShell);
    for (final node in _navigationFocus.values) {
      node.addListener(_refreshShell);
    }
    _sourceController.addListener(_refreshShell);
    unawaited(_initializeRuntimeState());
  }

  @override
  void dispose() {
    _railFocus
      ..removeListener(_refreshShell)
      ..dispose();
    _sourceController.removeListener(_refreshShell);
    if (_ownsSourceController) _sourceController.dispose();
    if (_ownsSourceManagementController) _sourceManagementController.dispose();
    if (_ownsCatalogScopeController) _catalogScopeController.dispose();
    _firstContentFocus.dispose();
    for (final node in _navigationFocus.values) {
      node.removeListener(_refreshShell);
      node.dispose();
    }
    super.dispose();
  }

  void _refreshShell() {
    if (mounted) setState(() {});
  }

  /// Both controllers touch the same local catalog on a fresh installation.
  /// Sequence their startup migration work without delaying the first frame.
  Future<void> _initializeRuntimeState() async {
    if (!_usesLegacyBrowse) await _catalogScopeController.initialize();
    if (widget.fixtureMode == HomeFixtureMode.runtime) {
      await _sourceController.initialize();
    }
  }

  void _openRail() {
    _navigationFocus[_destination]!.requestFocus();
  }

  void _closeRail() {
    final target = _lastContentFocus?.canRequestFocus == true
        ? _lastContentFocus
        : _firstContentFocus;
    target!.requestFocus();
  }

  void _handleBack() {
    if (_railExpanded) {
      _closeRail();
    } else {
      _openRail();
    }
  }

  void _selectDestination(ShellDestination destination) {
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
    setState(() {
      _destination = destination;
      _sourceSetupFromHome = false;
      _sourceSetupOpen = false;
      _libraryVisibilitySource = null;
      _libraryVisibilityBusy = false;
      _restoreSourceManagementSelectedRowFocus = false;
      _restoreSourceManagementVisibilityFocus = false;
    });
    if (!_usesLegacyBrowse && _isCatalogDestination(destination)) {
      // Source operations are durable, not event-streamed into the shell.
      // Refresh only at a destination boundary so disabled/removed scopes fall
      // back before the next catalog settles, without requerying on focus.
      unawaited(_catalogScopeController.refresh());
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
  }

  void _beginPlayback(PlaybackHandoff handoff) {
    final external = widget.onPlaybackHandoff;
    if (external != null) {
      external(handoff);
      return;
    }
    setState(() {
      _playbackOrigin = FocusManager.instance.primaryFocus;
      _playback = handoff;
    });
  }

  Future<void> _exitPlayback() async {
    if (!mounted) return;
    setState(() => _playback = null);
    final origin = _playbackOrigin;
    _playbackOrigin = null;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && origin?.canRequestFocus == true) {
        origin!.requestFocus();
      }
    });
  }

  Future<void> _openPlaybackSettings() async {
    await _exitPlayback();
    if (mounted) _selectDestination(ShellDestination.settings);
  }

  void _openSourceSetupFromHome() {
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

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.escape): _handleBack,
        const SingleActivator(LogicalKeyboardKey.browserBack): _handleBack,
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
                  onLibraryVisibilityBusyChanged: _libraryVisibilityBusyChanged,
                  m3uFilePicker: widget.m3uFilePicker ?? _pickM3uFile,
                  sourceController: _sourceController,
                  sourceManagementController: _sourceManagementController,
                  browseSource: widget.browseSource,
                  browseData: widget.browseData,
                  scopedBrowseData: _scopedBrowseData,
                  catalogScopeController: _catalogScopeController,
                  useLegacyBrowse: _usesLegacyBrowse,
                  localSearchData: _localSearchData,
                  browseSession: _browseSession,
                  searchSession: _searchSession,
                  credentialStore: widget.credentialStore,
                  onPlaybackHandoff: _beginPlayback,
                ),
              ),
              Positioned(
                left: 0,
                top: 0,
                bottom: 0,
                child: Focus(
                  focusNode: _railFocus,
                  skipTraversal: true,
                  child: MouseRegion(
                    onEnter: (_) => setState(() => _railHovered = true),
                    onExit: (_) => setState(() => _railHovered = false),
                    child: _NavigationRail(
                      selected: _destination,
                      isExpanded: _railExpanded,
                      showFixtureLabel:
                          widget.fixtureMode != HomeFixtureMode.runtime ||
                          widget.browseData != null,
                      focusNodes: _navigationFocus,
                      onSelected: _selectDestination,
                    ),
                  ),
                ),
              ),
              if (_playback != null)
                Positioned.fill(
                  child: PlayerScreen(
                    handoff: _playback!,
                    source: widget.browseSource ?? _sourceController.persisted,
                    credentialStore: widget.credentialStore,
                    sourceResolver: _resolvePlaybackSource,
                    transportFactory: widget.playbackTransportFactory,
                    fullscreenPort: widget.fullscreenPort,
                    onExit: _exitPlayback,
                    onOpenSettings: _openPlaybackSettings,
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
    required this.browseSource,
    required this.browseData,
    required this.scopedBrowseData,
    required this.catalogScopeController,
    required this.useLegacyBrowse,
    required this.localSearchData,
    required this.browseSession,
    required this.searchSession,
    required this.credentialStore,
    required this.onPlaybackHandoff,
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
  final PersistedSource? browseSource;
  final BasicBrowseData? browseData;
  final ScopedBrowseData scopedBrowseData;
  final CatalogScopeController catalogScopeController;
  final bool useLegacyBrowse;
  final LocalSearchData localSearchData;
  final BasicBrowseSession browseSession;
  final LocalSearchSession searchSession;
  final CredentialStore? credentialStore;
  final ValueChanged<PlaybackHandoff>? onPlaybackHandoff;

  @override
  Widget build(BuildContext context) {
    final effectiveFixture = fixtureMode == HomeFixtureMode.runtime
        ? (sourceController.persisted == null
              ? HomeFixtureMode.noSources
              : HomeFixtureMode.noPersonalization)
        : fixtureMode;
    if (destination == ShellDestination.home) {
      return HomeScreen(
        fixtureMode: effectiveFixture,
        showFixtureCopy: fixtureMode != HomeFixtureMode.runtime,
        initialFocus: initialContentFocus,
        onContentFocus: onContentFocus,
        onOpenRail: onOpenRail,
        onBrowseLive: () => onSelectDestination(ShellDestination.live),
        onBrowseMovies: () => onSelectDestination(ShellDestination.movies),
        onBrowseSeries: () => onSelectDestination(ShellDestination.series),
        onAddSource: onOpenSourceSetupFromHome,
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
        restoreSelectedFocusOnEntry: restoreSourceManagementSelectedRowFocus,
        restoreVisibilityFocusOnEntry: restoreSourceManagementVisibilityFocus,
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
        credentialStore: credentialStore,
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
        credentialStore: credentialStore,
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
  });

  final ShellDestination selected;
  final bool isExpanded;
  final bool showFixtureLabel;
  final Map<ShellDestination, FocusNode> focusNodes;
  final ValueChanged<ShellDestination> onSelected;

  @override
  Widget build(BuildContext context) {
    final railWidth = isExpanded ? 224.0 : 72.0;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 150),
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
                    SizedBox(
                      height: 52,
                      child: Row(
                        children: [
                          const SizedBox(width: 22),
                          const Icon(
                            Icons.play_circle_outline,
                            color: _amber,
                            size: 27,
                          ),
                          if (isExpanded) ...[
                            const SizedBox(width: 12),
                            const Expanded(
                              child: Text(
                                'Wabbit TV',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: _warmWhite,
                                  fontSize: 18,
                                  fontWeight: FontWeight.w700,
                                  letterSpacing: -0.2,
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                    const SizedBox(height: 20),
                    Expanded(
                      child: ListView(
                        padding: EdgeInsets.zero,
                        children: [
                          for (final destination in ShellDestination.values)
                            _RailDestination(
                              destination: destination,
                              isSelected: destination == selected,
                              expanded: isExpanded,
                              focusNode: focusNodes[destination]!,
                              onPressed: () => onSelected(destination),
                            ),
                        ],
                      ),
                    ),
                    if (isExpanded && showFixtureLabel)
                      const Padding(
                        padding: EdgeInsets.fromLTRB(20, 0, 16, 20),
                        child: Text(
                          'Local fixture preview',
                          style: TextStyle(color: _quietText, fontSize: 12),
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

class _RailDestination extends StatelessWidget {
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
  Widget build(BuildContext context) {
    return FocusableActionDetector(
      focusNode: focusNode,
      shortcuts: const <ShortcutActivator, Intent>{
        SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
        SingleActivator(LogicalKeyboardKey.select): ActivateIntent(),
      },
      actions: <Type, Action<Intent>>{
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (_) {
            onPressed();
            return null;
          },
        ),
      },
      onShowFocusHighlight: (_) {},
      child: Builder(
        builder: (context) {
          final focused = Focus.of(context).hasFocus;
          return Semantics(
            button: true,
            selected: isSelected,
            label: destination.label,
            child: GestureDetector(
              onTap: onPressed,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 130),
                curve: Curves.easeOutCubic,
                height: 48,
                margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
                padding: const EdgeInsets.symmetric(horizontal: 12),
                decoration: BoxDecoration(
                  color: isSelected
                      ? const Color(0xFF262624)
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(6),
                  border: focused
                      ? Border.all(color: _amber, width: 2)
                      : Border.all(color: Colors.transparent, width: 2),
                ),
                child: Row(
                  children: [
                    Icon(
                      destination.icon,
                      size: 22,
                      color: isSelected ? _warmWhite : _quietText,
                    ),
                    if (expanded) ...[
                      const SizedBox(width: 14),
                      Expanded(
                        child: Text(
                          destination.label,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: isSelected ? _warmWhite : _quietText,
                            fontSize: 15,
                            fontWeight: isSelected
                                ? FontWeight.w700
                                : FontWeight.w500,
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
