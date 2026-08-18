import 'package:flutter/foundation.dart';

import '../sources/source_catalog_database.dart';
import '../sources/source_models.dart';

/// The local-only persistence and source-resolution boundary shared by Browse
/// and Search. It deliberately exposes no credentials or provider calls.
abstract interface class CatalogScopePort {
  Future<List<SourceRosterEntry>> loadSourceRoster();

  Future<LibraryScope> loadCatalogScope();

  Future<LibraryScope> saveCatalogScope(LibraryScope scope);

  Future<PersistedSource?> loadReadySourceById(String sourceId);
}

class DatabaseCatalogScopePort implements CatalogScopePort {
  const DatabaseCatalogScopePort(this.database);

  final SourceCatalogDatabase database;

  @override
  Future<List<SourceRosterEntry>> loadSourceRoster() =>
      database.loadSourceRoster();

  @override
  Future<LibraryScope> loadCatalogScope() => database.loadCatalogScope();

  @override
  Future<LibraryScope> saveCatalogScope(LibraryScope scope) =>
      database.saveCatalogScope(scope);

  @override
  Future<PersistedSource?> loadReadySourceById(String sourceId) =>
      database.loadReadySourceById(sourceId);
}

/// One app-owned controller keeps the catalog scope identical across Live,
/// Movies, Series, and Search.
///
/// The shell owns this controller. Screens listen to it but never dispose it.
class CatalogScopeController extends ChangeNotifier {
  CatalogScopeController({required this.port});

  final CatalogScopePort port;
  List<SourceRosterEntry> _sources = const [];
  LibraryScope _scope = const LibraryScope.all();
  LibraryScope? _lastPersistedScope;
  Object? _error;
  String? _announcement;
  Future<void>? _initializing;
  Future<void>? _reloading;
  Future<void> _selectionTail = Future<void>.value();
  int _selectionRequest = 0;
  bool _loading = true;
  int _revision = 0;

  bool get loading => _loading;
  bool get initialized => !_loading && _error == null;
  Object? get error => _error;
  LibraryScope get scope => _scope;
  List<SourceRosterEntry> get sources => _sources;
  String? get announcement => _announcement;

  /// Changes whenever callers should reload their bounded local result page.
  int get revision => _revision;

  String get scopeLabel {
    final sourceId = _scope.sourceId;
    if (sourceId == null) return 'All sources';
    for (final source in _sources) {
      if (source.id == sourceId) return source.name;
    }
    return 'All sources';
  }

  SourceRosterEntry? get selectedSource {
    final sourceId = _scope.sourceId;
    if (sourceId == null) return null;
    for (final source in _sources) {
      if (source.id == sourceId) return source;
    }
    return null;
  }

  Future<void> initialize() {
    final current = _initializing;
    if (current != null) return current;
    if (initialized) return Future.value();
    final future = _startReload(initialLoad: true);
    _initializing = future;
    return future.whenComplete(() => _initializing = null);
  }

  /// Reloads the credential-free roster and persisted scope from local state.
  Future<void> refresh() => _startReload(initialLoad: false);

  /// A source action can cause Browse and Search to request a roster at the
  /// same time. One local read is sufficient; more importantly, it avoids
  /// turning a transient SQLite busy response into multiple global failures.
  Future<void> _startReload({required bool initialLoad}) {
    final pending = _reloading;
    if (pending != null) return pending;
    late final Future<void> future;
    future = _reload(initialLoad: initialLoad).whenComplete(() {
      if (identical(_reloading, future)) _reloading = null;
    });
    _reloading = future;
    return future;
  }

  Future<void> _reload({required bool initialLoad}) async {
    final previousSourceId = _scope.sourceId;
    if (initialLoad) {
      _loading = true;
      _error = null;
      notifyListeners();
    }
    try {
      // Fresh installs may create and migrate the same SQLite file here. Keep
      // the two tiny local reads sequential so their migration opens cannot
      // race each other.
      final roster = await port.loadSourceRoster();
      final persistedScope = await port.loadCatalogScope();
      final enabled = List<SourceRosterEntry>.unmodifiable(
        roster.where(_isBrowsableSource),
      );
      var loadedScope = persistedScope;
      final loadedSourceId = loadedScope.sourceId;
      if (loadedSourceId != null &&
          !enabled.any((source) => source.id == loadedSourceId)) {
        loadedScope = await port.saveCatalogScope(const LibraryScope.all());
      }
      _sources = enabled;
      _scope = loadedScope;
      _lastPersistedScope = loadedScope;
      _loading = false;
      _error = null;
      if (!initialLoad &&
          previousSourceId != null &&
          _scope.sourceId == null &&
          !enabled.any((source) => source.id == previousSourceId)) {
        _announcement = 'Source unavailable. Showing All sources.';
      }
      _revision++;
      notifyListeners();
    } catch (_) {
      _loading = false;
      if (initialLoad) {
        _error = Object();
      } else {
        // Existing local data remains a valid Browse/Search snapshot. Do not
        // replace it with the global unavailable state just because a refresh
        // roster read collided with a large write transaction.
        _announcement =
            'Could not update sources. Showing the last local catalog.';
      }
      notifyListeners();
    }
  }

  bool _isBrowsableSource(SourceRosterEntry source) {
    if (!source.enabled) return false;
    if (source.status == 'ready' || source.status == 'refreshing') return true;
    return source.status == 'refresh_failed' &&
        source.counts.values.any((count) => count > 0);
  }

  Future<void> select(LibraryScope requested) {
    final request = ++_selectionRequest;
    final selection = _selectionTail.then(
      (_) => _saveSelection(requested, request),
    );
    _selectionTail = selection;
    return selection;
  }

  Future<void> _saveSelection(LibraryScope requested, int request) async {
    final sourceId = requested.sourceId;
    final canSelect =
        sourceId == null || _sources.any((source) => source.id == sourceId);
    final desired = canSelect ? requested : const LibraryScope.all();
    try {
      final saved = await port.saveCatalogScope(desired);
      _lastPersistedScope = saved;
      if (request != _selectionRequest) return;
      _scope = saved;
      _error = null;
      if (sourceId != null && saved.sourceId != sourceId) {
        _announcement = 'Source unavailable. Showing All sources.';
      } else {
        _announcement = null;
      }
      _revision++;
      notifyListeners();
    } catch (_) {
      if (request != _selectionRequest) return;
      final persisted = _lastPersistedScope;
      if (persisted != null && persisted.sourceId != _scope.sourceId) {
        _scope = persisted;
        _revision++;
      }
      _error = Object();
      _announcement = 'Could not change source. Try again.';
      notifyListeners();
    }
  }

  Future<PersistedSource?> resolveReadySource(String sourceId) =>
      port.loadReadySourceById(sourceId);

  void clearAnnouncement() {
    if (_announcement == null) return;
    _announcement = null;
    notifyListeners();
  }
}
