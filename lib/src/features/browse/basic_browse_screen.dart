import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

import '../../cinema.dart';
import '../../focus_edge.dart';
import '../artwork/artwork_loader.dart';
import '../artwork/source_artwork.dart';
import '../guide/guide_data.dart';
import '../sources/credential_store.dart';
import '../sources/epg_models.dart';
import '../sources/source_catalog_database.dart';
import '../sources/source_models.dart';
import 'catalog_scope_controller.dart';
import 'minimal_continuations.dart';
import 'playback_handoff.dart';
import 'series_info_loader.dart';

const _graphite = Cinema.ink;
const _surface = Color(0xFF141419);
const _raised = Color(0xFF1E1E23);
const _line = Color(0x1AF5F1E8);
const _warmWhite = Cinema.text;
const _quietText = Cinema.faint;
const _amber = Cinema.amber;

/// Space under each poster row, inside the grid's row extent.
const _posterRowGap = 16.0;

String? _catalogScopeState(CatalogScopeController controller) {
  final selected = controller.selectedSource;
  if (selected != null) {
    return switch (selected.status) {
      'refreshing' => 'Refreshing · showing saved catalog',
      'refresh_failed' => 'Refresh failed · showing saved catalog',
      _ => null,
    };
  }

  final refreshing = controller.sources
      .where((source) => source.status == 'refreshing')
      .length;
  final failed = controller.sources
      .where((source) => source.status == 'refresh_failed')
      .length;
  final affected = refreshing + failed;
  if (affected == 0) return null;
  final saved = affected == 1
      ? 'saved catalog remains available'
      : 'saved catalogs remain available';
  if (refreshing > 0 && failed > 0) {
    final refreshingSources =
        '$refreshing ${refreshing == 1 ? 'source' : 'sources'} refreshing';
    final failedSources =
        '$failed ${failed == 1 ? 'source' : 'sources'} refresh failed';
    return '$refreshingSources · $failedSources · $saved';
  }
  if (refreshing > 0) {
    return '$refreshing ${refreshing == 1 ? 'source' : 'sources'} refreshing · $saved';
  }
  return '$failed ${failed == 1 ? 'source' : 'sources'} refresh failed · $saved';
}

/// The deliberately small handoff from catalog browse into the later player.
typedef BrowseItemActivated = void Function(BrowseCatalogItem item);

/// A narrow test seam around the two bounded local catalog queries.
abstract interface class BasicBrowseData {
  Future<List<BrowseCategorySummary>> browseCategories({
    required String sourceId,
    required SourceMediaKind kind,
  });

  Future<BrowsePage> browsePage({
    required String sourceId,
    required SourceMediaKind kind,
    required BrowseCategorySelection selection,
    BrowseCursor? cursor,
    int limit,
  });
}

/// Bounded unified-library queries used only when the global scope is All
/// sources. Keeping this separate preserves the Phase 1 named-source seam.
abstract interface class ScopedBrowseData {
  Future<LibraryPage> browseLibraryPage({
    required LibraryScope scope,
    required SourceMediaKind kind,
    BrowseCursor? cursor,
    int limit,
  });

  Future<int> countLibraryItems({
    required LibraryScope scope,
    required SourceMediaKind kind,
  });
}

class DatabaseBasicBrowseData implements BasicBrowseData, ScopedBrowseData {
  const DatabaseBasicBrowseData(this.database);

  final SourceCatalogDatabase database;

  @override
  Future<List<BrowseCategorySummary>> browseCategories({
    required String sourceId,
    required SourceMediaKind kind,
  }) => database.browseCategories(sourceId: sourceId, kind: kind);

  @override
  Future<BrowsePage> browsePage({
    required String sourceId,
    required SourceMediaKind kind,
    required BrowseCategorySelection selection,
    BrowseCursor? cursor,
    int limit = 100,
  }) => database.browsePage(
    sourceId: sourceId,
    kind: kind,
    selection: selection,
    cursor: cursor,
    limit: limit,
  );

  @override
  Future<LibraryPage> browseLibraryPage({
    required LibraryScope scope,
    required SourceMediaKind kind,
    BrowseCursor? cursor,
    int limit = 100,
  }) => database.browseLibraryPage(
    scope: scope,
    kind: kind,
    cursor: cursor,
    limit: limit,
  );

  @override
  Future<int> countLibraryItems({
    required LibraryScope scope,
    required SourceMediaKind kind,
  }) => database.countLibraryItems(scope: scope, kind: kind);
}

/// Keeps only practical browse position while the shell changes destinations.
class BasicBrowseSession {
  final Map<String, _BrowseBookmark> _bookmarks = {};

  @visibleForTesting
  int mountedItemFocusCount = 0;

  _BrowseBookmark _bookmarkFor(SourceMediaKind kind, LibraryScope scope) {
    final sourceKey = scope.sourceId ?? 'all';
    return _bookmarks.putIfAbsent(
      '${kind.name}:$sourceKey',
      _BrowseBookmark.new,
    );
  }
}

class _BrowseBookmark {
  BrowseCategorySelection selection = const BrowseCategorySelection.all();
  String? focusedItemId;
  double scrollOffset = 0;
  List<BrowseCatalogItem> items = const [];
  Map<String, String> sourceNames = const {};
  Map<String, String> epgCatalogIds = const {};
  List<BrowseCategorySummary> categories = const [];
  int? total;
  int? controllerRevision;
  BrowseCursor? nextCursor;
}

class BasicBrowseScreen extends StatefulWidget {
  const BasicBrowseScreen({
    super.key,
    required this.kind,
    required this.source,
    required this.initialFocus,
    required this.onContentFocus,
    required this.onOpenRail,
    required this.session,
    this.data,
    this.scopedData,
    this.scopeController,
    this.onOpenSourceSetup,
    this.onItemActivated,
    this.onPlaybackHandoff,
    this.selectingSecondChannel = false,
    this.secondChannelMessage,
    this.secondChannelBusy = false,
    this.onCancelSecondChannel,
    this.onOrganizeItem,
    this.credentialStore,
    this.seriesInfoLoader,
    this.artworkLoader,
    this.epgWindowPort,
    this.now,
  });

  final SourceMediaKind kind;
  final PersistedSource? source;
  final FocusNode initialFocus;
  final ValueChanged<FocusNode> onContentFocus;
  final VoidCallback onOpenRail;
  final BasicBrowseSession session;
  final BasicBrowseData? data;
  final ScopedBrowseData? scopedData;
  final CatalogScopeController? scopeController;
  final VoidCallback? onOpenSourceSetup;

  /// Legacy browse notification kept only for the existing shell tests.
  /// New playback work must use [onPlaybackHandoff].
  final BrowseItemActivated? onItemActivated;
  final ValueChanged<PlaybackHandoff>? onPlaybackHandoff;
  final bool selectingSecondChannel;
  final String? secondChannelMessage;
  final bool secondChannelBusy;
  final VoidCallback? onCancelSecondChannel;
  final ValueChanged<BrowseCatalogItem>? onOrganizeItem;
  final CredentialStore? credentialStore;
  final SeriesInfoLoader? seriesInfoLoader;
  final ArtworkProvider? artworkLoader;
  final EpgWindowPort? epgWindowPort;
  final DateTime Function()? now;

  @override
  State<BasicBrowseScreen> createState() => _BasicBrowseScreenState();
}

class _BasicBrowseScreenState extends State<BasicBrowseScreen> {
  static const _pageSize = 100;
  final FocusNode _categoryLauncherFocus = FocusNode(
    debugLabel: 'browse categories launcher',
  );
  final FocusNode _scopeFocus = FocusNode(debugLabel: 'catalog scope');
  final ScrollController _itemsScroll = ScrollController();

  /// Movies and series show as a poster grid; its shape comes from layout.
  bool get _posterGrid => widget.kind != SourceMediaKind.live;
  int _gridColumns = 1;
  double _gridRowExtent = 220;
  final ScrollController _categoriesScroll = ScrollController();
  final Map<int, FocusNode> _mountedCategoryNodes = {};
  final Map<String, FocusNode> _mountedItemNodes = {};
  Timer? _epgTimer;
  Timer? _epgBoundaryTimer;
  Map<String, EpgChannelWindow> _epgWindows = const {};
  final Map<String, DateTime> _epgRefreshAttempts = {};
  int _epgWindowRequest = 0;
  List<BrowseCategorySummary>? _categories;
  List<BrowseCatalogItem> _items = const [];
  BrowseCursor? _nextCursor;
  Object? _error;
  bool _loading = false;
  bool _loadingMore = false;
  bool _pageError = false;
  bool _restoringCachedFocus = false;
  bool _categoryOverlay = false;
  bool _scopeMenu = false;
  int _request = 0;
  int _seriesRequest = 0;
  _BrowseContinuation? _continuation;
  late BasicBrowseData _data;
  late ScopedBrowseData _scopedData;
  late SeriesInfoLoader _seriesInfoLoader;
  late _BrowseBookmark _bookmark;
  LibraryScope _activeScope = const LibraryScope.all();
  PersistedSource? _activeSource;
  int _scopeRevision = -1;
  int? _total;

  @override
  void initState() {
    super.initState();
    _data =
        widget.data ?? const DatabaseBasicBrowseData(SourceCatalogDatabase());
    _scopedData =
        widget.scopedData ??
        const DatabaseBasicBrowseData(SourceCatalogDatabase());
    _seriesInfoLoader =
        widget.seriesInfoLoader ??
        XtreamSeriesInfoLoader(credentialStore: widget.credentialStore);
    _activeScope =
        widget.scopeController?.scope ??
        (widget.source == null
            ? const LibraryScope.all()
            : LibraryScope.source(widget.source!.id));
    _activeSource = widget.source;
    _bookmark = widget.session._bookmarkFor(widget.kind, _activeScope);
    _restoringCachedFocus =
        _bookmark.items.isNotEmpty && _bookmark.focusedItemId != null;
    _itemsScroll.addListener(_maybeLoadMore);
    final scopeController = widget.scopeController;
    if (scopeController == null) {
      _loadCatalog(resetSelection: false);
    } else {
      scopeController.addListener(_onScopeStateChanged);
      unawaited(scopeController.initialize());
      if (scopeController.initialized) _onScopeStateChanged();
    }
  }

  @override
  void didUpdateWidget(covariant BasicBrowseScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.scopeController != widget.scopeController) {
      oldWidget.scopeController?.removeListener(_onScopeStateChanged);
      widget.scopeController?.addListener(_onScopeStateChanged);
      unawaited(widget.scopeController?.initialize());
      _scopeRevision = -1;
    }
    if (oldWidget.kind != widget.kind ||
        oldWidget.source?.id != widget.source?.id ||
        oldWidget.scopeController != widget.scopeController) {
      if (oldWidget.kind != widget.kind) _scopeRevision = -1;
      _cancelSeriesRequest();
      _continuation = null;
      _rememberPosition();
      _activeScope =
          widget.scopeController?.scope ??
          (widget.source == null
              ? const LibraryScope.all()
              : LibraryScope.source(widget.source!.id));
      _activeSource = widget.source;
      _bookmark = widget.session._bookmarkFor(widget.kind, _activeScope);
      _items = const [];
      _categories = null;
      _nextCursor = null;
      _error = null;
      _clearEpgPresentation();
      if (widget.scopeController == null) {
        _loadCatalog(resetSelection: false);
      } else {
        _onScopeStateChanged();
      }
    }
    if (oldWidget.epgWindowPort != widget.epgWindowPort) {
      _clearEpgPresentation();
      _scheduleVisibleEpg(immediate: true);
    }
  }

  @override
  void dispose() {
    final epgPort = widget.epgWindowPort;
    if (epgPort != null) {
      unawaited(epgPort.refreshCatalogItems(const []));
    }
    _epgTimer?.cancel();
    _epgBoundaryTimer?.cancel();
    _cancelSeriesRequest();
    widget.scopeController?.removeListener(_onScopeStateChanged);
    _rememberPosition();
    _itemsScroll
      ..removeListener(_maybeLoadMore)
      ..dispose();
    _categoriesScroll.dispose();
    _categoryLauncherFocus.dispose();
    _scopeFocus.dispose();
    widget.session.mountedItemFocusCount = 0;
    super.dispose();
  }

  void _onScopeStateChanged() {
    final controller = widget.scopeController;
    if (!mounted || controller == null) return;
    if (!controller.initialized) {
      setState(() {});
      return;
    }
    if (_scopeRevision == controller.revision &&
        _sameScope(_activeScope, controller.scope)) {
      setState(() {});
      return;
    }
    final scopeChanged = !_sameScope(_activeScope, controller.scope);
    final revisionReload =
        _scopeRevision >= 0 &&
        _scopeRevision != controller.revision &&
        !scopeChanged;
    final ordinaryScopeNavigation =
        _scopeRevision >= 0 && scopeChanged && controller.announcement == null;
    _rememberPosition();
    _cancelSeriesRequest();
    _continuation = null;
    _activeScope = controller.scope;
    _activeSource = null;
    _scopeRevision = controller.revision;
    _bookmark = widget.session._bookmarkFor(widget.kind, _activeScope);
    // Selecting another scope does not change either scope's catalog data.
    // Rebase an already-loaded bookmark so ordinary in-session navigation can
    // restore it, while an older bookmark found on remount still refreshes.
    if (ordinaryScopeNavigation && _bookmark.items.isNotEmpty) {
      _bookmark.controllerRevision = controller.revision;
    }
    _items = _bookmark.items;
    _categories = _bookmark.items.isEmpty ? null : _bookmark.categories;
    _nextCursor = _bookmark.nextCursor;
    _total = _bookmark.total;
    _error = null;
    _clearEpgPresentation();
    _restoringCachedFocus =
        _bookmark.items.isNotEmpty && _bookmark.focusedItemId != null;
    unawaited(_loadCatalog(resetSelection: false, forceFresh: revisionReload));
  }

  bool _sameScope(LibraryScope a, LibraryScope b) => a.sourceId == b.sourceId;

  void _rememberPosition() {
    if (_itemsScroll.hasClients) {
      _bookmark.scrollOffset = _itemsScroll.offset;
    }
  }

  void _clearEpgPresentation() {
    _epgWindowRequest += 1;
    _epgTimer?.cancel();
    _epgBoundaryTimer?.cancel();
    _epgWindows = const {};
    _epgRefreshAttempts.clear();
    final epgPort = widget.epgWindowPort;
    if (epgPort != null) {
      unawaited(epgPort.refreshCatalogItems(const []));
    }
  }

  Future<void> _loadCatalog({
    required bool resetSelection,
    bool forceFresh = false,
  }) async {
    final scopeController = widget.scopeController;
    if (scopeController != null && !scopeController.initialized) return;
    final request = ++_request;
    final scope = _activeScope;
    final scopeRevision = scopeController?.revision;
    final bookmark = _bookmark;
    final kind = widget.kind;
    final bookmarkRevisionStale =
        scopeController != null &&
        bookmark.items.isNotEmpty &&
        bookmark.controllerRevision != scopeRevision;
    final requiresFresh = forceFresh || bookmarkRevisionStale;
    final allSources = scopeController != null && scope.isAll;
    var source = scopeController == null ? widget.source : _activeSource;
    setState(() {
      _loading = true;
      _loadingMore = false;
      _pageError = false;
      _error = null;
      if (requiresFresh) {
        _items = const [];
        _categories = null;
        _nextCursor = null;
        _total = null;
        _restoringCachedFocus = false;
        _clearEpgPresentation();
      }
    });
    if (requiresFresh) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _scopeFocus.requestFocus();
      });
    }
    if (!allSources && source == null && scope.sourceId != null) {
      source = await scopeController?.resolveReadySource(scope.sourceId!);
      if (!_catalogRequestIsCurrent(
        request: request,
        controller: scopeController,
        scopeRevision: scopeRevision,
        scope: scope,
        bookmark: bookmark,
      )) {
        return;
      }
      _activeSource = source;
    }
    if (!allSources && source == null) {
      setState(() {
        _categories = const [];
        _items = const [];
        _error = null;
        _loading = false;
      });
      return;
    }
    try {
      final totalFuture = allSources || scopeController != null
          ? _scopedData.countLibraryItems(scope: scope, kind: kind)
          : Future<int>.value(source!.counts[kind] ?? 0);
      final categoriesFuture = allSources
          ? Future<List<BrowseCategorySummary>>.value(const [])
          : _data.browseCategories(sourceId: source!.id, kind: kind);
      final results = await Future.wait<Object>([
        categoriesFuture,
        totalFuture,
      ]);
      final categories = results[0] as List<BrowseCategorySummary>;
      final total = results[1] as int;
      if (!_catalogRequestIsCurrent(
        request: request,
        controller: scopeController,
        scopeRevision: scopeRevision,
        scope: scope,
        bookmark: bookmark,
      )) {
        return;
      }
      bookmark
        ..categories = categories
        ..total = total;
      final selected = allSources
          ? null
          : _usableSelection(categories, bookmark.selection);
      if (!allSources && (resetSelection || selected == null)) {
        bookmark
          ..selection = const BrowseCategorySelection.all()
          ..items = const []
          ..nextCursor = null
          ..scrollOffset = 0
          ..focusedItemId = null;
      } else if (selected != null) {
        bookmark.selection = selected.selection;
      }
      if (bookmark.items.isNotEmpty && !requiresFresh) {
        setState(() {
          _categories = categories;
          _items = bookmark.items;
          _nextCursor = bookmark.nextCursor;
          _total = total;
          _loading = false;
        });
        _restoringCachedFocus = bookmark.focusedItemId != null;
        _restoreListPosition(restoreFocus: true);
        _scheduleVisibleEpg(immediate: true);
      } else {
        setState(() {
          _categories = categories;
          _total = total;
        });
        await _loadFirstPage(
          request,
          controller: scopeController,
          scopeRevision: scopeRevision,
          scope: scope,
          source: source,
          bookmark: bookmark,
          kind: kind,
        );
      }
    } catch (_) {
      if (!_catalogRequestIsCurrent(
        request: request,
        controller: scopeController,
        scopeRevision: scopeRevision,
        scope: scope,
        bookmark: bookmark,
      )) {
        return;
      }
      setState(() {
        _loading = false;
        _error = Object();
      });
    }
  }

  bool _catalogRequestIsCurrent({
    required int request,
    required CatalogScopeController? controller,
    required int? scopeRevision,
    required LibraryScope scope,
    required _BrowseBookmark bookmark,
  }) =>
      mounted &&
      request == _request &&
      identical(widget.scopeController, controller) &&
      identical(_bookmark, bookmark) &&
      _sameScope(_activeScope, scope) &&
      (controller == null || controller.revision == scopeRevision);

  BrowseCategorySummary? _usableSelection(
    List<BrowseCategorySummary> categories,
    BrowseCategorySelection selection,
  ) {
    for (final category in categories) {
      if (_sameSelection(category.selection, selection)) return category;
    }
    return null;
  }

  Future<void> _loadFirstPage(
    int request, {
    CatalogScopeController? controller,
    int? scopeRevision,
    LibraryScope? scope,
    PersistedSource? source,
    _BrowseBookmark? bookmark,
    SourceMediaKind? kind,
  }) async {
    final snapshotScope = scope ?? _activeScope;
    final snapshotBookmark = bookmark ?? _bookmark;
    final snapshotKind = kind ?? widget.kind;
    final snapshotController = controller ?? widget.scopeController;
    final snapshotRevision = scopeRevision ?? snapshotController?.revision;
    final snapshotSource = source ?? _activeSource ?? widget.source;
    try {
      final page = await _readPage(
        controller: snapshotController,
        scope: snapshotScope,
        source: snapshotSource,
        bookmark: snapshotBookmark,
        kind: snapshotKind,
      );
      if (!_catalogRequestIsCurrent(
        request: request,
        controller: snapshotController,
        scopeRevision: snapshotRevision,
        scope: snapshotScope,
        bookmark: snapshotBookmark,
      )) {
        return;
      }
      setState(() {
        _items = page.items;
        _nextCursor = page.nextCursor;
        _loading = false;
        _pageError = false;
      });
      snapshotBookmark
        ..items = page.items
        ..nextCursor = page.nextCursor
        ..controllerRevision = snapshotRevision;
      _restoreListPosition();
      _scheduleVisibleEpg(immediate: true);
    } catch (_) {
      if (!_catalogRequestIsCurrent(
        request: request,
        controller: snapshotController,
        scopeRevision: snapshotRevision,
        scope: snapshotScope,
        bookmark: snapshotBookmark,
      )) {
        return;
      }
      setState(() {
        _loading = false;
        _error = Object();
      });
    }
  }

  void _restoreListPosition({bool restoreFocus = false}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_itemsScroll.hasClients) return;
      final desired = _bookmark.scrollOffset.clamp(
        0.0,
        _itemsScroll.position.maxScrollExtent,
      );
      if ((_itemsScroll.offset - desired).abs() > 0.5) {
        _itemsScroll.jumpTo(desired);
      }
      if (restoreFocus && _bookmark.focusedItemId != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _restoreCachedFocus();
        });
      }
    });
  }

  void _restoreCachedFocus([int remainingFrames = 8]) {
    if (!mounted) return;
    final id = _bookmark.focusedItemId;
    final index = _items.indexWhere((item) => item.id == id);
    if (index < 0) return;
    _focusItemAt(index);
    final node = index == 0
        ? widget.initialFocus
        : _mountedItemNodes[_items[index].id];
    if (node?.context != null) {
      _restoringCachedFocus = false;
      return;
    }
    if (remainingFrames > 0) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _restoreCachedFocus(remainingFrames - 1),
      );
    }
  }

  void _maybeLoadMore() {
    _scheduleVisibleEpg();
    if (_itemsScroll.hasClients) {
      _bookmark.scrollOffset = _itemsScroll.offset;
    }
    if (!_itemsScroll.hasClients ||
        _nextCursor == null ||
        _loadingMore ||
        _loading ||
        _itemsScroll.position.extentAfter > 260) {
      return;
    }
    unawaited(_loadMore());
  }

  void _scheduleVisibleEpg({bool immediate = false}) {
    if (widget.kind != SourceMediaKind.live ||
        widget.epgWindowPort == null ||
        _items.isEmpty) {
      return;
    }
    _epgTimer?.cancel();
    if (immediate) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _loadVisibleEpg());
    } else {
      _epgTimer = Timer(const Duration(milliseconds: 120), _loadVisibleEpg);
    }
  }

  Future<void> _loadVisibleEpg() async {
    final port = widget.epgWindowPort;
    if (!mounted ||
        port == null ||
        widget.kind != SourceMediaKind.live ||
        _items.isEmpty) {
      return;
    }
    final extent = _itemRowExtent;
    final offset = _itemsScroll.hasClients ? _itemsScroll.offset : 0.0;
    final viewport = _itemsScroll.hasClients
        ? _itemsScroll.position.viewportDimension
        : extent * 8;
    final first = ((offset / extent).floor() - 2).clamp(0, _items.length);
    final count = ((viewport / extent).ceil() + 6).clamp(
      1,
      basicBrowseMountedEpgLimit,
    );
    final end = (first + count).clamp(0, _items.length);
    if (first >= end) return;
    final ids = <String>[];
    for (final item in _items.sublist(first, end)) {
      final id = _activeScope.isAll
          ? _bookmark.epgCatalogIds[item.id]
          : item.id;
      if (id != null && id.isNotEmpty && !ids.contains(id)) ids.add(id);
    }
    if (ids.isEmpty) {
      if (_epgWindows.isNotEmpty) {
        setState(_clearEpgPresentation);
      } else {
        _clearEpgPresentation();
      }
      return;
    }
    final request = _request;
    final windowRequest = ++_epgWindowRequest;
    final nowUtc = (widget.now?.call() ?? DateTime.now()).toUtc();
    final startUtc = nowUtc.subtract(const Duration(hours: 2));
    final endUtc = nowUtc.add(const Duration(hours: 24));

    Future<void> readCache() async {
      final windows = await port.loadEpgWindow(
        catalogItemIds: ids,
        windowStartUtc: startUtc,
        windowEndUtc: endUtc,
        atUtc: nowUtc,
      );
      if (!mounted ||
          request != _request ||
          windowRequest != _epgWindowRequest ||
          widget.epgWindowPort != port) {
        return;
      }
      setState(() {
        _epgWindows = Map.unmodifiable({
          for (final window in windows) window.catalogItemId: window,
        });
      });
      _scheduleEpgBoundaryRefresh();
    }

    try {
      await readCache();
      if (!mounted ||
          request != _request ||
          windowRequest != _epgWindowRequest) {
        return;
      }
      _epgRefreshAttempts.removeWhere((id, _) => !ids.contains(id));
      final toRefresh = ids
          .where((id) {
            final previous = _epgRefreshAttempts[id];
            return previous == null ||
                nowUtc.difference(previous) >= const Duration(minutes: 5);
          })
          .toList(growable: false);
      if (toRefresh.isEmpty) return;
      for (final id in toRefresh) {
        _epgRefreshAttempts[id] = nowUtc;
      }
      await port.refreshCatalogItems(toRefresh);
      await readCache();
    } catch (_) {
      // Now/Next is optional local metadata. Browse and playback stay primary.
      if (mounted &&
          request == _request &&
          windowRequest == _epgWindowRequest) {
        _scheduleEpgBoundaryRefresh(forceFallback: true);
      }
    }
  }

  void _scheduleEpgBoundaryRefresh({bool forceFallback = false}) {
    _epgBoundaryTimer?.cancel();
    final now = (widget.now?.call() ?? DateTime.now()).toUtc();
    DateTime? boundary;
    for (final window in _epgWindows.values) {
      for (final program in window.programs) {
        for (final candidate in [program.startUtc, program.endUtc]) {
          if (candidate.isAfter(now) &&
              (boundary == null || candidate.isBefore(boundary))) {
            boundary = candidate;
          }
        }
      }
      final fallbackDelay = switch (window.availability) {
        EpgAvailability.unknown ||
        EpgAvailability.refreshing ||
        EpgAvailability.temporarilyUnavailable => const Duration(minutes: 5),
        EpgAvailability.empty => const Duration(minutes: 15),
        EpgAvailability.available when window.programs.isEmpty =>
          const Duration(minutes: 30),
        EpgAvailability.unsupported => const Duration(hours: 6),
        EpgAvailability.providerBlocked => const Duration(hours: 1),
        EpgAvailability.available => null,
      };
      if (fallbackDelay != null) {
        final fallback = now.add(fallbackDelay);
        if (boundary == null || fallback.isBefore(boundary)) {
          boundary = fallback;
        }
      }
    }
    if (boundary == null && forceFallback) {
      boundary = now.add(const Duration(minutes: 5));
    }
    if (boundary == null) return;
    final delay = boundary.difference(now) + const Duration(milliseconds: 100);
    _epgBoundaryTimer = Timer(delay, _loadVisibleEpg);
  }

  Future<void> _loadMore() async {
    final cursor = _nextCursor;
    if (cursor == null || _loadingMore) return;
    final request = _request;
    final controller = widget.scopeController;
    final scopeRevision = controller?.revision;
    final scope = _activeScope;
    final bookmark = _bookmark;
    final selection = bookmark.selection;
    final source = _activeSource ?? widget.source;
    final kind = widget.kind;
    setState(() {
      _loadingMore = true;
      _pageError = false;
    });
    try {
      final page = await _readPage(
        controller: controller,
        scope: scope,
        source: source,
        bookmark: bookmark,
        kind: kind,
        cursor: cursor,
      );
      if (!_catalogRequestIsCurrent(
            request: request,
            controller: controller,
            scopeRevision: scopeRevision,
            scope: scope,
            bookmark: bookmark,
          ) ||
          !_sameSelection(selection, bookmark.selection)) {
        return;
      }
      setState(() {
        _items = [..._items, ...page.items];
        _nextCursor = page.nextCursor;
        _loadingMore = false;
      });
      bookmark
        ..items = _items
        ..nextCursor = page.nextCursor
        ..controllerRevision = scopeRevision;
      _scheduleVisibleEpg(immediate: true);
    } catch (_) {
      if (!_catalogRequestIsCurrent(
            request: request,
            controller: controller,
            scopeRevision: scopeRevision,
            scope: scope,
            bookmark: bookmark,
          ) ||
          !_sameSelection(selection, bookmark.selection)) {
        return;
      }
      setState(() {
        _loadingMore = false;
        _pageError = true;
      });
    }
  }

  Future<BrowsePage> _readPage({
    required CatalogScopeController? controller,
    required LibraryScope scope,
    required PersistedSource? source,
    required _BrowseBookmark bookmark,
    required SourceMediaKind kind,
    BrowseCursor? cursor,
  }) async {
    if (controller != null && scope.isAll) {
      final page = await _scopedData.browseLibraryPage(
        scope: scope,
        kind: kind,
        cursor: cursor,
        limit: _pageSize,
      );
      final names = Map<String, String>.of(bookmark.sourceNames);
      final epgCatalogIds = Map<String, String>.of(bookmark.epgCatalogIds);
      final items = page.items
          .map((item) {
            names[item.libraryItemId] = item.sourceDisplayName;
            epgCatalogIds[item.libraryItemId] = item.catalogItemId;
            return BrowseCatalogItem(
              id: item.libraryItemId,
              sourceId: item.sourceId,
              kind: item.kind,
              title: item.title,
              artworkLocator: item.artworkLocator,
              playbackRef: item.playbackRef,
              libraryItemId: item.libraryItemId,
            );
          })
          .toList(growable: false);
      bookmark.sourceNames = Map.unmodifiable(names);
      bookmark.epgCatalogIds = Map.unmodifiable(epgCatalogIds);
      return BrowsePage(items: items, nextCursor: page.nextCursor);
    }
    if (source == null) {
      throw StateError('No ready source for named catalog scope.');
    }
    return _data.browsePage(
      sourceId: source.id,
      kind: kind,
      selection: bookmark.selection,
      cursor: cursor,
      limit: _pageSize,
    );
  }

  Future<void> _chooseCategory(BrowseCategorySummary category) async {
    if (_sameSelection(_bookmark.selection, category.selection)) {
      if (_categoryOverlay) _dismissCategoryOverlay(toLauncher: false);
      return;
    }
    _rememberPosition();
    _bookmark
      ..selection = category.selection
      ..focusedItemId = null
      ..scrollOffset = 0
      ..items = const []
      ..nextCursor = null;
    if (_itemsScroll.hasClients) _itemsScroll.jumpTo(0);
    setState(() {
      _items = const [];
      _nextCursor = null;
      _error = null;
      _loadingMore = false;
      _pageError = false;
      _categoryOverlay = false;
      _clearEpgPresentation();
    });
    final request = ++_request;
    setState(() => _loading = true);
    await _loadFirstPage(request);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_items.isEmpty) {
        widget.initialFocus.requestFocus();
      } else {
        _focusFirstItem();
      }
    });
  }

  void _focusFirstItem() {
    if (!mounted) return;
    final preferred = _items.firstWhere(
      (item) => item.id == _bookmark.focusedItemId,
      orElse: () => _items.isEmpty ? _emptyItem : _items.first,
    );
    if (preferred == _emptyItem) return;
    _focusItemAt(_items.indexOf(preferred));
  }

  static const _emptyItem = BrowseCatalogItem(
    id: '',
    sourceId: '',
    kind: SourceMediaKind.live,
    title: '',
    artworkLocator: null,
    playbackRef: '',
  );

  void _mountItemNode(String id, FocusNode node) {
    _mountedItemNodes[id] = node;
    widget.session.mountedItemFocusCount = _mountedItemNodes.length;
  }

  void _unmountItemNode(String id, FocusNode node) {
    if (identical(_mountedItemNodes[id], node)) _mountedItemNodes.remove(id);
    widget.session.mountedItemFocusCount = _mountedItemNodes.length;
  }

  void _mountCategoryNode(int index, FocusNode node) =>
      _mountedCategoryNodes[index] = node;

  void _unmountCategoryNode(int index, FocusNode node) {
    if (identical(_mountedCategoryNodes[index], node)) {
      _mountedCategoryNodes.remove(index);
    }
  }

  int _selectedCategoryIndex() {
    final categories = _categories ?? const <BrowseCategorySummary>[];
    return categories
        .indexWhere(
          (category) => _sameSelection(category.selection, _bookmark.selection),
        )
        .clamp(0, categories.isEmpty ? 0 : categories.length - 1);
  }

  void _focusItemAt(int index) {
    if (index < 0 || index >= _items.length) return;
    final columns = _posterGrid ? _gridColumns : 1;
    _focusVirtualRow(
      controller: _itemsScroll,
      index: index ~/ columns,
      rowExtent: _posterGrid ? _gridRowExtent : _itemRowExtent,
      node: () => index == 0
          ? widget.initialFocus
          : _mountedItemNodes[_items[index].id],
    );
  }

  void _focusCategoryAt(int index, {required double rowExtent}) {
    final categories = _categories ?? const <BrowseCategorySummary>[];
    if (index < 0 || index >= categories.length) return;
    _focusVirtualRow(
      controller: _categoriesScroll,
      index: index,
      rowExtent: rowExtent,
      node: () => _mountedCategoryNodes[index],
    );
  }

  void _focusVirtualRow({
    required ScrollController controller,
    required int index,
    required double rowExtent,
    required FocusNode? Function() node,
  }) {
    void revealThenFocus() {
      if (!mounted || !controller.hasClients) return;
      final position = controller.position;
      final rowStart = index * rowExtent;
      final rowEnd = rowStart + rowExtent;
      final visibleStart = controller.offset;
      final visibleEnd = visibleStart + position.viewportDimension;
      if (rowStart >= visibleStart && rowEnd <= visibleEnd) {
        node()?.requestFocus();
        return;
      }
      final target = (rowStart - (position.viewportDimension - rowExtent) / 2)
          .clamp(0.0, position.maxScrollExtent);
      controller.jumpTo(target);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) node()?.requestFocus();
      });
    }

    if (controller.hasClients) {
      revealThenFocus();
    } else {
      WidgetsBinding.instance.addPostFrameCallback((_) => revealThenFocus());
    }
  }

  void _focusSelectedCategory({double rowExtent = 48}) {
    final categories = _categories ?? const <BrowseCategorySummary>[];
    if (categories.isEmpty) {
      widget.onOpenRail();
      return;
    }
    _focusCategoryAt(_selectedCategoryIndex(), rowExtent: rowExtent);
  }

  void _activateItem(BrowseCatalogItem item) {
    _bookmark.focusedItemId = item.id;
    switch (item.kind) {
      case SourceMediaKind.live:
        _activateLive(item);
      case SourceMediaKind.movies:
        _openMovie(item);
      case SourceMediaKind.series:
        _openSeries(item);
    }
  }

  void _activateLive(BrowseCatalogItem item) {
    try {
      final handoff = playbackHandoffFor(item);
      widget.onPlaybackHandoff?.call(handoff);
      widget.onItemActivated?.call(item);
    } on ContinuationException catch (error) {
      setState(() {
        _continuation = _FailureContinuation(
          item: item,
          failure: error.failure,
        );
      });
    }
  }

  void _openMovie(BrowseCatalogItem item) {
    try {
      final handoff = playbackHandoffFor(item);
      if (handoff is! MoviePlaybackHandoff) {
        throw const ContinuationException(ContinuationFailure.invalidReference);
      }
      setState(() => _continuation = _MovieBrowseContinuation(item, handoff));
    } on ContinuationException catch (error) {
      setState(() {
        _continuation = _FailureContinuation(
          item: item,
          failure: error.failure,
        );
      });
    }
  }

  void _openSeries(BrowseCatalogItem item) {
    _cancelSeriesRequest();
    try {
      seriesReferenceFor(item);
    } on ContinuationException catch (error) {
      setState(() {
        _continuation = _FailureContinuation(
          item: item,
          failure: error.failure,
        );
      });
      return;
    }
    unawaited(_loadSeries(item));
  }

  Future<void> _loadSeries(BrowseCatalogItem item) async {
    final request = ++_seriesRequest;
    setState(() {
      _continuation = _SeriesBrowseContinuation(item: item, loading: true);
    });
    PersistedSource? source = _activeSource ?? widget.source;
    try {
      if (source?.id != item.sourceId) {
        source = await widget.scopeController?.resolveReadySource(
          item.sourceId,
        );
      }
    } catch (_) {
      if (!mounted || request != _seriesRequest) return;
      setState(() {
        _continuation = _SeriesBrowseContinuation(
          item: item,
          loading: false,
          failure: ContinuationFailure.unavailable,
        );
      });
      return;
    }
    if (!mounted || request != _seriesRequest) return;
    if (source == null) {
      setState(() {
        _continuation = _SeriesBrowseContinuation(
          item: item,
          loading: false,
          failure: ContinuationFailure.credentialsUnavailable,
        );
      });
      return;
    }
    try {
      final info = await _seriesInfoLoader.load(source: source, series: item);
      if (!mounted || request != _seriesRequest) return;
      setState(() {
        _continuation = _SeriesBrowseContinuation(
          item: item,
          loading: false,
          info: info,
        );
      });
    } on ContinuationException catch (error) {
      if (!mounted || request != _seriesRequest) return;
      setState(() {
        _continuation = _SeriesBrowseContinuation(
          item: item,
          loading: false,
          failure: error.failure,
        );
      });
    } catch (_) {
      if (!mounted || request != _seriesRequest) return;
      setState(() {
        _continuation = _SeriesBrowseContinuation(
          item: item,
          loading: false,
          failure: ContinuationFailure.unavailable,
        );
      });
    }
  }

  void _cancelSeriesRequest() {
    ++_seriesRequest;
    _seriesInfoLoader.cancel();
  }

  void _returnToBrowse() {
    _cancelSeriesRequest();
    // The catalog list is rebuilt after the continuation. Reuse its existing
    // post-layout restoration path so a deep virtual row reattaches before it
    // receives focus.
    _restoringCachedFocus = _bookmark.focusedItemId != null;
    setState(() => _continuation = null);
    _restoreListPosition(restoreFocus: true);
  }

  Widget _buildContinuation(_BrowseContinuation continuation) =>
      switch (continuation) {
        _MovieBrowseContinuation(:final item, :final handoff) =>
          MovieContinuation(
            title: item.title,
            artworkLocator: item.artworkLocator,
            artworkLoader: widget.artworkLoader,
            onOrganize: widget.onOrganizeItem == null
                ? null
                : () => widget.onOrganizeItem!(item),
            onBack: _returnToBrowse,
            onPlay: () {
              widget.onPlaybackHandoff?.call(handoff);
              widget.onItemActivated?.call(item);
            },
          ),
        _SeriesBrowseContinuation(
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
            onBack: _returnToBrowse,
            onRetry: () => _openSeries(item),
            onEpisodeActivated: (episode) {
              final handoff = EpisodePlaybackHandoff(
                sourceId: item.sourceId,
                title: episode.title,
                providerItemId: episode.providerItemId,
                extension: episode.extension,
                libraryItemId: item.libraryItemId,
              );
              widget.onPlaybackHandoff?.call(handoff);
              widget.onItemActivated?.call(item);
            },
          ),
        _FailureContinuation(:final item, :final failure) =>
          ContinuationFailureView(
            title: item.title,
            failure: failure,
            onBack: _returnToBrowse,
            onRetry: () => _activateItem(item),
          ),
      };

  void _dismissCategoryOverlay({required bool toLauncher}) {
    if (!_categoryOverlay) return;
    setState(() => _categoryOverlay = false);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (toLauncher) {
        _categoryLauncherFocus.requestFocus();
      } else {
        _focusFirstItem();
      }
    });
  }

  bool _sameSelection(BrowseCategorySelection a, BrowseCategorySelection b) =>
      a.kind == b.kind && a.sourceGroupId == b.sourceGroupId;

  double get _itemRowExtent {
    final scaled = MediaQuery.textScalerOf(context).scale(16);
    return 68 + ((scaled - 16).clamp(0, 16) * 1.25);
  }

  double get _categoryRowExtent {
    final scaled = MediaQuery.textScalerOf(context).scale(15);
    return 40 + ((scaled - 15).clamp(0, 15) * 1.2);
  }

  void _openScopeMenu() {
    final controller = widget.scopeController;
    if (controller == null || controller.sources.isEmpty || _scopeMenu) return;
    setState(() => _scopeMenu = true);
  }

  void _dismissScopeMenu() {
    if (!_scopeMenu) return;
    setState(() => _scopeMenu = false);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _scopeFocus.requestFocus();
    });
  }

  Future<void> _chooseScope(LibraryScope scope) async {
    final controller = widget.scopeController;
    if (controller == null) return;
    setState(() => _scopeMenu = false);
    _scopeFocus.requestFocus();
    await controller.select(scope);
    if (mounted) _scopeFocus.requestFocus();
  }

  void _focusFromScope({required bool narrow}) {
    if (_activeScope.isAll) {
      if (_items.isNotEmpty) _focusFirstItem();
      return;
    }
    if (narrow) {
      _categoryLauncherFocus.requestFocus();
    } else {
      _focusSelectedCategory(rowExtent: _categoryRowExtent);
    }
  }

  @override
  Widget build(BuildContext context) {
    final continuation = _continuation;
    if (continuation != null) return _buildContinuation(continuation);
    final scopeController = widget.scopeController;
    if (scopeController != null &&
        scopeController.loading &&
        scopeController.sources.isEmpty &&
        _items.isEmpty) {
      return _ScopeLoading(kind: widget.kind);
    }
    if (scopeController != null &&
        scopeController.error != null &&
        scopeController.sources.isEmpty) {
      return _BrowseMessage(
        title: 'Catalog unavailable',
        message: 'Could not load the local source list. Try again.',
        actionLabel: 'Try again',
        focusNode: widget.initialFocus,
        onFocused: widget.onContentFocus,
        onLeft: widget.onOpenRail,
        onPressed: () => unawaited(scopeController.refresh()),
      );
    }
    final allSources = scopeController != null && _activeScope.isAll;
    final source = scopeController == null ? widget.source : _activeSource;
    final noActiveSources = scopeController != null
        ? scopeController.sources.isEmpty
        : source == null;
    if (noActiveSources) {
      return _BrowseMessage(
        title: 'No source ready',
        message:
            'Add a source before browsing ${widget.kind.label.toLowerCase()}.',
        actionLabel: 'Add source',
        primaryAction: true,
        focusNode: widget.initialFocus,
        onFocused: widget.onContentFocus,
        onLeft: widget.onOpenRail,
        onPressed: widget.onOpenSourceSetup ?? widget.onOpenRail,
      );
    }
    if (_error != null && _items.isEmpty) {
      return _BrowseMessage(
        title: 'Catalog unavailable',
        message: 'Could not load this local catalog. Try again or check this source in Settings.',
        actionLabel: 'Try again',
        focusNode: widget.initialFocus,
        onFocused: widget.onContentFocus,
        onLeft: widget.onOpenRail,
        onPressed: () => _loadCatalog(resetSelection: false),
      );
    }
    if (!allSources &&
        _categories != null &&
        _categories!.isEmpty &&
        !_loading) {
      return _BrowseMessage(
        title: 'Catalog not ready',
        message:
            'This source does not have a ready ${widget.kind.label.toLowerCase()} catalog yet.',
        actionLabel: 'Open source',
        focusNode: widget.initialFocus,
        onFocused: widget.onContentFocus,
        onLeft: widget.onOpenRail,
        onPressed: widget.onOpenSourceSetup ?? widget.onOpenRail,
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final narrow = constraints.maxWidth < 760;
        return ColoredBox(
          color: _graphite,
          child: Focus(
            onKeyEvent: (_, event) {
              if (_scopeMenu &&
                  event is KeyDownEvent &&
                  (event.logicalKey == LogicalKeyboardKey.escape ||
                      event.logicalKey == LogicalKeyboardKey.browserBack)) {
                _dismissScopeMenu();
                return KeyEventResult.handled;
              }
              if (_categoryOverlay &&
                  event is KeyDownEvent &&
                  (event.logicalKey == LogicalKeyboardKey.escape ||
                      event.logicalKey == LogicalKeyboardKey.browserBack)) {
                _dismissCategoryOverlay(toLauncher: true);
                return KeyEventResult.handled;
              }
              return KeyEventResult.ignored;
            },
            child: SafeArea(
              left: false,
              child: Stack(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(24, 22, 32, 0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (widget.selectingSecondChannel) ...[
                          _SecondChannelBanner(
                            message: widget.secondChannelMessage,
                            busy: widget.secondChannelBusy,
                            onCancel: widget.onCancelSecondChannel,
                          ),
                          const SizedBox(height: 14),
                        ],
                        _DirectoryHeader(
                          kind: widget.kind,
                          summary: _headerSummary(
                            allSources: allSources,
                            source: source,
                            controller: scopeController,
                          ),
                          narrow: narrow,
                          showCategories: !allSources,
                          categoryFocusNode: _categoryLauncherFocus,
                          onOpenCategories: () {
                            setState(() => _categoryOverlay = true);
                            WidgetsBinding.instance.addPostFrameCallback((_) {
                              _focusSelectedCategory(
                                rowExtent: _categoryRowExtent + 4,
                              );
                            });
                          },
                          scopeLabel: scopeController?.scopeLabel,
                          scopeFocusNode: _scopeFocus,
                          onOpenScope: _openScopeMenu,
                          onScopeDown: () => _focusFromScope(narrow: narrow),
                        ),
                        const SizedBox(height: 18),
                        Expanded(
                          child:
                              _categories == null || _loading && _items.isEmpty
                              ? _DirectorySkeleton(
                                  narrow: narrow,
                                  unified: allSources,
                                )
                              : Row(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  children: [
                                    if (!allSources && !narrow) ...[
                                      SizedBox(
                                        width: 200,
                                        child: _CategoryPane(
                                          categories: _categories!,
                                          selected: _bookmark.selection,
                                          controller: _categoriesScroll,
                                          onNodeMounted: _mountCategoryNode,
                                          onNodeUnmounted: _unmountCategoryNode,
                                          onChoose: _chooseCategory,
                                          onOpenRail: widget.onOpenRail,
                                          onRight: _focusFirstItem,
                                          onFocusIndex: (index) =>
                                              _focusCategoryAt(
                                                index,
                                                rowExtent: _categoryRowExtent,
                                              ),
                                          rowExtent: _categoryRowExtent,
                                          onUpFromFirst: scopeController == null
                                              ? null
                                              : () =>
                                                    _scopeFocus.requestFocus(),
                                        ),
                                      ),
                                      const SizedBox(width: 24),
                                    ],
                                    Expanded(child: _buildItems()),
                                  ],
                                ),
                        ),
                      ],
                    ),
                  ),
                  if (!allSources &&
                      narrow &&
                      _categoryOverlay &&
                      _categories != null)
                    Positioned.fill(
                      child: _CategoryOverlay(
                        categories: _categories!,
                        selected: _bookmark.selection,
                        controller: _categoriesScroll,
                        onNodeMounted: _mountCategoryNode,
                        onNodeUnmounted: _unmountCategoryNode,
                        onChoose: _chooseCategory,
                        onDismiss: () =>
                            _dismissCategoryOverlay(toLauncher: true),
                        onFocusIndex: (index) => _focusCategoryAt(
                          index,
                          rowExtent: _categoryRowExtent + 4,
                        ),
                        rowExtent: _categoryRowExtent + 4,
                      ),
                    ),
                  if (_scopeMenu && scopeController != null)
                    Positioned(
                      top: 74,
                      right: 32,
                      width: constraints.maxWidth < 600 ? 220 : 248,
                      child: _ScopeMenu(
                        sources: scopeController.sources,
                        selected: scopeController.scope,
                        onChoose: (scope) => unawaited(_chooseScope(scope)),
                        onDismiss: _dismissScopeMenu,
                      ),
                    ),
                  if (scopeController?.announcement != null)
                    Positioned(
                      left: 32,
                      right: 32,
                      bottom: 10,
                      child: Semantics(
                        liveRegion: true,
                        label: scopeController!.announcement,
                        child: Text(
                          scopeController.announcement!,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            color: _quietText,
                            fontSize: 13,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  String _headerSummary({
    required bool allSources,
    required PersistedSource? source,
    required CatalogScopeController? controller,
  }) {
    final count = _total == null ? 'Loading' : _formatCount(_total!);
    final sourceState = controller == null
        ? null
        : _catalogScopeState(controller);
    if (allSources) {
      final sourceCount = controller?.sources.length ?? 0;
      final totalSummary =
          '$count available across $sourceCount ${sourceCount == 1 ? 'source' : 'sources'}';
      return sourceState == null
          ? totalSummary
          : '$sourceState · $totalSummary';
    }
    final noun = switch (widget.kind) {
      SourceMediaKind.live => _total == 1 ? 'channel' : 'channels',
      SourceMediaKind.movies => _total == 1 ? 'movie' : 'movies',
      SourceMediaKind.series => 'series',
    };
    // With a scope pill the source name is already on screen.
    final totalSummary = controller == null
        ? '$count $noun · ${source?.name ?? 'Source'}'
        : '$count $noun';
    return sourceState == null ? totalSummary : '$sourceState · $totalSummary';
  }

  Widget _buildItems() {
    final allSources = widget.scopeController != null && _activeScope.isAll;
    final selected = _usableSelection(
      _categories ?? const [],
      _bookmark.selection,
    );
    if (selected != null && selected.itemCount == 0 && !_loading) {
      return _EmptyCategory(
        kind: widget.kind,
        focusNode: widget.initialFocus,
        onFocused: widget.onContentFocus,
        onLeft: widget.onOpenRail,
        onReturnToAll: () {
          final all = _categories!.first;
          unawaited(_chooseCategory(all));
        },
      );
    }
    if (allSources && _items.isEmpty && !_loading) {
      return _EmptyUnifiedCatalog(
        kind: widget.kind,
        focusNode: widget.initialFocus,
        onFocused: widget.onContentFocus,
        onLeft: widget.onOpenRail,
        onChangeScope: _openScopeMenu,
      );
    }
    final nowUtc = (widget.now?.call() ?? DateTime.now()).toUtc();
    const overline = TextStyle(
      color: _quietText,
      fontSize: 12,
      fontWeight: FontWeight.w700,
      letterSpacing: 0.3,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  selected?.name ?? 'All ${widget.kind.label}',
                  key: const ValueKey('browse-selected-category'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: overline,
                ),
              ),
              if (allSources && !_posterGrid) ...[
                const SizedBox(width: 12),
                const SizedBox(
                  width: 170,
                  child: Text('SOURCE', style: overline),
                ),
                const SizedBox(width: 52),
              ],
            ],
          ),
        ),
        Expanded(
          child: _BottomFade(
            child: _posterGrid
                ? LayoutBuilder(
                    builder: (context, constraints) {
                      final textScaler = MediaQuery.textScalerOf(context);
                      const gap = 18.0;
                      final width = constraints.maxWidth - 16;
                      final columns = ((width + gap) / (112 + gap))
                          .floor()
                          .clamp(2, 10);
                      final tileWidth = (width - gap * (columns - 1)) / columns;
                      _gridColumns = columns;
                      _gridRowExtent =
                          tileWidth * 1.5 +
                          8 +
                          textScaler.scale(12.5) * 1.4 +
                          (allSources ? textScaler.scale(11.5) * 1.4 : 0) +
                          _posterRowGap;
                      return GridView.builder(
                        key: ValueKey('browse-items-${widget.kind.name}'),
                        controller: _itemsScroll,
                        padding: const EdgeInsets.fromLTRB(8, 8, 8, 48),
                        scrollCacheExtent: const ScrollCacheExtent.pixels(360),
                        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: columns,
                          crossAxisSpacing: gap,
                          mainAxisExtent: _gridRowExtent,
                        ),
                        itemCount: _items.length + (_loadingMore ? columns : 0),
                        itemBuilder: (context, index) => index >= _items.length
                            ? const Padding(
                                padding: EdgeInsets.only(bottom: 44),
                                child: DecoratedBox(
                                  decoration: BoxDecoration(
                                    color: _surface,
                                    borderRadius: BorderRadius.all(
                                      Radius.circular(12),
                                    ),
                                  ),
                                ),
                              )
                            : _itemTile(
                                index,
                                columns: columns,
                                allSources: allSources,
                                nowUtc: nowUtc,
                              ),
                      );
                    },
                  )
                : ListView.builder(
                    key: ValueKey('browse-items-${widget.kind.name}'),
                    controller: _itemsScroll,
                    itemExtent: _itemRowExtent,
                    padding: const EdgeInsets.only(bottom: 48),
                    scrollCacheExtent: const ScrollCacheExtent.pixels(360),
                    itemCount: _items.length + (_loadingMore ? 3 : 0),
                    itemBuilder: (context, index) => index >= _items.length
                        ? const _ItemSkeleton()
                        : _itemTile(
                            index,
                            columns: 1,
                            allSources: allSources,
                            nowUtc: nowUtc,
                          ),
                  ),
          ),
        ),
        if (_pageError) _PageErrorFooter(onRetry: () => unawaited(_loadMore())),
        if (_error != null && _items.isNotEmpty)
          _PageErrorFooter(
            label: 'Catalog update failed. Showing the last usable list.',
            onRetry: () => unawaited(_loadCatalog(resetSelection: false)),
          ),
      ],
    );
  }

  /// One list row or grid tile. Arrow keys move by [columns] vertically;
  /// Left from the first column returns to the categories (or the rail).
  Widget _itemTile(
    int index, {
    required int columns,
    required bool allSources,
    required DateTime nowUtc,
  }) {
    final item = _items[index];
    final column = index % columns;
    final epgCatalogId = allSources
        ? _bookmark.epgCatalogIds[item.id]
        : item.id;
    return _CatalogRow(
      key: ValueKey('browse-row-${item.id}'),
      item: item,
      kind: widget.kind,
      poster: _posterGrid,
      initialFocusNode: index == 0 ? widget.initialFocus : null,
      autofocus: index == 0 && !_restoringCachedFocus,
      artworkLoader: widget.artworkLoader,
      onNodeMounted: _mountItemNode,
      onNodeUnmounted: _unmountItemNode,
      onFocused: (node) {
        if (!_restoringCachedFocus) {
          _bookmark.focusedItemId = item.id;
        }
        widget.onContentFocus(node);
      },
      onLeft: column > 0
          ? () => _focusItemAt(index - 1)
          : allSources
          ? widget.onOpenRail
          : () => _focusSelectedCategory(rowExtent: _categoryRowExtent),
      onRight: _posterGrid
          ? () {
              if (column + 1 < columns) _focusItemAt(index + 1);
            }
          : null,
      onUp: index < columns
          ? (widget.scopeController == null
                ? null
                : () => _scopeFocus.requestFocus())
          : () => _focusItemAt(index - columns),
      onDown: () {
        if (index + columns < _items.length) {
          _focusItemAt(index + columns);
        } else if (_nextCursor != null) {
          unawaited(_loadMore());
        } else if (index ~/ columns < (_items.length - 1) ~/ columns) {
          _focusItemAt(_items.length - 1);
        }
      },
      onActivate: () => _activateItem(item),
      onOrganize: widget.onOrganizeItem == null
          ? null
          : () => widget.onOrganizeItem!(item),
      sourceName: allSources ? _bookmark.sourceNames[item.id] : null,
      nowNext: epgCatalogId == null ? null : _epgWindows[epgCatalogId]?.nowNext,
      nowUtc: nowUtc,
    );
  }
}

/// Fades a scrolling list into the ink at the bottom edge. Lists pad their
/// end by the fade's height so the last item can scroll clear of it.
class _BottomFade extends StatelessWidget {
  const _BottomFade({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => Stack(
    children: [
      Positioned.fill(child: child),
      const Positioned(
        left: 0,
        right: 0,
        bottom: 0,
        height: 48,
        child: IgnorePointer(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.bottomCenter,
                end: Alignment.topCenter,
                colors: [Cinema.ink, Color(0x000B0B0E)],
              ),
            ),
          ),
        ),
      ),
    ],
  );
}

/// The round Organize button a row or poster shows while focused or hovered.
class _OrganizeButton extends StatelessWidget {
  const _OrganizeButton({required this.onPressed, this.size = 34});

  final VoidCallback onPressed;
  final double size;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: 'Organize',
    child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onPressed,
      child: Container(
        width: size,
        height: size,
        decoration: const BoxDecoration(
          color: Color(0xB80B0B0E),
          shape: BoxShape.circle,
        ),
        child: Icon(
          Icons.bookmark_add_outlined,
          size: size * 0.5,
          color: _warmWhite,
        ),
      ),
    ),
  );
}

sealed class _BrowseContinuation {
  const _BrowseContinuation(this.item);
  final BrowseCatalogItem item;
}

class _MovieBrowseContinuation extends _BrowseContinuation {
  const _MovieBrowseContinuation(super.item, this.handoff);
  final MoviePlaybackHandoff handoff;
}

class _SeriesBrowseContinuation extends _BrowseContinuation {
  const _SeriesBrowseContinuation({
    required BrowseCatalogItem item,
    required this.loading,
    this.info,
    this.failure,
  }) : super(item);
  final bool loading;
  final SeriesInfo? info;
  final ContinuationFailure? failure;
}

class _FailureContinuation extends _BrowseContinuation {
  const _FailureContinuation({
    required BrowseCatalogItem item,
    required this.failure,
  }) : super(item);
  final ContinuationFailure failure;
}

class _SecondChannelBanner extends StatefulWidget {
  const _SecondChannelBanner({
    required this.message,
    required this.busy,
    required this.onCancel,
  });

  final String? message;
  final bool busy;
  final VoidCallback? onCancel;

  @override
  State<_SecondChannelBanner> createState() => _SecondChannelBannerState();
}

class _SecondChannelBannerState extends State<_SecondChannelBanner> {
  final _cancelFocus = FocusNode(debugLabel: 'cancel second channel');
  bool _focused = false;

  @override
  void dispose() {
    _cancelFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Container(
    key: const ValueKey('browse-second-channel-banner'),
    constraints: const BoxConstraints(minHeight: 64),
    padding: const EdgeInsets.fromLTRB(16, 10, 10, 10),
    decoration: BoxDecoration(
      color: _surface,
      border: Border.all(color: _line),
      borderRadius: BorderRadius.circular(8),
    ),
    child: Row(
      children: [
        const Icon(Icons.view_week_outlined, color: _amber, size: 22),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                widget.busy
                    ? 'Checking stream allowance…'
                    : 'Choose a second channel',
                style: const TextStyle(
                  color: _warmWhite,
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                widget.message ??
                    'Your current channel keeps playing in Corner Signal.',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: widget.message == null ? _quietText : _warmWhite,
                  fontSize: 12,
                  height: 1.25,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 12),
        Focus(
          focusNode: _cancelFocus,
          canRequestFocus: !widget.busy,
          onFocusChange: (value) => setState(() => _focused = value),
          onKeyEvent: (_, event) {
            if (!widget.busy &&
                event is KeyDownEvent &&
                (event.logicalKey == LogicalKeyboardKey.enter ||
                    event.logicalKey == LogicalKeyboardKey.select)) {
              widget.onCancel?.call();
              return KeyEventResult.handled;
            }
            return KeyEventResult.ignored;
          },
          child: Semantics(
            button: true,
            enabled: !widget.busy,
            label: 'Cancel adding a second channel',
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: widget.busy
                  ? null
                  : () {
                      _cancelFocus.requestFocus();
                      widget.onCancel?.call();
                    },
              child: Container(
                height: 44,
                padding: const EdgeInsets.symmetric(horizontal: 14),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: _focused ? _raised : Colors.transparent,
                  border: Border.all(
                    color: _focused ? _amber : _line,
                    width: _focused ? 2 : 1,
                  ),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: const Text(
                  'Cancel',
                  style: TextStyle(
                    color: _warmWhite,
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
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

class _DirectoryHeader extends StatelessWidget {
  const _DirectoryHeader({
    required this.kind,
    required this.summary,
    required this.narrow,
    required this.showCategories,
    required this.categoryFocusNode,
    required this.onOpenCategories,
    required this.scopeLabel,
    required this.scopeFocusNode,
    required this.onOpenScope,
    required this.onScopeDown,
  });

  final SourceMediaKind kind;
  final String summary;
  final bool narrow;
  final bool showCategories;
  final FocusNode categoryFocusNode;
  final VoidCallback onOpenCategories;
  final String? scopeLabel;
  final FocusNode scopeFocusNode;
  final VoidCallback onOpenScope;
  final VoidCallback onScopeDown;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Flexible(
                child: Text(
                  kind.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: _warmWhite,
                    fontFamily: Cinema.display,
                    fontSize: 28,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.6,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Flexible(
                child: Text(
                  summary,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: _quietText, fontSize: 13),
                ),
              ),
            ],
          ),
        ),
        if (scopeLabel != null) ...[
          SizedBox(width: narrow ? 12 : 16),
          ConstrainedBox(
            constraints: BoxConstraints(maxWidth: narrow ? 160 : 240),
            child: _ScopeButton(
              label: scopeLabel!,
              focusNode: scopeFocusNode,
              onPressed: onOpenScope,
              onDown: onScopeDown,
            ),
          ),
        ],
        if (narrow && showCategories) ...[
          const SizedBox(width: 12),
          SizedBox(
            width: 108,
            child: _DirectoryButton(
              label: 'Categories',
              focusNode: categoryFocusNode,
              onPressed: onOpenCategories,
            ),
          ),
        ],
      ],
    );
  }
}

class _ScopeButton extends StatefulWidget {
  const _ScopeButton({
    required this.label,
    required this.focusNode,
    required this.onPressed,
    required this.onDown,
  });

  final String label;
  final FocusNode focusNode;
  final VoidCallback onPressed;
  final VoidCallback onDown;

  @override
  State<_ScopeButton> createState() => _ScopeButtonState();
}

class _ScopeButtonState extends State<_ScopeButton> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) => Focus(
    focusNode: widget.focusNode,
    onFocusChange: (focused) => setState(() => _focused = focused),
    onKeyEvent: (_, event) {
      if (event is! KeyDownEvent) return KeyEventResult.ignored;
      switch (event.logicalKey) {
        case LogicalKeyboardKey.enter:
        case LogicalKeyboardKey.select:
          widget.onPressed();
          return KeyEventResult.handled;
        case LogicalKeyboardKey.arrowDown:
          widget.onDown();
          return KeyEventResult.handled;
        default:
          return KeyEventResult.ignored;
      }
    },
    child: Semantics(
      button: true,
      label: 'Catalog scope, ${widget.label}',
      child: GestureDetector(
        onTap: () {
          widget.focusNode.requestFocus();
          widget.onPressed();
        },
        child: AnimatedContainer(
          key: const ValueKey('catalog-scope-control'),
          duration: const Duration(milliseconds: 120),
          height: 40,
          padding: const EdgeInsets.fromLTRB(14, 0, 12, 0),
          decoration: BoxDecoration(
            color: _focused ? Cinema.amber : Cinema.glass,
            borderRadius: BorderRadius.circular(20),
            boxShadow: _focused ? [Cinema.focusGlow.last] : const [],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.layers_outlined,
                size: 16,
                color: _focused ? Cinema.amberInk : Cinema.quiet,
              ),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  widget.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: _focused ? Cinema.amberInk : Cinema.quiet,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const SizedBox(width: 6),
              Icon(
                Icons.keyboard_arrow_down,
                size: 18,
                color: _focused ? Cinema.amberInk : Cinema.quiet,
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

class _ScopeMenu extends StatefulWidget {
  const _ScopeMenu({
    required this.sources,
    required this.selected,
    required this.onChoose,
    required this.onDismiss,
  });

  final List<SourceRosterEntry> sources;
  final LibraryScope selected;
  final ValueChanged<LibraryScope> onChoose;
  final VoidCallback onDismiss;

  @override
  State<_ScopeMenu> createState() => _ScopeMenuState();
}

class _ScopeMenuState extends State<_ScopeMenu> {
  static const _rowExtent = 48.0;
  final ScrollController _scrollController = ScrollController();
  final Map<String, FocusNode> _mountedNodes = {};

  List<({LibraryScope scope, String label})> get _choices => [
    (scope: const LibraryScope.all(), label: 'All sources'),
    for (final source in widget.sources)
      (scope: LibraryScope.source(source.id), label: source.name),
  ];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final selectedIndex = _choices.indexWhere(
        (choice) => choice.scope.sourceId == widget.selected.sourceId,
      );
      _focusAt(selectedIndex < 0 ? 0 : selectedIndex);
    });
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _focusAt(int index) {
    final choices = _choices;
    if (index < 0 || index >= choices.length) return;
    final key = choices[index].scope.sourceId ?? 'all';

    void revealThenFocus() {
      if (!mounted || !_scrollController.hasClients) return;
      final position = _scrollController.position;
      final rowStart = 6 + index * _rowExtent;
      final rowEnd = rowStart + _rowExtent;
      final visibleStart = _scrollController.offset;
      final visibleEnd = visibleStart + position.viewportDimension;
      if (rowStart >= visibleStart && rowEnd <= visibleEnd) {
        _mountedNodes[key]?.requestFocus();
        return;
      }
      final target = (rowStart - (position.viewportDimension - _rowExtent) / 2)
          .clamp(0.0, position.maxScrollExtent);
      _scrollController.jumpTo(target);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _mountedNodes[key]?.requestFocus();
      });
    }

    if (_scrollController.hasClients) {
      revealThenFocus();
    } else {
      WidgetsBinding.instance.addPostFrameCallback((_) => revealThenFocus());
    }
  }

  @override
  Widget build(BuildContext context) {
    final choices = _choices;
    return Material(
      key: const ValueKey('catalog-scope-menu'),
      color: _surface,
      elevation: 10,
      shadowColor: Colors.black54,
      borderRadius: BorderRadius.circular(6),
      child: Container(
        constraints: const BoxConstraints(maxHeight: 264),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: _line),
        ),
        child: ListView.builder(
          controller: _scrollController,
          padding: const EdgeInsets.symmetric(vertical: 6),
          shrinkWrap: true,
          itemExtent: 48,
          itemCount: choices.length,
          itemBuilder: (context, index) {
            final choice = choices[index];
            return _ScopeOptionRow(
              key: ValueKey(
                'catalog-scope-row-${choice.scope.sourceId ?? 'all'}',
              ),
              nodeKey: choice.scope.sourceId ?? 'all',
              label: choice.label,
              selected: widget.selected.sourceId == choice.scope.sourceId,
              onNodeMounted: (key, node) => _mountedNodes[key] = node,
              onNodeUnmounted: (key, node) {
                if (identical(_mountedNodes[key], node)) {
                  _mountedNodes.remove(key);
                }
              },
              onChoose: () => widget.onChoose(choice.scope),
              onUp: index == 0 ? null : () => _focusAt(index - 1),
              onDown: index + 1 == choices.length
                  ? null
                  : () => _focusAt(index + 1),
              onDismiss: widget.onDismiss,
            );
          },
        ),
      ),
    );
  }
}

class _ScopeOptionRow extends StatefulWidget {
  const _ScopeOptionRow({
    super.key,
    required this.nodeKey,
    required this.label,
    required this.selected,
    required this.onNodeMounted,
    required this.onNodeUnmounted,
    required this.onChoose,
    required this.onUp,
    required this.onDown,
    required this.onDismiss,
  });

  final String nodeKey;
  final String label;
  final bool selected;
  final void Function(String key, FocusNode node) onNodeMounted;
  final void Function(String key, FocusNode node) onNodeUnmounted;
  final VoidCallback onChoose;
  final VoidCallback? onUp;
  final VoidCallback? onDown;
  final VoidCallback onDismiss;

  @override
  State<_ScopeOptionRow> createState() => _ScopeOptionRowState();
}

class _ScopeOptionRowState extends State<_ScopeOptionRow> {
  bool _focused = false;
  late final FocusNode _focusNode;

  @override
  void initState() {
    super.initState();
    _focusNode = FocusNode(debugLabel: 'catalog scope ${widget.nodeKey}');
    widget.onNodeMounted(widget.nodeKey, _focusNode);
  }

  @override
  void didUpdateWidget(covariant _ScopeOptionRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.nodeKey != widget.nodeKey) {
      oldWidget.onNodeUnmounted(oldWidget.nodeKey, _focusNode);
      widget.onNodeMounted(widget.nodeKey, _focusNode);
    }
  }

  @override
  void dispose() {
    widget.onNodeUnmounted(widget.nodeKey, _focusNode);
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Focus(
    focusNode: _focusNode,
    onFocusChange: (focused) => setState(() => _focused = focused),
    onKeyEvent: (_, event) {
      if (event is! KeyDownEvent) return KeyEventResult.ignored;
      switch (event.logicalKey) {
        case LogicalKeyboardKey.arrowUp:
          widget.onUp?.call();
          return KeyEventResult.handled;
        case LogicalKeyboardKey.arrowDown:
          widget.onDown?.call();
          return KeyEventResult.handled;
        case LogicalKeyboardKey.enter:
        case LogicalKeyboardKey.select:
          widget.onChoose();
          return KeyEventResult.handled;
        case LogicalKeyboardKey.escape:
        case LogicalKeyboardKey.browserBack:
          widget.onDismiss();
          return KeyEventResult.handled;
        default:
          return KeyEventResult.ignored;
      }
    },
    child: Semantics(
      button: true,
      selected: widget.selected,
      label: widget.label,
      child: GestureDetector(
        onTap: () {
          _focusNode.requestFocus();
          widget.onChoose();
        },
        child: Container(
          key: ValueKey('catalog-scope-${widget.label}'),
          margin: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: widget.selected ? _raised : Colors.transparent,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(
              color: _focused ? _amber : Colors.transparent,
              width: 2,
            ),
          ),
          alignment: Alignment.centerLeft,
          child: Text(
            widget.label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: widget.selected ? _warmWhite : _quietText,
              fontSize: 14,
              fontWeight: widget.selected ? FontWeight.w700 : FontWeight.w500,
            ),
          ),
        ),
      ),
    ),
  );
}

class _CategoryPane extends StatelessWidget {
  const _CategoryPane({
    required this.categories,
    required this.selected,
    required this.controller,
    required this.onNodeMounted,
    required this.onNodeUnmounted,
    required this.onChoose,
    required this.onOpenRail,
    required this.onRight,
    required this.onFocusIndex,
    required this.rowExtent,
    required this.onUpFromFirst,
  });

  final List<BrowseCategorySummary> categories;
  final BrowseCategorySelection selected;
  final ScrollController controller;
  final void Function(int index, FocusNode node) onNodeMounted;
  final void Function(int index, FocusNode node) onNodeUnmounted;
  final ValueChanged<BrowseCategorySummary> onChoose;
  final VoidCallback onOpenRail;
  final VoidCallback onRight;
  final ValueChanged<int> onFocusIndex;
  final double rowExtent;
  final VoidCallback? onUpFromFirst;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const Padding(
        padding: EdgeInsets.fromLTRB(12, 0, 12, 8),
        child: Text(
          'Categories',
          style: TextStyle(
            color: _quietText,
            fontSize: 12,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.3,
          ),
        ),
      ),
      Expanded(
        child: _BottomFade(
          child: ListView.builder(
            controller: controller,
            padding: const EdgeInsets.only(bottom: 48),
            itemCount: categories.length,
            itemExtent: rowExtent,
            itemBuilder: (context, index) => _CategoryRow(
              key: ValueKey(
                'browse-category-${categories[index].selection.kind.name}-${categories[index].selection.sourceGroupId ?? 'none'}',
              ),
              index: index,
              category: categories[index],
              selected: _sameCategory(categories[index].selection, selected),
              onNodeMounted: onNodeMounted,
              onNodeUnmounted: onNodeUnmounted,
              onLeft: onOpenRail,
              onRight: onRight,
              onChoose: () => onChoose(categories[index]),
              onUp: index == 0 ? onUpFromFirst : () => onFocusIndex(index - 1),
              onDown: index + 1 == categories.length
                  ? null
                  : () => onFocusIndex(index + 1),
            ),
          ),
        ),
      ),
    ],
  );
}

class _CategoryOverlay extends StatelessWidget {
  const _CategoryOverlay({
    required this.categories,
    required this.selected,
    required this.controller,
    required this.onNodeMounted,
    required this.onNodeUnmounted,
    required this.onChoose,
    required this.onDismiss,
    required this.onFocusIndex,
    required this.rowExtent,
  });

  final List<BrowseCategorySummary> categories;
  final BrowseCategorySelection selected;
  final ScrollController controller;
  final void Function(int index, FocusNode node) onNodeMounted;
  final void Function(int index, FocusNode node) onNodeUnmounted;
  final ValueChanged<BrowseCategorySummary> onChoose;
  final VoidCallback onDismiss;
  final ValueChanged<int> onFocusIndex;
  final double rowExtent;

  @override
  Widget build(BuildContext context) => Material(
    key: const ValueKey('browse-category-overlay'),
    color: _graphite.withValues(alpha: .98),
    child: SafeArea(
      left: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(32, 22, 32, 32),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: _surface,
            border: Border.all(color: _line),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Focus(
            onKeyEvent: (_, event) {
              if (event is KeyDownEvent &&
                  (event.logicalKey == LogicalKeyboardKey.escape ||
                      event.logicalKey == LogicalKeyboardKey.browserBack)) {
                onDismiss();
                return KeyEventResult.handled;
              }
              return KeyEventResult.ignored;
            },
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(18, 15, 12, 13),
                  child: Row(
                    children: [
                      const Expanded(
                        child: Text(
                          'Categories',
                          style: TextStyle(
                            color: _warmWhite,
                            fontSize: 18,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      IconButton(
                        tooltip: 'Close categories',
                        onPressed: onDismiss,
                        style: ButtonStyle(side: focusEdge()),
                        icon: const Icon(Icons.close, color: _warmWhite),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1, color: _line),
                Expanded(
                  child: ListView.builder(
                    controller: controller,
                    itemCount: categories.length,
                    itemExtent: rowExtent,
                    itemBuilder: (context, index) => _CategoryRow(
                      key: ValueKey(
                        'browse-overlay-category-${categories[index].selection.kind.name}-${categories[index].selection.sourceGroupId ?? 'none'}',
                      ),
                      index: index,
                      category: categories[index],
                      selected: _sameCategory(
                        categories[index].selection,
                        selected,
                      ),
                      onNodeMounted: onNodeMounted,
                      onNodeUnmounted: onNodeUnmounted,
                      onLeft: onDismiss,
                      onRight: onDismiss,
                      onChoose: () => onChoose(categories[index]),
                      onUp: index == 0 ? null : () => onFocusIndex(index - 1),
                      onDown: index + 1 == categories.length
                          ? null
                          : () => onFocusIndex(index + 1),
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

class _CategoryRow extends StatefulWidget {
  const _CategoryRow({
    super.key,
    required this.index,
    required this.category,
    required this.selected,
    required this.onNodeMounted,
    required this.onNodeUnmounted,
    required this.onLeft,
    required this.onRight,
    required this.onChoose,
    this.onUp,
    this.onDown,
  });

  final int index;
  final BrowseCategorySummary category;
  final bool selected;
  final void Function(int index, FocusNode node) onNodeMounted;
  final void Function(int index, FocusNode node) onNodeUnmounted;
  final VoidCallback onLeft;
  final VoidCallback onRight;
  final VoidCallback onChoose;
  final VoidCallback? onUp;
  final VoidCallback? onDown;

  @override
  State<_CategoryRow> createState() => _CategoryRowState();
}

class _CategoryRowState extends State<_CategoryRow> {
  bool _focused = false;
  late final FocusNode _focusNode;

  @override
  void initState() {
    super.initState();
    _focusNode = FocusNode(debugLabel: 'browse category ${widget.index}');
    widget.onNodeMounted(widget.index, _focusNode);
  }

  @override
  void didUpdateWidget(covariant _CategoryRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.index != widget.index) {
      oldWidget.onNodeUnmounted(oldWidget.index, _focusNode);
      widget.onNodeMounted(widget.index, _focusNode);
    }
  }

  @override
  void dispose() {
    widget.onNodeUnmounted(widget.index, _focusNode);
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Focus(
    focusNode: _focusNode,
    onFocusChange: (focused) => setState(() => _focused = focused),
    onKeyEvent: (_, event) {
      if (event is! KeyDownEvent) return KeyEventResult.ignored;
      switch (event.logicalKey) {
        case LogicalKeyboardKey.arrowLeft:
          widget.onLeft();
          return KeyEventResult.handled;
        case LogicalKeyboardKey.arrowRight:
          widget.onRight();
          return KeyEventResult.handled;
        case LogicalKeyboardKey.arrowUp:
          widget.onUp?.call();
          return KeyEventResult.handled;
        case LogicalKeyboardKey.arrowDown:
          widget.onDown?.call();
          return KeyEventResult.handled;
        case LogicalKeyboardKey.enter:
        case LogicalKeyboardKey.select:
          widget.onChoose();
          return KeyEventResult.handled;
        default:
          return KeyEventResult.ignored;
      }
    },
    child: Semantics(
      button: true,
      selected: widget.selected,
      label:
          '${widget.category.name}, ${_formatCount(widget.category.itemCount)} items',
      child: GestureDetector(
        onTap: () {
          _focusNode.requestFocus();
          widget.onChoose();
        },
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          margin: const EdgeInsets.symmetric(vertical: 2),
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            // Focus fills the pill solid amber: the glow ring would show
            // through the selected pill's translucent fill.
            color: _focused
                ? Cinema.amber
                : widget.selected
                ? Cinema.glass
                : const Color(0x00000000),
            borderRadius: BorderRadius.circular(18),
            boxShadow: _focused ? [Cinema.focusGlow.last] : const [],
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  widget.category.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: _focused
                        ? Cinema.amberInk
                        : widget.selected
                        ? Cinema.amber
                        : Cinema.quiet,
                    fontSize: 14,
                    fontWeight: widget.selected
                        ? FontWeight.w700
                        : FontWeight.w600,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                _formatCount(widget.category.itemCount),
                style: TextStyle(
                  color: _focused
                      ? Cinema.amberInk
                      : widget.selected
                      ? Cinema.amber
                      : _quietText,
                  fontSize: 12.5,
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

class _CatalogRow extends StatefulWidget {
  const _CatalogRow({
    super.key,
    required this.item,
    required this.kind,
    required this.initialFocusNode,
    required this.autofocus,
    required this.artworkLoader,
    required this.onNodeMounted,
    required this.onNodeUnmounted,
    required this.onFocused,
    required this.onLeft,
    required this.onUp,
    required this.onDown,
    required this.onActivate,
    this.onRight,
    this.poster = false,
    this.onOrganize,
    this.sourceName,
    this.nowNext,
    this.nowUtc,
  });
  final BrowseCatalogItem item;
  final SourceMediaKind kind;
  final FocusNode? initialFocusNode;
  final bool autofocus;
  final ArtworkProvider? artworkLoader;
  final void Function(String id, FocusNode node) onNodeMounted;
  final void Function(String id, FocusNode node) onNodeUnmounted;
  final ValueChanged<FocusNode> onFocused;
  final VoidCallback onLeft;
  final VoidCallback? onUp;
  final VoidCallback onDown;
  final VoidCallback onActivate;

  /// Grid tiles move right. Without it, Right opens Organize on a list row.
  final VoidCallback? onRight;

  /// Movies and series show as a poster tile instead of a list row.
  final bool poster;
  final VoidCallback? onOrganize;
  final String? sourceName;
  final EpgNowNext? nowNext;
  final DateTime? nowUtc;
  @override
  State<_CatalogRow> createState() => _CatalogRowState();
}

class _CatalogRowState extends State<_CatalogRow> {
  bool _focused = false;
  bool _hovered = false;
  late final FocusNode _ownedFocus;

  FocusNode get _focusNode => widget.initialFocusNode ?? _ownedFocus;

  @override
  void initState() {
    super.initState();
    _ownedFocus = FocusNode(
      debugLabel: 'browse ${widget.kind.name} ${widget.item.id}',
    );
    widget.onNodeMounted(widget.item.id, _focusNode);
  }

  @override
  void didUpdateWidget(covariant _CatalogRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.item.id != widget.item.id ||
        oldWidget.initialFocusNode != widget.initialFocusNode) {
      oldWidget.onNodeUnmounted(
        oldWidget.item.id,
        oldWidget.initialFocusNode ?? _ownedFocus,
      );
      widget.onNodeMounted(widget.item.id, _focusNode);
    }
  }

  @override
  void dispose() {
    widget.onNodeUnmounted(widget.item.id, _focusNode);
    _ownedFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Focus(
    focusNode: _focusNode,
    autofocus: widget.autofocus,
    onFocusChange: (focused) {
      setState(() => _focused = focused);
      if (focused) widget.onFocused(_focusNode);
    },
    onKeyEvent: (_, event) {
      if (event is! KeyDownEvent) return KeyEventResult.ignored;
      switch (event.logicalKey) {
        case LogicalKeyboardKey.arrowLeft:
          widget.onLeft();
          return KeyEventResult.handled;
        case LogicalKeyboardKey.arrowUp:
          widget.onUp?.call();
          return KeyEventResult.handled;
        case LogicalKeyboardKey.arrowDown:
          widget.onDown();
          return KeyEventResult.handled;
        case LogicalKeyboardKey.arrowRight when widget.onRight != null:
          widget.onRight!();
          return KeyEventResult.handled;
        case LogicalKeyboardKey.arrowRight:
        case LogicalKeyboardKey.contextMenu:
          widget.onOrganize?.call();
          return widget.onOrganize == null
              ? KeyEventResult.ignored
              : KeyEventResult.handled;
        case LogicalKeyboardKey.enter:
        case LogicalKeyboardKey.select:
          widget.onActivate();
          return KeyEventResult.handled;
        default:
          return KeyEventResult.ignored;
      }
    },
    child: Semantics(
      button: true,
      label: [
        widget.item.title,
        widget.kind.label,
        if (widget.sourceName != null) widget.sourceName!,
        if (widget.nowNext?.current != null)
          'Now ${widget.nowNext!.current!.title}',
        if (widget.nowNext?.next != null) 'Next ${widget.nowNext!.next!.title}',
      ].join(', '),
      customSemanticsActions: widget.onOrganize == null
          ? null
          : {
              const CustomSemanticsAction(label: 'Organize item'):
                  widget.onOrganize!,
            },
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          onTap: () {
            _focusNode.requestFocus();
            widget.onActivate();
          },
          child: widget.poster ? _poster(context) : _row(context),
        ),
      ),
    ),
  );

  void _organize() {
    _focusNode.requestFocus();
    widget.onOrganize!();
  }

  Widget _row(BuildContext context) {
    final guide = _guideLine(context);
    return AnimatedContainer(
      key: ValueKey('browse-item-${widget.item.id}'),
      duration: const Duration(milliseconds: 120),
      margin: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
      padding: const EdgeInsets.fromLTRB(6, 0, 10, 0),
      decoration: BoxDecoration(
        // Opaque when focused so the ring stays a ring.
        color: _focused
            ? _raised
            : _hovered
            ? Cinema.glass
            : const Color(0x00000000),
        borderRadius: BorderRadius.circular(14),
        boxShadow: _focused ? Cinema.focusGlow : const [],
      ),
      child: Row(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: SourceArtwork(
              key: ValueKey('browse-artwork-${widget.item.id}'),
              locator: widget.item.artworkLocator,
              kind: widget.item.kind,
              loader: widget.artworkLoader,
              focused: _focused,
              loadWhenVisible: true,
              width: 88,
              height: 50,
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.item.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: _warmWhite,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (guide != null) ...[const SizedBox(height: 4), guide],
              ],
            ),
          ),
          if (widget.sourceName != null) ...[
            const SizedBox(width: 12),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 170),
              child: Text(
                widget.sourceName!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: _quietText, fontSize: 13),
              ),
            ),
          ],
          if (widget.onOrganize != null) ...[
            const SizedBox(width: 8),
            Visibility(
              visible: _focused || _hovered,
              maintainSize: true,
              maintainAnimation: true,
              maintainState: true,
              child: _OrganizeButton(onPressed: _organize),
            ),
          ],
        ],
      ),
    );
  }

  /// The current program with its progress and times, or the next one.
  /// Channels without guide data show no line at all.
  Widget? _guideLine(BuildContext context) {
    final nowNext = widget.nowNext;
    if (nowNext == null) return null;
    final localizations = MaterialLocalizations.of(context);
    String time(DateTime value) =>
        localizations.formatTimeOfDay(TimeOfDay.fromDateTime(value.toLocal()));
    const quiet = TextStyle(color: Cinema.quiet, fontSize: 12.5);
    final current = nowNext.current;
    if (current != null) {
      final span = current.endUtc.difference(current.startUtc).inSeconds;
      final now = widget.nowUtc;
      final progress = now == null || span <= 0
          ? null
          : (now.difference(current.startUtc).inSeconds / span).clamp(0.0, 1.0);
      return Row(
        key: ValueKey('browse-now-next-${widget.item.id}'),
        children: [
          Flexible(
            child: Text(
              current.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: quiet,
            ),
          ),
          if (progress != null) ...[
            const SizedBox(width: 10),
            SizedBox(
              width: 56,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(2),
                child: LinearProgressIndicator(
                  value: progress,
                  minHeight: 3,
                  backgroundColor: const Color(0x2EF5F1E8),
                  color: Cinema.amber,
                ),
              ),
            ),
          ],
          const SizedBox(width: 10),
          Text(
            '${time(current.startUtc)} – ${time(current.endUtc)}',
            maxLines: 1,
            style: const TextStyle(color: _quietText, fontSize: 12.5),
          ),
        ],
      );
    }
    final next = nowNext.next;
    if (next == null) return null;
    return Text(
      'Next · ${time(next.startUtc)} · ${next.title}',
      key: ValueKey('browse-now-next-${widget.item.id}'),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: quiet,
    );
  }

  Widget _poster(BuildContext context) {
    final motion = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : const Duration(milliseconds: 140);
    return Padding(
      key: ValueKey('browse-item-${widget.item.id}'),
      padding: const EdgeInsets.only(bottom: _posterRowGap),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: AnimatedScale(
              scale: _focused ? 1.04 : 1,
              duration: motion,
              curve: Curves.easeOutCubic,
              child: AnimatedContainer(
                duration: motion,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  boxShadow: _focused ? Cinema.focusGlow : const [],
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      SourceArtwork(
                        key: ValueKey('browse-artwork-${widget.item.id}'),
                        locator: widget.item.artworkLocator,
                        kind: widget.item.kind,
                        loader: widget.artworkLoader,
                        focused: _focused,
                        loadWhenVisible: true,
                        width: double.infinity,
                        height: double.infinity,
                        placeholder: Padding(
                          padding: const EdgeInsets.all(10),
                          child: Align(
                            alignment: Alignment.bottomLeft,
                            child: Text(
                              widget.item.title,
                              maxLines: 4,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Cinema.quiet,
                                fontFamily: Cinema.display,
                                fontSize: 14,
                                fontWeight: FontWeight.w800,
                                height: 1.05,
                              ),
                            ),
                          ),
                        ),
                      ),
                      if (widget.onOrganize != null && (_focused || _hovered))
                        Positioned(
                          top: 7,
                          right: 7,
                          child: _OrganizeButton(
                            size: 30,
                            onPressed: _organize,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            widget.item.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: _focused ? _warmWhite : Cinema.quiet,
              fontSize: 12.5,
              fontWeight: FontWeight.w600,
            ),
          ),
          if (widget.sourceName != null)
            Text(
              widget.sourceName!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: _quietText, fontSize: 11.5),
            ),
        ],
      ),
    );
  }
}

class _DirectorySkeleton extends StatelessWidget {
  const _DirectorySkeleton({required this.narrow, this.unified = false});

  final bool narrow;
  final bool unified;
  @override
  Widget build(BuildContext context) => narrow || unified
      ? const _SkeletonPanel()
      : const Row(
          children: [
            SizedBox(width: 228, child: _SkeletonPanel()),
            SizedBox(width: 20),
            Expanded(child: _SkeletonPanel()),
          ],
        );
}

class _ScopeLoading extends StatelessWidget {
  const _ScopeLoading({required this.kind});

  final SourceMediaKind kind;

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: _graphite,
    child: SafeArea(
      left: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(32, 22, 32, 32),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        kind.label,
                        style: const TextStyle(
                          color: _warmWhite,
                          fontSize: 31,
                          fontWeight: FontWeight.w700,
                          letterSpacing: -0.7,
                        ),
                      ),
                      const SizedBox(height: 5),
                      const Text(
                        'Loading local catalog',
                        style: TextStyle(color: _quietText, fontSize: 14),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 16),
                Semantics(
                  liveRegion: true,
                  label: 'Loading sources',
                  child: Container(
                    key: const ValueKey('catalog-scope-loading'),
                    width: 184,
                    height: 44,
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    alignment: Alignment.centerLeft,
                    decoration: BoxDecoration(
                      color: _surface,
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: _line),
                    ),
                    child: const Text(
                      'Loading sources…',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: _quietText, fontSize: 14),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 22),
            const Expanded(
              child: _DirectorySkeleton(narrow: true, unified: true),
            ),
          ],
        ),
      ),
    ),
  );
}

class _SkeletonPanel extends StatelessWidget {
  const _SkeletonPanel();
  @override
  Widget build(BuildContext context) => DecoratedBox(
    key: const ValueKey('browse-skeleton-panel'),
    decoration: BoxDecoration(
      color: _surface,
      border: Border.fromBorderSide(const BorderSide(color: _line)),
      borderRadius: BorderRadius.circular(8),
    ),
    child: Semantics(
      label: 'Loading catalog items',
      child: ListView.builder(
        physics: const NeverScrollableScrollPhysics(),
        itemExtent: 60,
        itemCount: 7,
        itemBuilder: (_, _) => const _ItemSkeleton(),
      ),
    ),
  );
}

class _ItemSkeleton extends StatelessWidget {
  const _ItemSkeleton();
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
    child: Row(
      children: [
        Container(width: 50, height: 36, color: _raised),
        const SizedBox(width: 12),
        Expanded(child: Container(height: 12, color: _raised)),
      ],
    ),
  );
}

class _PageErrorFooter extends StatelessWidget {
  const _PageErrorFooter({
    required this.onRetry,
    this.label = 'Could not load more items.',
  });

  final VoidCallback onRetry;
  final String label;

  @override
  Widget build(BuildContext context) => Container(
    key: const ValueKey('browse-next-page-error'),
    padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
    decoration: const BoxDecoration(
      border: Border(top: BorderSide(color: _line)),
    ),
    child: Row(
      children: [
        Expanded(
          child: Text(
            label,
            style: const TextStyle(color: _quietText, fontSize: 13),
          ),
        ),
        TextButton(
          onPressed: onRetry,
          style: ButtonStyle(side: focusEdge()),
          child: const Text('Retry'),
        ),
      ],
    ),
  );
}

class _EmptyCategory extends StatelessWidget {
  const _EmptyCategory({
    required this.kind,
    required this.focusNode,
    required this.onFocused,
    required this.onLeft,
    required this.onReturnToAll,
  });
  final SourceMediaKind kind;
  final FocusNode focusNode;
  final ValueChanged<FocusNode> onFocused;
  final VoidCallback onLeft;
  final VoidCallback onReturnToAll;
  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: _surface,
      border: Border.all(color: _line),
      borderRadius: BorderRadius.circular(8),
    ),
    child: Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text(
            'Nothing here yet',
            style: TextStyle(
              color: _warmWhite,
              fontSize: 18,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'This provider category has no available items.',
            style: TextStyle(color: _quietText),
          ),
          const SizedBox(height: 18),
          _DirectoryButton(
            label: 'View all ${kind.label.toLowerCase()}',
            focusNode: focusNode,
            onFocused: onFocused,
            onLeft: onLeft,
            onPressed: onReturnToAll,
          ),
        ],
      ),
    ),
  );
}

class _EmptyUnifiedCatalog extends StatelessWidget {
  const _EmptyUnifiedCatalog({
    required this.kind,
    required this.focusNode,
    required this.onFocused,
    required this.onLeft,
    required this.onChangeScope,
  });

  final SourceMediaKind kind;
  final FocusNode focusNode;
  final ValueChanged<FocusNode> onFocused;
  final VoidCallback onLeft;
  final VoidCallback onChangeScope;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: _surface,
      border: Border.all(color: _line),
      borderRadius: BorderRadius.circular(8),
    ),
    child: Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'No available ${kind.label.toLowerCase()}',
            style: const TextStyle(
              color: _warmWhite,
              fontSize: 18,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'Choose a source to check its provider categories.',
            textAlign: TextAlign.center,
            style: TextStyle(color: _quietText),
          ),
          const SizedBox(height: 18),
          _DirectoryButton(
            label: 'Change source',
            focusNode: focusNode,
            onFocused: onFocused,
            onLeft: onLeft,
            onPressed: onChangeScope,
          ),
        ],
      ),
    ),
  );
}

class _BrowseMessage extends StatelessWidget {
  const _BrowseMessage({
    required this.title,
    required this.message,
    required this.actionLabel,
    required this.focusNode,
    required this.onFocused,
    required this.onLeft,
    required this.onPressed,
    this.primaryAction = false,
  });
  final String title;
  final String message;
  final String actionLabel;
  final FocusNode focusNode;
  final ValueChanged<FocusNode> onFocused;
  final VoidCallback onLeft;
  final VoidCallback onPressed;
  final bool primaryAction;
  @override
  Widget build(BuildContext context) => ColoredBox(
    color: _graphite,
    child: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: Padding(
          padding: const EdgeInsets.all(40),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(
                  color: _warmWhite,
                  fontSize: 30,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                message,
                style: const TextStyle(
                  color: _quietText,
                  fontSize: 16,
                  height: 1.45,
                ),
              ),
              const SizedBox(height: 24),
              _DirectoryButton(
                label: actionLabel,
                primary: primaryAction,
                focusNode: focusNode,
                onPressed: onPressed,
                onFocused: onFocused,
                onLeft: onLeft,
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

class _DirectoryButton extends StatefulWidget {
  const _DirectoryButton({
    required this.label,
    required this.focusNode,
    required this.onPressed,
    this.onFocused,
    this.onLeft,
    this.primary = false,
  });
  final String label;
  final FocusNode focusNode;
  final VoidCallback onPressed;
  final ValueChanged<FocusNode>? onFocused;
  final VoidCallback? onLeft;
  final bool primary;
  @override
  State<_DirectoryButton> createState() => _DirectoryButtonState();
}

class _DirectoryButtonState extends State<_DirectoryButton> {
  bool _focused = false;
  @override
  Widget build(BuildContext context) => Focus(
    focusNode: widget.focusNode,
    onFocusChange: (focused) {
      setState(() => _focused = focused);
      if (focused) widget.onFocused?.call(widget.focusNode);
    },
    onKeyEvent: (_, event) {
      if (event is KeyDownEvent) {
        if (event.logicalKey == LogicalKeyboardKey.arrowLeft &&
            widget.onLeft != null) {
          widget.onLeft!();
          return KeyEventResult.handled;
        }
        if (event.logicalKey == LogicalKeyboardKey.enter ||
            event.logicalKey == LogicalKeyboardKey.select) {
          widget.onPressed();
          return KeyEventResult.handled;
        }
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
          key: ValueKey('browse-action-${widget.label}'),
          height: 44,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: widget.primary ? _amber : _surface,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(
              color: _focused
                  ? (widget.primary ? _warmWhite : _amber)
                  : (widget.primary ? _amber : _line),
              width: _focused ? 2 : 1,
            ),
          ),
          child: Text(
            widget.label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: widget.primary ? const Color(0xFF17120A) : _warmWhite,
              fontSize: 14,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ),
    ),
  );
}

bool _sameCategory(BrowseCategorySelection a, BrowseCategorySelection b) =>
    a.kind == b.kind && a.sourceGroupId == b.sourceGroupId;

String _formatCount(int value) => value.toString().replaceAllMapped(
  RegExp(r'(?<!^)(?=(?:\d{3})+$)'),
  (_) => ',',
);
