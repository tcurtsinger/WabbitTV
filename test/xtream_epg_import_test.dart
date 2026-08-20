import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:wabbit_tv/src/features/sources/credential_store.dart';
import 'package:wabbit_tv/src/features/sources/epg_models.dart';
import 'package:wabbit_tv/src/features/sources/source_catalog_database.dart';
import 'package:wabbit_tv/src/features/sources/source_models.dart';
import 'package:wabbit_tv/src/features/sources/xtream_epg_service.dart';

void main() {
  test(
    'lazy importer requests exact short EPG and persists bounded cache',
    () async {
      final now = DateTime.utc(2026, 8, 19, 12);
      final requests = <Uri>[];
      var active = 0;
      var maximumActive = 0;
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        requests.add(request.uri);
        active++;
        maximumActive = maximumActive < active ? active : maximumActive;
        await Future<void>.delayed(const Duration(milliseconds: 20));
        request.response.write(
          jsonEncode({
            'epg_listings': [
              {
                'title': base64.encode(utf8.encode('Programme')),
                'start_timestamp': now.millisecondsSinceEpoch ~/ 1000,
                'stop_timestamp':
                    now.add(const Duration(hours: 1)).millisecondsSinceEpoch ~/
                    1000,
              },
            ],
          }),
        );
        await request.response.close();
        active--;
      });
      final fixture = await _ImportFixture.create(server, itemCount: 6);
      addTearDown(fixture.dispose);
      final service = XtreamEpgService(
        database: fixture.database,
        credentialStore: fixture.credentials,
        now: () => now,
      );

      final summary = await service.refreshCatalogItems([
        for (var index = 0; index < 6; index++) 'source:live:item-$index',
      ]);
      expect(summary.claimed, 6);
      expect(summary.refreshed, 6);
      expect(summary.failed, 0);
      expect(
        maximumActive,
        lessThanOrEqualTo(xtreamEpgMaximumConcurrentRequests),
      );
      expect(requests, hasLength(6));
      for (final request in requests) {
        expect(request.path, '/player_api.php');
        expect(request.queryParameters['action'], 'get_short_epg');
        expect(
          request.queryParameters['limit'],
          '$xtreamEpgRequestListingLimit',
        );
      }
      expect(
        requests.map((request) => request.queryParameters['stream_id']).toSet(),
        {for (var index = 0; index < 6; index++) 'item-$index'},
      );
      final windows = await fixture.database.loadEpgWindow(
        catalogItemIds: const ['source:live:item-0'],
        windowStartUtc: now,
        windowEndUtc: now.add(const Duration(hours: 2)),
        atUtc: now,
      );
      expect(windows.single.nowNext.current?.title, 'Programme');
      expect(summary.toString(), isNot(contains('fixture-password')));
    },
  );

  test(
    'HTTP 200 empty is channel-local and a disjoint stream still refreshes',
    () async {
      final now = DateTime.utc(2026, 8, 19, 12);
      final requests = <String>[];
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        final streamId = request.uri.queryParameters['stream_id']!;
        requests.add(streamId);
        request.response.write(
          streamId == 'item-0'
              ? jsonEncode({'epg_listings': <Object?>[]})
              : jsonEncode({
                  'epg_listings': [
                    {
                      'title': 'Disjoint programme',
                      'start_timestamp': now.millisecondsSinceEpoch ~/ 1000,
                      'stop_timestamp':
                          now
                              .add(const Duration(hours: 1))
                              .millisecondsSinceEpoch ~/
                          1000,
                    },
                  ],
                }),
        );
        await request.response.close();
      });
      final fixture = await _ImportFixture.create(server, itemCount: 2);
      addTearDown(fixture.dispose);
      final service = XtreamEpgService(
        database: fixture.database,
        credentialStore: fixture.credentials,
        now: () => now,
      );

      final empty = await service.refreshCatalogItems(const [
        'source:live:item-0',
      ]);
      expect(empty.empty, 1);
      expect(empty.failed, 0);
      expect(empty.unsupported, 0);
      final emptyWindow = (await fixture.database.loadEpgWindow(
        catalogItemIds: const ['source:live:item-0'],
        windowStartUtc: now,
        windowEndUtc: now.add(const Duration(hours: 2)),
        atUtc: now,
      )).single;
      expect(emptyWindow.availability, EpgAvailability.empty);

      final refreshed = await service.refreshCatalogItems(const [
        'source:live:item-1',
      ]);
      expect(refreshed.refreshed, 1);
      expect(refreshed.failed, 0);
      final disjointWindow = (await fixture.database.loadEpgWindow(
        catalogItemIds: const ['source:live:item-1'],
        windowStartUtc: now,
        windowEndUtc: now.add(const Duration(hours: 2)),
        atUtc: now,
      )).single;
      expect(disjointWindow.nowNext.current?.title, 'Disjoint programme');
      expect(requests, ['item-0', 'item-1']);
    },
  );

  test('malformed refresh retains last-good programmes and stores only fixed failure', () async {
    final now = DateTime.utc(2026, 8, 19, 12);
    var malformed = false;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      request.response.write(
        malformed
            ? jsonEncode({
                'epg_listings': [
                  {
                    'title': 'fixture-password',
                    'provider_error': 'provider_error',
                    'start': '2026-08-19 13:00:00',
                    'end': '2026-08-19 14:00:00',
                  },
                ],
              })
            : jsonEncode({
                'epg_listings': [
                  {
                    'title': 'Last good',
                    'start_timestamp': now.millisecondsSinceEpoch ~/ 1000,
                    'stop_timestamp':
                        now
                            .add(const Duration(hours: 2))
                            .millisecondsSinceEpoch ~/
                        1000,
                  },
                ],
              }),
      );
      await request.response.close();
    });
    final fixture = await _ImportFixture.create(server);
    addTearDown(fixture.dispose);
    var clock = now;
    final service = XtreamEpgService(
      database: fixture.database,
      credentialStore: fixture.credentials,
      now: () => clock,
    );
    expect(
      (await service.refreshCatalogItems(const ['source:live:item-0']))
          .refreshed,
      1,
    );
    malformed = true;
    clock = now.add(const Duration(minutes: 31));
    final summary = await service.refreshCatalogItems(const [
      'source:live:item-0',
    ]);
    expect(summary.failed, 1);
    final window = (await fixture.database.loadEpgWindow(
      catalogItemIds: const ['source:live:item-0'],
      windowStartUtc: now,
      windowEndUtc: now.add(const Duration(hours: 3)),
      atUtc: now,
    )).single;
    expect(window.nowNext.current?.title, 'Last good');
    expect(window.availability, EpgAvailability.temporarilyUnavailable);

    final db = sqlite3.open(fixture.path);
    addTearDown(db.close);
    expect(
      db
          .select('SELECT last_error FROM epg_channel_state')
          .single['last_error'],
      EpgRefreshFailure.malformedResponse.name,
    );
    final stored = [
      ...db.select('SELECT * FROM epg_source_state'),
      ...db.select('SELECT * FROM epg_channel_state'),
    ].expand((row) => row.values).join(' ');
    expect(stored, isNot(contains('fixture-password')));
    expect(stored, isNot(contains('provider_error')));
  });

  test(
    'unsupported endpoint backs off source and M3U rows never request EPG',
    () async {
      final now = DateTime.utc(2026, 8, 19, 12);
      var requests = 0;
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        requests++;
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
      });
      final fixture = await _ImportFixture.create(server);
      addTearDown(fixture.dispose);
      final service = XtreamEpgService(
        database: fixture.database,
        credentialStore: fixture.credentials,
        now: () => now,
      );
      expect(
        (await service.refreshCatalogItems(const ['source:live:item-0']))
            .unsupported,
        1,
      );
      expect(
        (await service.refreshCatalogItems(const ['source:live:item-0']))
            .claimed,
        0,
      );
      expect(requests, 1);

      final db = sqlite3.open(fixture.path);
      db.execute("UPDATE sources SET kind = 'm3u_url' WHERE id = 'source'");
      db.execute('DELETE FROM epg_source_state');
      db.execute('DELETE FROM epg_channel_state');
      db.close();
      expect(
        (await service.refreshCatalogItems(const ['source:live:item-0']))
            .claimed,
        0,
      );
      expect(requests, 1);
    },
  );

  test('HTTP 405 and 501 are fixed unsupported outcomes', () async {
    for (final status in [
      HttpStatus.methodNotAllowed,
      HttpStatus.notImplemented,
    ]) {
      final now = DateTime.utc(2026, 8, 19, 12);
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final fixture = await _ImportFixture.create(server);
      var requests = 0;
      server.listen((request) async {
        requests++;
        request.response.statusCode = status;
        await request.response.close();
      });
      try {
        final service = XtreamEpgService(
          database: fixture.database,
          credentialStore: fixture.credentials,
          now: () => now,
        );
        final summary = await service.refreshCatalogItems(const [
          'source:live:item-0',
        ]);
        expect(summary.unsupported, 1, reason: 'HTTP $status');
        expect(summary.failed, 0, reason: 'HTTP $status');
        expect(requests, 1, reason: 'HTTP $status');
      } finally {
        await server.close(force: true);
        await fixture.dispose();
      }
    }
  });

  test(
    'authentication failure backs off disjoint channels source-wide',
    () async {
      final now = DateTime.utc(2026, 8, 19, 12);
      var requests = 0;
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        requests++;
        request.response.statusCode = HttpStatus.unauthorized;
        await request.response.close();
      });
      final fixture = await _ImportFixture.create(server, itemCount: 2);
      addTearDown(fixture.dispose);
      final service = XtreamEpgService(
        database: fixture.database,
        credentialStore: fixture.credentials,
        now: () => now,
      );

      expect(
        (await service.refreshCatalogItems(const ['source:live:item-0']))
            .failed,
        1,
      );
      expect(
        (await service.refreshCatalogItems(const ['source:live:item-1']))
            .claimed,
        0,
      );
      expect(requests, 1);
      final disjointWindow = (await fixture.database.loadEpgWindow(
        catalogItemIds: const ['source:live:item-1'],
        windowStartUtc: now,
        windowEndUtc: now.add(const Duration(hours: 2)),
        atUtc: now,
      )).single;
      expect(
        disjointWindow.availability,
        EpgAvailability.temporarilyUnavailable,
      );

      final db = sqlite3.open(fixture.path);
      addTearDown(db.close);
      final state = db
          .select('SELECT retry_after_utc_ms, last_error FROM epg_source_state')
          .single;
      expect(state['retry_after_utc_ms'] as int, greaterThan(0));
      expect(state['last_error'], EpgRefreshFailure.authentication.name);
    },
  );

  test(
    'explicit manual retry bypasses persisted authentication backoff',
    () async {
      final now = DateTime.utc(2026, 8, 19, 12);
      var reject = true;
      var requests = 0;
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        requests++;
        if (reject) {
          request.response.statusCode = HttpStatus.unauthorized;
        } else {
          request.response.write(jsonEncode({'epg_listings': <Object?>[]}));
        }
        await request.response.close();
      });
      final fixture = await _ImportFixture.create(server);
      addTearDown(fixture.dispose);
      final service = XtreamEpgService(
        database: fixture.database,
        credentialStore: fixture.credentials,
        now: () => now,
      );

      final failed = await service.refreshCatalogItems(const [
        'source:live:item-0',
      ]);
      expect(failed.failed, 1);
      reject = false;
      expect(
        (await service.refreshCatalogItems(const ['source:live:item-0']))
            .claimed,
        0,
      );
      expect(requests, 1);

      final retried = await service.refreshCatalogItems(const [
        'source:live:item-0',
      ], manualRetry: true);
      expect(retried.claimed, 1);
      expect(retried.empty, 1);
      expect(retried.failed, 0);
      expect(requests, 2);
    },
  );

  test(
    'authentication retry supersedes an earlier unsupported capability',
    () async {
      final initial = DateTime.utc(2026, 8, 19, 12);
      var clock = initial;
      var status = HttpStatus.notFound;
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        request.response.statusCode = status;
        await request.response.close();
      });
      final fixture = await _ImportFixture.create(server);
      addTearDown(fixture.dispose);
      final service = XtreamEpgService(
        database: fixture.database,
        credentialStore: fixture.credentials,
        now: () => clock,
      );
      expect(
        (await service.refreshCatalogItems(const ['source:live:item-0']))
            .unsupported,
        1,
      );

      clock = initial.add(xtreamEpgUnsupportedRetry);
      status = HttpStatus.unauthorized;
      expect(
        (await service.refreshCatalogItems(const ['source:live:item-0']))
            .failed,
        1,
      );
      final window = (await fixture.database.loadEpgWindow(
        catalogItemIds: const ['source:live:item-0'],
        windowStartUtc: clock,
        windowEndUtc: clock.add(const Duration(hours: 2)),
        atUtc: clock,
      )).single;
      expect(window.availability, EpgAvailability.temporarilyUnavailable);

      final db = sqlite3.open(fixture.path);
      addTearDown(db.close);
      expect(
        db
            .select('SELECT capability FROM epg_source_state')
            .single['capability'],
        'unknown',
      );
    },
  );

  test(
    'cancellation during credential load wins over source backoff',
    () async {
      final now = DateTime.utc(2026, 8, 19, 12);
      var requests = 0;
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        requests++;
        request.response.write(jsonEncode({'epg_listings': <Object?>[]}));
        await request.response.close();
      });
      final fixture = await _ImportFixture.create(server);
      addTearDown(fixture.dispose);
      final credentials = _GatedNullCredentials();
      final service = XtreamEpgService(
        database: fixture.database,
        credentialStore: credentials,
        now: () => now,
      );

      final refreshing = service.refreshCatalogItems(const [
        'source:live:item-0',
      ]);
      await credentials.readStarted.future.timeout(const Duration(seconds: 3));
      final cancelling = service.cancelActiveRefresh();
      credentials.releaseRead.complete();

      await cancelling.timeout(const Duration(seconds: 3));
      final summary = await refreshing;
      expect(summary.failed, 1);
      expect(requests, 0);
      final db = sqlite3.open(fixture.path);
      final channel = db.select('''SELECT last_error, retry_after_utc_ms
         FROM epg_channel_state''').single;
      final source = db.select('''SELECT last_error, retry_after_utc_ms
         FROM epg_source_state''').single;
      db.close();
      expect(channel['last_error'], EpgRefreshFailure.cancelled.name);
      expect(channel['retry_after_utc_ms'], now.millisecondsSinceEpoch);
      expect(source['last_error'], isNull);
      expect(source['retry_after_utc_ms'], 0);
    },
  );

  test(
    'client factory cancellation records cancelled instead of unreachable',
    () async {
      final now = DateTime.utc(2026, 8, 19, 12);
      var requests = 0;
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        requests++;
        request.response.write(jsonEncode({'epg_listings': <Object?>[]}));
        await request.response.close();
      });
      final fixture = await _ImportFixture.create(server);
      addTearDown(fixture.dispose);
      late XtreamEpgService cancellingService;
      cancellingService = XtreamEpgService(
        database: fixture.database,
        credentialStore: fixture.credentials,
        now: () => now,
        clientFactory: () {
          unawaited(cancellingService.cancelActiveRefresh());
          throw StateError('fixture client factory cancellation');
        },
      );

      final cancelled = await cancellingService.refreshCatalogItems(const [
        'source:live:item-0',
      ]);
      expect(cancelled.failed, 1);
      final db = sqlite3.open(fixture.path);
      final channel = db.select('''SELECT last_error, retry_after_utc_ms
         FROM epg_channel_state''').single;
      final source = db.select('''SELECT last_error, retry_after_utc_ms
         FROM epg_source_state''').single;
      db.close();
      expect(channel['last_error'], EpgRefreshFailure.cancelled.name);
      expect(channel['retry_after_utc_ms'], now.millisecondsSinceEpoch);
      expect(source['last_error'], isNull);
      expect(source['retry_after_utc_ms'], 0);

      final retryService = XtreamEpgService(
        database: fixture.database,
        credentialStore: fixture.credentials,
        now: () => now,
      );
      final retried = await retryService.refreshCatalogItems(const [
        'source:live:item-0',
      ]);
      expect(retried.empty, 1);
      expect(requests, 1);
    },
  );

  test(
    'response body bound fails safely without persisting provider payload',
    () async {
      final now = DateTime.utc(2026, 8, 19, 12);
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        request.response.write('x' * (xtreamEpgResponseByteLimit + 1));
        await request.response.close();
      });
      final fixture = await _ImportFixture.create(server);
      addTearDown(fixture.dispose);
      final service = XtreamEpgService(
        database: fixture.database,
        credentialStore: fixture.credentials,
        now: () => now,
      );
      final summary = await service.refreshCatalogItems(const [
        'source:live:item-0',
      ]);
      expect(summary.failed, 1);
      final db = sqlite3.open(fixture.path);
      addTearDown(db.close);
      expect(db.select('SELECT * FROM epg_programs'), isEmpty);
      expect(
        db
            .select('SELECT last_error FROM epg_channel_state')
            .single['last_error'],
        EpgRefreshFailure.responseTooLarge.name,
      );
    },
  );

  test(
    'claim failure is truthful and the next retry is not throttled',
    () async {
      final now = DateTime.utc(2026, 8, 19, 12);
      var requests = 0;
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        requests++;
        request.response.write(jsonEncode({'epg_listings': <Object?>[]}));
        await request.response.close();
      });
      final fixture = await _ImportFixture.create(server);
      addTearDown(fixture.dispose);
      final database = _ClaimFailureDatabase(fixture.path);
      final service = XtreamEpgService(
        database: database,
        credentialStore: fixture.credentials,
        now: () => now,
      );

      final failed = await service.refreshCatalogItems(const [
        'source:live:item-0',
      ]);
      expect(failed.claimed, 0);
      expect(failed.failed, 1);
      expect(failed.failure, EpgRefreshFailure.localPersistence);
      expect(failed.toString(), isNot(contains(fixture.path)));
      expect(failed.toString(), isNot(contains('fixture-password')));
      expect(requests, 0);

      final retried = await service.refreshCatalogItems(const [
        'source:live:item-0',
      ]);
      expect(retried.empty, 1);
      expect(retried.failed, 0);
      expect(retried.failure, isNull);
      expect(requests, 1);
    },
  );

  test(
    'commit and failure-record exceptions remain local persistence failure',
    () async {
      final now = DateTime.utc(2026, 8, 19, 12);
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        request.response.write(jsonEncode({'epg_listings': <Object?>[]}));
        await request.response.close();
      });
      final fixture = await _ImportFixture.create(server);
      addTearDown(fixture.dispose);
      final database = _CommitAndFailureDatabase(fixture.path);
      final service = XtreamEpgService(
        database: database,
        credentialStore: fixture.credentials,
        now: () => now,
      );

      final summary = await service.refreshCatalogItems(const [
        'source:live:item-0',
      ]);
      expect(summary.claimed, 1);
      expect(summary.failed, 1);
      expect(summary.empty, 0);
      expect(summary.failure, EpgRefreshFailure.localPersistence);
      expect(summary.toString(), isNot(contains(fixture.path)));
      expect(summary.toString(), isNot(contains('fixture-password')));
      expect(database.commitCalls, 1);
      expect(database.failureCalls, 1);

      final raw = sqlite3.open(fixture.path);
      final state = raw.select('''SELECT refresh_state, retry_after_utc_ms
           FROM epg_channel_state
           WHERE catalog_item_id = 'source:live:item-0' ''').single;
      raw.close();
      expect(state['refresh_state'], 'refreshing');
      expect(
        state['retry_after_utc_ms'] as int,
        greaterThan(now.millisecondsSinceEpoch),
        reason:
            'the summary must not pretend the failed lease write released it',
      );
      expect(
        (await service.refreshCatalogItems(const [
          'source:live:item-0',
        ], manualRetry: true)).claimed,
        0,
        reason: 'manual retry must not steal the still-active lease',
      );
    },
  );

  test(
    'failure-record exception overrides provider failure classification',
    () async {
      final now = DateTime.utc(2026, 8, 19, 12);
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        request.response.statusCode = HttpStatus.unauthorized;
        await request.response.close();
      });
      final fixture = await _ImportFixture.create(server);
      addTearDown(fixture.dispose);
      final database = _FailureRecordDatabase(fixture.path);
      final service = XtreamEpgService(
        database: database,
        credentialStore: fixture.credentials,
        now: () => now,
      );

      final summary = await service.refreshCatalogItems(const [
        'source:live:item-0',
      ]);
      expect(summary.claimed, 1);
      expect(summary.failed, 1);
      expect(summary.unsupported, 0);
      expect(summary.failure, EpgRefreshFailure.localPersistence);
      expect(database.failureCalls, 1);
    },
  );

  test(
    'commit exception remains local persistence after fallback write',
    () async {
      final now = DateTime.utc(2026, 8, 19, 12);
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        request.response.write(jsonEncode({'epg_listings': <Object?>[]}));
        await request.response.close();
      });
      final fixture = await _ImportFixture.create(server);
      addTearDown(fixture.dispose);
      final database = _CommitFailureDatabase(fixture.path);
      final service = XtreamEpgService(
        database: database,
        credentialStore: fixture.credentials,
        now: () => now,
      );

      final summary = await service.refreshCatalogItems(const [
        'source:live:item-0',
      ]);
      expect(summary.claimed, 1);
      expect(summary.failed, 1);
      expect(summary.failure, EpgRefreshFailure.localPersistence);
      final raw = sqlite3.open(fixture.path);
      final state = raw.select('''SELECT refresh_state, last_error
         FROM epg_channel_state
         WHERE catalog_item_id = 'source:live:item-0' ''').single;
      raw.close();
      expect(state['refresh_state'], 'error');
      expect(state['last_error'], EpgRefreshFailure.localPersistence.name);
    },
  );

  test('duplicate mounted requests coalesce behind one shared batch', () async {
    final now = DateTime.utc(2026, 8, 19, 12);
    final requested = Completer<void>();
    final release = Completer<void>();
    var requests = 0;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      requests++;
      if (!requested.isCompleted) requested.complete();
      await release.future;
      request.response.write(
        jsonEncode({
          'epg_listings': [
            {
              'title': 'Programme',
              'start_timestamp': now.millisecondsSinceEpoch ~/ 1000,
              'stop_timestamp':
                  now.add(const Duration(hours: 1)).millisecondsSinceEpoch ~/
                  1000,
            },
          ],
        }),
      );
      await request.response.close();
    });
    final fixture = await _ImportFixture.create(server);
    addTearDown(fixture.dispose);
    final service = XtreamEpgService(
      database: fixture.database,
      credentialStore: fixture.credentials,
      now: () => now,
    );

    final first = service.refreshCatalogItems(const ['source:live:item-0']);
    await requested.future.timeout(const Duration(seconds: 3));
    final duplicate = service.refreshCatalogItems(const ['source:live:item-0']);
    release.complete();

    expect((await first).refreshed, 1);
    expect((await duplicate).refreshed, 1);
    expect(requests, 1);
  });

  test('latest viewport supersedes obsolete queued channels after one in-flight wave', () async {
    final now = DateTime.utc(2026, 8, 19, 12);
    final firstWaveStarted = Completer<void>();
    final releaseFirstWave = Completer<void>();
    final requests = <String>[];
    const latestId = 'item-21';
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      final id = request.uri.queryParameters['stream_id']!;
      requests.add(id);
      if (id != latestId) {
        if (requests.length == xtreamEpgMaximumConcurrentRequests &&
            !firstWaveStarted.isCompleted) {
          firstWaveStarted.complete();
        }
        await releaseFirstWave.future;
      }
      request.response.write(jsonEncode({'epg_listings': <Object?>[]}));
      await request.response.close();
    });
    final fixture = await _ImportFixture.create(server, itemCount: 22);
    addTearDown(fixture.dispose);
    final service = XtreamEpgService(
      database: fixture.database,
      credentialStore: fixture.credentials,
      now: () => now,
    );
    final first = service.refreshCatalogItems([
      for (var index = 0; index < 20; index++) 'source:live:item-$index',
    ]);
    await firstWaveStarted.future.timeout(const Duration(seconds: 3));
    final obsolete = service.refreshCatalogItems(const ['source:live:item-20']);
    final latest = service.refreshCatalogItems(const ['source:live:item-21']);
    releaseFirstWave.complete();

    await Future.wait([first, obsolete, latest]);
    expect(requests, hasLength(xtreamEpgMaximumConcurrentRequests + 1));
    expect(
      requests.take(xtreamEpgMaximumConcurrentRequests).every((id) {
        final index = int.parse(id.substring('item-'.length));
        return index < 20;
      }),
      isTrue,
    );
    expect(requests.last, latestId);
    expect(requests, isNot(contains('item-20')));
  });

  test('empty viewport release drops off-screen queued channels', () async {
    final now = DateTime.utc(2026, 8, 19, 12);
    final firstWaveStarted = Completer<void>();
    final releaseFirstWave = Completer<void>();
    var requests = 0;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      requests++;
      if (requests == xtreamEpgMaximumConcurrentRequests &&
          !firstWaveStarted.isCompleted) {
        firstWaveStarted.complete();
      }
      await releaseFirstWave.future;
      request.response.write(jsonEncode({'epg_listings': <Object?>[]}));
      await request.response.close();
    });
    final fixture = await _ImportFixture.create(server, itemCount: 20);
    addTearDown(fixture.dispose);
    final service = XtreamEpgService(
      database: fixture.database,
      credentialStore: fixture.credentials,
      now: () => now,
    );
    final refreshing = service.refreshCatalogItems([
      for (var index = 0; index < 20; index++) 'source:live:item-$index',
    ]);
    await firstWaveStarted.future.timeout(const Duration(seconds: 3));
    final released = service.refreshCatalogItems(const []);
    releaseFirstWave.complete();

    await Future.wait([refreshing, released]);
    expect(requests, xtreamEpgMaximumConcurrentRequests);
  });

  test('a viewport queued during cache pruning is not stranded', () async {
    final now = DateTime.utc(2026, 8, 19, 12);
    final requests = <String>[];
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      requests.add(request.uri.queryParameters['stream_id']!);
      request.response.write(jsonEncode({'epg_listings': <Object?>[]}));
      await request.response.close();
    });
    final fixture = await _ImportFixture.create(server, itemCount: 2);
    addTearDown(fixture.dispose);
    final gatedDatabase = _PruneGateDatabase(fixture.path);
    final service = XtreamEpgService(
      database: gatedDatabase,
      credentialStore: fixture.credentials,
      now: () => now,
    );

    final first = service.refreshCatalogItems(const ['source:live:item-0']);
    await gatedDatabase.pruneStarted.future.timeout(const Duration(seconds: 3));
    final duringPrune = service.refreshCatalogItems(const [
      'source:live:item-1',
    ]);
    gatedDatabase.releasePrune.complete();

    expect((await first).empty, 2);
    expect((await duringPrune).empty, 2);
    expect(requests, ['item-0', 'item-1']);
  });

  test('category release cancels claimed rows and lets a new category start promptly', () async {
    final now = DateTime.utc(2026, 8, 19, 12);
    final oldWaveStarted = Completer<void>();
    final releaseOldResponses = Completer<void>();
    final newCategoryStarted = Completer<void>();
    final requests = <String>[];
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      final id = request.uri.queryParameters['stream_id']!;
      requests.add(id);
      if (id == 'item-4') {
        if (!newCategoryStarted.isCompleted) newCategoryStarted.complete();
      } else {
        if (requests.where((value) => value != 'item-4').length ==
                xtreamEpgMaximumConcurrentRequests &&
            !oldWaveStarted.isCompleted) {
          oldWaveStarted.complete();
        }
        await releaseOldResponses.future;
      }
      try {
        request.response.write(jsonEncode({'epg_listings': <Object?>[]}));
        await request.response.close();
      } catch (_) {
        // The obsolete response belongs to a force-closed client.
      }
    });
    final fixture = await _ImportFixture.create(server, itemCount: 5);
    addTearDown(fixture.dispose);
    final service = XtreamEpgService(
      database: fixture.database,
      credentialStore: fixture.credentials,
      now: () => now,
    );

    final obsolete = service.refreshCatalogItems(const [
      'source:live:item-0',
      'source:live:item-1',
      'source:live:item-2',
      'source:live:item-3',
    ]);
    await oldWaveStarted.future.timeout(const Duration(seconds: 3));
    await service.cancelActiveRefresh();
    final current = service.refreshCatalogItems(const ['source:live:item-4']);
    await newCategoryStarted.future.timeout(const Duration(seconds: 1));
    expect((await current).empty, 1);
    final cancelled = await obsolete.timeout(const Duration(seconds: 3));
    expect(cancelled.claimed, xtreamEpgMaximumConcurrentRequests);
    expect(cancelled.failed, xtreamEpgMaximumConcurrentRequests);

    final db = sqlite3.open(fixture.path);
    final states = db.select(
      '''SELECT catalog_item_id, refresh_state, last_error,
                  retry_after_utc_ms
           FROM epg_channel_state
           WHERE catalog_item_id != 'source:live:item-4'
           ORDER BY catalog_item_id''',
    );
    db.close();
    expect(states, hasLength(xtreamEpgMaximumConcurrentRequests));
    expect(states.map((row) => row['refresh_state']), everyElement('error'));
    expect(
      states.map((row) => row['last_error']),
      everyElement(EpgRefreshFailure.cancelled.name),
    );
    expect(
      states.map((row) => row['retry_after_utc_ms'] as int),
      everyElement(now.millisecondsSinceEpoch),
    );

    releaseOldResponses.complete();
    final retried = await service.refreshCatalogItems(const [
      'source:live:item-0',
    ]);
    expect(retried.empty, 1);
    expect(requests.where((id) => id == 'item-0'), hasLength(2));
  });

  test(
    'same channel cannot re-claim until cancelled lease cleanup completes',
    () async {
      final now = DateTime.utc(2026, 8, 19, 12);
      final firstStarted = Completer<void>();
      final releaseFirstResponse = Completer<void>();
      final replacementStarted = Completer<void>();
      var requests = 0;
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() async {
        if (!releaseFirstResponse.isCompleted) releaseFirstResponse.complete();
        await server.close(force: true);
      });
      server.listen((request) async {
        requests++;
        final attempt = requests;
        if (attempt == 1) {
          firstStarted.complete();
          await releaseFirstResponse.future;
        } else if (!replacementStarted.isCompleted) {
          replacementStarted.complete();
        }
        try {
          request.response.write(jsonEncode({'epg_listings': <Object?>[]}));
          await request.response.close();
        } catch (_) {
          // The obsolete first response belongs to a force-closed client.
        }
      });
      final fixture = await _ImportFixture.create(server);
      addTearDown(fixture.dispose);
      final service = XtreamEpgService(
        database: fixture.database,
        credentialStore: fixture.credentials,
        now: () => now,
      );

      final obsolete = service.refreshCatalogItems(const [
        'source:live:item-0',
      ]);
      await firstStarted.future.timeout(const Duration(seconds: 3));
      final cancelling = service.cancelActiveRefresh();
      final replacement = service.refreshCatalogItems(const [
        'source:live:item-0',
      ]);

      await cancelling.timeout(const Duration(seconds: 3));
      await replacementStarted.future.timeout(const Duration(seconds: 1));
      expect((await obsolete).failed, 1);
      expect((await replacement).empty, 1);
      expect(requests, 2);
      final window = (await fixture.database.loadEpgWindow(
        catalogItemIds: const ['source:live:item-0'],
        windowStartUtc: now,
        windowEndUtc: now.add(const Duration(hours: 1)),
        atUtc: now,
      )).single;
      expect(window.availability, EpgAvailability.empty);
      releaseFirstResponse.complete();
    },
  );

  test(
    'cancellation closes a stalled request and leaves no busy lease',
    () async {
      final now = DateTime.utc(2026, 8, 19, 12);
      final requested = Completer<void>();
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        if (!requested.isCompleted) requested.complete();
        request.response.write('{');
        await request.response.flush();
      });
      final fixture = await _ImportFixture.create(server, itemCount: 6);
      addTearDown(fixture.dispose);
      final service = XtreamEpgService(
        database: fixture.database,
        credentialStore: fixture.credentials,
        now: () => now,
      );
      final refreshing = service.refreshCatalogItems([
        for (var index = 0; index < 6; index++) 'source:live:item-$index',
      ]);
      await requested.future.timeout(const Duration(seconds: 3));
      service.cancel();
      await refreshing.timeout(const Duration(seconds: 3));

      final db = sqlite3.open(fixture.path);
      addTearDown(db.close);
      final states = db.select(
        'SELECT refresh_state, last_error FROM epg_channel_state',
      );
      expect(states, hasLength(xtreamEpgMaximumConcurrentRequests));
      expect(states.map((row) => row['refresh_state']), everyElement('error'));
      expect(
        states.map((row) => row['last_error']),
        everyElement(EpgRefreshFailure.cancelled.name),
      );
    },
  );
}

class _ImportFixture {
  _ImportFixture({
    required this.directory,
    required this.path,
    required this.database,
    required this.credentials,
  });

  final Directory directory;
  final String path;
  final SourceCatalogDatabase database;
  final _Credentials credentials;

  static Future<_ImportFixture> create(
    HttpServer server, {
    int itemCount = 1,
  }) async {
    final directory = await Directory.systemTemp.createTemp(
      'wabbit-epg-import-',
    );
    final path = '${directory.path}${Platform.pathSeparator}catalog.sqlite';
    final database = SourceCatalogDatabase(databasePath: path);
    final endpoint = 'http://${server.address.address}:${server.port}';
    await database.commitInitialSource(
      SourceDefinition(
        id: 'source',
        name: 'Source',
        serverUrl: endpoint,
        username: 'fixture-user',
        password: 'fixture-password',
        credentialKey: 'source-key',
      ),
      [
        ImportedStage(
          kind: SourceMediaKind.live,
          categories: const [],
          items: [
            for (var index = 0; index < itemCount; index++)
              ImportedCatalogItem(
                providerKey: 'item-$index',
                title: 'Channel $index',
                categoryKey: null,
                playbackRef: 'safe-ref-$index',
              ),
          ],
        ),
      ],
    );
    return _ImportFixture(
      directory: directory,
      path: path,
      database: database,
      credentials: _Credentials(endpoint),
    );
  }

  Future<void> dispose() => directory.delete(recursive: true);
}

class _Credentials implements CredentialStore {
  const _Credentials(this.endpoint);

  final String endpoint;

  @override
  Future<void> delete(String key) async {}

  @override
  Future<StoredCredential?> read(String key) async => StoredCredential(
    username: 'fixture-user',
    password: 'fixture-password',
    serverUrl: endpoint,
  );

  @override
  Future<void> write({
    required String key,
    required String username,
    required String password,
    String? serverUrl,
  }) async {}
}

class _GatedNullCredentials implements CredentialStore {
  final readStarted = Completer<void>();
  final releaseRead = Completer<void>();

  @override
  Future<void> delete(String key) async {}

  @override
  Future<StoredCredential?> read(String key) async {
    readStarted.complete();
    await releaseRead.future;
    return null;
  }

  @override
  Future<void> write({
    required String key,
    required String username,
    required String password,
    String? serverUrl,
  }) async {}
}

class _PruneGateDatabase extends SourceCatalogDatabase {
  _PruneGateDatabase(String path) : super(databasePath: path);

  final pruneStarted = Completer<void>();
  final releasePrune = Completer<void>();
  var _gated = false;

  @override
  Future<int> pruneExpiredEpg(DateTime beforeUtc) async {
    if (!_gated) {
      _gated = true;
      pruneStarted.complete();
      await releasePrune.future;
    }
    return super.pruneExpiredEpg(beforeUtc);
  }
}

class _ClaimFailureDatabase extends SourceCatalogDatabase {
  _ClaimFailureDatabase(String path) : super(databasePath: path);

  var _failed = false;

  @override
  Future<List<EpgRefreshTarget>> claimEpgRefreshTargets({
    required List<String> catalogItemIds,
    required DateTime nowUtc,
    int limit = 32,
    bool manualRetry = false,
  }) {
    if (!_failed) {
      _failed = true;
      throw StateError('fixture claim failure');
    }
    return super.claimEpgRefreshTargets(
      catalogItemIds: catalogItemIds,
      nowUtc: nowUtc,
      limit: limit,
      manualRetry: manualRetry,
    );
  }
}

class _CommitAndFailureDatabase extends SourceCatalogDatabase {
  _CommitAndFailureDatabase(String path) : super(databasePath: path);

  int commitCalls = 0;
  int failureCalls = 0;

  @override
  Future<bool> commitEpgRefreshTarget({
    required EpgRefreshTarget target,
    required List<EpgProgram> programs,
    required DateTime completedAtUtc,
  }) {
    commitCalls++;
    throw StateError('fixture commit failure');
  }

  @override
  Future<bool> failEpgRefreshTarget({
    required EpgRefreshTarget target,
    required EpgRefreshFailure failure,
    required DateTime failedAtUtc,
    required DateTime retryAfterUtc,
  }) {
    failureCalls++;
    throw StateError('fixture failure-state failure');
  }
}

class _CommitFailureDatabase extends SourceCatalogDatabase {
  _CommitFailureDatabase(String path) : super(databasePath: path);

  @override
  Future<bool> commitEpgRefreshTarget({
    required EpgRefreshTarget target,
    required List<EpgProgram> programs,
    required DateTime completedAtUtc,
  }) {
    throw StateError('fixture commit failure');
  }
}

class _FailureRecordDatabase extends SourceCatalogDatabase {
  _FailureRecordDatabase(String path) : super(databasePath: path);

  int failureCalls = 0;

  @override
  Future<bool> failEpgRefreshTarget({
    required EpgRefreshTarget target,
    required EpgRefreshFailure failure,
    required DateTime failedAtUtc,
    required DateTime retryAfterUtc,
  }) {
    failureCalls++;
    throw StateError('fixture failure-state failure');
  }
}
