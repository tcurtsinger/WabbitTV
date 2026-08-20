import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wabbit_tv/src/features/browse/playback_handoff.dart';
import 'package:wabbit_tv/src/features/browse/series_info_loader.dart';
import 'package:wabbit_tv/src/features/library/my_library_screen.dart';
import 'package:wabbit_tv/src/features/sources/source_catalog_database.dart';
import 'package:wabbit_tv/src/features/sources/source_models.dart';

void main() {
  testWidgets('renders approved direct directory and dense mixed ledger', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1265, 713));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final data = _FakeLibraryData.standard();
    await tester.pumpWidget(_harness(data: data));
    await tester.pumpAndSettle();

    expect(find.text('My Library'), findsOneWidget);
    expect(find.text('Your saved library'), findsOneWidget);
    expect(find.text('Library'), findsOneWidget);
    expect(find.text('Favorites'), findsNWidgets(2));
    expect(find.text('World News Now'), findsOneWidget);
    expect(find.text('MOVIE   |   Weekend playlist'), findsOneWidget);
    expect(find.byKey(const ValueKey('my-library-directory')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('my-library-items-favorites')),
      findsOneWidget,
    );

    final artwork = find.byKey(
      const ValueKey('my-library-artwork-favorites-0'),
    );
    expect(tester.getSize(artwork), const Size(50, 36));
    expect(find.byType(Image), findsNothing);
    expect(find.textContaining('Create group'), findsNothing);
    expect(find.textContaining('Edit'), findsNothing);
    expect(find.textContaining('Pin'), findsNothing);

    final directory = tester.getRect(
      find.byKey(const ValueKey('my-library-directory')),
    );
    final ledger = tester.getRect(
      find.byKey(const ValueKey('my-library-items-favorites')),
    );
    expect(directory.width, 270);
    expect(ledger.width, greaterThan(directory.width * 2));
  });

  testWidgets('artwork is provided only through the fixed widget seam', (
    tester,
  ) async {
    final built = <String>[];
    final deliberateFocusStates = <bool>[];
    await tester.pumpWidget(
      _harness(
        data: _FakeLibraryData.standard(),
        artworkBuilder: (context, item, deliberatelyFocused) {
          built.add(item.artworkKey ?? item.id);
          deliberateFocusStates.add(deliberatelyFocused);
          return ColoredBox(
            key: ValueKey('owned-art-${item.id}'),
            color: Colors.blue,
          );
        },
      ),
    );
    await tester.pumpAndSettle();

    expect(built, isNotEmpty);
    expect(find.byKey(const ValueKey('owned-art-favorites-0')), findsOneWidget);
    expect(
      tester.getSize(
        find.byKey(const ValueKey('my-library-artwork-favorites-0')),
      ),
      const Size(50, 36),
    );
    expect(deliberateFocusStates, contains(false));
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    await tester.pump();
    expect(deliberateFocusStates, contains(true));
  });

  testWidgets('mouse, Enter, and Select share typed available-row activation', (
    tester,
  ) async {
    final activated = <MyLibraryItem>[];
    await tester.pumpWidget(
      _harness(data: _FakeLibraryData.standard(), onActivated: activated.add),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('my-library-item-favorites-0')));
    expect(activated.single.id, 'favorites-0');

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    expect(activated.last.id, 'favorites-1');

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    expect(activated.last.id, 'favorites-2');
    expect(activated, hasLength(3));
  });

  testWidgets('unavailable item and source fallout remains visible but inert', (
    tester,
  ) async {
    final activated = <MyLibraryItem>[];
    final data = _FakeLibraryData.standard(includeUnavailable: true);
    await tester.pumpWidget(_harness(data: data, onActivated: activated.add));
    await tester.pumpAndSettle();

    expect(find.textContaining('Source unavailable'), findsOneWidget);
    expect(find.textContaining('Unavailable'), findsAtLeastNWidgets(1));
    await tester.tap(
      find.byKey(const ValueKey('my-library-item-favorites-source-offline')),
    );
    await tester.tap(
      find.byKey(const ValueKey('my-library-item-favorites-item-missing')),
    );
    expect(activated, isEmpty);
  });

  testWidgets('Live resolves and hands off the exact source variant', (
    tester,
  ) async {
    final data = _FakeLibraryData.standard();
    data.playableOverrides['favorites-0'] = const LibraryCatalogItem(
      libraryItemId: 'favorites-0',
      catalogItemId: 'exact-live-catalog',
      sourceId: 'exact-live-source',
      sourceDisplayName: 'Exact source',
      kind: SourceMediaKind.live,
      title: 'World News Now',
      artworkLocator: null,
      playbackRef: '{"providerId":"900","kind":"live","extension":"ts"}',
    );
    final handoffs = <PlaybackHandoff>[];
    await tester.pumpWidget(_harness(data: data, onHandoff: handoffs.add));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('my-library-item-favorites-0')));
    await tester.pumpAndSettle();
    final handoff = handoffs.single as LivePlaybackHandoff;
    expect(handoff.sourceId, 'exact-live-source');
    expect(handoff.providerItemId, '900');
    expect(handoff.libraryItemId, 'favorites-0');
  });

  testWidgets('Movie opens its continuation and hands off only after Play', (
    tester,
  ) async {
    final data = _FakeLibraryData.standard();
    data.playableOverrides['favorites-1'] = const LibraryCatalogItem(
      libraryItemId: 'favorites-1',
      catalogItemId: 'exact-movie-catalog',
      sourceId: 'movie-source',
      sourceDisplayName: 'Movie source',
      kind: SourceMediaKind.movies,
      title: 'Midnight Crossing',
      artworkLocator: null,
      playbackRef: '{"providerId":"901","kind":"movies","extension":"mkv"}',
    );
    final handoffs = <PlaybackHandoff>[];
    await tester.pumpWidget(_harness(data: data, onHandoff: handoffs.add));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('my-library-item-favorites-1')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('movie-play')), findsOneWidget);
    expect(handoffs, isEmpty);

    await tester.tap(find.byKey(const ValueKey('movie-play')));
    final handoff = handoffs.single as MoviePlaybackHandoff;
    expect(handoff.sourceId, 'movie-source');
    expect(handoff.providerItemId, '901');
    expect(handoff.extension, 'mkv');
    expect(handoff.libraryItemId, 'favorites-1');
  });

  testWidgets(
    'Series uses its exact source and keeps library identity on episode',
    (tester) async {
      final data = _FakeLibraryData.standard();
      data.playableOverrides['favorites-2'] = const LibraryCatalogItem(
        libraryItemId: 'favorites-2',
        catalogItemId: 'exact-series-catalog',
        sourceId: 'exact-series-source',
        sourceDisplayName: 'Series source',
        kind: SourceMediaKind.series,
        title: 'Wild Terrain',
        artworkLocator: null,
        playbackRef: '{"providerId":"902","kind":"series"}',
      );
      final loader = _FakeLibrarySeriesLoader();
      final handoffs = <PlaybackHandoff>[];
      await tester.pumpWidget(
        _harness(data: data, onHandoff: handoffs.add, seriesInfoLoader: loader),
      );
      await tester.pumpAndSettle();

      await tester.tap(
        find.byKey(const ValueKey('my-library-item-favorites-2')),
      );
      await tester.pumpAndSettle();
      expect(loader.loadedSourceId, 'exact-series-source');
      expect(loader.loadedCatalogId, 'exact-series-catalog');
      await tester.tap(find.byKey(const ValueKey('series-episode-0')));
      final handoff = handoffs.single as EpisodePlaybackHandoff;
      expect(handoff.sourceId, 'exact-series-source');
      expect(handoff.providerItemId, 'episode-77');
      expect(handoff.libraryItemId, 'favorites-2');
    },
  );

  testWidgets(
    'continuation Back and Escape restore the exact ledger row focus',
    (tester) async {
      final data = _FakeLibraryData.standard();
      await tester.pumpWidget(_harness(data: data, onHandoff: (_) {}));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('my-library-item-favorites-1')),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('movie-play')), findsOneWidget);

      await tester.sendKeyEvent(
        LogicalKeyboardKey.browserBack,
        platform: 'windows',
        physicalKey: PhysicalKeyboardKey.browserBack,
      );
      await tester.pump();
      await tester.pump();
      await tester.pump();
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'my library item favorites-1',
      );
      expect(
        find.byKey(const ValueKey('my-library-items-favorites')),
        findsOneWidget,
      );

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('movie-play')), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      await tester.pump();
      await tester.pump();
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'my library item favorites-1',
      );
    },
  );

  testWidgets(
    'missing playable resolver result is actionable and never hands off',
    (tester) async {
      final data = _FakeLibraryData.standard();
      data.playableOverrides['favorites-0'] = null;
      final handoffs = <PlaybackHandoff>[];
      await tester.pumpWidget(_harness(data: data, onHandoff: handoffs.add));
      await tester.pumpAndSettle();

      await tester.tap(
        find.byKey(const ValueKey('my-library-item-favorites-0')),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('continuation-error-copy')),
        findsOneWidget,
      );
      expect(
        find.text('This item cannot be opened from the imported catalog.'),
        findsOneWidget,
      );
      expect(handoffs, isEmpty);
    },
  );

  testWidgets('late playable resolution cannot replace the latest activation', (
    tester,
  ) async {
    final data = _GatedPlayableData();
    final handoffs = <PlaybackHandoff>[];
    await tester.pumpWidget(_harness(data: data, onHandoff: handoffs.add));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('my-library-item-favorites-0')));
    await tester.tap(find.byKey(const ValueKey('my-library-item-favorites-1')));
    data.movie.complete(
      const LibraryCatalogItem(
        libraryItemId: 'favorites-1',
        catalogItemId: 'movie',
        sourceId: 'new-source',
        sourceDisplayName: 'New',
        kind: SourceMediaKind.movies,
        title: 'Midnight Crossing',
        artworkLocator: null,
        playbackRef: '{"providerId":"2","kind":"movies"}',
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('movie-play')), findsOneWidget);

    data.live.complete(
      const LibraryCatalogItem(
        libraryItemId: 'favorites-0',
        catalogItemId: 'live',
        sourceId: 'old-source',
        sourceDisplayName: 'Old',
        kind: SourceMediaKind.live,
        title: 'World News Now',
        artworkLocator: null,
        playbackRef: '{"providerId":"1","kind":"live"}',
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('movie-play')), findsOneWidget);
    expect(handoffs, isEmpty);
  });

  testWidgets('narrow launcher opens overlay and Escape restores launcher', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(600, 713));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    var railOpens = 0;
    await tester.pumpWidget(
      _harness(
        data: _FakeLibraryData.standard(),
        onOpenRail: () => railOpens++,
      ),
    );
    await tester.pumpAndSettle();

    final launcher = find.byKey(
      const ValueKey('my-library-directory-launcher'),
    );
    expect(launcher, findsOneWidget);
    await tester.tap(launcher);
    await tester.pump();
    expect(
      find.byKey(const ValueKey('my-library-directory-overlay')),
      findsOneWidget,
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(
      find.byKey(const ValueKey('my-library-directory-overlay')),
      findsNothing,
    );
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'my library directory launcher',
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    expect(railOpens, 1);
  });

  testWidgets('wide arrows cross panes and Back returns to selected section', (
    tester,
  ) async {
    var railOpens = 0;
    await tester.pumpWidget(
      _harness(
        data: _FakeLibraryData.standard(),
        onOpenRail: () => railOpens++,
      ),
    );
    await tester.pumpAndSettle();
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'my library section favorites',
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'my library item favorites-0',
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'my library section favorites',
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    expect(railOpens, 1);
  });

  testWidgets('truthfully distinguishes empty library and empty saved list', (
    tester,
  ) async {
    var railOpens = 0;
    await tester.pumpWidget(
      _harness(data: _FakeLibraryData.empty(), onOpenRail: () => railOpens++),
    );
    await tester.pumpAndSettle();
    expect(find.text('Your saved library is empty'), findsOneWidget);
    expect(
      find.text(
        'Favorites and custom groups will appear here when you save them.',
      ),
      findsOneWidget,
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    expect(railOpens, 1);

    await tester.pumpWidget(
      _harness(
        key: const ValueKey('empty-section-harness'),
        data: _FakeLibraryData.onlyEmptySection(),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Nothing saved here yet'), findsOneWidget);
    expect(find.text('0 items'), findsOneWidget);
  });

  testWidgets('initial local-read failure retries without exposing details', (
    tester,
  ) async {
    final data = _RetryingDirectoryData();
    var railOpens = 0;
    await tester.pumpWidget(
      _harness(data: data, onOpenRail: () => railOpens++),
    );
    await tester.pumpAndSettle();
    expect(find.text('My Library could not be loaded'), findsOneWidget);
    expect(find.textContaining('sqlite'), findsNothing);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    expect(railOpens, 1);

    await tester.tap(find.byKey(const ValueKey('my-library-initial-retry')));
    await tester.pumpAndSettle();
    expect(find.text('World News Now'), findsOneWidget);
    expect(data.sectionCalls, 2);
  });

  testWidgets('refresh failure preserves the last usable directory and rows', (
    tester,
  ) async {
    final session = MyLibrarySession();
    await tester.pumpWidget(
      _harness(
        key: const ValueKey('refresh-harness'),
        data: _FakeLibraryData.standard(),
        session: session,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('World News Now'), findsOneWidget);

    await tester.pumpWidget(
      _harness(
        key: const ValueKey('refresh-harness'),
        data: const _FailingDirectoryData(),
        session: session,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('World News Now'), findsOneWidget);
    expect(
      find.text(
        'My Library could not refresh. Your last loaded library is unchanged.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('failed section selection leaves the current list unchanged', (
    tester,
  ) async {
    final data = _FakeLibraryData.standard()..failingSections.add('living');
    await tester.pumpWidget(_harness(data: data));
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(const ValueKey('my-library-section-row-living')),
    );
    await tester.pumpAndSettle();
    expect(find.text('World News Now'), findsOneWidget);
    expect(
      find.text(
        'That saved list could not be opened. Your current list is unchanged.',
      ),
      findsOneWidget,
    );
    expect(find.text('Favorites'), findsNWidgets(2));

    data.failingSections.remove('living');
    await tester.tap(find.byKey(const ValueKey('my-library-recovery-retry')));
    await tester.pumpAndSettle();
    expect(find.text('Living Room Live'), findsOneWidget);
    expect(find.text('Living Room'), findsNWidgets(2));
  });

  testWidgets('bounded keyset paging and page retry keep loaded rows visible', (
    tester,
  ) async {
    final data = _PagingData();
    await tester.pumpWidget(_harness(data: data));
    await tester.pumpAndSettle();
    expect(data.requestedLimits, everyElement(100));

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    await tester.pump();
    expect(find.text('First page 0'), findsOneWidget);
    expect(find.byKey(const ValueKey('my-library-page-retry')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('my-library-page-retry')));
    await tester.pumpAndSettle();
    expect(find.text('Second page'), findsOneWidget);
    expect(data.cursors, contains(const MyLibraryPageCursor('next')));
  });

  testWidgets('latest section wins when older local reads finish late', (
    tester,
  ) async {
    final data = _GatedSelectionData();
    await tester.pumpWidget(_harness(data: data));
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(const ValueKey('my-library-section-row-living')),
    );
    await tester.pump();
    await tester.tap(
      find.byKey(const ValueKey('my-library-section-row-weekend')),
    );
    await tester.pump();

    data.weekend.complete(
      const MyLibraryPage(
        items: [
          MyLibraryItem(
            id: 'latest',
            title: 'Latest selection',
            kind: MyLibraryMediaKind.movie,
            sourceName: 'Local',
          ),
        ],
        nextCursor: null,
      ),
    );
    await tester.pump();
    data.living.complete(
      const MyLibraryPage(
        items: [
          MyLibraryItem(
            id: 'stale',
            title: 'Stale selection',
            kind: MyLibraryMediaKind.live,
            sourceName: 'Local',
          ),
        ],
        nextCursor: null,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Latest selection'), findsOneWidget);
    expect(find.text('Stale selection'), findsNothing);
    expect(find.text('Weekend Movies'), findsNWidgets(2));
  });

  testWidgets('selected section, scroll, and focused item restore on return', (
    tester,
  ) async {
    final session = MyLibrarySession();
    final data = _FakeLibraryData.withManyItems(40);
    await tester.pumpWidget(_harness(data: data, session: session));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    for (var index = 0; index < 14; index++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      await tester.pump();
    }
    final focusedBeforeReturn = session.focusedItemId;
    expect(focusedBeforeReturn, isNotNull);
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'my library item $focusedBeforeReturn',
    );
    expect(session.itemScrollOffset, greaterThan(0));

    await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
    await tester.pump();
    await tester.pumpWidget(_harness(data: data, session: session));
    await tester.pumpAndSettle();
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'my library item $focusedBeforeReturn',
    );
    expect(
      find.text('Saved title ${focusedBeforeReturn!.split('-').last}'),
      findsOneWidget,
    );
  });

  testWidgets('long Unicode names stay inside constrained directory rows', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(600, 713));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(_harness(data: _FakeLibraryData.longNames()));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('my-library-directory-launcher')),
    );
    await tester.pump();
    final row = tester.getRect(
      find.byKey(const ValueKey('my-library-section-row-unicode')),
    );
    expect(row.left, greaterThanOrEqualTo(0));
    expect(row.right, lessThanOrEqualTo(600));
    expect(tester.takeException(), isNull);
  });

  testWidgets('large text expands fixed rows without clipping', (tester) async {
    await tester.binding.setSurfaceSize(const Size(600, 713));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      _harness(
        data: _FakeLibraryData.longNames(),
        textScaler: const TextScaler.linear(2),
      ),
    );
    await tester.pumpAndSettle();

    final item = tester.getRect(
      find.byKey(const ValueKey('my-library-item-unicode-item')),
    );
    expect(item.height, greaterThan(64));
    expect(item.right, lessThanOrEqualTo(600));
    expect(tester.takeException(), isNull);
  });

  testWidgets('directory requests the full supported 200 collection window', (
    tester,
  ) async {
    final data = _FakeLibraryData.standard();
    await tester.pumpWidget(_harness(data: data));
    await tester.pumpAndSettle();

    expect(data.lastSectionLimit, 200);
  });

  testWidgets(
    'organization revision refreshes without losing a surviving row',
    (tester) async {
      const key = ValueKey('revision-harness');
      final seed = _FakeLibraryData.standard();
      final data = _FakeLibraryData(
        seed.sections.toList(),
        seed.itemsBySection.map((key, value) => MapEntry(key, value.toList())),
      );
      final session = MyLibrarySession();
      await tester.pumpWidget(
        _harness(
          key: key,
          data: data,
          session: session,
          organizationRevision: 0,
        ),
      );
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'my library item favorites-1',
      );

      data.sections[0] = const MyLibrarySection(
        id: 'favorites',
        name: 'Favorites',
        kind: MyLibrarySectionKind.favorites,
        itemCount: 2,
      );
      data.itemsBySection['favorites'] = data.itemsBySection['favorites']!
          .skip(1)
          .toList();
      await tester.pumpWidget(
        _harness(
          key: key,
          data: data,
          session: session,
          organizationRevision: 1,
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('my-library-item-favorites-0')),
        findsNothing,
      );
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'my library item favorites-1',
      );
    },
  );
}

Widget _harness({
  Key? key,
  required MyLibraryData data,
  MyLibrarySession? session,
  MyLibraryItemActivated? onActivated,
  MyLibraryArtworkBuilder? artworkBuilder,
  VoidCallback? onOpenRail,
  ValueChanged<PlaybackHandoff>? onHandoff,
  SeriesInfoLoader? seriesInfoLoader,
  int organizationRevision = 0,
  TextScaler textScaler = TextScaler.noScaling,
}) => _Harness(
  key: key,
  data: data,
  session: session ?? MyLibrarySession(),
  onActivated: onActivated ?? (_) {},
  artworkBuilder: artworkBuilder,
  onOpenRail: onOpenRail ?? () {},
  onHandoff: onHandoff,
  seriesInfoLoader: seriesInfoLoader,
  organizationRevision: organizationRevision,
  textScaler: textScaler,
);

class _Harness extends StatefulWidget {
  const _Harness({
    super.key,
    required this.data,
    required this.session,
    required this.onActivated,
    required this.onOpenRail,
    this.onHandoff,
    this.seriesInfoLoader,
    this.artworkBuilder,
    this.organizationRevision = 0,
    required this.textScaler,
  });
  final MyLibraryData data;
  final MyLibrarySession session;
  final MyLibraryItemActivated onActivated;
  final MyLibraryArtworkBuilder? artworkBuilder;
  final TextScaler textScaler;
  final VoidCallback onOpenRail;
  final ValueChanged<PlaybackHandoff>? onHandoff;
  final SeriesInfoLoader? seriesInfoLoader;
  final int organizationRevision;

  @override
  State<_Harness> createState() => _HarnessState();
}

class _HarnessState extends State<_Harness> {
  final FocusNode _focus = FocusNode(debugLabel: 'library entry');

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(textScaler: widget.textScaler),
      child: child!,
    ),
    theme: ThemeData.dark(useMaterial3: true).copyWith(
      textTheme: ThemeData.dark().textTheme.apply(fontFamily: 'Segoe UI'),
    ),
    home: Scaffold(
      body: MyLibraryScreen(
        data: widget.data,
        initialFocus: _focus,
        onContentFocus: (_) {},
        onOpenRail: widget.onOpenRail,
        session: widget.session,
        organizationRevision: widget.organizationRevision,
        onItemActivated: widget.onActivated,
        onPlaybackHandoff: widget.onHandoff,
        seriesInfoLoader: widget.seriesInfoLoader,
        artworkBuilder: widget.artworkBuilder,
      ),
    ),
  );
}

abstract class _TestLibraryData implements MyLibraryData {
  const _TestLibraryData();

  @override
  Future<LibraryCatalogItem?> resolvePlayableItem(String libraryItemId) async =>
      null;

  @override
  Future<PersistedSource?> loadReadySourceById(String sourceId) async =>
      PersistedSource(
        id: sourceId,
        name: 'Source $sourceId',
        credentialKey: 'test-$sourceId',
        counts: const {},
      );
}

class _FakeLibraryData extends _TestLibraryData {
  _FakeLibraryData(this.sections, this.itemsBySection);

  factory _FakeLibraryData.standard({bool includeUnavailable = false}) {
    final items = _standardItems();
    if (includeUnavailable) {
      items
        ..[1] = const MyLibraryItem(
          id: 'favorites-source-offline',
          title: 'Offline source title',
          kind: MyLibraryMediaKind.live,
          sourceName: 'Removed source',
          availability: MyLibraryItemAvailability.sourceUnavailable,
        )
        ..[2] = const MyLibraryItem(
          id: 'favorites-item-missing',
          title: 'Missing title',
          kind: MyLibraryMediaKind.movie,
          sourceName: 'Home provider',
          availability: MyLibraryItemAvailability.itemUnavailable,
        );
    }
    return _FakeLibraryData(_standardSections(), {
      'favorites': items,
      'living': const [
        MyLibraryItem(
          id: 'living-0',
          title: 'Living Room Live',
          kind: MyLibraryMediaKind.live,
          sourceName: 'Home provider',
        ),
      ],
      'weekend': const [
        MyLibraryItem(
          id: 'weekend-0',
          title: 'Weekend Movie',
          kind: MyLibraryMediaKind.movie,
          sourceName: 'Home provider',
        ),
      ],
    });
  }

  factory _FakeLibraryData.empty() => _FakeLibraryData(const [], const {});

  factory _FakeLibraryData.onlyEmptySection() => _FakeLibraryData(
    const [
      MyLibrarySection(
        id: 'favorites',
        name: 'Favorites',
        kind: MyLibrarySectionKind.favorites,
        itemCount: 0,
      ),
    ],
    const {'favorites': []},
  );

  factory _FakeLibraryData.withManyItems(int count) => _FakeLibraryData(
    [
      MyLibrarySection(
        id: 'favorites',
        name: 'Favorites',
        kind: MyLibrarySectionKind.favorites,
        itemCount: count,
      ),
    ],
    {
      'favorites': [
        for (var index = 0; index < count; index++)
          MyLibraryItem(
            id: 'favorites-$index',
            title: 'Saved title $index',
            kind: MyLibraryMediaKind.values[index % 3],
            sourceName: 'Home provider',
          ),
      ],
    },
  );

  factory _FakeLibraryData.longNames() => _FakeLibraryData(
    const [
      MyLibrarySection(
        id: 'unicode',
        name: '家族のお気に入り — Très longue collection pour le salon et les soirées',
        kind: MyLibrarySectionKind.customGroup,
        itemCount: 1,
      ),
    ],
    const {
      'unicode': [
        MyLibraryItem(
          id: 'unicode-item',
          title: '非常に長い番組タイトル — Une émission avec un titre extrêmement long',
          kind: MyLibraryMediaKind.series,
          sourceName: '家庭のプロバイダー',
        ),
      ],
    },
  );

  final List<MyLibrarySection> sections;
  final Map<String, List<MyLibraryItem>> itemsBySection;
  final Set<String> failingSections = {};
  final Map<String, LibraryCatalogItem?> playableOverrides = {};
  int sectionCalls = 0;
  int? lastSectionLimit;

  @override
  Future<List<MyLibrarySection>> loadSections({int limit = 100}) async {
    sectionCalls++;
    lastSectionLimit = limit;
    return sections;
  }

  @override
  Future<MyLibraryPage> loadItems({
    required String sectionId,
    MyLibraryPageCursor? cursor,
    int limit = 100,
  }) async {
    if (failingSections.contains(sectionId)) throw StateError('local read');
    final items = itemsBySection[sectionId] ?? const [];
    return MyLibraryPage(
      items: items.take(limit).toList(),
      nextCursor: null,
      totalCount: items.length,
    );
  }

  @override
  Future<LibraryCatalogItem?> resolvePlayableItem(String libraryItemId) async {
    if (playableOverrides.containsKey(libraryItemId)) {
      return playableOverrides[libraryItemId];
    }
    MyLibraryItem? presentation;
    for (final items in itemsBySection.values) {
      for (final item in items) {
        if (item.id == libraryItemId) {
          presentation = item;
          break;
        }
      }
      if (presentation != null) break;
    }
    if (presentation == null || !presentation.isAvailable) return null;
    final kind = switch (presentation.kind) {
      MyLibraryMediaKind.live => SourceMediaKind.live,
      MyLibraryMediaKind.movie => SourceMediaKind.movies,
      MyLibraryMediaKind.series => SourceMediaKind.series,
    };
    return LibraryCatalogItem(
      libraryItemId: presentation.id,
      catalogItemId: '${presentation.id}-catalog',
      sourceId: 'source-a',
      sourceDisplayName: presentation.sourceLabel,
      kind: kind,
      title: presentation.title,
      artworkLocator: null,
      playbackRef: '{"providerId":"${presentation.id}","kind":"${kind.name}"}',
    );
  }
}

class _RetryingDirectoryData extends _FakeLibraryData {
  _RetryingDirectoryData()
    : super(_standardSections(), {'favorites': _standardItems()});

  @override
  Future<List<MyLibrarySection>> loadSections({int limit = 100}) async {
    sectionCalls++;
    if (sectionCalls == 1) throw StateError('sqlite path should be redacted');
    return sections;
  }
}

class _FailingDirectoryData extends _TestLibraryData {
  const _FailingDirectoryData();

  @override
  Future<List<MyLibrarySection>> loadSections({int limit = 100}) =>
      Future.error(StateError('local read'));

  @override
  Future<MyLibraryPage> loadItems({
    required String sectionId,
    MyLibraryPageCursor? cursor,
    int limit = 100,
  }) => Future.error(StateError('not reached'));
}

class _PagingData extends _TestLibraryData {
  bool failNext = true;
  final List<int> requestedLimits = [];
  final List<MyLibraryPageCursor?> cursors = [];

  @override
  Future<List<MyLibrarySection>> loadSections({int limit = 100}) async =>
      const [
        MyLibrarySection(
          id: 'favorites',
          name: 'Favorites',
          kind: MyLibrarySectionKind.favorites,
          itemCount: 3,
        ),
      ];

  @override
  Future<MyLibraryPage> loadItems({
    required String sectionId,
    MyLibraryPageCursor? cursor,
    int limit = 100,
  }) async {
    requestedLimits.add(limit);
    cursors.add(cursor);
    if (cursor == null) {
      return const MyLibraryPage(
        items: [
          MyLibraryItem(
            id: 'first-0',
            title: 'First page 0',
            kind: MyLibraryMediaKind.live,
            sourceName: 'Home',
          ),
          MyLibraryItem(
            id: 'first-1',
            title: 'First page 1',
            kind: MyLibraryMediaKind.movie,
            sourceName: 'Home',
          ),
        ],
        nextCursor: MyLibraryPageCursor('next'),
        totalCount: 3,
      );
    }
    if (failNext) {
      failNext = false;
      throw StateError('page');
    }
    return const MyLibraryPage(
      items: [
        MyLibraryItem(
          id: 'second',
          title: 'Second page',
          kind: MyLibraryMediaKind.series,
          sourceName: 'Home',
        ),
      ],
      nextCursor: null,
      totalCount: 3,
    );
  }
}

class _GatedSelectionData extends _TestLibraryData {
  final Completer<MyLibraryPage> living = Completer<MyLibraryPage>();
  final Completer<MyLibraryPage> weekend = Completer<MyLibraryPage>();

  @override
  Future<List<MyLibrarySection>> loadSections({int limit = 100}) async =>
      _standardSections();

  @override
  Future<MyLibraryPage> loadItems({
    required String sectionId,
    MyLibraryPageCursor? cursor,
    int limit = 100,
  }) async => switch (sectionId) {
    'living' => living.future,
    'weekend' => weekend.future,
    _ => MyLibraryPage(
      items: _standardItems(),
      nextCursor: null,
      totalCount: _standardItems().length,
    ),
  };
}

class _FakeLibrarySeriesLoader implements SeriesInfoLoader {
  String? loadedSourceId;
  String? loadedCatalogId;

  @override
  void cancel() {}

  @override
  Future<SeriesInfo> load({
    required PersistedSource source,
    required BrowseCatalogItem series,
  }) async {
    loadedSourceId = source.id;
    loadedCatalogId = series.id;
    return const SeriesInfo(
      seasons: [
        SeriesSeason(
          name: '1',
          episodes: [
            SeriesEpisode(
              providerItemId: 'episode-77',
              title: 'Episode 77',
              extension: 'mp4',
            ),
          ],
        ),
      ],
    );
  }
}

class _GatedPlayableData extends _FakeLibraryData {
  _GatedPlayableData()
    : super(_standardSections(), {'favorites': _standardItems()});

  final Completer<LibraryCatalogItem?> live = Completer<LibraryCatalogItem?>();
  final Completer<LibraryCatalogItem?> movie = Completer<LibraryCatalogItem?>();

  @override
  Future<LibraryCatalogItem?> resolvePlayableItem(String libraryItemId) =>
      switch (libraryItemId) {
        'favorites-0' => live.future,
        'favorites-1' => movie.future,
        _ => super.resolvePlayableItem(libraryItemId),
      };
}

List<MyLibrarySection> _standardSections() => const [
  MyLibrarySection(
    id: 'favorites',
    name: 'Favorites',
    kind: MyLibrarySectionKind.favorites,
    itemCount: 3,
  ),
  MyLibrarySection(
    id: 'living',
    name: 'Living Room',
    kind: MyLibrarySectionKind.customGroup,
    itemCount: 1,
  ),
  MyLibrarySection(
    id: 'weekend',
    name: 'Weekend Movies',
    kind: MyLibrarySectionKind.customGroup,
    itemCount: 1,
  ),
];

List<MyLibraryItem> _standardItems() => [
  const MyLibraryItem(
    id: 'favorites-0',
    title: 'World News Now',
    kind: MyLibraryMediaKind.live,
    sourceName: 'Home provider',
    artworkKey: 'art-0',
  ),
  const MyLibraryItem(
    id: 'favorites-1',
    title: 'Midnight Crossing',
    kind: MyLibraryMediaKind.movie,
    sourceName: 'Weekend playlist',
    artworkKey: 'art-1',
  ),
  const MyLibraryItem(
    id: 'favorites-2',
    title: 'Wild Terrain',
    kind: MyLibraryMediaKind.series,
    sourceName: 'Home provider',
  ),
];
