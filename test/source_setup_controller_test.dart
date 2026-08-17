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
  group('SourceSetupController', () {
    test('commits all three stages before saving the password', () async {
      final service = _FakeSourcePort();
      final credentials = _FakeCredentialStore();
      final controller = SourceSetupController(
        service: service,
        credentialStore: credentials,
      );

      await controller.connect(
        name: 'Living room',
        serverUrl: 'https://provider.example:8443',
        username: 'fixture-user',
        password: 'fixture-password',
      );

      expect(controller.ready?.counts[SourceMediaKind.live], 2);
      expect(controller.ready?.counts[SourceMediaKind.movies], 3);
      expect(controller.ready?.counts[SourceMediaKind.series], 4);
      expect(service.commitCount, 1);
      expect(credentials.writes, 1);
      expect(service.removed, isEmpty);
    });

    test(
      'cancel prevents a delayed stage from committing a source or secret',
      () async {
        final service = _DelayedSourcePort();
        final credentials = _FakeCredentialStore();
        final controller = SourceSetupController(
          service: service,
          credentialStore: credentials,
        );

        final operation = controller.connect(
          name: 'Living room',
          serverUrl: 'https://provider.example',
          username: 'fixture-user',
          password: 'fixture-password',
        );
        await service.started.future;
        expect(controller.isImporting, isTrue);
        controller.cancel();
        service.complete();
        await operation;

        expect(controller.isImporting, isFalse);
        expect(controller.ready, isNull);
        expect(service.commitCount, 0);
        expect(credentials.writes, 0);
        expect(service.removed, isNotEmpty);
      },
    );

    test(
      'rejects user info, queries, and fragments in Xtream base URLs',
      () async {
        for (final url in [
          'https://token@provider.example',
          'https://provider.example?password=fixture',
          'https://provider.example#fragment',
        ]) {
          final service = _FakeSourcePort();
          final controller = SourceSetupController(
            service: service,
            credentialStore: _FakeCredentialStore(),
          );
          await controller.connect(
            name: 'Fixture',
            serverUrl: url,
            username: 'fixture-user',
            password: 'fixture-password',
          );
          expect(controller.fieldErrors['serverUrl'], isNotNull);
          expect(service.commitCount, 0);
        }
      },
    );

    test('keeps an authentication failure redacted and retryable', () async {
      final controller = SourceSetupController(
        service: _FailingSourcePort(SourceImportFailureKind.authentication),
        credentialStore: _FakeCredentialStore(),
      );

      await controller.connect(
        name: 'Living room',
        serverUrl: 'https://provider.example',
        username: 'fixture-user',
        password: 'fixture-password',
      );

      expect(controller.failure, SourceImportFailureKind.authentication);
      expect(controller.isImporting, isFalse);
      expect(controller.stages[SourceMediaKind.live], ImportStageStatus.error);
    });
  });

  test(
    'first-source migration stores catalog data but has no password column',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'wabbit-source-test-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final path = '${directory.path}${Platform.pathSeparator}catalog.sqlite';
      final database = SourceCatalogDatabase(databasePath: path);
      final source = SourceDefinition(
        id: 'source-fixture',
        name: 'Fixture source',
        serverUrl: 'https://provider.example',
        username: 'fixture-user',
        password: 'fixture-password',
        credentialKey: 'fixture-key',
      );

      final ready = await database.commitInitialSource(source, [
        _stage(SourceMediaKind.live, 2),
        _stage(SourceMediaKind.movies, 3),
        _stage(SourceMediaKind.series, 4),
      ]);
      final db = sqlite3.open(path);
      addTearDown(db.close);

      final sourceColumns = db.select('PRAGMA table_info(sources)');
      final columnNames = sourceColumns.map((row) => row['name']).toList();
      expect(columnNames, isNot(contains('password')));
      expect(
        db.select('SELECT COUNT(*) AS total FROM sources').single['total'],
        1,
      );
      expect(
        db
            .select('SELECT COUNT(*) AS total FROM catalog_items')
            .single['total'],
        9,
      );
      expect(ready.counts[SourceMediaKind.series], 4);
    },
  );
}

ImportedStage _stage(SourceMediaKind kind, int count) => ImportedStage(
  kind: kind,
  categories: [
    ImportedCategory(providerKey: '${kind.name}-group', name: kind.label),
  ],
  items: [
    for (var index = 0; index < count; index++)
      ImportedCatalogItem(
        providerKey: '${kind.name}-$index',
        title: '${kind.label} fixture $index',
        categoryKey: '${kind.name}-group',
        playbackRef: '{"providerId":"$index"}',
      ),
  ],
);

class _FakeSourcePort implements SourceSetupPort {
  int commitCount = 0;
  final List<String> removed = [];

  @override
  Future<ImportedStage> fetch(
    SourceDefinition source,
    SourceMediaKind kind,
  ) async => _stage(kind, kind.index + 2);

  @override
  Future<SourceReady> commit(
    SourceDefinition source,
    List<ImportedStage> stages,
  ) async {
    commitCount++;
    return SourceReady(
      counts: {for (final stage in stages) stage.kind: stage.itemCount},
    );
  }

  @override
  Future<void> remove(String sourceId) async {
    removed.add(sourceId);
  }
}

class _DelayedSourcePort extends _FakeSourcePort {
  final started = Completer<void>();
  final _result = Completer<ImportedStage>();

  @override
  Future<ImportedStage> fetch(SourceDefinition source, SourceMediaKind kind) {
    if (!started.isCompleted) started.complete();
    return _result.future;
  }

  void complete() => _result.complete(_stage(SourceMediaKind.live, 2));
}

class _FailingSourcePort extends _FakeSourcePort {
  _FailingSourcePort(this.failure);

  final SourceImportFailureKind failure;

  @override
  Future<ImportedStage> fetch(SourceDefinition source, SourceMediaKind kind) =>
      Future<ImportedStage>.error(SourceImportFailure(failure));
}

class _FakeCredentialStore implements CredentialStore {
  int writes = 0;

  @override
  Future<StoredCredential?> read(String key) async => null;

  @override
  Future<void> delete(String key) async {}

  @override
  Future<void> write({
    required String key,
    required String username,
    required String password,
    String? serverUrl,
  }) async {
    writes++;
  }
}
