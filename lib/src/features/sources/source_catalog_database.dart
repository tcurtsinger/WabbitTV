import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart';

import 'credential_store.dart';
import 'source_models.dart';
import 'xtream_connector.dart';

const _accountAndCategoryLimit = 8 * 1024 * 1024;
const _itemLimit = 256 * 1024 * 1024;
const _requestLimit = Duration(seconds: 120);
const _importLimit = Duration(minutes: 8);
const _cancelAcknowledgementLimit = Duration(milliseconds: 250);
const _defaultBrowsePageLimit = 100;
const _maximumBrowsePageLimit = 200;

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

class SourceCatalogDatabase {
  const SourceCatalogDatabase({
    this.databasePath,
    this.ignoreCancelForTest = false,
  });
  final String? databasePath;
  final bool ignoreCancelForTest;

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
  }

  Future<PersistedSource?> loadReadySource() async {
    final path = await resolvedPath();
    return Isolate.run<PersistedSource?>(() => _loadReadyOnWorker(path));
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

  Future<void> removeInitialSource(String sourceId) async {
    final path = await resolvedPath();
    await Isolate.run<void>(() => _deleteSourceOnWorker(path, sourceId));
  }
}

void _initialImportWorker(Map<String, Object?> args) {
  final worker = _InitialImportWorker(args);
  worker.start();
}

class _InitialImportWorker {
  _InitialImportWorker(this.args)
    : ignoreCancel = args['ignoreCancel']! as bool,
      events = args['events']! as SendPort,
      path = args['path']! as String,
      source = (args['source']! as Map<Object?, Object?>)
          .cast<String, Object?>();

  final Map<String, Object?> args;
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
      db = sqlite3.open(path);
      _migrate(db!);
      _createPending(db!, source);
      client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
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
        counts.length != SourceMediaKind.values.length) {
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
      events.send(const {'type': 'ready'});
      _close();
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
    events.send({
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
    });
    _close();
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
  final db = sqlite3.open(path);
  try {
    _migrate(db);
    return db
        .select(
          "SELECT id, credential_key FROM sources WHERE enabled = 0 OR refresh_state = 'pending'",
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

PersistedSource? _loadReadyOnWorker(String path) {
  if (!File(path).existsSync()) return null;
  final db = sqlite3.open(path);
  try {
    _migrate(db);
    final source = db.select(
      "SELECT id, name, credential_key FROM sources WHERE enabled = 1 AND refresh_state = 'ready' ORDER BY last_refresh_at DESC LIMIT 1",
    );
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

List<BrowseCategorySummary> _browseCategoriesOnWorker(
  String path,
  String sourceId,
  SourceMediaKind kind,
) {
  if (!File(path).existsSync()) return const [];
  final db = sqlite3.open(path);
  try {
    _migrate(db);
    final readySource = db.select(
      "SELECT id FROM sources WHERE id = ? AND enabled = 1 AND refresh_state = 'ready'",
      [sourceId],
    );
    if (readySource.isEmpty) return const [];

    final total =
        db.select(
              'SELECT COUNT(*) AS count FROM catalog_items WHERE source_id = ? AND kind = ? AND available = 1',
              [sourceId, kind.name],
            ).single['count']!
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
         WHERE groups.source_id = ? AND groups.content_kind = ?
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
         WHERE source_id = ? AND kind = ? AND available = 1
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
  final db = sqlite3.open(path);
  try {
    _migrate(db);
    final filters = <String>[
      "source_id = ?",
      'kind = ?',
      'available = 1',
      "EXISTS (SELECT 1 FROM sources WHERE sources.id = catalog_items.source_id AND sources.enabled = 1 AND sources.refresh_state = 'ready')",
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

SourceReady _commitFixtureOnWorker(
  String path,
  SourceDefinition source,
  List<ImportedStage> stages,
) {
  final db = sqlite3.open(path);
  try {
    _migrate(db);
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
  final db = sqlite3.open(path);
  try {
    _migrate(db);
    _deleteSource(db, sourceId);
  } finally {
    db.close();
  }
}

void _createPending(Database db, Map<String, Object?> source) {
  db.execute('BEGIN IMMEDIATE');
  try {
    db.execute(
      '''INSERT INTO sources (id, kind, name, display_endpoint, credential_key, enabled, refresh_generation, refresh_state, last_refresh_at, last_error, settings_json) VALUES (?, 'xtream', ?, ?, ?, 0, 1, 'pending', NULL, NULL, '{}')''',
      [
        source['id'],
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
      }
    } finally {
      groups.close();
    }
    final insert = db.prepare(
      '''INSERT INTO catalog_items (id, source_id, provider_key, kind, parent_id, source_group_id, title, normalized_title, playback_ref, artwork_locator, year, external_id, metadata_json, generation, available, updated_at) VALUES (?, ?, ?, ?, NULL, ?, ?, ?, ?, ?, NULL, NULL, NULL, 1, 1, ?)''',
    );
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
          DateTime.now().toUtc().toIso8601String(),
        ]);
      }
    } finally {
      insert.close();
    }
    db.execute('COMMIT');
  } catch (_) {
    db.execute('ROLLBACK');
    rethrow;
  }
}

void _deleteSource(Database db, String sourceId) {
  db.execute('BEGIN IMMEDIATE');
  try {
    db.execute('DELETE FROM catalog_items WHERE source_id = ?', [sourceId]);
    db.execute('DELETE FROM source_groups WHERE source_id = ?', [sourceId]);
    db.execute('DELETE FROM sources WHERE id = ?', [sourceId]);
    db.execute('COMMIT');
  } catch (_) {
    db.execute('ROLLBACK');
    rethrow;
  }
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
}

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
