import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wabbit_tv/src/features/browse/basic_browse_screen.dart';
import 'package:wabbit_tv/src/features/browse/playback_handoff.dart';
import 'package:wabbit_tv/src/features/browse/series_info_loader.dart';
import 'package:wabbit_tv/src/features/sources/source_catalog_database.dart';
import 'package:wabbit_tv/src/features/sources/source_models.dart';

void main() {
  testWidgets(
    'live, movie, series, retry, and Back use the continuation seam',
    (tester) async {
      final loader = _FakeSeriesLoader();
      final handoffs = <PlaybackHandoff>[];
      await tester.pumpWidget(
        _screen(
          kind: SourceMediaKind.live,
          loader: loader,
          onHandoff: handoffs.add,
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('browse-item-live-row')));
      expect(handoffs.single, isA<LivePlaybackHandoff>());
      expect(loader.calls, 0);

      await tester.pumpWidget(
        _screen(
          kind: SourceMediaKind.movies,
          loader: loader,
          onHandoff: handoffs.add,
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('browse-item-movies-row')));
      await tester.pump();
      expect(find.byKey(const ValueKey('movie-play')), findsOneWidget);
      expect(
        tester.getSize(
          find.byKey(const ValueKey('movie-continuation-artwork')),
        ),
        const Size(120, 84),
      );
      expect(loader.calls, 0);
      await tester.tap(find.byKey(const ValueKey('movie-play')));
      expect(handoffs.last, isA<MoviePlaybackHandoff>());

      loader.failure = const ContinuationException(
        ContinuationFailure.timedOut,
      );
      await tester.pumpWidget(
        _screen(
          kind: SourceMediaKind.series,
          loader: loader,
          onHandoff: handoffs.add,
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('browse-item-series-row')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('series-retry')), findsOneWidget);
      expect(
        tester.getSize(
          find.byKey(const ValueKey('series-continuation-artwork')),
        ),
        const Size(120, 84),
      );
      final callsBeforeRetry = loader.calls;
      loader.failure = null;
      await tester.tap(find.byKey(const ValueKey('series-retry')));
      await tester.pumpAndSettle();
      expect(loader.calls, callsBeforeRetry + 1);
      expect(find.byKey(const ValueKey('series-episode-0')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('series-episode-0')));
      expect(handoffs.last, isA<EpisodePlaybackHandoff>());

      await tester.tap(find.byKey(const ValueKey('continuation-visible-back')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('browse-item-series-row')),
        findsOneWidget,
      );
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'continuation initial',
      );
    },
  );

  testWidgets('continuations start on actionable keyboard targets', (
    tester,
  ) async {
    final loader = _FakeSeriesLoader();
    final handoffs = <PlaybackHandoff>[];
    await tester.pumpWidget(
      _screen(
        kind: SourceMediaKind.movies,
        loader: loader,
        onHandoff: handoffs.add,
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('browse-item-movies-row')));
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    expect(handoffs.single, isA<MoviePlaybackHandoff>());

    loader.failure = const ContinuationException(ContinuationFailure.timedOut);
    await tester.pumpWidget(
      _screen(
        kind: SourceMediaKind.series,
        loader: loader,
        onHandoff: handoffs.add,
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('browse-item-series-row')));
    await tester.pumpAndSettle();
    final beforeRetry = loader.calls;
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(loader.calls, beforeRetry + 1);

    loader.failure = null;
    await tester.tap(find.byKey(const ValueKey('series-retry')));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    expect(handoffs.last, isA<EpisodePlaybackHandoff>());
  });

  testWidgets('movie Play stays compact at the reference viewport', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1265, 713));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      _screen(kind: SourceMediaKind.movies, loader: _FakeSeriesLoader()),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('browse-item-movies-row')));
    await tester.pumpAndSettle();
    final play = tester.getRect(find.byKey(const ValueKey('movie-play')));
    expect(play.height, 42);
    expect(play.width, lessThan(200));
    expect(play.bottom, lessThanOrEqualTo(713));
    expect(
      find.byKey(const ValueKey('continuation-visible-back')),
      findsOneWidget,
    );
  });

  testWidgets(
    'long season strips keep remote-focused seasons visible before entering episodes',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(700, 713));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        _screen(kind: SourceMediaKind.series, loader: _ManySeasonLoader()),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('browse-item-series-row')));
      await tester.pumpAndSettle();

      for (var index = 0; index < 10; index++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
        await tester.pump();
      }
      await tester.pumpAndSettle();

      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'series season 10',
      );
      final season = tester.getRect(
        find.byKey(const ValueKey('series-season-11')),
      );
      expect(season.left, greaterThanOrEqualTo(0));
      expect(season.right, lessThanOrEqualTo(700));

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'series episode 0',
      );
    },
  );

  testWidgets('episode focus scrolls across virtual-list cache boundaries', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(700, 600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      _screen(kind: SourceMediaKind.series, loader: _ManyEpisodeLoader()),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('browse-item-series-row')));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();

    for (var index = 0; index < 12; index++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      await tester.pump();
    }

    expect(FocusManager.instance.primaryFocus?.debugLabel, 'series episode 12');
    final episode = tester.getRect(
      find.byKey(const ValueKey('series-episode-12')),
    );
    expect(episode.top, greaterThanOrEqualTo(0));
    expect(episode.bottom, lessThanOrEqualTo(600));
  });

  testWidgets(
    'same browse state cancels a loading series when destination changes',
    (tester) async {
      final loader = _CompletingSeriesLoader();
      const key = ValueKey('shared browse');
      await tester.pumpWidget(
        _screen(kind: SourceMediaKind.series, loader: loader, key: key),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('browse-item-series-row')));
      await tester.pump();
      expect(loader.calls, 1);
      final cancelsBeforeSwitch = loader.cancels;
      await tester.pumpWidget(
        _screen(kind: SourceMediaKind.movies, loader: loader, key: key),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('browse-item-movies-row')),
        findsOneWidget,
      );
      expect(loader.cancels, cancelsBeforeSwitch + 1);
      loader.complete();
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('series-episodes')), findsNothing);
    },
  );

  testWidgets(
    'Back restores a deep virtual series row after its continuation',
    (tester) async {
      final session = BasicBrowseSession();
      final focus = FocusNode(debugLabel: 'deep continuation initial');
      addTearDown(focus.dispose);
      await tester.pumpWidget(
        _screen(
          kind: SourceMediaKind.series,
          loader: _FakeSeriesLoader(),
          data: _DeepSeriesData(),
          session: session,
          initialFocus: focus,
        ),
      );
      await tester.pumpAndSettle();
      final late = find.byKey(const ValueKey('browse-item-series-149'));
      await tester.scrollUntilVisible(
        late,
        420,
        scrollable: find.descendant(
          of: find.byKey(const ValueKey('browse-items-series')),
          matching: find.byType(Scrollable),
        ),
      );
      await tester.tap(late);
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      await tester.pump();
      await tester.pumpAndSettle();
      expect(late, findsOneWidget);
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'browse series series-149',
      );
    },
  );

  testWidgets('late series result is ignored after Back', (tester) async {
    final loader = _CompletingSeriesLoader();
    await tester.pumpWidget(
      _screen(kind: SourceMediaKind.series, loader: loader),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('browse-item-series-row')));
    await tester.pump();
    expect(loader.calls, 1);
    await tester.tap(find.byKey(const ValueKey('continuation-visible-back')));
    await tester.pumpAndSettle();
    loader.complete();
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('browse-item-series-row')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('series-episodes')), findsNothing);
  });
}

Widget _screen({
  required SourceMediaKind kind,
  required SeriesInfoLoader loader,
  ValueChanged<PlaybackHandoff>? onHandoff,
  Key? key,
  BasicBrowseData? data,
  BasicBrowseSession? session,
  FocusNode? initialFocus,
}) => MaterialApp(
  home: Scaffold(
    body: BasicBrowseScreen(
      key: key ?? ValueKey(kind),
      kind: kind,
      source: _source,
      data: data ?? _OneItemData(kind),
      seriesInfoLoader: loader,
      session: session ?? BasicBrowseSession(),
      initialFocus:
          initialFocus ?? FocusNode(debugLabel: 'continuation initial'),
      onContentFocus: (_) {},
      onOpenRail: () {},
      onPlaybackHandoff: onHandoff,
    ),
  ),
);

const _source = PersistedSource(
  id: 'fixture-source',
  name: 'Fixture',
  credentialKey: 'fixture-key',
  counts: {
    SourceMediaKind.live: 1,
    SourceMediaKind.movies: 1,
    SourceMediaKind.series: 1,
  },
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

class _OneItemData implements BasicBrowseData {
  const _OneItemData(this.kind);
  final SourceMediaKind kind;
  BrowseCatalogItem _itemFor(SourceMediaKind requestedKind) =>
      requestedKind == SourceMediaKind.series
      ? _seriesItem
      : BrowseCatalogItem(
          id: '${requestedKind.name}-row',
          sourceId: _source.id,
          kind: requestedKind,
          title: 'Private ${requestedKind.label}',
          artworkLocator: null,
          playbackRef: playbackReference({
            'providerId': '${requestedKind.name}-private',
            'kind': requestedKind.name,
          }),
        );
  @override
  Future<List<BrowseCategorySummary>> browseCategories({
    required String sourceId,
    required SourceMediaKind kind,
  }) async => [
    BrowseCategorySummary(
      selection: const BrowseCategorySelection.all(),
      name: 'All ${kind.label}',
      itemCount: 1,
    ),
  ];
  @override
  Future<BrowsePage> browsePage({
    required String sourceId,
    required SourceMediaKind kind,
    required BrowseCategorySelection selection,
    BrowseCursor? cursor,
    int limit = 100,
  }) async => BrowsePage(
    items: cursor == null ? [_itemFor(kind)] : const [],
    nextCursor: null,
  );
}

class _DeepSeriesData implements BasicBrowseData {
  final _items = [
    for (var index = 0; index < 150; index++)
      BrowseCatalogItem(
        id: 'series-$index',
        sourceId: _source.id,
        kind: SourceMediaKind.series,
        title: 'Series $index',
        artworkLocator: null,
        playbackRef: playbackReference({
          'providerId': '$index',
          'kind': 'series',
        }),
      ),
  ];

  @override
  Future<List<BrowseCategorySummary>> browseCategories({
    required String sourceId,
    required SourceMediaKind kind,
  }) async => [
    const BrowseCategorySummary(
      selection: BrowseCategorySelection.all(),
      name: 'All Series',
      itemCount: 150,
    ),
  ];

  @override
  Future<BrowsePage> browsePage({
    required String sourceId,
    required SourceMediaKind kind,
    required BrowseCategorySelection selection,
    BrowseCursor? cursor,
    int limit = 100,
  }) async {
    final start = cursor == null ? 0 : int.parse(cursor.id.split('-').last) + 1;
    final end = (start + limit).clamp(0, _items.length);
    return BrowsePage(
      items: _items.sublist(start, end),
      nextCursor: end == _items.length
          ? null
          : BrowseCursor(normalizedTitle: 'series', id: _items[end - 1].id),
    );
  }
}

class _FakeSeriesLoader implements SeriesInfoLoader {
  int calls = 0;
  ContinuationException? failure;
  @override
  void cancel() {}

  @override
  Future<SeriesInfo> load({
    required PersistedSource source,
    required BrowseCatalogItem series,
  }) async {
    calls++;
    if (failure != null) throw failure!;
    return const SeriesInfo(
      seasons: [
        SeriesSeason(
          name: '1',
          episodes: [
            SeriesEpisode(
              providerItemId: 'episode-private',
              title: 'Episode one',
              extension: 'mp4',
            ),
          ],
        ),
      ],
    );
  }
}

class _CompletingSeriesLoader implements SeriesInfoLoader {
  final _completer = Completer<SeriesInfo>();
  int calls = 0;
  int cancels = 0;
  @override
  void cancel() {
    cancels++;
  }

  @override
  Future<SeriesInfo> load({
    required PersistedSource source,
    required BrowseCatalogItem series,
  }) {
    calls++;
    return _completer.future;
  }

  void complete() => _completer.complete(const SeriesInfo(seasons: []));
}

class _ManySeasonLoader implements SeriesInfoLoader {
  @override
  void cancel() {}

  @override
  Future<SeriesInfo> load({
    required PersistedSource source,
    required BrowseCatalogItem series,
  }) async => SeriesInfo(
    seasons: [
      for (var index = 1; index <= 12; index++)
        SeriesSeason(
          name: '$index',
          episodes: [
            SeriesEpisode(
              providerItemId: 'episode-$index',
              title: 'Season $index episode',
              extension: 'mp4',
            ),
          ],
        ),
    ],
  );
}

class _ManyEpisodeLoader implements SeriesInfoLoader {
  @override
  void cancel() {}

  @override
  Future<SeriesInfo> load({
    required PersistedSource source,
    required BrowseCatalogItem series,
  }) async => SeriesInfo(
    seasons: [
      SeriesSeason(
        name: '1',
        episodes: [
          for (var index = 0; index < 20; index++)
            SeriesEpisode(
              providerItemId: 'episode-$index',
              title: 'Episode $index',
              extension: 'mp4',
            ),
        ],
      ),
    ],
  );
}
