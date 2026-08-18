import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:wabbit_tv/src/features/sources/source_catalog_database.dart';
import 'package:wabbit_tv/src/features/sources/source_models.dart';

void main() {
  test(
    'all and source scopes choose one active variant per library identity',
    () async {
      final fixture = await _FoundationFixture.create();
      addTearDown(fixture.dispose);
      await fixture.seedThreeSources();

      final sqlite = sqlite3.open(fixture.path);
      try {
        // Treat the two provider records as one genuine local identity and
        // prefer Beta when All sources has both variants available.
        sqlite.execute(
          'DELETE FROM library_members WHERE catalog_item_id = ?',
          ['beta:live:shared'],
        );
        sqlite.execute(
          'UPDATE library_members SET preferred = 0 WHERE catalog_item_id = ?',
          ['alpha:live:shared'],
        );
        sqlite.execute(
          '''INSERT INTO library_members
             (library_item_id, catalog_item_id, preferred)
             VALUES (?, ?, 1)''',
          ['alpha:live:shared', 'beta:live:shared'],
        );
      } finally {
        sqlite.close();
      }

      final all = await fixture.database.browseLibraryPage(
        scope: const LibraryScope.all(),
        kind: SourceMediaKind.live,
      );
      final shared = all.items.where(
        (item) => item.libraryItemId == 'alpha:live:shared',
      );
      expect(shared, hasLength(1));
      expect(shared.single.catalogItemId, 'beta:live:shared');
      expect(shared.single.sourceId, 'beta');
      expect(shared.single.sourceDisplayName, 'Beta Room');

      final pagedIds = <String>[];
      BrowseCursor? cursor;
      do {
        final page = await fixture.database.browseLibraryPage(
          scope: const LibraryScope.all(),
          kind: SourceMediaKind.live,
          cursor: cursor,
          limit: 1,
        );
        pagedIds.addAll(page.items.map((item) => item.libraryItemId));
        cursor = page.nextCursor;
      } while (cursor != null);
      expect(pagedIds, hasLength(pagedIds.toSet().length));
      expect(pagedIds.where((id) => id == 'alpha:live:shared'), hasLength(1));
      expect(pagedIds, contains('alpha:live:shared-other'));

      final alpha = await fixture.database.browseLibraryPage(
        scope: const LibraryScope.source('alpha'),
        kind: SourceMediaKind.live,
      );
      final alphaShared = alpha.items.singleWhere(
        (item) => item.libraryItemId == 'alpha:live:shared',
      );
      expect(alphaShared.catalogItemId, 'alpha:live:shared');
      expect(alphaShared.sourceDisplayName, 'Alpha Room');
      expect(
        await fixture.database.countLibraryItems(
          scope: const LibraryScope.all(),
          kind: SourceMediaKind.live,
        ),
        all.items.length,
      );

      // A typed refresh failure keeps the source ready and its last-good
      // catalog available.
      final failed = sqlite3.open(fixture.path);
      try {
        failed.execute(
          "UPDATE sources SET refresh_state = 'ready', last_error = 'unreachable' WHERE id = 'beta'",
        );
      } finally {
        failed.close();
      }
      expect(
        (await fixture.database.browseLibraryPage(
          scope: const LibraryScope.source('beta'),
          kind: SourceMediaKind.live,
        )).items,
        isNotEmpty,
      );
    },
  );

  test('mixed literal search is bounded, ordered, and source-aware', () async {
    final fixture = await _FoundationFixture.create();
    addTearDown(fixture.dispose);
    await fixture.seedThreeSources();

    final results = await fixture.database.searchLibraryPage(
      query: 'Café + 世界',
      scope: const LibraryScope.all(),
      limit: 2,
    );
    expect(results.items, hasLength(2));
    expect(results.items.map((item) => item.kind), [
      SourceMediaKind.movies,
      SourceMediaKind.live,
    ]);
    expect(results.items.map((item) => item.sourceDisplayName), [
      'Beta Room',
      'Alpha Room',
    ]);
    expect(results.nextCursor, isNotNull);

    final second = await fixture.database.searchLibraryPage(
      query: 'Café + 世界',
      scope: const LibraryScope.all(),
      cursor: results.nextCursor,
      limit: 2,
    );
    expect(second.items.single.kind, SourceMediaKind.series);
    expect(second.items.single.sourceDisplayName, 'Gamma Room');
    expect(second.nextCursor, isNull);

    expect(
      await fixture.database.countLibraryItems(
        scope: const LibraryScope.all(),
        query: 'Café + 世界',
      ),
      3,
    );
    expect(
      await fixture.database.countLibraryItems(
        scope: const LibraryScope.all(),
        kind: SourceMediaKind.movies,
        query: 'Café + 世界',
      ),
      1,
    );
    expect(
      (await fixture.database.searchLibraryPage(
        query: 'Café + 世界',
        scope: const LibraryScope.source('alpha'),
      )).items.single.sourceId,
      'alpha',
    );
  });

  test(
    'global catalog scope persists and stale sources fall back to All',
    () async {
      final fixture = await _FoundationFixture.create();
      addTearDown(fixture.dispose);
      await fixture.seedThreeSources();

      expect((await fixture.database.loadCatalogScope()).isAll, isTrue);
      final saved = await fixture.database.saveCatalogScope(
        const LibraryScope.source('beta'),
      );
      expect(saved.sourceId, 'beta');
      expect((await fixture.database.loadCatalogScope()).sourceId, 'beta');

      final sqlite = sqlite3.open(fixture.path);
      try {
        final settings = sqlite.select('SELECT key, value FROM app_settings');
        expect(settings, hasLength(1));
        expect(settings.single['key'], 'catalog_scope');
        expect(settings.single['value'], 'source:beta');
        final serialized = settings.single.values.join(' ');
        expect(serialized, isNot(contains('password')));
        expect(serialized, isNot(contains('credential')));
        expect(serialized, isNot(contains('{')));
      } finally {
        sqlite.close();
      }

      await fixture.database.setSourceEnabled('beta', false);
      expect((await fixture.database.loadCatalogScope()).isAll, isTrue);
      expect(
        (await fixture.database.saveCatalogScope(
          const LibraryScope.source('beta'),
        )).isAll,
        isTrue,
      );
      await fixture.database.setSourceEnabled('beta', true);
      await fixture.database.saveCatalogScope(
        const LibraryScope.source('beta'),
      );
      await fixture.database.removeSource('beta');
      expect((await fixture.database.loadCatalogScope()).isAll, isTrue);
    },
  );

  test(
    'playable source lookup is exact and excludes disabled sources',
    () async {
      final fixture = await _FoundationFixture.create();
      addTearDown(fixture.dispose);
      await fixture.seedThreeSources();

      final beta = await fixture.database.loadReadySourceById('beta');
      expect(beta?.id, 'beta');
      expect(beta?.credentialKey, 'beta-credential');
      expect(beta?.counts[SourceMediaKind.movies], 1);
      await fixture.database.setSourceEnabled('beta', false);
      expect(await fixture.database.loadReadySourceById('beta'), isNull);
      expect(await fixture.database.loadReadySourceById('missing'), isNull);
    },
  );

  test(
    '50k unified browse and count stay off the main isolate and bounded',
    () async {
      final fixture = await _FoundationFixture.create();
      addTearDown(fixture.dispose);
      await fixture.database.commitInitialSource(
        fixture.definition('bulk', 'Bulk Room'),
        [
          ImportedStage(
            kind: SourceMediaKind.live,
            categories: const [],
            items: [
              for (var index = 0; index < 50000; index++)
                ImportedCatalogItem(
                  providerKey: '$index',
                  title: 'Channel ${index.toString().padLeft(5, '0')}',
                  categoryKey: null,
                  playbackRef: 'provider-id-$index',
                ),
            ],
          ),
        ],
      );

      var heartbeats = 0;
      final heartbeat = Timer.periodic(
        const Duration(milliseconds: 1),
        (_) => heartbeats++,
      );
      final page = await fixture.database.browseLibraryPage(
        scope: const LibraryScope.all(),
        kind: SourceMediaKind.live,
        limit: 1000,
      );
      final count = await fixture.database.countLibraryItems(
        scope: const LibraryScope.all(),
        kind: SourceMediaKind.live,
      );
      heartbeat.cancel();

      expect(page.items, hasLength(200));
      expect(page.nextCursor?.id, page.items.last.libraryItemId);
      expect(count, 50000);
      expect(heartbeats, greaterThan(0));
    },
    timeout: const Timeout(Duration(seconds: 45)),
  );
}

class _FoundationFixture {
  _FoundationFixture(this.directory)
    : path = '${directory.path}${Platform.pathSeparator}catalog.sqlite',
      database = SourceCatalogDatabase(
        databasePath:
            '${directory.path}${Platform.pathSeparator}catalog.sqlite',
      );

  final Directory directory;
  final String path;
  final SourceCatalogDatabase database;

  static Future<_FoundationFixture> create() async => _FoundationFixture(
    await Directory.systemTemp.createTemp('wabbit-scope-search-'),
  );

  SourceDefinition definition(String id, String name) => SourceDefinition(
    id: id,
    name: name,
    serverUrl: 'https://$id.example',
    username: 'not-persisted-user',
    password: 'not-persisted-password',
    credentialKey: '$id-credential',
  );

  Future<void> seedThreeSources() async {
    await database.commitInitialSource(definition('alpha', 'Alpha Room'), [
      const ImportedStage(
        kind: SourceMediaKind.live,
        categories: [],
        items: [
          ImportedCatalogItem(
            providerKey: 'cafe',
            title: 'Café 世界 News',
            categoryKey: null,
            playbackRef: 'alpha-cafe-id',
          ),
          ImportedCatalogItem(
            providerKey: 'shared',
            title: 'Shared Broadcast',
            categoryKey: null,
            playbackRef: 'alpha-shared-id',
          ),
          ImportedCatalogItem(
            providerKey: 'shared-other',
            title: 'Shared Broadcast',
            categoryKey: null,
            playbackRef: 'alpha-shared-other-id',
          ),
        ],
      ),
    ]);
    await database.commitInitialSource(definition('beta', 'Beta Room'), [
      const ImportedStage(
        kind: SourceMediaKind.live,
        categories: [],
        items: [
          ImportedCatalogItem(
            providerKey: 'shared',
            title: 'Shared Broadcast',
            categoryKey: null,
            playbackRef: 'beta-shared-id',
          ),
        ],
      ),
      const ImportedStage(
        kind: SourceMediaKind.movies,
        categories: [],
        items: [
          ImportedCatalogItem(
            providerKey: 'cafe-film',
            title: 'Café 世界 Film',
            categoryKey: null,
            playbackRef: 'beta-film-id',
          ),
        ],
      ),
    ]);
    await database.commitInitialSource(definition('gamma', 'Gamma Room'), [
      const ImportedStage(
        kind: SourceMediaKind.series,
        categories: [],
        items: [
          ImportedCatalogItem(
            providerKey: 'cafe-series',
            title: 'Café 世界 Series',
            categoryKey: null,
            playbackRef: 'gamma-series-id',
          ),
        ],
      ),
    ]);
  }

  Future<void> dispose() => directory.delete(recursive: true);
}
