import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:wabbit_tv/src/features/sources/credential_store.dart';
import 'package:wabbit_tv/src/features/sources/source_catalog_database.dart';
import 'package:wabbit_tv/src/features/sources/source_models.dart';
import 'package:wabbit_tv/src/features/sources/source_setup_controller.dart';

void main() {
  test('disabling the selected ready source rebinds to the other ready source once', () async {
    final fixture = await _ManagedFixture.create();
    addTearDown(fixture.dispose);
    final controller = fixture.controller();
    await controller.initialize();
    expect(controller.persisted?.id, 'primary');
    var notifications = 0;
    controller.addListener(() => notifications++);

    await controller.setManagedSourceEnabled('primary', false);

    expect(controller.persisted?.id, 'secondary');
    expect(controller.ready?.counts[SourceMediaKind.live], 1);
    expect(notifications, 1);
  });

  test('removing the selected source rebinds, then removing last source clears ready once each', () async {
    final fixture = await _ManagedFixture.create();
    addTearDown(fixture.dispose);
    final controller = fixture.controller();
    await controller.initialize();
    var notifications = 0;
    controller.addListener(() => notifications++);

    expect(await controller.removeManagedSource('primary'), isTrue);
    expect(controller.persisted?.id, 'secondary');
    expect(controller.ready, isNotNull);
    expect(notifications, 1);

    notifications = 0;
    expect(await controller.removeManagedSource('secondary'), isTrue);
    expect(controller.persisted, isNull);
    expect(controller.ready, isNull);
    expect(notifications, 1);
  });
}

class _ManagedFixture {
  _ManagedFixture(this.directory, this.database);

  final Directory directory;
  final SourceCatalogDatabase database;

  static Future<_ManagedFixture> create() async {
    final directory = await Directory.systemTemp.createTemp(
      'wabbit-managed-rebind-',
    );
    final database = SourceCatalogDatabase(
      databasePath: '${directory.path}${Platform.pathSeparator}catalog.sqlite',
    );
    final fixture = _ManagedFixture(directory, database);
    await fixture._seed('primary', '2026-01-02T00:00:00.000Z');
    await fixture._seed('secondary', '2026-01-01T00:00:00.000Z');
    return fixture;
  }

  Future<void> _seed(String id, String refreshedAt) async {
    await database.commitInitialSource(
      SourceDefinition(
        id: id,
        name: id,
        serverUrl: 'https://provider.example',
        username: 'user',
        password: 'password',
        credentialKey: '$id-key',
      ),
      [
        ImportedStage(
          kind: SourceMediaKind.live,
          categories: const [],
          items: [
            ImportedCatalogItem(
              providerKey: 'item',
              title: id,
              categoryKey: null,
              playbackRef: '$id-ref',
            ),
          ],
        ),
      ],
    );
    final db = sqlite3.open(await database.resolvedPath());
    try {
      db.execute('UPDATE sources SET last_refresh_at = ? WHERE id = ?', [
        refreshedAt,
        id,
      ]);
    } finally {
      db.close();
    }
  }

  SourceSetupController controller() => SourceSetupController(
    productionService: SourceSetupService(database: database),
    credentialStore: _Credentials(),
  );

  Future<void> dispose() => directory.delete(recursive: true);
}

class _Credentials implements CredentialStore {
  @override
  Future<void> delete(String key) async {}

  @override
  Future<StoredCredential?> read(String key) async =>
      StoredCredential(username: 'user', password: 'password');

  @override
  Future<void> write({
    required String key,
    required String username,
    required String password,
    String? serverUrl,
  }) async {}
}
