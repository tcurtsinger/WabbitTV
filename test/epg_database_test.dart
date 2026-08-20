import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:wabbit_tv/src/features/sources/epg_models.dart';
import 'package:wabbit_tv/src/features/sources/source_catalog_database.dart';
import 'package:wabbit_tv/src/features/sources/source_models.dart';

void main() {
  test('schema v12 installs bounded EPG tables and expiry index', () async {
    final fixture = await _EpgFixture.create();
    addTearDown(fixture.dispose);
    await fixture.seed('source');

    final db = sqlite3.open(fixture.path);
    addTearDown(db.close);
    expect(db.select('SELECT version FROM schema_migrations'), hasLength(12));
    final tables = db
        .select("SELECT name FROM sqlite_master WHERE type = 'table'")
        .map((row) => row['name']);
    expect(
      tables,
      containsAll(['epg_source_state', 'epg_channel_state', 'epg_programs']),
    );
    expect(
      db.select('PRAGMA index_list(epg_programs)').map((row) => row['name']),
      contains('epg_programs_expiry'),
    );
    final columns = [
      ...db.select('PRAGMA table_info(epg_source_state)'),
      ...db.select('PRAGMA table_info(epg_channel_state)'),
      ...db.select('PRAGMA table_info(epg_programs)'),
    ].map((row) => row['name']).join(' ');
    expect(columns, isNot(contains('password')));
    expect(columns, isNot(contains('username')));
    expect(columns, isNot(contains('url')));
    expect(columns, isNot(contains('playback_ref')));
  });

  test('two concurrent v11 opens install v12 exactly once', () async {
    final fixture = await _EpgFixture.create();
    addTearDown(fixture.dispose);
    await fixture.seed('legacy');
    final legacy = sqlite3.open(fixture.path);
    legacy.execute('DROP INDEX epg_programs_expiry');
    legacy.execute('DROP TABLE epg_programs');
    legacy.execute('DROP TABLE epg_channel_state');
    legacy.execute('DROP TABLE epg_source_state');
    legacy.execute('DELETE FROM schema_migrations WHERE version = 12');
    legacy.close();

    final blocker = sqlite3.open(fixture.path);
    blocker.execute('PRAGMA busy_timeout = 8000');
    blocker.execute('BEGIN IMMEDIATE');
    final opens = [
      SourceCatalogDatabase(databasePath: fixture.path).loadSourceRoster(),
      SourceCatalogDatabase(databasePath: fixture.path).loadSourceRoster(),
    ];
    await Future<void>.delayed(const Duration(milliseconds: 250));
    blocker.execute('COMMIT');
    blocker.close();
    final results = await Future.wait(opens)
        .timeout(const Duration(seconds: 10));
    expect(results.every((rows) => rows.length == 1), isTrue);

    final db = sqlite3.open(fixture.path);
    addTearDown(db.close);
    expect(
      db.select('SELECT 1 FROM schema_migrations WHERE version = 12'),
      hasLength(1),
    );
    expect(
      db.select("SELECT 1 FROM sqlite_master WHERE name = 'epg_programs'"),
      hasLength(1),
    );
  });

  test(
    'exact claims, UTC window, deterministic Now/Next, and last-good failure',
    () async {
      final fixture = await _EpgFixture.create();
      addTearDown(fixture.dispose);
      await fixture.seed('one');
      await fixture.seed('two');
      final now = DateTime.utc(2026, 8, 19, 12);

      final claims = await fixture.database.claimEpgRefreshTargets(
        catalogItemIds: ['one:live:item', 'two:live:item'],
        nowUtc: now,
      );
      expect(claims, hasLength(2));
      expect(
        claims.map((target) => target.providerStreamId),
        everyElement('item'),
      );
      expect(claims.first.toString(), isNot(contains('item')));
      final one = claims.singleWhere((target) => target.sourceId == 'one');
      expect(
        await fixture.database.commitEpgRefreshTarget(
          target: one,
          completedAtUtc: now,
          programs: [
            EpgProgram(
              catalogItemId: one.catalogItemId,
              startUtc: now.subtract(const Duration(minutes: 30)),
              endUtc: now.add(const Duration(minutes: 30)),
              title: 'Current',
            ),
            EpgProgram(
              catalogItemId: one.catalogItemId,
              startUtc: now.add(const Duration(minutes: 30)),
              endUtc: now.add(const Duration(minutes: 90)),
              title: 'Next',
              description: 'Description',
            ),
          ],
        ),
        isTrue,
      );

      var windows = await fixture.database.loadEpgWindow(
        catalogItemIds: ['two:live:item', 'one:live:item'],
        windowStartUtc: now.subtract(const Duration(hours: 1)),
        windowEndUtc: now.add(const Duration(hours: 2)),
        atUtc: now,
      );
      expect(windows.map((window) => window.catalogItemId), [
        'two:live:item',
        'one:live:item',
      ]);
      final oneWindow = windows.last;
      expect(oneWindow.availability, EpgAvailability.available);
      expect(oneWindow.nowNext.current?.title, 'Current');
      expect(oneWindow.nowNext.next?.title, 'Next');
      expect(windows.first.programs, isEmpty);

      expect(
        await fixture.database.claimEpgRefreshTargets(
          catalogItemIds: ['one:live:item'],
          nowUtc: now.add(const Duration(minutes: 1)),
        ),
        isEmpty,
      );
      final retry = (await fixture.database.claimEpgRefreshTargets(
        catalogItemIds: ['one:live:item'],
        nowUtc: now.add(const Duration(minutes: 31)),
      )).single;
      expect(
        await fixture.database.commitEpgRefreshTarget(
          target: one,
          programs: const [],
          completedAtUtc: now.add(const Duration(minutes: 31)),
        ),
        isFalse,
        reason: 'the older generation must not replace a newer claim',
      );
      expect(
        await fixture.database.failEpgRefreshTarget(
          target: retry,
          failure: EpgRefreshFailure.timedOut,
          failedAtUtc: now.add(const Duration(minutes: 31)),
          retryAfterUtc: now.add(const Duration(minutes: 36)),
        ),
        isTrue,
      );
      windows = await fixture.database.loadEpgWindow(
        catalogItemIds: ['one:live:item'],
        windowStartUtc: now.subtract(const Duration(hours: 1)),
        windowEndUtc: now.add(const Duration(hours: 2)),
        atUtc: now,
      );
      expect(
        windows.single.availability,
        EpgAvailability.temporarilyUnavailable,
      );
      expect(windows.single.nowNext.current?.title, 'Current');

      final emptyRefresh = (await fixture.database.claimEpgRefreshTargets(
        catalogItemIds: ['one:live:item'],
        nowUtc: now.add(const Duration(minutes: 37)),
      )).single;
      expect(
        await fixture.database.commitEpgRefreshTarget(
          target: emptyRefresh,
          programs: const [],
          completedAtUtc: now.add(const Duration(minutes: 37)),
        ),
        isTrue,
      );
      windows = await fixture.database.loadEpgWindow(
        catalogItemIds: ['one:live:item'],
        windowStartUtc: now.subtract(const Duration(hours: 1)),
        windowEndUtc: now.add(const Duration(hours: 2)),
        atUtc: now,
      );
      expect(windows.single.availability, EpgAvailability.empty);
      expect(windows.single.programs, isEmpty);
    },
  );

  test(
    'visibility, source kind, refresh invalidation, and removal remain exact',
    () async {
      final fixture = await _EpgFixture.create();
      addTearDown(fixture.dispose);
      await fixture.seed('visible', category: true);
      await fixture.seed('hidden', category: true);
      await fixture.seed('m3u');
      var raw = sqlite3.open(fixture.path);
      raw.execute(
        "UPDATE source_groups SET hidden = 1 WHERE source_id = 'hidden'",
      );
      raw.execute("UPDATE sources SET kind = 'm3u_url' WHERE id = 'm3u'");
      raw.close();
      final now = DateTime.utc(2026, 8, 19, 12);

      var claims = await fixture.database.claimEpgRefreshTargets(
        catalogItemIds: [
          'visible:live:item',
          'hidden:live:item',
          'm3u:live:item',
        ],
        nowUtc: now,
      );
      expect(claims.map((target) => target.catalogItemId), [
        'visible:live:item',
      ]);
      final target = claims.single;
      await fixture.database.commitEpgRefreshTarget(
        target: target,
        completedAtUtc: now,
        programs: [
          EpgProgram(
            catalogItemId: target.catalogItemId,
            startUtc: now,
            endUtc: now.add(const Duration(hours: 1)),
            title: 'Programme',
          ),
        ],
      );
      expect(
        await fixture.database.claimEpgRefreshTargets(
          catalogItemIds: ['visible:live:item'],
          nowUtc: now.add(const Duration(minutes: 1)),
        ),
        isEmpty,
      );

      final refresh = await fixture.database.beginRefresh('visible');
      expect(refresh, isNotNull);
      await fixture.database.commitRefresh(refresh!, [
        _EpgFixture.stage(category: true),
      ]);
      claims = await fixture.database.claimEpgRefreshTargets(
        catalogItemIds: ['visible:live:item'],
        nowUtc: now.add(const Duration(minutes: 1)),
      );
      expect(claims, hasLength(1));
      expect(
        (await fixture.database.loadEpgWindow(
          catalogItemIds: ['visible:live:item'],
          windowStartUtc: now,
          windowEndUtc: now.add(const Duration(hours: 2)),
          atUtc: now,
        )).single.programs,
        hasLength(1),
        reason:
            'catalog refresh invalidates TTL without deleting last good EPG',
      );

      await fixture.database.removeSource('visible');
      raw = sqlite3.open(fixture.path);
      expect(raw.select('SELECT * FROM epg_programs'), isEmpty);
      expect(raw.select('SELECT * FROM epg_channel_state'), isEmpty);
      expect(
        raw.select(
          "SELECT * FROM epg_source_state WHERE source_id = 'visible'",
        ),
        isEmpty,
      );
      raw.close();
    },
  );

  test(
    'database commit rejects implausibly long programme intervals',
    () async {
      final fixture = await _EpgFixture.create();
      addTearDown(fixture.dispose);
      await fixture.seed('duration');
      final now = DateTime.utc(2026, 8, 19, 12);
      final target = (await fixture.database.claimEpgRefreshTargets(
        catalogItemIds: const ['duration:live:item'],
        nowUtc: now,
      )).single;

      expect(
        await fixture.database.commitEpgRefreshTarget(
          target: target,
          completedAtUtc: now,
          programs: [
            EpgProgram(
              catalogItemId: target.catalogItemId,
              startUtc: now,
              endUtc: now
                  .add(epgMaximumProgramDuration)
                  .add(const Duration(milliseconds: 1)),
              title: 'Too long',
            ),
          ],
        ),
        isFalse,
      );
      expect(
        await fixture.database.commitEpgRefreshTarget(
          target: target,
          completedAtUtc: now,
          programs: [
            EpgProgram(
              catalogItemId: target.catalogItemId,
              startUtc: now,
              endUtc: now.add(epgMaximumProgramDuration),
              title: 'Plausible all-day block',
            ),
          ],
        ),
        isTrue,
      );
    },
  );

  test(
    'manual retry bypasses persisted error once but not an active lease',
    () async {
      final fixture = await _EpgFixture.create();
      addTearDown(fixture.dispose);
      await fixture.seed('retry');
      final now = DateTime.utc(2026, 8, 19, 12);
      final failedTarget = (await fixture.database.claimEpgRefreshTargets(
        catalogItemIds: const ['retry:live:item'],
        nowUtc: now,
      )).single;
      expect(
        await fixture.database.failEpgRefreshTarget(
          target: failedTarget,
          failure: EpgRefreshFailure.authentication,
          failedAtUtc: now,
          retryAfterUtc: now.add(const Duration(minutes: 5)),
        ),
        isTrue,
      );

      final beforeRetry = now.add(const Duration(minutes: 1));
      expect(
        await fixture.database.claimEpgRefreshTargets(
          catalogItemIds: const ['retry:live:item'],
          nowUtc: beforeRetry,
        ),
        isEmpty,
      );
      final manual = await fixture.database.claimEpgRefreshTargets(
        catalogItemIds: const ['retry:live:item'],
        nowUtc: beforeRetry,
        manualRetry: true,
      );
      expect(manual, hasLength(1));
      expect(
        await fixture.database.claimEpgRefreshTargets(
          catalogItemIds: const ['retry:live:item'],
          nowUtc: beforeRetry,
          manualRetry: true,
        ),
        isEmpty,
        reason: 'manual retry must not steal a live refreshing lease',
      );
      expect(
        await fixture.database.commitEpgRefreshTarget(
          target: manual.single,
          programs: const [],
          completedAtUtc: beforeRetry,
        ),
        isTrue,
      );
      expect(
        await fixture.database.claimEpgRefreshTargets(
          catalogItemIds: const ['retry:live:item'],
          nowUtc: beforeRetry,
          manualRetry: true,
        ),
        isEmpty,
        reason: 'manual retry must not bypass a successful empty-cache TTL',
      );
    },
  );
}

class _EpgFixture {
  _EpgFixture(this.directory)
    : path = '${directory.path}${Platform.pathSeparator}catalog.sqlite',
      database = SourceCatalogDatabase(
        databasePath:
            '${directory.path}${Platform.pathSeparator}catalog.sqlite',
      );

  final Directory directory;
  final String path;
  final SourceCatalogDatabase database;

  static Future<_EpgFixture> create() async =>
      _EpgFixture(await Directory.systemTemp.createTemp('wabbit-epg-db-'));

  static ImportedStage stage({bool category = false}) => ImportedStage(
    kind: SourceMediaKind.live,
    categories: category
        ? const [ImportedCategory(providerKey: 'group', name: 'Group')]
        : const [],
    items: [
      ImportedCatalogItem(
        providerKey: 'item',
        title: 'Channel',
        categoryKey: category ? 'group' : null,
        playbackRef: 'safe-ref',
      ),
    ],
  );

  Future<void> seed(String id, {bool category = false}) =>
      database.commitInitialSource(
        SourceDefinition(
          id: id,
          name: id,
          serverUrl: 'https://provider.invalid',
          username: 'fixture-user',
          password: 'fixture-password',
          credentialKey: '$id-key',
        ),
        [stage(category: category)],
      );

  Future<void> dispose() => directory.delete(recursive: true);
}
