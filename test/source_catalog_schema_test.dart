import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:wabbit_tv/src/features/sources/credential_store.dart';
import 'package:wabbit_tv/src/features/sources/source_catalog_database.dart';
import 'package:wabbit_tv/src/features/sources/source_models.dart';
import 'package:wabbit_tv/src/features/sources/xtream_connector.dart';

void main() {
  test(
    'fresh catalog creates the current schema and separate identities',
    () async {
      final fixture = await _SchemaFixture.create();
      addTearDown(fixture.dispose);
      await fixture.seed(
        'fresh',
        'Fresh',
        title: 'Fresh Title',
        playbackRef: 'secret-ref',
      );

      final db = sqlite3.open(fixture.path);
      addTearDown(db.close);
      expect(_tableNames(db), containsAll(_currentTables));
      expect(
        db.select('PRAGMA table_info(sources)').map((row) => row['name']),
        containsAll(['reported_connection_limit', 'connection_limit_override']),
      );
      expect(db.select('SELECT * FROM schema_migrations').length, 12);
      expect(_tableNames(db), contains('playback_progress'));
      expect(
        db
            .select('PRAGMA table_info(playback_progress)')
            .map((row) => row['name']),
        containsAll([
          'library_item_id',
          'media_key',
          'position_ms',
          'duration_ms',
          'watched_ms',
          'completed',
          'cleared',
          'updated_at_us',
        ]),
      );
      expect(
        db
            .select('PRAGMA index_list(custom_group_items)')
            .map((row) => row['name']),
        contains('custom_group_items_library'),
      );
      expect(
        db
            .select(
              '''EXPLAIN QUERY PLAN
               SELECT custom_group_id FROM custom_group_items
               WHERE library_item_id = ?''',
              ['fresh:live:item'],
            )
            .map((row) => row['detail'])
            .join('\n'),
        contains('custom_group_items_library'),
      );
      expect(
        db.select('PRAGMA table_info(source_groups)').map((row) => row['name']),
        containsAll(['hidden', 'generation', 'available']),
      );
      expect(
        db.select('PRAGMA table_info(catalog_items)').map((row) => row['name']),
        contains('hidden'),
      );
      expect(db.select('SELECT * FROM library_items').length, 1);
      expect(db.select('SELECT * FROM library_members').length, 1);
      expect(
        db.select('SELECT title FROM library_fts').single['title'],
        'Fresh Title',
      );
    },
  );

  test('v3 catalog migrates to latest with deterministic identity and secret-free FTS', () async {
    final fixture = await _SchemaFixture.create();
    addTearDown(fixture.dispose);
    final db = sqlite3.open(fixture.path);
    _createVersion3Database(db);
    db.execute(
      '''INSERT INTO sources VALUES
         ('legacy', 'xtream', 'Legacy', 'provider.example', 'legacy-key', 1, 1, 'ready', NULL, NULL, '{}')''',
    );
    db.execute('''INSERT INTO catalog_items VALUES
         ('legacy:live:one', 'legacy', 'one', 'live', NULL, NULL,
          'Legacy Title', 'legacy title', 'playback-secret-123', NULL,
          NULL, NULL, '{"token":"secret"}', 1, 1, '2026-08-17T00:00:00Z')''');
    db.close();

    final roster = await fixture.database.loadSourceRoster();
    // A completed upgrade is safe to open again; no duplicate-object retry.
    expect((await fixture.database.loadSourceRoster()).single.id, 'legacy');

    expect(roster.single.id, 'legacy');
    expect(roster.single.counts[SourceMediaKind.live], 1);
    final migrated = sqlite3.open(fixture.path);
    addTearDown(migrated.close);
    expect(migrated.select('SELECT * FROM schema_migrations').length, 12);
    expect(
      migrated.select(
        'SELECT library_item_id, title, supporting_text FROM library_fts',
      ),
      hasLength(1),
    );
    final ftsText = migrated
        .select('SELECT * FROM library_fts')
        .single
        .values
        .join(' ');
    expect(ftsText, isNot(contains('playback-secret-123')));
    expect(ftsText, isNot(contains('"token"')));
    expect(
      migrated
          .select('SELECT * FROM library_members')
          .single['catalog_item_id'],
      'legacy:live:one',
    );
  });

  test('visibility category directory counts use the source-group availability index', () async {
    final fixture = await _SchemaFixture.create();
    addTearDown(fixture.dispose);
    await fixture.database.commitInitialSource(
      _definition('visibility', 'Visibility'),
      const [
        ImportedStage(
          kind: SourceMediaKind.live,
          categories: [
            ImportedCategory(providerKey: 'news', name: 'News'),
            ImportedCategory(providerKey: 'sports', name: 'Sports'),
          ],
          items: [
            ImportedCatalogItem(
              providerKey: 'news-one',
              title: 'News One',
              categoryKey: 'news',
              playbackRef: 'safe-news',
            ),
            ImportedCatalogItem(
              providerKey: 'sports-one',
              title: 'Sports One',
              categoryKey: 'sports',
              playbackRef: 'safe-sports',
            ),
          ],
        ),
      ],
    );

    final db = sqlite3.open(fixture.path);
    addTearDown(db.close);
    expect(
      db.select('PRAGMA index_list(catalog_items)').map((row) => row['name']),
      contains('catalog_items_source_group_available'),
    );

    final plan = db.select(
      '''EXPLAIN QUERY PLAN
           SELECT groups.id, groups.name, groups.hidden,
                  COUNT(items.id) AS item_count,
                  COALESCE(SUM(CASE WHEN items.hidden = 1 THEN 1 ELSE 0 END), 0)
                    AS hidden_item_count
           FROM source_groups AS groups
           LEFT JOIN catalog_items AS items
             ON items.source_group_id = groups.id
            AND items.available = 1
           WHERE groups.source_id = ? AND groups.content_kind = ?
             AND groups.available = 1
           GROUP BY groups.id
           ORDER BY groups.sort_key ASC, groups.id ASC
           LIMIT ?''',
      ['visibility', SourceMediaKind.live.name, 100],
    );
    final itemAccess = plan
        .map((row) => row['detail']! as String)
        .where((detail) => detail.contains(' items '))
        .toList(growable: false);

    expect(
      itemAccess,
      hasLength(1),
      reason: plan.map((row) => row['detail']).join('\n'),
    );
    expect(
      itemAccess.every(
        (detail) => detail.contains('catalog_items_source_group_available'),
      ),
      isTrue,
      reason: plan.map((row) => row['detail']).join('\n'),
    );
    expect(
      itemAccess.join('\n'),
      isNot(contains('catalog_items_available')),
      reason: plan.map((row) => row['detail']).join('\n'),
    );
  });

  test('startup recovery preserves a durable disabled source', () async {
    final fixture = await _SchemaFixture.create();
    addTearDown(fixture.dispose);
    await fixture.seed('disabled', 'Disabled');
    final db = sqlite3.open(fixture.path);
    db.execute("UPDATE sources SET enabled = 0, refresh_state = 'ready'");
    db.close();

    await fixture.database.recoverPending(_Credentials());

    final roster = await fixture.database.loadSourceRoster();
    expect(roster, hasLength(1));
    expect(roster.single.enabled, isFalse);
    expect(roster.single.status, 'ready');
  });

  test('source roster returns enabled state, status, and counts for multiple sources', () async {
    final fixture = await _SchemaFixture.create();
    addTearDown(fixture.dispose);
    await fixture.seed('one', 'One', kind: SourceMediaKind.live);
    await fixture.seed('two', 'Two', kind: SourceMediaKind.movies);
    final db = sqlite3.open(fixture.path);
    db.execute("UPDATE sources SET enabled = 0 WHERE id = 'two'");
    db.close();

    final roster = await fixture.database.loadSourceRoster();
    final one = roster.singleWhere((entry) => entry.id == 'one');
    final two = roster.singleWhere((entry) => entry.id == 'two');
    expect(one.enabled, isTrue);
    expect(one.kind, 'xtream');
    expect(one.status, 'ready');
    expect(one.counts[SourceMediaKind.live], 1);
    expect(two.enabled, isFalse);
    expect(two.status, 'ready');
    expect(two.counts[SourceMediaKind.movies], 1);
  });

  test('failed and incomplete refresh retain the last-good catalog', () async {
    final fixture = await _SchemaFixture.create();
    addTearDown(fixture.dispose);
    await fixture.seed('refresh', 'Refresh', title: 'Last good');

    final failed = await fixture.database.beginRefresh('refresh');
    expect(failed, isNotNull);
    await fixture.database.failRefresh(
      failed!,
      SourceRefreshFailure.unreachable,
    );
    expect(
      (await fixture.database.browsePage(
        sourceId: 'refresh',
        kind: SourceMediaKind.live,
      )).items.single.title,
      'Last good',
    );
    final afterFailure = sqlite3.open(fixture.path);
    addTearDown(afterFailure.close);
    expect(
      afterFailure
          .select('SELECT last_error FROM sources')
          .single['last_error'],
      'unreachable',
    );
    final failureStatus =
        (await fixture.database.loadSourceRoster()).single.status;
    expect(failureStatus, 'refresh_failed');
    expect(failureStatus, isNot(contains('unreachable')));
    final restarted = SourceCatalogDatabase(databasePath: fixture.path);
    expect(
      (await restarted.loadSourceRoster()).single.status,
      'refresh_failed',
    );

    final interrupted = await fixture.database.beginRefresh('refresh');
    expect(interrupted, isNotNull);
    expect(
      (await fixture.database.browseLibraryPage(
        scope: const LibraryScope.all(),
        kind: SourceMediaKind.live,
      )).items.single.title,
      'Last good',
    );
    await fixture.database.recoverPending(_Credentials());
    expect(
      (await fixture.database.browsePage(
        sourceId: 'refresh',
        kind: SourceMediaKind.live,
      )).items.single.title,
      'Last good',
    );
  });

  test(
    'successful refresh is idempotent and only marks missing rows unavailable',
    () async {
      final fixture = await _SchemaFixture.create();
      addTearDown(fixture.dispose);
      await fixture.seed('refresh', 'Refresh', title: 'Old');

      Future<void> commitCurrent(List<ImportedStage> stages) async {
        final refresh = await fixture.database.beginRefresh('refresh');
        expect(refresh, isNotNull);
        await fixture.database.commitRefresh(refresh!, stages);
      }

      await commitCurrent([_stage('Updated', 'item'), _stage('New', 'new')]);
      await commitCurrent([_stage('Updated', 'item')]);
      final page = await fixture.database.browsePage(
        sourceId: 'refresh',
        kind: SourceMediaKind.live,
      );
      expect(page.items.map((item) => item.title), ['Updated']);
      final db = sqlite3.open(fixture.path);
      addTearDown(db.close);
      expect(
        db.select(
          'SELECT id FROM catalog_items WHERE source_id = ? AND available = 1',
          ['refresh'],
        ),
        hasLength(1),
      );
      expect(
        db.select('SELECT id FROM catalog_items WHERE source_id = ?', [
          'refresh',
        ]),
        hasLength(2),
      );
      expect(db.select('SELECT * FROM library_fts').length, 1);
      expect(
        db.select('SELECT display_title FROM library_items WHERE id = ?', [
          'refresh:live:item',
        ]).single['display_title'],
        'Updated',
      );
      expect(
        db.select('SELECT title FROM library_fts WHERE library_item_id = ?', [
          'refresh:live:item',
        ]).single['title'],
        'Updated',
      );
    },
  );

  test(
    'large refresh rebuilds FTS by stage while local reads keep last good data',
    () async {
      final fixture = await _SchemaFixture.create();
      addTearDown(fixture.dispose);
      await fixture.seed('large', 'Large', title: 'Last good');
      final refresh = await fixture.database.beginRefresh('large');
      expect(refresh, isNotNull);
      final stage = ImportedStage(
        kind: SourceMediaKind.live,
        categories: const [],
        items: List.generate(
          50000,
          (index) => ImportedCatalogItem(
            providerKey: 'item-$index',
            title: 'Refresh catalog item $index',
            categoryKey: null,
            playbackRef: 'safe-$index',
          ),
        ),
      );
      var heartbeats = 0;
      final heartbeat = Timer.periodic(
        const Duration(milliseconds: 10),
        (_) => heartbeats++,
      );
      final write = fixture.database.commitRefresh(refresh!, [stage]);
      final reads = Future.wait([
        fixture.database.loadSourceRoster(),
        fixture.database.browseLibraryPage(
          scope: const LibraryScope.all(),
          kind: SourceMediaKind.live,
        ),
      ]);
      late final List<Object?> completed;
      try {
        completed = await Future.wait<Object?>([write, reads])
            .timeout(const Duration(seconds: 60));
      } finally {
        heartbeat.cancel();
      }

      // The worker-owned write does not poison normal local catalog reads.
      final duringRefresh = completed[1]! as List<Object?>;
      expect((duringRefresh[0] as List<SourceRosterEntry>).single.id, 'large');
      expect((duringRefresh[1] as LibraryPage).items, isNotEmpty);
      expect(heartbeats, greaterThan(0));
    },
  );

  test(
    'refresh source contains one stage FTS delete rather than per-item deletes',
    () async {
      final source = (await File(
        'lib/src/features/sources/source_catalog_database.dart',
      ).readAsString()).replaceAll('\r\n', '\n');
      expect(
        source,
        contains(
          'DELETE FROM library_fts\n       WHERE library_item_id IN (\n         SELECT id FROM catalog_items WHERE source_id = ? AND kind = ?',
        ),
      );
      expect(
        source,
        isNot(contains("DELETE FROM library_fts WHERE library_item_id = ?")),
      );
    },
  );

  test(
    'an abnormal refresh worker exit clears only its busy source marker',
    () async {
      final fixture = await _SchemaFixture.create();
      addTearDown(fixture.dispose);
      await fixture.seed('crashed', 'Crashed');
      final refresh = await fixture.database.beginRefresh('crashed');
      expect(refresh, isNotNull);

      final crashed = await M3uRefreshImport.start(
        path: fixture.path,
        sourceId: 'crashed',
        locator: fixture.path,
        isUrl: false,
        exitImmediatelyForTest: true,
      );
      await expectLater(
        crashed.completed.timeout(const Duration(seconds: 10)),
        throwsA(isA<SourceImportFailure>()),
      );
      final db = sqlite3.open(fixture.path);
      addTearDown(db.close);
      final row = db.select(
        'SELECT refresh_state, last_error FROM sources WHERE id = ?',
        ['crashed'],
      ).single;
      expect(row['refresh_state'], 'ready');
      expect(row['last_error'], SourceRefreshFailure.unreachable.name);
    },
  );

  test(
    'disabled sources are absent from active browse but remain in the roster',
    () async {
      final fixture = await _SchemaFixture.create();
      addTearDown(fixture.dispose);
      await fixture.seed('disabled', 'Disabled');
      await fixture.database.setSourceEnabled('disabled', false);

      expect(
        await fixture.database.browseCategories(
          sourceId: 'disabled',
          kind: SourceMediaKind.live,
        ),
        isEmpty,
      );
      expect(
        (await fixture.database.loadSourceRoster()).single.enabled,
        isFalse,
      );
    },
  );

  test(
    'removing one source removes only its member and catalog variant',
    () async {
      final fixture = await _SchemaFixture.create();
      addTearDown(fixture.dispose);
      await fixture.seed('one', 'One');
      await fixture.seed('two', 'Two');

      await fixture.database.removeSource('one');

      final db = sqlite3.open(fixture.path);
      addTearDown(db.close);
      expect(db.select('SELECT id FROM sources').single['id'], 'two');
      expect(
        db.select('SELECT source_id FROM catalog_items').single['source_id'],
        'two',
      );
      expect(
        db
            .select('SELECT catalog_item_id FROM library_members')
            .single['catalog_item_id'],
        'two:live:item',
      );
      // The removed identity remains available to future organization data.
      expect(db.select('SELECT id FROM library_items'), hasLength(2));
    },
  );

  test(
    'library scope, active state, paging, and literal FTS search stay bounded',
    () async {
      final fixture = await _SchemaFixture.create();
      addTearDown(fixture.dispose);
      await fixture.database.commitInitialSource(
        _definition('alpha', 'Alpha'),
        [_stage('News (One)', 'one', category: 'Sports & News')],
      );
      await fixture.database.commitInitialSource(_definition('beta', 'Beta'), [
        _stage('News Two', 'two', category: 'Sports & News'),
      ]);
      await fixture.database.commitInitialSource(
        _definition('gamma', 'Gamma'),
        [_stage('Café 世界', 'unicode')],
      );

      expect(
        (await fixture.database.browseLibraryPage(
          scope: const LibraryScope.source('alpha'),
          kind: SourceMediaKind.live,
        )).items.map((item) => item.sourceId),
        ['alpha'],
      );
      expect(
        (await fixture.database.browseLibraryPage(
          scope: const LibraryScope.all(),
          kind: SourceMediaKind.live,
        )).items,
        hasLength(3),
      );
      final search = await fixture.database.searchLibraryPage(
        query: 'Sports & (News)',
        scope: const LibraryScope.all(),
        kind: SourceMediaKind.live,
      );
      expect(search.items, hasLength(2));
      expect(
        (await fixture.database.searchLibraryPage(
          query: 'Café + 世界',
          scope: const LibraryScope.all(),
          kind: SourceMediaKind.live,
        )).items.single.sourceId,
        'gamma',
      );
      await fixture.database.setSourceEnabled('beta', false);
      expect(
        (await fixture.database.browseLibraryPage(
          scope: const LibraryScope.all(),
          kind: SourceMediaKind.live,
        )).items.map((item) => item.sourceId),
        containsAll(['alpha', 'gamma']),
      );

      final db = sqlite3.open(fixture.path);
      addTearDown(db.close);
      final fts = db
          .select('SELECT * FROM library_fts')
          .map((row) => row.values.join(' '))
          .join(' ');
      expect(fts, contains('Sports & News'));
      expect(fts, isNot(contains('never-indexed-ref')));
      expect(fts, isNot(contains('provider.example')));
      expect(fts, isNot(contains('alpha-key')));
    },
  );

  test('50k library browse and FTS pages stay off-isolate and cursor deterministic', () async {
    final fixture = await _SchemaFixture.create();
    addTearDown(fixture.dispose);
    await fixture.database.commitInitialSource(_definition('bulk', 'Bulk'), [
      ImportedStage(
        kind: SourceMediaKind.live,
        categories: const [],
        items: [
          for (var index = 0; index < 50000; index++)
            ImportedCatalogItem(
              providerKey: '$index',
              title: index < 318 ? 'Fox fixture $index' : 'Channel $index',
              categoryKey: null,
              playbackRef: 'ref-$index',
            ),
        ],
      ),
    ]);
    var beats = 0;
    final heartbeat = Timer.periodic(
      const Duration(milliseconds: 1),
      (_) => beats++,
    );
    final first = await fixture.database.browseLibraryPage(
      scope: const LibraryScope.all(),
      kind: SourceMediaKind.live,
      limit: 200,
    );
    heartbeat.cancel();
    final second = await fixture.database.browseLibraryPage(
      scope: const LibraryScope.all(),
      kind: SourceMediaKind.live,
      cursor: first.nextCursor,
      limit: 200,
    );
    final search = await fixture.database.searchLibraryPage(
      query: 'Fox',
      scope: const LibraryScope.all(),
      limit: 200,
    );
    final nextSearch = await fixture.database.searchLibraryPage(
      query: 'Fox',
      scope: const LibraryScope.all(),
      cursor: search.nextCursor,
      limit: 200,
    );
    final searchCount = await fixture.database.countLibraryItems(
      scope: const LibraryScope.all(),
      kind: SourceMediaKind.live,
      query: 'Fox',
    );
    expect(beats, greaterThan(0));
    expect(first.items, hasLength(200));
    expect(first.nextCursor, isNotNull);
    expect(second.items, hasLength(200));
    expect(
      second.items.first.catalogItemId,
      isNot(first.items.last.catalogItemId),
    );
    expect(search.items, hasLength(200));
    expect(search.nextCursor, isNotNull);
    expect(nextSearch.items, hasLength(118));
    expect(searchCount, 318);
    expect(
      [...search.items, ...nextSearch.items].map((item) => item.kind),
      everyElement(SourceMediaKind.live),
    );
    expect(
      nextSearch.items.first.catalogItemId,
      isNot(search.items.last.catalogItemId),
    );

    final bundledSqlite = sqlite3.open(fixture.path);
    addTearDown(bundledSqlite.close);
    final pagePlan = bundledSqlite.select(
      '''EXPLAIN QUERY PLAN WITH ranked AS (
           SELECT library.id AS library_item_id,
                  catalog.id AS catalog_item_id,
                  catalog.source_id,
                  source.name AS source_display_name,
                  catalog.kind,
                  library.display_title,
                  library.normalized_title,
                  library.artwork_locator,
                  catalog.playback_ref,
                  ROW_NUMBER() OVER (
                    PARTITION BY library.id
                    ORDER BY member.preferred DESC,
                             catalog.source_id ASC,
                             catalog.id ASC
                  ) AS variant_rank
           FROM library_fts
           CROSS JOIN library_items AS library
             ON library.id = library_fts.library_item_id
           CROSS JOIN library_members AS member
             ON member.library_item_id = library.id
           CROSS JOIN catalog_items AS catalog
             ON catalog.id = member.catalog_item_id
           CROSS JOIN sources AS source ON source.id = catalog.source_id
           WHERE catalog.available = 1
             AND catalog.hidden = 0
             AND NOT EXISTS (
               SELECT 1 FROM source_groups AS visibility_group
               WHERE visibility_group.id = catalog.source_group_id
                 AND visibility_group.hidden = 1
             )
             AND source.enabled = 1
             AND source.refresh_state IN ('ready', 'refreshing')
             AND catalog.kind = ?
             AND library_fts MATCH ?
         )
         SELECT library_item_id, catalog_item_id, source_id,
                source_display_name, kind, display_title, normalized_title,
                artwork_locator, playback_ref
         FROM ranked
         WHERE variant_rank = 1
         ORDER BY normalized_title ASC, library_item_id ASC
         LIMIT ?''',
      [SourceMediaKind.live.name, '"Fox"', 201],
    );
    final scopedCursorPagePlan = bundledSqlite.select(
      '''EXPLAIN QUERY PLAN WITH ranked AS (
           SELECT library.id AS library_item_id,
                  catalog.id AS catalog_item_id,
                  catalog.source_id,
                  source.name AS source_display_name,
                  catalog.kind,
                  library.display_title,
                  library.normalized_title,
                  library.artwork_locator,
                  catalog.playback_ref,
                  ROW_NUMBER() OVER (
                    PARTITION BY library.id
                    ORDER BY member.preferred DESC,
                             catalog.source_id ASC,
                             catalog.id ASC
                  ) AS variant_rank
           FROM library_fts
           CROSS JOIN library_items AS library
             ON library.id = library_fts.library_item_id
           CROSS JOIN library_members AS member
             ON member.library_item_id = library.id
           CROSS JOIN catalog_items AS catalog
             ON catalog.id = member.catalog_item_id
           CROSS JOIN sources AS source ON source.id = catalog.source_id
           WHERE catalog.available = 1
             AND catalog.hidden = 0
             AND NOT EXISTS (
               SELECT 1 FROM source_groups AS visibility_group
               WHERE visibility_group.id = catalog.source_group_id
                 AND visibility_group.hidden = 1
             )
             AND source.enabled = 1
             AND source.refresh_state IN ('ready', 'refreshing')
             AND catalog.kind = ?
             AND catalog.source_id = ?
             AND library_fts MATCH ?
         )
         SELECT library_item_id, catalog_item_id, source_id,
                source_display_name, kind, display_title, normalized_title,
                artwork_locator, playback_ref
         FROM ranked
         WHERE variant_rank = 1
           AND (normalized_title > ?
             OR (normalized_title = ? AND library_item_id > ?))
         ORDER BY normalized_title ASC, library_item_id ASC
         LIMIT ?''',
      [
        SourceMediaKind.live.name,
        'bulk',
        '"Fox"',
        search.nextCursor!.normalizedTitle,
        search.nextCursor!.normalizedTitle,
        search.nextCursor!.id,
        201,
      ],
    );
    final countPlan = bundledSqlite.select(
      '''EXPLAIN QUERY PLAN
         SELECT COUNT(DISTINCT library.id) AS count
         FROM library_fts
         CROSS JOIN library_items AS library
           ON library.id = library_fts.library_item_id
         CROSS JOIN library_members AS member
           ON member.library_item_id = library.id
         CROSS JOIN catalog_items AS catalog
           ON catalog.id = member.catalog_item_id
         CROSS JOIN sources AS source ON source.id = catalog.source_id
         WHERE catalog.available = 1
           AND catalog.hidden = 0
           AND NOT EXISTS (
             SELECT 1 FROM source_groups AS visibility_group
             WHERE visibility_group.id = catalog.source_group_id
               AND visibility_group.hidden = 1
           )
           AND source.enabled = 1
           AND source.refresh_state IN ('ready', 'refreshing')
           AND catalog.kind = ?
           AND library_fts MATCH ?''',
      [SourceMediaKind.live.name, '"Fox"'],
    );
    final scopedCountPlan = bundledSqlite.select(
      '''EXPLAIN QUERY PLAN
         SELECT COUNT(DISTINCT library.id) AS count
         FROM library_fts
         CROSS JOIN library_items AS library
           ON library.id = library_fts.library_item_id
         CROSS JOIN library_members AS member
           ON member.library_item_id = library.id
         CROSS JOIN catalog_items AS catalog
           ON catalog.id = member.catalog_item_id
         CROSS JOIN sources AS source ON source.id = catalog.source_id
         WHERE catalog.available = 1
           AND catalog.hidden = 0
           AND NOT EXISTS (
             SELECT 1 FROM source_groups AS visibility_group
             WHERE visibility_group.id = catalog.source_group_id
               AND visibility_group.hidden = 1
           )
           AND source.enabled = 1
           AND source.refresh_state IN ('ready', 'refreshing')
           AND catalog.kind = ?
           AND catalog.source_id = ?
           AND library_fts MATCH ?''',
      [SourceMediaKind.live.name, 'bulk', '"Fox"'],
    );
    _expectFtsJoinOrder(pagePlan);
    _expectFtsJoinOrder(scopedCursorPagePlan);
    _expectFtsJoinOrder(countPlan);
    _expectFtsJoinOrder(scopedCountPlan);
  });
}

void _expectFtsJoinOrder(ResultSet plan) {
  final access = plan
      .map((row) => row['detail']! as String)
      .where(
        (detail) => detail.startsWith('SCAN ') || detail.startsWith('SEARCH '),
      )
      .toList(growable: false);
  final mainAccess = access
      .where(
        (detail) =>
            detail.contains('library_fts VIRTUAL TABLE') ||
            detail.startsWith('SCAN library ') ||
            detail.startsWith('SEARCH library ') ||
            detail.startsWith('SCAN member ') ||
            detail.startsWith('SEARCH member ') ||
            detail.startsWith('SCAN catalog ') ||
            detail.startsWith('SEARCH catalog ') ||
            detail.startsWith('SCAN source ') ||
            detail.startsWith('SEARCH source '),
      )
      .toList(growable: false);
  expect(mainAccess.map(_planTable).toList(growable: false), [
    'library_fts',
    'library',
    'member',
    'catalog',
    'source',
  ], reason: access.join('\n'));
}

String _planTable(String detail) {
  if (detail.contains('library_fts VIRTUAL TABLE')) return 'library_fts';
  return detail.split(' ')[1];
}

SourceDefinition _definition(String id, String name) => SourceDefinition(
  id: id,
  name: name,
  serverUrl: 'https://provider.example',
  username: 'user',
  password: 'password',
  credentialKey: '$id-key',
);

ImportedStage _stage(String title, String key, {String? category}) =>
    ImportedStage(
      kind: SourceMediaKind.live,
      categories: category == null
          ? const []
          : [ImportedCategory(providerKey: 'category', name: category)],
      items: [
        ImportedCatalogItem(
          providerKey: key,
          title: title,
          categoryKey: category == null ? null : 'category',
          playbackRef: 'never-indexed-ref',
        ),
      ],
    );

const _currentTables = [
  'sources',
  'source_groups',
  'catalog_items',
  'library_items',
  'library_members',
  'favorites',
  'custom_groups',
  'custom_group_items',
  'watch_state',
  'playback_progress',
  'epg_source_state',
  'epg_channel_state',
  'epg_programs',
  'app_settings',
  'library_fts',
];

Iterable<String> _tableNames(Database db) => db
    .select(
      "SELECT name FROM sqlite_master WHERE type IN ('table', 'virtual table')",
    )
    .map((row) => row['name']! as String);

class _SchemaFixture {
  _SchemaFixture(this.directory)
    : path = '${directory.path}${Platform.pathSeparator}catalog.sqlite',
      database = SourceCatalogDatabase(
        databasePath:
            '${directory.path}${Platform.pathSeparator}catalog.sqlite',
      );

  final Directory directory;
  final String path;
  final SourceCatalogDatabase database;

  static Future<_SchemaFixture> create() async =>
      _SchemaFixture(await Directory.systemTemp.createTemp('wabbit-schema-'));

  Future<void> seed(
    String id,
    String name, {
    SourceMediaKind kind = SourceMediaKind.live,
    String? title,
    String playbackRef = 'safe-ref',
  }) => database.commitInitialSource(
    SourceDefinition(
      id: id,
      name: name,
      serverUrl: 'https://provider.example',
      username: 'user',
      password: 'password',
      credentialKey: '$id-key',
    ),
    [
      ImportedStage(
        kind: kind,
        categories: const [],
        items: [
          ImportedCatalogItem(
            providerKey: 'item',
            title: title ?? '$name item',
            categoryKey: null,
            playbackRef: playbackRef,
          ),
        ],
      ),
    ],
  );

  Future<void> dispose() => directory.delete(recursive: true);
}

class _Credentials implements CredentialStore {
  @override
  Future<void> delete(String key) async {}

  @override
  Future<StoredCredential?> read(String key) async => null;

  @override
  Future<void> write({
    required String key,
    required String username,
    required String password,
    String? serverUrl,
  }) async {}
}

void _createVersion3Database(Database db) {
  db.execute('CREATE TABLE schema_migrations (version INTEGER PRIMARY KEY)');
  for (final version in [1, 2, 3]) {
    db.execute('INSERT INTO schema_migrations VALUES (?)', [version]);
  }
  db.execute(
    '''CREATE TABLE sources (id TEXT PRIMARY KEY, kind TEXT NOT NULL, name TEXT NOT NULL, display_endpoint TEXT NOT NULL, credential_key TEXT NOT NULL, enabled INTEGER NOT NULL, refresh_generation INTEGER NOT NULL, refresh_state TEXT NOT NULL, last_refresh_at TEXT, last_error TEXT, settings_json TEXT NOT NULL)''',
  );
  db.execute(
    '''CREATE TABLE source_groups (id INTEGER PRIMARY KEY AUTOINCREMENT, source_id TEXT NOT NULL, provider_key TEXT NOT NULL, content_kind TEXT NOT NULL, name TEXT NOT NULL, sort_key TEXT NOT NULL, UNIQUE(source_id, provider_key, content_kind))''',
  );
  db.execute(
    '''CREATE TABLE catalog_items (id TEXT PRIMARY KEY, source_id TEXT NOT NULL, provider_key TEXT NOT NULL, kind TEXT NOT NULL, parent_id TEXT, source_group_id INTEGER, title TEXT NOT NULL, normalized_title TEXT NOT NULL, playback_ref TEXT NOT NULL, artwork_locator TEXT, year INTEGER, external_id TEXT, metadata_json TEXT, generation INTEGER NOT NULL, available INTEGER NOT NULL, updated_at TEXT NOT NULL, UNIQUE(source_id, provider_key, kind))''',
  );
}
