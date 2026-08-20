import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:wabbit_tv/src/features/sources/source_catalog_database.dart';
import 'package:wabbit_tv/src/features/sources/source_models.dart';

void main() {
  test(
    'browse categories and pages only expose ready available source data',
    () async {
      final fixture = await _BrowseFixture.create();
      addTearDown(fixture.dispose);
      await fixture.seedSmallCatalog();

      final categories = await fixture.database.browseCategories(
        sourceId: fixture.primary.id,
        kind: SourceMediaKind.live,
      );

      expect(
        categories.map((category) => (category.name, category.itemCount)),
        [
          ('All Live', 4),
          ('Alpha', 1),
          ('Empty', 0),
          ('Zebra', 2),
          ('Uncategorized', 1),
        ],
      );
      expect(categories.first.selection.kind, BrowseCategorySelectionKind.all);
      expect(
        categories.last.selection.kind,
        BrowseCategorySelectionKind.uncategorized,
      );
      expect(
        await fixture.database.browseCategories(
          sourceId: fixture.secondary.id,
          kind: SourceMediaKind.live,
        ),
        isEmpty,
      );

      final firstPage = await fixture.database.browsePage(
        sourceId: fixture.primary.id,
        kind: SourceMediaKind.live,
        limit: 2,
      );
      expect(firstPage.items.map((item) => item.title), ['Apple', 'Bravo']);
      expect(firstPage.items.map((item) => item.libraryItemId), [
        'primary:live:uncategorized',
        'primary:live:bravo',
      ]);
      expect(
        firstPage.items
            .singleWhere((item) => item.title == 'Bravo')
            .artworkLocator,
        'art://bravo',
      );
      expect(
        firstPage.items
            .singleWhere((item) => item.title == 'Bravo')
            .playbackRef,
        'ref-bravo',
      );
      expect(firstPage.nextCursor, isNotNull);

      final secondPage = await fixture.database.browsePage(
        sourceId: fixture.primary.id,
        kind: SourceMediaKind.live,
        cursor: firstPage.nextCursor,
        limit: 2,
      );
      expect(secondPage.items.map((item) => item.title), ['Same', 'Same']);
      expect(secondPage.items.map((item) => item.id), [
        'primary:live:same-1',
        'primary:live:same-2',
      ]);
      expect(secondPage.nextCursor, isNull);

      final alpha = categories.singleWhere(
        (category) => category.name == 'Alpha',
      );
      final alphaPage = await fixture.database.browsePage(
        sourceId: fixture.primary.id,
        kind: SourceMediaKind.live,
        selection: alpha.selection,
      );
      expect(alphaPage.items.single.title, 'Bravo');

      final uncategorized = await fixture.database.browsePage(
        sourceId: fixture.primary.id,
        kind: SourceMediaKind.live,
        selection: const BrowseCategorySelection.uncategorized(),
      );
      expect(uncategorized.items.map((item) => item.title), ['Apple']);

      final wrongKind = await fixture.database.browsePage(
        sourceId: fixture.primary.id,
        kind: SourceMediaKind.movies,
      );
      expect(wrongKind.items.map((item) => item.title), ['Movie only']);
    },
  );

  test(
    'exact visible lookup honors source category and visibility boundaries',
    () async {
      final fixture = await _BrowseFixture.create();
      addTearDown(fixture.dispose);
      await fixture.seedSmallCatalog();

      final categories = await fixture.database.browseCategories(
        sourceId: fixture.primary.id,
        kind: SourceMediaKind.live,
      );
      final alpha = categories.singleWhere(
        (category) => category.name == 'Alpha',
      );
      final zebra = categories.singleWhere(
        (category) => category.name == 'Zebra',
      );
      final exact = await fixture.database.loadVisibleCatalogItem(
        sourceId: fixture.primary.id,
        kind: SourceMediaKind.live,
        selection: alpha.selection,
        catalogItemId: 'primary:live:bravo',
      );

      expect(exact?.title, 'Bravo');
      expect(exact?.libraryItemId, 'primary:live:bravo');
      expect(
        await fixture.database.loadVisibleCatalogItem(
          sourceId: fixture.primary.id,
          kind: SourceMediaKind.live,
          selection: zebra.selection,
          catalogItemId: 'primary:live:bravo',
        ),
        isNull,
      );
      expect(
        await fixture.database.loadVisibleCatalogItem(
          sourceId: fixture.primary.id,
          kind: SourceMediaKind.live,
          selection: const BrowseCategorySelection.all(),
          catalogItemId: 'primary:live:offline',
        ),
        isNull,
      );
      expect(
        await fixture.database.loadVisibleCatalogItem(
          sourceId: fixture.secondary.id,
          kind: SourceMediaKind.live,
          selection: const BrowseCategorySelection.all(),
          catalogItemId: 'secondary:live:other',
        ),
        isNull,
      );

      final tailWindow = await fixture.database.browseWindowAroundCatalogItem(
        sourceId: fixture.primary.id,
        kind: SourceMediaKind.live,
        selection: const BrowseCategorySelection.all(),
        catalogItemId: 'primary:live:same-2',
        limit: 3,
      );
      expect(tailWindow?.items.map((item) => item.id), [
        'primary:live:same-1',
        'primary:live:same-2',
      ]);
      expect(tailWindow?.previousCursor?.id, 'primary:live:same-1');
      expect(tailWindow?.nextCursor, isNull);
      final head = await fixture.database.browsePageBefore(
        sourceId: fixture.primary.id,
        kind: SourceMediaKind.live,
        selection: const BrowseCategorySelection.all(),
        cursor: tailWindow!.previousCursor!,
        limit: 2,
      );
      expect(head.items.map((item) => item.id), [
        'primary:live:uncategorized',
        'primary:live:bravo',
      ]);
      expect(head.previousCursor, isNull);

      await fixture.database.setCatalogItemHidden(
        sourceId: fixture.primary.id,
        catalogItemId: 'primary:live:uncategorized',
        hidden: true,
      );
      final revalidated = await fixture.database.browseWindowAroundCatalogItem(
        sourceId: fixture.primary.id,
        kind: SourceMediaKind.live,
        selection: const BrowseCategorySelection.all(),
        catalogItemId: 'primary:live:bravo',
        limit: 3,
      );
      expect(
        revalidated?.items.map((item) => item.id),
        isNot(contains('primary:live:uncategorized')),
      );

      await fixture.database.setCatalogItemHidden(
        sourceId: fixture.primary.id,
        catalogItemId: 'primary:live:bravo',
        hidden: true,
      );
      expect(
        await fixture.database.loadVisibleCatalogItem(
          sourceId: fixture.primary.id,
          kind: SourceMediaKind.live,
          selection: const BrowseCategorySelection.all(),
          catalogItemId: 'primary:live:bravo',
        ),
        isNull,
      );
    },
  );

  test('browse paging remains bounded and traverses 50k items off the main isolate', () async {
    final fixture = await _BrowseFixture.create();
    addTearDown(fixture.dispose);
    const itemCount = 50000;
    await fixture.database.commitInitialSource(fixture.primary, [
      ImportedStage(
        kind: SourceMediaKind.live,
        categories: const [
          ImportedCategory(providerKey: 'catalog', name: 'Catalog'),
        ],
        items: [
          for (var index = 0; index < itemCount; index++)
            ImportedCatalogItem(
              providerKey: 'item-$index',
              title: 'Fixture ${index.toString().padLeft(5, '0')}',
              categoryKey: 'catalog',
              artworkLocator: index == 0 ? 'art://first' : null,
              playbackRef: 'ref-$index',
            ),
        ],
      ),
    ]);

    var heartbeats = 0;
    final heartbeat = Timer.periodic(
      const Duration(milliseconds: 1),
      (_) => heartbeats++,
    );
    final seen = <String>{};
    BrowseCursor? cursor;
    do {
      final page = await fixture.database.browsePage(
        sourceId: fixture.primary.id,
        kind: SourceMediaKind.live,
        cursor: cursor,
        limit: 1000,
      );
      expect(page.items, isNotEmpty);
      expect(page.items.length, lessThanOrEqualTo(200));
      seen.addAll(page.items.map((item) => item.id));
      cursor = page.nextCursor;
    } while (cursor != null);
    heartbeat.cancel();

    expect(seen, hasLength(itemCount));
    expect(heartbeats, greaterThan(0));
  }, timeout: const Timeout(Duration(seconds: 45)));

  test(
    'browse query upgrades an existing version-two catalog with its All index',
    () async {
      final fixture = await _BrowseFixture.create();
      addTearDown(fixture.dispose);
      await fixture.seedSmallCatalog();
      final db = sqlite3.open(await fixture.database.resolvedPath());
      try {
        db.execute('DROP TRIGGER sources_connection_override_insert');
        db.execute('DROP TRIGGER sources_connection_override_update');
        db.execute('DROP TABLE playback_progress');
        db.execute('DROP INDEX catalog_items_browse_all');
        db.execute('DROP INDEX catalog_items_parent');
        db.execute('DROP INDEX catalog_items_source_group');
        db.execute('DROP INDEX catalog_items_available');
        db.execute('DROP TABLE library_fts');
        db.execute('DROP TABLE watch_state');
        db.execute('DROP TABLE custom_group_items');
        db.execute('DROP TABLE custom_groups');
        db.execute('DROP TABLE favorites');
        db.execute('DROP TABLE library_members');
        db.execute('DROP TABLE library_items');
        db.execute('DROP TABLE app_settings');
        db.execute('ALTER TABLE sources DROP COLUMN connection_limit_override');
        db.execute('ALTER TABLE sources DROP COLUMN reported_connection_limit');
        db.execute('DELETE FROM schema_migrations WHERE version >= 3');
      } finally {
        db.close();
      }

      await fixture.database.browsePage(
        sourceId: fixture.primary.id,
        kind: SourceMediaKind.live,
      );

      final upgraded = sqlite3.open(await fixture.database.resolvedPath());
      try {
        expect(
          upgraded
              .select('PRAGMA index_list(catalog_items)')
              .map((row) => row['name']),
          contains('catalog_items_browse_all'),
        );
        expect(
          upgraded
              .select('SELECT MAX(version) AS version FROM schema_migrations')
              .single['version'],
          12,
        );
      } finally {
        upgraded.close();
      }
    },
  );

  test('All and source-group pages use ordered browse indexes', () async {
    final fixture = await _BrowseFixture.create();
    addTearDown(fixture.dispose);
    await fixture.seedSmallCatalog();
    final db = sqlite3.open(await fixture.database.resolvedPath());
    try {
      final allPlan = _queryPlan(
        db,
        '''SELECT id, source_id, kind, title, normalized_title, artwork_locator, playback_ref
           FROM catalog_items
           WHERE source_id = ? AND kind = ? AND available = 1
             AND EXISTS (SELECT 1 FROM sources WHERE sources.id = catalog_items.source_id AND sources.enabled = 1 AND sources.refresh_state = 'ready')
           ORDER BY normalized_title ASC, id ASC
           LIMIT ?''',
        [fixture.primary.id, SourceMediaKind.live.name, 101],
      );
      expect(allPlan, contains('catalog_items_browse_all'));
      expect(allPlan, isNot(contains('USE TEMP B-TREE FOR ORDER BY')));

      final groupId = db.select(
        "SELECT id FROM source_groups WHERE source_id = ? AND content_kind = ? AND provider_key = 'zebra'",
        [fixture.primary.id, SourceMediaKind.live.name],
      ).single['id'];
      final groupPlan = _queryPlan(
        db,
        '''SELECT id, source_id, kind, title, normalized_title, artwork_locator, playback_ref
           FROM catalog_items
           WHERE source_id = ? AND kind = ? AND available = 1
             AND EXISTS (SELECT 1 FROM sources WHERE sources.id = catalog_items.source_id AND sources.enabled = 1 AND sources.refresh_state = 'ready')
             AND source_group_id = ?
           ORDER BY normalized_title ASC, id ASC
           LIMIT ?''',
        [fixture.primary.id, SourceMediaKind.live.name, groupId, 101],
      );
      expect(groupPlan, contains('catalog_items_browse_page'));
      expect(groupPlan, isNot(contains('USE TEMP B-TREE FOR ORDER BY')));
    } finally {
      db.close();
    }
  });
}

String _queryPlan(Database db, String sql, List<Object?> parameters) => db
    .select('EXPLAIN QUERY PLAN $sql', parameters)
    .map((row) => row['detail']! as String)
    .join('\n');

class _BrowseFixture {
  _BrowseFixture(this.directory)
    : database = SourceCatalogDatabase(
        databasePath:
            '${directory.path}${Platform.pathSeparator}catalog.sqlite',
      );

  final Directory directory;
  final SourceCatalogDatabase database;
  final primary = const SourceDefinition(
    id: 'primary',
    name: 'Primary',
    serverUrl: 'https://primary.example',
    username: 'not-stored',
    password: 'not-stored',
    credentialKey: 'primary-key',
  );
  final secondary = const SourceDefinition(
    id: 'secondary',
    name: 'Secondary',
    serverUrl: 'https://secondary.example',
    username: 'not-stored',
    password: 'not-stored',
    credentialKey: 'secondary-key',
  );

  static Future<_BrowseFixture> create() async =>
      _BrowseFixture(await Directory.systemTemp.createTemp('wabbit-browse-'));

  Future<void> seedSmallCatalog() async {
    await database.commitInitialSource(primary, [
      const ImportedStage(
        kind: SourceMediaKind.live,
        categories: [
          ImportedCategory(providerKey: 'zebra', name: 'Zebra'),
          ImportedCategory(providerKey: 'alpha', name: 'Alpha'),
          ImportedCategory(providerKey: 'empty', name: 'Empty'),
        ],
        items: [
          ImportedCatalogItem(
            providerKey: 'uncategorized',
            title: 'Apple',
            categoryKey: null,
            artworkLocator: null,
            playbackRef: 'ref-apple',
          ),
          ImportedCatalogItem(
            providerKey: 'bravo',
            title: 'Bravo',
            categoryKey: 'alpha',
            artworkLocator: 'art://bravo',
            playbackRef: 'ref-bravo',
          ),
          ImportedCatalogItem(
            providerKey: 'same-1',
            title: 'Same',
            categoryKey: 'zebra',
            artworkLocator: null,
            playbackRef: 'ref-same-1',
          ),
          ImportedCatalogItem(
            providerKey: 'same-2',
            title: 'Same',
            categoryKey: 'zebra',
            artworkLocator: null,
            playbackRef: 'ref-same-2',
          ),
          ImportedCatalogItem(
            providerKey: 'offline',
            title: 'Offline',
            categoryKey: null,
            artworkLocator: null,
            playbackRef: 'ref-offline',
          ),
        ],
      ),
      const ImportedStage(
        kind: SourceMediaKind.movies,
        categories: [],
        items: [
          ImportedCatalogItem(
            providerKey: 'movie',
            title: 'Movie only',
            categoryKey: null,
            artworkLocator: null,
            playbackRef: 'ref-movie',
          ),
        ],
      ),
    ]);
    await database.commitInitialSource(secondary, [
      const ImportedStage(
        kind: SourceMediaKind.live,
        categories: [],
        items: [
          ImportedCatalogItem(
            providerKey: 'other',
            title: 'Other source',
            categoryKey: null,
            artworkLocator: null,
            playbackRef: 'ref-other',
          ),
        ],
      ),
    ]);
    final db = sqlite3.open(await database.resolvedPath());
    try {
      db.execute('UPDATE catalog_items SET available = 0 WHERE id = ?', [
        'primary:live:offline',
      ]);
      db.execute(
        "UPDATE sources SET enabled = 0, refresh_state = 'pending' WHERE id = ?",
        [secondary.id],
      );
    } finally {
      db.close();
    }
  }

  Future<void> dispose() => directory.delete(recursive: true);
}
