import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

import '../../home_fixture_mode.dart';
import '../artwork/artwork_loader.dart';
import '../artwork/source_artwork.dart';
import '../browse/minimal_continuations.dart';
import '../browse/playback_handoff.dart';
import '../browse/series_info_loader.dart';
import '../sources/credential_store.dart';
import '../sources/source_catalog_database.dart';
import '../sources/source_models.dart';

const _graphite = Color(0xFF111212);
const _surface = Color(0xFF191A1A);
const _raised = Color(0xFF222321);
const _line = Color(0xFF343534);
const _warmWhite = Color(0xFFF4F0E7);
const _quietText = Color(0xFFAAA8A2);
const _amber = Color(0xFFFFB347);

abstract interface class HomeData {
  Future<bool> hasSources();
  Future<List<RecentlyWatchedItem>> loadRecentlyWatched({required int limit});
  Future<List<HomePersonalShelf>> loadPinnedShelves({
    required int shelfLimit,
    required int itemLimit,
  });
  Future<PersistedSource?> loadReadySourceById(String sourceId);
}

class HomePersonalShelf {
  const HomePersonalShelf({required this.collection, required this.items});

  final PersonalLibraryDirectoryEntry collection;
  final List<PersonalLibraryItem> items;
}

class DatabaseHomeData implements HomeData {
  const DatabaseHomeData(this.database);

  final SourceCatalogDatabase database;

  @override
  Future<bool> hasSources() => database.hasAnySource();

  @override
  Future<List<RecentlyWatchedItem>> loadRecentlyWatched({required int limit}) =>
      database.loadRecentlyWatched(limit: limit);

  @override
  Future<List<HomePersonalShelf>> loadPinnedShelves({
    required int shelfLimit,
    required int itemLimit,
  }) async {
    final collections = await database.loadPinnedPersonalLibraryDirectory(
      limit: shelfLimit.clamp(1, 24),
    );
    final shelves = <HomePersonalShelf>[];
    for (final collection in collections) {
      final List<PersonalLibraryItem> items;
      if (collection.kind == PersonalLibraryDirectoryKind.favorites) {
        items = (await database.loadFavoriteLibraryPage(
          limit: itemLimit.clamp(1, 24),
        )).items;
      } else {
        items = (await database.loadCustomGroupLibraryPage(
          customGroupId: collection.collectionId!,
          limit: itemLimit.clamp(1, 24),
        )).items;
      }
      shelves.add(
        HomePersonalShelf(
          collection: collection,
          items: List.unmodifiable(items),
        ),
      );
    }
    return List.unmodifiable(shelves);
  }

  @override
  Future<PersistedSource?> loadReadySourceById(String sourceId) =>
      database.loadReadySourceById(sourceId);
}

enum HomeLoadPhase { initializing, noSources, noHistory, ready, failure }

class HomeController extends ChangeNotifier {
  HomeController({
    required this.data,
    this.historyLimit = 24,
    this.pinnedShelfLimit = 12,
    this.pinnedItemLimit = 12,
  });

  final HomeData data;
  final int historyLimit;
  final int pinnedShelfLimit;
  final int pinnedItemLimit;
  HomeLoadPhase _phase = HomeLoadPhase.initializing;
  List<RecentlyWatchedItem> _recentlyWatched = const [];
  List<HomePersonalShelf> _pinnedShelves = const [];
  bool _showingSavedHistory = false;
  int _generation = 0;
  bool _started = false;
  bool _disposed = false;

  HomeLoadPhase get phase => _phase;
  List<RecentlyWatchedItem> get recentlyWatched => _recentlyWatched;
  List<HomePersonalShelf> get pinnedShelves => _pinnedShelves;
  bool get showingSavedHistory => _showingSavedHistory;

  Future<void> initialize() async {
    if (_disposed || _started) return;
    _started = true;
    await _load();
  }

  /// Reloads local Home state after a successful history write or source
  /// lifecycle change. Stale completions cannot replace a newer result.
  Future<void> refresh() {
    if (_disposed) return Future<void>.value();
    _started = true;
    return _load();
  }

  Future<void> retry() {
    if (_disposed) return Future<void>.value();
    _started = true;
    return _load(showInitializing: true);
  }

  Future<void> _load({bool showInitializing = false}) async {
    final generation = ++_generation;
    if (showInitializing) {
      _phase = HomeLoadPhase.initializing;
      _notify();
    }
    try {
      if (!await data.hasSources()) {
        if (!_accepts(generation)) return;
        _recentlyWatched = const [];
        _pinnedShelves = const [];
        _showingSavedHistory = false;
        _phase = HomeLoadPhase.noSources;
        _notify();
        return;
      }
      final recent = await data.loadRecentlyWatched(
        limit: historyLimit.clamp(1, 48),
      );
      final pinned = await data.loadPinnedShelves(
        shelfLimit: pinnedShelfLimit.clamp(1, 24),
        itemLimit: pinnedItemLimit.clamp(1, 24),
      );
      if (!_accepts(generation)) return;
      _recentlyWatched = List.unmodifiable(recent);
      _pinnedShelves = List.unmodifiable(pinned);
      _showingSavedHistory = false;
      _phase = recent.isEmpty && pinned.isEmpty
          ? HomeLoadPhase.noHistory
          : HomeLoadPhase.ready;
      _notify();
    } catch (_) {
      if (!_accepts(generation)) return;
      if (_recentlyWatched.isNotEmpty || _pinnedShelves.isNotEmpty) {
        _showingSavedHistory = true;
        _phase = HomeLoadPhase.ready;
      } else {
        _recentlyWatched = const [];
        _pinnedShelves = const [];
        _showingSavedHistory = false;
        _phase = HomeLoadPhase.failure;
      }
      _notify();
    }
  }

  bool _accepts(int generation) => !_disposed && generation == _generation;

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _generation += 1;
    super.dispose();
  }
}

/// App-owned, bounded restoration state for the single Phase 3 continuity
/// shelf. It contains no provider locator or playback credential.
class HomeSession {
  String? focusedLibraryItemId;
  String? focusedShelfKey;
  double horizontalOffset = 0;
  final Map<String, double> pinnedOffsets = {};
}

typedef HomeArtworkBuilder = Widget Function(
  BuildContext context,
  RecentlyWatchedItem item,
  bool focused,
);

enum FixtureKind { live, movie, series }

class FixtureItem {
  const FixtureItem({
    required this.title,
    required this.kind,
    required this.note,
    required this.artSeed,
  });

  final String title;
  final FixtureKind kind;
  final String note;
  final int artSeed;

  String get kindLabel => switch (kind) {
    FixtureKind.live => 'Live',
    FixtureKind.movie => 'Movie',
    FixtureKind.series => 'Series',
  };
}

class FixtureShelf {
  const FixtureShelf({required this.title, required this.items});

  final String title;
  final List<FixtureItem> items;
}

const _shelves = <FixtureShelf>[
  FixtureShelf(
    title: 'Living Room',
    items: [
      FixtureItem(
        title: 'Northbound',
        kind: FixtureKind.live,
        note: 'Pinned channel',
        artSeed: 0,
      ),
      FixtureItem(
        title: 'Field Notes',
        kind: FixtureKind.series,
        note: 'Pinned series',
        artSeed: 1,
      ),
      FixtureItem(
        title: 'Night Signal',
        kind: FixtureKind.movie,
        note: 'Pinned movie',
        artSeed: 2,
      ),
      FixtureItem(
        title: 'The Long Turn',
        kind: FixtureKind.movie,
        note: 'Pinned movie',
        artSeed: 3,
      ),
      FixtureItem(
        title: 'Static Season',
        kind: FixtureKind.series,
        note: 'Pinned series',
        artSeed: 4,
      ),
      FixtureItem(
        title: 'Dawn Relay',
        kind: FixtureKind.live,
        note: 'Pinned channel',
        artSeed: 5,
      ),
    ],
  ),
  FixtureShelf(
    title: 'Weekend Movies',
    items: [
      FixtureItem(
        title: 'Open Waterline',
        kind: FixtureKind.movie,
        note: 'Pinned movie',
        artSeed: 6,
      ),
      FixtureItem(
        title: 'Aperture',
        kind: FixtureKind.movie,
        note: 'Pinned movie',
        artSeed: 7,
      ),
      FixtureItem(
        title: 'Late Check-Out',
        kind: FixtureKind.movie,
        note: 'Pinned movie',
        artSeed: 8,
      ),
      FixtureItem(
        title: 'Small Hours',
        kind: FixtureKind.movie,
        note: 'Pinned movie',
        artSeed: 9,
      ),
    ],
  ),
  FixtureShelf(
    title: 'Favorites',
    items: [
      FixtureItem(
        title: 'Horizon Desk',
        kind: FixtureKind.live,
        note: 'Favorite channel',
        artSeed: 10,
      ),
      FixtureItem(
        title: 'Soft Focus',
        kind: FixtureKind.series,
        note: 'Favorite series',
        artSeed: 11,
      ),
      FixtureItem(
        title: 'Off Hours',
        kind: FixtureKind.movie,
        note: 'Favorite movie',
        artSeed: 0,
      ),
      FixtureItem(
        title: 'Signal Path',
        kind: FixtureKind.live,
        note: 'Favorite channel',
        artSeed: 3,
      ),
    ],
  ),
];

class HomeScreen extends StatefulWidget {
  const HomeScreen({
    super.key,
    required this.fixtureMode,
    required this.showFixtureCopy,
    required this.initialFocus,
    required this.onContentFocus,
    required this.onOpenRail,
    required this.onBrowseLive,
    required this.onBrowseMovies,
    required this.onBrowseSeries,
    required this.onAddSource,
    this.controller,
    this.session,
    this.artworkBuilder,
    this.artworkLoader,
    this.onActivateLibraryItem,
    this.onPlaybackHandoff,
    this.onOrganizeItem,
    this.onOrganizePersonalItem,
    this.credentialStore,
    this.seriesInfoLoader,
    this.initializeController = true,
  });

  final HomeFixtureMode fixtureMode;
  final bool showFixtureCopy;
  final FocusNode initialFocus;
  final ValueChanged<FocusNode> onContentFocus;
  final VoidCallback onOpenRail;
  final VoidCallback onBrowseLive;
  final VoidCallback onBrowseMovies;
  final VoidCallback onBrowseSeries;
  final VoidCallback onAddSource;
  final HomeController? controller;
  final HomeSession? session;
  final HomeArtworkBuilder? artworkBuilder;
  final ArtworkProvider? artworkLoader;
  final ValueChanged<LibraryCatalogItem>? onActivateLibraryItem;
  final ValueChanged<PlaybackHandoff>? onPlaybackHandoff;
  final ValueChanged<LibraryCatalogItem>? onOrganizeItem;
  final ValueChanged<PersonalLibraryItem>? onOrganizePersonalItem;
  final CredentialStore? credentialStore;
  final SeriesInfoLoader? seriesInfoLoader;
  final bool initializeController;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  late final List<List<FocusNode>> _focusNodes;
  late final HomeSession _fallbackSession = HomeSession();
  FixtureItem _selectedItem = _shelves.first.items.first;

  @override
  void initState() {
    super.initState();
    _focusNodes = List<List<FocusNode>>.generate(
      _shelves.length,
      (shelfIndex) => List<FocusNode>.generate(
        _shelves[shelfIndex].items.length,
        (itemIndex) => shelfIndex == 0 && itemIndex == 0
            ? widget.initialFocus
            : FocusNode(debugLabel: 'home shelf $shelfIndex item $itemIndex'),
      ),
    );
  }

  @override
  void dispose() {
    for (final row in _focusNodes) {
      for (final node in row) {
        if (node != widget.initialFocus) node.dispose();
      }
    }
    super.dispose();
  }

  void _moveFocus(int shelfIndex, int itemIndex, LogicalKeyboardKey key) {
    if (key == LogicalKeyboardKey.arrowLeft) {
      if (itemIndex == 0) {
        widget.onOpenRail();
      } else {
        _focusNodes[shelfIndex][itemIndex - 1].requestFocus();
      }
      return;
    }
    if (key == LogicalKeyboardKey.arrowRight &&
        itemIndex < _focusNodes[shelfIndex].length - 1) {
      _focusNodes[shelfIndex][itemIndex + 1].requestFocus();
      return;
    }
    if (key == LogicalKeyboardKey.arrowUp && shelfIndex > 0) {
      final target = math.min(
        itemIndex,
        _focusNodes[shelfIndex - 1].length - 1,
      );
      _focusNodes[shelfIndex - 1][target].requestFocus();
      return;
    }
    if (key == LogicalKeyboardKey.arrowDown &&
        shelfIndex < _focusNodes.length - 1) {
      final target = math.min(
        itemIndex,
        _focusNodes[shelfIndex + 1].length - 1,
      );
      _focusNodes[shelfIndex + 1][target].requestFocus();
    }
  }

  void _activate(FixtureItem item) {
    final message = item.kind == FixtureKind.live
        ? '${item.title} is a local fixture. Live playback is not part of this proof.'
        : '${item.title} is a local fixture. Details are not part of this proof.';
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    if (widget.fixtureMode == HomeFixtureMode.runtime) {
      final controller = widget.controller;
      assert(controller != null, 'Runtime Home requires a HomeController.');
      if (controller == null) {
        return const ColoredBox(color: _graphite);
      }
      return _ProductionHome(
        controller: controller,
        session: widget.session ?? _fallbackSession,
        artworkBuilder: widget.artworkBuilder,
        artworkLoader: widget.artworkLoader,
        initialFocus: widget.initialFocus,
        onContentFocus: widget.onContentFocus,
        onOpenRail: widget.onOpenRail,
        onBrowseLive: widget.onBrowseLive,
        onBrowseMovies: widget.onBrowseMovies,
        onBrowseSeries: widget.onBrowseSeries,
        onAddSource: widget.onAddSource,
        onActivate: widget.onActivateLibraryItem,
        onPlaybackHandoff: widget.onPlaybackHandoff,
        onOrganizeItem: widget.onOrganizeItem,
        onOrganizePersonalItem: widget.onOrganizePersonalItem,
        credentialStore: widget.credentialStore,
        seriesInfoLoader: widget.seriesInfoLoader,
        initializeController: widget.initializeController,
      );
    }
    if (widget.fixtureMode == HomeFixtureMode.noSources) {
      return _NoSourceHome(
        focusNode: widget.initialFocus,
        onContentFocus: widget.onContentFocus,
        onOpenRail: widget.onOpenRail,
        onAddSource: widget.onAddSource,
      );
    }

    if (widget.fixtureMode == HomeFixtureMode.noPersonalization) {
      return _NoPersonalizationHome(
        showFixtureCopy: widget.showFixtureCopy,
        focusNode: widget.initialFocus,
        onContentFocus: widget.onContentFocus,
        onOpenRail: widget.onOpenRail,
        onBrowseLive: widget.onBrowseLive,
        onBrowseMovies: widget.onBrowseMovies,
        onBrowseSeries: widget.onBrowseSeries,
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final textScale = MediaQuery.textScalerOf(context).scale(1);
        final narrow = constraints.maxWidth < 780 || textScale > 1.35;
        return ColoredBox(
          color: _graphite,
          child: SafeArea(
            left: false,
            child: ListView(
              padding: EdgeInsets.fromLTRB(narrow ? 24 : 48, 22, 32, 48),
              children: [
                _HomeHeader(narrow: narrow),
                const SizedBox(height: 30),
                _FocusedShelf(
                  shelf: _shelves.first,
                  selected: _selectedItem,
                  nodes: _focusNodes.first,
                  narrow: narrow,
                  onFocus: (item, node) {
                    widget.onContentFocus(node);
                    setState(() => _selectedItem = item);
                  },
                  onMove: (index, key) => _moveFocus(0, index, key),
                  onActivate: _activate,
                ),
                const SizedBox(height: 36),
                for (
                  var shelfIndex = 1;
                  shelfIndex < _shelves.length;
                  shelfIndex++
                ) ...[
                  _StandardShelf(
                    shelf: _shelves[shelfIndex],
                    nodes: _focusNodes[shelfIndex],
                    onFocus: (item, node) {
                      widget.onContentFocus(node);
                      setState(() => _selectedItem = item);
                    },
                    onMove: (itemIndex, key) =>
                        _moveFocus(shelfIndex, itemIndex, key),
                    onActivate: _activate,
                  ),
                  const SizedBox(height: 36),
                ],
                const Text(
                  'Illustrative local fixture content — no provider is connected.',
                  style: TextStyle(color: _quietText, fontSize: 13),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _ProductionHome extends StatefulWidget {
  const _ProductionHome({
    required this.controller,
    required this.session,
    required this.initialFocus,
    required this.onContentFocus,
    required this.onOpenRail,
    required this.onBrowseLive,
    required this.onBrowseMovies,
    required this.onBrowseSeries,
    required this.onAddSource,
    required this.onActivate,
    required this.onPlaybackHandoff,
    required this.onOrganizeItem,
    required this.onOrganizePersonalItem,
    required this.credentialStore,
    required this.seriesInfoLoader,
    required this.initializeController,
    this.artworkBuilder,
    this.artworkLoader,
  });

  final HomeController controller;
  final HomeSession session;
  final FocusNode initialFocus;
  final ValueChanged<FocusNode> onContentFocus;
  final VoidCallback onOpenRail;
  final VoidCallback onBrowseLive;
  final VoidCallback onBrowseMovies;
  final VoidCallback onBrowseSeries;
  final VoidCallback onAddSource;
  final ValueChanged<LibraryCatalogItem>? onActivate;
  final ValueChanged<PlaybackHandoff>? onPlaybackHandoff;
  final ValueChanged<LibraryCatalogItem>? onOrganizeItem;
  final ValueChanged<PersonalLibraryItem>? onOrganizePersonalItem;
  final CredentialStore? credentialStore;
  final SeriesInfoLoader? seriesInfoLoader;
  final bool initializeController;
  final HomeArtworkBuilder? artworkBuilder;
  final ArtworkProvider? artworkLoader;

  @override
  State<_ProductionHome> createState() => _ProductionHomeState();
}

class _ProductionHomeState extends State<_ProductionHome> {
  late final ScrollController _horizontalController;
  List<FocusNode> _nodes = const [];
  List<String> _nodeItemIds = const [];
  final Map<String, List<FocusNode>> _pinnedNodes = {};
  final Map<String, List<String>> _pinnedItemIds = {};
  final Map<String, ScrollController> _pinnedScroll = {};
  _HomeContinuation? _continuation;
  late SeriesInfoLoader _seriesInfoLoader;
  int _seriesRequest = 0;
  int _focusRepairGeneration = 0;
  bool _repairingContentFocus = false;

  @override
  void initState() {
    super.initState();
    _horizontalController = ScrollController(
      initialScrollOffset: widget.session.horizontalOffset,
    )..addListener(_rememberOffset);
    _seriesInfoLoader =
        widget.seriesInfoLoader ??
        XtreamSeriesInfoLoader(credentialStore: widget.credentialStore);
    widget.controller.addListener(_controllerChanged);
    _repairSessionSelection();
    _syncFocusNodes();
    _syncPinnedFocusNodes();
    if (widget.initializeController) {
      unawaited(widget.controller.initialize());
    }
  }

  @override
  void didUpdateWidget(covariant _ProductionHome oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_controllerChanged);
      widget.controller.addListener(_controllerChanged);
      _repairSessionSelection();
      _syncFocusNodes();
      _syncPinnedFocusNodes();
      if (widget.initializeController) {
        unawaited(widget.controller.initialize());
      }
    }
    if (oldWidget.seriesInfoLoader != widget.seriesInfoLoader ||
        oldWidget.credentialStore != widget.credentialStore) {
      _cancelSeriesRequest();
      _seriesInfoLoader =
          widget.seriesInfoLoader ??
          XtreamSeriesInfoLoader(credentialStore: widget.credentialStore);
    }
  }

  void _controllerChanged() {
    if (!mounted) return;
    final repairGeneration = ++_focusRepairGeneration;
    _repairingContentFocus = true;
    final selectedNode = _selectedPinnedNode;
    final restorePinnedFocus = selectedNode?.hasFocus ?? false;
    final previousShelfKeys = _pinnedItemIds.keys.toList(growable: false);
    final previousItems = {
      for (final entry in _pinnedItemIds.entries)
        entry.key: List<String>.of(entry.value),
    };
    _repairSessionSelection(
      previousShelfKeys: previousShelfKeys,
      previousItems: previousItems,
    );
    _syncFocusNodes();
    _syncPinnedFocusNodes();
    setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || repairGeneration != _focusRepairGeneration) return;
      _repairingContentFocus = false;
      if (restorePinnedFocus) _requestSessionFocus();
    });
  }

  FocusNode? get _selectedPinnedNode {
    final key = widget.session.focusedShelfKey;
    final itemId = widget.session.focusedLibraryItemId;
    if (key == null || key == 'recent' || itemId == null) return null;
    final index = (_pinnedItemIds[key] ?? const <String>[]).indexOf(itemId);
    final nodes = _pinnedNodes[key] ?? const <FocusNode>[];
    return index >= 0 && index < nodes.length ? nodes[index] : null;
  }

  void _repairSessionSelection({
    List<String> previousShelfKeys = const [],
    Map<String, List<String>> previousItems = const {},
  }) {
    if (widget.controller.phase != HomeLoadPhase.ready) return;
    final recentIds = widget.controller.recentlyWatched
        .map((entry) => entry.item.libraryItemId)
        .toList(growable: false);
    final shelves = widget.controller.pinnedShelves;
    final selectedKey = widget.session.focusedShelfKey;
    final selectedId = widget.session.focusedLibraryItemId;

    if (selectedKey == 'recent' && recentIds.contains(selectedId)) return;
    final selectedShelfIndex = shelves.indexWhere(
      (shelf) => shelf.collection.reference.key == selectedKey,
    );
    if (selectedShelfIndex >= 0 &&
        shelves[selectedShelfIndex].items.any(
          (item) => item.libraryItemId == selectedId,
        )) {
      return;
    }

    final previousShelfIndex = previousShelfKeys.indexOf(selectedKey ?? '');
    final previousItemIndex =
        previousItems[selectedKey]?.indexOf(selectedId ?? '') ?? -1;
    if (selectedShelfIndex >= 0 &&
        shelves[selectedShelfIndex].items.isNotEmpty) {
      final items = shelves[selectedShelfIndex].items;
      _selectPersonalItem(
        shelves[selectedShelfIndex],
        items[math.min(math.max(previousItemIndex, 0), items.length - 1)],
      );
      return;
    }

    if (shelves.isNotEmpty) {
      final start = previousShelfIndex < 0
          ? 0
          : math.min(previousShelfIndex, shelves.length - 1);
      for (var index = start; index < shelves.length; index++) {
        if (shelves[index].items.isNotEmpty) {
          _selectPersonalItem(shelves[index], shelves[index].items.first);
          return;
        }
      }
      for (var index = start - 1; index >= 0; index--) {
        if (shelves[index].items.isNotEmpty) {
          _selectPersonalItem(shelves[index], shelves[index].items.first);
          return;
        }
      }
    }
    if (recentIds.isNotEmpty) {
      widget.session
        ..focusedShelfKey = 'recent'
        ..focusedLibraryItemId = recentIds.first;
      return;
    }
    if (shelves.isNotEmpty) {
      widget.session
        ..focusedShelfKey = shelves.first.collection.reference.key
        ..focusedLibraryItemId = null;
    }
  }

  void _selectPersonalItem(HomePersonalShelf shelf, PersonalLibraryItem item) {
    widget.session
      ..focusedShelfKey = shelf.collection.reference.key
      ..focusedLibraryItemId = item.libraryItemId;
  }

  void _syncFocusNodes() {
    final items = widget.controller.phase == HomeLoadPhase.ready
        ? widget.controller.recentlyWatched
        : const <RecentlyWatchedItem>[];
    final ids = items
        .map((entry) => entry.item.libraryItemId)
        .toList(growable: false);
    if (_sameStrings(ids, _nodeItemIds)) return;
    final previous = <String, FocusNode>{
      for (var index = 0; index < _nodeItemIds.length; index++)
        _nodeItemIds[index]: _nodes[index],
    };
    if (ids.isEmpty) {
      for (final node in previous.values) {
        if (node != widget.initialFocus) node.dispose();
      }
      _nodes = const [];
      _nodeItemIds = const [];
      return;
    }
    final pinsOwnInitial = widget.controller.pinnedShelves.isNotEmpty;
    final selectedId =
        widget.session.focusedShelfKey == 'recent' &&
            ids.contains(widget.session.focusedLibraryItemId)
        ? widget.session.focusedLibraryItemId!
        : ids.first;
    final initialId = previous.entries
        .where((entry) => identical(entry.value, widget.initialFocus))
        .map((entry) => entry.key)
        .firstOrNull;
    final initialTarget =
        !pinsOwnInitial && initialId != null && ids.contains(initialId)
        ? initialId
        : selectedId;
    final nextNodes = <FocusNode>[];
    final retained = <FocusNode>{};
    for (var index = 0; index < ids.length; index++) {
      final id = ids[index];
      FocusNode node;
      if (!pinsOwnInitial && id == initialTarget) {
        node = widget.initialFocus;
      } else {
        final existing = previous[id];
        node = existing != null && existing != widget.initialFocus
            ? existing
            : FocusNode(debugLabel: 'home recent item $index');
      }
      nextNodes.add(node);
      retained.add(node);
    }
    for (final node in previous.values) {
      if (node != widget.initialFocus && !retained.contains(node)) {
        node.dispose();
      }
    }
    _nodes = List.unmodifiable(nextNodes);
    _nodeItemIds = ids;
  }

  void _syncPinnedFocusNodes() {
    final shelves = widget.controller.phase == HomeLoadPhase.ready
        ? widget.controller.pinnedShelves
        : const <HomePersonalShelf>[];
    final activeKeys = shelves
        .map((shelf) => shelf.collection.reference.key)
        .toSet();
    for (final key in _pinnedNodes.keys.toList()) {
      if (activeKeys.contains(key)) continue;
      for (final node in _pinnedNodes.remove(key)!) {
        if (node != widget.initialFocus) node.dispose();
      }
      _pinnedItemIds.remove(key);
      _pinnedScroll.remove(key)?.dispose();
    }
    for (final shelf in shelves) {
      final key = shelf.collection.reference.key;
      final ids = shelf.items.map((item) => item.libraryItemId).toList();
      final previousIds = _pinnedItemIds[key] ?? const <String>[];
      final previousNodes = _pinnedNodes[key] ?? const <FocusNode>[];
      final previous = <String, FocusNode>{
        for (var index = 0; index < previousIds.length; index++)
          previousIds[index]: previousNodes[index],
      };
      final firstPinnedShelf = shelves.first.collection.reference.key == key;
      final selectedKey = widget.session.focusedShelfKey;
      final selectedId = widget.session.focusedLibraryItemId;
      final preferredId = selectedKey == key && ids.contains(selectedId)
          ? selectedId
          : ids.firstOrNull;
      final next = <FocusNode>[];
      final retained = <FocusNode>{};
      for (var index = 0; index < ids.length; index++) {
        final id = ids[index];
        final shouldOwnInitial = firstPinnedShelf && id == preferredId;
        final old = previous[id];
        final node = shouldOwnInitial
            ? widget.initialFocus
            : old != null && old != widget.initialFocus
            ? old
            : FocusNode(debugLabel: 'home pinned $key item $index');
        next.add(node);
        retained.add(node);
      }
      for (final node in previous.values) {
        if (node != widget.initialFocus && !retained.contains(node)) {
          node.dispose();
        }
      }
      _pinnedNodes[key] = List.unmodifiable(next);
      _pinnedItemIds[key] = List.unmodifiable(ids);
      _pinnedScroll.putIfAbsent(
        key,
        () =>
            ScrollController(
              initialScrollOffset: widget.session.pinnedOffsets[key] ?? 0,
            )..addListener(() {
              final controller = _pinnedScroll[key];
              if (controller?.hasClients == true) {
                widget.session.pinnedOffsets[key] = controller!.offset;
              }
            }),
      );
    }
  }

  void _rememberOffset() {
    if (_horizontalController.hasClients) {
      widget.session.horizontalOffset = _horizontalController.offset;
    }
  }

  void _moveFocus(int index, LogicalKeyboardKey key) {
    if (key == LogicalKeyboardKey.arrowLeft) {
      if (index == 0) {
        widget.onOpenRail();
      } else {
        _nodes[index - 1].requestFocus();
      }
    } else if (key == LogicalKeyboardKey.arrowRight &&
        index < _nodes.length - 1) {
      _nodes[index + 1].requestFocus();
    } else if (key == LogicalKeyboardKey.arrowUp &&
        widget.controller.pinnedShelves.isNotEmpty) {
      final last = widget.controller.pinnedShelves.last;
      final nodes = _pinnedNodes[last.collection.reference.key] ?? const [];
      if (nodes.isNotEmpty) {
        nodes[math.min(index, nodes.length - 1)].requestFocus();
      }
    }
  }

  void _movePinnedFocus(int shelfIndex, int itemIndex, LogicalKeyboardKey key) {
    final shelves = widget.controller.pinnedShelves;
    final shelf = shelves[shelfIndex];
    final nodes = _pinnedNodes[shelf.collection.reference.key] ?? const [];
    if (key == LogicalKeyboardKey.arrowLeft) {
      if (itemIndex == 0) {
        widget.onOpenRail();
      } else {
        nodes[itemIndex - 1].requestFocus();
      }
      return;
    }
    if (key == LogicalKeyboardKey.arrowRight && itemIndex + 1 < nodes.length) {
      nodes[itemIndex + 1].requestFocus();
      return;
    }
    if (key == LogicalKeyboardKey.arrowUp) {
      if (shelfIndex > 0) {
        final prior = shelves[shelfIndex - 1];
        final priorNodes =
            _pinnedNodes[prior.collection.reference.key] ?? const [];
        if (priorNodes.isNotEmpty) {
          priorNodes[math.min(itemIndex, priorNodes.length - 1)].requestFocus();
        }
      }
      return;
    }
    if (key == LogicalKeyboardKey.arrowDown) {
      if (shelfIndex + 1 < shelves.length) {
        final next = shelves[shelfIndex + 1];
        final nextNodes =
            _pinnedNodes[next.collection.reference.key] ?? const [];
        if (nextNodes.isNotEmpty) {
          nextNodes[math.min(itemIndex, nextNodes.length - 1)].requestFocus();
        }
      } else if (_nodes.isNotEmpty) {
        _nodes[math.min(itemIndex, _nodes.length - 1)].requestFocus();
      }
    }
  }

  void _focusItem(int index, BuildContext cardContext) {
    if (_repairingContentFocus) return;
    final item = widget.controller.recentlyWatched[index];
    widget.session
      ..focusedShelfKey = 'recent'
      ..focusedLibraryItemId = item.item.libraryItemId;
    widget.onContentFocus(_nodes[index]);
    setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      Scrollable.ensureVisible(
        cardContext,
        duration: const Duration(milliseconds: 150),
        curve: Curves.easeOutCubic,
        alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
      );
    });
  }

  void _focusPinnedItem(
    HomePersonalShelf shelf,
    int index,
    BuildContext cardContext,
  ) {
    if (_repairingContentFocus) return;
    final item = shelf.items[index];
    final key = shelf.collection.reference.key;
    widget.session
      ..focusedShelfKey = key
      ..focusedLibraryItemId = item.libraryItemId;
    final node = _pinnedNodes[key]![index];
    widget.onContentFocus(node);
    setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      Scrollable.ensureVisible(
        cardContext,
        duration: const Duration(milliseconds: 150),
        curve: Curves.easeOutCubic,
        alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
      );
    });
  }

  void _activateItem(LibraryCatalogItem item) {
    widget.session.focusedLibraryItemId = item.libraryItemId;
    widget.onActivate?.call(item);
    switch (item.kind) {
      case SourceMediaKind.live:
        _activateLive(item);
      case SourceMediaKind.movies:
        _openMovie(item);
      case SourceMediaKind.series:
        _openSeries(item);
    }
  }

  void _activateLive(LibraryCatalogItem item) {
    try {
      widget.onPlaybackHandoff?.call(playbackHandoffForLibrary(item));
    } on ContinuationException catch (error) {
      setState(
        () => _continuation = _FailureHomeContinuation(item, error.failure),
      );
    }
  }

  void _openMovie(LibraryCatalogItem item) {
    try {
      final handoff = playbackHandoffForLibrary(item);
      if (handoff is! MoviePlaybackHandoff) {
        throw const ContinuationException(ContinuationFailure.invalidReference);
      }
      setState(() => _continuation = _MovieHomeContinuation(item, handoff));
    } on ContinuationException catch (error) {
      setState(
        () => _continuation = _FailureHomeContinuation(item, error.failure),
      );
    }
  }

  void _openSeries(LibraryCatalogItem item) {
    _cancelSeriesRequest();
    try {
      seriesReferenceForLibrary(item);
    } on ContinuationException catch (error) {
      setState(
        () => _continuation = _FailureHomeContinuation(item, error.failure),
      );
      return;
    }
    unawaited(_loadSeries(item));
  }

  Future<void> _loadSeries(LibraryCatalogItem item) async {
    final request = ++_seriesRequest;
    setState(
      () => _continuation = _SeriesHomeContinuation(item, loading: true),
    );
    try {
      final source = await widget.controller.data.loadReadySourceById(
        item.sourceId,
      );
      if (source == null) {
        throw const ContinuationException(
          ContinuationFailure.credentialsUnavailable,
        );
      }
      final info = await _seriesInfoLoader.load(
        source: source,
        series: _browseItem(item),
      );
      if (!mounted || request != _seriesRequest) return;
      setState(
        () => _continuation = _SeriesHomeContinuation(
          item,
          loading: false,
          info: info,
        ),
      );
    } on ContinuationException catch (error) {
      if (mounted && request == _seriesRequest) {
        setState(
          () => _continuation = _SeriesHomeContinuation(
            item,
            loading: false,
            failure: error.failure,
          ),
        );
      }
    } catch (_) {
      if (mounted && request == _seriesRequest) {
        setState(
          () => _continuation = _SeriesHomeContinuation(
            item,
            loading: false,
            failure: ContinuationFailure.unavailable,
          ),
        );
      }
    }
  }

  BrowseCatalogItem _browseItem(LibraryCatalogItem item) => BrowseCatalogItem(
    id: item.catalogItemId,
    sourceId: item.sourceId,
    kind: item.kind,
    title: item.title,
    artworkLocator: item.artworkLocator,
    playbackRef: item.playbackRef,
  );

  void _cancelSeriesRequest() {
    ++_seriesRequest;
    _seriesInfoLoader.cancel();
  }

  void _returnToHome() {
    _cancelSeriesRequest();
    setState(() => _continuation = null);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _requestSessionFocus();
    });
  }

  void _requestSessionFocus() {
    final selectedId = widget.session.focusedLibraryItemId;
    final shelfKey = widget.session.focusedShelfKey;
    if (shelfKey != null && shelfKey != 'recent') {
      final index = (_pinnedItemIds[shelfKey] ?? const <String>[]).indexOf(
        selectedId ?? '',
      );
      final nodes = _pinnedNodes[shelfKey] ?? const <FocusNode>[];
      if (index >= 0 && index < nodes.length) {
        nodes[index].requestFocus();
        return;
      }
    }
    if (_nodes.isNotEmpty) {
      final index = _nodeItemIds.indexOf(selectedId ?? '');
      _nodes[index < 0 ? 0 : index].requestFocus();
      return;
    }
    final firstPinned = widget.controller.pinnedShelves.firstOrNull;
    if (firstPinned != null) {
      final nodes =
          _pinnedNodes[firstPinned.collection.reference.key] ?? const [];
      (nodes.firstOrNull ?? widget.initialFocus).requestFocus();
    }
  }

  @override
  void dispose() {
    _cancelSeriesRequest();
    widget.controller.removeListener(_controllerChanged);
    for (final node in _nodes) {
      if (node != widget.initialFocus) node.dispose();
    }
    for (final nodes in _pinnedNodes.values) {
      for (final node in nodes) {
        if (node != widget.initialFocus) node.dispose();
      }
    }
    for (final controller in _pinnedScroll.values) {
      controller.dispose();
    }
    _horizontalController
      ..removeListener(_rememberOffset)
      ..dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final continuation = _continuation;
    if (continuation != null) return _buildContinuation(continuation);
    return switch (widget.controller.phase) {
      HomeLoadPhase.initializing => _HomeLoading(
        focusNode: widget.initialFocus,
        onContentFocus: widget.onContentFocus,
        onOpenRail: widget.onOpenRail,
      ),
      HomeLoadPhase.noSources => _NoSourceHome(
        focusNode: widget.initialFocus,
        onContentFocus: widget.onContentFocus,
        onOpenRail: widget.onOpenRail,
        onAddSource: widget.onAddSource,
      ),
      HomeLoadPhase.noHistory => _NoPersonalizationHome(
        showFixtureCopy: false,
        focusNode: widget.initialFocus,
        onContentFocus: widget.onContentFocus,
        onOpenRail: widget.onOpenRail,
        onBrowseLive: widget.onBrowseLive,
        onBrowseMovies: widget.onBrowseMovies,
        onBrowseSeries: widget.onBrowseSeries,
      ),
      HomeLoadPhase.failure => _HomeReadFailure(
        focusNode: widget.initialFocus,
        onContentFocus: widget.onContentFocus,
        onOpenRail: widget.onOpenRail,
        onRetry: () => unawaited(widget.controller.retry()),
      ),
      HomeLoadPhase.ready => _buildHome(context),
    };
  }

  Widget _buildContinuation(_HomeContinuation continuation) =>
      switch (continuation) {
        _MovieHomeContinuation(:final item, :final handoff) =>
          MovieContinuation(
            title: item.title,
            artworkLocator: item.artworkLocator,
            artworkLoader: widget.artworkLoader,
            onOrganize: widget.onOrganizeItem == null
                ? null
                : () => widget.onOrganizeItem!(item),
            onBack: _returnToHome,
            onPlay: () => widget.onPlaybackHandoff?.call(handoff),
          ),
        _SeriesHomeContinuation(
          :final item,
          :final loading,
          :final info,
          :final failure,
        ) =>
          SeriesContinuation(
            title: item.title,
            artworkLocator: item.artworkLocator,
            artworkLoader: widget.artworkLoader,
            onOrganize: widget.onOrganizeItem == null
                ? null
                : () => widget.onOrganizeItem!(item),
            loading: loading,
            info: info,
            failure: failure,
            onBack: _returnToHome,
            onRetry: () => _openSeries(item),
            onEpisodeActivated: (episode) => widget.onPlaybackHandoff?.call(
              EpisodePlaybackHandoff(
                sourceId: item.sourceId,
                title: episode.title,
                providerItemId: episode.providerItemId,
                extension: episode.extension,
                libraryItemId: item.libraryItemId,
              ),
            ),
          ),
        _FailureHomeContinuation(:final item, :final failure) =>
          ContinuationFailureView(
            title: item.title,
            failure: failure,
            onBack: _returnToHome,
            onRetry: () => _activateItem(item),
          ),
      };

  Widget _buildHome(BuildContext context) {
    if (widget.controller.recentlyWatched.isEmpty) {
      return _buildPinnedOnly(context);
    }
    return _buildRecentlyWatched(context);
  }

  Widget _buildPinnedOnly(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final textScale = MediaQuery.textScalerOf(context).scale(1);
      final narrow = constraints.maxWidth < 780 || textScale > 1.35;
      return ColoredBox(
        color: _graphite,
        child: SafeArea(
          left: false,
          child: ListView(
            padding: EdgeInsets.fromLTRB(narrow ? 24 : 48, 22, 32, 48),
            children: [
              _HomeHeader(narrow: narrow, showFixtureCopy: false),
              if (widget.controller.showingSavedHistory) ...[
                const SizedBox(height: 10),
                const Text(
                  'Could not refresh Home. Showing saved local shelves.',
                  style: TextStyle(color: _quietText, fontSize: 13),
                ),
              ],
              const SizedBox(height: 30),
              ..._buildPinnedShelfWidgets(narrow),
            ],
          ),
        ),
      );
    },
  );

  List<Widget> _buildPinnedShelfWidgets(bool narrow) {
    final shelves = widget.controller.pinnedShelves;
    return [
      for (var shelfIndex = 0; shelfIndex < shelves.length; shelfIndex++) ...[
        _PinnedHomeShelf(
          shelf: shelves[shelfIndex],
          nodes:
              _pinnedNodes[shelves[shelfIndex].collection.reference.key] ??
              const [],
          controller:
              _pinnedScroll[shelves[shelfIndex].collection.reference.key],
          selectedLibraryItemId:
              widget.session.focusedShelfKey ==
                  shelves[shelfIndex].collection.reference.key
              ? widget.session.focusedLibraryItemId
              : null,
          narrow: narrow,
          artworkLoader: widget.artworkLoader,
          onFocused: (index, context) =>
              _focusPinnedItem(shelves[shelfIndex], index, context),
          onMove: (index, key) => _movePinnedFocus(shelfIndex, index, key),
          onOpenRail: widget.onOpenRail,
          onActivate: (item) {
            final exact = item.playableItem;
            if (exact != null) _activateItem(exact);
          },
          onOrganize: widget.onOrganizePersonalItem,
          emptyFocus:
              widget.controller.recentlyWatched.isEmpty && shelfIndex == 0
              ? widget.initialFocus
              : null,
        ),
        const SizedBox(height: 32),
      ],
    ];
  }

  Widget _buildRecentlyWatched(BuildContext context) {
    final items = widget.controller.recentlyWatched;
    final selectedId = widget.session.focusedLibraryItemId;
    final selected = items.firstWhere(
      (entry) => entry.item.libraryItemId == selectedId,
      orElse: () => items.first,
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        final textScale = MediaQuery.textScalerOf(context).scale(1);
        final narrow = constraints.maxWidth < 780 || textScale > 1.35;
        final carouselHeight = 220 + ((textScale - 1).clamp(0.0, 1.0) * 100);
        final details = _RecentShelfDetails(
          item: selected,
          fillHeight: !narrow,
        );
        final carousel = ListView.separated(
          key: const PageStorageKey('home-recently-watched-carousel'),
          controller: _horizontalController,
          scrollDirection: Axis.horizontal,
          itemCount: items.length,
          padding: const EdgeInsets.symmetric(vertical: 8),
          separatorBuilder: (_, _) => const SizedBox(width: 14),
          itemBuilder: (context, index) {
            final item = items[index];
            return SizedBox(
              width: narrow ? 144 : 172,
              child: _RecentCard(
                item: item,
                focusNode: _nodes[index],
                autofocus:
                    item.item.libraryItemId ==
                    widget.session.focusedLibraryItemId,
                artworkBuilder: widget.artworkBuilder,
                onFocused: (cardContext) => _focusItem(index, cardContext),
                onMove: (key) => _moveFocus(index, key),
                onOpenRail: widget.onOpenRail,
                onActivate: () => _activateItem(item.item),
                onOrganize: widget.onOrganizeItem == null
                    ? null
                    : () => widget.onOrganizeItem!(item.item),
              ),
            );
          },
        );
        return ColoredBox(
          color: _graphite,
          child: SafeArea(
            left: false,
            child: ListView(
              padding: EdgeInsets.fromLTRB(narrow ? 24 : 48, 22, 32, 48),
              children: [
                _HomeHeader(narrow: narrow, showFixtureCopy: false),
                if (widget.controller.showingSavedHistory) ...[
                  const SizedBox(height: 10),
                  const Text(
                    'Could not refresh Home. Showing saved local shelves.',
                    style: TextStyle(color: _quietText, fontSize: 13),
                  ),
                ],
                const SizedBox(height: 30),
                if (widget.controller.pinnedShelves.isNotEmpty) ...[
                  ..._buildPinnedShelfWidgets(narrow),
                  const SizedBox(height: 2),
                ],
                if (narrow) ...[
                  details,
                  const SizedBox(height: 18),
                  SizedBox(height: carouselHeight, child: carousel),
                ] else
                  SizedBox(
                    height: 264,
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        SizedBox(width: 248, child: details),
                        const SizedBox(width: 24),
                        Expanded(child: carousel),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _PinnedHomeShelf extends StatelessWidget {
  const _PinnedHomeShelf({
    required this.shelf,
    required this.nodes,
    required this.controller,
    required this.selectedLibraryItemId,
    required this.narrow,
    required this.artworkLoader,
    required this.onFocused,
    required this.onMove,
    required this.onOpenRail,
    required this.onActivate,
    required this.onOrganize,
    required this.emptyFocus,
  });

  final HomePersonalShelf shelf;
  final List<FocusNode> nodes;
  final ScrollController? controller;
  final String? selectedLibraryItemId;
  final bool narrow;
  final ArtworkProvider? artworkLoader;
  final void Function(int index, BuildContext context) onFocused;
  final void Function(int index, LogicalKeyboardKey key) onMove;
  final VoidCallback onOpenRail;
  final ValueChanged<PersonalLibraryItem> onActivate;
  final ValueChanged<PersonalLibraryItem>? onOrganize;
  final FocusNode? emptyFocus;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Row(
        children: [
          Expanded(
            child: Text(
              shelf.collection.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: _warmWhite,
                fontSize: 22,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          Text(
            '${shelf.collection.itemCount} items',
            style: const TextStyle(color: _quietText, fontSize: 13),
          ),
        ],
      ),
      const SizedBox(height: 12),
      if (shelf.items.isEmpty)
        Focus(
          focusNode: emptyFocus,
          onKeyEvent: (_, event) {
            if (event is KeyDownEvent &&
                (event.logicalKey == LogicalKeyboardKey.arrowLeft ||
                    event.logicalKey == LogicalKeyboardKey.escape ||
                    event.logicalKey == LogicalKeyboardKey.browserBack)) {
              onOpenRail();
              return KeyEventResult.handled;
            }
            return KeyEventResult.ignored;
          },
          child: const DecoratedBox(
            decoration: BoxDecoration(
              color: _surface,
              border: Border.fromBorderSide(BorderSide(color: _line)),
              borderRadius: BorderRadius.all(Radius.circular(8)),
            ),
            child: SizedBox(
              height: 82,
              child: Center(
                child: Text(
                  'This pinned collection is empty.',
                  style: TextStyle(color: _quietText, fontSize: 14),
                ),
              ),
            ),
          ),
        )
      else
        SizedBox(
          height: 196,
          child: ListView.separated(
            controller: controller,
            scrollDirection: Axis.horizontal,
            itemCount: shelf.items.length,
            separatorBuilder: (_, _) => const SizedBox(width: 14),
            itemBuilder: (context, index) {
              final item = shelf.items[index];
              return SizedBox(
                width: narrow ? 144 : 172,
                child: _PinnedHomeCard(
                  item: item,
                  focusNode: nodes[index],
                  autofocus: item.libraryItemId == selectedLibraryItemId,
                  artworkLoader: artworkLoader,
                  onFocused: (cardContext) => onFocused(index, cardContext),
                  onMove: (key) => onMove(index, key),
                  onOpenRail: onOpenRail,
                  onActivate: () => onActivate(item),
                  onOrganize: onOrganize == null
                      ? null
                      : () => onOrganize!(item),
                ),
              );
            },
          ),
        ),
    ],
  );
}

class _PinnedHomeCard extends StatefulWidget {
  const _PinnedHomeCard({
    required this.item,
    required this.focusNode,
    required this.autofocus,
    required this.artworkLoader,
    required this.onFocused,
    required this.onMove,
    required this.onOpenRail,
    required this.onActivate,
    required this.onOrganize,
  });

  final PersonalLibraryItem item;
  final FocusNode focusNode;
  final bool autofocus;
  final ArtworkProvider? artworkLoader;
  final ValueChanged<BuildContext> onFocused;
  final ValueChanged<LogicalKeyboardKey> onMove;
  final VoidCallback onOpenRail;
  final VoidCallback onActivate;
  final VoidCallback? onOrganize;

  @override
  State<_PinnedHomeCard> createState() => _PinnedHomeCardState();
}

class _PinnedHomeCardState extends State<_PinnedHomeCard> {
  bool _focused = false;
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final active = _focused || _hovered || widget.focusNode.hasFocus;
    return Focus(
      focusNode: widget.focusNode,
      autofocus: widget.autofocus,
      onFocusChange: (focused) {
        setState(() => _focused = focused);
        if (focused) widget.onFocused(context);
      },
      onKeyEvent: (_, event) {
        if (event is! KeyDownEvent) return KeyEventResult.ignored;
        final key = event.logicalKey;
        if (key == LogicalKeyboardKey.escape ||
            key == LogicalKeyboardKey.browserBack) {
          widget.onOpenRail();
          return KeyEventResult.handled;
        }
        if (key == LogicalKeyboardKey.enter ||
            key == LogicalKeyboardKey.select) {
          if (widget.item.isAvailable) widget.onActivate();
          return KeyEventResult.handled;
        }
        if (key == LogicalKeyboardKey.contextMenu) {
          widget.onOrganize?.call();
          return widget.onOrganize == null
              ? KeyEventResult.ignored
              : KeyEventResult.handled;
        }
        if (key == LogicalKeyboardKey.arrowLeft ||
            key == LogicalKeyboardKey.arrowRight ||
            key == LogicalKeyboardKey.arrowUp ||
            key == LogicalKeyboardKey.arrowDown) {
          widget.onMove(key);
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: Semantics(
        button: widget.item.isAvailable,
        enabled: widget.item.isAvailable,
        label:
            '${widget.item.title}, ${widget.item.kind.label}, ${widget.item.isAvailable ? widget.item.sourceDisplayName : 'Source unavailable'}',
        customSemanticsActions: widget.onOrganize == null
            ? null
            : {
                const CustomSemanticsAction(label: 'Organize item'):
                    widget.onOrganize!,
              },
        child: MouseRegion(
          cursor: widget.item.isAvailable
              ? SystemMouseCursors.click
              : MouseCursor.defer,
          onEnter: (_) => setState(() => _hovered = true),
          onExit: (_) => setState(() => _hovered = false),
          child: GestureDetector(
            onTap: widget.item.isAvailable
                ? () {
                    widget.focusNode.requestFocus();
                    widget.onActivate();
                  }
                : null,
            child: Stack(
              children: [
                Positioned.fill(
                  child: AnimatedScale(
                    scale: active ? 1.025 : 1,
                    duration: const Duration(milliseconds: 120),
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: _surface,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: _focused ? _amber : _line,
                          width: 2,
                        ),
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(6),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Expanded(
                              child: SourceArtwork(
                                locator: widget.item.isAvailable
                                    ? widget.item.artworkLocator
                                    : null,
                                kind: widget.item.kind,
                                loader: widget.artworkLoader,
                                focused: _focused,
                                loadWhenVisible: true,
                                width: double.infinity,
                                height: double.infinity,
                              ),
                            ),
                            Padding(
                              padding: const EdgeInsets.fromLTRB(10, 8, 10, 9),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    widget.item.title,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      color: _warmWhite,
                                      fontSize: 13,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  const SizedBox(height: 3),
                                  Text(
                                    widget.item.isAvailable
                                        ? widget.item.kind.label
                                        : 'Source unavailable',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      color: _quietText,
                                      fontSize: 11,
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
                if (widget.onOrganize != null && active)
                  Positioned(
                    right: 7,
                    top: 7,
                    child: Tooltip(
                      message: 'Organize item',
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () {
                          widget.focusNode.requestFocus();
                          widget.onOrganize!();
                        },
                        child: const SizedBox.square(
                          dimension: 48,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: Color(0xDD343534),
                              borderRadius: BorderRadius.all(
                                Radius.circular(24),
                              ),
                            ),
                            child: Center(
                              child: Icon(
                                Icons.bookmark_add_outlined,
                                size: 18,
                                color: _warmWhite,
                              ),
                            ),
                          ),
                        ),
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

sealed class _HomeContinuation {
  const _HomeContinuation(this.item);

  final LibraryCatalogItem item;
}

final class _MovieHomeContinuation extends _HomeContinuation {
  const _MovieHomeContinuation(super.item, this.handoff);

  final MoviePlaybackHandoff handoff;
}

final class _SeriesHomeContinuation extends _HomeContinuation {
  const _SeriesHomeContinuation(
    super.item, {
    required this.loading,
    this.info,
    this.failure,
  });

  final bool loading;
  final SeriesInfo? info;
  final ContinuationFailure? failure;
}

final class _FailureHomeContinuation extends _HomeContinuation {
  const _FailureHomeContinuation(super.item, this.failure);

  final ContinuationFailure failure;
}

bool _sameStrings(List<String> left, List<String> right) {
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index++) {
    if (left[index] != right[index]) return false;
  }
  return true;
}

class _HomeLoading extends StatelessWidget {
  const _HomeLoading({
    required this.focusNode,
    required this.onContentFocus,
    required this.onOpenRail,
  });

  final FocusNode focusNode;
  final ValueChanged<FocusNode> onContentFocus;
  final VoidCallback onOpenRail;

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: _graphite,
    child: SafeArea(
      left: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(48, 22, 32, 48),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const _HomeHeader(narrow: false, showFixtureCopy: false),
            const Spacer(),
            Focus(
              focusNode: focusNode,
              autofocus: true,
              onFocusChange: (focused) {
                if (focused) onContentFocus(focusNode);
              },
              onKeyEvent: (_, event) {
                if (event is KeyDownEvent &&
                    (event.logicalKey == LogicalKeyboardKey.arrowLeft ||
                        event.logicalKey == LogicalKeyboardKey.escape ||
                        event.logicalKey == LogicalKeyboardKey.browserBack)) {
                  onOpenRail();
                  return KeyEventResult.handled;
                }
                return KeyEventResult.ignored;
              },
              child: Semantics(
                liveRegion: true,
                label: 'Loading Home',
                child: const Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    SizedBox.square(
                      dimension: 22,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: _amber,
                      ),
                    ),
                    SizedBox(width: 12),
                    Text(
                      'Loading Home',
                      style: TextStyle(color: _quietText, fontSize: 16),
                    ),
                  ],
                ),
              ),
            ),
            const Spacer(),
          ],
        ),
      ),
    ),
  );
}

class _HomeReadFailure extends StatelessWidget {
  const _HomeReadFailure({
    required this.focusNode,
    required this.onContentFocus,
    required this.onOpenRail,
    required this.onRetry,
  });

  final FocusNode focusNode;
  final ValueChanged<FocusNode> onContentFocus;
  final VoidCallback onOpenRail;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: _graphite,
    child: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460),
        child: Padding(
          padding: const EdgeInsets.all(40),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(Icons.history_toggle_off, color: _quietText, size: 34),
              const SizedBox(height: 20),
              const Text(
                'Home could not be loaded',
                style: TextStyle(
                  color: _warmWhite,
                  fontSize: 30,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 12),
              const Text(
                'Your local catalog and watch history are unchanged.',
                style: TextStyle(color: _quietText, fontSize: 16, height: 1.45),
              ),
              const SizedBox(height: 26),
              _FocusedAction(
                label: 'Retry',
                focusNode: focusNode,
                onFocused: () => onContentFocus(focusNode),
                onLeft: onOpenRail,
                onPressed: onRetry,
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

class _RecentShelfDetails extends StatelessWidget {
  const _RecentShelfDetails({required this.item, required this.fillHeight});

  final RecentlyWatchedItem item;
  final bool fillHeight;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: _surface,
      border: Border.all(color: _line),
      borderRadius: BorderRadius.circular(8),
    ),
    child: Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Recently Watched',
            style: TextStyle(
              color: _warmWhite,
              fontSize: 22,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            item.item.kind.label.toUpperCase(),
            style: const TextStyle(
              color: _amber,
              fontSize: 12,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.7,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            item.item.title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: _warmWhite,
              fontSize: 18,
              fontWeight: FontWeight.w600,
              height: 1.2,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            item.item.sourceDisplayName,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: _quietText, fontSize: 14),
          ),
          if (fillHeight) const Spacer() else const SizedBox(height: 24),
          const Text(
            'Local watch history',
            style: TextStyle(color: _quietText, fontSize: 12),
          ),
        ],
      ),
    ),
  );
}

class _RecentCard extends StatefulWidget {
  const _RecentCard({
    required this.item,
    required this.focusNode,
    required this.autofocus,
    required this.onFocused,
    required this.onMove,
    required this.onOpenRail,
    required this.onActivate,
    this.onOrganize,
    this.artworkBuilder,
  });

  final RecentlyWatchedItem item;
  final FocusNode focusNode;
  final bool autofocus;
  final ValueChanged<BuildContext> onFocused;
  final ValueChanged<LogicalKeyboardKey> onMove;
  final VoidCallback onOpenRail;
  final VoidCallback onActivate;
  final VoidCallback? onOrganize;
  final HomeArtworkBuilder? artworkBuilder;

  @override
  State<_RecentCard> createState() => _RecentCardState();
}

class _RecentCardState extends State<_RecentCard> {
  bool _focused = false;
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final focused = _focused || widget.focusNode.hasFocus;
    final active = focused || _hovered;
    return Focus(
      focusNode: widget.focusNode,
      autofocus: widget.autofocus,
      onFocusChange: (focused) {
        setState(() => _focused = focused);
        if (focused) widget.onFocused(context);
      },
      onKeyEvent: (_, event) {
        if (event is! KeyDownEvent) return KeyEventResult.ignored;
        final key = event.logicalKey;
        if (key == LogicalKeyboardKey.escape ||
            key == LogicalKeyboardKey.browserBack) {
          widget.onOpenRail();
          return KeyEventResult.handled;
        }
        if (key == LogicalKeyboardKey.enter ||
            key == LogicalKeyboardKey.select) {
          widget.onActivate();
          return KeyEventResult.handled;
        }
        if (key == LogicalKeyboardKey.contextMenu) {
          widget.onOrganize?.call();
          return widget.onOrganize == null
              ? KeyEventResult.ignored
              : KeyEventResult.handled;
        }
        if (key == LogicalKeyboardKey.arrowLeft ||
            key == LogicalKeyboardKey.arrowRight ||
            key == LogicalKeyboardKey.arrowUp ||
            key == LogicalKeyboardKey.arrowDown) {
          widget.onMove(key);
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: Semantics(
        button: true,
        label:
            '${widget.item.item.title}, ${widget.item.item.kind.label}, ${widget.item.item.sourceDisplayName}',
        customSemanticsActions: widget.onOrganize == null
            ? null
            : {
                const CustomSemanticsAction(label: 'Organize item'):
                    widget.onOrganize!,
              },
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          onEnter: (_) => setState(() => _hovered = true),
          onExit: (_) => setState(() => _hovered = false),
          child: GestureDetector(
            onTap: () {
              widget.focusNode.requestFocus();
              widget.onActivate();
            },
            child: Stack(
              children: [
                Positioned.fill(
                  child: AnimatedScale(
                    scale: active ? 1.025 : 1,
                    duration: const Duration(milliseconds: 130),
                    curve: Curves.easeOutCubic,
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 130),
                      curve: Curves.easeOutCubic,
                      decoration: BoxDecoration(
                        color: _raised,
                        borderRadius: BorderRadius.circular(7),
                        border: Border.all(
                          color: focused ? _amber : _line,
                          width: focused ? 2 : 1,
                        ),
                        boxShadow: active
                            ? const [
                                BoxShadow(
                                  color: Color(0x55000000),
                                  offset: Offset(0, 8),
                                  blurRadius: 16,
                                ),
                              ]
                            : null,
                      ),
                      clipBehavior: Clip.antiAlias,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: SizedBox.expand(
                              child: RepaintBoundary(
                                child:
                                    widget.artworkBuilder?.call(
                                      context,
                                      widget.item,
                                      focused,
                                    ) ??
                                    _HomeArtworkPlaceholder(
                                      kind: widget.item.item.kind,
                                    ),
                              ),
                            ),
                          ),
                          Padding(
                            padding: const EdgeInsets.fromLTRB(10, 9, 10, 10),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  widget.item.item.title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    color: _warmWhite,
                                    fontSize: 18,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                const SizedBox(height: 3),
                                Text(
                                  widget.item.item.kind.label,
                                  style: const TextStyle(
                                    color: _quietText,
                                    fontSize: 13,
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
                if (widget.onOrganize != null)
                  Positioned(
                    top: 7,
                    right: 7,
                    child: Tooltip(
                      message: 'Organize',
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () {
                          widget.focusNode.requestFocus();
                          widget.onOrganize!();
                        },
                        child: Container(
                          padding: const EdgeInsets.all(7),
                          decoration: BoxDecoration(
                            color: const Color(0xCC111212),
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(color: _line),
                          ),
                          child: const Icon(
                            Icons.bookmark_add_outlined,
                            size: 18,
                            color: _warmWhite,
                          ),
                        ),
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

class _HomeArtworkPlaceholder extends StatelessWidget {
  const _HomeArtworkPlaceholder({required this.kind});

  final SourceMediaKind kind;

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: _surface,
    child: Center(
      child: Icon(
        switch (kind) {
          SourceMediaKind.live => Icons.live_tv_outlined,
          SourceMediaKind.movies => Icons.movie_outlined,
          SourceMediaKind.series => Icons.tv_outlined,
        },
        color: _quietText,
        size: 34,
      ),
    ),
  );
}

class _HomeHeader extends StatelessWidget {
  const _HomeHeader({required this.narrow, this.showFixtureCopy = true});

  final bool narrow;
  final bool showFixtureCopy;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      runSpacing: 14,
      alignment: WrapAlignment.spaceBetween,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        const Text(
          'Home',
          style: TextStyle(
            color: _warmWhite,
            fontSize: 31,
            fontWeight: FontWeight.w700,
            letterSpacing: -0.7,
          ),
        ),
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerRight,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: _surface,
              border: Border.all(color: _line),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.layers_outlined, size: 17, color: _quietText),
                const SizedBox(width: 8),
                Text(
                  showFixtureCopy
                      ? 'All sources · local fixture'
                      : 'All sources',
                  style: const TextStyle(color: _quietText, fontSize: 14),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _FocusedShelf extends StatelessWidget {
  const _FocusedShelf({
    required this.shelf,
    required this.selected,
    required this.nodes,
    required this.narrow,
    required this.onFocus,
    required this.onMove,
    required this.onActivate,
  });

  final FixtureShelf shelf;
  final FixtureItem selected;
  final List<FocusNode> nodes;
  final bool narrow;
  final void Function(FixtureItem, FocusNode) onFocus;
  final void Function(int, LogicalKeyboardKey) onMove;
  final ValueChanged<FixtureItem> onActivate;

  @override
  Widget build(BuildContext context) {
    final details = _ShelfDetails(
      title: shelf.title,
      item: selected,
      fillHeight: !narrow,
    );
    final cards = _CardCarousel(
      items: shelf.items,
      nodes: nodes,
      cardWidth: narrow ? 144 : 172,
      onFocus: onFocus,
      onMove: onMove,
      onActivate: onActivate,
      autofocusFirst: true,
    );

    return Column(
      key: const ValueKey('home-focused-shelf'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (narrow)
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              details,
              const SizedBox(height: 18),
              SizedBox(height: 220, child: cards),
            ],
          )
        else
          SizedBox(
            height: 264,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(width: 248, child: details),
                const SizedBox(width: 24),
                Expanded(child: cards),
              ],
            ),
          ),
      ],
    );
  }
}

class _ShelfDetails extends StatelessWidget {
  const _ShelfDetails({
    required this.title,
    required this.item,
    required this.fillHeight,
  });

  final String title;
  final FixtureItem item;
  final bool fillHeight;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: _surface,
        border: Border.all(color: _line),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: const TextStyle(
                color: _warmWhite,
                fontSize: 22,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              item.kindLabel.toUpperCase(),
              style: const TextStyle(
                color: _amber,
                fontSize: 12,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.7,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              item.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: _warmWhite,
                fontSize: 18,
                fontWeight: FontWeight.w600,
                height: 1.2,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              item.note,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: _quietText,
                fontSize: 14,
                height: 1.35,
              ),
            ),
            if (fillHeight) const Spacer() else const SizedBox(height: 24),
            const Text(
              'Manual order · fixture',
              style: TextStyle(color: _quietText, fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }
}

class _StandardShelf extends StatelessWidget {
  const _StandardShelf({
    required this.shelf,
    required this.nodes,
    required this.onFocus,
    required this.onMove,
    required this.onActivate,
  });

  final FixtureShelf shelf;
  final List<FocusNode> nodes;
  final void Function(FixtureItem, FocusNode) onFocus;
  final void Function(int, LogicalKeyboardKey) onMove;
  final ValueChanged<FixtureItem> onActivate;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          shelf.title,
          style: const TextStyle(
            color: _warmWhite,
            fontSize: 21,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 14),
        SizedBox(
          height: 220,
          child: _CardCarousel(
            items: shelf.items,
            nodes: nodes,
            cardWidth: 152,
            onFocus: onFocus,
            onMove: onMove,
            onActivate: onActivate,
          ),
        ),
      ],
    );
  }
}

class _CardCarousel extends StatelessWidget {
  const _CardCarousel({
    required this.items,
    required this.nodes,
    required this.cardWidth,
    required this.onFocus,
    required this.onMove,
    required this.onActivate,
    this.autofocusFirst = false,
  });

  final List<FixtureItem> items;
  final List<FocusNode> nodes;
  final double cardWidth;
  final void Function(FixtureItem, FocusNode) onFocus;
  final void Function(int, LogicalKeyboardKey) onMove;
  final ValueChanged<FixtureItem> onActivate;
  final bool autofocusFirst;

  @override
  Widget build(BuildContext context) {
    return ListView.separated(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(vertical: 2),
      clipBehavior: Clip.none,
      itemCount: items.length,
      separatorBuilder: (_, _) => const SizedBox(width: 14),
      itemBuilder: (context, index) => SizedBox(
        width: cardWidth,
        child: _FixtureCard(
          item: items[index],
          focusNode: nodes[index],
          onFocused: () => onFocus(items[index], nodes[index]),
          onMove: (key) => onMove(index, key),
          onActivate: () => onActivate(items[index]),
          autofocus: autofocusFirst && index == 0,
        ),
      ),
    );
  }
}

class _FixtureCard extends StatefulWidget {
  const _FixtureCard({
    required this.item,
    required this.focusNode,
    required this.onFocused,
    required this.onMove,
    required this.onActivate,
    required this.autofocus,
  });

  final FixtureItem item;
  final FocusNode focusNode;
  final VoidCallback onFocused;
  final ValueChanged<LogicalKeyboardKey> onMove;
  final VoidCallback onActivate;
  final bool autofocus;

  @override
  State<_FixtureCard> createState() => _FixtureCardState();
}

class _FixtureCardState extends State<_FixtureCard> {
  bool _focused = false;
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final active = _focused || _hovered;
    return Focus(
      focusNode: widget.focusNode,
      autofocus: widget.autofocus,
      onFocusChange: (focused) {
        setState(() => _focused = focused);
        if (focused) {
          widget.onFocused();
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) {
              Scrollable.ensureVisible(
                context,
                duration: const Duration(milliseconds: 150),
                curve: Curves.easeOutCubic,
                alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
              );
            }
          });
        }
      },
      onKeyEvent: (_, event) {
        if (event is! KeyDownEvent) return KeyEventResult.ignored;
        final key = event.logicalKey;
        if (key == LogicalKeyboardKey.enter ||
            key == LogicalKeyboardKey.select) {
          widget.onActivate();
          return KeyEventResult.handled;
        }
        if (key == LogicalKeyboardKey.arrowLeft ||
            key == LogicalKeyboardKey.arrowRight ||
            key == LogicalKeyboardKey.arrowUp ||
            key == LogicalKeyboardKey.arrowDown) {
          widget.onMove(key);
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: Semantics(
        key: ValueKey('fixture-card-${widget.item.title}'),
        button: true,
        label: '${widget.item.title}, ${widget.item.kindLabel}, fixture item',
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          onEnter: (_) => setState(() => _hovered = true),
          onExit: (_) => setState(() => _hovered = false),
          child: GestureDetector(
            onTap: () {
              widget.focusNode.requestFocus();
              widget.onActivate();
            },
            child: AnimatedScale(
              scale: active ? 1.025 : 1,
              duration: const Duration(milliseconds: 130),
              curve: Curves.easeOutCubic,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 130),
                curve: Curves.easeOutCubic,
                decoration: BoxDecoration(
                  color: _raised,
                  borderRadius: BorderRadius.circular(7),
                  border: Border.all(
                    color: _focused ? _amber : _line,
                    width: _focused ? 2 : 1,
                  ),
                  boxShadow: active
                      ? const [
                          BoxShadow(
                            color: Color(0x55000000),
                            offset: Offset(0, 8),
                            blurRadius: 16,
                          ),
                        ]
                      : null,
                ),
                clipBehavior: Clip.antiAlias,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: SizedBox.expand(
                        child: CustomPaint(
                          painter: _FixtureArtworkPainter(widget.item.artSeed),
                        ),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(10, 9, 10, 10),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            widget.item.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: _warmWhite,
                              fontSize: 18,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            widget.item.kindLabel,
                            style: const TextStyle(
                              color: _quietText,
                              fontSize: 13,
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
      ),
    );
  }
}

class _FixtureArtworkPainter extends CustomPainter {
  _FixtureArtworkPainter(this.seed);

  final int seed;

  static const _palettes = <List<Color>>[
    [Color(0xFF274A53), Color(0xFF83B9B1), Color(0xFF15262B)],
    [Color(0xFF4C354E), Color(0xFFD78377), Color(0xFF271C2A)],
    [Color(0xFF504223), Color(0xFFD9BC6C), Color(0xFF292317)],
    [Color(0xFF203D5A), Color(0xFF7FACC9), Color(0xFF162230)],
    [Color(0xFF4D2E30), Color(0xFFC4765D), Color(0xFF28191A)],
    [Color(0xFF30503F), Color(0xFF93BE84), Color(0xFF1C3026)],
    [Color(0xFF463D67), Color(0xFF9F91D6), Color(0xFF26223A)],
    [Color(0xFF4A402D), Color(0xFFBBA56A), Color(0xFF292319)],
    [Color(0xFF25444C), Color(0xFF6DA6A4), Color(0xFF14272B)],
    [Color(0xFF5B3248), Color(0xFFD18AAB), Color(0xFF321B28)],
    [Color(0xFF30465E), Color(0xFF9CB8D3), Color(0xFF1B2837)],
    [Color(0xFF4E3D2B), Color(0xFFD19E69), Color(0xFF2B2318)],
  ];

  @override
  void paint(Canvas canvas, Size size) {
    final palette = _palettes[seed % _palettes.length];
    final base = Paint()..color = palette[0];
    canvas.drawRect(Offset.zero & size, base);
    final accent = Paint()..color = palette[1];
    final dark = Paint()..color = palette[2];
    final unit = math.min(size.width, size.height);
    switch (seed % 6) {
      case 0:
        canvas.drawCircle(
          Offset(size.width * .72, size.height * .35),
          unit * .32,
          accent,
        );
        canvas.drawRect(
          Rect.fromLTWH(0, size.height * .68, size.width, size.height * .32),
          dark,
        );
      case 1:
        canvas.drawPath(
          Path()
            ..moveTo(0, size.height * .2)
            ..lineTo(size.width, size.height * .65)
            ..lineTo(size.width, size.height)
            ..lineTo(0, size.height * .7)
            ..close(),
          dark,
        );
        canvas.drawRect(
          Rect.fromLTWH(size.width * .2, 0, unit * .15, size.height),
          accent,
        );
      case 2:
        canvas.drawCircle(
          Offset(size.width * .3, size.height * .35),
          unit * .2,
          accent,
        );
        canvas.drawCircle(
          Offset(size.width * .66, size.height * .7),
          unit * .34,
          dark,
        );
      case 3:
        canvas.drawPath(
          Path()
            ..moveTo(size.width * .05, size.height)
            ..lineTo(size.width * .52, 0)
            ..lineTo(size.width, size.height * .82)
            ..lineTo(size.width, size.height)
            ..close(),
          dark,
        );
        canvas.drawRect(
          Rect.fromLTWH(size.width * .72, 0, unit * .12, size.height),
          accent,
        );
      case 4:
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTWH(
              size.width * .12,
              size.height * .12,
              size.width * .76,
              size.height * .76,
            ),
            Radius.circular(unit * .16),
          ),
          dark,
        );
        canvas.drawCircle(
          Offset(size.width * .5, size.height * .48),
          unit * .22,
          accent,
        );
      case 5:
        canvas.drawRect(
          Rect.fromLTWH(0, size.height * .58, size.width, size.height * .42),
          dark,
        );
        for (var i = 0; i < 4; i++) {
          canvas.drawRect(
            Rect.fromLTWH(
              size.width * (.1 + i * .22),
              size.height * (.12 + i * .05),
              unit * .1,
              size.height * .55,
            ),
            accent,
          );
        }
    }
    final line = Paint()
      ..color = const Color(0x33F4F0E7)
      ..strokeWidth = 1;
    canvas.drawLine(
      Offset(0, size.height * .83),
      Offset(size.width, size.height * .83),
      line,
    );
  }

  @override
  bool shouldRepaint(covariant _FixtureArtworkPainter oldDelegate) =>
      oldDelegate.seed != seed;
}

class _NoPersonalizationHome extends StatefulWidget {
  const _NoPersonalizationHome({
    required this.showFixtureCopy,
    required this.focusNode,
    required this.onContentFocus,
    required this.onOpenRail,
    required this.onBrowseLive,
    required this.onBrowseMovies,
    required this.onBrowseSeries,
  });

  final bool showFixtureCopy;
  final FocusNode focusNode;
  final ValueChanged<FocusNode> onContentFocus;
  final VoidCallback onOpenRail;
  final VoidCallback onBrowseLive;
  final VoidCallback onBrowseMovies;
  final VoidCallback onBrowseSeries;

  @override
  State<_NoPersonalizationHome> createState() => _NoPersonalizationHomeState();
}

class _NoPersonalizationHomeState extends State<_NoPersonalizationHome> {
  late final List<FocusNode> _nodes = [
    widget.focusNode,
    FocusNode(debugLabel: 'no-personalization movies'),
    FocusNode(debugLabel: 'no-personalization series'),
  ];

  void _moveFocus(int index, LogicalKeyboardKey key) {
    if (key == LogicalKeyboardKey.arrowLeft) {
      if (index == 0) {
        widget.onOpenRail();
      } else {
        _nodes[index - 1].requestFocus();
      }
      return;
    }

    if (key == LogicalKeyboardKey.arrowRight && index < _nodes.length - 1) {
      _nodes[index + 1].requestFocus();
    }
  }

  @override
  void dispose() {
    for (final node in _nodes.skip(1)) {
      node.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: _graphite,
      child: SafeArea(
        left: false,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(48, 22, 32, 48),
          children: [
            _HomeHeader(narrow: false, showFixtureCopy: widget.showFixtureCopy),
            const SizedBox(height: 56),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 700),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Start with what you want to watch',
                    style: TextStyle(
                      color: _warmWhite,
                      fontSize: 28,
                      fontWeight: FontWeight.w700,
                      letterSpacing: -0.5,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    widget.showFixtureCopy
                        ? 'This local source fixture has no Favorites, groups, or watch history yet.'
                        : 'Your library has no Favorites, groups, or watch history yet.',
                    style: const TextStyle(
                      color: _quietText,
                      fontSize: 16,
                      height: 1.45,
                    ),
                  ),
                  const SizedBox(height: 28),
                  Wrap(
                    spacing: 12,
                    runSpacing: 12,
                    children: [
                      _DirectEntry(
                        label: 'Live',
                        icon: Icons.live_tv_outlined,
                        focusNode: _nodes[0],
                        autofocus: true,
                        onFocused: () => widget.onContentFocus(_nodes[0]),
                        onMove: (key) => _moveFocus(0, key),
                        onPressed: widget.onBrowseLive,
                      ),
                      _DirectEntry(
                        label: 'Movies',
                        icon: Icons.movie_outlined,
                        focusNode: _nodes[1],
                        onFocused: () => widget.onContentFocus(_nodes[1]),
                        onMove: (key) => _moveFocus(1, key),
                        onPressed: widget.onBrowseMovies,
                      ),
                      _DirectEntry(
                        label: 'Series',
                        icon: Icons.tv_outlined,
                        focusNode: _nodes[2],
                        onFocused: () => widget.onContentFocus(_nodes[2]),
                        onMove: (key) => _moveFocus(2, key),
                        onPressed: widget.onBrowseSeries,
                      ),
                    ],
                  ),
                  const SizedBox(height: 30),
                  const Text(
                    'Favorite something or create a group to make Home personal.',
                    style: TextStyle(color: _quietText, fontSize: 14),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DirectEntry extends StatefulWidget {
  const _DirectEntry({
    required this.label,
    required this.icon,
    required this.focusNode,
    required this.onFocused,
    required this.onMove,
    required this.onPressed,
    this.autofocus = false,
  });

  final String label;
  final IconData icon;
  final FocusNode focusNode;
  final VoidCallback onFocused;
  final ValueChanged<LogicalKeyboardKey> onMove;
  final VoidCallback onPressed;
  final bool autofocus;

  @override
  State<_DirectEntry> createState() => _DirectEntryState();
}

class _DirectEntryState extends State<_DirectEntry> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: widget.focusNode,
      autofocus: widget.autofocus,
      onFocusChange: (focused) {
        setState(() => _focused = focused);
        if (focused) widget.onFocused();
      },
      onKeyEvent: (_, event) {
        if (event is! KeyDownEvent) return KeyEventResult.ignored;
        if (event.logicalKey == LogicalKeyboardKey.arrowLeft ||
            event.logicalKey == LogicalKeyboardKey.arrowRight) {
          widget.onMove(event.logicalKey);
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
        label: 'Browse ${widget.label}',
        child: GestureDetector(
          onTap: () {
            widget.focusNode.requestFocus();
            widget.onPressed();
          },
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 130),
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
            decoration: BoxDecoration(
              color: _surface,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(
                color: _focused ? _amber : _line,
                width: _focused ? 2 : 1,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(widget.icon, color: _warmWhite, size: 20),
                const SizedBox(width: 10),
                Text(
                  widget.label,
                  style: const TextStyle(
                    color: _warmWhite,
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
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

class _NoSourceHome extends StatelessWidget {
  const _NoSourceHome({
    required this.focusNode,
    required this.onContentFocus,
    required this.onOpenRail,
    required this.onAddSource,
  });

  final FocusNode focusNode;
  final ValueChanged<FocusNode> onContentFocus;
  final VoidCallback onOpenRail;
  final VoidCallback onAddSource;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: _graphite,
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460),
          child: Padding(
            padding: const EdgeInsets.all(40),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(
                  Icons.add_to_queue_outlined,
                  color: _amber,
                  size: 34,
                ),
                const SizedBox(height: 20),
                const Text(
                  'Add your first source',
                  style: TextStyle(
                    color: _warmWhite,
                    fontSize: 30,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 12),
                const Text(
                  'Connect an Xtream or M3U source to begin.',
                  style: TextStyle(
                    color: _quietText,
                    fontSize: 16,
                    height: 1.45,
                  ),
                ),
                const SizedBox(height: 26),
                _FocusedAction(
                  label: 'Add source',
                  focusNode: focusNode,
                  onFocused: () => onContentFocus(focusNode),
                  onLeft: onOpenRail,
                  onPressed: onAddSource,
                ),
                const SizedBox(height: 18),
                const Text(
                  'Press Escape or Left to open navigation.',
                  style: TextStyle(color: _quietText, fontSize: 13),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _FocusedAction extends StatefulWidget {
  const _FocusedAction({
    required this.label,
    required this.focusNode,
    required this.onFocused,
    required this.onLeft,
    required this.onPressed,
  });

  final String label;
  final FocusNode focusNode;
  final VoidCallback onFocused;
  final VoidCallback onLeft;
  final VoidCallback onPressed;

  @override
  State<_FocusedAction> createState() => _FocusedActionState();
}

class _FocusedActionState extends State<_FocusedAction> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: widget.focusNode,
      autofocus: true,
      onFocusChange: (focused) {
        setState(() => _focused = focused);
        if (focused) widget.onFocused();
      },
      onKeyEvent: (_, event) {
        if (event is! KeyDownEvent) return KeyEventResult.ignored;
        if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
          widget.onLeft();
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
            widget.focusNode.requestFocus();
            widget.onPressed();
          },
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: _amber,
              borderRadius: BorderRadius.circular(6),
              border: _focused ? Border.all(color: _warmWhite, width: 2) : null,
            ),
            child: Text(
              widget.label,
              style: const TextStyle(
                color: Color(0xFF17120A),
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
