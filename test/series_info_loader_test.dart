import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:wabbit_tv/src/features/browse/playback_handoff.dart';
import 'package:wabbit_tv/src/features/browse/series_info_loader.dart';
import 'package:wabbit_tv/src/features/sources/credential_store.dart';
import 'package:wabbit_tv/src/features/sources/source_catalog_database.dart';
import 'package:wabbit_tv/src/features/sources/source_models.dart';

void main() {
  test('series info is lazy, bounded, parsed, and credential-local', () async {
    var requests = 0;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);
    unawaited(
      server.forEach((request) async {
        requests++;
        expect(request.uri.path, '/player_api.php');
        expect(request.uri.queryParameters['action'], 'get_series_info');
        expect(request.uri.queryParameters['series_id'], 'series-private');
        request.response
          ..headers.contentType = ContentType.json
          ..write(
            jsonEncode({
              'episodes': {
                '2': [
                  {'id': 'ep-2', 'title': 'Episode two'},
                ],
                '1': [
                  {
                    'id': 1,
                    'name': 'Episode one',
                    'container_extension': 'mkv',
                  },
                ],
              },
            }),
          );
        await request.response.close();
      }),
    );
    final credentials = _Credentials(
      StoredCredential(
        username: 'user-secret',
        password: 'password-secret',
        serverUrl: 'http://${server.address.address}:${server.port}',
      ),
    );
    final result = await XtreamSeriesInfoLoader(credentialStore: credentials)
        .load(source: _source, series: _seriesItem);
    expect(requests, 1);
    expect(credentials.reads, 1);
    expect(result.seasons.map((season) => season.name), ['1', '2']);
    expect(result.seasons.first.episodes.single.extension, 'mkv');
    expect(
      result.seasons.first.episodes.single.toString(),
      'SeriesEpisode(redacted)',
    );
  });

  test(
    'large generated series parsing keeps the main isolate responsive',
    () async {
      final episodes = List<Object?>.generate(
        16000,
        (index) => {
          'id': index,
          'title': 'Generated episode $index ${'x' * 100}',
          'container_extension': 'mp4',
        },
        growable: false,
      );
      final bytes = Uint8List.fromList(
        utf8.encode(
          jsonEncode({
            'episodes': {'1': episodes},
          }),
        ),
      );
      expect(bytes.length, greaterThan(1024 * 1024));
      expect(bytes.length, lessThan(seriesInfoResponseByteLimit));

      var mainIsolateTicks = 0;
      final heartbeat = Timer.periodic(
        const Duration(milliseconds: 1),
        (_) => mainIsolateTicks++,
      );
      try {
        final info = await parseSeriesInfoBytesInWorker(bytes);
        expect(info.seasons.single.episodes, hasLength(16000));
        expect(mainIsolateTicks, greaterThan(0));
      } finally {
        heartbeat.cancel();
      }
    },
  );
  test('handoffs are typed and redacted', () {
    final live = BrowseCatalogItem(
      id: 'live-row',
      sourceId: _source.id,
      kind: SourceMediaKind.live,
      title: 'Private title',
      artworkLocator: null,
      playbackRef: playbackReference({
        'providerId': 'private-id',
        'kind': 'live',
      }),
    );
    final movie = BrowseCatalogItem(
      id: 'movie-row',
      sourceId: _source.id,
      kind: SourceMediaKind.movies,
      title: 'Private movie',
      artworkLocator: null,
      playbackRef: playbackReference({
        'providerId': 'private-movie-id',
        'kind': 'movies',
      }),
    );
    final liveHandoff = playbackHandoffFor(live);
    final movieHandoff = playbackHandoffFor(movie);
    expect(liveHandoff, isA<LivePlaybackHandoff>());
    expect(liveHandoff.extension, 'ts');
    expect(movieHandoff, isA<MoviePlaybackHandoff>());
    expect(movieHandoff.extension, 'mp4');
    for (final forbidden in ['private-id', 'Private title', 'user-secret']) {
      expect(liveHandoff.toString(), isNot(contains(forbidden)));
      expect(movieHandoff.toString(), isNot(contains(forbidden)));
    }
  });
}

const _source = PersistedSource(
  id: 'fixture-source',
  name: 'Fixture',
  credentialKey: 'fixture-key',
  counts: {},
);
final _seriesItem = BrowseCatalogItem(
  id: 'series-row',
  sourceId: _source.id,
  kind: SourceMediaKind.series,
  title: 'Private series',
  artworkLocator: null,
  playbackRef: playbackReference({
    'providerId': 'series-private',
    'kind': 'series',
  }),
);

class _Credentials implements CredentialStore {
  _Credentials(this.value);
  final StoredCredential value;
  int reads = 0;
  @override
  Future<void> delete(String key) async {}
  @override
  Future<StoredCredential?> read(String key) async {
    reads++;
    return value;
  }

  @override
  Future<void> write({
    required String key,
    required String username,
    required String password,
    String? serverUrl,
  }) async {}
}
