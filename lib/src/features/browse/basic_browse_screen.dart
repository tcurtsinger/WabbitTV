import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

import '../sources/credential_store.dart';
import '../sources/source_catalog_database.dart';
import '../sources/source_models.dart';
import 'minimal_continuations.dart';
import 'playback_handoff.dart';
import 'series_info_loader.dart';

const _graphite = Color(0xFF111212);
const _surface = Color(0xFF191A1A);
const _raised = Color(0xFF222321);
const _line = Color(0xFF343534);
const _warmWhite = Color(0xFFF4F0E7);
const _quietText = Color(0xFFAAA8A2);
const _amber = Color(0xFFFFB347);

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

class DatabaseBasicBrowseData implements BasicBrowseData {
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
}

/// Keeps only practical browse position while the shell changes destinations.
class BasicBrowseSession {
  final Map<SourceMediaKind, _BrowseBookmark> _bookmarks = {};

  _BrowseBookmark _bookmarkFor(SourceMediaKind kind) =>
      _bookmarks.putIfAbsent(kind, _BrowseBookmark.new);
}

class _BrowseBookmark {
  BrowseCategorySelection selection = const BrowseCategorySelection.all();
  String? focusedItemId;
  double scrollOffset = 0;
  String? sourceId;
  List<BrowseCatalogItem> items = const [];
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
    this.onOpenSourceSetup,
    this.onItemActivated,
    this.onPlaybackHandoff,
    this.credentialStore,
    this.seriesInfoLoader,
  });

  final SourceMediaKind kind;
  final PersistedSource? source;
  final FocusNode initialFocus;
  final ValueChanged<FocusNode> onContentFocus;
  final VoidCallback onOpenRail;
  final BasicBrowseSession session;
  final BasicBrowseData? data;
  final VoidCallback? onOpenSourceSetup;

  /// Legacy browse notification kept only for the existing shell tests.
  /// New playback work must use [onPlaybackHandoff].
  final BrowseItemActivated? onItemActivated;
  final ValueChanged<PlaybackHandoff>? onPlaybackHandoff;
  final CredentialStore? credentialStore;
  final SeriesInfoLoader? seriesInfoLoader;

  @override
  State<BasicBrowseScreen> createState() => _BasicBrowseScreenState();
}

class _BasicBrowseScreenState extends State<BasicBrowseScreen> {
  static const _pageSize = 100;
  final FocusNode _categoryLauncherFocus = FocusNode(
    debugLabel: 'browse categories launcher',
  );
  final ScrollController _itemsScroll = ScrollController();
  final ScrollController _categoriesScroll = ScrollController();
  final Map<int, FocusNode> _categoryNodes = {};
  final Map<String, FocusNode> _itemNodes = {};
  List<BrowseCategorySummary>? _categories;
  List<BrowseCatalogItem> _items = const [];
  BrowseCursor? _nextCursor;
  Object? _error;
  bool _loading = false;
  bool _loadingMore = false;
  bool _pageError = false;
  bool _restoringCachedFocus = false;
  bool _categoryOverlay = false;
  int _request = 0;
  int _seriesRequest = 0;
  _BrowseContinuation? _continuation;
  late BasicBrowseData _data;
  late SeriesInfoLoader _seriesInfoLoader;
  late _BrowseBookmark _bookmark;

  @override
  void initState() {
    super.initState();
    _data =
        widget.data ?? const DatabaseBasicBrowseData(SourceCatalogDatabase());
    _seriesInfoLoader =
        widget.seriesInfoLoader ??
        XtreamSeriesInfoLoader(credentialStore: widget.credentialStore);
    _bookmark = widget.session._bookmarkFor(widget.kind);
    _restoringCachedFocus =
        _bookmark.items.isNotEmpty && _bookmark.focusedItemId != null;
    _itemsScroll.addListener(_maybeLoadMore);
    _loadCatalog(resetSelection: false);
  }

  @override
  void didUpdateWidget(covariant BasicBrowseScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.kind != widget.kind ||
        oldWidget.source?.id != widget.source?.id) {
      _cancelSeriesRequest();
      _continuation = null;
      _rememberPosition();
      _bookmark = widget.session._bookmarkFor(widget.kind);
      _items = const [];
      _categories = null;
      _nextCursor = null;
      _error = null;
      _loadCatalog(resetSelection: false);
    }
  }

  @override
  void dispose() {
    _cancelSeriesRequest();
    _rememberPosition();
    _itemsScroll
      ..removeListener(_maybeLoadMore)
      ..dispose();
    _categoriesScroll.dispose();
    _categoryLauncherFocus.dispose();
    for (final node in _categoryNodes.values) {
      node.dispose();
    }
    for (final node in _itemNodes.values) {
      node.dispose();
    }
    super.dispose();
  }

  void _rememberPosition() {
    if (_itemsScroll.hasClients) {
      _bookmark.scrollOffset = _itemsScroll.offset;
    }
  }

  Future<void> _loadCatalog({required bool resetSelection}) async {
    final source = widget.source;
    if (source == null) {
      if (mounted) {
        setState(() {
          _categories = const [];
          _items = const [];
          _error = null;
          _loading = false;
        });
      }
      return;
    }
    final request = ++_request;
    setState(() {
      _loading = true;
      _loadingMore = false;
      _pageError = false;
      _error = null;
    });
    try {
      final categories = await _data.browseCategories(
        sourceId: source.id,
        kind: widget.kind,
      );
      if (!mounted || request != _request) return;
      if (_bookmark.sourceId != source.id) {
        _bookmark
          ..sourceId = source.id
          ..items = const []
          ..nextCursor = null
          ..focusedItemId = null
          ..scrollOffset = 0
          ..selection = const BrowseCategorySelection.all();
      }
      final selected = _usableSelection(categories, _bookmark.selection);
      if (resetSelection || selected == null) {
        _bookmark
          ..selection = const BrowseCategorySelection.all()
          ..items = const []
          ..nextCursor = null
          ..scrollOffset = 0
          ..focusedItemId = null;
      } else {
        _bookmark.selection = selected.selection;
      }
      if (_bookmark.items.isNotEmpty) {
        setState(() {
          _categories = categories;
          _items = _bookmark.items;
          _nextCursor = _bookmark.nextCursor;
          _loading = false;
        });
        _restoringCachedFocus = _bookmark.focusedItemId != null;
        _restoreListPosition(restoreFocus: true);
      } else {
        setState(() => _categories = categories);
        await _loadFirstPage(request);
      }
    } catch (_) {
      if (!mounted || request != _request) return;
      setState(() {
        _loading = false;
        _error = Object();
      });
    }
  }

  BrowseCategorySummary? _usableSelection(
    List<BrowseCategorySummary> categories,
    BrowseCategorySelection selection,
  ) {
    for (final category in categories) {
      if (_sameSelection(category.selection, selection)) return category;
    }
    return null;
  }

  Future<void> _loadFirstPage(int request) async {
    final source = widget.source;
    if (source == null) return;
    try {
      final page = await _data.browsePage(
        sourceId: source.id,
        kind: widget.kind,
        selection: _bookmark.selection,
        limit: _pageSize,
      );
      if (!mounted || request != _request) return;
      setState(() {
        _items = page.items;
        _nextCursor = page.nextCursor;
        _loading = false;
        _pageError = false;
      });
      _bookmark
        ..items = page.items
        ..nextCursor = page.nextCursor;
      _restoreListPosition();
    } catch (_) {
      if (!mounted || request != _request) return;
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
      if (desired > 0) _itemsScroll.jumpTo(desired);
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
    final node = _itemFocus(_items[index], index);
    node.requestFocus();
    if (node.context != null) {
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

  Future<void> _loadMore() async {
    final source = widget.source;
    final cursor = _nextCursor;
    if (source == null || cursor == null || _loadingMore) return;
    final request = _request;
    final selection = _bookmark.selection;
    setState(() {
      _loadingMore = true;
      _pageError = false;
    });
    try {
      final page = await _data.browsePage(
        sourceId: source.id,
        kind: widget.kind,
        selection: _bookmark.selection,
        cursor: cursor,
        limit: _pageSize,
      );
      if (!mounted ||
          request != _request ||
          !_sameSelection(selection, _bookmark.selection)) {
        return;
      }
      setState(() {
        _items = [..._items, ...page.items];
        _nextCursor = page.nextCursor;
        _loadingMore = false;
      });
      _bookmark
        ..items = _items
        ..nextCursor = page.nextCursor;
    } catch (_) {
      if (!mounted ||
          request != _request ||
          !_sameSelection(selection, _bookmark.selection)) {
        return;
      }
      setState(() {
        _loadingMore = false;
        _pageError = true;
      });
    }
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

  FocusNode _itemFocus(BrowseCatalogItem item, int index) {
    if (index == 0) return widget.initialFocus;
    return _itemNodes.putIfAbsent(
      item.id,
      () => FocusNode(debugLabel: 'browse ${widget.kind.name} ${item.id}'),
    );
  }

  FocusNode _categoryFocus(int index) => _categoryNodes.putIfAbsent(
    index,
    () => FocusNode(debugLabel: 'browse category $index'),
  );

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
    _focusVirtualRow(
      controller: _itemsScroll,
      index: index,
      rowExtent: 60,
      node: _itemFocus(_items[index], index),
    );
  }

  void _focusCategoryAt(int index, {required double rowExtent}) {
    final categories = _categories ?? const <BrowseCategorySummary>[];
    if (index < 0 || index >= categories.length) return;
    _focusVirtualRow(
      controller: _categoriesScroll,
      index: index,
      rowExtent: rowExtent,
      node: _categoryFocus(index),
    );
  }

  void _focusVirtualRow({
    required ScrollController controller,
    required int index,
    required double rowExtent,
    required FocusNode node,
  }) {
    void revealThenFocus() {
      if (!mounted || !controller.hasClients) return;
      final position = controller.position;
      final rowStart = index * rowExtent;
      final rowEnd = rowStart + rowExtent;
      final visibleStart = controller.offset;
      final visibleEnd = visibleStart + position.viewportDimension;
      if (rowStart >= visibleStart && rowEnd <= visibleEnd) {
        node.requestFocus();
        return;
      }
      final target = (rowStart - (position.viewportDimension - rowExtent) / 2)
          .clamp(0.0, position.maxScrollExtent);
      controller.jumpTo(target);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) node.requestFocus();
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
    final source = widget.source;
    if (source == null) return;
    final request = ++_seriesRequest;
    setState(() {
      _continuation = _SeriesBrowseContinuation(item: item, loading: true);
    });
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

  @override
  Widget build(BuildContext context) {
    final continuation = _continuation;
    if (continuation != null) return _buildContinuation(continuation);
    final source = widget.source;
    if (source == null) {
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
    if (_error != null) {
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
    if (_categories != null && _categories!.isEmpty && !_loading) {
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
                    padding: const EdgeInsets.fromLTRB(32, 22, 32, 32),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _DirectoryHeader(
                          kind: widget.kind,
                          sourceName: source.name,
                          total: source.counts[widget.kind] ?? 0,
                          narrow: narrow,
                          focusNode: _categoryLauncherFocus,
                          onOpenCategories: () {
                            setState(() => _categoryOverlay = true);
                            WidgetsBinding.instance.addPostFrameCallback((_) {
                              _focusSelectedCategory(rowExtent: 52);
                            });
                          },
                        ),
                        const SizedBox(height: 22),
                        Expanded(
                          child:
                              _categories == null || _loading && _items.isEmpty
                              ? _DirectorySkeleton(narrow: narrow)
                              : Row(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  children: [
                                    if (!narrow) ...[
                                      SizedBox(
                                        width: 228,
                                        child: _CategoryPane(
                                          categories: _categories!,
                                          selected: _bookmark.selection,
                                          nodes: _categoryFocus,
                                          controller: _categoriesScroll,
                                          onChoose: _chooseCategory,
                                          onOpenRail: widget.onOpenRail,
                                          onRight: _focusFirstItem,
                                          onFocusIndex: (index) =>
                                              _focusCategoryAt(
                                                index,
                                                rowExtent: 48,
                                              ),
                                        ),
                                      ),
                                      const SizedBox(width: 20),
                                    ],
                                    Expanded(child: _buildItems()),
                                  ],
                                ),
                        ),
                      ],
                    ),
                  ),
                  if (narrow && _categoryOverlay && _categories != null)
                    Positioned.fill(
                      child: _CategoryOverlay(
                        categories: _categories!,
                        selected: _bookmark.selection,
                        nodes: _categoryFocus,
                        controller: _categoriesScroll,
                        onChoose: _chooseCategory,
                        onDismiss: () =>
                            _dismissCategoryOverlay(toLauncher: true),
                        onFocusIndex: (index) =>
                            _focusCategoryAt(index, rowExtent: 52),
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

  Widget _buildItems() {
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
    return DecoratedBox(
      decoration: BoxDecoration(
        color: _surface,
        border: Border.all(color: _line),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 15, 18, 13),
            child: Text(
              selected?.name ?? 'All ${widget.kind.label}',
              key: const ValueKey('browse-selected-category'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: _warmWhite,
                fontSize: 18,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const Divider(height: 1, color: _line),
          Expanded(
            child: ListView.builder(
              key: ValueKey('browse-items-${widget.kind.name}'),
              controller: _itemsScroll,
              itemExtent: 60,
              scrollCacheExtent: const ScrollCacheExtent.pixels(360),
              itemCount: _items.length + (_loadingMore ? 3 : 0),
              itemBuilder: (context, index) {
                if (index >= _items.length) return const _ItemSkeleton();
                final item = _items[index];
                final itemFocus = _itemFocus(item, index);
                if (_restoringCachedFocus &&
                    item.id == _bookmark.focusedItemId) {
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (mounted) {
                      itemFocus.requestFocus();
                      _restoringCachedFocus = false;
                    }
                  });
                }
                return _CatalogRow(
                  item: item,
                  kind: widget.kind,
                  focusNode: itemFocus,
                  autofocus: index == 0 && !_restoringCachedFocus,
                  onFocused: (node) {
                    if (!_restoringCachedFocus) {
                      _bookmark.focusedItemId = item.id;
                    }
                    widget.onContentFocus(node);
                  },
                  onLeft: () {
                    _focusSelectedCategory();
                  },
                  onUp: index == 0 ? null : () => _focusItemAt(index - 1),
                  onDown: () {
                    if (index + 1 < _items.length) {
                      _focusItemAt(index + 1);
                    } else if (_nextCursor != null) {
                      unawaited(_loadMore());
                    }
                  },
                  onActivate: () => _activateItem(item),
                );
              },
            ),
          ),
          if (_pageError)
            _PageErrorFooter(onRetry: () => unawaited(_loadMore())),
        ],
      ),
    );
  }
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

class _DirectoryHeader extends StatelessWidget {
  const _DirectoryHeader({
    required this.kind,
    required this.sourceName,
    required this.total,
    required this.narrow,
    required this.focusNode,
    required this.onOpenCategories,
  });

  final SourceMediaKind kind;
  final String sourceName;
  final int total;
  final bool narrow;
  final FocusNode focusNode;
  final VoidCallback onOpenCategories;

  @override
  Widget build(BuildContext context) {
    final summary = Text(
      '${_formatCount(total)} items · $sourceName',
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: const TextStyle(color: _quietText, fontSize: 14),
    );
    return Row(
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
              summary,
            ],
          ),
        ),
        if (narrow) ...[
          const SizedBox(width: 16),
          _DirectoryButton(
            label: 'Categories',
            focusNode: focusNode,
            onPressed: onOpenCategories,
          ),
        ],
      ],
    );
  }
}

class _CategoryPane extends StatelessWidget {
  const _CategoryPane({
    required this.categories,
    required this.selected,
    required this.nodes,
    required this.controller,
    required this.onChoose,
    required this.onOpenRail,
    required this.onRight,
    required this.onFocusIndex,
  });

  final List<BrowseCategorySummary> categories;
  final BrowseCategorySelection selected;
  final FocusNode Function(int) nodes;
  final ScrollController controller;
  final ValueChanged<BrowseCategorySummary> onChoose;
  final VoidCallback onOpenRail;
  final VoidCallback onRight;
  final ValueChanged<int> onFocusIndex;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: _surface,
      border: Border.all(color: _line),
      borderRadius: BorderRadius.circular(8),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(18, 15, 18, 13),
          child: Text(
            'Categories',
            style: TextStyle(color: _warmWhite, fontWeight: FontWeight.w700),
          ),
        ),
        const Divider(height: 1, color: _line),
        Expanded(
          child: ListView.builder(
            controller: controller,
            itemCount: categories.length,
            itemExtent: 48,
            itemBuilder: (context, index) => _CategoryRow(
              category: categories[index],
              selected: _sameCategory(categories[index].selection, selected),
              focusNode: nodes(index),
              onLeft: onOpenRail,
              onRight: onRight,
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
  );
}

class _CategoryOverlay extends StatelessWidget {
  const _CategoryOverlay({
    required this.categories,
    required this.selected,
    required this.nodes,
    required this.controller,
    required this.onChoose,
    required this.onDismiss,
    required this.onFocusIndex,
  });

  final List<BrowseCategorySummary> categories;
  final BrowseCategorySelection selected;
  final FocusNode Function(int) nodes;
  final ScrollController controller;
  final ValueChanged<BrowseCategorySummary> onChoose;
  final VoidCallback onDismiss;
  final ValueChanged<int> onFocusIndex;

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
                    itemExtent: 52,
                    itemBuilder: (context, index) => _CategoryRow(
                      category: categories[index],
                      selected: _sameCategory(
                        categories[index].selection,
                        selected,
                      ),
                      focusNode: nodes(index),
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
    required this.category,
    required this.selected,
    required this.focusNode,
    required this.onLeft,
    required this.onRight,
    required this.onChoose,
    this.onUp,
    this.onDown,
  });

  final BrowseCategorySummary category;
  final bool selected;
  final FocusNode focusNode;
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

  @override
  Widget build(BuildContext context) => Focus(
    focusNode: widget.focusNode,
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
          widget.focusNode.requestFocus();
          widget.onChoose();
        },
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            color: widget.selected ? _raised : Colors.transparent,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(
              color: _focused ? _amber : Colors.transparent,
              width: 2,
            ),
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  widget.category.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: widget.selected ? _warmWhite : _quietText,
                    fontSize: 15,
                    fontWeight: widget.selected
                        ? FontWeight.w700
                        : FontWeight.w500,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                _formatCount(widget.category.itemCount),
                style: const TextStyle(color: _quietText, fontSize: 13),
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
    required this.item,
    required this.kind,
    required this.focusNode,
    required this.autofocus,
    required this.onFocused,
    required this.onLeft,
    required this.onUp,
    required this.onDown,
    required this.onActivate,
  });
  final BrowseCatalogItem item;
  final SourceMediaKind kind;
  final FocusNode focusNode;
  final bool autofocus;
  final ValueChanged<FocusNode> onFocused;
  final VoidCallback onLeft;
  final VoidCallback? onUp;
  final VoidCallback onDown;
  final VoidCallback onActivate;
  @override
  State<_CatalogRow> createState() => _CatalogRowState();
}

class _CatalogRowState extends State<_CatalogRow> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) => Focus(
    focusNode: widget.focusNode,
    autofocus: widget.autofocus,
    onFocusChange: (focused) {
      setState(() => _focused = focused);
      if (focused) widget.onFocused(widget.focusNode);
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
      label: '${widget.item.title}, ${widget.kind.label}',
      child: GestureDetector(
        onTap: () {
          widget.focusNode.requestFocus();
          widget.onActivate();
        },
        child: Container(
          key: ValueKey('browse-item-${widget.item.id}'),
          margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            color: _focused ? _raised : Colors.transparent,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(
              color: _focused ? _amber : Colors.transparent,
              width: 2,
            ),
          ),
          child: Row(
            children: [
              _Artwork(item: widget.item),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  widget.item.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: _warmWhite,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              if (widget.kind != SourceMediaKind.live) ...[
                const SizedBox(width: 12),
                const Icon(Icons.chevron_right, size: 19, color: _quietText),
              ],
            ],
          ),
        ),
      ),
    ),
  );
}

class _Artwork extends StatelessWidget {
  const _Artwork({required this.item});

  final BrowseCatalogItem item;

  @override
  Widget build(BuildContext context) {
    final icon = switch (item.kind) {
      SourceMediaKind.live => Icons.live_tv_outlined,
      SourceMediaKind.movies => Icons.movie_outlined,
      SourceMediaKind.series => Icons.tv_outlined,
    };
    return Container(
      key: ValueKey('browse-artwork-${item.id}'),
      width: 50,
      height: 36,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: _raised,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: _line),
      ),
      child: Icon(icon, size: 18, color: _quietText),
    );
  }
}

class _DirectorySkeleton extends StatelessWidget {
  const _DirectorySkeleton({required this.narrow});

  final bool narrow;
  @override
  Widget build(BuildContext context) => narrow
      ? const _SkeletonPanel()
      : const Row(
          children: [
            SizedBox(width: 228, child: _SkeletonPanel()),
            SizedBox(width: 20),
            Expanded(child: _SkeletonPanel()),
          ],
        );
}

class _SkeletonPanel extends StatelessWidget {
  const _SkeletonPanel();
  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: _surface,
      border: Border.fromBorderSide(const BorderSide(color: _line)),
      borderRadius: BorderRadius.circular(8),
    ),
    child: Column(
      children: [for (var i = 0; i < 7; i++) const _ItemSkeleton()],
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
  const _PageErrorFooter({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Container(
    key: const ValueKey('browse-next-page-error'),
    padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
    decoration: const BoxDecoration(
      border: Border(top: BorderSide(color: _line)),
    ),
    child: Row(
      children: [
        const Expanded(
          child: Text(
            'Could not load more items.',
            style: TextStyle(color: _quietText, fontSize: 13),
          ),
        ),
        TextButton(onPressed: onRetry, child: const Text('Retry')),
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
