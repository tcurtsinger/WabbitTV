import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:wabbit_tv/src/features/sources/credential_store.dart';
import 'package:wabbit_tv/src/features/sources/source_catalog_database.dart';
import 'package:wabbit_tv/src/features/sources/source_management_screen.dart';
import 'package:wabbit_tv/src/features/sources/source_management_service.dart';
import 'package:wabbit_tv/src/features/sources/source_models.dart';
import 'package:wabbit_tv/src/features/sources/source_setup_controller.dart';

void main() {
  group('SourceManagementService', () {
    test('reloads a real multi-source roster after disable and credential-safe remove', () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.dispose);
      await fixture.seedXtream('one');
      await fixture.seedXtream('two');
      final service = fixture.service;

      expect((await service.loadRoster()).map((entry) => entry.id), [
        'one',
        'two',
      ]);

      await service.setEnabled('one', false);
      final disabled = (await service.loadRoster()).singleWhere(
        (entry) => entry.id == 'one',
      );
      expect(disabled.enabled, isFalse);
      expect(disabled.status, 'ready');

      await service.remove('one');
      expect((await service.loadRoster()).map((entry) => entry.id), ['two']);
      expect(fixture.credentials.values.containsKey('one-key'), isFalse);
      expect(fixture.credentials.values.containsKey('two-key'), isTrue);

      fixture.credentials.failDelete = true;
      await expectLater(
        service.remove('two'),
        throwsA(isA<SourceManagementFailure>()),
      );
      expect((await service.loadRoster()).map((entry) => entry.id), ['two']);
      expect(fixture.credentials.values.containsKey('two-key'), isTrue);
    });

    test('renames only the local source label without refreshing', () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.dispose);
      await fixture.seedXtream('one');
      final before = fixture.db
          .select("SELECT refresh_generation FROM sources WHERE id = 'one'")
          .single['refresh_generation'];

      await fixture.service.rename('one', 'Living room');

      final row = fixture.db
          .select(
            "SELECT name, refresh_generation FROM sources WHERE id = 'one'",
          )
          .single;
      expect(row['name'], 'Living room');
      expect(row['refresh_generation'], before);
    });

    test(
      'delegates M3U refresh and leaves the last good catalog after failure',
      () async {
        final fixture = await _Fixture.create();
        addTearDown(fixture.dispose);
        final playlist = File(
          '${fixture.directory.path}${Platform.pathSeparator}source.m3u',
        );
        await playlist.writeAsString(
          '#EXTINF:-1,Before\nhttps://stream.example/before\n',
        );
        await fixture.seedM3u('m3u', playlist);

        await playlist.writeAsString(
          '#EXTINF:-1,After\nhttps://stream.example/after\n',
        );
        await fixture.service.refresh('m3u');
        expect(
          fixture.db
              .select(
                "SELECT title FROM catalog_items WHERE source_id = 'm3u' AND available = 1",
              )
              .single['title'],
          'After',
        );

        await playlist.writeAsString('#EXTINF:-1,Broken\nnot-a-url\n');
        await expectLater(
          fixture.service.refresh('m3u'),
          throwsA(isA<SourceManagementFailure>()),
        );
        expect(
          fixture.db
              .select(
                "SELECT title FROM catalog_items WHERE source_id = 'm3u' AND available = 1",
              )
              .single['title'],
          'After',
        );
      },
    );

    test('rejects concurrent source operations and requires an explicit editor hook', () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.dispose);
      await fixture.seedXtream('one');
      final started = Completer<void>();
      final release = Completer<void>();
      final service = SourceManagementService(
        sourceController: fixture.controller,
        onEditAndRefresh: (sourceId) async {
          started.complete();
          await release.future;
        },
      );

      final first = service.editAndRefresh('one');
      await started.future;
      await expectLater(
        service.setEnabled('one', false),
        throwsA(
          isA<SourceManagementFailure>().having(
            (error) => error.kind,
            'kind',
            SourceManagementFailureKind.operationInProgress,
          ),
        ),
      );
      release.complete();
      await first;

      final noEditor = SourceManagementService(
        sourceController: fixture.controller,
      );
      await expectLater(
        noEditor.editAndRefresh('one'),
        throwsA(
          isA<SourceManagementFailure>().having(
            (error) => error.kind,
            'kind',
            SourceManagementFailureKind.editUnavailable,
          ),
        ),
      );
    });
  });

  group('SourceManagementController', () {
    test(
      'loads durable truth, preserves selection, and reloads after an action',
      () async {
        final port = _RosterPort([
          _entry('one', enabled: true, status: 'ready'),
          _entry('two', enabled: true, status: 'ready'),
        ]);
        final controller = SourceManagementController(port: port);
        await controller.initialize();
        controller.select('two');

        await controller.toggle();
        expect(port.enableCalls, [('two', false)]);
        expect(controller.selectedId, 'two');
        expect(controller.selected!.enabled, isFalse);
        expect(controller.selected!.status, 'disabled');
      },
    );

    test(
      'does not mutate a stale list after failed action or overlapping action',
      () async {
        final gate = Completer<void>();
        final port = _RosterPort([
          _entry('one', enabled: true, status: 'ready'),
        ])..refreshGate = gate;
        final controller = SourceManagementController(port: port);
        await controller.initialize();

        final refreshing = controller.refresh();
        expect(controller.refreshing, isTrue);
        await controller.toggle();
        expect(controller.selected!.enabled, isTrue);
        expect(
          controller.recovery,
          'Another source action is already in progress.',
        );
        gate.complete();
        await refreshing;

        port.failToggle = true;
        await controller.toggle();
        expect(controller.selected!.enabled, isTrue);
        expect(
          controller.recovery,
          'That source could not be updated. Your local catalog is unchanged.',
        );
      },
    );
  });
}

SourceRosterEntry _entry(
  String id, {
  required bool enabled,
  required String status,
}) => SourceRosterEntry(
  id: id,
  name: id,
  kind: 'xtream',
  enabled: enabled,
  status: status,
  counts: const {
    SourceMediaKind.live: 1,
    SourceMediaKind.movies: 0,
    SourceMediaKind.series: 0,
  },
);

class _RosterPort implements SourceManagementPort {
  _RosterPort(List<SourceRosterEntry> seed) : entries = List.of(seed);
  final List<SourceRosterEntry> entries;
  final List<(String, bool)> enableCalls = [];
  Completer<void>? refreshGate;
  bool failToggle = false;

  @override
  Future<List<SourceRosterEntry>> loadRoster() async => List.of(entries);

  @override
  Future<void> editAndRefresh(String sourceId) async {}

  @override
  Future<void> refresh(String sourceId) async {
    await refreshGate?.future;
  }

  @override
  Future<void> rename(String sourceId, String name) async {
    final index = entries.indexWhere((entry) => entry.id == sourceId);
    final old = entries[index];
    entries[index] = SourceRosterEntry(
      id: old.id,
      name: name,
      kind: old.kind,
      enabled: old.enabled,
      status: old.status,
      counts: old.counts,
    );
  }

  @override
  Future<void> remove(String sourceId) async {
    entries.removeWhere((entry) => entry.id == sourceId);
  }

  @override
  Future<void> setEnabled(String sourceId, bool enabled) async {
    if (failToggle) throw StateError('provider secret');
    enableCalls.add((sourceId, enabled));
    final index = entries.indexWhere((entry) => entry.id == sourceId);
    final old = entries[index];
    entries[index] = SourceRosterEntry(
      id: old.id,
      name: old.name,
      kind: old.kind,
      enabled: enabled,
      status: enabled ? 'ready' : 'disabled',
      counts: old.counts,
    );
  }
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

class _Fixture {
  _Fixture(this.directory, this.database, this.credentials, this.db)
    : controller = SourceSetupController(
        productionService: SourceSetupService(database: database),
        credentialStore: credentials,
      );

  final Directory directory;
  final SourceCatalogDatabase database;
  final _MemoryCredentials credentials;
  final Database db;
  final SourceSetupController controller;

  SourceManagementService get service =>
      SourceManagementService(sourceController: controller);

  static Future<_Fixture> create() async {
    final directory = await Directory.systemTemp.createTemp(
      'wabbit-management-',
    );
    final database = SourceCatalogDatabase(
      databasePath: '${directory.path}${Platform.pathSeparator}catalog.sqlite',
    );
    final credentials = _MemoryCredentials();
    final db = sqlite3.open(await database.resolvedPath());
    return _Fixture(directory, database, credentials, db);
  }

  Future<void> seedXtream(String id) async {
    await database.commitInitialSource(
      SourceDefinition(
        id: id,
        name: id,
        serverUrl: 'https://$id.example',
        username: 'user',
        password: 'password',
        credentialKey: '$id-key',
      ),
      [
        const ImportedStage(
          kind: SourceMediaKind.live,
          categories: [],
          items: [
            ImportedCatalogItem(
              providerKey: 'live',
              title: 'Live',
              categoryKey: null,
              playbackRef: '{}',
            ),
          ],
        ),
      ],
    );
    await credentials.write(
      key: '$id-key',
      username: 'user',
      password: 'password',
      serverUrl: 'https://$id.example',
    );
  }

  Future<void> seedM3u(String id, File playlist) async {
    final source = M3uSourceInput(
      id: id,
      name: id,
      kind: M3uSourceKind.m3uFile,
      locator: playlist.path,
      credentialKey: '$id-key',
      displayEndpoint: playlist.uri.pathSegments.last,
    );
    final initial = await database.beginM3uInitialImport(source);
    await initial.pending;
    await initial.activate();
    await credentials.write(
      key: source.credentialKey,
      username: '',
      password: '',
      serverUrl: playlist.path,
    );
  }

  Future<void> dispose() async {
    db.close();
    await directory.delete(recursive: true);
  }
}
