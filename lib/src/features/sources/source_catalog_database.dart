import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart';

import 'credential_store.dart';
import 'epg_models.dart';
import 'm3u_connector.dart';
import 'source_models.dart';
import 'startup_models.dart';
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
const _defaultRecentlyWatchedLimit = 24;
const _maximumRecentlyWatchedLimit = 48;
const _maximumPlaybackKeyUtf8Bytes = 512;
const _defaultPlayableVariantLimit = 4;
const _maximumPlayableVariantLimit = 8;
const _defaultPersonalLibraryDirectoryLimit = 100;
const _maximumPersonalLibraryDirectoryLimit = 200;
const _maximumCustomGroups = _maximumPersonalLibraryDirectoryLimit - 1;
const _maximumCustomGroupNameLength = 80;
const _favoritesHomeOrdinalSettingKey = 'favorites_home_ordinal';
const _catalogScopeSettingKey = 'catalog_scope';
const _startupTargetSettingKey = 'startup_target';
const _previousDestinationSettingKey = 'previous_destination';
const _lastLiveLibraryItemSettingKey = 'last_live_library_item';
const _allCatalogScopeValue = 'all';
const _sourceCatalogScopePrefix = 'source:';
const _maximumEpgWindowItemIds = 64;

/// A bounded, title-ordered catalog window with truthful cursors on both
/// sides. [previousCursor] is the exclusive upper boundary for
/// [SourceCatalogDatabase.browsePageBefore]; [nextCursor] keeps the ordinary
/// forward browse semantics.
class CatalogBrowseWindow {
  const CatalogBrowseWindow({
    required this.items,
    required this.previousCursor,
    required this.nextCursor,
  });

  final List<BrowseCatalogItem> items;
  final BrowseCursor? previousCursor;
  final BrowseCursor? nextCursor;
}

const _maximumEpgRefreshTargets = 32;
const _maximumEpgProgramsPerChannel = 32;
const _epgRefreshLease = Duration(minutes: 2);
const _epgSuccessTtl = Duration(minutes: 30);
const _epgEmptyTtl = Duration(minutes: 15);

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
    Duration requestLimit = _requestLimit,
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
        'requestLimitMs': requestLimit.inMilliseconds,
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
    final requestLimit = Duration(milliseconds: args['requestLimitMs']! as int);
    final account = await _refreshJson(
      client,
      endpoint,
      args['username']! as String,
      args['password']! as String,
      null,
      _accountAndCategoryLimit,
      deadline,
      requestLimit,
      () => cancelled,
    );
    if (!_isAuthorized(account)) {
      throw const SourceImportFailure(SourceImportFailureKind.authentication);
    }
    final reportedConnectionLimit = _parseReportedConnectionLimit(account);
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
          requestLimit,
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
        requestLimit,
        () => cancelled,
      );
      if (raw is! List) {
        throw const SourceImportFailure(SourceImportFailureKind.emptyResponse);
      }
      final items = _parseItems(kind, raw.cast<Object?>());
      if (raw.isNotEmpty && items.isEmpty) {
        throw const SourceImportFailure(SourceImportFailureKind.emptyResponse);
      }
      stages.add(
        ImportedStage(kind: kind, categories: categories, items: items),
      );
    }
    if (cancelled) {
      throw const SourceImportFailure(SourceImportFailureKind.cancelled);
    }
    final ready = _commitRefreshOnWorker(
      path,
      refresh,
      stages,
      updateReportedConnectionLimit: true,
      reportedConnectionLimit: reportedConnectionLimit,
    );
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
  } on TimeoutException {
    if (refresh != null) {
      _failRefreshOnWorker(
        args['path']! as String,
        refresh,
        cancelled
            ? SourceRefreshFailure.cancelled
            : SourceRefreshFailure.timedOut,
      );
    }
    events.send({
      'type': cancelled ? 'cancelled' : 'failed',
      'failure':
          (cancelled
                  ? SourceImportFailureKind.cancelled
                  : SourceImportFailureKind.timedOut)
              .name,
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
  String? action,
  int max,
  DateTime deadline,
  Duration requestLimit,
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
      'action': ?action,
    },
  );
  final requestDeadline = _boundedRefreshDeadline(deadline, requestLimit);
  final response =
      await (await client
              .getUrl(uri)
              .timeout(_remainingRefreshDeadline(requestDeadline)))
          .close()
          .timeout(_remainingRefreshDeadline(requestDeadline));
  if (response.statusCode == 401 || response.statusCode == 403) {
    throw const SourceImportFailure(SourceImportFailureKind.authentication);
  }
  if (response.statusCode < 200 || response.statusCode >= 300) {
    throw HttpException('request');
  }
  final bytes = BytesBuilder();
  await (() async {
    await for (final chunk in response) {
      if (cancelled()) {
        throw const SourceImportFailure(SourceImportFailureKind.cancelled);
      }
      if (bytes.length + chunk.length > max) {
        throw const SourceImportFailure(SourceImportFailureKind.tooLarge);
      }
      bytes.add(chunk);
    }
  })().timeout(_remainingRefreshDeadline(requestDeadline));
  final text = utf8.decode(bytes.takeBytes());
  if (text.trim().isEmpty) {
    throw const SourceImportFailure(SourceImportFailureKind.emptyResponse);
  }
  return jsonDecode(text);
}

DateTime _boundedRefreshDeadline(
  DateTime importDeadline,
  Duration requestLimit,
) {
  final requestDeadline = DateTime.now().add(requestLimit);
  return requestDeadline.isBefore(importDeadline)
      ? requestDeadline
      : importDeadline;
}

Duration _remainingRefreshDeadline(DateTime deadline) {
  final remaining = deadline.difference(DateTime.now());
  if (remaining <= Duration.zero) throw TimeoutException('refresh-timeout');
  return remaining;
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

  /// Resolves one exact visible catalog identity inside the same source-local
  /// browse scope. This is a bounded restoration lookup, never a title search.
  Future<BrowseCatalogItem?> loadVisibleCatalogItem({
    required String sourceId,
    required SourceMediaKind kind,
    required BrowseCategorySelection selection,
    required String catalogItemId,
  }) async {
    if (catalogItemId.trim().isEmpty) return null;
    final path = await resolvedPath();
    return Isolate.run<BrowseCatalogItem?>(
      () => _loadVisibleCatalogItemOnWorker(
        path,
        sourceId,
        kind,
        selection,
        catalogItemId,
      ),
    );
  }

  /// Reconstructs one bounded, current catalog window around an exact visible
  /// identity. Every returned row is re-read through the active source,
  /// category, availability, and visibility filters.
  Future<CatalogBrowseWindow?> browseWindowAroundCatalogItem({
    required String sourceId,
    required SourceMediaKind kind,
    required BrowseCategorySelection selection,
    required String catalogItemId,
    int limit = _defaultBrowsePageLimit,
  }) async {
    if (catalogItemId.trim().isEmpty) return null;
    final path = await resolvedPath();
    return Isolate.run<CatalogBrowseWindow?>(
      () => _browseWindowAroundCatalogItemOnWorker(
        path,
        sourceId,
        kind,
        selection,
        catalogItemId,
        limit.clamp(3, _maximumBrowsePageLimit),
      ),
    );
  }

  /// Loads the bounded title-ordered page immediately before [cursor]. The
  /// returned [CatalogBrowseWindow.previousCursor] remains non-null only when
  /// still-earlier visible rows exist.
  Future<CatalogBrowseWindow> browsePageBefore({
    required String sourceId,
    required SourceMediaKind kind,
    required BrowseCategorySelection selection,
    required BrowseCursor cursor,
    int limit = _defaultBrowsePageLimit,
  }) async {
    final path = await resolvedPath();
    return Isolate.run<CatalogBrowseWindow>(
      () => _browsePageBeforeOnWorker(
        path,
        sourceId,
        kind,
        selection,
        cursor,
        limit.clamp(1, _maximumBrowsePageLimit),
      ),
    );
  }

  /// Reads the complete source-local category directory through bounded pages.
  /// Unlike ordinary Browse, hidden categories remain present so the user can
  /// restore them. `hiddenOnly` is the recovery filter and [limit] is the page
  /// size rather than a cap on the returned directory.
  Future<List<SourceVisibilityCategory>> loadVisibilityCategories({
    required String sourceId,
    required SourceMediaKind kind,
    bool hiddenOnly = false,
    int limit = _defaultVisibilityCategoryLimit,
  }) async {
    final categories = <SourceVisibilityCategory>[];
    BrowseCursor? cursor;
    do {
      final page = await loadVisibilityCategoryPage(
        sourceId: sourceId,
        kind: kind,
        hiddenOnly: hiddenOnly,
        cursor: cursor,
        limit: limit,
      );
      categories.addAll(page.categories);
      cursor = page.nextCursor;
    } while (cursor != null);
    return List.unmodifiable(categories);
  }

  /// Reads one bounded visibility-category page. Production normally uses
  /// [loadVisibilityCategories], which follows every cursor so bulk summaries
  /// and individual category management cannot be truncated.
  Future<SourceVisibilityCategoryPage> loadVisibilityCategoryPage({
    required String sourceId,
    required SourceMediaKind kind,
    bool hiddenOnly = false,
    BrowseCursor? cursor,
    int limit = _defaultVisibilityCategoryLimit,
  }) async {
    final path = await resolvedPath();
    return Isolate.run<SourceVisibilityCategoryPage>(
      () => _loadVisibilityCategoryPageOnWorker(
        path,
        sourceId,
        kind,
        hiddenOnly,
        cursor,
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

  /// Answers Home's source-presence question without computing catalog
  /// contribution totals for the full source roster.
  Future<bool> hasAnySource() async {
    final path = await resolvedPath();
    return Isolate.run<bool>(() => _hasAnySourceOnWorker(path));
  }

  /// Records viewing occurrence only. Existing position/duration fields are
  /// deliberately preserved for the later resume phase.
  Future<bool> recordRecentlyWatched(
    String libraryItemId, {
    DateTime? playedAt,
  }) async {
    final path = await resolvedPath();
    final timestamp = (playedAt ?? DateTime.now()).toUtc();
    return Isolate.run<bool>(
      () => _recordRecentlyWatchedOnWorker(path, libraryItemId, timestamp),
    );
  }

  /// Reads the most recent playable identities. Disabled, unavailable, hidden,
  /// and category-hidden source variants are excluded before one exact source
  /// variant is selected for playback.
  Future<List<RecentlyWatchedItem>> loadRecentlyWatched({
    int limit = _defaultRecentlyWatchedLimit,
  }) async {
    final path = await resolvedPath();
    return Isolate.run<List<RecentlyWatchedItem>>(
      () => _loadRecentlyWatchedOnWorker(
        path,
        limit.clamp(1, _maximumRecentlyWatchedLimit),
      ),
    );
  }

  /// Reads restart-safe progress for one exact Movie or Episode key.
  ///
  /// Both keys are bounded before SQLite work. Playback locators must never be
  /// used as [mediaKey]; the table intentionally has no locator/title column.
  Future<PlaybackProgress?> loadPlaybackProgress({
    required String libraryItemId,
    required String mediaKey,
  }) async {
    if (!_validPlaybackProgressKey(libraryItemId) ||
        !_validPlaybackProgressKey(mediaKey)) {
      return null;
    }
    final path = await resolvedPath();
    return Isolate.run<PlaybackProgress?>(
      () => _loadPlaybackProgressOnWorker(path, libraryItemId, mediaKey),
    );
  }

  /// Writes exact progress only when [progress.updatedAt] is newer than the
  /// durable row. Delayed transport callbacks therefore cannot overwrite a
  /// later stop, restart, or replacement.
  Future<bool> upsertPlaybackProgress(PlaybackProgress progress) async {
    if (!_validPlaybackProgressKey(progress.libraryItemId) ||
        !_validPlaybackProgressKey(progress.mediaKey) ||
        progress.positionMs < 0 ||
        progress.durationMs < 0 ||
        progress.watchedMs < 0) {
      return false;
    }
    final path = await resolvedPath();
    return Isolate.run<bool>(
      () => _upsertPlaybackProgressOnWorker(path, progress),
    );
  }

  /// Records authoritative cleared state for one exact Movie/Episode key.
  /// The durable guard rejects delayed pre-clear callbacks while reads return
  /// no resumable progress. History and sibling episodes remain untouched.
  Future<bool> clearPlaybackProgress({
    required String libraryItemId,
    required String mediaKey,
    DateTime? clearedAt,
  }) async {
    if (!_validPlaybackProgressKey(libraryItemId) ||
        !_validPlaybackProgressKey(mediaKey)) {
      return false;
    }
    final path = await resolvedPath();
    final timestamp = (clearedAt ?? DateTime.now()).toUtc();
    return Isolate.run<bool>(
      () => _clearPlaybackProgressOnWorker(
        path,
        libraryItemId,
        mediaKey,
        timestamp,
      ),
    );
  }

  /// Loads exact existing active/visible members of one identity only.
  /// Matching titles in other identities are never considered variants.
  Future<List<LibraryCatalogItem>> loadPlayableVariants({
    required String libraryItemId,
    int limit = _defaultPlayableVariantLimit,
  }) async {
    if (!_validPlaybackProgressKey(libraryItemId)) return const [];
    final path = await resolvedPath();
    return Isolate.run<List<LibraryCatalogItem>>(
      () => _loadPlayableVariantsOnWorker(
        path,
        libraryItemId,
        limit.clamp(1, _maximumPlayableVariantLimit),
      ),
    );
  }

  /// Returns the per-source allowance used before a transport is opened.
  Future<SourceConnectionAllowance?> loadSourceConnectionAllowance(
    String sourceId,
  ) async {
    if (!_validPlaybackProgressKey(sourceId)) return null;
    final path = await resolvedPath();
    return Isolate.run<SourceConnectionAllowance?>(
      () => _loadSourceConnectionAllowanceOnWorker(path, sourceId),
    );
  }

  /// Persists Automatic (null), one, or two. Every other override is rejected
  /// before SQLite and by the schema-v11 raw-write guard.
  Future<SourceConnectionAllowance?> setSourceConnectionLimitOverride({
    required String sourceId,
    required int? overrideLimit,
  }) async {
    if (!_validPlaybackProgressKey(sourceId) ||
        (overrideLimit != null && overrideLimit != 1 && overrideLimit != 2)) {
      return null;
    }
    final path = await resolvedPath();
    return Isolate.run<SourceConnectionAllowance?>(
      () => _setSourceConnectionLimitOverrideOnWorker(
        path,
        sourceId,
        overrideLimit,
      ),
    );
  }

  Future<StartupPreference> loadStartupPreference() async {
    final path = await resolvedPath();
    return Isolate.run<StartupPreference>(
      () => _loadStartupPreferenceOnWorker(path),
    );
  }

  Future<StartupPreference> saveStartupTarget(StartupTarget target) async {
    final path = await resolvedPath();
    return Isolate.run<StartupPreference>(
      () => _saveStartupTargetOnWorker(path, target),
    );
  }

  Future<StartupPreference> savePreviousDestination(
    StartupDestinationSlug destination,
  ) async {
    final path = await resolvedPath();
    return Isolate.run<StartupPreference>(
      () => _savePreviousDestinationOnWorker(path, destination),
    );
  }

  /// Records only an existing exact Live library identity. A Movie, Episode,
  /// missing identity, title, or playback locator can never replace the saved
  /// last channel.
  Future<bool> saveLastLiveLibraryItem(String libraryItemId) async {
    if (!_validPlaybackProgressKey(libraryItemId)) return false;
    final path = await resolvedPath();
    return Isolate.run<bool>(
      () => _saveLastLiveLibraryItemOnWorker(path, libraryItemId),
    );
  }

  Future<void> clearLastLiveLibraryItem() async {
    final path = await resolvedPath();
    await Isolate.run<void>(() => _clearLastLiveLibraryItemOnWorker(path));
  }

  /// Resolves the durable preference against current exact local eligibility.
  /// Hidden, disabled, unavailable, or removed variants quietly resolve Home.
  Future<StartupResolution> resolveStartupDestination() async {
    final path = await resolvedPath();
    return Isolate.run<StartupResolution>(
      () => _resolveStartupDestinationOnWorker(path),
    );
  }

  /// Reads cached guide data for a small exact Live-item set. M3U, hidden,
  /// disabled, unavailable, and non-Live rows are deliberately absent.
  Future<List<EpgChannelWindow>> loadEpgWindow({
    required List<String> catalogItemIds,
    required DateTime windowStartUtc,
    required DateTime windowEndUtc,
    required DateTime atUtc,
  }) async {
    final ids = _boundedExactIds(catalogItemIds, _maximumEpgWindowItemIds);
    if (ids.isEmpty || !windowEndUtc.isAfter(windowStartUtc)) return const [];
    final path = await resolvedPath();
    return Isolate.run<List<EpgChannelWindow>>(
      () => _loadEpgWindowOnWorker(
        path,
        ids,
        windowStartUtc.toUtc(),
        windowEndUtc.toUtc(),
        atUtc.toUtc(),
      ),
    );
  }

  /// Atomically leases stale visible Xtream Live rows for one bounded fetch.
  /// An explicit manual retry may bypass persisted error backoff, but never an
  /// active refreshing lease or a successful/empty cache TTL.
  /// The returned provider IDs are internal request data with redacted string
  /// forms; they are never persisted as settings or exposed by window reads.
  Future<List<EpgRefreshTarget>> claimEpgRefreshTargets({
    required List<String> catalogItemIds,
    required DateTime nowUtc,
    int limit = _maximumEpgRefreshTargets,
    bool manualRetry = false,
  }) async {
    final boundedLimit = limit.clamp(1, _maximumEpgRefreshTargets);
    final ids = _boundedExactIds(catalogItemIds, boundedLimit);
    if (ids.isEmpty) return const [];
    final path = await resolvedPath();
    return Isolate.run<List<EpgRefreshTarget>>(
      () => _claimEpgRefreshTargetsOnWorker(
        path,
        ids,
        nowUtc.toUtc(),
        boundedLimit,
        manualRetry,
      ),
    );
  }

  /// Replaces one exact channel cache only if this claim is still current.
  Future<bool> commitEpgRefreshTarget({
    required EpgRefreshTarget target,
    required List<EpgProgram> programs,
    required DateTime completedAtUtc,
  }) async {
    if (programs.length > _maximumEpgProgramsPerChannel ||
        programs.any((program) => !_validEpgProgram(target, program))) {
      return false;
    }
    final path = await resolvedPath();
    return Isolate.run<bool>(
      () => _commitEpgRefreshTargetOnWorker(
        path,
        target,
        programs,
        completedAtUtc.toUtc(),
      ),
    );
  }

  /// Records a fixed, credential-free failure while retaining last-good rows.
  Future<bool> failEpgRefreshTarget({
    required EpgRefreshTarget target,
    required EpgRefreshFailure failure,
    required DateTime failedAtUtc,
    required DateTime retryAfterUtc,
  }) async {
    final path = await resolvedPath();
    return Isolate.run<bool>(
      () => _failEpgRefreshTargetOnWorker(
        path,
        target,
        failure,
        failedAtUtc.toUtc(),
        retryAfterUtc.toUtc(),
      ),
    );
  }

  Future<void> markEpgSourceUnsupported({
    required String sourceId,
    required DateTime attemptedAtUtc,
    required DateTime retryAfterUtc,
  }) async {
    if (!_validPlaybackProgressKey(sourceId)) return;
    final path = await resolvedPath();
    await Isolate.run<void>(
      () => _markEpgSourceUnsupportedOnWorker(
        path,
        sourceId,
        attemptedAtUtc.toUtc(),
        retryAfterUtc.toUtc(),
      ),
    );
  }

  Future<int> pruneExpiredEpg(DateTime beforeUtc) async {
    final path = await resolvedPath();
    return Isolate.run<int>(
      () => _pruneExpiredEpgOnWorker(path, beforeUtc.toUtc()),
    );
  }

  /// Returns Favorites first, followed by the bounded custom-group directory
  /// in the user's explicit local order.
  Future<List<PersonalLibraryDirectoryEntry>> loadPersonalLibraryDirectory({
    int limit = _defaultPersonalLibraryDirectoryLimit,
  }) async {
    final path = await resolvedPath();
    return Isolate.run<List<PersonalLibraryDirectoryEntry>>(
      () => _loadPersonalLibraryDirectoryOnWorker(
        path,
        limit.clamp(1, _maximumPersonalLibraryDirectoryLimit),
      ),
    );
  }

  /// Returns only Favorites/custom groups pinned to Home in one shared order.
  Future<List<PersonalLibraryDirectoryEntry>>
  loadPinnedPersonalLibraryDirectory({int limit = 24}) async {
    final path = await resolvedPath();
    return Isolate.run<List<PersonalLibraryDirectoryEntry>>(
      () => _loadPinnedPersonalLibraryDirectoryOnWorker(
        path,
        limit.clamp(1, _maximumPersonalLibraryDirectoryLimit),
      ),
    );
  }

  /// Reads the Favorite flag and every custom-group membership for one stable
  /// local library identity. No source credential or playback locator crosses
  /// this boundary.
  Future<PersonalLibraryOrganization?> loadItemOrganization(
    String libraryItemId,
  ) async {
    final path = await resolvedPath();
    return Isolate.run<PersonalLibraryOrganization?>(
      () => _loadItemOrganizationOnWorker(path, libraryItemId),
    );
  }

  /// Replaces Favorite plus the complete desired custom-group set in one
  /// transaction. Existing custom-group ordinals are retained; new membership
  /// appends to that group's manual order.
  Future<PersonalLibraryMutationResult> saveItemOrganization({
    required String libraryItemId,
    required bool favorite,
    required Set<String> customGroupIds,
  }) async {
    final path = await resolvedPath();
    return Isolate.run<PersonalLibraryMutationResult>(
      () => _saveItemOrganizationOnWorker(
        path,
        libraryItemId,
        favorite,
        customGroupIds.toList(growable: false),
      ),
    );
  }

  Future<PersonalLibraryMutationResult> createCustomGroup(String name) async {
    final path = await resolvedPath();
    final random = Random.secure().nextInt(0x7fffffff).toRadixString(36);
    final id =
        'group-${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}-$random';
    return Isolate.run<PersonalLibraryMutationResult>(
      () => _createCustomGroupOnWorker(path, id, name),
    );
  }

  Future<PersonalLibraryMutationResult> renameCustomGroup({
    required String customGroupId,
    required String name,
  }) async {
    final path = await resolvedPath();
    return Isolate.run<PersonalLibraryMutationResult>(
      () => _renameCustomGroupOnWorker(path, customGroupId, name),
    );
  }

  Future<PersonalLibraryMutationResult> deleteCustomGroup(
    String customGroupId,
  ) async {
    final path = await resolvedPath();
    return Isolate.run<PersonalLibraryMutationResult>(
      () => _deleteCustomGroupOnWorker(path, customGroupId),
    );
  }

  Future<PersonalLibraryMutationResult> moveCustomGroup({
    required String customGroupId,
    required PersonalLibraryMoveDirection direction,
  }) async {
    final path = await resolvedPath();
    return Isolate.run<PersonalLibraryMutationResult>(
      () => _moveCustomGroupOnWorker(path, customGroupId, direction),
    );
  }

  Future<PersonalLibraryMutationResult> setPersonalCollectionPinned({
    required PersonalLibraryCollectionRef collection,
    required bool pinned,
  }) async {
    final path = await resolvedPath();
    return Isolate.run<PersonalLibraryMutationResult>(
      () => _setPersonalCollectionPinnedOnWorker(path, collection, pinned),
    );
  }

  Future<PersonalLibraryMutationResult> movePinnedPersonalCollection({
    required PersonalLibraryCollectionRef collection,
    required PersonalLibraryMoveDirection direction,
  }) async {
    final path = await resolvedPath();
    return Isolate.run<PersonalLibraryMutationResult>(
      () => _movePinnedPersonalCollectionOnWorker(path, collection, direction),
    );
  }

  Future<PersonalLibraryMutationResult> moveCustomGroupItem({
    required String customGroupId,
    required String libraryItemId,
    required PersonalLibraryMoveDirection direction,
  }) async {
    final path = await resolvedPath();
    return Isolate.run<PersonalLibraryMutationResult>(
      () => _moveCustomGroupItemOnWorker(
        path,
        customGroupId,
        libraryItemId,
        direction,
      ),
    );
  }

  Future<PersonalLibraryMutationResult> removeCustomGroupItem({
    required String customGroupId,
    required String libraryItemId,
  }) async {
    final path = await resolvedPath();
    return Isolate.run<PersonalLibraryMutationResult>(
      () => _removeCustomGroupItemOnWorker(path, customGroupId, libraryItemId),
    );
  }

  Future<FavoriteLibraryPage> loadFavoriteLibraryPage({
    FavoritePageCursor? cursor,
    int limit = _defaultBrowsePageLimit,
  }) async {
    final path = await resolvedPath();
    return Isolate.run<FavoriteLibraryPage>(
      () => _loadFavoriteLibraryPageOnWorker(
        path,
        cursor,
        limit.clamp(1, _maximumBrowsePageLimit),
      ),
    );
  }

  /// Reads a custom group's manual order without exposing any mutation seam.
  Future<CustomGroupLibraryPage> loadCustomGroupLibraryPage({
    required String customGroupId,
    CustomGroupPageCursor? cursor,
    int limit = _defaultBrowsePageLimit,
  }) async {
    final path = await resolvedPath();
    return Isolate.run<CustomGroupLibraryPage>(
      () => _loadCustomGroupLibraryPageOnWorker(
        path,
        customGroupId,
        cursor,
        limit.clamp(1, _maximumBrowsePageLimit),
      ),
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
    Duration requestLimit = _requestLimit,
  }) async => XtreamRefreshImport.start(
    path: await resolvedPath(),
    sourceId: sourceId,
    serverUrl: serverUrl,
    username: username,
    password: password,
    requestLimit: requestLimit,
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

List<String> _boundedExactIds(List<String> values, int limit) {
  final result = <String>[];
  final seen = <String>{};
  for (final value in values) {
    if (result.length == limit) break;
    if (!_validPlaybackProgressKey(value) || !seen.add(value)) continue;
    result.add(value);
  }
  return List.unmodifiable(result);
}

bool _validEpgProgram(EpgRefreshTarget target, EpgProgram program) =>
    program.catalogItemId == target.catalogItemId &&
    program.startUtc.isUtc &&
    program.endUtc.isUtc &&
    program.endUtc.isAfter(program.startUtc) &&
    program.endUtc.difference(program.startUtc) <= epgMaximumProgramDuration &&
    program.title.trim().isNotEmpty &&
    utf8.encode(program.title).length <= 512 &&
    (program.description == null ||
        utf8.encode(program.description!).length <= 4 * 1024);

StartupPreference _loadStartupPreferenceOnWorker(String path) {
  final db = _openDatabase(path);
  try {
    return _loadStartupPreference(db);
  } finally {
    db.close();
  }
}

StartupPreference _loadStartupPreference(Database db) {
  final rows = db.select(
    '''SELECT key, value FROM app_settings
       WHERE key IN (?, ?, ?)''',
    [
      _startupTargetSettingKey,
      _previousDestinationSettingKey,
      _lastLiveLibraryItemSettingKey,
    ],
  );
  final values = <String, String>{
    for (final row in rows) row['key']! as String: row['value']! as String,
  };
  final target = StartupTargetStorage.tryDecode(
    values[_startupTargetSettingKey],
  );
  final previousValue = values[_previousDestinationSettingKey];
  final previous = previousValue == null
      ? null
      : StartupDestinationSlug.values
            .where((value) => value.name == previousValue)
            .firstOrNull;
  final lastLive = values[_lastLiveLibraryItemSettingKey];
  return StartupPreference(
    target: target ?? StartupTarget.home,
    previousDestination: previous,
    lastLiveLibraryItemId:
        lastLive == null || !_validPlaybackProgressKey(lastLive)
        ? null
        : lastLive,
  );
}

StartupPreference _saveStartupTargetOnWorker(
  String path,
  StartupTarget target,
) {
  final db = _openDatabase(path);
  try {
    _writeAppSetting(db, _startupTargetSettingKey, target.storageValue);
    return _loadStartupPreference(db);
  } finally {
    db.close();
  }
}

StartupPreference _savePreviousDestinationOnWorker(
  String path,
  StartupDestinationSlug destination,
) {
  final db = _openDatabase(path);
  try {
    _writeAppSetting(db, _previousDestinationSettingKey, destination.name);
    return _loadStartupPreference(db);
  } finally {
    db.close();
  }
}

bool _saveLastLiveLibraryItemOnWorker(String path, String libraryItemId) {
  final db = _openDatabase(path);
  try {
    final rows = db.select(
      'SELECT 1 FROM library_items WHERE id = ? AND kind = ? LIMIT 1',
      [libraryItemId, SourceMediaKind.live.name],
    );
    if (rows.isEmpty) return false;
    _writeAppSetting(db, _lastLiveLibraryItemSettingKey, libraryItemId);
    return true;
  } finally {
    db.close();
  }
}

void _clearLastLiveLibraryItemOnWorker(String path) {
  final db = _openDatabase(path);
  try {
    db.execute('DELETE FROM app_settings WHERE key = ?', [
      _lastLiveLibraryItemSettingKey,
    ]);
  } finally {
    db.close();
  }
}

StartupResolution _resolveStartupDestinationOnWorker(String path) {
  final db = _openDatabase(path);
  try {
    final preference = _loadStartupPreference(db);
    switch (preference.target) {
      case StartupTarget.home:
        return const StartupResolution.home();
      case StartupTarget.previousScreen:
        final previous = preference.previousDestination;
        return previous == null
            ? const StartupResolution.home()
            : StartupResolution(destination: previous, lastLiveItem: null);
      case StartupTarget.lastChannel:
        final libraryItemId = preference.lastLiveLibraryItemId;
        if (libraryItemId == null) return const StartupResolution.home();
        final item = _loadEligibleStartupLiveItem(db, libraryItemId);
        return item == null
            ? const StartupResolution.home()
            : StartupResolution(
                destination: StartupDestinationSlug.live,
                lastLiveItem: item,
              );
    }
  } finally {
    db.close();
  }
}

LibraryCatalogItem? _loadEligibleStartupLiveItem(
  Database db,
  String libraryItemId,
) {
  final rows = db.select(
    '''SELECT library.id AS library_item_id,
              catalog.id AS catalog_item_id,
              catalog.source_id,
              source.name AS source_display_name,
              library.kind,
              library.display_title,
              library.artwork_locator,
              catalog.playback_ref
       FROM library_members AS member
       JOIN library_items AS library ON library.id = member.library_item_id
       JOIN catalog_items AS catalog ON catalog.id = member.catalog_item_id
       JOIN sources AS source ON source.id = catalog.source_id
       WHERE member.library_item_id = ?
         AND library.kind = ?
         AND catalog.kind = ?
         AND catalog.available = 1
         AND catalog.hidden = 0
         AND NOT EXISTS (
           SELECT 1 FROM source_groups AS visibility_group
           WHERE visibility_group.id = catalog.source_group_id
             AND visibility_group.hidden = 1
         )
         AND source.enabled = 1
         AND source.refresh_state IN ('ready', 'refreshing')
       ORDER BY member.preferred DESC, catalog.source_id ASC, catalog.id ASC
       LIMIT 1''',
    [libraryItemId, SourceMediaKind.live.name, SourceMediaKind.live.name],
  );
  if (rows.isEmpty) return null;
  final row = rows.single;
  return LibraryCatalogItem(
    libraryItemId: row['library_item_id']! as String,
    catalogItemId: row['catalog_item_id']! as String,
    sourceId: row['source_id']! as String,
    sourceDisplayName: row['source_display_name']! as String,
    kind: SourceMediaKind.live,
    title: row['display_title']! as String,
    artworkLocator: row['artwork_locator'] as String?,
    playbackRef: row['playback_ref']! as String,
  );
}

void _writeAppSetting(Database db, String key, String value) {
  db.execute(
    '''INSERT INTO app_settings (key, value) VALUES (?, ?)
       ON CONFLICT(key) DO UPDATE SET value = excluded.value''',
    [key, value],
  );
}

List<EpgChannelWindow> _loadEpgWindowOnWorker(
  String path,
  List<String> catalogItemIds,
  DateTime windowStartUtc,
  DateTime windowEndUtc,
  DateTime atUtc,
) {
  if (!File(path).existsSync()) return const [];
  final db = _openDatabase(path);
  try {
    final placeholders = List.filled(catalogItemIds.length, '?').join(',');
    final eligibleRows = db.select(
      '''SELECT catalog.id,
                channel.refresh_state,
                source_epg.capability,
                source_epg.last_error AS source_epg_error,
                source_epg.retry_after_utc_ms AS source_epg_retry_after_utc_ms
         FROM catalog_items AS catalog
         JOIN sources AS source ON source.id = catalog.source_id
         LEFT JOIN epg_channel_state AS channel
           ON channel.catalog_item_id = catalog.id
         LEFT JOIN epg_source_state AS source_epg
           ON source_epg.source_id = source.id
         WHERE catalog.id IN ($placeholders)
           AND catalog.kind = ?
           AND catalog.available = 1
           AND catalog.hidden = 0
           AND NOT EXISTS (
             SELECT 1 FROM source_groups AS visibility_group
             WHERE visibility_group.id = catalog.source_group_id
               AND visibility_group.hidden = 1
           )
           AND source.kind = 'xtream'
           AND source.enabled = 1
           AND source.refresh_state IN ('ready', 'refreshing')''',
      [...catalogItemIds, SourceMediaKind.live.name],
    );
    final eligible = {
      for (final row in eligibleRows) row['id']! as String: row,
    };
    if (eligible.isEmpty) return const [];
    final eligibleIds = catalogItemIds
        .where(eligible.containsKey)
        .toList(growable: false);
    final programPlaceholders = List.filled(eligibleIds.length, '?').join(',');
    final rows = db.select(
      '''SELECT catalog_item_id, start_utc_ms, end_utc_ms, title, description
         FROM epg_programs
         WHERE catalog_item_id IN ($programPlaceholders)
           AND end_utc_ms > ? AND start_utc_ms < ?
         ORDER BY catalog_item_id ASC, start_utc_ms ASC, end_utc_ms ASC''',
      [
        ...eligibleIds,
        windowStartUtc.millisecondsSinceEpoch,
        windowEndUtc.millisecondsSinceEpoch,
      ],
    );
    final programsByItem = <String, List<EpgProgram>>{};
    for (final row in rows) {
      final id = row['catalog_item_id']! as String;
      programsByItem
          .putIfAbsent(id, () => [])
          .add(
            EpgProgram(
              catalogItemId: id,
              startUtc: DateTime.fromMillisecondsSinceEpoch(
                row['start_utc_ms']! as int,
                isUtc: true,
              ),
              endUtc: DateTime.fromMillisecondsSinceEpoch(
                row['end_utc_ms']! as int,
                isUtc: true,
              ),
              title: row['title']! as String,
              description: row['description'] as String?,
            ),
          );
    }
    return List.unmodifiable(
      eligibleIds.map((id) {
        final state = eligible[id]!;
        final programs = List<EpgProgram>.unmodifiable(
          programsByItem[id] ?? const [],
        );
        return EpgChannelWindow(
          catalogItemId: id,
          availability: _epgAvailability(
            state['refresh_state'] as String?,
            state['capability'] as String?,
            state['source_epg_error'] as String?,
            state['source_epg_retry_after_utc_ms'] as int?,
            atUtc,
          ),
          programs: programs,
          nowNext: _epgNowNext(programs, atUtc),
        );
      }),
    );
  } finally {
    db.close();
  }
}

EpgAvailability _epgAvailability(
  String? state,
  String? capability,
  String? sourceError,
  int? sourceRetryAfterUtcMs,
  DateTime atUtc,
) {
  if (capability == 'unsupported') return EpgAvailability.unsupported;
  final sourceFailureActive =
      (sourceError == EpgRefreshFailure.credentialsUnavailable.name ||
          sourceError == EpgRefreshFailure.authentication.name) &&
      (sourceRetryAfterUtcMs ?? 0) > atUtc.millisecondsSinceEpoch;
  if (sourceFailureActive) return EpgAvailability.temporarilyUnavailable;
  return switch (state) {
    'refreshing' => EpgAvailability.refreshing,
    'available' => EpgAvailability.available,
    'empty' => EpgAvailability.empty,
    'error' => EpgAvailability.temporarilyUnavailable,
    _ => EpgAvailability.unknown,
  };
}

EpgNowNext _epgNowNext(List<EpgProgram> programs, DateTime atUtc) {
  EpgProgram? current;
  for (final program in programs) {
    if (!program.startUtc.isAfter(atUtc) && program.endUtc.isAfter(atUtc)) {
      if (current == null || program.startUtc.isAfter(current.startUtc)) {
        current = program;
      }
    }
  }
  final nextBoundary = current?.endUtc ?? atUtc;
  EpgProgram? next;
  for (final program in programs) {
    if (!program.startUtc.isBefore(nextBoundary) &&
        (next == null || program.startUtc.isBefore(next.startUtc))) {
      next = program;
    }
  }
  return EpgNowNext(current: current, next: next);
}

List<EpgRefreshTarget> _claimEpgRefreshTargetsOnWorker(
  String path,
  List<String> catalogItemIds,
  DateTime nowUtc,
  int limit,
  bool manualRetry,
) {
  if (!File(path).existsSync()) return const [];
  final db = _openDatabase(path);
  db.execute('BEGIN IMMEDIATE');
  try {
    final placeholders = List.filled(catalogItemIds.length, '?').join(',');
    final nowMs = nowUtc.millisecondsSinceEpoch;
    final rows = db.select(
      '''SELECT catalog.id, catalog.source_id, catalog.provider_key,
                COALESCE(channel.generation, 0) AS generation
         FROM catalog_items AS catalog
         JOIN sources AS source ON source.id = catalog.source_id
         LEFT JOIN epg_channel_state AS channel
           ON channel.catalog_item_id = catalog.id
         LEFT JOIN epg_source_state AS source_epg
           ON source_epg.source_id = source.id
         WHERE catalog.id IN ($placeholders)
           AND catalog.kind = ?
           AND catalog.available = 1
           AND catalog.hidden = 0
           AND NOT EXISTS (
             SELECT 1 FROM source_groups AS visibility_group
             WHERE visibility_group.id = catalog.source_group_id
               AND visibility_group.hidden = 1
           )
           AND source.kind = 'xtream'
           AND source.enabled = 1
           AND source.refresh_state IN ('ready', 'refreshing')
           AND (
             COALESCE(channel.retry_after_utc_ms, 0) <= ?
             OR (? = 1 AND channel.refresh_state = 'error')
           )
           AND (
             COALESCE(source_epg.retry_after_utc_ms, 0) <= ?
             OR (? = 1 AND source_epg.last_error IS NOT NULL)
           )
         ORDER BY catalog.id ASC
         LIMIT ?''',
      [
        ...catalogItemIds,
        SourceMediaKind.live.name,
        nowMs,
        manualRetry ? 1 : 0,
        nowMs,
        manualRetry ? 1 : 0,
        limit,
      ],
    );
    final targets = <EpgRefreshTarget>[];
    for (final row in rows) {
      final sourceId = row['source_id']! as String;
      final catalogItemId = row['id']! as String;
      final generation = (row['generation']! as int) + 1;
      db.execute(
        '''INSERT INTO epg_channel_state
             (catalog_item_id, generation, refresh_state, last_attempt_utc_ms,
              last_success_utc_ms, retry_after_utc_ms, last_error)
           VALUES (?, ?, 'refreshing', ?, NULL, ?, NULL)
           ON CONFLICT(catalog_item_id) DO UPDATE SET
             generation = excluded.generation,
             refresh_state = 'refreshing',
             last_attempt_utc_ms = excluded.last_attempt_utc_ms,
             retry_after_utc_ms = excluded.retry_after_utc_ms,
             last_error = NULL''',
        [
          catalogItemId,
          generation,
          nowMs,
          nowUtc.add(_epgRefreshLease).millisecondsSinceEpoch,
        ],
      );
      db.execute(
        '''INSERT INTO epg_source_state
             (source_id, capability, last_attempt_utc_ms,
              last_success_utc_ms, retry_after_utc_ms, last_error)
           VALUES (?, 'unknown', ?, NULL, 0, NULL)
           ON CONFLICT(source_id) DO UPDATE SET
             last_attempt_utc_ms = excluded.last_attempt_utc_ms''',
        [sourceId, nowMs],
      );
      targets.add(
        EpgRefreshTarget(
          sourceId: sourceId,
          catalogItemId: catalogItemId,
          providerStreamId: row['provider_key']! as String,
          generation: generation,
        ),
      );
    }
    db.execute('COMMIT');
    return List.unmodifiable(targets);
  } catch (_) {
    db.execute('ROLLBACK');
    rethrow;
  } finally {
    db.close();
  }
}

bool _commitEpgRefreshTargetOnWorker(
  String path,
  EpgRefreshTarget target,
  List<EpgProgram> programs,
  DateTime completedAtUtc,
) {
  if (!File(path).existsSync()) return false;
  final db = _openDatabase(path);
  db.execute('BEGIN IMMEDIATE');
  try {
    final active = db.select(
      '''SELECT 1 FROM epg_channel_state AS state
         JOIN catalog_items AS catalog ON catalog.id = state.catalog_item_id
         WHERE state.catalog_item_id = ? AND state.generation = ?
           AND state.refresh_state = 'refreshing'
           AND catalog.source_id = ? AND catalog.kind = ?
           AND catalog.available = 1''',
      [
        target.catalogItemId,
        target.generation,
        target.sourceId,
        SourceMediaKind.live.name,
      ],
    );
    if (active.isEmpty) {
      db.execute('ROLLBACK');
      return false;
    }
    db.execute('DELETE FROM epg_programs WHERE catalog_item_id = ?', [
      target.catalogItemId,
    ]);
    final insert = db.prepare('''INSERT INTO epg_programs
           (catalog_item_id, start_utc_ms, end_utc_ms, title, description)
         VALUES (?, ?, ?, ?, ?)''');
    try {
      for (final program in programs) {
        insert.execute([
          target.catalogItemId,
          program.startUtc.millisecondsSinceEpoch,
          program.endUtc.millisecondsSinceEpoch,
          program.title,
          program.description,
        ]);
      }
    } finally {
      insert.close();
    }
    final completedMs = completedAtUtc.millisecondsSinceEpoch;
    final ttl = programs.isEmpty ? _epgEmptyTtl : _epgSuccessTtl;
    db.execute(
      '''UPDATE epg_channel_state
         SET refresh_state = ?, last_success_utc_ms = ?,
             retry_after_utc_ms = ?, last_error = NULL
         WHERE catalog_item_id = ? AND generation = ?''',
      [
        programs.isEmpty ? 'empty' : 'available',
        completedMs,
        completedAtUtc.add(ttl).millisecondsSinceEpoch,
        target.catalogItemId,
        target.generation,
      ],
    );
    db.execute(
      '''INSERT INTO epg_source_state
           (source_id, capability, last_attempt_utc_ms,
            last_success_utc_ms, retry_after_utc_ms, last_error)
         VALUES (?, 'available', ?, ?, 0, NULL)
         ON CONFLICT(source_id) DO UPDATE SET
           capability = 'available',
           last_success_utc_ms = excluded.last_success_utc_ms,
           retry_after_utc_ms = 0,
           last_error = NULL''',
      [target.sourceId, completedMs, completedMs],
    );
    db.execute('COMMIT');
    return true;
  } catch (_) {
    db.execute('ROLLBACK');
    rethrow;
  } finally {
    db.close();
  }
}

bool _failEpgRefreshTargetOnWorker(
  String path,
  EpgRefreshTarget target,
  EpgRefreshFailure failure,
  DateTime failedAtUtc,
  DateTime retryAfterUtc,
) {
  if (!File(path).existsSync()) return false;
  final db = _openDatabase(path);
  db.execute('BEGIN IMMEDIATE');
  try {
    db.execute(
      '''UPDATE epg_channel_state
         SET refresh_state = 'error', last_attempt_utc_ms = ?,
             retry_after_utc_ms = ?, last_error = ?
         WHERE catalog_item_id = ? AND generation = ?
           AND refresh_state = 'refreshing' ''',
      [
        failedAtUtc.millisecondsSinceEpoch,
        retryAfterUtc.millisecondsSinceEpoch,
        failure.name,
        target.catalogItemId,
        target.generation,
      ],
    );
    final changed = db.updatedRows == 1;
    if (changed) {
      switch (failure) {
        case EpgRefreshFailure.unsupported:
          _markEpgSourceUnsupported(
            db,
            target.sourceId,
            failedAtUtc,
            retryAfterUtc,
          );
          break;
        case EpgRefreshFailure.credentialsUnavailable:
        case EpgRefreshFailure.authentication:
          _markEpgSourceTransientFailure(
            db,
            target.sourceId,
            failure,
            failedAtUtc,
            retryAfterUtc,
          );
          break;
        case EpgRefreshFailure.unreachable:
        case EpgRefreshFailure.malformedResponse:
        case EpgRefreshFailure.responseTooLarge:
        case EpgRefreshFailure.timedOut:
        case EpgRefreshFailure.localPersistence:
        case EpgRefreshFailure.cancelled:
          break;
      }
    }
    db.execute('COMMIT');
    return changed;
  } catch (_) {
    db.execute('ROLLBACK');
    rethrow;
  } finally {
    db.close();
  }
}

void _markEpgSourceUnsupportedOnWorker(
  String path,
  String sourceId,
  DateTime attemptedAtUtc,
  DateTime retryAfterUtc,
) {
  if (!File(path).existsSync()) return;
  final db = _openDatabase(path);
  try {
    _markEpgSourceUnsupported(db, sourceId, attemptedAtUtc, retryAfterUtc);
  } finally {
    db.close();
  }
}

void _markEpgSourceUnsupported(
  Database db,
  String sourceId,
  DateTime attemptedAtUtc,
  DateTime retryAfterUtc,
) {
  db.execute(
    '''INSERT INTO epg_source_state
         (source_id, capability, last_attempt_utc_ms,
          last_success_utc_ms, retry_after_utc_ms, last_error)
       VALUES (?, 'unsupported', ?, NULL, ?, 'unsupported')
       ON CONFLICT(source_id) DO UPDATE SET
         capability = 'unsupported',
         last_attempt_utc_ms = excluded.last_attempt_utc_ms,
         retry_after_utc_ms = excluded.retry_after_utc_ms,
         last_error = 'unsupported' ''',
    [
      sourceId,
      attemptedAtUtc.millisecondsSinceEpoch,
      retryAfterUtc.millisecondsSinceEpoch,
    ],
  );
}

void _markEpgSourceTransientFailure(
  Database db,
  String sourceId,
  EpgRefreshFailure failure,
  DateTime attemptedAtUtc,
  DateTime retryAfterUtc,
) {
  db.execute(
    '''INSERT INTO epg_source_state
         (source_id, capability, last_attempt_utc_ms,
          last_success_utc_ms, retry_after_utc_ms, last_error)
       VALUES (?, 'unknown', ?, NULL, ?, ?)
       ON CONFLICT(source_id) DO UPDATE SET
         capability = 'unknown',
         last_attempt_utc_ms = excluded.last_attempt_utc_ms,
         retry_after_utc_ms = excluded.retry_after_utc_ms,
         last_error = excluded.last_error''',
    [
      sourceId,
      attemptedAtUtc.millisecondsSinceEpoch,
      retryAfterUtc.millisecondsSinceEpoch,
      failure.name,
    ],
  );
}

int _pruneExpiredEpgOnWorker(String path, DateTime beforeUtc) {
  if (!File(path).existsSync()) return 0;
  final db = _openDatabase(path);
  try {
    db.execute('DELETE FROM epg_programs WHERE end_utc_ms < ?', [
      beforeUtc.millisecondsSinceEpoch,
    ]);
    return db.updatedRows;
  } finally {
    db.close();
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
      db!.execute(
        'UPDATE sources SET reported_connection_limit = ? WHERE id = ?',
        [_parseReportedConnectionLimit(account), source['id']],
      );
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
        if (rawItems is! List) {
          throw const SourceImportFailure(
            SourceImportFailureKind.emptyResponse,
          );
        }
        final items = _parseItems(kind, rawItems.cast<Object?>());
        if (rawItems.isNotEmpty && items.isEmpty) {
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

SourceVisibilityCategoryPage _loadVisibilityCategoryPageOnWorker(
  String path,
  String sourceId,
  SourceMediaKind kind,
  bool hiddenOnly,
  BrowseCursor? cursor,
  int limit,
) {
  if (!File(path).existsSync()) {
    return const SourceVisibilityCategoryPage(categories: [], nextCursor: null);
  }
  final db = _openDatabase(path);
  try {
    final ready = db.select(
      "SELECT id FROM sources WHERE id = ? AND refresh_state IN ('ready', 'refreshing')",
      [sourceId],
    );
    if (ready.isEmpty) {
      return const SourceVisibilityCategoryPage(
        categories: [],
        nextCursor: null,
      );
    }
    final hiddenFilter = hiddenOnly
        ? '''AND (groups.hidden = 1 OR EXISTS (
               SELECT 1 FROM catalog_items AS hidden_items
               WHERE hidden_items.source_group_id = groups.id
                 AND hidden_items.available = 1
                 AND hidden_items.hidden = 1
             ))'''
        : '';
    final cursorFilter = cursor == null
        ? ''
        : '''AND (groups.sort_key > ? OR
                 (groups.sort_key = ? AND groups.id > ?))''';
    final arguments = <Object?>[sourceId, kind.name];
    if (cursor != null) {
      arguments.addAll([
        cursor.normalizedTitle,
        cursor.normalizedTitle,
        int.parse(cursor.id),
      ]);
    }
    arguments.add(limit + 1);
    final rows = db.select(
      '''SELECT groups.id, groups.name, groups.hidden, groups.sort_key,
                COUNT(items.id) AS item_count,
                COALESCE(SUM(CASE WHEN items.hidden = 1 THEN 1 ELSE 0 END), 0)
                  AS hidden_item_count
         FROM source_groups AS groups
         LEFT JOIN catalog_items AS items
           ON items.source_group_id = groups.id
          AND items.available = 1
         WHERE groups.source_id = ? AND groups.content_kind = ?
           AND groups.available = 1
           $cursorFilter
           $hiddenFilter
         GROUP BY groups.id
         ORDER BY groups.sort_key ASC, groups.id ASC
         LIMIT ?''',
      arguments,
    );
    final hasMore = rows.length > limit;
    final visibleRows = hasMore ? rows.take(limit) : rows;
    final categories = visibleRows
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
    if (!hasMore && itemCount > 0 && (!hiddenOnly || hiddenItemCount > 0)) {
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
    final last = hasMore ? visibleRows.last : null;
    return SourceVisibilityCategoryPage(
      categories: List.unmodifiable(categories),
      nextCursor: last == null
          ? null
          : BrowseCursor(
              normalizedTitle: last['sort_key']! as String,
              id: (last['id']! as int).toString(),
            ),
    );
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
      '''SELECT id, source_id, kind, title, normalized_title, artwork_locator, playback_ref,
                (SELECT member.library_item_id
                 FROM library_members AS member
                 WHERE member.catalog_item_id = catalog_items.id
                 LIMIT 1) AS library_item_id
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
            libraryItemId: row['library_item_id'] as String?,
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

CatalogBrowseWindow? _browseWindowAroundCatalogItemOnWorker(
  String path,
  String sourceId,
  SourceMediaKind kind,
  BrowseCategorySelection selection,
  String catalogItemId,
  int limit,
) {
  if (!File(path).existsSync()) return null;
  final db = _openDatabase(path);
  try {
    final scope = _visibleCatalogBrowseScope(sourceId, kind, selection);
    if (scope == null) return null;
    final anchorRows = db.select(
      '''SELECT id, source_id, kind, title, normalized_title, artwork_locator,
                playback_ref,
                (SELECT member.library_item_id
                 FROM library_members AS member
                 WHERE member.catalog_item_id = catalog_items.id
                 LIMIT 1) AS library_item_id
         FROM catalog_items
         WHERE ${scope.filters.join(' AND ')} AND id = ?
         LIMIT 1''',
      [...scope.arguments, catalogItemId],
    );
    if (anchorRows.isEmpty) return null;
    final anchor = anchorRows.first;
    final anchorTitle = anchor['normalized_title']! as String;
    final anchorId = anchor['id']! as String;
    final beforeLimit = limit ~/ 2;
    final afterLimit = limit - beforeLimit - 1;
    final beforeRows = db.select(
      '''SELECT id, source_id, kind, title, normalized_title, artwork_locator,
                playback_ref,
                (SELECT member.library_item_id
                 FROM library_members AS member
                 WHERE member.catalog_item_id = catalog_items.id
                 LIMIT 1) AS library_item_id
         FROM catalog_items
         WHERE ${scope.filters.join(' AND ')}
           AND (normalized_title < ? OR (normalized_title = ? AND id < ?))
         ORDER BY normalized_title DESC, id DESC
         LIMIT ?''',
      [...scope.arguments, anchorTitle, anchorTitle, anchorId, beforeLimit + 1],
    );
    final hasEarlier = beforeRows.length > beforeLimit;
    final visibleBefore = beforeRows.take(beforeLimit).toList().reversed;
    final afterRows = db.select(
      '''SELECT id, source_id, kind, title, normalized_title, artwork_locator,
                playback_ref,
                (SELECT member.library_item_id
                 FROM library_members AS member
                 WHERE member.catalog_item_id = catalog_items.id
                 LIMIT 1) AS library_item_id
         FROM catalog_items
         WHERE ${scope.filters.join(' AND ')}
           AND (normalized_title > ? OR (normalized_title = ? AND id > ?))
         ORDER BY normalized_title ASC, id ASC
         LIMIT ?''',
      [...scope.arguments, anchorTitle, anchorTitle, anchorId, afterLimit + 1],
    );
    final hasLater = afterRows.length > afterLimit;
    final visibleAfter = afterRows.take(afterLimit).toList(growable: false);
    final visibleRows = <Row>[...visibleBefore, anchor, ...visibleAfter];
    return CatalogBrowseWindow(
      items: List.unmodifiable(visibleRows.map(_browseCatalogItemFromRow)),
      previousCursor: hasEarlier && visibleRows.isNotEmpty
          ? _browseCursorFromRow(visibleRows.first)
          : null,
      nextCursor: hasLater && visibleRows.isNotEmpty
          ? _browseCursorFromRow(visibleRows.last)
          : null,
    );
  } finally {
    db.close();
  }
}

CatalogBrowseWindow _browsePageBeforeOnWorker(
  String path,
  String sourceId,
  SourceMediaKind kind,
  BrowseCategorySelection selection,
  BrowseCursor cursor,
  int limit,
) {
  if (!File(path).existsSync()) {
    return const CatalogBrowseWindow(
      items: [],
      previousCursor: null,
      nextCursor: null,
    );
  }
  final db = _openDatabase(path);
  try {
    final scope = _visibleCatalogBrowseScope(sourceId, kind, selection);
    if (scope == null) {
      return const CatalogBrowseWindow(
        items: [],
        previousCursor: null,
        nextCursor: null,
      );
    }
    final rows = db.select(
      '''SELECT id, source_id, kind, title, normalized_title, artwork_locator,
                playback_ref,
                (SELECT member.library_item_id
                 FROM library_members AS member
                 WHERE member.catalog_item_id = catalog_items.id
                 LIMIT 1) AS library_item_id
         FROM catalog_items
         WHERE ${scope.filters.join(' AND ')}
           AND (normalized_title < ? OR (normalized_title = ? AND id < ?))
         ORDER BY normalized_title DESC, id DESC
         LIMIT ?''',
      [
        ...scope.arguments,
        cursor.normalizedTitle,
        cursor.normalizedTitle,
        cursor.id,
        limit + 1,
      ],
    );
    final hasEarlier = rows.length > limit;
    final visibleRows = rows.take(limit).toList().reversed.toList();
    return CatalogBrowseWindow(
      items: List.unmodifiable(visibleRows.map(_browseCatalogItemFromRow)),
      previousCursor: hasEarlier && visibleRows.isNotEmpty
          ? _browseCursorFromRow(visibleRows.first)
          : null,
      nextCursor: null,
    );
  } finally {
    db.close();
  }
}

({List<String> filters, List<Object?> arguments})? _visibleCatalogBrowseScope(
  String sourceId,
  SourceMediaKind kind,
  BrowseCategorySelection selection,
) {
  final filters = <String>[
    'source_id = ?',
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
      if (sourceGroupId == null) return null;
      filters.add('source_group_id = ?');
      arguments.add(sourceGroupId);
  }
  return (filters: filters, arguments: arguments);
}

BrowseCatalogItem _browseCatalogItemFromRow(Row row) => BrowseCatalogItem(
  id: row['id']! as String,
  sourceId: row['source_id']! as String,
  kind: SourceMediaKind.values.byName(row['kind']! as String),
  title: row['title']! as String,
  artworkLocator: row['artwork_locator'] as String?,
  playbackRef: row['playback_ref']! as String,
  libraryItemId: row['library_item_id'] as String?,
);

BrowseCursor _browseCursorFromRow(Row row) => BrowseCursor(
  normalizedTitle: row['normalized_title']! as String,
  id: row['id']! as String,
);

BrowseCatalogItem? _loadVisibleCatalogItemOnWorker(
  String path,
  String sourceId,
  SourceMediaKind kind,
  BrowseCategorySelection selection,
  String catalogItemId,
) {
  if (!File(path).existsSync()) return null;
  final db = _openDatabase(path);
  try {
    final filters = <String>[
      'id = ?',
      'source_id = ?',
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
    final arguments = <Object?>[catalogItemId, sourceId, kind.name];
    switch (selection.kind) {
      case BrowseCategorySelectionKind.all:
        break;
      case BrowseCategorySelectionKind.uncategorized:
        filters.add('source_group_id IS NULL');
      case BrowseCategorySelectionKind.sourceGroup:
        final sourceGroupId = selection.sourceGroupId;
        if (sourceGroupId == null) return null;
        filters.add('source_group_id = ?');
        arguments.add(sourceGroupId);
    }
    final rows = db.select(
      '''SELECT id, source_id, kind, title, artwork_locator, playback_ref,
                (SELECT member.library_item_id
                 FROM library_members AS member
                 WHERE member.catalog_item_id = catalog_items.id
                 LIMIT 1) AS library_item_id
         FROM catalog_items
         WHERE ${filters.join(' AND ')}
         LIMIT 1''',
      arguments,
    );
    if (rows.isEmpty) return null;
    final row = rows.first;
    return BrowseCatalogItem(
      id: row['id']! as String,
      sourceId: row['source_id']! as String,
      kind: SourceMediaKind.values.byName(row['kind']! as String),
      title: row['title']! as String,
      artworkLocator: row['artwork_locator'] as String?,
      playbackRef: row['playback_ref']! as String,
      libraryItemId: row['library_item_id'] as String?,
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

bool _hasAnySourceOnWorker(String path) {
  if (!File(path).existsSync()) return false;
  final db = _openDatabase(path);
  try {
    return db.select('SELECT 1 FROM sources LIMIT 1').isNotEmpty;
  } finally {
    db.close();
  }
}

bool _recordRecentlyWatchedOnWorker(
  String path,
  String libraryItemId,
  DateTime playedAt,
) {
  if (!File(path).existsSync()) return false;
  final db = _openDatabase(path);
  try {
    final identity = db.select('SELECT id FROM library_items WHERE id = ?', [
      libraryItemId,
    ]);
    if (identity.isEmpty) return false;
    final timestamp = playedAt.toUtc().toIso8601String();
    db.execute(
      '''INSERT INTO watch_state
           (library_item_id, position_ms, duration_ms, completed, last_played_at)
         VALUES (?, 0, 0, 0, ?)
         ON CONFLICT(library_item_id) DO UPDATE SET
           last_played_at = CASE
             WHEN excluded.last_played_at > watch_state.last_played_at
             THEN excluded.last_played_at
             ELSE watch_state.last_played_at
           END''',
      [libraryItemId, timestamp],
    );
    return true;
  } finally {
    db.close();
  }
}

List<RecentlyWatchedItem> _loadRecentlyWatchedOnWorker(String path, int limit) {
  if (!File(path).existsSync()) return const [];
  final db = _openDatabase(path);
  try {
    final rows = db.select(
      '''WITH ranked AS (
           SELECT watch.library_item_id,
                  watch.last_played_at,
                  catalog.id AS catalog_item_id,
                  catalog.source_id,
                  source.name AS source_display_name,
                  library.kind,
                  library.display_title,
                  library.artwork_locator,
                  catalog.playback_ref,
                  ROW_NUMBER() OVER (
                    PARTITION BY watch.library_item_id
                    ORDER BY member.preferred DESC,
                             catalog.source_id ASC,
                             catalog.id ASC
                  ) AS variant_rank
           FROM watch_state AS watch
           JOIN library_items AS library
             ON library.id = watch.library_item_id
           JOIN library_members AS member
             ON member.library_item_id = library.id
           JOIN catalog_items AS catalog
             ON catalog.id = member.catalog_item_id
           JOIN sources AS source
             ON source.id = catalog.source_id
           WHERE catalog.available = 1
             AND catalog.hidden = 0
             AND NOT EXISTS (
               SELECT 1 FROM source_groups AS visibility_group
               WHERE visibility_group.id = catalog.source_group_id
                 AND visibility_group.hidden = 1
             )
             AND source.enabled = 1
             AND source.refresh_state IN ('ready', 'refreshing')
         )
         SELECT library_item_id, last_played_at, catalog_item_id, source_id,
                source_display_name, kind, display_title, artwork_locator,
                playback_ref
         FROM ranked
         WHERE variant_rank = 1
         ORDER BY last_played_at DESC, library_item_id ASC
         LIMIT ?''',
      [limit],
    );
    return List.unmodifiable(
      rows.map(
        (row) => RecentlyWatchedItem(
          item: LibraryCatalogItem(
            libraryItemId: row['library_item_id']! as String,
            catalogItemId: row['catalog_item_id']! as String,
            sourceId: row['source_id']! as String,
            sourceDisplayName: row['source_display_name']! as String,
            kind: SourceMediaKind.values.byName(row['kind']! as String),
            title: row['display_title']! as String,
            artworkLocator: row['artwork_locator'] as String?,
            playbackRef: row['playback_ref']! as String,
          ),
          lastPlayedAt: DateTime.parse(row['last_played_at']! as String)
              .toUtc(),
        ),
      ),
    );
  } finally {
    db.close();
  }
}

bool _validPlaybackProgressKey(String value) {
  if (value.isEmpty || value.length > _maximumPlaybackKeyUtf8Bytes) {
    return false;
  }
  return utf8.encode(value).length <= _maximumPlaybackKeyUtf8Bytes;
}

PlaybackProgress? _loadPlaybackProgressOnWorker(
  String path,
  String libraryItemId,
  String mediaKey,
) {
  if (!File(path).existsSync()) return null;
  final db = _openDatabase(path);
  try {
    final rows = db.select(
      '''SELECT library_item_id, media_key, position_ms, duration_ms,
                watched_ms, completed, updated_at_us
         FROM playback_progress
         WHERE library_item_id = ? AND media_key = ? AND cleared = 0
         LIMIT 1''',
      [libraryItemId, mediaKey],
    );
    if (rows.isEmpty) return null;
    final row = rows.single;
    return PlaybackProgress(
      libraryItemId: row['library_item_id']! as String,
      mediaKey: row['media_key']! as String,
      positionMs: row['position_ms']! as int,
      durationMs: row['duration_ms']! as int,
      watchedMs: row['watched_ms']! as int,
      completed: row['completed']! as int == 1,
      updatedAt: DateTime.fromMicrosecondsSinceEpoch(
        row['updated_at_us']! as int,
        isUtc: true,
      ),
    );
  } finally {
    db.close();
  }
}

bool _upsertPlaybackProgressOnWorker(String path, PlaybackProgress progress) {
  final db = _openDatabase(path);
  try {
    final identity = db.select('SELECT 1 FROM library_items WHERE id = ?', [
      progress.libraryItemId,
    ]);
    if (identity.isEmpty) return false;
    db.execute(
      '''INSERT INTO playback_progress
           (library_item_id, media_key, position_ms, duration_ms, watched_ms,
            completed, cleared, updated_at_us)
         VALUES (?, ?, ?, ?, ?, ?, 0, ?)
         ON CONFLICT(library_item_id, media_key) DO UPDATE SET
           position_ms = excluded.position_ms,
           duration_ms = excluded.duration_ms,
           watched_ms = excluded.watched_ms,
           completed = excluded.completed,
           cleared = 0,
           updated_at_us = excluded.updated_at_us
         WHERE excluded.updated_at_us > playback_progress.updated_at_us''',
      [
        progress.libraryItemId,
        progress.mediaKey,
        progress.positionMs,
        progress.durationMs,
        progress.watchedMs,
        progress.completed ? 1 : 0,
        progress.updatedAt.toUtc().microsecondsSinceEpoch,
      ],
    );
    return db.updatedRows == 1;
  } finally {
    db.close();
  }
}

bool _clearPlaybackProgressOnWorker(
  String path,
  String libraryItemId,
  String mediaKey,
  DateTime clearedAt,
) {
  if (!File(path).existsSync()) return false;
  final db = _openDatabase(path);
  try {
    final identity = db.select('SELECT 1 FROM library_items WHERE id = ?', [
      libraryItemId,
    ]);
    if (identity.isEmpty) return false;
    db.execute(
      '''INSERT INTO playback_progress
           (library_item_id, media_key, position_ms, duration_ms, watched_ms,
            completed, cleared, updated_at_us)
         VALUES (?, ?, 0, 0, 0, 0, 1, ?)
         ON CONFLICT(library_item_id, media_key) DO UPDATE SET
           position_ms = 0,
           duration_ms = 0,
           watched_ms = 0,
           completed = 0,
           cleared = 1,
           updated_at_us = CASE
             WHEN excluded.updated_at_us > playback_progress.updated_at_us
             THEN excluded.updated_at_us
             ELSE playback_progress.updated_at_us + 1
           END''',
      [libraryItemId, mediaKey, clearedAt.microsecondsSinceEpoch],
    );
    // A valid exact identity is now authoritatively clear whether this inserted
    // a first tombstone or advanced an existing progress/tombstone generation.
    return true;
  } finally {
    db.close();
  }
}

List<LibraryCatalogItem> _loadPlayableVariantsOnWorker(
  String path,
  String libraryItemId,
  int limit,
) {
  if (!File(path).existsSync()) return const [];
  final db = _openDatabase(path);
  try {
    final rows = db.select(
      '''SELECT library.id AS library_item_id,
                catalog.id AS catalog_item_id,
                catalog.source_id,
                source.name AS source_display_name,
                library.kind,
                library.display_title,
                library.artwork_locator,
                catalog.playback_ref
         FROM library_members AS member
         JOIN library_items AS library ON library.id = member.library_item_id
         JOIN catalog_items AS catalog ON catalog.id = member.catalog_item_id
         JOIN sources AS source ON source.id = catalog.source_id
         WHERE member.library_item_id = ?
           AND catalog.available = 1
           AND catalog.hidden = 0
           AND NOT EXISTS (
             SELECT 1 FROM source_groups AS visibility_group
             WHERE visibility_group.id = catalog.source_group_id
               AND visibility_group.hidden = 1
           )
           AND source.enabled = 1
           AND source.refresh_state IN ('ready', 'refreshing')
         ORDER BY member.preferred DESC, catalog.source_id ASC, catalog.id ASC
         LIMIT ?''',
      [libraryItemId, limit],
    );
    return List.unmodifiable(
      rows.map(
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
      ),
    );
  } finally {
    db.close();
  }
}

SourceConnectionAllowance? _loadSourceConnectionAllowanceOnWorker(
  String path,
  String sourceId,
) {
  if (!File(path).existsSync()) return null;
  final db = _openDatabase(path);
  try {
    return _sourceConnectionAllowance(db, sourceId);
  } finally {
    db.close();
  }
}

SourceConnectionAllowance? _setSourceConnectionLimitOverrideOnWorker(
  String path,
  String sourceId,
  int? overrideLimit,
) {
  if (!File(path).existsSync()) return null;
  final db = _openDatabase(path);
  try {
    db.execute(
      'UPDATE sources SET connection_limit_override = ? WHERE id = ?',
      [overrideLimit, sourceId],
    );
    if (db.updatedRows == 0) return null;
    return _sourceConnectionAllowance(db, sourceId);
  } finally {
    db.close();
  }
}

SourceConnectionAllowance? _sourceConnectionAllowance(
  Database db,
  String sourceId,
) {
  final rows = db.select(
    '''SELECT reported_connection_limit, connection_limit_override
       FROM sources WHERE id = ? LIMIT 1''',
    [sourceId],
  );
  if (rows.isEmpty) return null;
  final row = rows.single;
  final rawReported = row['reported_connection_limit'] as int?;
  final rawOverride = row['connection_limit_override'] as int?;
  return SourceConnectionAllowance(
    reportedLimit: rawReported != null && rawReported > 0 ? rawReported : null,
    overrideLimit: rawOverride == 1 || rawOverride == 2 ? rawOverride : null,
  );
}

List<PersonalLibraryDirectoryEntry> _loadPersonalLibraryDirectoryOnWorker(
  String path,
  int limit,
) {
  if (!File(path).existsSync()) {
    return const [
      PersonalLibraryDirectoryEntry(
        kind: PersonalLibraryDirectoryKind.favorites,
        collectionId: null,
        name: 'Favorites',
        itemCount: 0,
      ),
    ];
  }
  final db = _openDatabase(path);
  try {
    final favoriteHomeOrdinal = _favoriteHomeOrdinal(db);
    final entries = <PersonalLibraryDirectoryEntry>[
      PersonalLibraryDirectoryEntry(
        kind: PersonalLibraryDirectoryKind.favorites,
        collectionId: null,
        name: 'Favorites',
        itemCount:
            db
                    .select('SELECT COUNT(*) AS count FROM favorites')
                    .single['count']!
                as int,
        homeOrdinal: favoriteHomeOrdinal,
      ),
    ];
    if (limit == 1) return List.unmodifiable(entries);
    final groups = db.select(
      '''SELECT groups.id, groups.name, groups.directory_ordinal,
                groups.home_ordinal,
                COUNT(items.library_item_id) AS item_count
         FROM custom_groups AS groups
         LEFT JOIN custom_group_items AS items
           ON items.custom_group_id = groups.id
         GROUP BY groups.id
         ORDER BY groups.directory_ordinal ASC, groups.id ASC
         LIMIT ?''',
      [limit - 1],
    );
    entries.addAll(
      groups.map(
        (row) => PersonalLibraryDirectoryEntry(
          kind: PersonalLibraryDirectoryKind.customGroup,
          collectionId: row['id']! as String,
          name: row['name']! as String,
          itemCount: row['item_count']! as int,
          directoryOrdinal: row['directory_ordinal']! as int,
          homeOrdinal: row['home_ordinal'] as int?,
        ),
      ),
    );
    return List.unmodifiable(entries);
  } finally {
    db.close();
  }
}

List<PersonalLibraryDirectoryEntry> _loadPinnedPersonalLibraryDirectoryOnWorker(
  String path,
  int limit,
) {
  if (!File(path).existsSync()) return const [];
  final db = _openDatabase(path);
  try {
    final entries = <PersonalLibraryDirectoryEntry>[];
    final favoriteHomeOrdinal = _favoriteHomeOrdinal(db);
    if (favoriteHomeOrdinal != null) {
      entries.add(
        PersonalLibraryDirectoryEntry(
          kind: PersonalLibraryDirectoryKind.favorites,
          collectionId: null,
          name: 'Favorites',
          itemCount:
              db
                      .select('SELECT COUNT(*) AS count FROM favorites')
                      .single['count']!
                  as int,
          homeOrdinal: favoriteHomeOrdinal,
        ),
      );
    }
    final groups = db.select(
      '''SELECT groups.id, groups.name, groups.directory_ordinal,
                groups.home_ordinal,
                COUNT(items.library_item_id) AS item_count
         FROM custom_groups AS groups
         LEFT JOIN custom_group_items AS items
           ON items.custom_group_id = groups.id
         WHERE groups.home_ordinal IS NOT NULL
         GROUP BY groups.id
         ORDER BY groups.home_ordinal ASC, groups.id ASC''',
    );
    entries.addAll(
      groups.map(
        (row) => PersonalLibraryDirectoryEntry(
          kind: PersonalLibraryDirectoryKind.customGroup,
          collectionId: row['id']! as String,
          name: row['name']! as String,
          itemCount: row['item_count']! as int,
          directoryOrdinal: row['directory_ordinal']! as int,
          homeOrdinal: row['home_ordinal']! as int,
        ),
      ),
    );
    entries.sort((a, b) {
      final ordinal = a.homeOrdinal!.compareTo(b.homeOrdinal!);
      return ordinal != 0
          ? ordinal
          : a.reference.key.compareTo(b.reference.key);
    });
    return List.unmodifiable(entries.take(limit));
  } finally {
    db.close();
  }
}

PersonalLibraryOrganization? _loadItemOrganizationOnWorker(
  String path,
  String libraryItemId,
) {
  if (!File(path).existsSync()) return null;
  final db = _openDatabase(path);
  try {
    if (db.select('SELECT 1 FROM library_items WHERE id = ?', [
      libraryItemId,
    ]).isEmpty) {
      return null;
    }
    final favorite = db.select(
      'SELECT 1 FROM favorites WHERE library_item_id = ?',
      [libraryItemId],
    ).isNotEmpty;
    final groups = db.select(
      '''SELECT groups.id, groups.name,
                CASE WHEN items.library_item_id IS NULL THEN 0 ELSE 1 END AS selected
         FROM custom_groups AS groups
         LEFT JOIN custom_group_items AS items
           ON items.custom_group_id = groups.id
          AND items.library_item_id = ?
         ORDER BY groups.directory_ordinal ASC, groups.id ASC''',
      [libraryItemId],
    );
    return PersonalLibraryOrganization(
      libraryItemId: libraryItemId,
      isFavorite: favorite,
      groups: List.unmodifiable(
        groups.map(
          (row) => PersonalLibraryGroupChoice(
            groupId: row['id']! as String,
            name: row['name']! as String,
            selected: row['selected']! == 1,
          ),
        ),
      ),
    );
  } finally {
    db.close();
  }
}

PersonalLibraryMutationResult _saveItemOrganizationOnWorker(
  String path,
  String libraryItemId,
  bool favorite,
  List<String> desiredGroupIds,
) {
  if (!File(path).existsSync()) {
    return const PersonalLibraryMutationResult(
      PersonalLibraryMutationOutcome.missingItem,
    );
  }
  final desired = desiredGroupIds.toSet();
  if (desired.length > _maximumCustomGroups) {
    return const PersonalLibraryMutationResult(
      PersonalLibraryMutationOutcome.limitReached,
    );
  }
  final db = _openDatabase(path);
  db.execute('BEGIN IMMEDIATE');
  try {
    if (db.select('SELECT 1 FROM library_items WHERE id = ?', [
      libraryItemId,
    ]).isEmpty) {
      db.execute('ROLLBACK');
      return const PersonalLibraryMutationResult(
        PersonalLibraryMutationOutcome.missingItem,
      );
    }
    if (desired.isNotEmpty) {
      final placeholders = List.filled(desired.length, '?').join(',');
      final existing = db.select(
        'SELECT id FROM custom_groups WHERE id IN ($placeholders)',
        desired.toList(growable: false),
      );
      if (existing.length != desired.length) {
        db.execute('ROLLBACK');
        return const PersonalLibraryMutationResult(
          PersonalLibraryMutationOutcome.missingGroup,
        );
      }
    }
    final wasFavorite = db.select(
      'SELECT 1 FROM favorites WHERE library_item_id = ?',
      [libraryItemId],
    ).isNotEmpty;
    final existingGroups = db
        .select(
          'SELECT custom_group_id FROM custom_group_items WHERE library_item_id = ?',
          [libraryItemId],
        )
        .map((row) => row['custom_group_id']! as String)
        .toSet();
    if (wasFavorite == favorite && _sameStringSet(existingGroups, desired)) {
      db.execute('COMMIT');
      return const PersonalLibraryMutationResult(
        PersonalLibraryMutationOutcome.unchanged,
      );
    }
    final now = DateTime.now().toUtc().toIso8601String();
    if (favorite) {
      db.execute(
        'INSERT OR IGNORE INTO favorites (library_item_id, created_at) VALUES (?, ?)',
        [libraryItemId, now],
      );
    } else {
      db.execute('DELETE FROM favorites WHERE library_item_id = ?', [
        libraryItemId,
      ]);
    }
    if (desired.isEmpty) {
      db.execute('DELETE FROM custom_group_items WHERE library_item_id = ?', [
        libraryItemId,
      ]);
    } else {
      final placeholders = List.filled(desired.length, '?').join(',');
      db.execute(
        '''DELETE FROM custom_group_items
           WHERE library_item_id = ?
             AND custom_group_id NOT IN ($placeholders)''',
        [libraryItemId, ...desired],
      );
      final append = db.prepare('''INSERT OR IGNORE INTO custom_group_items
             (custom_group_id, library_item_id, ordinal)
           SELECT ?, ?, COALESCE(MAX(ordinal), -1) + 1
           FROM custom_group_items WHERE custom_group_id = ?''');
      try {
        for (final groupId in desired) {
          append.execute([groupId, libraryItemId, groupId]);
        }
      } finally {
        append.close();
      }
    }
    db.execute(
      '''UPDATE custom_groups SET updated_at = ?
         WHERE id IN (SELECT custom_group_id FROM custom_group_items
                      WHERE library_item_id = ?)''',
      [now, libraryItemId],
    );
    db.execute('COMMIT');
    return const PersonalLibraryMutationResult(
      PersonalLibraryMutationOutcome.changed,
    );
  } catch (_) {
    db.execute('ROLLBACK');
    rethrow;
  } finally {
    db.close();
  }
}

PersonalLibraryMutationResult _createCustomGroupOnWorker(
  String path,
  String id,
  String rawName,
) {
  final name = _normalizedCustomGroupName(rawName);
  if (name == null) {
    return const PersonalLibraryMutationResult(
      PersonalLibraryMutationOutcome.invalidName,
    );
  }
  final db = _openDatabase(path);
  db.execute('BEGIN IMMEDIATE');
  try {
    if (_customGroupNameExists(db, name)) {
      db.execute('ROLLBACK');
      return const PersonalLibraryMutationResult(
        PersonalLibraryMutationOutcome.duplicateName,
      );
    }
    final count =
        db
                .select('SELECT COUNT(*) AS count FROM custom_groups')
                .single['count']!
            as int;
    if (count >= _maximumCustomGroups) {
      db.execute('ROLLBACK');
      return const PersonalLibraryMutationResult(
        PersonalLibraryMutationOutcome.limitReached,
      );
    }
    final ordinal =
        db
                .select(
                  'SELECT COALESCE(MAX(directory_ordinal), -1) + 1 AS ordinal FROM custom_groups',
                )
                .single['ordinal']!
            as int;
    final now = DateTime.now().toUtc().toIso8601String();
    db.execute(
      '''INSERT INTO custom_groups
           (id, name, home_ordinal, created_at, updated_at, directory_ordinal)
         VALUES (?, ?, NULL, ?, ?, ?)''',
      [id, name, now, now, ordinal],
    );
    db.execute('COMMIT');
    return PersonalLibraryMutationResult(
      PersonalLibraryMutationOutcome.changed,
      collection: PersonalLibraryDirectoryEntry(
        kind: PersonalLibraryDirectoryKind.customGroup,
        collectionId: id,
        name: name,
        itemCount: 0,
        directoryOrdinal: ordinal,
      ),
    );
  } catch (_) {
    db.execute('ROLLBACK');
    rethrow;
  } finally {
    db.close();
  }
}

PersonalLibraryMutationResult _renameCustomGroupOnWorker(
  String path,
  String customGroupId,
  String rawName,
) {
  final name = _normalizedCustomGroupName(rawName);
  if (name == null) {
    return const PersonalLibraryMutationResult(
      PersonalLibraryMutationOutcome.invalidName,
    );
  }
  if (!File(path).existsSync()) {
    return const PersonalLibraryMutationResult(
      PersonalLibraryMutationOutcome.missingGroup,
    );
  }
  final db = _openDatabase(path);
  db.execute('BEGIN IMMEDIATE');
  try {
    final rows = db.select('SELECT name FROM custom_groups WHERE id = ?', [
      customGroupId,
    ]);
    if (rows.isEmpty) {
      db.execute('ROLLBACK');
      return const PersonalLibraryMutationResult(
        PersonalLibraryMutationOutcome.missingGroup,
      );
    }
    if (_customGroupNameExists(db, name, exceptId: customGroupId)) {
      db.execute('ROLLBACK');
      return const PersonalLibraryMutationResult(
        PersonalLibraryMutationOutcome.duplicateName,
      );
    }
    if (rows.single['name'] == name) {
      db.execute('COMMIT');
      return const PersonalLibraryMutationResult(
        PersonalLibraryMutationOutcome.unchanged,
      );
    }
    db.execute(
      'UPDATE custom_groups SET name = ?, updated_at = ? WHERE id = ?',
      [name, DateTime.now().toUtc().toIso8601String(), customGroupId],
    );
    db.execute('COMMIT');
    return const PersonalLibraryMutationResult(
      PersonalLibraryMutationOutcome.changed,
    );
  } catch (_) {
    db.execute('ROLLBACK');
    rethrow;
  } finally {
    db.close();
  }
}

PersonalLibraryMutationResult _deleteCustomGroupOnWorker(
  String path,
  String customGroupId,
) {
  if (!File(path).existsSync()) {
    return const PersonalLibraryMutationResult(
      PersonalLibraryMutationOutcome.missingGroup,
    );
  }
  final db = _openDatabase(path);
  db.execute('BEGIN IMMEDIATE');
  try {
    if (db.select('SELECT 1 FROM custom_groups WHERE id = ?', [
      customGroupId,
    ]).isEmpty) {
      db.execute('ROLLBACK');
      return const PersonalLibraryMutationResult(
        PersonalLibraryMutationOutcome.missingGroup,
      );
    }
    db.execute('DELETE FROM custom_group_items WHERE custom_group_id = ?', [
      customGroupId,
    ]);
    db.execute('DELETE FROM custom_groups WHERE id = ?', [customGroupId]);
    _normalizeCustomGroupOrdinals(db);
    _normalizePinnedCollectionOrdinals(db);
    db.execute('COMMIT');
    return const PersonalLibraryMutationResult(
      PersonalLibraryMutationOutcome.changed,
    );
  } catch (_) {
    db.execute('ROLLBACK');
    rethrow;
  } finally {
    db.close();
  }
}

PersonalLibraryMutationResult _moveCustomGroupOnWorker(
  String path,
  String customGroupId,
  PersonalLibraryMoveDirection direction,
) {
  if (!File(path).existsSync()) {
    return const PersonalLibraryMutationResult(
      PersonalLibraryMutationOutcome.missingGroup,
    );
  }
  final db = _openDatabase(path);
  db.execute('BEGIN IMMEDIATE');
  try {
    _normalizeCustomGroupOrdinals(db);
    final rows = db.select(
      'SELECT id, directory_ordinal FROM custom_groups ORDER BY directory_ordinal, id',
    );
    final index = rows.indexWhere((row) => row['id'] == customGroupId);
    if (index < 0) {
      db.execute('ROLLBACK');
      return const PersonalLibraryMutationResult(
        PersonalLibraryMutationOutcome.missingGroup,
      );
    }
    final target = direction == PersonalLibraryMoveDirection.up
        ? index - 1
        : index + 1;
    if (target < 0 || target >= rows.length) {
      db.execute('COMMIT');
      return const PersonalLibraryMutationResult(
        PersonalLibraryMutationOutcome.unchanged,
      );
    }
    db.execute('UPDATE custom_groups SET directory_ordinal = ? WHERE id = ?', [
      rows[target]['directory_ordinal'],
      customGroupId,
    ]);
    db.execute('UPDATE custom_groups SET directory_ordinal = ? WHERE id = ?', [
      rows[index]['directory_ordinal'],
      rows[target]['id'],
    ]);
    db.execute('COMMIT');
    return const PersonalLibraryMutationResult(
      PersonalLibraryMutationOutcome.changed,
    );
  } catch (_) {
    db.execute('ROLLBACK');
    rethrow;
  } finally {
    db.close();
  }
}

PersonalLibraryMutationResult _setPersonalCollectionPinnedOnWorker(
  String path,
  PersonalLibraryCollectionRef collection,
  bool pinned,
) {
  final db = _openDatabase(path);
  db.execute('BEGIN IMMEDIATE');
  try {
    if (!_personalCollectionExists(db, collection)) {
      db.execute('ROLLBACK');
      return const PersonalLibraryMutationResult(
        PersonalLibraryMutationOutcome.missingGroup,
      );
    }
    final current = _personalCollectionHomeOrdinal(db, collection);
    if ((current != null) == pinned) {
      db.execute('COMMIT');
      return const PersonalLibraryMutationResult(
        PersonalLibraryMutationOutcome.unchanged,
      );
    }
    if (pinned) {
      final next = _nextPinnedCollectionOrdinal(db);
      _writePersonalCollectionHomeOrdinal(db, collection, next);
    } else {
      _writePersonalCollectionHomeOrdinal(db, collection, null);
      _normalizePinnedCollectionOrdinals(db);
    }
    db.execute('COMMIT');
    return const PersonalLibraryMutationResult(
      PersonalLibraryMutationOutcome.changed,
    );
  } catch (_) {
    db.execute('ROLLBACK');
    rethrow;
  } finally {
    db.close();
  }
}

PersonalLibraryMutationResult _movePinnedPersonalCollectionOnWorker(
  String path,
  PersonalLibraryCollectionRef collection,
  PersonalLibraryMoveDirection direction,
) {
  final db = _openDatabase(path);
  db.execute('BEGIN IMMEDIATE');
  try {
    _normalizePinnedCollectionOrdinals(db);
    final entries = _pinnedCollections(db);
    final index = entries.indexWhere(
      (entry) => entry.ref.key == collection.key,
    );
    if (index < 0) {
      db.execute('ROLLBACK');
      return const PersonalLibraryMutationResult(
        PersonalLibraryMutationOutcome.missingGroup,
      );
    }
    final target = direction == PersonalLibraryMoveDirection.up
        ? index - 1
        : index + 1;
    if (target < 0 || target >= entries.length) {
      db.execute('COMMIT');
      return const PersonalLibraryMutationResult(
        PersonalLibraryMutationOutcome.unchanged,
      );
    }
    _writePersonalCollectionHomeOrdinal(
      db,
      entries[index].ref,
      entries[target].ordinal,
    );
    _writePersonalCollectionHomeOrdinal(
      db,
      entries[target].ref,
      entries[index].ordinal,
    );
    db.execute('COMMIT');
    return const PersonalLibraryMutationResult(
      PersonalLibraryMutationOutcome.changed,
    );
  } catch (_) {
    db.execute('ROLLBACK');
    rethrow;
  } finally {
    db.close();
  }
}

PersonalLibraryMutationResult _moveCustomGroupItemOnWorker(
  String path,
  String customGroupId,
  String libraryItemId,
  PersonalLibraryMoveDirection direction,
) {
  if (!File(path).existsSync()) {
    return const PersonalLibraryMutationResult(
      PersonalLibraryMutationOutcome.missingGroup,
    );
  }
  final db = _openDatabase(path);
  db.execute('BEGIN IMMEDIATE');
  try {
    if (db.select('SELECT 1 FROM custom_groups WHERE id = ?', [
      customGroupId,
    ]).isEmpty) {
      db.execute('ROLLBACK');
      return const PersonalLibraryMutationResult(
        PersonalLibraryMutationOutcome.missingGroup,
      );
    }
    final currentRows = db.select(
      '''SELECT ordinal FROM custom_group_items
         WHERE custom_group_id = ? AND library_item_id = ?''',
      [customGroupId, libraryItemId],
    );
    if (currentRows.isEmpty) {
      db.execute('ROLLBACK');
      return const PersonalLibraryMutationResult(
        PersonalLibraryMutationOutcome.missingItem,
      );
    }
    final currentOrdinal = currentRows.single['ordinal']! as int;
    final targetRows = direction == PersonalLibraryMoveDirection.up
        ? db.select(
            '''SELECT library_item_id, ordinal FROM custom_group_items
               WHERE custom_group_id = ? AND ordinal < ?
               ORDER BY ordinal DESC, library_item_id DESC LIMIT 1''',
            [customGroupId, currentOrdinal],
          )
        : db.select(
            '''SELECT library_item_id, ordinal FROM custom_group_items
               WHERE custom_group_id = ? AND ordinal > ?
               ORDER BY ordinal ASC, library_item_id ASC LIMIT 1''',
            [customGroupId, currentOrdinal],
          );
    if (targetRows.isEmpty) {
      db.execute('COMMIT');
      return const PersonalLibraryMutationResult(
        PersonalLibraryMutationOutcome.unchanged,
      );
    }
    final target = targetRows.single;
    db.execute(
      '''UPDATE custom_group_items SET ordinal = ?
         WHERE custom_group_id = ? AND library_item_id = ?''',
      [target['ordinal'], customGroupId, libraryItemId],
    );
    db.execute(
      '''UPDATE custom_group_items SET ordinal = ?
         WHERE custom_group_id = ? AND library_item_id = ?''',
      [currentOrdinal, customGroupId, target['library_item_id']],
    );
    db.execute('UPDATE custom_groups SET updated_at = ? WHERE id = ?', [
      DateTime.now().toUtc().toIso8601String(),
      customGroupId,
    ]);
    db.execute('COMMIT');
    return const PersonalLibraryMutationResult(
      PersonalLibraryMutationOutcome.changed,
    );
  } catch (_) {
    db.execute('ROLLBACK');
    rethrow;
  } finally {
    db.close();
  }
}

PersonalLibraryMutationResult _removeCustomGroupItemOnWorker(
  String path,
  String customGroupId,
  String libraryItemId,
) {
  if (!File(path).existsSync()) {
    return const PersonalLibraryMutationResult(
      PersonalLibraryMutationOutcome.missingGroup,
    );
  }
  final db = _openDatabase(path);
  db.execute('BEGIN IMMEDIATE');
  try {
    if (db.select('SELECT 1 FROM custom_groups WHERE id = ?', [
      customGroupId,
    ]).isEmpty) {
      db.execute('ROLLBACK');
      return const PersonalLibraryMutationResult(
        PersonalLibraryMutationOutcome.missingGroup,
      );
    }
    db.execute(
      '''DELETE FROM custom_group_items
         WHERE custom_group_id = ? AND library_item_id = ?''',
      [customGroupId, libraryItemId],
    );
    final changed = db.updatedRows > 0;
    if (changed) {
      db.execute('UPDATE custom_groups SET updated_at = ? WHERE id = ?', [
        DateTime.now().toUtc().toIso8601String(),
        customGroupId,
      ]);
    }
    db.execute('COMMIT');
    return PersonalLibraryMutationResult(
      changed
          ? PersonalLibraryMutationOutcome.changed
          : PersonalLibraryMutationOutcome.unchanged,
    );
  } catch (_) {
    db.execute('ROLLBACK');
    rethrow;
  } finally {
    db.close();
  }
}

bool _sameStringSet(Set<String> a, Set<String> b) =>
    a.length == b.length && a.containsAll(b);

String? _normalizedCustomGroupName(String raw) {
  final name = raw.trim().replaceAll(RegExp(r'\s+'), ' ');
  if (name.isEmpty || name.length > _maximumCustomGroupNameLength) return null;
  return name;
}

bool _customGroupNameExists(Database db, String name, {String? exceptId}) {
  final rows = exceptId == null
      ? db.select(
          'SELECT 1 FROM custom_groups WHERE name = ? COLLATE NOCASE LIMIT 1',
          [name],
        )
      : db.select(
          '''SELECT 1 FROM custom_groups
             WHERE name = ? COLLATE NOCASE AND id <> ? LIMIT 1''',
          [name, exceptId],
        );
  return rows.isNotEmpty;
}

int? _favoriteHomeOrdinal(Database db) {
  final rows = db.select('SELECT value FROM app_settings WHERE key = ?', [
    _favoritesHomeOrdinalSettingKey,
  ]);
  return rows.isEmpty ? null : int.tryParse(rows.single['value']! as String);
}

void _normalizeCustomGroupOrdinals(Database db) {
  final rows = db.select(
    'SELECT id FROM custom_groups ORDER BY directory_ordinal, id',
  );
  final update = db.prepare(
    'UPDATE custom_groups SET directory_ordinal = ? WHERE id = ?',
  );
  try {
    for (var i = 0; i < rows.length; i += 1) {
      update.execute([i, rows[i]['id']]);
    }
  } finally {
    update.close();
  }
}

bool _personalCollectionExists(
  Database db,
  PersonalLibraryCollectionRef collection,
) =>
    collection.kind == PersonalLibraryDirectoryKind.favorites ||
    (collection.collectionId != null &&
        db.select('SELECT 1 FROM custom_groups WHERE id = ?', [
          collection.collectionId,
        ]).isNotEmpty);

int? _personalCollectionHomeOrdinal(
  Database db,
  PersonalLibraryCollectionRef collection,
) {
  if (collection.kind == PersonalLibraryDirectoryKind.favorites) {
    return _favoriteHomeOrdinal(db);
  }
  if (collection.collectionId == null) return null;
  final rows = db.select(
    'SELECT home_ordinal FROM custom_groups WHERE id = ?',
    [collection.collectionId],
  );
  return rows.isEmpty ? null : rows.single['home_ordinal'] as int?;
}

void _writePersonalCollectionHomeOrdinal(
  Database db,
  PersonalLibraryCollectionRef collection,
  int? ordinal,
) {
  if (collection.kind == PersonalLibraryDirectoryKind.favorites) {
    if (ordinal == null) {
      db.execute('DELETE FROM app_settings WHERE key = ?', [
        _favoritesHomeOrdinalSettingKey,
      ]);
    } else {
      db.execute(
        '''INSERT INTO app_settings (key, value) VALUES (?, ?)
           ON CONFLICT(key) DO UPDATE SET value = excluded.value''',
        [_favoritesHomeOrdinalSettingKey, '$ordinal'],
      );
    }
    return;
  }
  db.execute('UPDATE custom_groups SET home_ordinal = ? WHERE id = ?', [
    ordinal,
    collection.collectionId,
  ]);
}

int _nextPinnedCollectionOrdinal(Database db) {
  final values = <int>[
    ...db
        .select(
          'SELECT home_ordinal FROM custom_groups WHERE home_ordinal IS NOT NULL',
        )
        .map((row) => row['home_ordinal']! as int),
    ?_favoriteHomeOrdinal(db),
  ];
  return values.isEmpty ? 0 : values.reduce(max) + 1;
}

class _PinnedCollection {
  const _PinnedCollection(this.ref, this.ordinal);
  final PersonalLibraryCollectionRef ref;
  final int ordinal;
}

List<_PinnedCollection> _pinnedCollections(Database db) {
  final entries = <_PinnedCollection>[
    if (_favoriteHomeOrdinal(db) case final value?)
      _PinnedCollection(const PersonalLibraryCollectionRef.favorites(), value),
    ...db
        .select('''SELECT id, home_ordinal FROM custom_groups
             WHERE home_ordinal IS NOT NULL''')
        .map(
          (row) => _PinnedCollection(
            PersonalLibraryCollectionRef.customGroup(row['id']! as String),
            row['home_ordinal']! as int,
          ),
        ),
  ];
  entries.sort((a, b) {
    final ordinal = a.ordinal.compareTo(b.ordinal);
    return ordinal != 0 ? ordinal : a.ref.key.compareTo(b.ref.key);
  });
  return entries;
}

void _normalizePinnedCollectionOrdinals(Database db) {
  final entries = _pinnedCollections(db);
  for (var i = 0; i < entries.length; i += 1) {
    _writePersonalCollectionHomeOrdinal(db, entries[i].ref, i);
  }
}

FavoriteLibraryPage _loadFavoriteLibraryPageOnWorker(
  String path,
  FavoritePageCursor? cursor,
  int limit,
) {
  if (!File(path).existsSync()) {
    return const FavoriteLibraryPage(items: [], nextCursor: null);
  }
  final db = _openDatabase(path);
  try {
    final arguments = <Object?>[];
    final cursorFilter = cursor == null
        ? ''
        : '''WHERE (favorite.created_at < ?
             OR (favorite.created_at = ? AND favorite.library_item_id > ?))''';
    if (cursor != null) {
      final createdAt = cursor.createdAt.toUtc().toIso8601String();
      arguments.addAll([createdAt, createdAt, cursor.libraryItemId]);
    }
    arguments.add(limit + 1);
    final rows = db.select('''WITH page AS (
           SELECT favorite.library_item_id, favorite.created_at
           FROM favorites AS favorite
           $cursorFilter
           ORDER BY favorite.created_at DESC, favorite.library_item_id ASC
           LIMIT ?
         ), ranked AS (
           SELECT page.library_item_id,
                  catalog.id AS catalog_item_id,
                  catalog.source_id,
                  source.name AS source_display_name,
                  catalog.playback_ref,
                  ROW_NUMBER() OVER (
                    PARTITION BY page.library_item_id
                    ORDER BY member.preferred DESC,
                             catalog.source_id ASC,
                             catalog.id ASC
                  ) AS variant_rank
           FROM page
           JOIN library_members AS member
             ON member.library_item_id = page.library_item_id
           JOIN catalog_items AS catalog
             ON catalog.id = member.catalog_item_id
           JOIN sources AS source ON source.id = catalog.source_id
           WHERE catalog.available = 1
             AND catalog.hidden = 0
             AND NOT EXISTS (
               SELECT 1 FROM source_groups AS visibility_group
               WHERE visibility_group.id = catalog.source_group_id
                 AND visibility_group.hidden = 1
             )
             AND source.enabled = 1
             AND source.refresh_state IN ('ready', 'refreshing')
         ), chosen AS (
           SELECT * FROM ranked WHERE variant_rank = 1
         )
         SELECT page.created_at, page.library_item_id,
                library.kind, library.display_title, library.artwork_locator,
                chosen.catalog_item_id, chosen.source_id,
                chosen.source_display_name, chosen.playback_ref
         FROM page
         JOIN library_items AS library ON library.id = page.library_item_id
         LEFT JOIN chosen ON chosen.library_item_id = page.library_item_id
         ORDER BY page.created_at DESC, page.library_item_id ASC''', arguments);
    final hasMore = rows.length > limit;
    final visibleRows = hasMore ? rows.take(limit).toList() : rows;
    final last = visibleRows.lastOrNull;
    return FavoriteLibraryPage(
      items: List.unmodifiable(visibleRows.map(_personalLibraryItemFromRow)),
      nextCursor: hasMore && last != null
          ? FavoritePageCursor(
              createdAt: DateTime.parse(last['created_at']! as String).toUtc(),
              libraryItemId: last['library_item_id']! as String,
            )
          : null,
    );
  } finally {
    db.close();
  }
}

CustomGroupLibraryPage _loadCustomGroupLibraryPageOnWorker(
  String path,
  String customGroupId,
  CustomGroupPageCursor? cursor,
  int limit,
) {
  if (!File(path).existsSync()) {
    return const CustomGroupLibraryPage(items: [], nextCursor: null);
  }
  final db = _openDatabase(path);
  try {
    final arguments = <Object?>[customGroupId];
    final cursorFilter = cursor == null
        ? ''
        : '''AND (ordinal > ?
             OR (ordinal = ? AND library_item_id > ?))''';
    if (cursor != null) {
      arguments.addAll([cursor.ordinal, cursor.ordinal, cursor.libraryItemId]);
    }
    arguments.add(limit + 1);
    final rows = db.select('''WITH page AS (
           SELECT library_item_id, ordinal
           FROM custom_group_items
           WHERE custom_group_id = ?
           $cursorFilter
           ORDER BY ordinal ASC, library_item_id ASC
           LIMIT ?
         ), ranked AS (
           SELECT page.library_item_id,
                  catalog.id AS catalog_item_id,
                  catalog.source_id,
                  source.name AS source_display_name,
                  catalog.playback_ref,
                  ROW_NUMBER() OVER (
                    PARTITION BY page.library_item_id
                    ORDER BY member.preferred DESC,
                             catalog.source_id ASC,
                             catalog.id ASC
                  ) AS variant_rank
           FROM page
           JOIN library_members AS member
             ON member.library_item_id = page.library_item_id
           JOIN catalog_items AS catalog
             ON catalog.id = member.catalog_item_id
           JOIN sources AS source ON source.id = catalog.source_id
           WHERE catalog.available = 1
             AND catalog.hidden = 0
             AND NOT EXISTS (
               SELECT 1 FROM source_groups AS visibility_group
               WHERE visibility_group.id = catalog.source_group_id
                 AND visibility_group.hidden = 1
             )
             AND source.enabled = 1
             AND source.refresh_state IN ('ready', 'refreshing')
         ), chosen AS (
           SELECT * FROM ranked WHERE variant_rank = 1
         )
         SELECT page.ordinal, page.library_item_id,
                library.kind, library.display_title, library.artwork_locator,
                chosen.catalog_item_id, chosen.source_id,
                chosen.source_display_name, chosen.playback_ref
         FROM page
         JOIN library_items AS library
           ON library.id = page.library_item_id
         LEFT JOIN chosen ON chosen.library_item_id = page.library_item_id
         ORDER BY page.ordinal ASC, page.library_item_id ASC''', arguments);
    final hasMore = rows.length > limit;
    final visibleRows = hasMore ? rows.take(limit).toList() : rows;
    final last = visibleRows.lastOrNull;
    return CustomGroupLibraryPage(
      items: List.unmodifiable(visibleRows.map(_personalLibraryItemFromRow)),
      nextCursor: hasMore && last != null
          ? CustomGroupPageCursor(
              ordinal: last['ordinal']! as int,
              libraryItemId: last['library_item_id']! as String,
            )
          : null,
    );
  } finally {
    db.close();
  }
}

PersonalLibraryItem _personalLibraryItemFromRow(Row row) => PersonalLibraryItem(
  libraryItemId: row['library_item_id']! as String,
  kind: SourceMediaKind.values.byName(row['kind']! as String),
  title: row['display_title']! as String,
  artworkLocator: row['artwork_locator'] as String?,
  catalogItemId: row['catalog_item_id'] as String?,
  sourceId: row['source_id'] as String?,
  sourceDisplayName: row['source_display_name'] as String?,
  playbackRef: row['playback_ref'] as String?,
);

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
  List<ImportedStage> stages, {
  bool updateReportedConnectionLimit = false,
  int? reportedConnectionLimit,
}) {
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
      // Catalog refresh never deletes last-good guide rows. It only makes the
      // small set of previously visited Live channels eligible for lazy
      // revalidation the next time a visible surface requests them.
      db.execute(
        '''UPDATE epg_channel_state SET retry_after_utc_ms = 0
           WHERE catalog_item_id IN (
             SELECT id FROM catalog_items
             WHERE source_id = ? AND kind = ? AND available = 1
           )''',
        [refresh.sourceId, SourceMediaKind.live.name],
      );
      db.execute(
        'UPDATE epg_source_state SET retry_after_utc_ms = 0 WHERE source_id = ?',
        [refresh.sourceId],
      );
      db.execute(
        "UPDATE sources SET refresh_state = 'ready', last_refresh_at = ?, last_error = NULL WHERE id = ?",
        [DateTime.now().toUtc().toIso8601String(), refresh.sourceId],
      );
      if (updateReportedConnectionLimit) {
        db.execute(
          'UPDATE sources SET reported_connection_limit = ? WHERE id = ?',
          [reportedConnectionLimit, refresh.sourceId],
        );
      }
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
    // Every provider item keeps its own durable library identity. Matching
    // titles are intentionally not merged, automatically or manually.
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
    // A permanently removed source cannot remain the cold-start channel. Read
    // the exact membership before deleting it; transient unavailability and
    // local hiding deliberately do not clear this preference.
    db.execute(
      '''DELETE FROM app_settings
         WHERE key = ? AND value IN (
           SELECT member.library_item_id
           FROM library_members AS member
           JOIN catalog_items AS catalog ON catalog.id = member.catalog_item_id
           WHERE catalog.source_id = ?
         )''',
      [_lastLiveLibraryItemSettingKey, sourceId],
    );
    db.execute(
      '''DELETE FROM epg_programs WHERE catalog_item_id IN (
           SELECT id FROM catalog_items WHERE source_id = ?
         )''',
      [sourceId],
    );
    db.execute(
      '''DELETE FROM epg_channel_state WHERE catalog_item_id IN (
           SELECT id FROM catalog_items WHERE source_id = ?
         )''',
      [sourceId],
    );
    db.execute('DELETE FROM epg_source_state WHERE source_id = ?', [sourceId]);
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
  if (version < 8) {
    db.execute('BEGIN IMMEDIATE');
    try {
      db.execute(
        'CREATE INDEX IF NOT EXISTS favorites_recent_page ON favorites(created_at DESC, library_item_id ASC)',
      );
      db.execute(
        'CREATE INDEX IF NOT EXISTS custom_group_items_page ON custom_group_items(custom_group_id, ordinal, library_item_id)',
      );
      db.execute('INSERT INTO schema_migrations(version) VALUES (8)');
      db.execute('COMMIT');
    } catch (_) {
      db.execute('ROLLBACK');
      rethrow;
    }
  }
  if (version < 9) {
    db.execute('BEGIN IMMEDIATE');
    try {
      if (!_tableHasColumn(db, 'custom_groups', 'directory_ordinal')) {
        db.execute(
          'ALTER TABLE custom_groups ADD COLUMN directory_ordinal INTEGER NOT NULL DEFAULT 0',
        );
      }
      db.execute('''WITH ordered AS (
           SELECT id,
                  ROW_NUMBER() OVER (
                    ORDER BY name COLLATE NOCASE ASC, id ASC
                  ) - 1 AS ordinal
           FROM custom_groups
         )
         UPDATE custom_groups
         SET directory_ordinal = (
           SELECT ordinal FROM ordered WHERE ordered.id = custom_groups.id
         )''');
      db.execute(
        'CREATE INDEX IF NOT EXISTS custom_groups_directory ON custom_groups(directory_ordinal, id)',
      );
      db.execute(
        'CREATE INDEX IF NOT EXISTS custom_groups_home ON custom_groups(home_ordinal, id)',
      );
      db.execute('INSERT INTO schema_migrations(version) VALUES (9)');
      db.execute('COMMIT');
    } catch (_) {
      db.execute('ROLLBACK');
      rethrow;
    }
  }
  if (version < 10) {
    db.execute('BEGIN IMMEDIATE');
    try {
      // Item organization replaces one identity's complete membership set.
      // Keep that lookup keyed by the identity rather than scanning every
      // membership in every custom group at Strong scale.
      db.execute(
        'CREATE INDEX IF NOT EXISTS custom_group_items_library ON custom_group_items(library_item_id, custom_group_id)',
      );
      db.execute('INSERT INTO schema_migrations(version) VALUES (10)');
      db.execute('COMMIT');
    } catch (_) {
      db.execute('ROLLBACK');
      rethrow;
    }
  }
  if (version < 11) {
    db.execute('BEGIN IMMEDIATE');
    try {
      // Another isolate may have completed v11 while this connection waited
      // for the write lock. Re-read under the lock before any DDL/version row.
      final lockedVersion =
          db
                  .select(
                    'SELECT MAX(version) AS version FROM schema_migrations',
                  )
                  .first['version']
              as int? ??
          0;
      if (lockedVersion < 11) {
        // Episodes share the durable series identity but retain independent
        // progress through an opaque exact media key. No playback locator,
        // title, provider response, or engine error belongs in this table.
        db.execute('''CREATE TABLE IF NOT EXISTS playback_progress (
             library_item_id TEXT NOT NULL,
             media_key TEXT NOT NULL,
             position_ms INTEGER NOT NULL,
             duration_ms INTEGER NOT NULL,
             watched_ms INTEGER NOT NULL DEFAULT 0,
             completed INTEGER NOT NULL,
             cleared INTEGER NOT NULL DEFAULT 0,
             updated_at_us INTEGER NOT NULL,
             PRIMARY KEY (library_item_id, media_key),
             CHECK (position_ms >= 0),
             CHECK (duration_ms >= 0),
             CHECK (watched_ms >= 0),
             CHECK (completed IN (0, 1)),
             CHECK (cleared IN (0, 1))
           )''');
        // Version 4 reserved these columns before a UI exposed them. Normalize
        // an invalid local/manual value before installing the permanent guard.
        db.execute('''UPDATE sources SET connection_limit_override = NULL
           WHERE connection_limit_override IS NOT NULL
             AND connection_limit_override NOT IN (1, 2)''');
        db.execute(
          '''CREATE TRIGGER IF NOT EXISTS sources_connection_override_insert
           BEFORE INSERT ON sources
           WHEN NEW.connection_limit_override IS NOT NULL
             AND NEW.connection_limit_override NOT IN (1, 2)
           BEGIN
             SELECT RAISE(ABORT, 'invalid connection limit override');
           END''',
        );
        db.execute(
          '''CREATE TRIGGER IF NOT EXISTS sources_connection_override_update
           BEFORE UPDATE OF connection_limit_override ON sources
           WHEN NEW.connection_limit_override IS NOT NULL
             AND NEW.connection_limit_override NOT IN (1, 2)
           BEGIN
             SELECT RAISE(ABORT, 'invalid connection limit override');
           END''',
        );
        db.execute('INSERT INTO schema_migrations(version) VALUES (11)');
      }
      db.execute('COMMIT');
    } catch (_) {
      db.execute('ROLLBACK');
      rethrow;
    }
  }
  // Pre-verification v11 databases may already contain progress rows from the
  // first Phase 5 build. Repair that same unshipped schema in place and
  // backfill new state to zero without changing exact keys.
  if (version >= 11 &&
      (!_tableHasColumn(db, 'playback_progress', 'watched_ms') ||
          !_tableHasColumn(db, 'playback_progress', 'cleared'))) {
    db.execute('BEGIN IMMEDIATE');
    try {
      if (!_tableHasColumn(db, 'playback_progress', 'watched_ms')) {
        db.execute('''ALTER TABLE playback_progress
             ADD COLUMN watched_ms INTEGER NOT NULL DEFAULT 0
             CHECK (watched_ms >= 0)''');
      }
      if (!_tableHasColumn(db, 'playback_progress', 'cleared')) {
        db.execute('''ALTER TABLE playback_progress
             ADD COLUMN cleared INTEGER NOT NULL DEFAULT 0
             CHECK (cleared IN (0, 1))''');
      }
      db.execute('COMMIT');
    } catch (_) {
      db.execute('ROLLBACK');
      rethrow;
    }
  }
  if (version < 12) {
    db.execute('BEGIN IMMEDIATE');
    try {
      // App startup, a guide fetch, and catalog reads may all open this file at
      // once. Re-read under the writer lock so v12 is installed exactly once.
      final lockedVersion =
          db
                  .select(
                    'SELECT MAX(version) AS version FROM schema_migrations',
                  )
                  .first['version']
              as int? ??
          0;
      if (lockedVersion < 12) {
        db.execute('''CREATE TABLE IF NOT EXISTS epg_source_state (
             source_id TEXT PRIMARY KEY,
             capability TEXT NOT NULL DEFAULT 'unknown',
             last_attempt_utc_ms INTEGER,
             last_success_utc_ms INTEGER,
             retry_after_utc_ms INTEGER NOT NULL DEFAULT 0,
             last_error TEXT,
             CHECK (capability IN ('unknown', 'available', 'unsupported')),
             CHECK (retry_after_utc_ms >= 0)
           )''');
        db.execute('''CREATE TABLE IF NOT EXISTS epg_channel_state (
             catalog_item_id TEXT PRIMARY KEY,
             generation INTEGER NOT NULL DEFAULT 0,
             refresh_state TEXT NOT NULL DEFAULT 'unknown',
             last_attempt_utc_ms INTEGER,
             last_success_utc_ms INTEGER,
             retry_after_utc_ms INTEGER NOT NULL DEFAULT 0,
             last_error TEXT,
             CHECK (generation >= 0),
             CHECK (refresh_state IN
               ('unknown', 'refreshing', 'available', 'empty', 'error')),
             CHECK (retry_after_utc_ms >= 0)
           )''');
        db.execute('''CREATE TABLE IF NOT EXISTS epg_programs (
             catalog_item_id TEXT NOT NULL,
             start_utc_ms INTEGER NOT NULL,
             end_utc_ms INTEGER NOT NULL,
             title TEXT NOT NULL,
             description TEXT,
             PRIMARY KEY (catalog_item_id, start_utc_ms, end_utc_ms),
             CHECK (start_utc_ms >= 0),
             CHECK (end_utc_ms > start_utc_ms),
             CHECK (end_utc_ms - start_utc_ms <=
               ${epgMaximumProgramDuration.inMilliseconds}),
             CHECK (length(title) > 0)
           ) WITHOUT ROWID''');
        db.execute('''CREATE INDEX IF NOT EXISTS epg_programs_expiry
             ON epg_programs(end_utc_ms)''');
        db.execute('INSERT INTO schema_migrations(version) VALUES (12)');
      }
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

int? _parseReportedConnectionLimit(Object? value) {
  if (value is! Map || value['user_info'] is! Map) return null;
  final raw = (value['user_info'] as Map)['max_connections'];
  final parsed = raw is int ? raw : int.tryParse('$raw'.trim());
  return parsed != null && parsed > 0 ? parsed : null;
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
