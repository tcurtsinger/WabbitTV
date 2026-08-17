import 'package:flutter/material.dart' show SelectableText;
import 'package:flutter/widgets.dart' show Size, ValueKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:wabbit_tv/src/spikes/phase0/playback_probe_main.dart';
import 'package:wabbit_tv/src/spikes/phase0/strong_playback_probe.dart';
import 'package:wabbit_tv/src/spikes/phase0/strong_probe_models.dart';

void main() {
  const credentials = StrongProbeCredentials(
    endpoint: 'strong.example:8080',
    username: 'fake-user',
    password: 'super-secret-password',
  );

  test(
    'normalizes a provider endpoint and builds only in-memory test URIs',
    () {
      expect(
        normalizeXtreamEndpoint('strong.example:8080').toString(),
        'https://strong.example:8080/player_api.php',
      );
      final api = buildXtreamApiUri(credentials, action: 'get_live_streams');
      final playback = buildXtreamPlaybackUri(
        credentials,
        const ProbeStreamCandidate(
          kind: ProbeMediaKind.live,
          id: '987',
          title: 'Private provider title',
          extension: 'ts',
        ),
      );
      expect(api.path, '/player_api.php');
      expect(api.queryParameters['action'], 'get_live_streams');
      expect(
        categoryDiscoveryAction(ProbeMediaKind.live),
        'get_live_categories',
      );
      expect(
        categoryDiscoveryAction(ProbeMediaKind.movie),
        'get_vod_categories',
      );
      expect(
        categoryDiscoveryAction(ProbeMediaKind.episode),
        'get_series_categories',
      );
      expect(categoryCandidateAction(ProbeMediaKind.live), 'get_live_streams');
      expect(categoryCandidateAction(ProbeMediaKind.movie), 'get_vod_streams');
      expect(categoryCandidateAction(ProbeMediaKind.episode), 'get_series');
      final categoryApi = buildXtreamApiUri(
        credentials,
        action: categoryCandidateAction(ProbeMediaKind.movie),
        extraQuery: const {'category_id': 'private-category-id'},
      );
      expect(categoryApi.queryParameters['action'], 'get_vod_streams');
      expect(categoryApi.queryParameters['category_id'], 'private-category-id');
      expect(playback.path, '/live/fake-user/super-secret-password/987.ts');
    },
  );

  test('parses numeric and string account limits conservatively', () {
    final numeric = parseAccountFacts({
      'user_info': {
        'auth': 1,
        'status': 'Active',
        'max_connections': 3,
        'active_cons': 1,
      },
    });
    final strings = parseAccountFacts({
      'user_info': {
        'auth': '1',
        'status': 'ACTIVE',
        'max_connections': '2',
        'active_cons': '0',
      },
    });
    final malformed = parseAccountFacts({
      'user_info': {
        'auth': true,
        'status': 'anything',
        'max_connections': 'many',
        'active_cons': -1,
      },
    });

    expect(numeric.authenticated, isTrue);
    expect(numeric.availableConnections, 2);
    expect(numeric.permitsTwoStreams, isTrue);
    expect(strings.availableConnections, 2);
    expect(strings.permitsTwoStreams, isTrue);
    expect(malformed.maxConnections, isNull);
    expect(malformed.activeConnections, isNull);
    expect(malformed.permitsSingleStream, isTrue);
    expect(malformed.permitsTwoStreams, isFalse);
    expect(malformed.status, 'unknown');

    final fullyUsed = parseAccountFacts({
      'user_info': {
        'auth': 1,
        'status': 'Active',
        'max_connections': 1,
        'active_cons': 1,
      },
    });
    expect(fullyUsed.permitsSingleStream, isFalse);
    expect(fullyUsed.permitsTwoStreams, isFalse);
  });

  test('parses capped category lists without exposing category data', () {
    final raw = List<Object?>.generate(
      101,
      (index) => {
        'category_id': 'private-category-$index',
        'category_name': 'Private category $index',
      },
    )..add({'category_id': 'fallback-id', 'name': 'Fallback name'});

    final categories = parseProbeCategories(raw, ProbeMediaKind.movie);

    expect(categories, hasLength(probeCategoryLimit));
    expect(categories.first.id, 'private-category-0');
    expect(categories.last.id, 'private-category-99');
    expect(categories.first.toString(), 'ProbeCategory(redacted)');
    expect(
      parseProbeCategories([
        {'category_id': 'fallback-id', 'name': 'Fallback name'},
      ], ProbeMediaKind.live).single.name,
      'Fallback name',
    );
  });

  test('caps retained discovery candidates and ignores malformed entries', () {
    final raw = List<Object?>.generate(
      50,
      (index) => {
        'stream_id': index,
        'name': 'Provider title $index',
        'container_extension': 'mp4',
      },
    )..add({'stream_id': null, 'name': 'Ignored'});
    final candidates = parseDiscoveryCandidates(raw, ProbeMediaKind.movie);

    expect(candidates, hasLength(40));
    expect(candidates.first.id, '0');
    expect(candidates.last.id, '39');
    expect(candidates.first.toString(), 'ProbeStreamCandidate(redacted)');
  });

  test('series discovery uses series_id and episode parsing stays on id', () {
    final series = parseSeriesCandidates([
      {'series_id': 'series-44', 'name': 'Private series'},
    ]);
    final episodes = parseEpisodeCandidates({
      'episodes': {
        '1': [
          {
            'id': 'episode-7',
            'title': 'Private episode',
            'container_extension': 'mkv',
          },
        ],
      },
    });

    expect(series.single.id, 'series-44');
    expect(episodes.single.id, 'episode-7');
    expect(episodes.single.extension, 'mkv');
  });

  test('uses separate bounded account and discovery request budgets', () {
    expect(accountRequestTimeout, const Duration(seconds: 10));
    expect(accountResponseByteLimit, 1024 * 1024);
    expect(
      ProbeFailure.accountResponseTooLarge.label,
      'Account response exceeded the 1 MiB probe limit',
    );
    expect(discoveryRequestTimeout, const Duration(seconds: 60));
    expect(discoveryResponseByteLimit, 64 * 1024 * 1024);
    expect(
      ProbeFailure.discoveryResponseTooLarge.label,
      'Discovery response exceeded the 64 MiB probe limit',
    );
  });

  test(
    'discovery progress and bounded failures remain safe and actionable',
    () {
      expect(
        discoveryProgressLabel(ProbeMediaKind.live, 1),
        'Loading live candidates (1 of 3)',
      );
      expect(
        discoveryProgressLabel(ProbeMediaKind.movie, 2),
        'Loading movie candidates (2 of 3)',
      );
      expect(
        discoveryProgressLabel(ProbeMediaKind.episode, 3),
        'Loading series candidates (3 of 3)',
      );

      final failure = discoveryFailureLabel(
        ProbeMediaKind.movie,
        ProbeFailure.discoveryResponseTooLarge,
      );
      expect(
        failure,
        'Movie candidates: Discovery response exceeded the 64 MiB probe limit',
      );
      expect(
        categoryDiscoveryProgressLabel(ProbeMediaKind.live, 1),
        'Loading live categories (1 of 3)',
      );
      expect(
        categoryDiscoveryProgressLabel(ProbeMediaKind.movie, 2),
        'Loading movie categories (2 of 3)',
      );
      expect(
        categoryDiscoveryProgressLabel(ProbeMediaKind.episode, 3),
        'Loading series categories (3 of 3)',
      );
      final categoryFailure = categoryCandidateFailureLabel(
        ProbeMediaKind.movie,
        ProbeFailure.discoveryResponseTooLarge,
      );
      expect(
        categoryFailure,
        'Movie category candidates: Discovery response exceeded the 64 MiB probe limit',
      );
      for (final forbidden in [
        'provider.example',
        'private-title',
        'private-id',
        'user-secret',
      ]) {
        expect(failure, isNot(contains(forbidden)));
        expect(categoryFailure, isNot(contains(forbidden)));
      }
    },
  );

  test('bounded body reader rejects an oversized response before decoding all of it', () async {
    final response = Stream<List<int>>.fromIterable([
      [97, 98],
      [99, 100],
    ]);

    await expectLater(
      readBoundedUtf8Body(response, maxBytes: 3),
      throwsA(isA<ProbeResponseTooLarge>()),
    );
  });

  test('sanitized evidence never emits supplied secret, title, URL, or id', () {
    final candidate = const ProbeStreamCandidate(
      kind: ProbeMediaKind.episode,
      id: 'secret-episode-id',
      title: 'Private Provider Episode',
      extension: 'mkv',
    );
    final playback = buildXtreamPlaybackUri(credentials, candidate);
    final evidence = const ProbeEvidence(
      kind: ProbeMediaKind.episode,
      passed: true,
      failure: null,
      startupMs: 456,
      width: 1920,
      height: 1080,
      screenshotPresent: true,
    ).toSanitizedText();

    for (final forbidden in [
      credentials.username,
      credentials.password,
      candidate.title,
      candidate.id,
      playback.toString(),
    ]) {
      expect(evidence, isNot(contains(forbidden)));
    }
    expect(evidence, contains('Episode: PASS'));
  });

  testWidgets('probe starts at the memory-only account state', (tester) async {
    await tester.pumpWidget(const PlaybackProbeApp());

    expect(find.text('Playback probe'), findsOneWidget);
    expect(
      find.text('Temporary local diagnostic. Nothing is saved or logged.'),
      findsOneWidget,
    );
    expect(find.text('Provider endpoint'), findsOneWidget);
    expect(find.text('Check account'), findsOneWidget);
    expect(find.text('Mounted render evidence'), findsOneWidget);
  });

  testWidgets(
    'probe keeps its evidence ledger visible at the Windows reference size',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1265, 713));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(const PlaybackProbeApp());
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      final ledger = tester.getRect(
        find.byKey(const ValueKey('playback-probe-evidence-ledger')),
      );
      expect(ledger.top, greaterThanOrEqualTo(0));
      expect(ledger.bottom, lessThanOrEqualTo(713));
      expect(
        tester.widget<SelectableText>(find.byType(SelectableText)).data,
        contains('Account: not checked'),
      );
    },
  );

  testWidgets('rejected account facts expose a cleared retry path', (
    tester,
  ) async {
    await tester.pumpWidget(
      const PlaybackProbeApp(
        initialAccount: StrongAccountFacts(
          authenticated: false,
          status: 'unknown',
          maxConnections: null,
          activeConnections: null,
        ),
      ),
    );

    expect(find.text('Retry with new credentials'), findsOneWidget);
    expect(find.text('Provider endpoint'), findsNothing);

    await tester.tap(find.text('Retry with new credentials'));
    await tester.pump();

    expect(find.text('Provider endpoint'), findsOneWidget);
    expect(find.text('Check account'), findsOneWidget);
  });
}
