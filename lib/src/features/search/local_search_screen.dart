import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

import '../artwork/artwork_loader.dart';
import '../artwork/source_artwork.dart';
import '../browse/catalog_scope_controller.dart';
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

/// Typed handoff from the mixed local ledger to the shell's existing playback
/// or continuation contracts. The item remains credential-free.
typedef SearchItemActivated = void Function(LibraryCatalogItem item);

/// The bounded local catalog work used by Search. This has no provider
/// operation: typing in Search can never start a network request.
abstract interface class LocalSearchData {
  Future<LibraryPage> searchPage({
    required String query,
    required LibraryScope scope,
    BrowseCursor? cursor,
    int limit,
  });

  Future<int> count({required String query, required LibraryScope scope});

  Future<PersistedSource?> loadReadySourceById(String sourceId);
}

class DatabaseLocalSearchData implements LocalSearchData {
  const DatabaseLocalSearchData(this.database);

  final SourceCatalogDatabase database;

  @override
  Future<LibraryPage> searchPage({
    required String query,
    required LibraryScope scope,
    BrowseCursor? cursor,
    int limit = 100,
  }) => database.searchLibraryPage(
    query: query,
    scope: scope,
    cursor: cursor,
    limit: limit,
  );

  @override
  Future<int> count({required String query, required LibraryScope scope}) =>
      database.countLibraryItems(scope: scope, query: query);

  @override
  Future<PersistedSource?> loadReadySourceById(String sourceId) =>
      database.loadReadySourceById(sourceId);
}

/// Practical in-memory state retained while the user moves around the shell.
class LocalSearchSession {
  String query = '';
  String? scopeId;
  String? focusedItemId;
  double scrollOffset = 0;
  List<LibraryCatalogItem> items = const [];
  BrowseCursor? nextCursor;
  int? total;

  @visibleForTesting
  int mountedItemFocusCount = 0;
}

class LocalSearchScreen extends StatefulWidget {
  const LocalSearchScreen({
    super.key,
    required this.scopeController,
    required this.initialFocus,
    required this.onContentFocus,
    required this.onOpenRail,
    required this.session,
    this.data,
    this.onItemActivated,
    this.onPlaybackHandoff,
    this.onOrganizeItem,
    this.credentialStore,
    this.seriesInfoLoader,
    this.artworkLoader,
  });

  final CatalogScopeController scopeController;
  final FocusNode initialFocus;
  final ValueChanged<FocusNode> onContentFocus;
  final VoidCallback onOpenRail;
  final LocalSearchSession session;
  final LocalSearchData? data;
  final SearchItemActivated? onItemActivated;
  final ValueChanged<PlaybackHandoff>? onPlaybackHandoff;
  final ValueChanged<LibraryCatalogItem>? onOrganizeItem;
  final CredentialStore? credentialStore;
  final SeriesInfoLoader? seriesInfoLoader;
  final ArtworkProvider? artworkLoader;

  @override
  State<LocalSearchScreen> createState() => _LocalSearchScreenState();
}

class _LocalSearchScreenState extends State<LocalSearchScreen> {
  static const _pageSize = 100;
  static const _debounce = Duration(milliseconds: 180);
  final TextEditingController _queryController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final FocusNode _scopeFocus = FocusNode(debugLabel: 'search scope');
  final FocusNode _clearFocus = FocusNode(debugLabel: 'search clear');
  final FocusNode _errorRetryFocus = FocusNode(debugLabel: 'search retry');
  final FocusNode _pageRetryFocus = FocusNode(
    debugLabel: 'search next-page retry',
  );
  final Map<String, FocusNode> _mountedItemNodes = {};
  Timer? _debounceTimer;
  Timer? _scopeAnnouncementTimer;
  List<LibraryCatalogItem> _items = const [];
  BrowseCursor? _nextCursor;
  int? _total;
  Object? _error;
  bool _loading = false;
  bool _loadingMore = false;
  bool _pageError = false;
  bool _keyboardOpen = false;
  bool _restoringFocus = false;
  String? _scopeAnnouncement;
  String? _lastScopeAnnouncement;
  int _request = 0;
  int _seriesRequest = 0;
  int _scopeRevision = -1;
  _SearchContinuation? _continuation;
  late LocalSearchData _data;
  late SeriesInfoLoader _seriesInfoLoader;
  late String _activeQuery;
  late String? _activeScopeId;

  String get _query => _queryController.text.trim();
  bool get _hasQuery => _query.isNotEmpty;
  LibraryScope get _scope => widget.scopeController.scope;

  @override
  void initState() {
    super.initState();
    _data =
        widget.data ?? const DatabaseLocalSearchData(SourceCatalogDatabase());
    _seriesInfoLoader =
        widget.seriesInfoLoader ??
        XtreamSeriesInfoLoader(credentialStore: widget.credentialStore);
    _queryController.text = widget.session.query;
    _activeQuery = _query;
    _activeScopeId = widget.session.scopeId;
    _queryController.addListener(_onQueryChanged);
    _scrollController.addListener(_maybeLoadMore);
    widget.scopeController.addListener(_onScopeChanged);
    _scopeRevision = widget.scopeController.revision;
    _captureScopeAnnouncement();
    unawaited(widget.scopeController.initialize());
    if (_hasQuery) _loadForCurrentQuery(restore: true);
  }

  @override
  void dispose() {
    _cancelSeriesRequest();
    _rememberPosition();
    _debounceTimer?.cancel();
    _scopeAnnouncementTimer?.cancel();
    _queryController
      ..removeListener(_onQueryChanged)
      ..dispose();
    _scrollController
      ..removeListener(_maybeLoadMore)
      ..dispose();
    _scopeFocus.dispose();
    _clearFocus.dispose();
    _errorRetryFocus.dispose();
    _pageRetryFocus.dispose();
    widget.session.mountedItemFocusCount = 0;
    widget.scopeController.removeListener(_onScopeChanged);
    super.dispose();
  }

  void _onScopeChanged() {
    if (!mounted) return;
    _captureScopeAnnouncement();
    final revision = widget.scopeController.revision;
    if (revision == _scopeRevision) {
      setState(() {});
      return;
    }
    _scopeRevision = revision;
    if (_hasQuery) {
      _loadForCurrentQuery();
    } else {
      setState(() {});
    }
  }

  void _captureScopeAnnouncement() {
    final announcement = widget.scopeController.announcement;
    if (announcement == null) {
      _lastScopeAnnouncement = null;
      return;
    }
    if (announcement == _lastScopeAnnouncement) return;
    _lastScopeAnnouncement = announcement;
    _scopeAnnouncementTimer?.cancel();
    setState(() => _scopeAnnouncement = announcement);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && widget.scopeController.announcement == announcement) {
        widget.scopeController.clearAnnouncement();
      }
    });
    _scopeAnnouncementTimer = Timer(const Duration(seconds: 4), () {
      if (mounted) setState(() => _scopeAnnouncement = null);
    });
  }

  void _onQueryChanged() {
    widget.session.query = _queryController.text;
    _debounceTimer?.cancel();
    if (!_hasQuery) {
      ++_request;
      setState(() {
        _items = const [];
        _nextCursor = null;
        _total = null;
        _error = null;
        _loading = false;
        _loadingMore = false;
        _pageError = false;
      });
      return;
    }
    _debounceTimer = Timer(_debounce, () {
      if (mounted) _loadForCurrentQuery();
    });
  }

  bool _matchesSession() =>
      widget.session.query == _queryController.text &&
      widget.session.scopeId == _scope.sourceId;

  Future<void> _loadForCurrentQuery({bool restore = false}) async {
    if (!_hasQuery || widget.scopeController.loading) return;
    final query = _query;
    final scope = _scope;
    final request = ++_request;
    final queryOrScopeChanged =
        query != _activeQuery || scope.sourceId != _activeScopeId;
    if (queryOrScopeChanged) {
      widget.session
        ..focusedItemId = null
        ..scrollOffset = 0
        ..items = const []
        ..nextCursor = null
        ..total = null;
      _activeQuery = query;
      _activeScopeId = scope.sourceId;
    }
    if (restore && _matchesSession() && widget.session.items.isNotEmpty) {
      setState(() {
        _items = widget.session.items;
        _nextCursor = widget.session.nextCursor;
        _total = widget.session.total;
        _loading = false;
        _error = null;
      });
      _restoringFocus = widget.session.focusedItemId != null;
      _restorePosition();
      return;
    }
    // A fresh request replaces the session snapshot. A delayed count from an
    // earlier request must not become the total restored by a later remount.
    widget.session.total = null;
    setState(() {
      _loading = true;
      _loadingMore = false;
      _pageError = false;
      _error = null;
      _total = null;
    });
    try {
      // The first visible page is enough to make Search useful. Do not hold
      // it behind a second, independent count isolate on a real catalog.
      final page = await _data.searchPage(
        query: query,
        scope: scope,
        limit: _pageSize,
      );
      if (!mounted ||
          request != _request ||
          query != _query ||
          !_sameScope(scope, _scope)) {
        return;
      }
      setState(() {
        _items = page.items;
        _nextCursor = page.nextCursor;
        _loading = false;
      });
      widget.session
        ..query = _queryController.text
        ..scopeId = scope.sourceId
        ..items = page.items
        ..nextCursor = page.nextCursor;
      _restoringFocus = restore && widget.session.focusedItemId != null;
      _restorePosition();
      unawaited(_loadResultCount(query, scope, request));
    } catch (_) {
      if (!mounted ||
          request != _request ||
          query != _query ||
          !_sameScope(scope, _scope)) {
        return;
      }
      setState(() {
        _loading = false;
        _error = Object();
      });
    }
  }

  Future<void> _loadResultCount(
    String query,
    LibraryScope scope,
    int request,
  ) async {
    try {
      final total = await _data.count(query: query, scope: scope);
      if (!mounted ||
          request != _request ||
          query != _query ||
          !_sameScope(scope, _scope)) {
        return;
      }
      setState(() => _total = total);
      widget.session.total = total;
    } catch (_) {
      // Results are already usable. A later count is presentation-only and
      // must not replace the ledger with an error state.
    }
  }

  Future<void> _retryCatalogScope() async {
    await widget.scopeController.initialize();
    // A successful initialization advances the shared controller revision;
    // [_onScopeChanged] owns the single catalog request for that revision.
  }

  bool _sameScope(LibraryScope a, LibraryScope b) => a.sourceId == b.sourceId;

  void _rememberPosition() {
    if (_scrollController.hasClients) {
      widget.session.scrollOffset = _scrollController.offset;
    }
  }

  void _restorePosition() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) return;
      final target = widget.session.scrollOffset.clamp(
        0.0,
        _scrollController.position.maxScrollExtent,
      );
      if (target > 0) _scrollController.jumpTo(target);
      if (_restoringFocus) _restoreFocusedRow();
    });
  }

  void _restoreFocusedRow([int attempts = 8]) {
    final id = widget.session.focusedItemId;
    final index = _items.indexWhere((item) => item.libraryItemId == id);
    if (!mounted || id == null || index < 0) return;
    _focusRow(index);
    final node = _mountedItemNodes[id];
    if (node?.context != null || attempts == 0) {
      _restoringFocus = false;
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _restoreFocusedRow(attempts - 1),
    );
  }

  void _maybeLoadMore() {
    _rememberPosition();
    if (!_scrollController.hasClients ||
        _nextCursor == null ||
        _loading ||
        _loadingMore ||
        _scrollController.position.extentAfter > 260) {
      return;
    }
    unawaited(_loadMore());
  }

  Future<void> _loadMore() async {
    final cursor = _nextCursor;
    if (cursor == null || _loadingMore || !_hasQuery) return;
    final query = _query;
    final scope = _scope;
    final request = _request;
    setState(() {
      _loadingMore = true;
      _pageError = false;
    });
    try {
      final page = await _data.searchPage(
        query: query,
        scope: scope,
        cursor: cursor,
        limit: _pageSize,
      );
      if (!mounted ||
          request != _request ||
          query != _query ||
          !_sameScope(scope, _scope)) {
        return;
      }
      final updated = [..._items, ...page.items];
      setState(() {
        _items = updated;
        _nextCursor = page.nextCursor;
        _loadingMore = false;
      });
      widget.session
        ..items = updated
        ..nextCursor = page.nextCursor;
    } catch (_) {
      if (!mounted ||
          request != _request ||
          query != _query ||
          !_sameScope(scope, _scope)) {
        return;
      }
      setState(() {
        _loadingMore = false;
        _pageError = true;
      });
    }
  }

  void _clear() {
    _queryController.clear();
    widget.initialFocus.requestFocus();
  }

  void _mountItemNode(String id, FocusNode node) {
    _mountedItemNodes[id] = node;
    widget.session.mountedItemFocusCount = _mountedItemNodes.length;
  }

  void _unmountItemNode(String id, FocusNode node) {
    if (identical(_mountedItemNodes[id], node)) _mountedItemNodes.remove(id);
    widget.session.mountedItemFocusCount = _mountedItemNodes.length;
  }

  void _focusRow(int index) {
    if (index < 0 || index >= _items.length) return;
    void reveal() {
      if (!mounted || !_scrollController.hasClients) return;
      const rowExtent = 64.0;
      final position = _scrollController.position;
      final start = index * rowExtent;
      final end = start + rowExtent;
      final top = _scrollController.offset;
      final bottom = top + position.viewportDimension;
      if (start < top || end > bottom) {
        _scrollController.jumpTo(
          (start - (position.viewportDimension - rowExtent) / 2).clamp(
            0.0,
            position.maxScrollExtent,
          ),
        );
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            _mountedItemNodes[_items[index].libraryItemId]?.requestFocus();
          }
        });
      } else {
        _mountedItemNodes[_items[index].libraryItemId]?.requestFocus();
      }
    }

    if (_scrollController.hasClients) {
      reveal();
    } else {
      WidgetsBinding.instance.addPostFrameCallback((_) => reveal());
    }
  }

  FocusNode? _tvKeyboardFirstFocus;

  void _openTvKeyboard() {
    setState(() => _keyboardOpen = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _tvKeyboardFirstFocus?.requestFocus();
    });
  }

  void _closeTvKeyboard({required bool done}) {
    if (!_keyboardOpen) return;
    setState(() => _keyboardOpen = false);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (done && _items.isNotEmpty) {
        _focusRow(0);
      } else {
        widget.initialFocus.requestFocus();
      }
    });
  }

  void _activateItem(LibraryCatalogItem item) {
    widget.session.focusedItemId = item.libraryItemId;
    widget.onItemActivated?.call(item);
    switch (item.kind) {
      case SourceMediaKind.live:
        _activateLive(item);
      case SourceMediaKind.movies:
        _openMovie(item);
      case SourceMediaKind.series:
        _openSeries(item);
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

  void _activateLive(LibraryCatalogItem item) {
    try {
      widget.onPlaybackHandoff?.call(playbackHandoffForLibrary(item));
    } on ContinuationException catch (error) {
      setState(
        () => _continuation = _FailureSearchContinuation(item, error.failure),
      );
    }
  }

  void _openMovie(LibraryCatalogItem item) {
    try {
      final handoff = playbackHandoffForLibrary(item);
      if (handoff is! MoviePlaybackHandoff) {
        throw const ContinuationException(ContinuationFailure.invalidReference);
      }
      setState(() => _continuation = _MovieSearchContinuation(item, handoff));
    } on ContinuationException catch (error) {
      setState(
        () => _continuation = _FailureSearchContinuation(item, error.failure),
      );
    }
  }

  void _openSeries(LibraryCatalogItem item) {
    _cancelSeriesRequest();
    try {
      seriesReferenceForLibrary(item);
    } on ContinuationException catch (error) {
      setState(
        () => _continuation = _FailureSearchContinuation(item, error.failure),
      );
      return;
    }
    unawaited(_loadSeries(item));
  }

  Future<void> _loadSeries(LibraryCatalogItem item) async {
    final request = ++_seriesRequest;
    setState(
      () => _continuation = _SeriesSearchContinuation(item, loading: true),
    );
    try {
      final source = await _data.loadReadySourceById(item.sourceId);
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
        () => _continuation = _SeriesSearchContinuation(
          item,
          loading: false,
          info: info,
        ),
      );
    } on ContinuationException catch (error) {
      if (mounted && request == _seriesRequest) {
        setState(
          () => _continuation = _SeriesSearchContinuation(
            item,
            loading: false,
            failure: error.failure,
          ),
        );
      }
    } catch (_) {
      if (mounted && request == _seriesRequest) {
        setState(
          () => _continuation = _SeriesSearchContinuation(
            item,
            loading: false,
            failure: ContinuationFailure.unavailable,
          ),
        );
      }
    }
  }

  void _cancelSeriesRequest() {
    ++_seriesRequest;
    _seriesInfoLoader.cancel();
  }

  void _returnToSearch() {
    _cancelSeriesRequest();
    setState(() => _continuation = null);
    _restorePosition();
  }

  @override
  Widget build(BuildContext context) {
    final continuation = _continuation;
    if (continuation != null) return _buildContinuation(continuation);
    return LayoutBuilder(
      builder: (context, constraints) {
        final narrow = constraints.maxWidth < 720;
        return ColoredBox(
          color: _graphite,
          child: Focus(
            onKeyEvent: (_, event) {
              if (event is! KeyDownEvent) return KeyEventResult.ignored;
              if (event.logicalKey == LogicalKeyboardKey.escape ||
                  event.logicalKey == LogicalKeyboardKey.browserBack) {
                if (_keyboardOpen) {
                  _closeTvKeyboard(done: false);
                } else {
                  widget.onOpenRail();
                }
                return KeyEventResult.handled;
              }
              return KeyEventResult.ignored;
            },
            child: SafeArea(
              left: false,
              child: Stack(
                children: [
                  Padding(
                    padding: EdgeInsets.fromLTRB(
                      narrow ? 24 : 32,
                      22,
                      narrow ? 24 : 32,
                      32,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _SearchHeader(
                          scopeController: widget.scopeController,
                          focusNode: _scopeFocus,
                          narrow: narrow,
                          onFocused: widget.onContentFocus,
                          onDown: widget.initialFocus.requestFocus,
                        ),
                        const SizedBox(height: 10),
                        _SearchField(
                          controller: _queryController,
                          focusNode: widget.initialFocus,
                          clearFocusNode: _clearFocus,
                          onContentFocus: widget.onContentFocus,
                          onOpenKeyboard: _openTvKeyboard,
                          onClear: _clear,
                          onUpScope: _scopeFocus.requestFocus,
                          onDown: _error == null
                              ? null
                              : _errorRetryFocus.requestFocus,
                        ),
                        const SizedBox(height: 16),
                        Expanded(child: _buildBody()),
                      ],
                    ),
                  ),
                  if (_scopeAnnouncement != null)
                    Positioned(
                      left: narrow ? 24 : 32,
                      right: narrow ? 24 : 32,
                      bottom: 10,
                      child: Semantics(
                        liveRegion: true,
                        label: _scopeAnnouncement,
                        child: Text(
                          _scopeAnnouncement!,
                          key: const ValueKey('search-scope-announcement'),
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            color: _quietText,
                            fontSize: 13,
                          ),
                        ),
                      ),
                    ),
                  if (_keyboardOpen)
                    Positioned.fill(
                      child: _TvKeyboardOverlay(
                        queryController: _queryController,
                        onDismiss: () => _closeTvKeyboard(done: false),
                        onDone: () => _closeTvKeyboard(done: true),
                        onFirstFocus: (node) => _tvKeyboardFirstFocus = node,
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

  Widget _buildContinuation(_SearchContinuation continuation) =>
      switch (continuation) {
        _MovieSearchContinuation(:final item, :final handoff) =>
          MovieContinuation(
            title: item.title,
            artworkLocator: item.artworkLocator,
            artworkLoader: widget.artworkLoader,
            onOrganize: widget.onOrganizeItem == null
                ? null
                : () => widget.onOrganizeItem!(item),
            onBack: _returnToSearch,
            onPlay: () {
              widget.onPlaybackHandoff?.call(handoff);
            },
          ),
        _SeriesSearchContinuation(
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
            onBack: _returnToSearch,
            onRetry: () => _openSeries(item),
            onEpisodeActivated: (episode) {
              widget.onPlaybackHandoff?.call(
                EpisodePlaybackHandoff(
                  sourceId: item.sourceId,
                  title: episode.title,
                  providerItemId: episode.providerItemId,
                  extension: episode.extension,
                  libraryItemId: item.libraryItemId,
                ),
              );
            },
          ),
        _FailureSearchContinuation(:final item, :final failure) =>
          ContinuationFailureView(
            title: item.title,
            failure: failure,
            onBack: _returnToSearch,
            onRetry: () => _activateItem(item),
          ),
      };

  Widget _buildBody() {
    if (widget.scopeController.loading) return const _SearchSkeleton();
    if (widget.scopeController.error != null &&
        widget.scopeController.sources.isEmpty) {
      return _SearchMessage(
        key: const ValueKey('search-catalog-error'),
        title: 'Catalog unavailable',
        message: 'Could not load the local source list. Try again.',
        actionLabel: 'Try again',
        onPressed: _retryCatalogScope,
        actionFocusNode: _errorRetryFocus,
      );
    }
    if (!_hasQuery) {
      return const _SearchMessage(
        key: ValueKey('search-empty'),
        title: 'Search your local library',
        message: 'Type a title, channel, movie, or series to search every imported source.',
      );
    }
    if (_error != null) {
      return _SearchMessage(
        key: const ValueKey('search-error'),
        title: 'Search unavailable',
        message: 'Could not search the local library. Try again.',
        actionLabel: 'Retry',
        onPressed: _loadForCurrentQuery,
        actionFocusNode: _errorRetryFocus,
      );
    }
    if (_loading && _items.isEmpty) return const _SearchSkeleton();
    if (!_loading && _items.isEmpty) {
      return _SearchMessage(
        key: const ValueKey('search-no-results'),
        title: 'No local matches',
        message:
            'No matches for “$_query” in ${widget.scopeController.scopeLabel}.',
      );
    }
    return DecoratedBox(
      decoration: BoxDecoration(
        color: _surface,
        border: Border.all(color: _line),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 14, 18, 12),
            child: Row(
              children: [
                Expanded(
                  child: Semantics(
                    liveRegion: true,
                    label: _total == null
                        ? 'Searching local library'
                        : '${_formatCount(_total!)} local results',
                    child: Text(
                      _total == null
                          ? 'Searching local library'
                          : '${_formatCount(_total!)} results',
                      key: const ValueKey('search-result-count'),
                      style: const TextStyle(
                        color: _warmWhite,
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
                const ExcludeSemantics(
                  child: Icon(
                    Icons.manage_search_outlined,
                    color: _quietText,
                    size: 20,
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1, color: _line),
          Expanded(
            child: ListView.builder(
              key: const ValueKey('search-results'),
              controller: _scrollController,
              itemExtent: 64,
              scrollCacheExtent: const ScrollCacheExtent.pixels(384),
              itemCount: _items.length + (_loadingMore ? 3 : 0),
              itemBuilder: (context, index) {
                if (index >= _items.length) {
                  return const _SearchRowSkeleton();
                }
                final item = _items[index];
                return _SearchRow(
                  key: ValueKey('search-row-${item.libraryItemId}'),
                  item: item,
                  showSource: _scope.isAll,
                  autofocus: index == 0 && !_restoringFocus,
                  artworkLoader: widget.artworkLoader,
                  onNodeMounted: _mountItemNode,
                  onNodeUnmounted: _unmountItemNode,
                  onContentFocus: (focusedNode) {
                    _restoringFocus = false;
                    widget.session.focusedItemId = item.libraryItemId;
                    widget.onContentFocus(focusedNode);
                  },
                  onLeft: widget.onOpenRail,
                  onUp: index == 0
                      ? () => widget.initialFocus.requestFocus()
                      : () => _focusRow(index - 1),
                  onDown: () {
                    if (index + 1 < _items.length) {
                      _focusRow(index + 1);
                    } else if (_pageError) {
                      _pageRetryFocus.requestFocus();
                    } else if (_nextCursor != null) {
                      unawaited(_loadMore());
                    }
                  },
                  onActivate: () => _activateItem(item),
                  onOrganize: widget.onOrganizeItem == null
                      ? null
                      : () => widget.onOrganizeItem!(item),
                );
              },
            ),
          ),
          if (_pageError)
            _PageRetry(
              focusNode: _pageRetryFocus,
              onPressed: () => unawaited(_loadMore()),
            ),
        ],
      ),
    );
  }
}

sealed class _SearchContinuation {
  const _SearchContinuation(this.item);
  final LibraryCatalogItem item;
}

class _MovieSearchContinuation extends _SearchContinuation {
  const _MovieSearchContinuation(super.item, this.handoff);
  final MoviePlaybackHandoff handoff;
}

class _SeriesSearchContinuation extends _SearchContinuation {
  const _SeriesSearchContinuation(
    super.item, {
    required this.loading,
    this.info,
    this.failure,
  });
  final bool loading;
  final SeriesInfo? info;
  final ContinuationFailure? failure;
}

class _FailureSearchContinuation extends _SearchContinuation {
  const _FailureSearchContinuation(super.item, this.failure);
  final ContinuationFailure failure;
}

class _SearchHeader extends StatelessWidget {
  const _SearchHeader({
    required this.scopeController,
    required this.focusNode,
    required this.narrow,
    required this.onFocused,
    required this.onDown,
  });

  final CatalogScopeController scopeController;
  final FocusNode focusNode;
  final bool narrow;
  final ValueChanged<FocusNode> onFocused;
  final VoidCallback onDown;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: scopeController,
    builder: (context, _) {
      final sourceState = _catalogScopeState(scopeController);
      final stateHeight = (MediaQuery.textScalerOf(context).scale(13) + 5)
          .clamp(18, 30)
          .toDouble();
      return Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Search',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: _warmWhite,
                    fontSize: 31,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.7,
                  ),
                ),
                const SizedBox(height: 2),
                SizedBox(
                  height: stateHeight,
                  child: sourceState == null
                      ? null
                      : Align(
                          alignment: Alignment.centerLeft,
                          child: Semantics(
                            liveRegion: true,
                            child: Text(
                              sourceState,
                              key: const ValueKey('search-catalog-state'),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: _quietText,
                                fontSize: 13,
                              ),
                            ),
                          ),
                        ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          _ScopeMenu(
            key: const ValueKey('search-scope-menu'),
            scopeController: scopeController,
            focusNode: focusNode,
            onFocused: onFocused,
            compact: narrow,
            onDown: onDown,
          ),
        ],
      );
    },
  );
}

class _ScopeMenu extends StatefulWidget {
  const _ScopeMenu({
    super.key,
    required this.scopeController,
    required this.focusNode,
    required this.onFocused,
    required this.compact,
    required this.onDown,
  });
  final CatalogScopeController scopeController;
  final FocusNode focusNode;
  final ValueChanged<FocusNode> onFocused;
  final bool compact;
  final VoidCallback onDown;

  @override
  State<_ScopeMenu> createState() => _ScopeMenuState();
}

class _ScopeMenuState extends State<_ScopeMenu> {
  bool _focused = false;
  Future<void> _open() async {
    if (widget.scopeController.loading) return;
    final box = context.findRenderObject()! as RenderBox;
    final overlay =
        Overlay.of(context).context.findRenderObject()! as RenderBox;
    final position = RelativeRect.fromRect(
      Rect.fromPoints(
        box.localToGlobal(Offset.zero, ancestor: overlay),
        box.localToGlobal(box.size.bottomRight(Offset.zero), ancestor: overlay),
      ),
      Offset.zero & overlay.size,
    );
    final selection = await showMenu<LibraryScope>(
      context: context,
      position: position,
      color: _raised,
      items: [
        const PopupMenuItem(
          value: LibraryScope.all(),
          child: Text('All sources'),
        ),
        ...widget.scopeController.sources.map(
          (source) => PopupMenuItem(
            value: LibraryScope.source(source.id),
            child: Text(source.name, overflow: TextOverflow.ellipsis),
          ),
        ),
      ],
    );
    if (selection != null) unawaited(widget.scopeController.select(selection));
    if (mounted) widget.focusNode.requestFocus();
  }

  @override
  Widget build(BuildContext context) => Focus(
    focusNode: widget.focusNode,
    onFocusChange: (focused) {
      setState(() => _focused = focused);
      if (focused) widget.onFocused(widget.focusNode);
    },
    onKeyEvent: (_, event) {
      if (event is KeyDownEvent &&
          (event.logicalKey == LogicalKeyboardKey.enter ||
              event.logicalKey == LogicalKeyboardKey.select)) {
        unawaited(_open());
        return KeyEventResult.handled;
      }
      if (event is KeyDownEvent &&
          event.logicalKey == LogicalKeyboardKey.arrowDown) {
        widget.onDown();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    },
    child: Semantics(
      button: true,
      label: 'Catalog scope: ${widget.scopeController.scopeLabel}',
      child: GestureDetector(
        onTap: () {
          widget.focusNode.requestFocus();
          unawaited(_open());
        },
        child: _ScopeButton(
          label: widget.scopeController.scopeLabel,
          compact: widget.compact,
          focused: _focused,
        ),
      ),
    ),
  );
}

class _ScopeButton extends StatelessWidget {
  const _ScopeButton({
    required this.label,
    required this.compact,
    this.focused = false,
  });
  final String label;
  final bool compact;
  final bool focused;

  @override
  Widget build(BuildContext context) => Container(
    constraints: BoxConstraints(maxWidth: compact ? 160 : 184),
    height: 44,
    padding: const EdgeInsets.symmetric(horizontal: 14),
    decoration: BoxDecoration(
      color: _surface,
      border: Border.all(color: focused ? _amber : _line, width: 2),
      borderRadius: BorderRadius.circular(6),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Flexible(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: _warmWhite,
              fontSize: 14,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        const SizedBox(width: 8),
        const Icon(Icons.keyboard_arrow_down, color: _quietText, size: 18),
      ],
    ),
  );
}

class _SearchField extends StatelessWidget {
  const _SearchField({
    required this.controller,
    required this.focusNode,
    required this.clearFocusNode,
    required this.onContentFocus,
    required this.onOpenKeyboard,
    required this.onClear,
    required this.onUpScope,
    this.onDown,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final FocusNode clearFocusNode;
  final ValueChanged<FocusNode> onContentFocus;
  final VoidCallback onOpenKeyboard;
  final VoidCallback onClear;
  final VoidCallback onUpScope;
  final VoidCallback? onDown;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: focusNode,
    builder: (context, _) => Focus(
      onFocusChange: (focused) {
        if (focused) onContentFocus(focusNode);
      },
      onKeyEvent: (_, event) {
        if (event is KeyDownEvent &&
            (event.logicalKey == LogicalKeyboardKey.enter ||
                event.logicalKey == LogicalKeyboardKey.select)) {
          onOpenKeyboard();
          return KeyEventResult.handled;
        }
        if (event is KeyDownEvent &&
            event.logicalKey == LogicalKeyboardKey.arrowUp) {
          onUpScope();
          return KeyEventResult.handled;
        }
        if (event is KeyDownEvent &&
            event.logicalKey == LogicalKeyboardKey.arrowDown &&
            onDown != null) {
          onDown!();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: Container(
        height: 52,
        decoration: BoxDecoration(
          color: _surface,
          border: Border.all(
            color: focusNode.hasFocus ? _amber : _line,
            width: 2,
          ),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(
          children: [
            const Padding(
              padding: EdgeInsets.only(left: 16),
              child: Icon(Icons.search, color: _quietText),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: TextField(
                key: const ValueKey('search-field'),
                controller: controller,
                focusNode: focusNode,
                style: const TextStyle(color: _warmWhite, fontSize: 17),
                cursorColor: _amber,
                maxLines: 1,
                textInputAction: TextInputAction.search,
                onTap: () => onContentFocus(focusNode),
                onSubmitted: (_) => onOpenKeyboard(),
                decoration: const InputDecoration(
                  hintText: 'Search Live, Movies, and Series',
                  hintStyle: TextStyle(color: _quietText),
                  border: InputBorder.none,
                  isDense: true,
                ),
              ),
            ),
            _TextAction(
              label: 'Clear',
              focusNode: clearFocusNode,
              enabled: controller.text.isNotEmpty,
              onFocused: onContentFocus,
              onPressed: onClear,
            ),
            const SizedBox(width: 8),
          ],
        ),
      ),
    ),
  );
}

class _TextAction extends StatefulWidget {
  const _TextAction({
    required this.label,
    required this.focusNode,
    required this.enabled,
    required this.onFocused,
    required this.onPressed,
  });
  final String label;
  final FocusNode focusNode;
  final bool enabled;
  final ValueChanged<FocusNode> onFocused;
  final VoidCallback onPressed;

  @override
  State<_TextAction> createState() => _TextActionState();
}

class _TextActionState extends State<_TextAction> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) => Focus(
    focusNode: widget.focusNode,
    canRequestFocus: widget.enabled,
    onFocusChange: (focused) {
      setState(() => _focused = focused);
      if (focused) widget.onFocused(widget.focusNode);
    },
    onKeyEvent: (_, event) {
      if (event is KeyDownEvent &&
          (event.logicalKey == LogicalKeyboardKey.enter ||
              event.logicalKey == LogicalKeyboardKey.select)) {
        widget.onPressed();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    },
    child: GestureDetector(
      onTap: widget.enabled
          ? () {
              widget.focusNode.requestFocus();
              widget.onPressed();
            }
          : null,
      child: Container(
        key: ValueKey('search-action-${widget.label}'),
        height: 36,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: widget.enabled ? _raised : Colors.transparent,
          border: Border.all(
            color: _focused ? _amber : Colors.transparent,
            width: 2,
          ),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(
          widget.label,
          style: TextStyle(
            color: widget.enabled ? _warmWhite : _quietText,
            fontSize: 14,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    ),
  );
}

class _SearchRow extends StatefulWidget {
  const _SearchRow({
    super.key,
    required this.item,
    required this.showSource,
    required this.autofocus,
    required this.artworkLoader,
    required this.onNodeMounted,
    required this.onNodeUnmounted,
    required this.onContentFocus,
    required this.onLeft,
    required this.onUp,
    required this.onDown,
    required this.onActivate,
    this.onOrganize,
  });
  final LibraryCatalogItem item;
  final bool showSource;
  final bool autofocus;
  final ArtworkProvider? artworkLoader;
  final void Function(String id, FocusNode node) onNodeMounted;
  final void Function(String id, FocusNode node) onNodeUnmounted;
  final ValueChanged<FocusNode> onContentFocus;
  final VoidCallback onLeft;
  final VoidCallback onUp;
  final VoidCallback onDown;
  final VoidCallback onActivate;
  final VoidCallback? onOrganize;

  @override
  State<_SearchRow> createState() => _SearchRowState();
}

class _SearchRowState extends State<_SearchRow> {
  bool _focused = false;
  late final FocusNode _focusNode;

  @override
  void initState() {
    super.initState();
    _focusNode = FocusNode(debugLabel: 'search ${widget.item.libraryItemId}');
    widget.onNodeMounted(widget.item.libraryItemId, _focusNode);
  }

  @override
  void didUpdateWidget(covariant _SearchRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.item.libraryItemId != widget.item.libraryItemId) {
      oldWidget.onNodeUnmounted(oldWidget.item.libraryItemId, _focusNode);
      widget.onNodeMounted(widget.item.libraryItemId, _focusNode);
    }
  }

  @override
  void dispose() {
    widget.onNodeUnmounted(widget.item.libraryItemId, _focusNode);
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Focus(
    focusNode: _focusNode,
    autofocus: widget.autofocus,
    onFocusChange: (focused) {
      setState(() => _focused = focused);
      if (focused) widget.onContentFocus(_focusNode);
    },
    onKeyEvent: (_, event) {
      if (event is! KeyDownEvent) return KeyEventResult.ignored;
      switch (event.logicalKey) {
        case LogicalKeyboardKey.arrowLeft:
          widget.onLeft();
          return KeyEventResult.handled;
        case LogicalKeyboardKey.arrowUp:
          widget.onUp();
          return KeyEventResult.handled;
        case LogicalKeyboardKey.arrowDown:
          widget.onDown();
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
      label:
          '${widget.item.title}, ${widget.item.kind.label}${widget.showSource ? ', ${widget.item.sourceDisplayName}' : ''}',
      customSemanticsActions: widget.onOrganize == null
          ? null
          : {
              const CustomSemanticsAction(label: 'Organize item'):
                  widget.onOrganize!,
            },
      child: GestureDetector(
        onTap: () {
          _focusNode.requestFocus();
          widget.onActivate();
        },
        child: Container(
          key: ValueKey('search-item-${widget.item.libraryItemId}'),
          margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            color: _focused ? _raised : Colors.transparent,
            border: Border.all(
              color: _focused ? _amber : Colors.transparent,
              width: 2,
            ),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Row(
            children: [
              SourceArtwork(
                key: ValueKey('search-artwork-${widget.item.libraryItemId}'),
                locator: widget.item.artworkLocator,
                kind: widget.item.kind,
                loader: widget.artworkLoader,
                focused: _focused,
                loadWhenVisible: true,
              ),
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
              const SizedBox(width: 12),
              Text(
                _kindBadge(widget.item.kind),
                style: const TextStyle(
                  color: _quietText,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
              if (widget.showSource) ...[
                const SizedBox(width: 12),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 160),
                  child: Text(
                    widget.item.sourceDisplayName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: _quietText, fontSize: 14),
                  ),
                ),
              ],
              if (widget.onOrganize != null) ...[
                const SizedBox(width: 8),
                Tooltip(
                  message: 'Organize',
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () {
                      _focusNode.requestFocus();
                      widget.onOrganize!();
                    },
                    child: const Padding(
                      padding: EdgeInsets.all(7),
                      child: Icon(
                        Icons.bookmark_add_outlined,
                        size: 18,
                        color: _quietText,
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    ),
  );
}

class _SearchMessage extends StatelessWidget {
  const _SearchMessage({
    super.key,
    required this.title,
    required this.message,
    this.actionLabel,
    this.onPressed,
    this.actionFocusNode,
  });
  final String title;
  final String message;
  final String? actionLabel;
  final VoidCallback? onPressed;
  final FocusNode? actionFocusNode;

  @override
  Widget build(BuildContext context) => Center(
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 560),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              title,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: _warmWhite,
                fontSize: 22,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: _quietText,
                fontSize: 16,
                height: 1.4,
              ),
            ),
            if (actionLabel != null) ...[
              const SizedBox(height: 16),
              TextButton(
                key: const ValueKey('search-error-retry'),
                focusNode: actionFocusNode,
                onPressed: onPressed,
                child: Text(actionLabel!),
              ),
            ],
          ],
        ),
      ),
    ),
  );
}

class _SearchSkeleton extends StatelessWidget {
  const _SearchSkeleton();

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: _surface,
      border: Border.all(color: _line),
      borderRadius: BorderRadius.circular(8),
    ),
    child: ListView.builder(
      itemCount: 7,
      itemExtent: 64,
      itemBuilder: (_, _) => const _SearchRowSkeleton(),
    ),
  );
}

class _SearchRowSkeleton extends StatelessWidget {
  const _SearchRowSkeleton();

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
    child: Container(
      height: 32,
      decoration: BoxDecoration(
        color: _raised,
        borderRadius: BorderRadius.circular(6),
      ),
    ),
  );
}

class _PageRetry extends StatelessWidget {
  const _PageRetry({required this.focusNode, required this.onPressed});
  final FocusNode focusNode;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => Container(
    key: const ValueKey('search-next-page-error'),
    width: double.infinity,
    color: _raised,
    padding: const EdgeInsets.all(10),
    child: TextButton(
      focusNode: focusNode,
      onPressed: onPressed,
      child: const Text('Retry'),
    ),
  );
}

class _TvKeyboardOverlay extends StatefulWidget {
  const _TvKeyboardOverlay({
    required this.queryController,
    required this.onDismiss,
    required this.onDone,
    required this.onFirstFocus,
  });
  final TextEditingController queryController;
  final VoidCallback onDismiss;
  final VoidCallback onDone;
  final ValueChanged<FocusNode> onFirstFocus;

  @override
  State<_TvKeyboardOverlay> createState() => _TvKeyboardOverlayState();
}

class _TvKeyboardOverlayState extends State<_TvKeyboardOverlay> {
  static const _rows = <List<String>>[
    ['A', 'B', 'C', 'D', 'E', 'F', 'G', 'H', 'I', 'J'],
    ['K', 'L', 'M', 'N', 'O', 'P', 'Q', 'R', 'S', 'T'],
    ['U', 'V', 'W', 'X', 'Y', 'Z', '0', '1', '2', '3'],
    ['4', '5', '6', '7', '8', '9'],
    ['Space', 'Back', 'Clear', 'Done'],
  ];
  final Map<String, FocusNode> _nodes = {};

  FocusNode _node(String key) =>
      _nodes.putIfAbsent(key, () => FocusNode(debugLabel: 'tv keyboard $key'));

  @override
  void initState() {
    super.initState();
    widget.onFirstFocus(_node('A'));
  }

  @override
  void dispose() {
    for (final node in _nodes.values) {
      node.dispose();
    }
    super.dispose();
  }

  void _move(String key, LogicalKeyboardKey direction) {
    var row = -1;
    var column = -1;
    for (var r = 0; r < _rows.length; r++) {
      final c = _rows[r].indexOf(key);
      if (c >= 0) {
        row = r;
        column = c;
        break;
      }
    }
    if (row < 0) return;
    if (direction == LogicalKeyboardKey.arrowLeft ||
        direction == LogicalKeyboardKey.arrowRight) {
      final delta = direction == LogicalKeyboardKey.arrowLeft ? -1 : 1;
      final target = (column + delta).clamp(0, _rows[row].length - 1).toInt();
      _node(_rows[row][target]).requestFocus();
      return;
    }
    final targetRow = (row + (direction == LogicalKeyboardKey.arrowUp ? -1 : 1))
        .clamp(0, _rows.length - 1)
        .toInt();
    final target = _nearestKey(targetRow, _keyCenter(row, column));
    _node(target).requestFocus();
  }

  double _keyCenter(int row, int column) {
    final keys = _rows[row];
    final total = keys.fold<int>(0, (sum, key) => sum + _keyFlex(key));
    var before = 0;
    for (var index = 0; index < column; index++) {
      before += _keyFlex(keys[index]);
    }
    return (before + _keyFlex(keys[column]) / 2) / total;
  }

  String _nearestKey(int row, double center) {
    final keys = _rows[row];
    var closest = keys.first;
    var distance = double.infinity;
    for (var index = 0; index < keys.length; index++) {
      final candidateDistance = (_keyCenter(row, index) - center).abs();
      if (candidateDistance < distance) {
        closest = keys[index];
        distance = candidateDistance;
      }
    }
    return closest;
  }

  void _press(String key) {
    switch (key) {
      case 'Space':
        widget.queryController.text += ' ';
      case 'Back':
        final text = widget.queryController.text;
        if (text.isNotEmpty) {
          widget.queryController.text = text.substring(0, text.length - 1);
        }
      case 'Clear':
        widget.queryController.clear();
      case 'Done':
        widget.onDone();
      default:
        widget.queryController.text += key;
    }
    setState(() {});
  }

  @override
  Widget build(BuildContext context) => Stack(
    key: const ValueKey('search-tv-keyboard'),
    children: [
      Positioned.fill(
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onDismiss,
          child: ColoredBox(
            key: const ValueKey('search-tv-keyboard-scrim'),
            color: Colors.black.withValues(alpha: .62),
          ),
        ),
      ),
      Positioned.fill(
        child: Material(
          type: MaterialType.transparency,
          child: Focus(
            onKeyEvent: (_, event) {
              if (event is KeyDownEvent &&
                  (event.logicalKey == LogicalKeyboardKey.escape ||
                      event.logicalKey == LogicalKeyboardKey.browserBack)) {
                widget.onDismiss();
                return KeyEventResult.handled;
              }
              return KeyEventResult.ignored;
            },
            child: SafeArea(
              left: false,
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 760),
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: _surface,
                        border: Border.all(color: _line),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.all(18),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'Enter search text',
                              style: TextStyle(
                                color: _warmWhite,
                                fontSize: 18,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(height: 4),
                            const Text(
                              'Use arrows to move, then Select',
                              style: TextStyle(color: _quietText, fontSize: 14),
                            ),
                            const SizedBox(height: 12),
                            Container(
                              key: const ValueKey('search-tv-keyboard-query'),
                              height: 44,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                              ),
                              decoration: BoxDecoration(
                                color: _graphite,
                                border: Border.all(color: _line),
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Row(
                                children: [
                                  const Icon(
                                    Icons.search,
                                    color: _quietText,
                                    size: 20,
                                  ),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: Text(
                                      widget.queryController.text.isEmpty
                                          ? ' '
                                          : widget.queryController.text,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        color: _warmWhite,
                                        fontSize: 16,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(height: 16),
                            for (final row in _rows)
                              Row(
                                children: [
                                  for (final key in row)
                                    Expanded(
                                      flex: _keyFlex(key),
                                      child: Padding(
                                        padding: const EdgeInsets.all(3),
                                        child: _TvKey(
                                          label: key,
                                          focusNode: _node(key),
                                          onMove: (direction) =>
                                              _move(key, direction),
                                          onPressed: () => _press(key),
                                        ),
                                      ),
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
        ),
      ),
    ],
  );

  int _keyFlex(String key) => switch (key) {
    'Space' => 3,
    'Back' || 'Clear' || 'Done' => 2,
    _ => 1,
  };
}

class _TvKey extends StatefulWidget {
  const _TvKey({
    required this.label,
    required this.focusNode,
    required this.onMove,
    required this.onPressed,
  });
  final String label;
  final FocusNode focusNode;
  final ValueChanged<LogicalKeyboardKey> onMove;
  final VoidCallback onPressed;

  @override
  State<_TvKey> createState() => _TvKeyState();
}

class _TvKeyState extends State<_TvKey> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) => Focus(
    focusNode: widget.focusNode,
    onFocusChange: (focused) => setState(() => _focused = focused),
    onKeyEvent: (_, event) {
      if (event is! KeyDownEvent) return KeyEventResult.ignored;
      if (event.logicalKey == LogicalKeyboardKey.arrowLeft ||
          event.logicalKey == LogicalKeyboardKey.arrowRight ||
          event.logicalKey == LogicalKeyboardKey.arrowUp ||
          event.logicalKey == LogicalKeyboardKey.arrowDown) {
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
      label: widget.label,
      child: GestureDetector(
        onTap: () {
          widget.focusNode.requestFocus();
          widget.onPressed();
        },
        child: Container(
          height: 42,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: _focused ? _raised : _graphite,
            border: Border.all(
              color: _focused ? _amber : _line,
              width: _focused ? 2 : 1,
            ),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Text(
            widget.label,
            style: const TextStyle(
              color: _warmWhite,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ),
    ),
  );
}

String _formatCount(int value) {
  final digits = value.toString();
  final buffer = StringBuffer();
  for (var index = 0; index < digits.length; index++) {
    if (index > 0 && (digits.length - index) % 3 == 0) buffer.write(',');
    buffer.write(digits[index]);
  }
  return buffer.toString();
}

String _kindBadge(SourceMediaKind kind) => switch (kind) {
  SourceMediaKind.live => 'LIVE',
  SourceMediaKind.movies => 'MOVIE',
  SourceMediaKind.series => 'SERIES',
};
