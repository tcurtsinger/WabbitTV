import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:wabbit_tv/src/features/sources/credential_store.dart';
import 'package:wabbit_tv/src/features/sources/source_catalog_database.dart';
import 'package:wabbit_tv/src/features/sources/source_editor.dart';
import 'package:wabbit_tv/src/features/sources/source_models.dart';
import 'package:wabbit_tv/src/features/sources/source_setup_controller.dart';
import 'package:wabbit_tv/src/features/sources/xtream_connector.dart';

void main() {
  test(
    'Xtream editor loads its saved credential and saves before refreshing',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        final action = request.uri.queryParameters['action'];
        request.response.write(switch (action) {
          'get_live_categories' ||
          'get_vod_categories' ||
          'get_series_categories' => '[]',
          'get_live_streams' => '[{"stream_id":"after","name":"After edit"}]',
          'get_vod_streams' => '[{"stream_id":"movie","name":"Movie"}]',
          'get_series' => '[{"series_id":"series","name":"Series"}]',
          _ => '{"user_info":{"auth":1}}',
        });
        await request.response.close();
      });
      final fixture = await _Fixture.createXtream(server);
      addTearDown(fixture.dispose);

      final draft = await fixture.controller.loadEditor(
        const SourceEditorRequest(
          sourceId: 'xtream',
          sourceName: 'Before',
          databaseKind: 'xtream',
        ),
      );
      expect(draft, isNotNull);
      expect(draft!.endpoint, contains('127.0.0.1'));
      expect(draft.username, 'old-user');
      expect(draft.password, 'old-password');

      final saved = await fixture.controller.saveEditor(
        draft: draft,
        name: 'After',
        endpoint: draft.endpoint,
        username: 'new-user',
        password: 'new-password',
      );

      expect(saved, isTrue);
      expect(
        (await fixture.controller.loadSourceRoster()).single.name,
        'After',
      );
      expect(fixture.credentials.values['xtream-key']!.username, 'new-user');
      expect(
        fixture.credentials.values['xtream-key']!.password,
        'new-password',
      );
      expect(
        fixture.db
            .select(
              "SELECT title FROM catalog_items WHERE source_id = 'xtream' AND kind = 'live' AND available = 1",
            )
            .single['title'],
        'After edit',
      );
    },
  );

  test('editor validation leaves the saved connector untouched', () async {
    final fixture = await _Fixture.createLocalM3u();
    addTearDown(fixture.dispose);
    final draft = await fixture.controller.loadEditor(
      const SourceEditorRequest(
        sourceId: 'm3u',
        sourceName: 'Weekend',
        databaseKind: 'm3u_file',
      ),
    );

    final saved = await fixture.controller.saveEditor(
      draft: draft!,
      name: '',
      endpoint: '',
      username: '',
      password: '',
    );

    expect(saved, isFalse);
    expect(fixture.controller.fieldErrors['name'], 'Enter a source name.');
    expect(
      fixture.credentials.values['m3u-key']!.serverUrl,
      fixture.initialFile.path,
    );
  });

  test('failed M3U edit keeps the replacement locator for retry and last-good catalog', () async {
    final fixture = await _Fixture.createLocalM3u();
    addTearDown(fixture.dispose);
    final draft = await fixture.controller.loadEditor(
      const SourceEditorRequest(
        sourceId: 'm3u',
        sourceName: 'Weekend',
        databaseKind: 'm3u_file',
      ),
    );
    final broken = File(
      '${fixture.directory.path}${Platform.pathSeparator}broken.m3u',
    );
    await broken.writeAsString('#EXTINF:-1,Broken\nnot a stream\n');

    final saved = await fixture.controller.saveEditor(
      draft: draft!,
      name: 'Renamed weekend',
      endpoint: broken.path,
      username: '',
      password: '',
    );

    expect(saved, isFalse);
    expect(fixture.credentials.values['m3u-key']!.serverUrl, broken.path);
    expect(
      fixture.db
          .select(
            "SELECT title FROM catalog_items WHERE source_id = 'm3u' AND available = 1",
          )
          .single['title'],
      'Last good',
    );
    expect(
      (await fixture.controller.loadSourceRoster()).single.name,
      'Renamed weekend',
    );
  });

  test(
    'editor reserves one save before its first asynchronous write',
    () async {
      final server = await _xtreamServer();
      addTearDown(() => server.close(force: true));
      final fixture = await _Fixture.createXtream(server);
      addTearDown(fixture.dispose);
      final draft = await fixture.controller.loadEditor(
        const SourceEditorRequest(
          sourceId: 'xtream',
          sourceName: 'Before',
          databaseKind: 'xtream',
        ),
      );
      final gate = Completer<void>();
      fixture.credentials.writeGate = gate;

      final first = fixture.controller.saveEditor(
        draft: draft!,
        name: 'After',
        endpoint: draft.endpoint,
        username: 'new-user',
        password: 'new-password',
      );
      await fixture.credentials.writeStarted.future;
      expect(fixture.controller.isImporting, isTrue);

      final second = await fixture.controller.saveEditor(
        draft: draft,
        name: 'Competing',
        endpoint: draft.endpoint,
        username: 'other-user',
        password: 'other-password',
      );
      expect(second, isFalse);
      expect(fixture.credentials.writeCalls, 1);

      gate.complete();
      expect(await first, isTrue);
      expect(fixture.credentials.writeCalls, 1);
      expect(
        (await fixture.controller.loadSourceRoster()).single.name,
        'After',
      );
    },
  );

  test(
    'editor converts credential persistence exceptions into a local failure',
    () async {
      final server = await _xtreamServer();
      addTearDown(() => server.close(force: true));
      final fixture = await _Fixture.createXtream(server);
      addTearDown(fixture.dispose);
      final draft = await fixture.controller.loadEditor(
        const SourceEditorRequest(
          sourceId: 'xtream',
          sourceName: 'Before',
          databaseKind: 'xtream',
        ),
      );
      fixture.credentials.writeError = StateError('credential fixture failure');

      final saved = await fixture.controller.saveEditor(
        draft: draft!,
        name: 'After',
        endpoint: draft.endpoint,
        username: 'new-user',
        password: 'new-password',
      );

      expect(saved, isFalse);
      expect(
        fixture.controller.failure,
        SourceImportFailureKind.localPersistence,
      );
      expect(fixture.controller.isImporting, isFalse);
    },
  );

  test('editor converts rename exceptions into a local failure before credential write', () async {
    final server = await _xtreamServer();
    addTearDown(() => server.close(force: true));
    final fixture = await _Fixture.createXtream(
      server,
      renameSourceForTest: (_, _) =>
          Future<void>.error(StateError('rename fixture failure')),
    );
    addTearDown(fixture.dispose);
    final draft = await fixture.controller.loadEditor(
      const SourceEditorRequest(
        sourceId: 'xtream',
        sourceName: 'Before',
        databaseKind: 'xtream',
      ),
    );

    final saved = await fixture.controller.saveEditor(
      draft: draft!,
      name: 'After',
      endpoint: draft.endpoint,
      username: 'new-user',
      password: 'new-password',
    );

    expect(saved, isFalse);
    expect(
      fixture.controller.failure,
      SourceImportFailureKind.localPersistence,
    );
    expect(fixture.credentials.writeCalls, 0);
    expect((await fixture.controller.loadSourceRoster()).single.name, 'Before');
  });
}

Future<HttpServer> _xtreamServer() async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((request) async {
    final action = request.uri.queryParameters['action'];
    request.response.write(switch (action) {
      'get_live_categories' ||
      'get_vod_categories' ||
      'get_series_categories' => '[]',
      'get_live_streams' => '[{"stream_id":"after","name":"After edit"}]',
      'get_vod_streams' => '[{"stream_id":"movie","name":"Movie"}]',
      'get_series' => '[{"series_id":"series","name":"Series"}]',
      _ => '{"user_info":{"auth":1}}',
    });
    await request.response.close();
  });
  return server;
}

class _Fixture {
  _Fixture(this.directory, this.database, this.credentials, this.controller)
    : db = sqlite3.open(
        '${directory.path}${Platform.pathSeparator}catalog.sqlite',
      );

  final Directory directory;
  final SourceCatalogDatabase database;
  final _Credentials credentials;
  final SourceSetupController controller;
  final Database db;
  late final File initialFile;

  static Future<_Fixture> createXtream(
    HttpServer server, {
    Future<void> Function(String sourceId, String name)? renameSourceForTest,
  }) async {
    final directory = await Directory.systemTemp.createTemp(
      'wabbit-editor-xtream-',
    );
    final database = SourceCatalogDatabase(
      databasePath: '${directory.path}${Platform.pathSeparator}catalog.sqlite',
    );
    final url = 'http://${server.address.address}:${server.port}';
    await database.commitInitialSource(
      SourceDefinition(
        id: 'xtream',
        name: 'Before',
        serverUrl: url,
        username: 'old-user',
        password: 'old-password',
        credentialKey: 'xtream-key',
      ),
      [_stage('Before edit')],
    );
    final credentials = _Credentials()
      ..values['xtream-key'] = StoredCredential(
        username: 'old-user',
        password: 'old-password',
        serverUrl: url,
      );
    return _Fixture(
      directory,
      database,
      credentials,
      SourceSetupController(
        productionService: SourceSetupService(
          database: database,
          renameSourceForTest: renameSourceForTest,
        ),
        credentialStore: credentials,
      ),
    );
  }

  static Future<_Fixture> createLocalM3u() async {
    final directory = await Directory.systemTemp.createTemp(
      'wabbit-editor-m3u-',
    );
    final database = SourceCatalogDatabase(
      databasePath: '${directory.path}${Platform.pathSeparator}catalog.sqlite',
    );
    final file = File('${directory.path}${Platform.pathSeparator}initial.m3u');
    await file.writeAsString(
      '#EXTINF:-1,Last good\nhttps://stream.example/good\n',
    );
    await database.commitInitialSource(
      SourceDefinition(
        id: 'm3u',
        name: 'Weekend',
        serverUrl: 'https://never-stored.example',
        username: '',
        password: '',
        credentialKey: 'm3u-key',
      ),
      [_stage('Last good')],
    );
    final credentials = _Credentials()
      ..values['m3u-key'] = StoredCredential(
        username: '',
        password: '',
        serverUrl: file.path,
      );
    final fixture = _Fixture(
      directory,
      database,
      credentials,
      SourceSetupController(
        productionService: SourceSetupService(database: database),
        credentialStore: credentials,
      ),
    );
    fixture.initialFile = file;
    fixture.db.execute("UPDATE sources SET kind = 'm3u_file' WHERE id = 'm3u'");
    return fixture;
  }

  Future<void> dispose() async {
    db.close();
    await directory.delete(recursive: true);
  }
}

ImportedStage _stage(String title) => ImportedStage(
  kind: SourceMediaKind.live,
  categories: const [],
  items: [
    ImportedCatalogItem(
      providerKey: title,
      title: title,
      categoryKey: null,
      playbackRef: '{}',
    ),
  ],
);

class _Credentials implements CredentialStore {
  final values = <String, StoredCredential>{};
  Completer<void>? writeGate;
  final Completer<void> writeStarted = Completer<void>();
  Object? writeError;
  int writeCalls = 0;

  @override
  Future<void> delete(String key) async => values.remove(key);

  @override
  Future<StoredCredential?> read(String key) async => values[key];

  @override
  Future<void> write({
    required String key,
    required String username,
    required String password,
    String? serverUrl,
  }) async {
    writeCalls++;
    if (!writeStarted.isCompleted) writeStarted.complete();
    final error = writeError;
    if (error != null) throw error;
    await writeGate?.future;
    values[key] = StoredCredential(
      username: username,
      password: password,
      serverUrl: serverUrl,
    );
  }
}
