import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wabbit_tv/src/features/browse/playback_handoff.dart';
import 'package:wabbit_tv/src/features/browse/series_info_loader.dart';
import 'package:wabbit_tv/src/features/home/home_screen.dart';
import 'package:wabbit_tv/src/features/sources/source_catalog_database.dart';
import 'package:wabbit_tv/src/features/sources/source_models.dart';
import 'package:wabbit_tv/src/home_fixture_mode.dart';

void main() {
  test('Home controller suppresses a stale local completion', () async {
    final firstSources = Completer<bool>();
    var checks = 0;
    final data = _HomeData(
      sourceCheck: () {
        checks += 1;
        return checks == 1 ? firstSources.future : Future.value(true);
      },
      loadHistory: (_) async => [_recent(0)],
    );
    final controller = HomeController(data: data);
    addTearDown(controller.dispose);

    final stale = controller.refresh();
    final latest = controller.refresh();
    await latest;
    firstSources.complete(false);
    await stale;

    expect(controller.phase, HomeLoadPhase.ready);
    expect(controller.recentlyWatched.single.item.libraryItemId, 'library-0');
  });

  test(
    'Home refresh preserves its last usable history on local failure',
    () async {
      var reads = 0;
      final controller = HomeController(
        data: _HomeData(
          sourceCheck: () async => true,
          loadHistory: (_) async {
            reads++;
            if (reads > 1) throw StateError('transient local read');
            return [_recent(0)];
          },
        ),
      );
      addTearDown(controller.dispose);

      await controller.initialize();
      await controller.refresh();

      expect(controller.phase, HomeLoadPhase.ready);
      expect(controller.recentlyWatched.single.item.libraryItemId, 'library-0');
      expect(controller.showingSavedHistory, isTrue);
    },
  );

  testWidgets('runtime Home shows genuine loading then no-source state', (
    tester,
  ) async {
    final sources = Completer<bool>();
    final data = _HomeData(sourceCheck: () => sources.future);
    final controller = HomeController(data: data);
    final focus = FocusNode();
    addTearDown(focus.dispose);
    addTearDown(controller.dispose);

    await tester.pumpWidget(_host(controller: controller, focus: focus));
    expect(find.text('Loading Home'), findsOneWidget);

    sources.complete(false);
    await tester.pump();
    await tester.pump();
    expect(find.text('Add your first source'), findsOneWidget);
    expect(find.text('Add source'), findsOneWidget);
  });

  testWidgets('runtime Home preserves the verified no-history direct entries', (
    tester,
  ) async {
    final controller = HomeController(
      data: _HomeData(sourceCheck: () async => true),
    );
    final focus = FocusNode();
    addTearDown(focus.dispose);
    addTearDown(controller.dispose);

    await tester.pumpWidget(_host(controller: controller, focus: focus));
    await tester.pump();
    await tester.pump();
    expect(find.text('Start with what you want to watch'), findsOneWidget);
    expect(find.text('Live'), findsOneWidget);
    expect(find.text('Movies'), findsOneWidget);
    expect(find.text('Series'), findsOneWidget);
  });

  testWidgets('local-read failure retries into a lazy Recently Watched shelf', (
    tester,
  ) async {
    var historyReads = 0;
    final recent = List.generate(40, _recent);
    final data = _HomeData(
      sourceCheck: () async => true,
      loadHistory: (_) async {
        historyReads += 1;
        if (historyReads == 1) throw StateError('fixture local read failure');
        return recent;
      },
    );
    final controller = HomeController(data: data, historyLimit: 48);
    final focus = FocusNode();
    final session = HomeSession();
    final artworkFocus = <String, bool>{};
    LibraryCatalogItem? activated;
    PlaybackHandoff? handoff;
    var railOpens = 0;
    addTearDown(focus.dispose);
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      _host(
        controller: controller,
        focus: focus,
        session: session,
        onOpenRail: () => railOpens += 1,
        onActivate: (item) => activated = item,
        onPlaybackHandoff: (value) => handoff = value,
        artworkBuilder: (context, entry, focused) {
          artworkFocus[entry.item.libraryItemId] = focused;
          return const ColoredBox(color: Colors.black);
        },
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(find.text('Home could not be loaded'), findsOneWidget);

    await tester.tap(find.text('Retry'));
    await tester.pump();
    await tester.pump();
    expect(find.text('Recently Watched'), findsOneWidget);
    expect(find.text('Item 0'), findsWidgets);
    expect(find.text('Item 39'), findsNothing);
    expect(artworkFocus['library-0'], isTrue);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(session.focusedLibraryItemId, 'library-1');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(activated?.libraryItemId, 'library-1');
    expect(handoff, isNull);
    expect(find.byKey(const ValueKey('movie-play')), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    expect(handoff, isA<MoviePlaybackHandoff>());
    expect(handoff?.libraryItemId, 'library-1');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(session.focusedLibraryItemId, 'library-1');
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'home recent item 1',
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    expect(railOpens, 1);
  });

  testWidgets('Recently Watched Live starts direct library playback', (
    tester,
  ) async {
    final item = _recent(0, kind: SourceMediaKind.live);
    final controller = HomeController(
      data: _HomeData(
        sourceCheck: () async => true,
        loadHistory: (_) async => [item],
      ),
    );
    final focus = FocusNode();
    PlaybackHandoff? handoff;
    addTearDown(focus.dispose);
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      _host(
        controller: controller,
        focus: focus,
        onPlaybackHandoff: (value) => handoff = value,
      ),
    );
    await tester.pump();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);

    expect(handoff, isA<LivePlaybackHandoff>());
    expect(handoff?.libraryItemId, 'library-0');
    expect(find.byKey(const ValueKey('movie-play')), findsNothing);
  });

  testWidgets('history reorder preserves the exact focused card node', (
    tester,
  ) async {
    var history = [_recent(0), _recent(1)];
    final controller = HomeController(
      data: _HomeData(
        sourceCheck: () async => true,
        loadHistory: (_) async => history,
      ),
    );
    final focus = FocusNode();
    addTearDown(focus.dispose);
    addTearDown(controller.dispose);

    await tester.pumpWidget(_host(controller: controller, focus: focus));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    final focusedBefore = FocusManager.instance.primaryFocus;
    expect(focusedBefore?.debugLabel, 'home recent item 1');

    history = [_recent(1), _recent(0)];
    await controller.refresh();
    await tester.pump();

    expect(FocusManager.instance.primaryFocus, same(focusedBefore));
    expect(FocusManager.instance.primaryFocus?.hasFocus, isTrue);
  });

  testWidgets('large text uses the stacked Recently Watched composition', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1265, 713));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = HomeController(
      data: _HomeData(
        sourceCheck: () async => true,
        loadHistory: (_) async => [_recent(0), _recent(1)],
      ),
    );
    final focus = FocusNode();
    addTearDown(focus.dispose);
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      _host(
        controller: controller,
        focus: focus,
        textScaler: const TextScaler.linear(2),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Recently Watched'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('pinned shelves render before Recently Watched on Home', (
    tester,
  ) async {
    final controller = HomeController(
      data: _HomeData(
        sourceCheck: () async => true,
        loadHistory: (_) async => [_recent(0)],
        loadPinned: (_, _) async => [
          _personalShelf(
            id: 'favorites',
            name: 'Favorites',
            items: [_personal('favorite-movie', SourceMediaKind.movies)],
          ),
        ],
      ),
    );
    final focus = FocusNode();
    final session = HomeSession();
    addTearDown(focus.dispose);
    addTearDown(controller.dispose);

    await tester.binding.setSurfaceSize(const Size(1265, 713));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      _host(controller: controller, focus: focus, session: session),
    );
    await tester.pumpAndSettle();

    expect(
      tester.getTopLeft(find.text('Favorites')).dy,
      lessThan(tester.getTopLeft(find.text('Recently Watched')).dy),
    );
    expect(session.focusedShelfKey, 'group:favorites');
    expect(session.focusedLibraryItemId, 'favorite-movie');

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(session.focusedShelfKey, 'recent');
    expect(session.focusedLibraryItemId, 'library-0');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();
    expect(session.focusedShelfKey, 'group:favorites');
  });

  testWidgets(
    'Series episode playback keeps identity and Back restores card before rail',
    (tester) async {
      final item = _recent(0, kind: SourceMediaKind.series);
      final loader = _SeriesLoader(
        const SeriesInfo(
          seasons: [
            SeriesSeason(
              name: '1',
              episodes: [
                SeriesEpisode(
                  providerItemId: 'episode-7',
                  title: 'Episode seven',
                  extension: 'mkv',
                ),
              ],
            ),
          ],
        ),
      );
      final controller = HomeController(
        data: _HomeData(
          sourceCheck: () async => true,
          loadHistory: (_) async => [item],
        ),
      );
      final focus = FocusNode();
      final session = HomeSession();
      final handoffs = <PlaybackHandoff>[];
      var railOpens = 0;
      addTearDown(focus.dispose);
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        _host(
          controller: controller,
          focus: focus,
          session: session,
          seriesInfoLoader: loader,
          onOpenRail: () => railOpens += 1,
          onPlaybackHandoff: handoffs.add,
        ),
      );
      await tester.pump();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      await tester.pump();

      expect(loader.loads, 1);
      expect(find.text('Episode seven'), findsOneWidget);
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'series season 0');
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'series episode 0',
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      expect(handoffs.single, isA<EpisodePlaybackHandoff>());
      final episode = handoffs.single as EpisodePlaybackHandoff;
      expect(episode.libraryItemId, 'library-0');
      expect(episode.providerItemId, 'episode-7');
      expect(episode.extension, 'mkv');

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(session.focusedLibraryItemId, 'library-0');
      expect(focus.hasFocus, isTrue);
      expect(railOpens, 0);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      expect(railOpens, 1);
    },
  );

  testWidgets(
    'pinned-only Movie and Series Back restore their exact pinned cards',
    (tester) async {
      final pinned = [
        _personalShelf(
          id: 'featured',
          name: 'Featured',
          items: [
            _personal('pinned-movie', SourceMediaKind.movies),
            _personal('pinned-series', SourceMediaKind.series),
          ],
        ),
      ];
      final loader = _SeriesLoader(
        const SeriesInfo(
          seasons: [
            SeriesSeason(
              name: '1',
              episodes: [
                SeriesEpisode(
                  providerItemId: 'episode-1',
                  title: 'Episode one',
                  extension: 'mp4',
                ),
              ],
            ),
          ],
        ),
        expectedCatalogId: 'catalog-pinned-series',
      );
      final controller = HomeController(
        data: _HomeData(
          sourceCheck: () async => true,
          loadPinned: (_, _) async => pinned,
        ),
      );
      final focus = FocusNode();
      final session = HomeSession();
      addTearDown(focus.dispose);
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        _host(
          controller: controller,
          focus: focus,
          session: session,
          seriesInfoLoader: loader,
        ),
      );
      await tester.pumpAndSettle();

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(find.byKey(const ValueKey('movie-play')), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(session.focusedLibraryItemId, 'pinned-movie');
      expect(focus.hasFocus, isTrue);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expect(session.focusedLibraryItemId, 'pinned-series');
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(find.text('Episode one'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();

      expect(session.focusedShelfKey, 'group:featured');
      expect(session.focusedLibraryItemId, 'pinned-series');
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'home pinned group:featured item 1',
      );
    },
  );

  testWidgets('refresh repairs focus when the focused pinned card is removed', (
    tester,
  ) async {
    var items = [
      _personal('keep-before', SourceMediaKind.movies),
      _personal('remove-me', SourceMediaKind.movies),
      _personal('keep-after', SourceMediaKind.movies),
    ];
    final controller = HomeController(
      data: _HomeData(
        sourceCheck: () async => true,
        loadPinned: (_, _) async => [
          _personalShelf(id: 'focus', name: 'Focus', items: items),
        ],
      ),
    );
    final focus = FocusNode();
    final session = HomeSession();
    addTearDown(focus.dispose);
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      _host(controller: controller, focus: focus, session: session),
    );
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    final removedNode = FocusManager.instance.primaryFocus;
    expect(session.focusedLibraryItemId, 'remove-me');

    items = [
      _personal('keep-before', SourceMediaKind.movies),
      _personal('keep-after', SourceMediaKind.movies),
    ];
    await controller.refresh();
    await tester.pumpAndSettle();

    expect(session.focusedShelfKey, 'group:focus');
    expect(session.focusedLibraryItemId, 'keep-after');
    expect(FocusManager.instance.primaryFocus, isNot(same(removedNode)));
    expect(FocusManager.instance.primaryFocus?.hasFocus, isTrue);
  });

  testWidgets(
    'pinned cards are single traversal stops with pointer and card organize routes',
    (tester) async {
      final controller = HomeController(
        data: _HomeData(
          sourceCheck: () async => true,
          loadPinned: (_, _) async => [
            _personalShelf(
              id: 'traversal',
              name: 'Traversal',
              items: [
                _personal('first-card', SourceMediaKind.movies),
                _personal('second-card', SourceMediaKind.movies),
              ],
            ),
          ],
        ),
      );
      final focus = FocusNode();
      final session = HomeSession();
      final organized = <String>[];
      addTearDown(focus.dispose);
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        _host(
          controller: controller,
          focus: focus,
          session: session,
          onOrganizePersonal: (item) => organized.add(item.libraryItemId),
        ),
      );
      await tester.pumpAndSettle();

      expect(session.focusedLibraryItemId, 'first-card');
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(session.focusedLibraryItemId, 'second-card');
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'home pinned group:traversal item 1',
      );

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pump();
      expect(session.focusedLibraryItemId, 'first-card');
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expect(session.focusedLibraryItemId, 'second-card');

      await tester.tap(find.byTooltip('Organize item'));
      await tester.pump();
      expect(organized, ['second-card']);
      expect(session.focusedLibraryItemId, 'second-card');
      await tester.sendKeyEvent(LogicalKeyboardKey.contextMenu);
      expect(organized, ['second-card', 'second-card']);
    },
  );

  testWidgets('pinned Favorites and groups keep Home shelf order and actions', (
    tester,
  ) async {
    final pinned = [
      HomePersonalShelf(
        collection: const PersonalLibraryDirectoryEntry(
          kind: PersonalLibraryDirectoryKind.favorites,
          collectionId: null,
          name: 'Favorites',
          itemCount: 2,
          homeOrdinal: 0,
        ),
        items: [
          _personal('fav-live', SourceMediaKind.live),
          _personal('fav-movie', SourceMediaKind.movies),
        ],
      ),
      HomePersonalShelf(
        collection: const PersonalLibraryDirectoryEntry(
          kind: PersonalLibraryDirectoryKind.customGroup,
          collectionId: 'family',
          name: 'Family Room',
          itemCount: 1,
          homeOrdinal: 1,
        ),
        items: [_personal('family-series', SourceMediaKind.series)],
      ),
    ];
    final controller = HomeController(
      data: _HomeData(
        sourceCheck: () async => true,
        loadPinned: (_, _) async => pinned,
      ),
    );
    final focus = FocusNode();
    final session = HomeSession();
    PersonalLibraryItem? organized;
    final handoffs = <PlaybackHandoff>[];
    addTearDown(focus.dispose);
    addTearDown(controller.dispose);

    await tester.binding.setSurfaceSize(const Size(1265, 713));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      _host(
        controller: controller,
        focus: focus,
        session: session,
        onPlaybackHandoff: handoffs.add,
        onOrganizePersonal: (item) => organized = item,
      ),
    );
    await tester.pumpAndSettle();

    expect(
      tester.getTopLeft(find.text('Favorites')).dy,
      lessThan(tester.getTopLeft(find.text('Family Room')).dy),
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.contextMenu);
    expect(organized?.libraryItemId, 'fav-live');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    expect(handoffs.single.libraryItemId, 'fav-live');

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(session.focusedLibraryItemId, 'fav-movie');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(session.focusedShelfKey, 'group:family');
    expect(session.focusedLibraryItemId, 'family-series');
  });
}

Widget _host({
  required HomeController controller,
  required FocusNode focus,
  HomeSession? session,
  VoidCallback? onOpenRail,
  ValueChanged<LibraryCatalogItem>? onActivate,
  ValueChanged<PlaybackHandoff>? onPlaybackHandoff,
  ValueChanged<PersonalLibraryItem>? onOrganizePersonal,
  SeriesInfoLoader? seriesInfoLoader,
  HomeArtworkBuilder? artworkBuilder,
  TextScaler textScaler = TextScaler.noScaling,
}) => MaterialApp(
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(textScaler: textScaler),
    child: child!,
  ),
  home: Scaffold(
    body: HomeScreen(
      fixtureMode: HomeFixtureMode.runtime,
      showFixtureCopy: false,
      initialFocus: focus,
      onContentFocus: (_) {},
      onOpenRail: onOpenRail ?? () {},
      onBrowseLive: () {},
      onBrowseMovies: () {},
      onBrowseSeries: () {},
      onAddSource: () {},
      controller: controller,
      session: session,
      artworkBuilder: artworkBuilder,
      onActivateLibraryItem: onActivate,
      onPlaybackHandoff: onPlaybackHandoff,
      onOrganizePersonalItem: onOrganizePersonal,
      seriesInfoLoader: seriesInfoLoader,
    ),
  ),
);

class _HomeData implements HomeData {
  _HomeData({
    required this.sourceCheck,
    this.loadHistory = _emptyHistory,
    this.loadPinned = _emptyPinned,
  });

  final Future<bool> Function() sourceCheck;
  final Future<List<RecentlyWatchedItem>> Function(int limit) loadHistory;
  final Future<List<HomePersonalShelf>> Function(int shelfLimit, int itemLimit)
  loadPinned;

  static Future<List<RecentlyWatchedItem>> _emptyHistory(int _) async =>
      const [];
  static Future<List<HomePersonalShelf>> _emptyPinned(int _, int _) async =>
      const [];

  static Future<PersistedSource?> _readySource(String sourceId) async =>
      PersistedSource(
        id: sourceId,
        name: 'Strong',
        credentialKey: 'source-key',
        counts: const {},
      );

  @override
  Future<bool> hasSources() => sourceCheck();

  @override
  Future<List<RecentlyWatchedItem>> loadRecentlyWatched({required int limit}) =>
      loadHistory(limit);

  @override
  Future<List<HomePersonalShelf>> loadPinnedShelves({
    required int shelfLimit,
    required int itemLimit,
  }) => loadPinned(shelfLimit, itemLimit);

  @override
  Future<PersistedSource?> loadReadySourceById(String sourceId) =>
      _readySource(sourceId);
}

class _SeriesLoader implements SeriesInfoLoader {
  _SeriesLoader(this.info, {this.expectedCatalogId = 'catalog-0'});

  final SeriesInfo info;
  final String expectedCatalogId;
  int loads = 0;

  @override
  void cancel() {}

  @override
  Future<SeriesInfo> load({
    required PersistedSource source,
    required BrowseCatalogItem series,
  }) async {
    loads += 1;
    expect(source.id, 'source');
    expect(series.id, expectedCatalogId);
    return info;
  }
}

RecentlyWatchedItem _recent(
  int index, {
  SourceMediaKind kind = SourceMediaKind.movies,
}) => RecentlyWatchedItem(
  item: LibraryCatalogItem(
    libraryItemId: 'library-$index',
    catalogItemId: 'catalog-$index',
    sourceId: 'source',
    sourceDisplayName: 'Strong',
    kind: kind,
    title: 'Item $index',
    artworkLocator: null,
    playbackRef:
        '{"providerId":"$index","kind":"${kind.name}","extension":"mp4"}',
  ),
  lastPlayedAt: DateTime.utc(
    2026,
    8,
    18,
    12,
  ).subtract(Duration(minutes: index)),
);

PersonalLibraryItem _personal(String id, SourceMediaKind kind) =>
    PersonalLibraryItem(
      libraryItemId: id,
      kind: kind,
      title: id,
      artworkLocator: null,
      catalogItemId: 'catalog-$id',
      sourceId: 'source',
      sourceDisplayName: 'Strong',
      playbackRef:
          '{"providerId":"$id","kind":"${kind.name}","extension":"mp4"}',
    );

HomePersonalShelf _personalShelf({
  required String id,
  required String name,
  required List<PersonalLibraryItem> items,
}) => HomePersonalShelf(
  collection: PersonalLibraryDirectoryEntry(
    kind: PersonalLibraryDirectoryKind.customGroup,
    collectionId: id,
    name: name,
    itemCount: items.length,
    homeOrdinal: 0,
  ),
  items: items,
);
