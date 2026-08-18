import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart';

import 'credential_store.dart';
import 'm3u_connector.dart';
import 'source_models.dart';
import 'xtream_connector.dart';

const _accountAndCategoryLimit = 8 * 1024 * 1024;
const _itemLimit = 256 * 1024 * 1024;
const _requestLimit = Duration(seconds: 120);
const _importLimit = Duration(minutes: 8);
const _cancelAcknowledgementLimit = Duration(milliseconds: 250);
const _defaultBrowsePageLimit = 100;
const _maximumBrowsePageLimit = 200;
const _defaultVisibilityCategoryLimit = 1000;
const _maximumVisibilityCategoryLimit = 1000;
const _defaultSourceRosterLimit = 100;
const _maximumSourceRosterLimit = 100;
const _catalogScopeSettingKey = 'catalog_scope';
const _allCatalogScopeValue = 'all';
const _sourceCatalogScopePrefix = 'source:';

enum ImportWorkerEventKind { stage, pending, ready, failed, cancelled }

class ImportWorkerEvent {
  const ImportWorkerEvent._(
    this.kind, {
    this.mediaKind,
    this.count,
    this.failure,
  });

  final ImportWorkerEventKind kind;
  final SourceMediaKind? mediaKind;
  final int? count;
  final SourceImportFailureKind? failure;

  factory ImportWorkerEvent.fromMessage(Map<Object?, Object?> message) {
    final type = message['type']! as String;
    return switch (type) {
      'stage' => ImportWorkerEvent._(
        ImportWorkerEventKind.stage,
        mediaKind: SourceMediaKind.values.byName(message['kind']! as String),
        count: message['count'] as int?,
      ),
      'pending' => const ImportWorkerEvent._(ImportWorkerEventKind.pending),
      'ready' => const ImportWorkerEvent._(ImportWorkerEventKind.ready),
      'cancelled' => const ImportWorkerEvent._(ImportWorkerEventKind.cancelled),
      _ => ImportWorkerEvent._(
        ImportWorkerEventKind.failed,
        failure: SourceImportFailureKind.values.byName(
          message['failure']! as String,
        ),
      ),
    };
  }
}

class PersistedSource {
  const PersistedSource({
    required this.id,
    required this.name,
    required this.credentialKey,
    required this.counts,
  });
  final String id;
  final String name;
  final String credentialKey;
  final Map<SourceMediaKind, int> counts;

  SourceReady get ready => SourceReady(counts: counts);
}

/// A single import owns its worker until it has activated or cleaned up the
/// pending source. Its stream contains only stage state and counts.
class InitialSourceImport {
  InitialSourceImport._(
    this._events,
    this._isolate,
    this._databasePath,
    this._sourceId,
  ) {
    // Terminal failures are also delivered on events; keep an unobserved
    // pending/ready future from becoming an unhandled isolate error.
    unawaited(_pending.future.then<void>((_) {}, onError: (_, _) {}));
    unawaited(_ready.future.then<void>((_) {}, onError: (_, _) {}));
  }

  final ReceivePort _events;
  final Isolate _isolate;
  final String _databasePath;
  final String _sourceId;
  final _control = Completer<SendPort>();
  final _pending = Completer<SourceReady>();
  final _ready = Completer<SourceReady>();
  final _terminal = Completer<void>();
  final _stream = StreamController<ImportWorkerEvent>.broadcast();
  late final StreamSubscription<dynamic> _subscription;
  final Map<SourceMediaKind, int> _counts = {
    for (final kind in SourceMediaKind.values) kind: 0,
  };
  bool _closed = false;

  static Future<InitialSourceImport> startM3u({
    required String databasePath,
    required M3uSourceInput source,
    bool ignoreCancelForTest = false,
  }) async {
    final events = ReceivePort();
    final isolate = await Isolate.spawn<Map<String, Object?>>(
      _initialImportWorker,
      {
        'events': events.sendPort,
        'path': databasePath,
        'ignoreCancel': ignoreCancelForTest,
        'm3u': true,
        'source': {
          'id': source.id,
          'name': source.name,
          'kind': source.databaseKind,
          'locator': source.locator,
          'credentialKey': source.credentialKey,
          'displayEndpoint': source.displayEndpoint,
        },
      },
      errorsAreFatal: true,
    );
    final import = InitialSourceImport._(
      events,
      isolate,
      databasePath,
      source.id,
    );
    import._listen();
    return import;
  }

  static Future<InitialSourceImport> start({
    required String databasePath,
    required SourceDefinition source,
    bool ignoreCancelForTest = false,
  }) async {
    final events = ReceivePort();
    final isolate = await Isolate.spawn<Map<String, Object?>>(
      _initialImportWorker,
      {
        'events': events.sendPort,
        'path': databasePath,
        'ignoreCancel': ignoreCancelForTest,
        'source': {
          'id': source.id,
          'name': source.name,
          'serverUrl': source.serverUrl,
          'username': source.username,
          'password': source.password,
          'credentialKey': source.credentialKey,
          'displayEndpoint': source.displayEndpoint,
        },
      },
      errorsAreFatal: true,
    );
    final import = InitialSourceImport._(
      events,
      isolate,
      databasePath,
      source.id,
    );
    import._listen();
    await import._control.future;
    return import;
  }

  Stream<ImportWorkerEvent> get events => _stream.stream;
  Future<SourceReady> get pending => _pending.future;
  Future<void> get terminal => _terminal.future;

  void _listen() {
    _subscription = _events.listen(
      (dynamic raw) {
        if (raw is SendPort) {
          if (!_control.isCompleted) _control.complete(raw);
          return;
        }
        if (raw is! Map) return;
        final message = raw.cast<Object?, Object?>();
        final event = ImportWorkerEvent.fromMessage(message);
        if (event.kind == ImportWorkerEventKind.stage &&
            event.mediaKind != null) {
          _counts[event.mediaKind!] = event.count ?? _counts[event.mediaKind!]!;
        }
        _stream.add(event);
        switch (event.kind) {
          case ImportWorkerEventKind.pending:
            if (!_pending.isCompleted) {
              _pending.complete(SourceReady(counts: Map.unmodifiable(_counts)));
            }
          case ImportWorkerEventKind.ready:
            final ready = SourceReady(counts: Map.unmodifiable(_counts));
            if (!_pending.isCompleted) _pending.complete(ready);
            if (!_ready.isCompleted) _ready.complete(ready);
            _completeTerminal();
          case ImportWorkerEventKind.failed:
            final error = SourceImportFailure(
              event.failure ?? SourceImportFailureKind.emptyResponse,
            );
            if (!_pending.isCompleted) _pending.completeError(error);
            if (!_ready.isCompleted) _ready.completeError(error);
            _completeTerminal();
          case ImportWorkerEventKind.cancelled:
            final error = const SourceImportFailure(
              SourceImportFailureKind.cancelled,
            );
            if (!_pending.isCompleted) _pending.completeError(error);
            if (!_ready.isCompleted) _ready.completeError(error);
            _completeTerminal();
          case ImportWorkerEventKind.stage:
            break;
        }
      },
      onError: (_, _) {
        final error = const SourceImportFailure(
          SourceImportFailureKind.unreachable,
        );
        if (!_pending.isCompleted) _pending.completeError(error);
        if (!_ready.isCompleted) _ready.completeError(error);
        _completeTerminal();
      },
    );
  }

  Future<SourceReady> activate() async {
    (await _control.future).send(const {'command': 'activate'});
    return _ready.future;
  }

  Future<void> cancel() async {
    (await _control.future).send(const {'command': 'cancel'});
    try {
      await terminal.timeout(_cancelAcknowledgementLimit);
    } on TimeoutException {
      await _forceCancel();
    }
  }

  Future<void> _forceCancel() async {
    if (_closed) return;
    _completeTerminal(
      error: const SourceImportFailure(SourceImportFailureKind.cancelled),
    );
    final databasePath = _databasePath;
    final sourceId = _sourceId;
    await Isolate.run<void>(
      () => _deleteSourceOnWorker(databasePath, sourceId),
    );
  }

  Future<void> cleanup() async {
    (await _control.future).send(const {'command': 'cleanup'});
    await terminal;
  }

  void _completeTerminal({SourceImportFailure? error}) {
    if (_closed) return;
    _closed = true;
    if (error != null) {
      if (!_pending.isCompleted) _pending.completeError(error);
      if (!_ready.isCompleted) _ready.completeError(error);
    }
    if (!_terminal.isCompleted) _terminal.complete();
    unawaited(_subscription.cancel());
    _events.close();
    _stream.close();
    _isolate.kill(priority: Isolate.immediate);
  }
}

class M3uRefreshImport {
  M3uRefreshImport._(
    this._events,
    this._isolate,
    this._databasePath,
    this._sourceId,
  ) {
    _subscription = _events.listen((raw) {
      if (_closed) return;
      if (raw is SendPort) {
        if (!_control.isCompleted) _control.complete(raw);
        return;
      }
      // Isolate error messages arrive as a two-value list and an exit without
      // a normal terminal event arrives as null. Neither may strand the UI in
      // Refreshing or leave this source's marker busy until an app restart.
      if (raw == null || raw is List) {
        unawaited(_completeAbnormally());
        return;
      }
      if (raw is! Map) return;
      final message = raw.cast<Object?, Object?>();
      switch (message['type']) {
        case 'ready':
          if (!_done.isCompleted) {
            _done.complete(
              SourceReady(
                counts: {SourceMediaKind.live: message['count'] as int},
              ),
            );
          }
          _close();
        case 'cancelled':
          if (!_done.isCompleted) {
            _done.completeError(
              const SourceImportFailure(SourceImportFailureKind.cancelled),
            );
          }
          _close();
        default:
          if (!_done.isCompleted) {
            _done.completeError(
              SourceImportFailure(
                SourceImportFailureKind.values.byName(
                  message['failure'] as String,
                ),
              ),
            );
          }
          _close();
      }
    });
  }
  final ReceivePort _events;
  final Isolate _isolate;
  final String _databasePath;
  final String _sourceId;
  final _control = Completer<SendPort>();
  final _done = Completer<SourceReady>();
  late final StreamSubscription<dynamic> _subscription;
  bool _closed = false;
  bool _recoveringAbnormalExit = false;
  Future<SourceReady> get completed => _done.future;
  static Future<M3uRefreshImport> start({
    required String path,
    required String sourceId,
    required String locator,
    required bool isUrl,
    bool exitImmediatelyForTest = false,
  }) async {
    final events = ReceivePort();
    final isolate = await Isolate.spawn<Map<String, Object?>>(
      _m3uRefreshWorker,
      {
        'events': events.sendPort,
        'path': path,
        'sourceId': sourceId,
        'locator': locator,
        'isUrl': isUrl,
        'exitImmediatelyForTest': exitImmediatelyForTest,
      },
      onError: events.sendPort,
      onExit: events.sendPort,
      errorsAreFatal: true,
    );
    return M3uRefreshImport._(events, isolate, path, sourceId);
  }

  Future<void> cancel() async {
    (await _control.future).send(const {'command': 'cancel'});
  }

  Future<void> _completeAbnormally() async {
    // Fatal isolate errors are followed by an exit event. Coalesce both
    // notifications before scheduling the recovery write.
    if (_closed || _recoveringAbnormalExit) return;
    _recoveringAbnormalExit = true;
    // The refresh has not crossed its commit transaction. Restoring only this
    // source exposes its intact last-good generation and makes Retry usable.
    final databasePath = _databasePath;
    final sourceId = _sourceId;
    try {
      await Isolate.run<void>(
        () => _recoverAbnormalRefreshOnWorker(databasePath, sourceId),
      );
    } catch (_) {
      // The terminal result must still reach the parent; startup recovery is
      // the bounded final fallback if the database itself is unavailable.
    }
    if (!_done.isCompleted) {
      _done.completeError(
        const SourceImportFailure(SourceImportFailureKind.unreachable),
      );
    }
    _close();
  }

  void _close() {
    if (_closed) return;
    _closed = true;
    _isolate.kill(priority: Isolate.immediate);
    unawaited(_subscription.cancel());
    _events.close();
  }
}

/// Cancellable, worker-owned Xtream refresh. Credentials enter only this
/// isolate and parsed catalog lists never return to UI code.
class XtreamRefreshImport {
  static Future<M3uRefreshImport> start({
    required String path,
    required String sourceId,
    required String serverUrl,
    required String username,
    required String password,
  }) async {
    final events = ReceivePort();
    final isolate = await Isolate.spawn<Map<String, Object?>>(
      _xtreamRefreshWorker,
      {
        'events': events.sendPort,
        'path': path,
        'sourceId': sourceId,
        'serverUrl': serverUrl,
        'username': username,
        'password': password,
      },
      onError: events.sendPort,
      onExit: events.sendPort,
      errorsAreFatal: true,
    );
    return M3uRefreshImport._(events, isolate, path, sourceId);
  }
}

void _xtreamRefreshWorker(Map<String, Object?> args) async {
  final events = args['events']! as SendPort;
  final control = ReceivePort();
  events.send(control.sendPort);
  var cancelled = false;
  final client = HttpClient();
  control.listen((raw) {
    if (raw is Map && raw['command'] == 'cancel') {
      cancelled = true;
      client.close(force: true);
    }
  });
  SourceRefresh? refresh;
  try {
    final path = args['path']! as String;
    refresh = _beginRefreshOnWorker(path, args['sourceId']! as String);
    if (refresh == null) {
      throw const SourceImportFailure(SourceImportFailureKind.emptyResponse);
    }
    final endpoint = Uri.parse(args['serverUrl']! as String);
    final deadline = DateTime.now().add(_importLimit);
    final stages = <ImportedStage>[];
    for (final kind in SourceMediaKind.values) {
      final categories = _parseCategories(
        await _refreshJson(
          client,
          endpoint,
          args['username']! as String,
          args['password']! as String,
          kind.categoryAction,
          _accountAndCategoryLimit,
          deadline,
          () => cancelled,
        ),
      );
      final raw = await _refreshJson(
        client,
        endpoint,
        args['username']! as String,
        args['password']! as String,
        kind.xtreamAction,
        _itemLimit,
        deadline,
        () => cancelled,
      );
      if (raw is! List || raw.isEmpty) {
        throw const SourceImportFailure(SourceImportFailureKind.emptyResponse);
      }
      stages.add(
        ImportedStage(
          kind: kind,
          categories: categories,
          items: _parseItems(kind, raw.cast<Object?>()),
        ),
      );
    }
    if (cancelled) {
      throw const SourceImportFailure(SourceImportFailureKind.cancelled);
    }
    final ready = _commitRefreshOnWorker(path, refresh, stages);
    events.send({
      'type': 'ready',
      'count': ready.counts[SourceMediaKind.live] ?? 0,
    });
  } on SourceImportFailure catch (error) {
    if (refresh != null) {
      _failRefreshOnWorker(
        args['path']! as String,
        refresh,
        SourceRefreshFailure.values.byName(error.kind.name),
      );
    }
    events.send({
      'type': error.kind == SourceImportFailureKind.cancelled
          ? 'cancelled'
          : 'failed',
      'failure': error.kind.name,
    });
  } catch (_) {
    if (refresh != null) {
      _failRefreshOnWorker(
        args['path']! as String,
        refresh,
        cancelled
            ? SourceRefreshFailure.cancelled
            : SourceRefreshFailure.unreachable,
      );
    }
    events.send({
      'type': cancelled ? 'cancelled' : 'failed',
      'failure':
          (cancelled
                  ? SourceImportFailureKind.cancelled
                  : SourceImportFailureKind.unreachable)
              .name,
    });
  } finally {
    client.close(force: true);
    control.close();
  }
}

Future<Object?> _refreshJson(
  HttpClient client,
  Uri endpoint,
  String username,
  String password,
  String action,
  int max,
  DateTime deadline,
  bool Function() cancelled,
) async {
  if (cancelled()) {
    throw const SourceImportFailure(SourceImportFailureKind.cancelled);
  }
  final path = endpoint.path.endsWith('/')
      ? '${endpoint.path}player_api.php'
      : '${endpoint.path}/player_api.php';
  final uri = endpoint.replace(
    path: path,
    queryParameters: {
      ...endpoint.queryParameters,
      'username': username,
      'password': password,
      'action': action,
    },
  );
  final remaining = deadline.difference(DateTime.now());
  if (remaining <= Duration.zero) throw TimeoutException('refresh-timeout');
  final response = await (await client.getUrl(uri).timeout(remaining))
      .close()
      .timeout(remaining);
  if (response.statusCode == 401 || response.statusCode == 403) {
    throw const SourceImportFailure(SourceImportFailureKind.authentication);
  }
  if (response.statusCode < 200 || response.statusCode >= 300) {
    throw HttpException('request');
  }
  final bytes = BytesBuilder();
  await for (final chunk in response) {
    if (cancelled()) {
      throw const SourceImportFailure(SourceImportFailureKind.cancelled);
    }
    if (bytes.length + chunk.length > max) {
      throw const SourceImportFailure(SourceImportFailureKind.tooLarge);
    }
    bytes.add(chunk);
  }
  final text = utf8.decode(bytes.takeBytes());
  if (text.trim().isEmpty) {
    throw const SourceImportFailure(SourceImportFailureKind.emptyResponse);
  }
  return jsonDecode(text);
}

void _m3uRefreshWorker(Map<String, Object?> args) async {
  final events = args['events']! as SendPort;
  final control = ReceivePort();
  events.send(control.sendPort);
  if (args['exitImmediatelyForTest'] == true) Isolate.exit();
  var cancelled = false;
  HttpClient? client;
  control.listen((raw) {
    if (raw is Map && raw['command'] == 'cancel') {
      cancelled = true;
      client?.close(force: true);
    }
  });
  SourceRefresh? refresh;
  try {
    final path = args['path']! as String;
    final sourceId = args['sourceId']! as String;
    refresh = _beginRefreshOnWorker(path, sourceId);
    if (refresh == null) {
      throw const SourceImportFailure(SourceImportFailureKind.emptyResponse);
    }
    client = HttpClient();
    final connector = M3uConnector();
    final stage = args['isUrl']! as bool
        ? await connector.importUrl(
            url: Uri.parse(args['locator']! as String),
            sourceId: sourceId,
            isCancelled: () => cancelled,
            httpClient: client,
          )
        : await connector.importFile(
            path: args['locator']! as String,
            sourceId: sourceId,
            isCancelled: () => cancelled,
          );
    if (cancelled) {
      throw const SourceImportFailure(SourceImportFailureKind.cancelled);
    }
    final ready = _commitRefreshOnWorker(path, refresh, [stage]);
    events.send({
      'type': 'ready',
      'count': ready.counts[SourceMediaKind.live] ?? 0,
    });
  } on SourceImportFailure catch (error) {
    if (refresh != null) {
      _failRefreshOnWorker(
        args['path']! as String,
        refresh,
        SourceRefreshFailure.values.byName(error.kind.name),
      );
    }
    events.send({
      'type': error.kind == SourceImportFailureKind.cancelled
          ? 'cancelled'
          : 'failed',
      'failure': error.kind.name,
    });
  } catch (_) {
    if (refresh != null) {
      _failRefreshOnWorker(
        args['path']! as String,
        refresh,
        cancelled
            ? SourceRefreshFailure.cancelled
            : SourceRefreshFailure.unreachable,
      );
    }
    events.send({
      'type': cancelled ? 'cancelled' : 'failed',
      'failure':
          (cancelled
                  ? SourceImportFailureKind.cancelled
                  : SourceImportFailureKind.unreachable)
              .name,
    });
  } finally {
    client?.close(force: true);
    control.close();
  }
}

class SourceCatalogDatabase {
  const SourceCatalogDatabase({
    this.databasePath,
    this.ignoreCancelForTest = false,
  });
  final String? databasePath;
  final bool ignoreCancelForTest;

  Future<InitialSourceImport> beginM3uInitialImport(
    M3uSourceInput source,
  ) async => InitialSourceImport.startM3u(
    databasePath: await resolvedPath(),
    source: source,
    ignoreCancelForTest: ignoreCancelForTest,
  );
  Future<InitialSourceImport> beginInitialImport(
    SourceDefinition source,
  ) async => InitialSourceImport.start(
    databasePath: await resolvedPath(),
    source: source,
    ignoreCancelForTest: ignoreCancelForTest,
  );

  Future<String> resolvedPath() async {
    if (databasePath != null) return databasePath!;
    final directory = await getApplicationSupportDirectory();
    await directory.create(recursive: true);
    return '${directory.path}${Platform.pathSeparator}wabbit_tv.sqlite';
  }

  /// Startup only: remove a source that never crossed credential + activation.
  Future<void> recoverPending(CredentialStore credentials) async {
    final path = await resolvedPath();
    final pending = await Isolate.run<List<Map<String, String>>>(
      () => _pendingOnWorker(path),
    );
    for (final source in pending) {
      try {
        await credentials.delete(source['credentialKey']!);
      } catch (_) {
        // A failed OS credential deletion must not preserve an unusable pending DB row.
      }
      await Isolate.run<void>(() => _deleteSourceOnWorker(path, source['id']!));
    }
    await Isolate.run<void>(() => _recoverInterruptedRefreshesOnWorker(path));
  }

  Future<PersistedSource?> loadReadySource() async {
    final path = await resolvedPath();
    return Isolate.run<PersistedSource?>(() => _loadReadyOnWorker(path));
  }

  /// Resolves the playable source selected by a library row without exposing
  /// credentials on that row. Disabled or non-ready sources return null.
  Future<PersistedSource?> loadReadySourceById(String sourceId) async {
    final path = await resolvedPath();
    return Isolate.run<PersistedSource?>(
      () => _loadReadyOnWorker(path, sourceId: sourceId),
    );
  }

  /// Reads a small, credential-free roster for source-management callers.
  /// This includes disabled sources so callers can offer enable/remove actions.
  Future<List<SourceRosterEntry>> loadSourceRoster({
    int limit = _defaultSourceRosterLimit,
  }) async {
    final path = await resolvedPath();
    final boundedLimit = limit.clamp(1, _maximumSourceRosterLimit);
    return Isolate.run<List<SourceRosterEntry>>(
      () => _loadSourceRosterOnWorker(path, boundedLimit),
    );
  }

  /// Returns the categories that can actually be browsed for one ready source.
  /// The first summary is the complete available catalog for [kind].
  Future<List<BrowseCategorySummary>> browseCategories({
    required String sourceId,
    required SourceMediaKind kind,
  }) async {
    final path = await resolvedPath();
    return Isolate.run<List<BrowseCategorySummary>>(
      () => _browseCategoriesOnWorker(path, sourceId, kind),
    );
  }

  /// Reads one bounded, title-ordered catalog page without resolving source
  /// credentials or turning a playback reference into a final stream URL.
  Future<BrowsePage> browsePage({
    required String sourceId,
    required SourceMediaKind kind,
    BrowseCategorySelection selection = const BrowseCategorySelection.all(),
    BrowseCursor? cursor,
    int limit = _defaultBrowsePageLimit,
  }) async {
    final path = await resolvedPath();
    final boundedLimit = limit.clamp(1, _maximumBrowsePageLimit);
    return Isolate.run<BrowsePage>(
      () => _browsePageOnWorker(
        path,
        sourceId,
        kind,
        selection,
        cursor,
        boundedLimit,
      ),
    );
  }

  /// Reads a bounded source-local category directory for visibility
  /// maintenance. Unlike ordinary Browse, hidden categories remain present so
  /// the user can restore them. `hiddenOnly` is the recovery filter.
  Future<List<SourceVisibilityCategory>> loadVisibilityCategories({
    required String sourceId,
    required SourceMediaKind kind,
    bool hiddenOnly = false,
    int limit = _defaultVisibilityCategoryLimit,
  }) async {
    final path = await resolvedPath();
    return Isolate.run<List<SourceVisibilityCategory>>(
      () => _loadVisibilityCategoriesOnWorker(
        path,
        sourceId,
        kind,
        hiddenOnly,
        limit.clamp(1, _maximumVisibilityCategoryLimit),
      ),
    );
  }

  /// Reads one bounded title-ordered visibility ledger page. This intentionally
  /// does not apply category visibility: a hidden category must still expose
  /// its individual item preferences for restoration.
  Future<SourceVisibilityPage> loadVisibilityItems({
    required String sourceId,
    required SourceMediaKind kind,
    required BrowseCategorySelection selection,
    bool hiddenOnly = false,
    BrowseCursor? cursor,
    int limit = _defaultBrowsePageLimit,
  }) async {
    final path = await resolvedPath();
    return Isolate.run<SourceVisibilityPage>(
      () => _loadVisibilityItemsOnWorker(
        path,
        sourceId,
        kind,
        selection,
        hiddenOnly,
        cursor,
        limit.clamp(1, _maximumBrowsePageLimit),
      ),
    );
  }

  /// Persists source/category-local inclusion without touching item choices.
  Future<void> setSourceGroupHidden({
    required String sourceId,
    required SourceMediaKind kind,
    required int sourceGroupId,
    required bool hidden,
  }) async {
    final path = await resolvedPath();
    await Isolate.run<void>(
      () => _setSourceGroupHiddenOnWorker(
        path,
        sourceId,
        kind,
        sourceGroupId,
        hidden,
      ),
    );
  }

  /// Applies one category visibility value to every provider group belonging
  /// to one source and media kind. Uncategorized and per-item preferences are
  /// not source-group rows and are therefore deliberately untouched.
  Future<int> setAllCategoriesHidden({
    required String sourceId,
    required SourceMediaKind kind,
    required bool hidden,
  }) async {
    final path = await resolvedPath();
    return Isolate.run<int>(
      () => _setAllCategoriesHiddenOnWorker(path, sourceId, kind, hidden),
    );
  }

  /// Persists one imported item's source-local inclusion. [catalogItemId] is
  /// additionally constrained by [sourceId], so callers cannot change another
  /// source's item through a stale selection.
  Future<void> setCatalogItemHidden({
    required String sourceId,
    required String catalogItemId,
    required bool hidden,
  }) async {
    final path = await resolvedPath();
    await Isolate.run<void>(
      () =>
          _setCatalogItemHiddenOnWorker(path, sourceId, catalogItemId, hidden),
    );
  }

  /// Reads a bounded library page across all active sources or one source.
  Future<LibraryPage> browseLibraryPage({
    required LibraryScope scope,
    required SourceMediaKind kind,
    BrowseCursor? cursor,
    int limit = _defaultBrowsePageLimit,
  }) async {
    final path = await resolvedPath();
    return Isolate.run<LibraryPage>(
      () => _libraryPageOnWorker(
        path,
        scope,
        kind,
        cursor,
        limit.clamp(1, _maximumBrowsePageLimit),
      ),
    );
  }

  /// Searches title and nonsecret supporting text with literal FTS tokens.
  Future<LibraryPage> searchLibraryPage({
    required String query,
    required LibraryScope scope,
    SourceMediaKind? kind,
    BrowseCursor? cursor,
    int limit = _defaultBrowsePageLimit,
  }) async {
    final path = await resolvedPath();
    return Isolate.run<LibraryPage>(
      () => _libraryPageOnWorker(
        path,
        scope,
        kind,
        cursor,
        limit.clamp(1, _maximumBrowsePageLimit),
        query: query,
      ),
    );
  }

  /// Counts active library identities in SQL without materializing a page.
  /// Omitting [kind] permits the mixed Live/Movie/Series Search total.
  Future<int> countLibraryItems({
    required LibraryScope scope,
    SourceMediaKind? kind,
    String? query,
  }) async {
    final path = await resolvedPath();
    return Isolate.run<int>(
      () => _countLibraryItemsOnWorker(path, scope, kind: kind, query: query),
    );
  }

  /// Loads the one global catalog scope. Stale source selections normalize to
  /// All sources so re-enabling a source cannot unexpectedly restore it.
  Future<LibraryScope> loadCatalogScope() async {
    final path = await resolvedPath();
    return Isolate.run<LibraryScope>(() => _loadCatalogScopeOnWorker(path));
  }

  /// Persists All sources or one currently enabled local source. An invalid
  /// source selection is normalized to All sources and returned to the caller.
  Future<LibraryScope> saveCatalogScope(LibraryScope scope) async {
    final path = await resolvedPath();
    return Isolate.run<LibraryScope>(
      () => _saveCatalogScopeOnWorker(path, scope),
    );
  }

  // Compatibility seam for existing isolated database tests. Production uses
  // beginInitialImport so decode and writes never cross isolates.
  Future<SourceReady> commitInitialSource(
    SourceDefinition source,
    List<ImportedStage> stages,
  ) async {
    final path = await resolvedPath();
    return Isolate.run<SourceReady>(
      () => _commitFixtureOnWorker(path, source, stages),
    );
  }

  Future<M3uRefreshImport> beginM3uRefresh({
    required String sourceId,
    required String locator,
    required bool isUrl,
  }) async => M3uRefreshImport.start(
    path: await resolvedPath(),
    sourceId: sourceId,
    locator: locator,
    isUrl: isUrl,
  );

  Future<M3uRefreshImport> beginXtreamRefresh({
    required String sourceId,
    required String serverUrl,
    required String username,
    required String password,
  }) async => XtreamRefreshImport.start(
    path: await resolvedPath(),
    sourceId: sourceId,
    serverUrl: serverUrl,
    username: username,
    password: password,
  );

  Future<SourceOperationRecord?> loadSourceOperation(String sourceId) async {
    final path = await resolvedPath();
    return Isolate.run(() => _loadSourceOperationOnWorker(path, sourceId));
  }

  Future<void> removeInitialSource(String sourceId) async {
    await removeSource(sourceId);
  }

  Future<void> renameSource(String sourceId, String name) async {
    final path = await resolvedPath();
    await Isolate.run<void>(() => _renameSourceOnWorker(path, sourceId, name));
  }

  Future<void> setSourceEnabled(String sourceId, bool enabled) async {
    final path = await resolvedPath();
    await Isolate.run<void>(
      () => _setSourceEnabledOnWorker(path, sourceId, enabled),
    );
  }

  Future<void> removeSource(String sourceId) async {
    final path = await resolvedPath();
    await Isolate.run<void>(() => _deleteSourceOnWorker(path, sourceId));
  }

  /// Reserves a new generation without touching the last usable catalog.
  Future<SourceRefresh?> beginRefresh(String sourceId) async {
    final path = await resolvedPath();
    return Isolate.run<SourceRefresh?>(
      () => _beginRefreshOnWorker(path, sourceId),
    );
  }

  /// Atomically makes a fully parsed generation current for one source.
  Future<SourceReady> commitRefresh(
    SourceRefresh refresh,
    List<ImportedStage> stages,
  ) async {
    final path = await resolvedPath();
    return Isolate.run<SourceReady>(
      () => _commitRefreshOnWorker(path, refresh, stages),
    );
  }

  /// Abandons a reserved generation while retaining the last ready catalog.
  Future<void> failRefresh(
    SourceRefresh refresh,
    SourceRefreshFailure failure,
  ) async {
    final path = await resolvedPath();
    await Isolate.run<void>(() => _failRefreshOnWorker(path, refresh, failure));
  }
}

void _initialImportWorker(Map<String, Object?> args) {
  final worker = _InitialImportWorker(args);
  worker.start();
}

class _InitialImportWorker {
  _InitialImportWorker(this.args)
    : isM3u = args['m3u'] == true,
      ignoreCancel = args['ignoreCancel']! as bool,
      events = args['events']! as SendPort,
      path = args['path']! as String,
      source = (args['source']! as Map<Object?, Object?>)
          .cast<String, Object?>();

  final Map<String, Object?> args;
  final bool isM3u;
  final bool ignoreCancel;
  final SendPort events;
  final String path;
  final Map<String, Object?> source;
  final ReceivePort control = ReceivePort();
  final Map<SourceMediaKind, int> counts = {};
  HttpClient? client;
  Database? db;
  bool cancelled = false;
  bool finished = false;

  void start() {
    events.send(control.sendPort);
    control.listen(_command);
    unawaited(_run());
  }

  void _command(dynamic raw) {
    if (raw is! Map || finished) return;
    final command = raw['command'];
    if (command == 'cancel' || command == 'cleanup') {
      if (ignoreCancel) return;
      cancelled = true;
      client?.close(force: true);
      if (db != null) {
        unawaited(_cleanupAndFinish(cancelledEvent: command == 'cancel'));
      }
    } else if (command == 'activate') {
      unawaited(_activate());
    }
  }

  Future<void> _run() async {
    try {
      db = _openDatabase(path);
      _createPending(db!, source);
      client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
      if (isM3u) {
        _throwIfCancelled();
        events.send({'type': 'stage', 'kind': SourceMediaKind.live.name});
        final connector = M3uConnector();
        final stage = source['kind'] == 'm3u_url'
            ? await connector.importUrl(
                url: Uri.parse(source['locator']! as String),
                sourceId: source['id']! as String,
                isCancelled: () => cancelled,
                httpClient: client,
              )
            : await connector.importFile(
                path: source['locator']! as String,
                sourceId: source['id']! as String,
                isCancelled: () => cancelled,
              );
        _throwIfCancelled();
        _writeStage(
          db!,
          source['id']! as String,
          stage.kind,
          stage.categories,
          stage.items,
        );
        counts[SourceMediaKind.live] = stage.itemCount;
        client?.close(force: true);
        client = null;
        events.send({
          'type': 'stage',
          'kind': SourceMediaKind.live.name,
          'count': stage.itemCount,
        });
        events.send(const {'type': 'pending'});
        return;
      }
      final deadline = DateTime.now().add(_importLimit);
      final endpoint = Uri.parse(source['serverUrl']! as String);
      final username = source['username']! as String;
      final password = source['password']! as String;
      final account = await _getJson(
        endpoint,
        username,
        password,
        null,
        _accountAndCategoryLimit,
        deadline,
      );
      if (!_isAuthorized(account)) {
        throw const SourceImportFailure(SourceImportFailureKind.authentication);
      }
      for (final kind in SourceMediaKind.values) {
        _throwIfCancelled();
        events.send({'type': 'stage', 'kind': kind.name});
        final categories = await _getJson(
          endpoint,
          username,
          password,
          kind.categoryAction,
          _accountAndCategoryLimit,
          deadline,
        );
        _throwIfCancelled();
        final rawItems = await _getJson(
          endpoint,
          username,
          password,
          kind.xtreamAction,
          _itemLimit,
          deadline,
        );
        if (rawItems is! List || rawItems.isEmpty) {
          throw const SourceImportFailure(
            SourceImportFailureKind.emptyResponse,
          );
        }
        final items = _parseItems(kind, rawItems.cast<Object?>());
        if (items.isEmpty) {
          throw const SourceImportFailure(
            SourceImportFailureKind.emptyResponse,
          );
        }
        _writeStage(
          db!,
          source['id']! as String,
          kind,
          _parseCategories(categories),
          items,
        );
        counts[kind] = items.length;
        events.send({
          'type': 'stage',
          'kind': kind.name,
          'count': items.length,
        });
      }
      client?.close(force: true);
      client = null;
      _throwIfCancelled();
      events.send(const {'type': 'pending'});
    } on SourceImportFailure catch (error) {
      await _cleanupAndFinish(failure: error.kind);
    } on SocketException {
      await _cleanupAndFinish(
        failure: cancelled
            ? SourceImportFailureKind.cancelled
            : SourceImportFailureKind.unreachable,
      );
    } on HttpException {
      await _cleanupAndFinish(
        failure: cancelled
            ? SourceImportFailureKind.cancelled
            : SourceImportFailureKind.unreachable,
      );
    } on TimeoutException {
      await _cleanupAndFinish(
        failure: cancelled
            ? SourceImportFailureKind.cancelled
            : SourceImportFailureKind.timedOut,
      );
    } on FormatException {
      await _cleanupAndFinish(failure: SourceImportFailureKind.emptyResponse);
    } catch (_) {
      await _cleanupAndFinish(
        failure: cancelled
            ? SourceImportFailureKind.cancelled
            : SourceImportFailureKind.emptyResponse,
      );
    }
  }

  Future<void> _activate() async {
    if (finished ||
        cancelled ||
        db == null ||
        counts.length != (isM3u ? 1 : SourceMediaKind.values.length)) {
      return;
    }
    try {
      db!.execute('BEGIN IMMEDIATE');
      db!.execute(
        "UPDATE sources SET enabled = 1, refresh_state = 'ready', last_refresh_at = ? WHERE id = ?",
        [DateTime.now().toUtc().toIso8601String(), source['id']],
      );
      db!.execute('COMMIT');
      finished = true;
      // The parent treats `ready` as permission to read the catalog. Release
      // this worker's SQLite handle first so a freshly activated source never
      // races its own first roster/browse read.
      _close();
      events.send(const {'type': 'ready'});
    } catch (_) {
      try {
        db!.execute('ROLLBACK');
      } catch (_) {}
      await _cleanupAndFinish(failure: SourceImportFailureKind.emptyResponse);
    }
  }

  Future<void> _cleanupAndFinish({
    SourceImportFailureKind? failure,
    bool cancelledEvent = false,
  }) async {
    if (finished) return;
    finished = true;
    client?.close(force: true);
    client = null;
    if (db != null) {
      try {
        _deleteSource(db!, source['id']! as String);
      } catch (_) {}
    }
    final terminal = {
      'type':
          cancelledEvent ||
              cancelled ||
              failure == SourceImportFailureKind.cancelled
          ? 'cancelled'
          : 'failed',
      if (!(cancelledEvent ||
          cancelled ||
          failure == SourceImportFailureKind.cancelled))
        'failure': (failure ?? SourceImportFailureKind.emptyResponse).name,
    };
    _close();
    events.send(terminal);
  }

  void _close() {
    db?.close();
    db = null;
    control.close();
  }

  void _throwIfCancelled() {
    if (cancelled) {
      throw const SourceImportFailure(SourceImportFailureKind.cancelled);
    }
  }

  Future<Object?> _getJson(
    Uri endpoint,
    String username,
    String password,
    String? action,
    int maxBytes,
    DateTime deadline,
  ) async {
    _throwIfCancelled();
    final requestDeadline = _boundedDeadline(deadline);
    final path = endpoint.path.endsWith('/')
        ? '${endpoint.path}player_api.php'
        : '${endpoint.path}/player_api.php';
    final query = <String, String>{
      ...endpoint.queryParameters,
      'username': username,
      'password': password,
      'action': ?action,
    };
    final uri = endpoint.replace(path: path, queryParameters: query);
    final request = await client!
        .getUrl(uri)
        .timeout(_remainingDeadline(requestDeadline));
    final response = await request.close().timeout(
      _remainingDeadline(requestDeadline),
    );
    if (response.statusCode == HttpStatus.unauthorized ||
        response.statusCode == HttpStatus.forbidden) {
      throw const SourceImportFailure(SourceImportFailureKind.authentication);
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw HttpException('request-failed');
    }
    if (response.contentLength > maxBytes) {
      throw const SourceImportFailure(SourceImportFailureKind.tooLarge);
    }
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in response.timeout(
      _remainingDeadline(requestDeadline),
    )) {
      _throwIfCancelled();
      _remainingDeadline(requestDeadline);
      if (bytes.length + chunk.length > maxBytes) {
        throw const SourceImportFailure(SourceImportFailureKind.tooLarge);
      }
      bytes.add(chunk);
    }
    final text = utf8.decode(bytes.takeBytes());
    if (text.trim().isEmpty) {
      throw const SourceImportFailure(SourceImportFailureKind.emptyResponse);
    }
    return jsonDecode(text);
  }

  DateTime _boundedDeadline(DateTime importDeadline) {
    final requestDeadline = DateTime.now().add(_requestLimit);
    return requestDeadline.isBefore(importDeadline)
        ? requestDeadline
        : importDeadline;
  }

  Duration _remainingDeadline(DateTime deadline) {
    final remaining = deadline.difference(DateTime.now());
    if (remaining <= Duration.zero) throw TimeoutException('import-timeout');
    return remaining;
  }
}

List<Map<String, String>> _pendingOnWorker(String path) {
  if (!File(path).existsSync()) return const [];
  final db = _openDatabase(path);
  try {
    return db
        .select(
          "SELECT id, credential_key FROM sources WHERE refresh_state = 'pending'",
        )
        .map(
          (row) => {
            'id': row['id']! as String,
            'credentialKey': row['credential_key']! as String,
          },
        )
        .toList();
  } finally {
    db.close();
  }
}

PersistedSource? _loadReadyOnWorker(String path, {String? sourceId}) {
  if (!File(path).existsSync()) return null;
  final db = _openDatabase(path);
  try {
    final source = db.select('''SELECT id, name, credential_key FROM sources
         WHERE enabled = 1
           AND refresh_state IN ('ready', 'refreshing')
           ${sourceId == null ? '' : 'AND id = ?'}
         ORDER BY last_refresh_at DESC, id ASC
         LIMIT 1''', sourceId == null ? const [] : [sourceId]);
    if (source.isEmpty) return null;
    final row = source.single;
    final totals = db.select(
      'SELECT kind, COUNT(*) AS count FROM catalog_items WHERE source_id = ? AND available = 1 GROUP BY kind',
      [row['id']],
    );
    final counts = {for (final kind in SourceMediaKind.values) kind: 0};
    for (final total in totals) {
      counts[SourceMediaKind.values.byName(total['kind']! as String)] =
          total['count']! as int;
    }
    return PersistedSource(
      id: row['id']! as String,
      name: row['name']! as String,
      credentialKey: row['credential_key']! as String,
      counts: counts,
    );
  } finally {
    db.close();
  }
}

SourceOperationRecord? _loadSourceOperationOnWorker(
  String path,
  String sourceId,
) {
  if (!File(path).existsSync()) return null;
  final db = _openDatabase(path);
  try {
    final rows = db.select(
      'SELECT id, kind, credential_key FROM sources WHERE id = ?',
      [sourceId],
    );
    if (rows.isEmpty) return null;
    final row = rows.single;
    return SourceOperationRecord(
      id: row['id']! as String,
      kind: row['kind']! as String,
      credentialKey: row['credential_key']! as String,
    );
  } finally {
    db.close();
  }
}

List<SourceRosterEntry> _loadSourceRosterOnWorker(String path, int limit) {
  if (!File(path).existsSync()) return const [];
  final db = _openDatabase(path);
  try {
    final sources = db.select(
      '''SELECT id, name, kind, enabled, refresh_state, last_error
         FROM sources
         ORDER BY enabled DESC, last_refresh_at DESC, id ASC
         LIMIT ?''',
      [limit],
    );
    final totals = db.select(
      '''SELECT source_id, kind, COUNT(*) AS count
         FROM catalog_items
         WHERE available = 1 AND source_id IN (
           SELECT id FROM sources
           ORDER BY enabled DESC, last_refresh_at DESC, id ASC
           LIMIT ?
         )
         GROUP BY source_id, kind''',
      [limit],
    );
    final countsBySource = <String, Map<SourceMediaKind, int>>{};
    for (final total in totals) {
      final sourceId = total['source_id']! as String;
      final counts = countsBySource.putIfAbsent(
        sourceId,
        () => {for (final kind in SourceMediaKind.values) kind: 0},
      );
      counts[SourceMediaKind.values.byName(total['kind']! as String)] =
          total['count']! as int;
    }
    return List.unmodifiable(
      sources.map((row) {
        final sourceId = row['id']! as String;
        return SourceRosterEntry(
          id: sourceId,
          name: row['name']! as String,
          kind: row['kind']! as String,
          enabled: row['enabled']! as int == 1,
          status: _rosterStatus(
            row['refresh_state']! as String,
            row['last_error'] as String?,
          ),
          counts: Map.unmodifiable(
            countsBySource[sourceId] ??
                {for (final kind in SourceMediaKind.values) kind: 0},
          ),
        );
      }),
    );
  } finally {
    db.close();
  }
}

String _rosterStatus(String refreshState, String? lastError) {
  final isTypedFailure =
      lastError != null &&
      SourceRefreshFailure.values.any((failure) => failure.name == lastError);
  return isTypedFailure ? 'refresh_failed' : refreshState;
}

List<SourceVisibilityCategory> _loadVisibilityCategoriesOnWorker(
  String path,
  String sourceId,
  SourceMediaKind kind,
  bool hiddenOnly,
  int limit,
) {
  if (!File(path).existsSync()) return const [];
  final db = _openDatabase(path);
  try {
    final ready = db.select(
      "SELECT id FROM sources WHERE id = ? AND refresh_state IN ('ready', 'refreshing')",
      [sourceId],
    );
    if (ready.isEmpty) return const [];
    final hiddenFilter = hiddenOnly
        ? '''AND (groups.hidden = 1 OR EXISTS (
               SELECT 1 FROM catalog_items AS hidden_items
               WHERE hidden_items.source_group_id = groups.id
                 AND hidden_items.available = 1
                 AND hidden_items.hidden = 1
             ))'''
        : '';
    final rows = db.select(
      '''SELECT groups.id, groups.name, groups.hidden,
                COUNT(items.id) AS item_count,
                COALESCE(SUM(CASE WHEN items.hidden = 1 THEN 1 ELSE 0 END), 0)
                  AS hidden_item_count
         FROM source_groups AS groups
         LEFT JOIN catalog_items AS items
           ON items.source_group_id = groups.id
          AND items.available = 1
         WHERE groups.source_id = ? AND groups.content_kind = ?
           AND groups.available = 1
           $hiddenFilter
         GROUP BY groups.id
         ORDER BY groups.sort_key ASC, groups.id ASC
         LIMIT ?''',
      [sourceId, kind.name, limit],
    );
    final categories = rows
        .map(
          (row) => SourceVisibilityCategory(
            selection: BrowseCategorySelection.sourceGroup(row['id']! as int),
            name: row['name']! as String,
            itemCount: row['item_count']! as int,
            hiddenItemCount: row['hidden_item_count']! as int,
            isHidden: row['hidden']! as int == 1,
          ),
        )
        .toList(growable: true);

    // Uncategorized is a real item slice, not a synthetic provider group. It
    // can only be individually hidden, and remains available as recovery data.
    final uncategorized = db
        .select(
          '''SELECT COUNT(*) AS item_count,
                COALESCE(SUM(CASE WHEN hidden = 1 THEN 1 ELSE 0 END), 0)
                  AS hidden_item_count
         FROM catalog_items
         WHERE source_id = ? AND kind = ? AND available = 1
           AND source_group_id IS NULL''',
          [sourceId, kind.name],
        )
        .single;
    final itemCount = uncategorized['item_count']! as int;
    final hiddenItemCount = uncategorized['hidden_item_count']! as int;
    if (itemCount > 0 && (!hiddenOnly || hiddenItemCount > 0)) {
      categories.add(
        SourceVisibilityCategory(
          selection: const BrowseCategorySelection.uncategorized(),
          name: 'Uncategorized',
          itemCount: itemCount,
          hiddenItemCount: hiddenItemCount,
          isHidden: false,
        ),
      );
    }
    return List.unmodifiable(categories);
  } finally {
    db.close();
  }
}

SourceVisibilityPage _loadVisibilityItemsOnWorker(
  String path,
  String sourceId,
  SourceMediaKind kind,
  BrowseCategorySelection selection,
  bool hiddenOnly,
  BrowseCursor? cursor,
  int limit,
) {
  if (!File(path).existsSync()) {
    return const SourceVisibilityPage(items: [], nextCursor: null);
  }
  final db = _openDatabase(path);
  try {
    final filters = <String>[
      'source_id = ?',
      'kind = ?',
      'available = 1',
      "EXISTS (SELECT 1 FROM sources WHERE sources.id = catalog_items.source_id AND sources.refresh_state IN ('ready', 'refreshing'))",
    ];
    final arguments = <Object?>[sourceId, kind.name];
    switch (selection.kind) {
      case BrowseCategorySelectionKind.all:
        break;
      case BrowseCategorySelectionKind.uncategorized:
        filters.add('source_group_id IS NULL');
      case BrowseCategorySelectionKind.sourceGroup:
        final sourceGroupId = selection.sourceGroupId;
        if (sourceGroupId == null) {
          return const SourceVisibilityPage(items: [], nextCursor: null);
        }
        filters.add('source_group_id = ?');
        arguments.add(sourceGroupId);
    }
    if (hiddenOnly) filters.add('hidden = 1');
    if (cursor != null) {
      filters.add(
        '(normalized_title > ? OR (normalized_title = ? AND id > ?))',
      );
      arguments.addAll([
        cursor.normalizedTitle,
        cursor.normalizedTitle,
        cursor.id,
      ]);
    }
    arguments.add(limit + 1);
    final rows = db.select('''SELECT id, kind, title, normalized_title, hidden
         FROM catalog_items
         WHERE ${filters.join(' AND ')}
         ORDER BY normalized_title ASC, id ASC
         LIMIT ?''', arguments);
    final hasMore = rows.length > limit;
    final visibleRows = hasMore ? rows.take(limit) : rows;
    final items = visibleRows
        .map(
          (row) => SourceVisibilityItem(
            catalogItemId: row['id']! as String,
            kind: SourceMediaKind.values.byName(row['kind']! as String),
            title: row['title']! as String,
            isHidden: row['hidden']! as int == 1,
          ),
        )
        .toList(growable: false);
    final last = visibleRows.isEmpty ? null : visibleRows.last;
    return SourceVisibilityPage(
      items: List.unmodifiable(items),
      nextCursor: hasMore && last != null
          ? BrowseCursor(
              normalizedTitle: last['normalized_title']! as String,
              id: last['id']! as String,
            )
          : null,
    );
  } finally {
    db.close();
  }
}

void _setSourceGroupHiddenOnWorker(
  String path,
  String sourceId,
  SourceMediaKind kind,
  int sourceGroupId,
  bool hidden,
) {
  final db = _openDatabase(path);
  try {
    db.execute('BEGIN IMMEDIATE');
    try {
      final group = db.select(
        '''SELECT id FROM source_groups
           WHERE id = ? AND source_id = ? AND content_kind = ?''',
        [sourceGroupId, sourceId, kind.name],
      );
      if (group.isEmpty) {
        throw StateError('Visibility category is unavailable.');
      }
      db.execute('UPDATE source_groups SET hidden = ? WHERE id = ?', [
        hidden ? 1 : 0,
        sourceGroupId,
      ]);
      db.execute('COMMIT');
    } catch (_) {
      db.execute('ROLLBACK');
      rethrow;
    }
  } finally {
    db.close();
  }
}

int _setAllCategoriesHiddenOnWorker(
  String path,
  String sourceId,
  SourceMediaKind kind,
  bool hidden,
) {
  final db = _openDatabase(path);
  try {
    db.execute('BEGIN IMMEDIATE');
    try {
      final source = db.select('SELECT id FROM sources WHERE id = ?', [
        sourceId,
      ]);
      if (source.isEmpty) {
        throw StateError('Visibility source is unavailable.');
      }
      final value = hidden ? 1 : 0;
      db.execute(
        '''UPDATE source_groups
           SET hidden = ?
           WHERE source_id = ? AND content_kind = ?
             AND available = 1 AND hidden <> ?''',
        [value, sourceId, kind.name, value],
      );
      final changed = db.updatedRows;
      db.execute('COMMIT');
      return changed;
    } catch (_) {
      db.execute('ROLLBACK');
      rethrow;
    }
  } finally {
    db.close();
  }
}

void _setCatalogItemHiddenOnWorker(
  String path,
  String sourceId,
  String catalogItemId,
  bool hidden,
) {
  final db = _openDatabase(path);
  try {
    db.execute('BEGIN IMMEDIATE');
    try {
      final item = db.select(
        'SELECT id FROM catalog_items WHERE id = ? AND source_id = ?',
        [catalogItemId, sourceId],
      );
      if (item.isEmpty) throw StateError('Visibility item is unavailable.');
      db.execute('UPDATE catalog_items SET hidden = ? WHERE id = ?', [
        hidden ? 1 : 0,
        catalogItemId,
      ]);
      db.execute('COMMIT');
    } catch (_) {
      db.execute('ROLLBACK');
      rethrow;
    }
  } finally {
    db.close();
  }
}

List<BrowseCategorySummary> _browseCategoriesOnWorker(
  String path,
  String sourceId,
  SourceMediaKind kind,
) {
  if (!File(path).existsSync()) return const [];
  final db = _openDatabase(path);
  try {
    final readySource = db.select(
      "SELECT id FROM sources WHERE id = ? AND enabled = 1 AND refresh_state IN ('ready', 'refreshing')",
      [sourceId],
    );
    if (readySource.isEmpty) return const [];

    final total =
        db
                .select(
                  '''SELECT COUNT(*) AS count FROM catalog_items AS items
                 WHERE items.source_id = ? AND items.kind = ?
                   AND items.available = 1 AND items.hidden = 0
                   AND NOT EXISTS (
                     SELECT 1 FROM source_groups AS visibility_group
                     WHERE visibility_group.id = items.source_group_id
                       AND visibility_group.hidden = 1
                   )''',
                  [sourceId, kind.name],
                )
                .single['count']!
            as int;
    final categories = <BrowseCategorySummary>[
      BrowseCategorySummary(
        selection: const BrowseCategorySelection.all(),
        name: 'All ${kind.label}',
        itemCount: total,
      ),
    ];
    final groups = db.select(
      '''SELECT groups.id, groups.name, COUNT(items.id) AS count
         FROM source_groups AS groups
         LEFT JOIN catalog_items AS items
           ON items.source_group_id = groups.id
          AND items.kind = groups.content_kind
          AND items.available = 1
          AND items.hidden = 0
         WHERE groups.source_id = ? AND groups.content_kind = ?
           AND groups.hidden = 0
           AND groups.available = 1
         GROUP BY groups.id
         ORDER BY groups.sort_key ASC, groups.id ASC''',
      [sourceId, kind.name],
    );
    for (final group in groups) {
      categories.add(
        BrowseCategorySummary(
          selection: BrowseCategorySelection.sourceGroup(group['id']! as int),
          name: group['name']! as String,
          itemCount: group['count']! as int,
        ),
      );
    }
    final uncategorized =
        db
                .select(
                  '''SELECT COUNT(*) AS count FROM catalog_items
         WHERE source_id = ? AND kind = ? AND available = 1 AND hidden = 0
           AND source_group_id IS NULL''',
                  [sourceId, kind.name],
                )
                .single['count']!
            as int;
    if (uncategorized > 0) {
      categories.add(
        BrowseCategorySummary(
          selection: const BrowseCategorySelection.uncategorized(),
          name: 'Uncategorized',
          itemCount: uncategorized,
        ),
      );
    }
    return List.unmodifiable(categories);
  } finally {
    db.close();
  }
}

BrowsePage _browsePageOnWorker(
  String path,
  String sourceId,
  SourceMediaKind kind,
  BrowseCategorySelection selection,
  BrowseCursor? cursor,
  int limit,
) {
  if (!File(path).existsSync()) {
    return const BrowsePage(items: [], nextCursor: null);
  }
  final db = _openDatabase(path);
  try {
    final filters = <String>[
      "source_id = ?",
      'kind = ?',
      'available = 1',
      'hidden = 0',
      '''NOT EXISTS (
           SELECT 1 FROM source_groups AS visibility_group
           WHERE visibility_group.id = catalog_items.source_group_id
             AND visibility_group.hidden = 1
         )''',
      "EXISTS (SELECT 1 FROM sources WHERE sources.id = catalog_items.source_id AND sources.enabled = 1 AND sources.refresh_state IN ('ready', 'refreshing'))",
    ];
    final arguments = <Object?>[sourceId, kind.name];
    switch (selection.kind) {
      case BrowseCategorySelectionKind.all:
        break;
      case BrowseCategorySelectionKind.uncategorized:
        filters.add('source_group_id IS NULL');
      case BrowseCategorySelectionKind.sourceGroup:
        final sourceGroupId = selection.sourceGroupId;
        if (sourceGroupId == null) {
          return const BrowsePage(items: [], nextCursor: null);
        }
        filters.add('source_group_id = ?');
        arguments.add(sourceGroupId);
    }
    if (cursor != null) {
      filters.add(
        '(normalized_title > ? OR (normalized_title = ? AND id > ?))',
      );
      arguments.addAll([
        cursor.normalizedTitle,
        cursor.normalizedTitle,
        cursor.id,
      ]);
    }
    arguments.add(limit + 1);
    final rows = db.select(
      '''SELECT id, source_id, kind, title, normalized_title, artwork_locator, playback_ref
         FROM catalog_items
         WHERE ${filters.join(' AND ')}
         ORDER BY normalized_title ASC, id ASC
         LIMIT ?''',
      arguments,
    );
    final hasMore = rows.length > limit;
    final visibleRows = hasMore ? rows.take(limit) : rows;
    final items = visibleRows
        .map(
          (row) => BrowseCatalogItem(
            id: row['id']! as String,
            sourceId: row['source_id']! as String,
            kind: SourceMediaKind.values.byName(row['kind']! as String),
            title: row['title']! as String,
            artworkLocator: row['artwork_locator'] as String?,
            playbackRef: row['playback_ref']! as String,
          ),
        )
        .toList(growable: false);
    final last = visibleRows.isEmpty ? null : visibleRows.last;
    return BrowsePage(
      items: items,
      nextCursor: hasMore && last != null
          ? BrowseCursor(
              normalizedTitle: last['normalized_title']! as String,
              id: last['id']! as String,
            )
          : null,
    );
  } finally {
    db.close();
  }
}

LibraryPage _libraryPageOnWorker(
  String path,
  LibraryScope scope,
  SourceMediaKind? kind,
  BrowseCursor? cursor,
  int limit, {
  String? query,
}) {
  if (!File(path).existsSync()) {
    return const LibraryPage(items: [], nextCursor: null);
  }
  final db = _openDatabase(path);
  try {
    final filters = <String>[
      'catalog.available = 1',
      'catalog.hidden = 0',
      '''NOT EXISTS (
           SELECT 1 FROM source_groups AS visibility_group
           WHERE visibility_group.id = catalog.source_group_id
             AND visibility_group.hidden = 1
         )''',
      'source.enabled = 1',
      "source.refresh_state IN ('ready', 'refreshing')",
    ];
    final arguments = <Object?>[];
    if (kind != null) {
      filters.add('catalog.kind = ?');
      arguments.add(kind.name);
    }
    if (scope.sourceId != null) {
      filters.add('catalog.source_id = ?');
      arguments.add(scope.sourceId);
    }
    if (query != null) {
      final match = _literalFtsQuery(query);
      if (match == null) {
        return const LibraryPage(items: [], nextCursor: null);
      }
      filters.add('library_fts MATCH ?');
      arguments.add(match);
    }
    final cursorFilter = cursor == null
        ? ''
        : '''AND (normalized_title > ?
             OR (normalized_title = ? AND library_item_id > ?))''';
    if (cursor != null) {
      arguments.addAll([
        cursor.normalizedTitle,
        cursor.normalizedTitle,
        cursor.id,
      ]);
    }
    arguments.add(limit + 1);
    final rows = db.select('''WITH ranked AS (
           SELECT library.id AS library_item_id,
                  catalog.id AS catalog_item_id,
                  catalog.source_id,
                  source.name AS source_display_name,
                  catalog.kind,
                  library.display_title,
                  library.normalized_title,
                  library.artwork_locator,
                  catalog.playback_ref,
                  ROW_NUMBER() OVER (
                    PARTITION BY library.id
                    ORDER BY member.preferred DESC,
                             catalog.source_id ASC,
                             catalog.id ASC
                  ) AS variant_rank
           ${query == null ? 'FROM library_items AS library' : '''FROM library_fts
           CROSS JOIN library_items AS library
             ON library.id = library_fts.library_item_id'''}
           ${query == null ? 'JOIN' : 'CROSS JOIN'} library_members AS member
             ON member.library_item_id = library.id
           ${query == null ? 'JOIN' : 'CROSS JOIN'} catalog_items AS catalog
             ON catalog.id = member.catalog_item_id
           ${query == null ? 'JOIN' : 'CROSS JOIN'} sources AS source
             ON source.id = catalog.source_id
           WHERE ${filters.join(' AND ')}
         )
         SELECT library_item_id, catalog_item_id, source_id,
                source_display_name, kind, display_title, normalized_title,
                artwork_locator, playback_ref
         FROM ranked
         WHERE variant_rank = 1
         $cursorFilter
         ORDER BY normalized_title ASC, library_item_id ASC
         LIMIT ?''', arguments);
    final hasMore = rows.length > limit;
    final visibleRows = hasMore ? rows.take(limit) : rows;
    final items = visibleRows
        .map(
          (row) => LibraryCatalogItem(
            libraryItemId: row['library_item_id']! as String,
            catalogItemId: row['catalog_item_id']! as String,
            sourceId: row['source_id']! as String,
            sourceDisplayName: row['source_display_name']! as String,
            kind: SourceMediaKind.values.byName(row['kind']! as String),
            title: row['display_title']! as String,
            artworkLocator: row['artwork_locator'] as String?,
            playbackRef: row['playback_ref']! as String,
          ),
        )
        .toList(growable: false);
    final last = visibleRows.isEmpty ? null : visibleRows.last;
    return LibraryPage(
      items: List.unmodifiable(items),
      nextCursor: hasMore && last != null
          ? BrowseCursor(
              normalizedTitle: last['normalized_title']! as String,
              id: last['library_item_id']! as String,
            )
          : null,
    );
  } finally {
    db.close();
  }
}

int _countLibraryItemsOnWorker(
  String path,
  LibraryScope scope, {
  SourceMediaKind? kind,
  String? query,
}) {
  if (!File(path).existsSync()) return 0;
  final db = _openDatabase(path);
  try {
    final filters = <String>[
      'catalog.available = 1',
      'catalog.hidden = 0',
      '''NOT EXISTS (
           SELECT 1 FROM source_groups AS visibility_group
           WHERE visibility_group.id = catalog.source_group_id
             AND visibility_group.hidden = 1
         )''',
      'source.enabled = 1',
      "source.refresh_state IN ('ready', 'refreshing')",
    ];
    final arguments = <Object?>[];
    if (kind != null) {
      filters.add('catalog.kind = ?');
      arguments.add(kind.name);
    }
    if (scope.sourceId != null) {
      filters.add('catalog.source_id = ?');
      arguments.add(scope.sourceId);
    }
    if (query != null) {
      final match = _literalFtsQuery(query);
      if (match == null) return 0;
      filters.add('library_fts MATCH ?');
      arguments.add(match);
    }
    return db.select('''SELECT COUNT(DISTINCT library.id) AS count
             ${query == null ? 'FROM library_items AS library' : '''FROM library_fts
             CROSS JOIN library_items AS library
               ON library.id = library_fts.library_item_id'''}
             ${query == null ? '''JOIN library_members AS member
               ON member.library_item_id = library.id''' : '''CROSS JOIN library_members AS member
               ON member.library_item_id = library.id'''}
             ${query == null ? 'JOIN' : 'CROSS JOIN'} catalog_items AS catalog
               ON catalog.id = member.catalog_item_id
             ${query == null ? 'JOIN' : 'CROSS JOIN'} sources AS source
               ON source.id = catalog.source_id
             WHERE ${filters.join(' AND ')}''', arguments).single['count']!
        as int;
  } finally {
    db.close();
  }
}

LibraryScope _loadCatalogScopeOnWorker(String path) {
  if (!File(path).existsSync()) return const LibraryScope.all();
  final db = _openDatabase(path);
  try {
    final rows = db.select('SELECT value FROM app_settings WHERE key = ?', [
      _catalogScopeSettingKey,
    ]);
    if (rows.isEmpty || rows.single['value'] == _allCatalogScopeValue) {
      return const LibraryScope.all();
    }
    final value = rows.single['value']! as String;
    if (!value.startsWith(_sourceCatalogScopePrefix)) {
      _writeCatalogScope(db, const LibraryScope.all());
      return const LibraryScope.all();
    }
    final sourceId = value.substring(_sourceCatalogScopePrefix.length);
    final enabled = db.select(
      'SELECT id FROM sources WHERE id = ? AND enabled = 1',
      [sourceId],
    );
    if (enabled.isEmpty) {
      _writeCatalogScope(db, const LibraryScope.all());
      return const LibraryScope.all();
    }
    return LibraryScope.source(sourceId);
  } finally {
    db.close();
  }
}

LibraryScope _saveCatalogScopeOnWorker(String path, LibraryScope scope) {
  final db = _openDatabase(path);
  try {
    final sourceId = scope.sourceId;
    if (sourceId == null) {
      _writeCatalogScope(db, const LibraryScope.all());
      return const LibraryScope.all();
    }
    final enabled = db.select(
      'SELECT id FROM sources WHERE id = ? AND enabled = 1',
      [sourceId],
    );
    if (enabled.isEmpty) {
      _writeCatalogScope(db, const LibraryScope.all());
      return const LibraryScope.all();
    }
    final saved = LibraryScope.source(sourceId);
    _writeCatalogScope(db, saved);
    return saved;
  } finally {
    db.close();
  }
}

void _writeCatalogScope(Database db, LibraryScope scope) {
  final value = scope.sourceId == null
      ? _allCatalogScopeValue
      : '$_sourceCatalogScopePrefix${scope.sourceId}';
  db.execute(
    '''INSERT INTO app_settings (key, value) VALUES (?, ?)
       ON CONFLICT(key) DO UPDATE SET value = excluded.value''',
    [_catalogScopeSettingKey, value],
  );
}

String? _literalFtsQuery(String value) {
  final punctuation = RegExp(
    r'^[()\[\]{}:"+*^~!&|,-]+|[()\[\]{}:"+*^~!&|,-]+$',
  );
  final quoted = value
      .trim()
      .split(RegExp(r'\s+'))
      .map((segment) => segment.replaceAll(punctuation, ''))
      .where((segment) => segment.isNotEmpty)
      .map((segment) => '"${segment.replaceAll('"', '""')}"')
      .toList();
  return quoted.isEmpty ? null : quoted.join(' AND ');
}

SourceReady _commitFixtureOnWorker(
  String path,
  SourceDefinition source,
  List<ImportedStage> stages,
) {
  final db = _openDatabase(path);
  try {
    _createPending(db, {
      'id': source.id,
      'name': source.name,
      'credentialKey': source.credentialKey,
      'displayEndpoint': source.displayEndpoint,
    });
    final counts = <SourceMediaKind, int>{};
    for (final stage in stages) {
      _writeStage(db, source.id, stage.kind, stage.categories, stage.items);
      counts[stage.kind] = stage.itemCount;
    }
    db.execute(
      "UPDATE sources SET enabled = 1, refresh_state = 'ready' WHERE id = ?",
      [source.id],
    );
    return SourceReady(counts: counts);
  } finally {
    db.close();
  }
}

void _deleteSourceOnWorker(String path, String sourceId) {
  if (!File(path).existsSync()) return;
  final db = _openDatabase(path);
  try {
    _deleteSource(db, sourceId);
  } finally {
    db.close();
  }
}

void _recoverInterruptedRefreshesOnWorker(String path) {
  if (!File(path).existsSync()) return;
  final db = _openDatabase(path);
  try {
    // A refresh never changes availability until its commit transaction, so
    // returning to ready exposes the intact last-good generation after restart.
    db.execute(
      "UPDATE sources SET refresh_state = 'ready' WHERE refresh_state = 'refreshing'",
    );
  } finally {
    db.close();
  }
}

/// Parent-side recovery for a refresh worker that exits without sending a
/// terminal message. It is intentionally source-scoped: another connector's
/// in-flight marker is never touched.
void _recoverAbnormalRefreshOnWorker(String path, String sourceId) {
  if (!File(path).existsSync()) return;
  final db = _openDatabase(path);
  try {
    db.execute(
      "UPDATE sources SET refresh_state = 'ready', last_error = ? WHERE id = ? AND refresh_state = 'refreshing'",
      [SourceRefreshFailure.unreachable.name, sourceId],
    );
  } finally {
    db.close();
  }
}

void _renameSourceOnWorker(String path, String sourceId, String name) {
  if (!File(path).existsSync()) return;
  final db = _openDatabase(path);
  try {
    db.execute('UPDATE sources SET name = ? WHERE id = ?', [name, sourceId]);
  } finally {
    db.close();
  }
}

void _setSourceEnabledOnWorker(String path, String sourceId, bool enabled) {
  if (!File(path).existsSync()) return;
  final db = _openDatabase(path);
  try {
    db.execute('UPDATE sources SET enabled = ? WHERE id = ?', [
      enabled ? 1 : 0,
      sourceId,
    ]);
  } finally {
    db.close();
  }
}

SourceRefresh? _beginRefreshOnWorker(String path, String sourceId) {
  if (!File(path).existsSync()) return null;
  final db = _openDatabase(path);
  try {
    db.execute('BEGIN IMMEDIATE');
    try {
      final rows = db.select(
        "SELECT refresh_generation FROM sources WHERE id = ? AND refresh_state = 'ready'",
        [sourceId],
      );
      if (rows.isEmpty) {
        db.execute('COMMIT');
        return null;
      }
      final generation = (rows.single['refresh_generation']! as int) + 1;
      db.execute(
        "UPDATE sources SET refresh_generation = ?, refresh_state = 'refreshing', last_error = NULL WHERE id = ?",
        [generation, sourceId],
      );
      db.execute('COMMIT');
      return SourceRefresh(sourceId: sourceId, generation: generation);
    } catch (_) {
      db.execute('ROLLBACK');
      rethrow;
    }
  } finally {
    db.close();
  }
}

SourceReady _commitRefreshOnWorker(
  String path,
  SourceRefresh refresh,
  List<ImportedStage> stages,
) {
  final db = _openDatabase(path);
  try {
    db.execute('BEGIN IMMEDIATE');
    try {
      final active = db.select(
        "SELECT id FROM sources WHERE id = ? AND refresh_generation = ? AND refresh_state = 'refreshing'",
        [refresh.sourceId, refresh.generation],
      );
      if (active.isEmpty) throw StateError('Refresh is no longer current.');
      final counts = <SourceMediaKind, int>{};
      for (final stage in stages) {
        _upsertStage(
          db,
          refresh.sourceId,
          refresh.generation,
          stage.kind,
          stage.categories,
          stage.items,
        );
        counts[stage.kind] = stage.itemCount;
      }
      db.execute(
        'UPDATE catalog_items SET available = 0 WHERE source_id = ? AND generation < ?',
        [refresh.sourceId, refresh.generation],
      );
      db.execute(
        'UPDATE source_groups SET available = 0 WHERE source_id = ? AND generation < ?',
        [refresh.sourceId, refresh.generation],
      );
      db.execute(
        "UPDATE sources SET refresh_state = 'ready', last_refresh_at = ?, last_error = NULL WHERE id = ?",
        [DateTime.now().toUtc().toIso8601String(), refresh.sourceId],
      );
      db.execute('COMMIT');
      return SourceReady(counts: counts);
    } catch (_) {
      db.execute('ROLLBACK');
      rethrow;
    }
  } finally {
    db.close();
  }
}

void _failRefreshOnWorker(
  String path,
  SourceRefresh refresh,
  SourceRefreshFailure failure,
) {
  if (!File(path).existsSync()) return;
  final db = _openDatabase(path);
  try {
    db.execute(
      "UPDATE sources SET refresh_state = 'ready', last_error = ? WHERE id = ? AND refresh_generation = ? AND refresh_state = 'refreshing'",
      [failure.name, refresh.sourceId, refresh.generation],
    );
  } finally {
    db.close();
  }
}

void _createPending(Database db, Map<String, Object?> source) {
  db.execute('BEGIN IMMEDIATE');
  try {
    db.execute(
      '''INSERT INTO sources (id, kind, name, display_endpoint, credential_key, enabled, refresh_generation, refresh_state, last_refresh_at, last_error, reported_connection_limit, connection_limit_override, settings_json) VALUES (?, ?, ?, ?, ?, 0, 1, 'pending', NULL, NULL, NULL, NULL, '{}')''',
      [
        source['id'],
        source['kind'] ?? 'xtream',
        source['name'],
        source['displayEndpoint'],
        source['credentialKey'],
      ],
    );
    db.execute('COMMIT');
  } catch (_) {
    db.execute('ROLLBACK');
    rethrow;
  }
}

void _writeStage(
  Database db,
  String sourceId,
  SourceMediaKind kind,
  List<ImportedCategory> categories,
  List<ImportedCatalogItem> items,
) {
  db.execute('BEGIN IMMEDIATE');
  try {
    final groupIds = <String, int>{};
    final groupNames = <String, String>{};
    final groups = db.prepare(
      'INSERT INTO source_groups (source_id, provider_key, content_kind, name, sort_key) VALUES (?, ?, ?, ?, ?)',
    );
    try {
      for (final category in categories) {
        groups.execute([
          sourceId,
          category.providerKey,
          kind.name,
          category.name,
          category.name.toLowerCase(),
        ]);
        groupIds[category.providerKey] = db.lastInsertRowId;
        groupNames[category.providerKey] = category.name;
      }
    } finally {
      groups.close();
    }
    final insert = db.prepare(
      '''INSERT INTO catalog_items (id, source_id, provider_key, kind, parent_id, source_group_id, title, normalized_title, playback_ref, artwork_locator, year, external_id, metadata_json, generation, available, updated_at) VALUES (?, ?, ?, ?, NULL, ?, ?, ?, ?, ?, NULL, NULL, NULL, 1, 1, ?)''',
    );
    final updatedAt = DateTime.now().toUtc().toIso8601String();
    try {
      for (final item in items) {
        insert.execute([
          '$sourceId:${kind.name}:${item.providerKey}',
          sourceId,
          item.providerKey,
          kind.name,
          item.categoryKey == null ? null : groupIds[item.categoryKey],
          item.title,
          item.title.toLowerCase(),
          item.playbackRef,
          item.artworkLocator,
          updatedAt,
        ]);
      }
    } finally {
      insert.close();
    }
    // The Phase 2 baseline starts with exactly one durable library identity
    // per provider item. Later organization work may deliberately merge them.
    final identities = db.prepare('''INSERT OR IGNORE INTO library_items
         (id, kind, display_title, normalized_title, artwork_locator)
         VALUES (?, ?, ?, ?, ?)''');
    final members = db.prepare('''INSERT OR IGNORE INTO library_members
         (library_item_id, catalog_item_id, preferred) VALUES (?, ?, 1)''');
    final search = db.prepare('''INSERT OR IGNORE INTO library_fts
         (library_item_id, title, supporting_text) VALUES (?, ?, ?)''');
    try {
      for (final item in items) {
        final id = '$sourceId:${kind.name}:${item.providerKey}';
        identities.execute([
          id,
          kind.name,
          item.title,
          item.title.toLowerCase(),
          item.artworkLocator,
        ]);
        members.execute([id, id]);
        // FTS intentionally receives display data only, never playback_ref.
        search.execute([
          id,
          item.title,
          item.categoryKey == null ? '' : groupNames[item.categoryKey] ?? '',
        ]);
      }
    } finally {
      identities.close();
      members.close();
      search.close();
    }
    db.execute('COMMIT');
  } catch (_) {
    db.execute('ROLLBACK');
    rethrow;
  }
}

/// Writes one refresh stage inside the caller's transaction.
void _upsertStage(
  Database db,
  String sourceId,
  int generation,
  SourceMediaKind kind,
  List<ImportedCategory> categories,
  List<ImportedCatalogItem> items,
) {
  final groupIds = <String, int>{};
  final groupNames = <String, String>{};
  final groups = db.prepare('''INSERT INTO source_groups
       (source_id, provider_key, content_kind, name, sort_key, generation, available)
       VALUES (?, ?, ?, ?, ?, ?, 1)
       ON CONFLICT(source_id, provider_key, content_kind) DO UPDATE SET
         name = excluded.name, sort_key = excluded.sort_key,
         generation = excluded.generation, available = 1''');
  try {
    for (final category in categories) {
      groups.execute([
        sourceId,
        category.providerKey,
        kind.name,
        category.name,
        category.name.toLowerCase(),
        generation,
      ]);
      groupIds[category.providerKey] =
          db.select(
                'SELECT id FROM source_groups WHERE source_id = ? AND provider_key = ? AND content_kind = ?',
                [sourceId, category.providerKey, kind.name],
              ).single['id']!
              as int;
      groupNames[category.providerKey] = category.name;
    }
  } finally {
    groups.close();
  }
  final catalog = db.prepare('''INSERT INTO catalog_items
       (id, source_id, provider_key, kind, parent_id, source_group_id, title,
        normalized_title, playback_ref, artwork_locator, year, external_id,
        metadata_json, generation, available, updated_at)
       VALUES (?, ?, ?, ?, NULL, ?, ?, ?, ?, ?, NULL, NULL, NULL, ?, 1, ?)
       ON CONFLICT(source_id, provider_key, kind) DO UPDATE SET
         source_group_id = excluded.source_group_id, title = excluded.title,
         normalized_title = excluded.normalized_title,
         playback_ref = excluded.playback_ref,
         artwork_locator = excluded.artwork_locator, generation = excluded.generation,
         available = 1, updated_at = excluded.updated_at''');
  final identities = db.prepare('''INSERT OR IGNORE INTO library_items
       (id, kind, display_title, normalized_title, artwork_locator)
       VALUES (?, ?, ?, ?, ?)''');
  final members = db.prepare('''INSERT OR IGNORE INTO library_members
       (library_item_id, catalog_item_id, preferred) VALUES (?, ?, 1)''');
  final updateIdentity = db.prepare('''UPDATE library_items
       SET display_title = ?, normalized_title = ?, artwork_locator = ?
       WHERE id = ? AND NOT EXISTS (
         SELECT 1 FROM library_members
         WHERE library_item_id = ? AND catalog_item_id <> ?
       )''');
  // `library_item_id` is deliberately UNINDEXED in the FTS table. Deleting
  // one row per item therefore makes a large refresh quadratic. A stage owns
  // one source/kind, so clear its searchable rows once before rebuilding it.
  // The surrounding refresh transaction keeps the last-good catalog visible
  // until this complete stage set is committed.
  db.execute(
    '''DELETE FROM library_fts
       WHERE library_item_id IN (
         SELECT id FROM catalog_items WHERE source_id = ? AND kind = ?
       )''',
    [sourceId, kind.name],
  );
  final search = db.prepare('''INSERT INTO library_fts
       (library_item_id, title, supporting_text) VALUES (?, ?, ?)''');
  final updatedAt = DateTime.now().toUtc().toIso8601String();
  try {
    for (final item in items) {
      final id = '$sourceId:${kind.name}:${item.providerKey}';
      final normalizedTitle = item.title.toLowerCase();
      catalog.execute([
        id,
        sourceId,
        item.providerKey,
        kind.name,
        item.categoryKey == null ? null : groupIds[item.categoryKey],
        item.title,
        normalizedTitle,
        item.playbackRef,
        item.artworkLocator,
        generation,
        updatedAt,
      ]);
      identities.execute([
        id,
        kind.name,
        item.title,
        normalizedTitle,
        item.artworkLocator,
      ]);
      members.execute([id, id]);
      updateIdentity.execute([
        item.title,
        normalizedTitle,
        item.artworkLocator,
        id,
        id,
        id,
      ]);
      // FTS intentionally receives display data only, never playback data.
      search.execute([
        id,
        item.title,
        item.categoryKey == null ? '' : groupNames[item.categoryKey] ?? '',
      ]);
    }
  } finally {
    catalog.close();
    identities.close();
    members.close();
    updateIdentity.close();
    search.close();
  }
}

void _deleteSource(Database db, String sourceId) {
  db.execute('BEGIN IMMEDIATE');
  try {
    // Library identities remain so a favorite, group, or watch state cannot
    // be destroyed merely because its final source variant is removed.
    db.execute(
      'DELETE FROM library_members WHERE catalog_item_id IN (SELECT id FROM catalog_items WHERE source_id = ?)',
      [sourceId],
    );
    db.execute('DELETE FROM catalog_items WHERE source_id = ?', [sourceId]);
    db.execute('DELETE FROM source_groups WHERE source_id = ?', [sourceId]);
    db.execute('DELETE FROM sources WHERE id = ?', [sourceId]);
    db.execute('COMMIT');
  } catch (_) {
    db.execute('ROLLBACK');
    rethrow;
  }
}

const _sqliteBusyTimeoutMilliseconds = 8000;

/// Every worker gets the same bounded SQLite wait policy before touching
/// durable local state. WAL is persisted in the database file, so only switch
/// modes when an older database is not already in WAL mode; repeatedly
/// requesting a mode change while a refresh owns a write transaction is the
/// avoidable source of reader failures this boundary prevents.
Database _openDatabase(String path) {
  final db = sqlite3.open(path);
  db.execute('PRAGMA busy_timeout = $_sqliteBusyTimeoutMilliseconds');
  _migrate(db);
  final mode = db.select('PRAGMA journal_mode').single.values.single;
  if ('$mode'.toLowerCase() != 'wal') {
    db.select('PRAGMA journal_mode = WAL');
  }
  return db;
}

void _migrate(Database db) {
  db.execute(
    'CREATE TABLE IF NOT EXISTS schema_migrations (version INTEGER PRIMARY KEY)',
  );
  final version =
      db
              .select('SELECT MAX(version) AS version FROM schema_migrations')
              .first['version']
          as int? ??
      0;
  if (version < 1) {
    db.execute(
      '''CREATE TABLE sources (id TEXT PRIMARY KEY, kind TEXT NOT NULL, name TEXT NOT NULL, display_endpoint TEXT NOT NULL, credential_key TEXT NOT NULL, enabled INTEGER NOT NULL, refresh_generation INTEGER NOT NULL, refresh_state TEXT NOT NULL, last_refresh_at TEXT, last_error TEXT, settings_json TEXT NOT NULL)''',
    );
    db.execute(
      '''CREATE TABLE source_groups (id INTEGER PRIMARY KEY AUTOINCREMENT, source_id TEXT NOT NULL, provider_key TEXT NOT NULL, content_kind TEXT NOT NULL, name TEXT NOT NULL, sort_key TEXT NOT NULL, UNIQUE(source_id, provider_key, content_kind))''',
    );
    db.execute(
      '''CREATE TABLE catalog_items (id TEXT PRIMARY KEY, source_id TEXT NOT NULL, provider_key TEXT NOT NULL, kind TEXT NOT NULL, parent_id TEXT, source_group_id INTEGER, title TEXT NOT NULL, normalized_title TEXT NOT NULL, playback_ref TEXT NOT NULL, artwork_locator TEXT, year INTEGER, external_id TEXT, metadata_json TEXT, generation INTEGER NOT NULL, available INTEGER NOT NULL, updated_at TEXT NOT NULL, UNIQUE(source_id, provider_key, kind))''',
    );
    db.execute(
      'CREATE INDEX source_groups_source_kind ON source_groups(source_id, content_kind)',
    );
    db.execute(
      'CREATE INDEX catalog_items_source_kind ON catalog_items(source_id, kind)',
    );
    db.execute('INSERT INTO schema_migrations(version) VALUES (1)');
  }
  if (version < 2) {
    db.execute(
      'CREATE INDEX catalog_items_browse_page ON catalog_items(source_id, kind, available, source_group_id, normalized_title, id)',
    );
    db.execute('INSERT INTO schema_migrations(version) VALUES (2)');
  }
  if (version < 3) {
    db.execute(
      'CREATE INDEX catalog_items_browse_all ON catalog_items(source_id, kind, available, normalized_title, id)',
    );
    db.execute('INSERT INTO schema_migrations(version) VALUES (3)');
  }
  if (version < 4) {
    db.execute('BEGIN IMMEDIATE');
    try {
      db.execute(
        'ALTER TABLE sources ADD COLUMN reported_connection_limit INTEGER',
      );
      db.execute(
        'ALTER TABLE sources ADD COLUMN connection_limit_override INTEGER',
      );
      db.execute('INSERT INTO schema_migrations(version) VALUES (4)');
      db.execute('COMMIT');
    } catch (_) {
      db.execute('ROLLBACK');
      rethrow;
    }
  }
  if (version < 5) {
    db.execute('BEGIN IMMEDIATE');
    try {
      db.execute(
        '''CREATE TABLE library_items (id TEXT PRIMARY KEY, kind TEXT NOT NULL, display_title TEXT NOT NULL, normalized_title TEXT NOT NULL, artwork_locator TEXT)''',
      );
      db.execute(
        '''CREATE TABLE library_members (library_item_id TEXT NOT NULL, catalog_item_id TEXT NOT NULL UNIQUE, preferred INTEGER NOT NULL, PRIMARY KEY (library_item_id, catalog_item_id))''',
      );
      db.execute(
        '''CREATE TABLE favorites (library_item_id TEXT PRIMARY KEY, created_at TEXT NOT NULL)''',
      );
      db.execute(
        '''CREATE TABLE custom_groups (id TEXT PRIMARY KEY, name TEXT NOT NULL, home_ordinal INTEGER, created_at TEXT NOT NULL, updated_at TEXT NOT NULL)''',
      );
      db.execute(
        '''CREATE TABLE custom_group_items (custom_group_id TEXT NOT NULL, library_item_id TEXT NOT NULL, ordinal INTEGER NOT NULL, PRIMARY KEY (custom_group_id, library_item_id))''',
      );
      db.execute(
        '''CREATE TABLE watch_state (library_item_id TEXT PRIMARY KEY, position_ms INTEGER NOT NULL, duration_ms INTEGER NOT NULL, completed INTEGER NOT NULL, last_played_at TEXT NOT NULL)''',
      );
      db.execute(
        'CREATE TABLE app_settings (key TEXT PRIMARY KEY, value TEXT NOT NULL)',
      );
      db.execute('''CREATE VIRTUAL TABLE library_fts USING fts5(
         library_item_id UNINDEXED, title, supporting_text)''');
      db.execute(
        'CREATE INDEX catalog_items_parent ON catalog_items(parent_id)',
      );
      db.execute(
        'CREATE INDEX catalog_items_source_group ON catalog_items(source_group_id)',
      );
      db.execute(
        'CREATE INDEX catalog_items_available ON catalog_items(available)',
      );
      db.execute(
        'CREATE INDEX custom_group_items_group_ordinal ON custom_group_items(custom_group_id, ordinal)',
      );
      db.execute(
        'CREATE INDEX watch_state_last_played ON watch_state(last_played_at)',
      );
      // Existing Phase 1 catalog rows deterministically become their own
      // identities. Only display/search text is copied into the FTS table.
      db.execute(
        '''INSERT INTO library_items (id, kind, display_title, normalized_title, artwork_locator)
         SELECT id, kind, title, normalized_title, artwork_locator FROM catalog_items''',
      );
      db.execute('''INSERT INTO library_members (library_item_id, catalog_item_id, preferred)
         SELECT id, id, 1 FROM catalog_items''');
      db.execute(
        '''INSERT INTO library_fts (library_item_id, title, supporting_text)
         SELECT catalog.id, catalog.title, COALESCE(groups.name, '')
         FROM catalog_items AS catalog
         LEFT JOIN source_groups AS groups ON groups.id = catalog.source_group_id''',
      );
      db.execute('INSERT INTO schema_migrations(version) VALUES (5)');
      db.execute('COMMIT');
    } catch (_) {
      db.execute('ROLLBACK');
      rethrow;
    }
  }
  if (version < 6) {
    db.execute('BEGIN IMMEDIATE');
    try {
      // Visibility is a compact local preference carried by the durable
      // provider identities. Refresh upserts intentionally omit these fields,
      // preserving user choices while new provider rows start included.
      if (!_tableHasColumn(db, 'source_groups', 'hidden')) {
        db.execute(
          'ALTER TABLE source_groups ADD COLUMN hidden INTEGER NOT NULL DEFAULT 0',
        );
      }
      if (!_tableHasColumn(db, 'catalog_items', 'hidden')) {
        db.execute(
          'ALTER TABLE catalog_items ADD COLUMN hidden INTEGER NOT NULL DEFAULT 0',
        );
      }
      db.execute(
        'CREATE INDEX IF NOT EXISTS source_groups_visibility ON source_groups(source_id, content_kind, hidden, sort_key, id)',
      );
      db.execute(
        'CREATE INDEX IF NOT EXISTS catalog_items_visibility_page ON catalog_items(source_id, kind, available, hidden, source_group_id, normalized_title, id)',
      );
      db.execute(
        'CREATE INDEX IF NOT EXISTS catalog_items_visibility_all ON catalog_items(source_id, kind, available, hidden, normalized_title, id)',
      );
      // The visibility directory is driven by provider groups and counts each
      // group's available items.  The broader availability index turns that
      // into a catalog-wide scan for every group at Strong scale.
      db.execute(
        'CREATE INDEX IF NOT EXISTS catalog_items_source_group_available ON catalog_items(source_group_id, available)',
      );
      db.execute('INSERT INTO schema_migrations(version) VALUES (6)');
      db.execute('COMMIT');
    } catch (_) {
      db.execute('ROLLBACK');
      rethrow;
    }
  }
  if (version < 7) {
    db.execute('BEGIN IMMEDIATE');
    try {
      // Provider categories remain durable so local hidden preferences survive
      // a temporary provider omission. Availability determines whether a
      // group belongs to the current refreshed catalog.
      if (!_tableHasColumn(db, 'source_groups', 'generation')) {
        db.execute(
          'ALTER TABLE source_groups ADD COLUMN generation INTEGER NOT NULL DEFAULT 1',
        );
      }
      if (!_tableHasColumn(db, 'source_groups', 'available')) {
        db.execute(
          'ALTER TABLE source_groups ADD COLUMN available INTEGER NOT NULL DEFAULT 1',
        );
      }
      db.execute('''UPDATE source_groups
           SET generation = COALESCE((
             SELECT refresh_generation FROM sources
             WHERE sources.id = source_groups.source_id
           ), 1), available = 1''');
      db.execute(
        'CREATE INDEX IF NOT EXISTS source_groups_active_directory ON source_groups(source_id, content_kind, available, hidden, sort_key, id)',
      );
      db.execute('INSERT INTO schema_migrations(version) VALUES (7)');
      db.execute('COMMIT');
    } catch (_) {
      db.execute('ROLLBACK');
      rethrow;
    }
  }
}

bool _tableHasColumn(Database db, String table, String column) =>
    db.select('PRAGMA table_info($table)').any((row) => row['name'] == column);

bool _isAuthorized(Object? value) {
  if (value is! Map) return false;
  final info = value['user_info'];
  if (info is! Map) return false;
  final auth = info['auth'];
  return auth == 1 || auth == '1' || auth == true;
}

List<ImportedCategory> _parseCategories(Object? value) => value is! List
    ? const []
    : value
          .whereType<Map>()
          .map(
            (e) => ImportedCategory(
              providerKey: '${e['category_id'] ?? ''}'.trim(),
              name: '${e['category_name'] ?? ''}'.trim(),
            ),
          )
          .where((e) => e.providerKey.isNotEmpty && e.name.isNotEmpty)
          .toList();
List<ImportedCatalogItem> _parseItems(
  SourceMediaKind kind,
  List<Object?> items,
) => items
    .whereType<Map>()
    .map((e) {
      final key =
          '${e[kind == SourceMediaKind.series ? 'series_id' : 'stream_id'] ?? ''}'
              .trim();
      final title = '${e['name'] ?? ''}'.trim();
      final category = '${e['category_id'] ?? ''}'.trim();
      final extension = '${e['container_extension'] ?? ''}'.trim();
      final artwork =
          '${e[kind == SourceMediaKind.series ? 'cover' : 'stream_icon'] ?? ''}'
              .trim();
      return ImportedCatalogItem(
        providerKey: key,
        title: title,
        categoryKey: category.isEmpty ? null : category,
        playbackRef: playbackReference({
          'providerId': key,
          'kind': kind.name,
          if (extension.isNotEmpty) 'extension': extension,
        }),
        artworkLocator: artwork.isEmpty ? null : artwork,
      );
    })
    .where((e) => e.providerKey.isNotEmpty && e.title.isNotEmpty)
    .toList();
