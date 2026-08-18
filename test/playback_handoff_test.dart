import 'package:flutter_test/flutter_test.dart';
import 'package:wabbit_tv/src/features/browse/playback_handoff.dart';
import 'package:wabbit_tv/src/features/sources/source_models.dart';

void main() {
  test('M3U handoffs retain only a safe immutable transport instruction', () {
    final handoff = playbackHandoffFor(
      BrowseCatalogItem(
        id: 'row',
        sourceId: 'm3u-source',
        kind: SourceMediaKind.live,
        title: 'Private M3U title',
        artworkLocator: null,
        playbackRef: '{"url":"https://stream.example/live?token=secret","headers":{"X-Token":"header-secret"}}',
      ),
    );

    expect(handoff, isA<M3uLivePlaybackHandoff>());
    final m3u = handoff as M3uLivePlaybackHandoff;
    expect(m3u.uri.host, 'stream.example');
    expect(m3u.httpHeaders, {'X-Token': 'header-secret'});
    expect(() => m3u.httpHeaders['Other'] = 'nope', throwsUnsupportedError);
    expect(m3u.toString(), isNot(contains('secret')));
    expect(m3u.toString(), isNot(contains('Private M3U title')));
  });

  test('M3U malformed references fail with the redacted catalog failure', () {
    for (final playbackRef in [
      '{"url":"file:///private.m3u"}',
      '{"url":"https://stream.example/live","headers":{"bad name":"x"}}',
      '{"url":"https://stream.example/live","headers":{"X-Token":3}}',
      '{"url":3}',
    ]) {
      expect(
        () => playbackHandoffFor(
          BrowseCatalogItem(
            id: 'row',
            sourceId: 'source',
            kind: SourceMediaKind.live,
            title: 'Title',
            artworkLocator: null,
            playbackRef: playbackRef,
          ),
        ),
        throwsA(
          isA<ContinuationException>().having(
            (error) => error.toString(),
            'string form',
            'ContinuationException(redacted)',
          ),
        ),
      );
    }
  });

  test('library handoffs preserve the chosen result source', () {
    final library = LibraryCatalogItem(
      libraryItemId: 'identity',
      catalogItemId: 'catalog-b',
      sourceId: 'source-b',
      sourceDisplayName: 'Source B',
      kind: SourceMediaKind.movies,
      title: 'Movie',
      artworkLocator: null,
      playbackRef: '{"providerId":"42","kind":"movies","extension":"mkv"}',
    );

    final handoff = playbackHandoffForLibrary(library);
    expect(handoff, isA<MoviePlaybackHandoff>());
    expect(handoff.sourceId, 'source-b');
    expect((handoff as MoviePlaybackHandoff).extension, 'mkv');
  });

  test('series library references preserve the chosen Xtream reference', () {
    final reference = seriesReferenceForLibrary(
      const LibraryCatalogItem(
        libraryItemId: 'identity',
        catalogItemId: 'catalog-b',
        sourceId: 'source-b',
        sourceDisplayName: 'Source B',
        kind: SourceMediaKind.series,
        title: 'Series',
        artworkLocator: null,
        playbackRef: '{"providerId":"series-42","kind":"series"}',
      ),
    );
    expect(reference.providerItemId, 'series-42');
    expect(reference.toString(), 'SeriesReference(redacted)');
  });
}
