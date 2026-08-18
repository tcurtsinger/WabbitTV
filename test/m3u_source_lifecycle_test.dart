import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:wabbit_tv/src/features/sources/source_catalog_database.dart';
import 'package:wabbit_tv/src/features/sources/source_models.dart';
import 'package:wabbit_tv/src/features/sources/credential_store.dart';
import 'package:wabbit_tv/src/features/sources/source_setup_controller.dart';
import 'package:wabbit_tv/src/features/sources/xtream_connector.dart';

void main() {
  test('M3U URL initial worker retains only safe source display data', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);
    server.listen((request) async {
      request.response.write('#EXTINF:-1,One\nhttps://stream.example/one\n');
      await request.response.close();
    });
    final temp = await Directory.systemTemp.createTemp('wabbit-m3u-life-');
    addTearDown(() => temp.delete(recursive: true));
    final path = '${temp.path}${Platform.pathSeparator}catalog.sqlite';
    final url =
        'http://${server.address.address}:${server.port}/secret.m3u?token=secret';
    final database = SourceCatalogDatabase(databasePath: path);
    final import = await database.beginM3uInitialImport(
      M3uSourceInput(
        id: 'm3u',
        name: 'M3U',
        kind: M3uSourceKind.m3uUrl,
        locator: url,
        credentialKey: 'key',
        displayEndpoint: server.address.address,
      ),
    );
    final pending = await import.pending;
    expect(pending.counts[SourceMediaKind.live], 1);
    await import.activate();
    final db = sqlite3.open(path);
    addTearDown(db.close);
    expect(
      db.select('SELECT kind, display_endpoint FROM sources').single['kind'],
      'm3u_url',
    );
    expect(
      await File(path).readAsString(encoding: latin1),
      isNot(contains(url)),
    );
  });

  test(
    'M3U refresh is idempotent and a failed refresh retains last good catalog',
    () async {
      final temp = await Directory.systemTemp.createTemp('wabbit-m3u-refresh-');
      addTearDown(() => temp.delete(recursive: true));
      final file = File('${temp.path}${Platform.pathSeparator}fixture.m3u');
      await file.writeAsString(
        '#EXTINF:-1 tvg-id="one",One\nhttps://stream.example/one\n',
      );
      final database = SourceCatalogDatabase(
        databasePath: '${temp.path}${Platform.pathSeparator}catalog.sqlite',
      );
      final initial = await database.beginM3uInitialImport(
        M3uSourceInput(
          id: 'm3u',
          name: 'M3U',
          kind: M3uSourceKind.m3uFile,
          locator: file.path,
          credentialKey: 'key',
          displayEndpoint: 'fixture.m3u',
        ),
      );
      await initial.pending;
      await initial.activate();
      final refresh = await database.beginM3uRefresh(
        sourceId: 'm3u',
        locator: file.path,
        isUrl: false,
      );
      await refresh.completed;
      await file.writeAsString('#EXTINF:-1,Broken\nnot-a-url\n');
      final failed = await database.beginM3uRefresh(
        sourceId: 'm3u',
        locator: file.path,
        isUrl: false,
      );
      await expectLater(failed.completed, throwsA(isA<SourceImportFailure>()));
      final db = sqlite3.open(await database.resolvedPath());
      addTearDown(db.close);
      expect(
        db
            .select(
              'SELECT COUNT(*) AS count FROM catalog_items WHERE available = 1',
            )
            .single['count'],
        1,
      );
      expect(
        db.select('SELECT refresh_state FROM sources').single['refresh_state'],
        'ready',
      );
    },
  );
  test(
    'targeted remove deletes only the selected source and credential',
    () async {
      final fixture = await _RemovalFixture.create();
      addTearDown(fixture.dispose);
      final controller = fixture.controller();
      expect(await controller.removeManagedSource('one'), isTrue);
      final db = sqlite3.open(fixture.path);
      addTearDown(db.close);
      expect(
        db.select('SELECT id FROM sources ORDER BY id').single['id'],
        'two',
      );
      expect(fixture.credentials.values.containsKey('one-key'), isFalse);
      expect(fixture.credentials.values.containsKey('two-key'), isTrue);
    },
  );

  test(
    'targeted remove cleans up a source whose credential is already absent',
    () async {
      final fixture = await _RemovalFixture.create();
      addTearDown(fixture.dispose);
      fixture.credentials.values.remove('one-key');

      expect(await fixture.controller().removeManagedSource('one'), isTrue);

      final db = sqlite3.open(fixture.path);
      addTearDown(db.close);
      expect(
        db.select('SELECT id FROM sources ORDER BY id').single['id'],
        'two',
      );
      expect(
        db
            .select('SELECT source_id FROM catalog_items ORDER BY source_id')
            .single['source_id'],
        'two',
      );
      expect(fixture.credentials.values.containsKey('two-key'), isTrue);
    },
  );

  test(
    'secure delete failure retains selected source, catalog, and credential',
    () async {
      final fixture = await _RemovalFixture.create();
      addTearDown(fixture.dispose);
      fixture.credentials.failDelete = true;
      expect(await fixture.controller().removeManagedSource('one'), isFalse);
      final db = sqlite3.open(fixture.path);
      addTearDown(db.close);
      expect(
        db.select('SELECT id FROM sources WHERE id = ?', ['one']),
        isNotEmpty,
      );
      expect(
        db.select('SELECT id FROM catalog_items WHERE source_id = ?', ['one']),
        isNotEmpty,
      );
      expect(fixture.credentials.values['one-key']?.serverUrl, 'file-one');
    },
  );

  test(
    'DB remove failure restores the exact prior credential and source',
    () async {
      final fixture = await _RemovalFixture.create();
      addTearDown(fixture.dispose);
      final prior = fixture.credentials.values['one-key']!;
      final service = SourceSetupService(
        database: fixture.database,
        removeSourceForTest: (_) => Future.error(StateError('db')),
      );
      expect(
        await SourceSetupController(
          productionService: service,
          credentialStore: fixture.credentials,
        ).removeManagedSource('one'),
        isFalse,
      );
      final restored = fixture.credentials.values['one-key']!;
      expect(
        (restored.username, restored.password, restored.serverUrl),
        (prior.username, prior.password, prior.serverUrl),
      );
      final db = sqlite3.open(fixture.path);
      addTearDown(db.close);
      expect(
        db.select('SELECT id FROM sources WHERE id = ?', ['one']),
        isNotEmpty,
      );
      expect(
        db.select('SELECT id FROM catalog_items WHERE source_id = ?', ['one']),
        isNotEmpty,
      );
    },
  );
  test(
    'local-file initial keeps basename in SQLite and full path in credentials',
    () async {
      final temp = await Directory.systemTemp.createTemp('wabbit-m3u-file-');
      addTearDown(() => temp.delete(recursive: true));
      final file = File(
        '${temp.path}${Platform.pathSeparator}private-list.m3u',
      );
      await file.writeAsString('#EXTINF:-1,One\nhttps://stream.example/one\n');
      final database = SourceCatalogDatabase(
        databasePath: '${temp.path}${Platform.pathSeparator}catalog.sqlite',
      );
      final credentials = _MemoryCredentials();
      final controller = SourceSetupController(
        productionService: SourceSetupService(database: database),
        credentialStore: credentials,
      );
      await controller.connectM3uFile(name: 'File', path: file.path);
      final db = sqlite3.open(await database.resolvedPath());
      addTearDown(db.close);
      expect(
        db
            .select('SELECT display_endpoint FROM sources')
            .single['display_endpoint'],
        'private-list.m3u',
      );
      expect(
        await File(await database.resolvedPath())
            .readAsString(encoding: latin1),
        isNot(contains(file.path)),
      );
      expect(credentials.values.values.single.serverUrl, file.path);
    },
  );

  test(
    'unreadable local-file initial leaves no source or credential',
    () async {
      final temp = await Directory.systemTemp.createTemp('wabbit-m3u-missing-');
      addTearDown(() => temp.delete(recursive: true));
      final database = SourceCatalogDatabase(
        databasePath: '${temp.path}${Platform.pathSeparator}catalog.sqlite',
      );
      final credentials = _MemoryCredentials();
      await SourceSetupController(
        productionService: SourceSetupService(database: database),
        credentialStore: credentials,
      ).connectM3uFile(
        name: 'Missing',
        path: '${temp.path}${Platform.pathSeparator}missing.m3u',
      );
      expect(credentials.values, isEmpty);
      final db = sqlite3.open(await database.resolvedPath());
      addTearDown(db.close);
      expect(db.select('SELECT * FROM sources'), isEmpty);
    },
  );

  test('cancelling a delayed M3U URL refresh waits for worker acknowledgement and preserves the last-good catalog', () async {
    final delayedRequest = Completer<void>();
    final releaseDelayedResponse = Completer<void>();
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      if (request.uri.path == '/delayed.m3u') {
        if (!delayedRequest.isCompleted) delayedRequest.complete();
        await releaseDelayedResponse.future;
        try {
          request.response.write(
            '#EXTINF:-1,Stale replacement\nhttps://stream.example/stale\n',
          );
          await request.response.close();
        } on HttpException {
          // The controller deliberately closes the worker client on cancellation.
        }
        return;
      }
      request.response.write(
        '#EXTINF:-1,Last good\nhttps://stream.example/good\n',
      );
      await request.response.close();
    });
    final temp = await Directory.systemTemp.createTemp('wabbit-m3u-cancel-');
    addTearDown(() => temp.delete(recursive: true));
    final database = SourceCatalogDatabase(
      databasePath: '${temp.path}${Platform.pathSeparator}catalog.sqlite',
    );
    final credentials = _MemoryCredentials();
    final controller = SourceSetupController(
      productionService: SourceSetupService(database: database),
      credentialStore: credentials,
    );
    final base = 'http://${server.address.address}:${server.port}';
    await controller.connectM3uUrl(name: 'M3U', url: '$base/initial.m3u');
    final sourceId = controller.persisted!.id;

    final refresh = controller.refreshM3uSource(
      sourceId,
      replacementLocator: '$base/delayed.m3u',
    );
    await delayedRequest.future.timeout(const Duration(seconds: 5));
    expect(controller.busy, isTrue);

    final cancellation = controller.cancel();
    // cancel() has requested cancellation but has not yet observed the worker's
    // terminal response; starting another refresh here would race that worker.
    expect(controller.busy, isTrue);
    await cancellation;
    await refresh;

    expect(controller.busy, isFalse);
    expect(controller.failure, isNull);
    final db = sqlite3.open(await database.resolvedPath());
    addTearDown(db.close);
    expect(
      db
          .select('SELECT title FROM catalog_items WHERE available = 1')
          .single['title'],
      'Last good',
    );
    expect(
      db.select('SELECT refresh_state FROM sources').single['refresh_state'],
      'ready',
    );
    expect(
      db.select('SELECT last_error FROM sources').single['last_error'],
      'cancelled',
    );

    releaseDelayedResponse.complete();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(
      db
          .select('SELECT title FROM catalog_items WHERE available = 1')
          .single['title'],
      'Last good',
    );
  });

  test('an edited M3U locator is stored before refresh and retry uses it after a failed refresh', () async {
    final temp = await Directory.systemTemp.createTemp('wabbit-m3u-edit-');
    addTearDown(() => temp.delete(recursive: true));
    final initialFile = File(
      '${temp.path}${Platform.pathSeparator}initial.m3u',
    );
    final replacementFile = File(
      '${temp.path}${Platform.pathSeparator}replacement.m3u',
    );
    await initialFile.writeAsString(
      '#EXTINF:-1,Original\nhttps://stream.example/original\n',
    );
    // This is a valid M3U envelope with no usable stream; the failed refresh must
    // keep the original catalog and the replacement locator.
    await replacementFile.writeAsString('#EXTINF:-1,Broken\nnot-a-url\n');
    final database = SourceCatalogDatabase(
      databasePath: '${temp.path}${Platform.pathSeparator}catalog.sqlite',
    );
    final credentials = _MemoryCredentials();
    final controller = SourceSetupController(
      productionService: SourceSetupService(database: database),
      credentialStore: credentials,
    );
    await controller.connectM3uFile(name: 'M3U', path: initialFile.path);
    final source = controller.persisted!;

    await controller.refreshM3uSource(
      source.id,
      replacementLocator: replacementFile.path,
    );

    expect(controller.failure, SourceImportFailureKind.emptyResponse);
    expect(
      credentials.values[source.credentialKey]?.serverUrl,
      replacementFile.path,
    );
    final db = sqlite3.open(await database.resolvedPath());
    addTearDown(db.close);
    expect(
      db
          .select('SELECT title FROM catalog_items WHERE available = 1')
          .single['title'],
      'Original',
    );
    expect(
      db.select('SELECT refresh_state FROM sources').single['refresh_state'],
      'ready',
    );

    await replacementFile.writeAsString(
      '#EXTINF:-1,Replacement\nhttps://stream.example/replacement\n',
    );
    await controller.refreshManagedSource(source.id);

    expect(controller.failure, isNull);
    expect(
      db
          .select('SELECT title FROM catalog_items WHERE available = 1')
          .single['title'],
      'Replacement',
    );
    expect(
      credentials.values[source.credentialKey]?.serverUrl,
      replacementFile.path,
    );
  });
}

class _MemoryCredentials implements CredentialStore {
  final values = <String, StoredCredential>{};
  bool failDelete = false;
  @override
  Future<void> delete(String key) async {
    if (failDelete) throw StateError('delete');
    values.remove(key);
  }

  @override
  Future<StoredCredential?> read(String key) async => values[key];
  @override
  Future<void> write({
    required String key,
    required String username,
    required String password,
    String? serverUrl,
  }) async {
    values[key] = StoredCredential(
      username: username,
      password: password,
      serverUrl: serverUrl,
    );
  }
}

class _RemovalFixture {
  _RemovalFixture(this.directory, this.database, this.credentials)
    : path = '${directory.path}${Platform.pathSeparator}catalog.sqlite';
  final Directory directory;
  final SourceCatalogDatabase database;
  final _MemoryCredentials credentials;
  final String path;
  static Future<_RemovalFixture> create() async {
    final directory = await Directory.systemTemp.createTemp('wabbit-remove-');
    final path = '${directory.path}${Platform.pathSeparator}catalog.sqlite';
    final database = SourceCatalogDatabase(databasePath: path);
    final credentials = _MemoryCredentials();
    for (final id in ['one', 'two']) {
      await database.commitInitialSource(
        SourceDefinition(
          id: id,
          name: id,
          serverUrl: 'https://$id.example',
          username: 'u',
          password: 'p',
          credentialKey: '$id-key',
        ),
        [
          ImportedStage(
            kind: SourceMediaKind.live,
            categories: const [],
            items: [
              ImportedCatalogItem(
                providerKey: 'p',
                title: id,
                categoryKey: null,
                playbackRef: '{}',
              ),
            ],
          ),
        ],
      );
      await credentials.write(
        key: '$id-key',
        username: '',
        password: '',
        serverUrl: 'file-$id',
      );
    }
    return _RemovalFixture(directory, database, credentials);
  }

  SourceSetupController controller() => SourceSetupController(
    productionService: SourceSetupService(database: database),
    credentialStore: credentials,
  );
  Future<void> dispose() => directory.delete(recursive: true);
}
