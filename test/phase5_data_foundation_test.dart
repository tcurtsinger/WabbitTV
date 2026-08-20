import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:wabbit_tv/src/features/sources/source_catalog_database.dart';
import 'package:wabbit_tv/src/features/sources/source_models.dart';
import 'package:wabbit_tv/src/features/sources/xtream_connector.dart';

void main() {
  test(
    'schema v11 progress is exact, indexed, idempotent, and redacted',
    () async {
      final fixture = await _Phase5Fixture.create();
      addTearDown(fixture.dispose);
      await fixture.seed(
        id: 'series-source',
        kind: SourceMediaKind.series,
        title: 'Series title',
        playbackRef: '{"providerId":"series-secret","token":"must-not-copy"}',
      );

      // Opening the migrated database repeatedly must not duplicate schema or
      // fail on triggers/tables that already exist.
      expect(await fixture.database.loadSourceRoster(), hasLength(1));
      expect(await fixture.database.loadSourceRoster(), hasLength(1));

      final db = sqlite3.open(fixture.path);
      addTearDown(db.close);
      expect(db.select('SELECT version FROM schema_migrations'), hasLength(12));
      expect(
        db
            .select('PRAGMA table_info(playback_progress)')
            .map((row) => row['name']),
        [
          'library_item_id',
          'media_key',
          'position_ms',
          'duration_ms',
          'watched_ms',
          'completed',
          'cleared',
          'updated_at_us',
        ],
      );
      final watchedColumn = db
          .select('PRAGMA table_info(playback_progress)')
          .singleWhere((row) => row['name'] == 'watched_ms');
      expect(watchedColumn['notnull'], 1);
      expect('${watchedColumn['dflt_value']}', '0');
      final clearedColumn = db
          .select('PRAGMA table_info(playback_progress)')
          .singleWhere((row) => row['name'] == 'cleared');
      expect(clearedColumn['notnull'], 1);
      expect('${clearedColumn['dflt_value']}', '0');
      final plan = db
          .select(
            '''EXPLAIN QUERY PLAN
               SELECT position_ms FROM playback_progress
               WHERE library_item_id = ? AND media_key = ? LIMIT 1''',
            ['series-source:series:item', 'episode:one'],
          )
          .map((row) => row['detail'])
          .join('\n');
      expect(plan, contains('sqlite_autoindex_playback_progress_1'));

      final columns = db
          .select('PRAGMA table_info(playback_progress)')
          .map((row) => row['name']! as String)
          .join(' ');
      expect(columns, isNot(contains('playback')));
      expect(columns, isNot(contains('locator')));
      expect(columns, isNot(contains('title')));
      expect(columns, isNot(contains('credential')));
      expect(columns, isNot(contains('error')));
    },
  );

  test(
    'two concurrent v10 opens migrate v11 once under the write lock',
    () async {
      final fixture = await _Phase5Fixture.create();
      addTearDown(fixture.dispose);
      await fixture.seed(id: 'legacy', kind: SourceMediaKind.movies);
      final legacy = sqlite3.open(fixture.path);
      legacy.execute('DROP TRIGGER sources_connection_override_insert');
      legacy.execute('DROP TRIGGER sources_connection_override_update');
      legacy.execute('DROP TABLE playback_progress');
      legacy.execute('DELETE FROM schema_migrations WHERE version >= 11');
      legacy.execute(
        'UPDATE sources SET connection_limit_override = 9 WHERE id = ?',
        ['legacy'],
      );
      legacy.close();

      // Hold the writer so both database workers read v10 before competing for
      // the same migration lock. The second must re-read the version after the
      // first commits rather than attempting a duplicate version insert.
      final blocker = sqlite3.open(fixture.path);
      blocker.execute('PRAGMA busy_timeout = 8000');
      blocker.execute('BEGIN IMMEDIATE');
      final concurrentOpens = [
        SourceCatalogDatabase(databasePath: fixture.path).loadSourceRoster(),
        SourceCatalogDatabase(databasePath: fixture.path).loadSourceRoster(),
      ];
      await Future<void>.delayed(const Duration(milliseconds: 250));
      blocker.execute('COMMIT');
      blocker.close();
      final rosters = await Future.wait(concurrentOpens)
          .timeout(const Duration(seconds: 10));
      expect(rosters.every((roster) => roster.length == 1), isTrue);

      final upgraded = SourceCatalogDatabase(databasePath: fixture.path);
      expect(await upgraded.loadSourceRoster(), hasLength(1));
      final check = sqlite3.open(fixture.path);
      addTearDown(check.close);
      expect(
        check.select(
          'SELECT version FROM schema_migrations WHERE version = 11',
        ),
        hasLength(1),
      );
      expect(
        check.select(
          "SELECT name FROM sqlite_master WHERE name = 'playback_progress'",
        ),
        hasLength(1),
      );
      expect(
        (await upgraded.loadSourceConnectionAllowance('legacy'))?.overrideLimit,
        isNull,
      );
    },
  );

  test('early v11 progress rows backfill watched time to zero', () async {
    final fixture = await _Phase5Fixture.create();
    addTearDown(fixture.dispose);
    await fixture.seed(id: 'movie', kind: SourceMediaKind.movies);
    final oldV11 = sqlite3.open(fixture.path);
    oldV11.execute('DROP TABLE playback_progress');
    oldV11.execute('''CREATE TABLE playback_progress (
         library_item_id TEXT NOT NULL,
         media_key TEXT NOT NULL,
         position_ms INTEGER NOT NULL,
         duration_ms INTEGER NOT NULL,
         completed INTEGER NOT NULL,
         updated_at_us INTEGER NOT NULL,
         PRIMARY KEY (library_item_id, media_key)
       )''');
    oldV11.execute(
      '''INSERT INTO playback_progress
         (library_item_id, media_key, position_ms, duration_ms, completed,
          updated_at_us)
         VALUES (?, ?, ?, ?, ?, ?)''',
      [
        'movie:movies:item',
        'movie',
        180000,
        600000,
        0,
        DateTime.utc(2026, 8, 19, 12).microsecondsSinceEpoch,
      ],
    );
    oldV11.close();

    final repaired = SourceCatalogDatabase(databasePath: fixture.path);
    final progress = await repaired.loadPlaybackProgress(
      libraryItemId: 'movie:movies:item',
      mediaKey: 'movie',
    );
    expect(progress?.positionMs, 180000);
    expect(progress?.watchedMs, 0);
    expect(progress?.isResumeEligible, isFalse);
  });

  test(
    'movie and episode progress survives restart and rejects stale writes',
    () async {
      final fixture = await _Phase5Fixture.create();
      addTearDown(fixture.dispose);
      await fixture.seed(
        id: 'series-source',
        kind: SourceMediaKind.series,
        title: 'Series title',
      );
      const libraryItemId = 'series-source:series:item';
      final noon = DateTime.utc(2026, 8, 19, 12);
      final later = DateTime.utc(2026, 8, 19, 13);

      expect(
        await fixture.database.upsertPlaybackProgress(
          PlaybackProgress(
            libraryItemId: libraryItemId,
            mediaKey: 'episode:one',
            positionMs: 45000,
            durationMs: 300000,
            completed: false,
            updatedAt: noon,
          ),
        ),
        isTrue,
      );
      expect(
        await fixture.database.upsertPlaybackProgress(
          PlaybackProgress(
            libraryItemId: libraryItemId,
            mediaKey: 'episode:two',
            positionMs: 290000,
            durationMs: 300000,
            completed: true,
            updatedAt: later,
          ),
        ),
        isTrue,
      );
      expect(
        await fixture.database.upsertPlaybackProgress(
          PlaybackProgress(
            libraryItemId: libraryItemId,
            mediaKey: 'episode:one',
            positionMs: 120000,
            durationMs: 300000,
            completed: false,
            updatedAt: later,
          ),
        ),
        isTrue,
      );

      // A delayed callback, including one with an identical timestamp, cannot
      // move the exact episode backward.
      for (final staleAt in [noon, later]) {
        expect(
          await fixture.database.upsertPlaybackProgress(
            PlaybackProgress(
              libraryItemId: libraryItemId,
              mediaKey: 'episode:one',
              positionMs: 1000,
              durationMs: 300000,
              completed: false,
              updatedAt: staleAt,
            ),
          ),
          isFalse,
        );
      }

      final restarted = SourceCatalogDatabase(databasePath: fixture.path);
      final episodeOne = await restarted.loadPlaybackProgress(
        libraryItemId: libraryItemId,
        mediaKey: 'episode:one',
      );
      final episodeTwo = await restarted.loadPlaybackProgress(
        libraryItemId: libraryItemId,
        mediaKey: 'episode:two',
      );
      expect(episodeOne?.positionMs, 120000);
      expect(episodeOne?.watchedMs, 0);
      expect(episodeOne?.isResumeEligible, isFalse);
      expect(episodeOne?.completed, isFalse);
      expect(episodeTwo?.positionMs, 290000);
      expect(episodeTwo?.completed, isTrue);
      expect(episodeOne.toString(), isNot(contains(libraryItemId)));
      expect(episodeOne.toString(), isNot(contains('episode:one')));

      expect(
        await restarted.upsertPlaybackProgress(
          PlaybackProgress(
            libraryItemId: 'missing',
            mediaKey: 'movie',
            positionMs: 1,
            durationMs: 2,
            completed: false,
            updatedAt: later,
          ),
        ),
        isFalse,
      );
      expect(
        await restarted.loadPlaybackProgress(
          libraryItemId: libraryItemId,
          mediaKey: 'x' * 513,
        ),
        isNull,
      );
    },
  );

  test('seek position does not satisfy actual watched resume threshold after restart', () async {
    final fixture = await _Phase5Fixture.create();
    addTearDown(fixture.dispose);
    await fixture.seed(id: 'movie', kind: SourceMediaKind.movies);
    const libraryItemId = 'movie:movies:item';
    await fixture.database.upsertPlaybackProgress(
      PlaybackProgress(
        libraryItemId: libraryItemId,
        mediaKey: 'movie',
        positionMs: 180000,
        durationMs: 600000,
        watchedMs: 1000,
        completed: false,
        updatedAt: DateTime.utc(2026, 8, 19, 12),
      ),
    );

    final restarted = SourceCatalogDatabase(databasePath: fixture.path);
    var progress = await restarted.loadPlaybackProgress(
      libraryItemId: libraryItemId,
      mediaKey: 'movie',
    );
    expect(progress?.positionMs, 180000);
    expect(progress?.watchedMs, 1000);
    expect(progress?.isResumeEligible, isFalse);

    await restarted.upsertPlaybackProgress(
      PlaybackProgress(
        libraryItemId: libraryItemId,
        mediaKey: 'movie',
        positionMs: 181000,
        durationMs: 600000,
        watchedMs: 30000,
        completed: false,
        updatedAt: DateTime.utc(2026, 8, 19, 12, 1),
      ),
    );
    progress = await restarted.loadPlaybackProgress(
      libraryItemId: libraryItemId,
      mediaKey: 'movie',
    );
    expect(progress?.isResumeEligible, isTrue);

    expect(
      PlaybackProgress(
        libraryItemId: libraryItemId,
        mediaKey: 'movie',
        positionMs: 550000,
        durationMs: 600000,
        watchedMs: 30000,
        completed: false,
        updatedAt: DateTime.utc(2026, 8, 19, 12, 2),
      ).isResumeEligible,
      isFalse,
      reason: 'less than 60 seconds remaining restarts near the beginning',
    );
  });

  test('Start over clears one exact progress row durably', () async {
    final fixture = await _Phase5Fixture.create();
    addTearDown(fixture.dispose);
    await fixture.seed(id: 'series', kind: SourceMediaKind.series);
    const libraryItemId = 'series:series:item';
    await fixture.database.recordRecentlyWatched(
      libraryItemId,
      playedAt: DateTime.utc(2026, 8, 19, 11),
    );
    for (final mediaKey in ['episode:one', 'episode:two']) {
      await fixture.database.upsertPlaybackProgress(
        PlaybackProgress(
          libraryItemId: libraryItemId,
          mediaKey: mediaKey,
          positionMs: 90000,
          durationMs: 600000,
          watchedMs: 90000,
          completed: false,
          updatedAt: DateTime.utc(2026, 8, 19, 12),
        ),
      );
    }

    expect(
      await fixture.database.clearPlaybackProgress(
        libraryItemId: libraryItemId,
        mediaKey: 'episode:one',
        clearedAt: DateTime.utc(2026, 8, 19, 13),
      ),
      isTrue,
    );
    expect(
      await fixture.database.upsertPlaybackProgress(
        PlaybackProgress(
          libraryItemId: libraryItemId,
          mediaKey: 'episode:one',
          positionMs: 1000,
          durationMs: 600000,
          watchedMs: 1000,
          completed: false,
          updatedAt: DateTime.utc(2026, 8, 19, 12, 30),
        ),
      ),
      isFalse,
      reason: 'a delayed pre-clear callback cannot resurrect resume state',
    );
    final restarted = SourceCatalogDatabase(databasePath: fixture.path);
    expect(
      await restarted.loadPlaybackProgress(
        libraryItemId: libraryItemId,
        mediaKey: 'episode:one',
      ),
      isNull,
    );
    expect(
      await restarted.loadPlaybackProgress(
        libraryItemId: libraryItemId,
        mediaKey: 'episode:two',
      ),
      isNotNull,
    );
    expect(
      (await restarted.loadRecentlyWatched()).single.item.libraryItemId,
      libraryItemId,
    );
    expect(
      await restarted.clearPlaybackProgress(
        libraryItemId: libraryItemId,
        mediaKey: 'episode:one',
      ),
      isTrue,
      reason: 'already clear is the successful desired state',
    );
    expect(
      await restarted.clearPlaybackProgress(
        libraryItemId: libraryItemId,
        mediaKey: 'episode:never-played',
        clearedAt: DateTime.utc(2026, 8, 19, 13),
      ),
      isTrue,
    );
    final raw = sqlite3.open(fixture.path);
    expect(
      raw
          .select(
            '''SELECT cleared FROM playback_progress
               WHERE library_item_id = ? AND media_key = ?''',
            [libraryItemId, 'episode:one'],
          )
          .single['cleared'],
      1,
    );
    raw.close();
  });

  test('progress survives refresh without replacing watch history', () async {
    final fixture = await _Phase5Fixture.create();
    addTearDown(fixture.dispose);
    await fixture.seed(
      id: 'movie-source',
      kind: SourceMediaKind.movies,
      title: 'Before',
    );
    const libraryItemId = 'movie-source:movies:item';
    final playedAt = DateTime.utc(2026, 8, 19, 12);
    await fixture.database.recordRecentlyWatched(
      libraryItemId,
      playedAt: playedAt,
    );
    await fixture.database.upsertPlaybackProgress(
      PlaybackProgress(
        libraryItemId: libraryItemId,
        mediaKey: 'movie',
        positionMs: 90000,
        durationMs: 600000,
        completed: false,
        updatedAt: DateTime.utc(2026, 8, 19, 12, 1),
      ),
    );

    final refresh = await fixture.database.beginRefresh('movie-source');
    expect(refresh, isNotNull);
    await fixture.database.commitRefresh(refresh!, [
      _stage(SourceMediaKind.movies, title: 'After'),
    ]);

    expect(
      (await fixture.database.loadPlaybackProgress(
        libraryItemId: libraryItemId,
        mediaKey: 'movie',
      ))?.positionMs,
      90000,
    );
    final recent = await fixture.database.loadRecentlyWatched();
    expect(recent.single.item.libraryItemId, libraryItemId);
    expect(recent.single.lastPlayedAt, playedAt);
  });

  test(
    'allowance precedence is override then report then conservative one',
    () async {
      final fixture = await _Phase5Fixture.create();
      addTearDown(fixture.dispose);
      await fixture.seed(id: 'source', kind: SourceMediaKind.live);

      var allowance = await fixture.database.loadSourceConnectionAllowance(
        'source',
      );
      expect(allowance?.reportedLimit, isNull);
      expect(allowance?.overrideLimit, isNull);
      expect(allowance?.effectiveLimit, 1);
      expect(allowance?.usesConservativeDefault, isTrue);

      final raw = sqlite3.open(fixture.path);
      raw.execute(
        'UPDATE sources SET reported_connection_limit = 2 WHERE id = ?',
        ['source'],
      );
      raw.close();
      allowance = await fixture.database.loadSourceConnectionAllowance(
        'source',
      );
      expect(allowance?.effectiveLimit, 2);

      allowance = await fixture.database.setSourceConnectionLimitOverride(
        sourceId: 'source',
        overrideLimit: 1,
      );
      expect(allowance?.reportedLimit, 2);
      expect(allowance?.overrideLimit, 1);
      expect(allowance?.effectiveLimit, 1);

      expect(
        await fixture.database.setSourceConnectionLimitOverride(
          sourceId: 'source',
          overrideLimit: 3,
        ),
        isNull,
      );
      expect(
        (await fixture.database.loadSourceConnectionAllowance('source'))
            ?.effectiveLimit,
        1,
      );
      allowance = await fixture.database.setSourceConnectionLimitOverride(
        sourceId: 'source',
        overrideLimit: null,
      );
      expect(allowance?.effectiveLimit, 2);
      expect(
        await fixture.database.loadSourceConnectionAllowance('missing'),
        isNull,
      );

      final guarded = sqlite3.open(fixture.path);
      expect(
        () => guarded.execute(
          'UPDATE sources SET connection_limit_override = 4 WHERE id = ?',
          ['source'],
        ),
        throwsA(isA<SqliteException>()),
      );
      guarded.close();
      expect(allowance.toString(), isNot(contains('source')));
    },
  );

  test(
    'Xtream initial import and successful refresh persist max connections',
    () async {
      var maxConnections = '2';
      var authorized = true;
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        final action = request.uri.queryParameters['action'];
        request.response.write(
          action == null
              ? '{"user_info":{"auth":${authorized ? 1 : 0},'
                    '"max_connections":"$maxConnections"}}'
              : '[]',
        );
        await request.response.close();
      });

      final fixture = await _Phase5Fixture.create();
      addTearDown(fixture.dispose);
      final definition = SourceDefinition(
        id: 'xtream',
        name: 'Xtream',
        serverUrl: 'http://${server.address.address}:${server.port}',
        username: 'user',
        password: 'credential-secret',
        credentialKey: 'key-secret',
      );
      final importing = await fixture.database.beginInitialImport(definition);
      await importing.pending.timeout(const Duration(seconds: 10));
      await importing.activate().timeout(const Duration(seconds: 10));
      expect(
        (await fixture.database.loadSourceConnectionAllowance('xtream'))
            ?.reportedLimit,
        2,
      );
      final importedAllowance = await fixture.database
          .loadSourceConnectionAllowance('xtream');
      expect(
        importedAllowance.toString(),
        isNot(
          anyOf(
            contains(definition.serverUrl),
            contains(definition.password),
            contains(definition.credentialKey),
          ),
        ),
      );

      maxConnections = 'invalid';
      var refreshing = await fixture.database.beginXtreamRefresh(
        sourceId: 'xtream',
        serverUrl: definition.serverUrl,
        username: definition.username,
        password: definition.password,
      );
      await refreshing.completed.timeout(const Duration(seconds: 10));
      expect(
        (await fixture.database.loadSourceConnectionAllowance('xtream'))
            ?.effectiveLimit,
        1,
      );

      maxConnections = '2';
      refreshing = await fixture.database.beginXtreamRefresh(
        sourceId: 'xtream',
        serverUrl: definition.serverUrl,
        username: definition.username,
        password: definition.password,
      );
      await refreshing.completed.timeout(const Duration(seconds: 10));
      expect(
        (await fixture.database.loadSourceConnectionAllowance('xtream'))
            ?.reportedLimit,
        2,
      );

      authorized = false;
      refreshing = await fixture.database.beginXtreamRefresh(
        sourceId: 'xtream',
        serverUrl: definition.serverUrl,
        username: definition.username,
        password: definition.password,
      );
      await expectLater(
        refreshing.completed.timeout(const Duration(seconds: 10)),
        throwsA(isA<SourceImportFailure>()),
      );
      expect(
        (await fixture.database.loadSourceConnectionAllowance('xtream'))
            ?.reportedLimit,
        2,
        reason: 'a failed refresh must retain the last successful report',
      );
    },
  );

  test(
    'variants are bounded exact active members without title matching',
    () async {
      final fixture = await _Phase5Fixture.create();
      addTearDown(fixture.dispose);
      for (final id in ['alpha', 'beta', 'same-title-only']) {
        await fixture.seed(
          id: id,
          kind: SourceMediaKind.movies,
          title: 'Shared title',
          playbackRef: '{"providerId":"$id","token":"secret-$id"}',
        );
      }
      final raw = sqlite3.open(fixture.path);
      raw.execute('DELETE FROM library_members WHERE catalog_item_id = ?', [
        'beta:movies:item',
      ]);
      raw.execute(
        '''INSERT INTO library_members
           (library_item_id, catalog_item_id, preferred)
           VALUES (?, ?, 0)''',
        ['alpha:movies:item', 'beta:movies:item'],
      );
      raw.close();

      var variants = await fixture.database.loadPlayableVariants(
        libraryItemId: 'alpha:movies:item',
        limit: 999,
      );
      expect(variants.map((item) => item.catalogItemId), [
        'alpha:movies:item',
        'beta:movies:item',
      ]);
      expect(
        variants.map((item) => item.catalogItemId),
        isNot(contains('same-title-only:movies:item')),
      );

      await fixture.database.setCatalogItemHidden(
        sourceId: 'beta',
        catalogItemId: 'beta:movies:item',
        hidden: true,
      );
      expect(
        await fixture.database.loadPlayableVariants(
          libraryItemId: 'alpha:movies:item',
        ),
        hasLength(1),
      );
      await fixture.database.setCatalogItemHidden(
        sourceId: 'beta',
        catalogItemId: 'beta:movies:item',
        hidden: false,
      );

      for (var index = 0; index < 10; index++) {
        final id = 'variant-$index';
        await fixture.seed(
          id: id,
          kind: SourceMediaKind.movies,
          title: 'Not title matched $index',
        );
        final member = sqlite3.open(fixture.path);
        member.execute(
          'DELETE FROM library_members WHERE catalog_item_id = ?',
          ['$id:movies:item'],
        );
        member.execute(
          '''INSERT INTO library_members
             (library_item_id, catalog_item_id, preferred)
             VALUES (?, ?, 0)''',
          ['alpha:movies:item', '$id:movies:item'],
        );
        member.close();
      }
      variants = await fixture.database.loadPlayableVariants(
        libraryItemId: 'alpha:movies:item',
        limit: 999,
      );
      expect(variants, hasLength(8));

      await fixture.database.setSourceEnabled('beta', false);
      variants = await fixture.database.loadPlayableVariants(
        libraryItemId: 'alpha:movies:item',
        limit: 2,
      );
      expect(
        variants.map((item) => item.catalogItemId),
        isNot(contains('beta:movies:item')),
      );
    },
  );
}

class _Phase5Fixture {
  _Phase5Fixture(this.directory, this.path)
    : database = SourceCatalogDatabase(databasePath: path);

  final Directory directory;
  final String path;
  final SourceCatalogDatabase database;

  static Future<_Phase5Fixture> create() async {
    final directory = await Directory.systemTemp.createTemp(
      'wabbit-phase5-data-',
    );
    return _Phase5Fixture(
      directory,
      '${directory.path}${Platform.pathSeparator}catalog.sqlite',
    );
  }

  Future<void> seed({
    required String id,
    required SourceMediaKind kind,
    String title = 'Item',
    String playbackRef = '{"providerId":"item"}',
  }) => database.commitInitialSource(
    SourceDefinition(
      id: id,
      name: id,
      serverUrl: 'https://provider.example',
      username: 'user',
      password: 'credential-secret',
      credentialKey: '$id-key',
    ),
    [_stage(kind, title: title, playbackRef: playbackRef)],
  );

  Future<void> dispose() => directory.delete(recursive: true);
}

ImportedStage _stage(
  SourceMediaKind kind, {
  String title = 'Item',
  String playbackRef = '{"providerId":"item"}',
}) => ImportedStage(
  kind: kind,
  categories: const [],
  items: [
    ImportedCatalogItem(
      providerKey: 'item',
      title: title,
      categoryKey: null,
      playbackRef: playbackRef,
    ),
  ],
);
