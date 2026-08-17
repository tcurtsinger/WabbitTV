import 'dart:async';
import 'dart:io';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:wabbit_tv/src/features/sources/source_catalog_database.dart';
import 'package:wabbit_tv/src/features/sources/source_models.dart';

void main() {
  test('worker cancellation force-closes a stalled local provider and removes pending rows', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);
    final received = Completer<void>();
    server.listen((request) async {
      if (!received.isCompleted) received.complete();
      // Deliberately never respond: cancellation must close the worker client.
      await Completer<void>().future;
    });
    final temp = await Directory.systemTemp.createTemp('wabbit-import-worker-');
    addTearDown(() => temp.delete(recursive: true));
    final path = '${temp.path}${Platform.pathSeparator}catalog.sqlite';
    final database = SourceCatalogDatabase(databasePath: path);
    final import = await database.beginInitialImport(
      SourceDefinition(
        id: 'stalled-source',
        name: 'Fixture',
        serverUrl: 'http://${server.address.address}:${server.port}',
        username: 'fixture-user',
        password: 'fixture-password',
        credentialKey: 'fixture-key',
      ),
    );
    await received.future.timeout(const Duration(seconds: 3));
    await import.cancel().timeout(const Duration(seconds: 3));
    final db = sqlite3.open(path);
    addTearDown(db.close);
    expect(db.select('SELECT * FROM sources'), isEmpty);
  });

  test(
    'forced cancellation cleans a pending row when the worker ignores cancel',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);
      final received = Completer<void>();
      server.listen((request) async {
        if (!received.isCompleted) received.complete();
        await Completer<void>().future;
      });
      final temp = await Directory.systemTemp.createTemp(
        'wabbit-forced-cancel-',
      );
      addTearDown(() => temp.delete(recursive: true));
      final path = '${temp.path}${Platform.pathSeparator}catalog.sqlite';
      final database = SourceCatalogDatabase(
        databasePath: path,
        ignoreCancelForTest: true,
      );
      final import = await database.beginInitialImport(
        SourceDefinition(
          id: 'nonresponsive-source',
          name: 'Fixture',
          serverUrl: 'http://${server.address.address}:${server.port}',
          username: 'fixture-user',
          password: 'fixture-password',
          credentialKey: 'fixture-key',
        ),
      );
      await received.future.timeout(const Duration(seconds: 3));

      await import.cancel().timeout(const Duration(seconds: 2));

      final db = sqlite3.open(path);
      addTearDown(db.close);
      expect(db.select('SELECT * FROM sources'), isEmpty);
      expect(db.select('SELECT * FROM catalog_items'), isEmpty);
    },
  );

  test(
    'worker imports 50k linked items while the main isolate keeps a heartbeat',
    () async {
      final items = jsonEncode([
        for (var index = 0; index < 50000; index++)
          {
            'stream_id': 'l$index',
            'name': 'Fixture $index',
            'category_id': '1',
          },
      ]);
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);
      server.listen((request) async {
        final action = request.uri.queryParameters['action'];
        final body = switch (action) {
          null => '{"user_info":{"auth":1}}',
          'get_live_categories' =>
            '[{"category_id":"1","category_name":"News"}]',
          'get_live_streams' => items,
          'get_vod_categories' || 'get_series_categories' => '[]',
          _ => '[{"stream_id":"one","series_id":"one","name":"One"}]',
        };
        request.response.headers.contentType = ContentType.json;
        request.response.write(body);
        await request.response.close();
      });
      final temp = await Directory.systemTemp.createTemp(
        'wabbit-import-worker-',
      );
      addTearDown(() => temp.delete(recursive: true));
      final database = SourceCatalogDatabase(
        databasePath: '${temp.path}${Platform.pathSeparator}catalog.sqlite',
      );
      final import = await database.beginInitialImport(
        SourceDefinition(
          id: 'large-source',
          name: 'Fixture',
          serverUrl: 'http://${server.address.address}:${server.port}',
          username: 'fixture-user',
          password: 'fixture-password',
          credentialKey: 'fixture-key',
        ),
      );
      var heartbeats = 0;
      final timer = Timer.periodic(
        const Duration(milliseconds: 1),
        (_) => heartbeats++,
      );
      final pending = await import.pending.timeout(const Duration(seconds: 15));
      timer.cancel();
      expect(pending.counts[SourceMediaKind.live], 50000);
      expect(heartbeats, greaterThan(0));
      await import.activate();
    },
  );
  test('worker preserves category linkage and activates only after explicit activation', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);
    server.listen((request) async {
      final action = request.uri.queryParameters['action'];
      final body = switch (action) {
        null => '{"user_info":{"auth":1}}',
        'get_live_categories' => '[{"category_id":"1","category_name":"News"}]',
        'get_vod_categories' => '[{"category_id":"2","category_name":"Films"}]',
        'get_series_categories' =>
          '[{"category_id":"3","category_name":"Shows"}]',
        'get_live_streams' =>
          '[{"stream_id":"l1","name":"Live","category_id":"1"}]',
        'get_vod_streams' =>
          '[{"stream_id":"m1","name":"Movie","category_id":"2"}]',
        _ => '[{"series_id":"s1","name":"Series","category_id":"3"}]',
      };
      request.response.headers.contentType = ContentType.json;
      request.response.write(body);
      await request.response.close();
    });
    final temp = await Directory.systemTemp.createTemp('wabbit-import-worker-');
    addTearDown(() => temp.delete(recursive: true));
    final path = '${temp.path}${Platform.pathSeparator}catalog.sqlite';
    final database = SourceCatalogDatabase(databasePath: path);
    final import = await database.beginInitialImport(
      SourceDefinition(
        id: 'ready-source',
        name: 'Fixture',
        serverUrl: 'http://${server.address.address}:${server.port}',
        username: 'fixture-user',
        password: 'fixture-password',
        credentialKey: 'fixture-key',
      ),
    );
    final pending = await import.pending.timeout(const Duration(seconds: 3));
    expect(pending.counts.values, everyElement(1));
    var db = sqlite3.open(path);
    expect(db.select('SELECT enabled FROM sources').single['enabled'], 0);
    expect(
      db.select('SELECT source_group_id FROM catalog_items WHERE kind = ?', [
        'live',
      ]).single['source_group_id'],
      isNotNull,
    );
    db.close();
    final ready = await import.activate().timeout(const Duration(seconds: 3));
    expect(ready.counts[SourceMediaKind.series], 1);
    db = sqlite3.open(path);
    addTearDown(db.close);
    expect(
      db.select('SELECT enabled, refresh_state FROM sources').single['enabled'],
      1,
    );
    expect(
      db.select("SELECT settings_json FROM sources").single['settings_json'],
      '{}',
    );
    expect(
      db.select('PRAGMA table_info(sources)').map((row) => row['name']),
      isNot(contains('password')),
    );
  });
}
