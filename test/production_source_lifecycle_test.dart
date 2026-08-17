import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:wabbit_tv/src/features/sources/credential_store.dart';
import 'package:wabbit_tv/src/features/sources/source_catalog_database.dart';
import 'package:wabbit_tv/src/features/sources/source_models.dart';
import 'package:wabbit_tv/src/features/sources/source_setup_controller.dart';
import 'package:wabbit_tv/src/features/sources/xtream_connector.dart';

void main() {
  test(
    'production credential-write failure leaves no source or catalog rows',
    () async {
      final fixture = await _ProductionFixture.start();
      addTearDown(fixture.dispose);
      final credentials = _RecordingCredentials(failWrite: true);
      final controller = fixture.controller(credentials);

      await fixture.connect(controller);

      final db = sqlite3.open(fixture.path);
      addTearDown(db.close);
      expect(controller.ready, isNull);
      expect(credentials.deleted, contains(credentials.key));
      expect(db.select('SELECT * FROM sources'), isEmpty);
      expect(db.select('SELECT * FROM catalog_items'), isEmpty);
    },
  );

  test('production import writes credential before ready activation and restarts ready', () async {
    final fixture = await _ProductionFixture.start();
    addTearDown(fixture.dispose);
    final credentials = _RecordingCredentials(
      onWrite: () {
        final db = sqlite3.open(fixture.path);
        try {
          final row = db
              .select('SELECT enabled, refresh_state FROM sources')
              .single;
          expect(row['enabled'], 0);
          expect(row['refresh_state'], 'pending');
        } finally {
          db.close();
        }
      },
    );
    final controller = fixture.controller(credentials);

    await fixture.connect(controller);

    expect(credentials.writes, 1);
    expect(controller.ready?.counts, {
      SourceMediaKind.live: 1,
      SourceMediaKind.movies: 1,
      SourceMediaKind.series: 1,
    });
    final restarted = fixture.controller(credentials);
    await restarted.initialize();
    expect(restarted.ready?.counts, controller.ready?.counts);
  });

  test(
    'production SQLite never stores exact provider credentials or URL',
    () async {
      final fixture = await _ProductionFixture.start();
      addTearDown(fixture.dispose);
      final controller = fixture.controller(_RecordingCredentials());

      await fixture.connect(controller);

      final contents = latin1.decode(await File(fixture.path).readAsBytes());
      expect(contents, isNot(contains(fixture.username)));
      expect(contents, isNot(contains(fixture.password)));
      expect(contents, isNot(contains(fixture.serverUrl)));
    },
  );

  test('activation failure after a credential write cleans credential and pending DB', () async {
    final fixture = await _ProductionFixture.start();
    addTearDown(fixture.dispose);
    final credentials = _RecordingCredentials(
      onWrite: () {
        final db = sqlite3.open(fixture.path);
        try {
          db.execute('''
            CREATE TRIGGER abort_ready BEFORE UPDATE OF enabled ON sources
            WHEN NEW.enabled = 1
            BEGIN SELECT RAISE(ABORT, 'fixture activation failure'); END;
          ''');
        } finally {
          db.close();
        }
      },
    );
    final controller = fixture.controller(credentials);

    await fixture.connect(controller);

    final db = sqlite3.open(fixture.path);
    addTearDown(db.close);
    expect(controller.ready, isNull);
    expect(controller.failure, SourceImportFailureKind.emptyResponse);
    expect(credentials.deleted, contains(credentials.key));
    expect(db.select('SELECT * FROM sources'), isEmpty);
    expect(db.select('SELECT * FROM catalog_items'), isEmpty);
  });

  test(
    'pending DB rows are removed even when secure credential deletion fails',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'wabbit-recover-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final path = '${directory.path}${Platform.pathSeparator}catalog.sqlite';
      final database = SourceCatalogDatabase(databasePath: path);
      await database.commitInitialSource(
        const SourceDefinition(
          id: 'pending-fixture',
          name: 'Fixture',
          serverUrl: 'https://provider.example',
          username: 'fixture-user',
          password: 'fixture-password',
          credentialKey: 'fixture-key',
        ),
        const [],
      );
      final db = sqlite3.open(path);
      db.execute("UPDATE sources SET enabled = 0, refresh_state = 'pending'");
      db.close();

      await database.recoverPending(_RecordingCredentials(failDelete: true));

      final recovered = sqlite3.open(path);
      addTearDown(recovered.close);
      expect(recovered.select('SELECT * FROM sources'), isEmpty);
    },
  );
}

class _ProductionFixture {
  _ProductionFixture(this.server, this.directory)
    : path = '${directory.path}${Platform.pathSeparator}catalog.sqlite',
      serverUrl = 'http://${server.address.address}:${server.port}';

  final HttpServer server;
  final Directory directory;
  final String path;
  final String serverUrl;
  final username = 'fixture-user-exact';
  final password = 'fixture-password-exact';

  static Future<_ProductionFixture> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      final action = request.uri.queryParameters['action'];
      final body = switch (action) {
        null => '{"user_info":{"auth":1}}',
        'get_live_categories' => '[{"category_id":"l","category_name":"Live"}]',
        'get_vod_categories' =>
          '[{"category_id":"m","category_name":"Movies"}]',
        'get_series_categories' =>
          '[{"category_id":"s","category_name":"Series"}]',
        'get_live_streams' =>
          '[{"stream_id":"l1","name":"Live","category_id":"l"}]',
        'get_vod_streams' =>
          '[{"stream_id":"m1","name":"Movie","category_id":"m"}]',
        _ => '[{"series_id":"s1","name":"Series","category_id":"s"}]',
      };
      request.response.headers.contentType = ContentType.json;
      request.response.write(body);
      await request.response.close();
    });
    final directory = await Directory.systemTemp.createTemp(
      'wabbit-production-',
    );
    return _ProductionFixture(server, directory);
  }

  SourceSetupController controller(_RecordingCredentials credentials) =>
      SourceSetupController(
        productionService: SourceSetupService(
          database: SourceCatalogDatabase(databasePath: path),
        ),
        credentialStore: credentials,
      );

  Future<void> connect(SourceSetupController controller) => controller.connect(
    name: 'Fixture source',
    serverUrl: serverUrl,
    username: username,
    password: password,
  );

  Future<void> dispose() async {
    await server.close(force: true);
    await directory.delete(recursive: true);
  }
}

class _RecordingCredentials implements CredentialStore {
  _RecordingCredentials({
    this.failWrite = false,
    this.failDelete = false,
    this.onWrite,
  });

  final bool failWrite;
  final bool failDelete;
  final void Function()? onWrite;
  int writes = 0;
  String? key;
  final deleted = <String>[];

  @override
  Future<void> write({
    required String key,
    required String username,
    required String password,
    String? serverUrl,
  }) async {
    this.key = key;
    writes++;
    if (failWrite) throw StateError('fixture credential write failure');
    onWrite?.call();
  }

  @override
  Future<StoredCredential?> read(String key) async => null;

  @override
  Future<void> delete(String key) async {
    deleted.add(key);
    if (failDelete) throw StateError('fixture credential deletion failure');
  }
}
