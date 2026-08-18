import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:wabbit_tv/src/features/sources/credential_store.dart';
import 'package:wabbit_tv/src/features/sources/source_catalog_database.dart';
import 'package:wabbit_tv/src/features/sources/source_models.dart';
import 'package:wabbit_tv/src/features/sources/source_setup_controller.dart';
import 'package:wabbit_tv/src/features/sources/xtream_connector.dart';

void main() {
  test('Xtream refresh is idempotent, retires missing rows, and roster rename is local', () async {
    var requests = 0;
    var second = false;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      requests++;
      final action = request.uri.queryParameters['action'];
      final body = switch (action) {
        'get_live_categories' => '[]',
        'get_vod_categories' || 'get_series_categories' => '[]',
        'get_live_streams' => second ? '[{"stream_id":"new","name":"New"}]' : '[{"stream_id":"old","name":"Old"},{"stream_id":"new","name":"New"}]',
        'get_vod_streams' => '[{"stream_id":"movie","name":"Movie"}]',
        'get_series' => '[{"series_id":"series","name":"Series"}]',
        _ => '{"user_info":{"auth":1}}',
      };
      request.response.write(body);
      await request.response.close();
    });
    final dir = await Directory.systemTemp.createTemp('wabbit-xtream-refresh-');
    addTearDown(() => dir.delete(recursive: true));
    final path = '${dir.path}${Platform.pathSeparator}catalog.sqlite';
    final database = SourceCatalogDatabase(databasePath: path);
    final source = SourceDefinition(
      id: 'x',
      name: 'Before',
      serverUrl: 'http://${server.address.address}:${server.port}',
      username: 'u',
      password: 'p',
      credentialKey: 'key',
    );
    await database.commitInitialSource(source, [
      const ImportedStage(
        kind: SourceMediaKind.live,
        categories: [],
        items: [
          ImportedCatalogItem(
            providerKey: 'old',
            title: 'Old',
            categoryKey: null,
            playbackRef: 'old',
          ),
        ],
      ),
    ]);
    final credentials = _Credentials(source.serverUrl);
    final controller = SourceSetupController(
      productionService: SourceSetupService(database: database),
      credentialStore: credentials,
    );
    await controller.refreshManagedSource('x');
    second = true;
    await controller.refreshManagedSource('x');
    final db = sqlite3.open(path);
    addTearDown(db.close);
    expect(
      db.select(
        'SELECT id FROM catalog_items WHERE source_id = ? AND available = 1',
        ['x'],
      ),
      hasLength(3),
    );
    expect(
      db
          .select("SELECT available FROM catalog_items WHERE id = 'x:live:old'")
          .single['available'],
      0,
    );
    final beforeRenameRequests = requests;
    await controller.renameManagedSource('x', 'After');
    expect(requests, beforeRenameRequests);
    expect((await controller.loadSourceRoster()).single.name, 'After');
  });

  test(
    'Xtream refresh failure is redacted and retains last-good catalog',
    () async {
      var reject = false;
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        if (reject) {
          request.response.statusCode = HttpStatus.unauthorized;
        } else {
          final action = request.uri.queryParameters['action'];
          request.response.write(
            action == null
                ? '{"user_info":{"auth":1}}'
                : action.contains('categories')
                ? '[]'
                : '[{"stream_id":"one","name":"One"}]',
          );
        }
        await request.response.close();
      });
      final fixture = await _XtreamFixture.create(server, id: 'failure');
      addTearDown(fixture.dispose);
      await fixture.controller.refreshManagedSource('failure');
      reject = true;
      await fixture.controller.refreshManagedSource('failure');
      final rows = fixture.db.select(
        'SELECT available FROM catalog_items WHERE source_id = ? AND available = 1',
        ['failure'],
      );
      expect(rows, isNotEmpty);
      expect(rows.every((row) => row['available'] == 1), isTrue);
      final source = fixture.db.select(
        'SELECT refresh_state, last_error FROM sources WHERE id = ?',
        ['failure'],
      ).single;
      expect(source['refresh_state'], 'ready');
      expect(source['last_error'], 'authentication');
    },
  );

  test(
    'Xtream refresh authenticates before accepting empty media stages',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        final action = request.uri.queryParameters['action'];
        request.response.write(
          action == null ? '{"user_info":{"auth":0}}' : '[]',
        );
        await request.response.close();
      });
      final fixture = await _XtreamFixture.create(server, id: 'expired');
      addTearDown(fixture.dispose);

      await fixture.controller.refreshManagedSource('expired');

      expect(
        fixture.controller.failure,
        SourceImportFailureKind.authentication,
      );
      expect(
        fixture.db.select(
          'SELECT COUNT(*) AS count FROM catalog_items WHERE source_id = ? AND available = 1',
          ['expired'],
        ).single['count'],
        1,
      );
      expect(
        fixture.db.select(
          'SELECT refresh_state, last_error FROM sources WHERE id = ?',
          ['expired'],
        ).single,
        containsPair('last_error', 'authentication'),
      );
    },
  );

  test('Xtream refresh bounds a stalled response body', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final requests = server.listen((request) {
      final action = request.uri.queryParameters['action'];
      if (action == null) {
        request.response.write('{"user_info":{"auth":1}}');
        unawaited(request.response.close());
        return;
      }
      if (action == 'get_live_categories') {
        request.response.write('[');
        unawaited(request.response.flush());
        return;
      }
      request.response.write('[]');
      unawaited(request.response.close());
    });
    addTearDown(() async {
      await server.close(force: true);
      await requests.cancel();
    });
    final dir = await Directory.systemTemp.createTemp(
      'wabbit-xtream-body-deadline-',
    );
    addTearDown(() => dir.delete(recursive: true));
    final path = '${dir.path}${Platform.pathSeparator}catalog.sqlite';
    final database = SourceCatalogDatabase(databasePath: path);
    const source = SourceDefinition(
      id: 'deadline',
      name: 'Deadline',
      serverUrl: 'http://placeholder.invalid',
      username: 'u',
      password: 'p',
      credentialKey: 'key',
    );
    await database.commitInitialSource(source, [
      const ImportedStage(
        kind: SourceMediaKind.live,
        categories: [],
        items: [
          ImportedCatalogItem(
            providerKey: 'old',
            title: 'Old',
            categoryKey: null,
            playbackRef: 'old',
          ),
        ],
      ),
    ]);
    final refresh = await database.beginXtreamRefresh(
      sourceId: source.id,
      serverUrl: 'http://${server.address.address}:${server.port}',
      username: source.username,
      password: source.password,
      requestLimit: const Duration(milliseconds: 100),
    );

    await expectLater(
      refresh.completed.timeout(const Duration(seconds: 3)),
      throwsA(
        isA<SourceImportFailure>().having(
          (error) => error.kind,
          'kind',
          SourceImportFailureKind.timedOut,
        ),
      ),
    );
    final db = sqlite3.open(path);
    addTearDown(db.close);
    expect(
      db.select(
        'SELECT COUNT(*) AS count FROM catalog_items WHERE source_id = ? AND available = 1',
        [source.id],
      ).single['count'],
      1,
    );
    expect(
      db.select('SELECT refresh_state, last_error FROM sources WHERE id = ?', [
        source.id,
      ]).single,
      containsPair('last_error', 'timedOut'),
    );
  });

  test(
    'Xtream refresh accepts empty stages and retires their old items',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        final action = request.uri.queryParameters['action'];
        request.response.write(switch (action) {
          'get_live_categories' ||
          'get_vod_categories' ||
          'get_series_categories' => '[]',
          'get_live_streams' => '[{"stream_id":"new-live","name":"New live"}]',
          'get_vod_streams' || 'get_series' => '[]',
          _ => '{"user_info":{"auth":1}}',
        });
        await request.response.close();
      });
      final dir = await Directory.systemTemp.createTemp(
        'wabbit-xtream-empty-refresh-',
      );
      addTearDown(() => dir.delete(recursive: true));
      final path = '${dir.path}${Platform.pathSeparator}catalog.sqlite';
      final database = SourceCatalogDatabase(databasePath: path);
      final source = SourceDefinition(
        id: 'live-only-refresh',
        name: 'Before',
        serverUrl: 'http://${server.address.address}:${server.port}',
        username: 'u',
        password: 'p',
        credentialKey: 'key',
      );
      await database.commitInitialSource(source, [
        for (final kind in SourceMediaKind.values)
          ImportedStage(
            kind: kind,
            categories: const [],
            items: [
              ImportedCatalogItem(
                providerKey: 'old-${kind.name}',
                title: 'Old ${kind.label}',
                categoryKey: null,
                playbackRef: 'old-${kind.name}',
              ),
            ],
          ),
      ]);
      final controller = SourceSetupController(
        productionService: SourceSetupService(database: database),
        credentialStore: _Credentials(source.serverUrl),
      );

      await controller.refreshManagedSource(source.id);

      final db = sqlite3.open(path);
      addTearDown(db.close);
      expect(controller.failure, isNull);
      expect(
        db
            .select(
              '''SELECT kind, COUNT(*) AS count
           FROM catalog_items
           WHERE source_id = ? AND available = 1
           GROUP BY kind''',
              [source.id],
            )
            .map((row) => '${row['kind']}:${row['count']}'),
        ['live:1'],
      );
      expect(
        db.select(
          'SELECT refresh_state, last_error FROM sources WHERE id = ?',
          [source.id],
        ).single,
        containsPair('refresh_state', 'ready'),
      );
    },
  );

  test('Xtream cancellation remains busy until acknowledgement and retains catalog', () async {
    final requested = Completer<void>();
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      if (!requested.isCompleted) requested.complete();
      await Future<void>.delayed(const Duration(seconds: 10));
      await request.response.close();
    });
    final fixture = await _XtreamFixture.create(server, id: 'cancel');
    addTearDown(fixture.dispose);
    final refreshing = fixture.controller.refreshManagedSource('cancel');
    await requested.future.timeout(const Duration(seconds: 2));
    expect(fixture.controller.busy, isTrue);
    final cancelling = fixture.controller.cancel();
    expect(fixture.controller.busy, isTrue);
    await cancelling;
    await refreshing;
    expect(fixture.controller.busy, isFalse);
    expect(
      fixture.db.select(
        'SELECT available FROM catalog_items WHERE source_id = ? AND available = 1',
        ['cancel'],
      ).single['available'],
      1,
    );
  });

  test(
    'managed refresh dispatches an M3U source without Xtream requests',
    () async {
      final dir = await Directory.systemTemp.createTemp('wabbit-m3u-dispatch-');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}${Platform.pathSeparator}source.m3u');
      await file.writeAsString(
        '#EXTINF:-1,Before\nhttps://example.test/before\n',
      );
      final database = SourceCatalogDatabase(
        databasePath: '${dir.path}${Platform.pathSeparator}catalog.sqlite',
      );
      final initial = await database.beginM3uInitialImport(
        M3uSourceInput(
          id: 'm3u',
          name: 'M3U',
          kind: M3uSourceKind.m3uFile,
          locator: file.path,
          credentialKey: 'm3u-key',
          displayEndpoint: 'source.m3u',
        ),
      );
      await initial.pending;
      await initial.activate();
      await file.writeAsString(
        '#EXTINF:-1,After\nhttps://example.test/after\n',
      );
      final controller = SourceSetupController(
        productionService: SourceSetupService(database: database),
        credentialStore: _Credentials(file.path),
      );
      await controller.refreshManagedSource('m3u');
      final db = sqlite3.open(await database.resolvedPath());
      addTearDown(db.close);
      expect(
        db
            .select(
              "SELECT title FROM catalog_items WHERE source_id = 'm3u' AND available = 1",
            )
            .single['title'],
        'After',
      );
      expect((await controller.loadSourceRoster()).single.kind, 'm3u_file');
    },
  );
}

class _XtreamFixture {
  _XtreamFixture(this.db, this.controller, this._dir);
  final Database db;
  final SourceSetupController controller;
  final Directory _dir;

  static Future<_XtreamFixture> create(
    HttpServer server, {
    required String id,
  }) async {
    final dir = await Directory.systemTemp.createTemp('wabbit-xtream-fixture-');
    final path = '${dir.path}${Platform.pathSeparator}catalog.sqlite';
    final database = SourceCatalogDatabase(databasePath: path);
    final source = SourceDefinition(
      id: id,
      name: id,
      serverUrl: 'http://${server.address.address}:${server.port}',
      username: 'u',
      password: 'p',
      credentialKey: '$id-key',
    );
    await database.commitInitialSource(source, [
      const ImportedStage(
        kind: SourceMediaKind.live,
        categories: [],
        items: [
          ImportedCatalogItem(
            providerKey: 'old',
            title: 'Old',
            categoryKey: null,
            playbackRef: 'old',
          ),
        ],
      ),
    ]);
    return _XtreamFixture(
      sqlite3.open(path),
      SourceSetupController(
        productionService: SourceSetupService(database: database),
        credentialStore: _Credentials(source.serverUrl),
      ),
      dir,
    );
  }

  Future<void> dispose() async {
    db.close();
    await _dir.delete(recursive: true);
  }
}

class _Credentials implements CredentialStore {
  _Credentials(this.url);
  final String url;
  @override
  Future<void> delete(String key) async {}
  @override
  Future<StoredCredential?> read(String key) async =>
      StoredCredential(username: 'u', password: 'p', serverUrl: url);
  @override
  Future<void> write({
    required String key,
    required String username,
    required String password,
    String? serverUrl,
  }) async {}
}
