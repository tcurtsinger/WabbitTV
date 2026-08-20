import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:wabbit_tv/src/features/library/my_library_service.dart';
import 'package:wabbit_tv/src/features/sources/source_catalog_database.dart';
import 'package:wabbit_tv/src/features/sources/source_models.dart';

void main() {
  test(
    'recent history records occurrence and selects one active exact variant',
    () async {
      final fixture = await _ContinuityFixture.create();
      addTearDown(fixture.dispose);
      expect(await fixture.database.hasAnySource(), isFalse);
      await fixture.seed();
      expect(await fixture.database.hasAnySource(), isTrue);

      expect(
        await fixture.database.recordRecentlyWatched(
          'source:movies:one',
          playedAt: DateTime.utc(2026, 8, 18, 12),
        ),
        isTrue,
      );
      expect(
        await fixture.database.recordRecentlyWatched(
          'source:movies:two',
          playedAt: DateTime.utc(2026, 8, 18, 13),
        ),
        isTrue,
      );
      // A delayed older callback cannot move an item backward or overwrite the
      // later Phase 5 position fields already present in watch_state.
      final raw = sqlite3.open(fixture.path);
      raw.execute(
        '''UPDATE watch_state
         SET position_ms = 9000, duration_ms = 60000, completed = 0
         WHERE library_item_id = ?''',
        ['source:movies:one'],
      );
      raw.close();
      await fixture.database.recordRecentlyWatched(
        'source:movies:one',
        playedAt: DateTime.utc(2026, 8, 18, 11),
      );

      final recent = await fixture.database.loadRecentlyWatched(limit: 2);
      expect(recent.map((entry) => entry.item.libraryItemId), [
        'source:movies:two',
        'source:movies:one',
      ]);
      expect(recent.first.item.sourceId, 'source');
      expect(recent.first.item.sourceDisplayName, 'Source');
      expect(recent.first.item.catalogItemId, 'source:movies:two');
      expect(recent.first.item.playbackRef, contains('providerId'));

      final check = sqlite3.open(fixture.path);
      final state = check
          .select(
            '''SELECT position_ms, duration_ms, last_played_at FROM watch_state
         WHERE library_item_id = ?''',
            ['source:movies:one'],
          )
          .single;
      check.close();
      expect(state['position_ms'], 9000);
      expect(state['duration_ms'], 60000);
      expect(
        state['last_played_at'],
        DateTime.utc(2026, 8, 18, 12).toIso8601String(),
      );
      expect(
        await fixture.database.recordRecentlyWatched('missing-identity'),
        isFalse,
      );
    },
  );

  test(
    'recent history filters hidden unavailable and disabled variants',
    () async {
      final fixture = await _ContinuityFixture.create();
      addTearDown(fixture.dispose);
      await fixture.seed();
      for (final id in ['source:movies:one', 'source:movies:two']) {
        await fixture.database.recordRecentlyWatched(id);
      }

      await fixture.database.setCatalogItemHidden(
        sourceId: 'source',
        catalogItemId: 'source:movies:one',
        hidden: true,
      );
      expect(
        (await fixture.database.loadRecentlyWatched()).map(
          (entry) => entry.item.libraryItemId,
        ),
        ['source:movies:two'],
      );
      await fixture.database.setCatalogItemHidden(
        sourceId: 'source',
        catalogItemId: 'source:movies:one',
        hidden: false,
      );
      final category =
          (await fixture.database.browseCategories(
            sourceId: 'source',
            kind: SourceMediaKind.movies,
          )).singleWhere(
            (entry) =>
                entry.selection.kind == BrowseCategorySelectionKind.sourceGroup,
          );
      await fixture.database.setSourceGroupHidden(
        sourceId: 'source',
        kind: SourceMediaKind.movies,
        sourceGroupId: category.selection.sourceGroupId!,
        hidden: true,
      );
      expect(
        (await fixture.database.loadRecentlyWatched()).map(
          (entry) => entry.item.libraryItemId,
        ),
        ['source:movies:two'],
      );
      await fixture.database.setSourceGroupHidden(
        sourceId: 'source',
        kind: SourceMediaKind.movies,
        sourceGroupId: category.selection.sourceGroupId!,
        hidden: false,
      );
      final raw = sqlite3.open(fixture.path);
      raw.execute('UPDATE catalog_items SET available = 0 WHERE id = ?', [
        'source:movies:two',
      ]);
      raw.close();
      expect(
        (await fixture.database.loadRecentlyWatched()).map(
          (entry) => entry.item.libraryItemId,
        ),
        ['source:movies:one'],
      );
      await fixture.database.setSourceEnabled('source', false);
      expect(await fixture.database.loadRecentlyWatched(), isEmpty);
    },
  );

  test(
    'read-only personal directory and pages keep deterministic order',
    () async {
      final fixture = await _ContinuityFixture.create();
      addTearDown(fixture.dispose);
      await fixture.seed();
      final raw = sqlite3.open(fixture.path);
      raw.execute('''INSERT INTO favorites VALUES
         ('source:movies:one', '2026-08-18T12:00:00.000Z'),
         ('source:movies:two', '2026-08-18T13:00:00.000Z')''');
      raw.execute('''INSERT INTO custom_groups
         (id, name, home_ordinal, created_at, updated_at, directory_ordinal)
         VALUES ('weekend', 'Weekend', NULL, '2026-08-18T00:00:00.000Z',
          '2026-08-18T00:00:00.000Z', 0)''');
      raw.execute('''INSERT INTO custom_group_items VALUES
         ('weekend', 'source:movies:two', 20),
         ('weekend', 'source:movies:one', 10)''');
      raw.close();

      final directory = await fixture.database.loadPersonalLibraryDirectory();
      expect(directory.map((entry) => entry.name), ['Favorites', 'Weekend']);
      expect(directory.map((entry) => entry.itemCount), [2, 2]);

      final favoriteFirst = await fixture.database.loadFavoriteLibraryPage(
        limit: 1,
      );
      expect(favoriteFirst.items.single.libraryItemId, 'source:movies:two');
      expect(favoriteFirst.items.single.playableItem?.sourceId, 'source');
      final favoriteSecond = await fixture.database.loadFavoriteLibraryPage(
        cursor: favoriteFirst.nextCursor,
        limit: 1,
      );
      expect(favoriteSecond.items.single.libraryItemId, 'source:movies:one');

      final groupFirst = await fixture.database.loadCustomGroupLibraryPage(
        customGroupId: 'weekend',
        limit: 1,
      );
      expect(groupFirst.items.single.libraryItemId, 'source:movies:one');
      final groupSecond = await fixture.database.loadCustomGroupLibraryPage(
        customGroupId: 'weekend',
        cursor: groupFirst.nextCursor,
        limit: 1,
      );
      expect(groupSecond.items.single.libraryItemId, 'source:movies:two');

      final adapter = DatabaseMyLibraryData(fixture.database);
      await adapter.loadSections();
      await adapter.loadItems(sectionId: 'favorites');
      await adapter.loadItems(sectionId: 'weekend');
      expect(
        (await adapter.resolvePlayableItem('source:movies:two'))?.sourceId,
        'source',
      );

      await fixture.database.setSourceEnabled('source', false);
      final unavailable = await fixture.database.loadCustomGroupLibraryPage(
        customGroupId: 'weekend',
      );
      expect(unavailable.items, hasLength(2));
      expect(unavailable.items.every((item) => !item.isAvailable), isTrue);
    },
  );

  test(
    'large personal ledgers page membership first with ordered indexes',
    () async {
      final fixture = await _ContinuityFixture.create();
      addTearDown(fixture.dispose);
      await fixture.seed();
      final raw = sqlite3.open(fixture.path);
      raw.execute('BEGIN IMMEDIATE');
      try {
        raw.execute('''WITH RECURSIVE seq(i) AS (
             SELECT 0 UNION ALL SELECT i + 1 FROM seq WHERE i < 4999
           )
           INSERT INTO library_items
             (id, kind, display_title, normalized_title, artwork_locator)
           SELECT printf('bulk-%05d', i), 'movies',
                  printf('Bulk %05d', i), printf('bulk %05d', i), NULL
           FROM seq''');
        raw.execute('''WITH RECURSIVE seq(i) AS (
             SELECT 0 UNION ALL SELECT i + 1 FROM seq WHERE i < 4999
           )
           INSERT INTO catalog_items
             (id, source_id, provider_key, kind, parent_id, source_group_id,
              title, normalized_title, playback_ref, artwork_locator, year,
              external_id, metadata_json, generation, available, updated_at,
              hidden)
           SELECT printf('bulk-%05d', i), 'source', printf('bulk-%05d', i),
                  'movies', NULL, NULL, printf('Bulk %05d', i),
                  printf('bulk %05d', i),
                  printf('{"providerId":"bulk-%05d","kind":"movies"}', i),
                  NULL, NULL, NULL, NULL, 1, 1,
                  '2026-08-18T00:00:00.000Z', 0
           FROM seq''');
        raw.execute('''INSERT INTO library_members
             (library_item_id, catalog_item_id, preferred)
           SELECT id, id, 1 FROM library_items WHERE id LIKE 'bulk-%' ''');
        raw.execute('''INSERT INTO favorites (library_item_id, created_at)
           SELECT id,
                  strftime('%Y-%m-%dT%H:%M:%fZ',
                           '2026-01-01T00:00:00Z',
                           '+' || CAST(substr(id, 6) AS INTEGER) || ' seconds')
           FROM library_items WHERE id LIKE 'bulk-%' ''');
        raw.execute('''INSERT INTO custom_groups
           (id, name, home_ordinal, created_at, updated_at, directory_ordinal)
           VALUES ('large', 'Large', NULL, '2026-08-18T00:00:00.000Z',
            '2026-08-18T00:00:00.000Z', 0)''');
        raw.execute('''INSERT INTO custom_group_items
             (custom_group_id, library_item_id, ordinal)
           SELECT 'large', id, CAST(substr(id, 6) AS INTEGER)
           FROM library_items WHERE id LIKE 'bulk-%' ''');
        raw.execute('COMMIT');
      } catch (_) {
        raw.execute('ROLLBACK');
        rethrow;
      }

      final favoritePlan = raw.select(
        '''EXPLAIN QUERY PLAN SELECT library_item_id, created_at
           FROM favorites
           ORDER BY created_at DESC, library_item_id ASC LIMIT 101''',
      );
      final groupPlan = raw.select(
        '''EXPLAIN QUERY PLAN SELECT library_item_id, ordinal
           FROM custom_group_items WHERE custom_group_id = 'large'
           ORDER BY ordinal ASC, library_item_id ASC LIMIT 101''',
      );
      expect(
        favoritePlan.map((row) => row['detail']).join('\n'),
        contains('favorites_recent_page'),
      );
      expect(
        groupPlan.map((row) => row['detail']).join('\n'),
        contains('custom_group_items_page'),
      );
      raw.close();

      final firstFavorite = await fixture.database
          .loadFavoriteLibraryPage(limit: 100)
          .timeout(const Duration(seconds: 10));
      final secondFavorite = await fixture.database
          .loadFavoriteLibraryPage(cursor: firstFavorite.nextCursor, limit: 100)
          .timeout(const Duration(seconds: 10));
      expect(firstFavorite.items, hasLength(100));
      expect(secondFavorite.items, hasLength(100));
      expect(firstFavorite.items.first.libraryItemId, 'bulk-04999');
      expect(secondFavorite.items.first.libraryItemId, 'bulk-04899');
      expect(
        firstFavorite.items
            .map((item) => item.libraryItemId)
            .toSet()
            .intersection(
              secondFavorite.items.map((item) => item.libraryItemId).toSet(),
            ),
        isEmpty,
      );

      final firstGroup = await fixture.database
          .loadCustomGroupLibraryPage(customGroupId: 'large', limit: 100)
          .timeout(const Duration(seconds: 10));
      final secondGroup = await fixture.database
          .loadCustomGroupLibraryPage(
            customGroupId: 'large',
            cursor: firstGroup.nextCursor,
            limit: 100,
          )
          .timeout(const Duration(seconds: 10));
      expect(firstGroup.items.first.libraryItemId, 'bulk-00000');
      expect(secondGroup.items.first.libraryItemId, 'bulk-00100');
    },
  );
}

class _ContinuityFixture {
  _ContinuityFixture(this.directory, this.path)
    : database = SourceCatalogDatabase(databasePath: path);

  final Directory directory;
  final String path;
  final SourceCatalogDatabase database;

  static Future<_ContinuityFixture> create() async {
    final directory = await Directory.systemTemp.createTemp('wabbit-history-');
    return _ContinuityFixture(directory, '${directory.path}/catalog.sqlite');
  }

  Future<void> seed() => database.commitInitialSource(
    const SourceDefinition(
      id: 'source',
      name: 'Source',
      serverUrl: 'https://provider.example',
      username: 'user',
      password: 'secret',
      credentialKey: 'source-key',
    ),
    const [
      ImportedStage(
        kind: SourceMediaKind.movies,
        categories: [
          ImportedCategory(providerKey: 'featured', name: 'Featured'),
        ],
        items: [
          ImportedCatalogItem(
            providerKey: 'one',
            title: 'One',
            categoryKey: 'featured',
            playbackRef:
                '{"providerId":"one","kind":"movies","extension":"mp4"}',
          ),
          ImportedCatalogItem(
            providerKey: 'two',
            title: 'Two',
            categoryKey: null,
            playbackRef:
                '{"providerId":"two","kind":"movies","extension":"mp4"}',
          ),
        ],
      ),
    ],
  );

  Future<void> dispose() => directory.delete(recursive: true);
}
