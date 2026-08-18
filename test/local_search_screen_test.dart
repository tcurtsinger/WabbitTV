import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wabbit_tv/src/features/browse/catalog_scope_controller.dart';
import 'package:wabbit_tv/src/features/browse/playback_handoff.dart';
import 'package:wabbit_tv/src/features/browse/series_info_loader.dart';
import 'package:wabbit_tv/src/features/search/local_search_screen.dart';
import 'package:wabbit_tv/src/features/sources/source_catalog_database.dart';
import 'package:wabbit_tv/src/features/sources/source_models.dart';

void main() {
  testWidgets('empty Search stays instructional and does not query a catalog', (
    tester,
  ) async {
    final data = _FakeSearchData();
    await tester.pumpWidget(_screen(data: data));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('search-empty')), findsOneWidget);
    expect(find.byKey(const ValueKey('search-results')), findsNothing);
    expect(data.searchCalls, 0);
    expect(data.countCalls, 0);

    final field = find.byKey(const ValueKey('search-field'));
    await tester.tap(field);
    await tester.pump();
    final box = tester.widget<Container>(
      find.ancestor(of: field, matching: find.byType(Container)).first,
    );
    final border = box.decoration! as BoxDecoration;
    expect((border.border! as Border).top.color, const Color(0xFFFFB347));
    expect((border.border! as Border).top.width, 2);
  });

  testWidgets('physical Unicode search yields one mixed local ledger', (
    tester,
  ) async {
    final data = _FakeSearchData();
    await tester.pumpWidget(_screen(data: data));
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const ValueKey('search-field')), 'Café');
    await tester.pump(const Duration(milliseconds: 220));
    await tester.pumpAndSettle();

    expect(data.searchCalls, 1);
    expect(data.lastQuery, 'Café');
    expect(find.byKey(const ValueKey('search-results')), findsOneWidget);
    expect(find.text('LIVE'), findsOneWidget);
    expect(find.text('MOVIE'), findsOneWidget);
    expect(find.text('SERIES'), findsOneWidget);
    expect(find.text('Strong'), findsAtLeastNWidgets(1));
    expect(find.text('M3U backup'), findsAtLeastNWidgets(1));
  });

  testWidgets(
    'remote keyboard supports keys, nearest-row movement, clear, done, and escape',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(600, 713));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(_screen(data: _FakeSearchData()));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('search-field')));
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('search-tv-keyboard')), findsOneWidget);
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'tv keyboard A');

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'tv keyboard K');
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'tv keyboard Space',
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'tv keyboard Back',
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'tv keyboard Clear',
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('search-field')))
            .controller!
            .text,
        '',
      );

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('search-tv-keyboard')), findsNothing);
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'search field');
    },
  );

  testWidgets('TV keyboard keeps Search visible behind a subdued scrim', (
    tester,
  ) async {
    await tester.pumpWidget(_screen(data: _FakeSearchData()));
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const ValueKey('search-field')), 'Café');
    await tester.pump(const Duration(milliseconds: 220));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('search-tv-keyboard')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('search-tv-keyboard-query')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('search-results')), findsOneWidget);
    expect(
      tester
          .widget<ColoredBox>(
            find.byKey(const ValueKey('search-tv-keyboard-scrim')),
          )
          .color,
      Colors.black.withValues(alpha: .62),
    );
  });

  testWidgets('Search scope launcher matches the confirmed compact control', (
    tester,
  ) async {
    await tester.pumpWidget(_screen(data: _FakeSearchData()));
    await tester.pumpAndSettle();

    expect(
      tester.getSize(find.byKey(const ValueKey('search-scope-menu'))).height,
      44,
    );
    expect(find.byIcon(Icons.layers_outlined), findsNothing);
    expect(find.byIcon(Icons.keyboard_arrow_down), findsOneWidget);
  });

  testWidgets(
    'scope selection reruns a query while non-revision notices do not',
    (tester) async {
      final port = _ScopePort();
      final controller = CatalogScopeController(port: port);
      final data = _FakeSearchData();
      await tester.pumpWidget(_screen(data: data, controller: controller));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('search-field')),
        'News',
      );
      await tester.pump(const Duration(milliseconds: 220));
      await tester.pumpAndSettle();
      expect(data.searchCalls, 1);

      controller.clearAnnouncement();
      await tester.pumpAndSettle();
      expect(data.searchCalls, 1);

      await controller.select(const LibraryScope.source('backup'));
      await tester.pumpAndSettle();
      expect(data.searchCalls, 2);
      expect(data.lastScope?.sourceId, 'backup');
    },
  );

  testWidgets('a disabled Search scope announces one local fallback', (
    tester,
  ) async {
    final port = _ScopePort();
    final controller = CatalogScopeController(port: port);
    await tester.pumpWidget(
      _screen(data: _FakeSearchData(), controller: controller),
    );
    await tester.pumpAndSettle();
    await controller.select(const LibraryScope.source('backup'));
    await tester.pumpAndSettle();

    port.sources = [port.sources.first];
    await controller.refresh();
    await tester.pumpAndSettle();

    expect(controller.scope.isAll, isTrue);
    expect(controller.announcement, isNull);
    expect(
      find.byKey(const ValueKey('search-scope-announcement')),
      findsOneWidget,
    );
    expect(
      find.text('Source unavailable. Showing All sources.'),
      findsOneWidget,
    );

    await tester.pump(const Duration(seconds: 4));
    expect(
      find.byKey(const ValueKey('search-scope-announcement')),
      findsNothing,
    );
    await controller.refresh();
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('search-scope-announcement')),
      findsNothing,
    );
  });

  testWidgets('Clear ignores a stale local response', (tester) async {
    final data = _ControlledSearchData();
    await tester.pumpWidget(_screen(data: data));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('search-field')), 'stale');
    await tester.pump(const Duration(milliseconds: 220));
    expect(data.pending, isNotNull);
    await tester.tap(find.byKey(const ValueKey('search-action-Clear')));
    data.pending!.complete(const LibraryPage(items: _items, nextCursor: null));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('search-empty')), findsOneWidget);
    expect(find.byKey(const ValueKey('search-results')), findsNothing);
  });

  testWidgets('mouse activation exposes the credential-free library item', (
    tester,
  ) async {
    LibraryCatalogItem? activated;
    await tester.pumpWidget(
      _screen(data: _FakeSearchData(), onActivated: (item) => activated = item),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('search-field')), 'Cafe');
    await tester.pump(const Duration(milliseconds: 220));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('search-item-live-1')));
    expect(activated?.libraryItemId, 'live-1');
    expect(activated?.sourceId, 'strong');
  });

  testWidgets(
    'Done focuses the first result and scope menu restores launcher focus',
    (tester) async {
      await tester.pumpWidget(_screen(data: _FakeSearchData()));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('search-field')),
        'Cafe',
      );
      await tester.pump(const Duration(milliseconds: 220));
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'search live-1');

      await tester.tap(find.byKey(const ValueKey('search-scope-menu')));
      await tester.pumpAndSettle();
      expect(find.text('M3U backup'), findsAtLeastNWidgets(1));
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'search scope');
    },
  );
  testWidgets('Live activation preserves the chosen result source', (
    tester,
  ) async {
    PlaybackHandoff? handoff;
    await tester.pumpWidget(
      _screen(data: _FakeSearchData(), onHandoff: (value) => handoff = value),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('search-field')), 'Cafe');
    await tester.pump(const Duration(milliseconds: 220));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('search-item-live-1')));
    expect(handoff, isA<LivePlaybackHandoff>());
    expect(handoff?.sourceId, 'strong');
  });

  testWidgets('Movie Play preserves the chosen result source', (tester) async {
    PlaybackHandoff? handoff;
    await tester.pumpWidget(
      _screen(data: _FakeSearchData(), onHandoff: (value) => handoff = value),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('search-field')), 'Cafe');
    await tester.pump(const Duration(milliseconds: 220));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('search-item-movie-1')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('movie-play')));

    expect(handoff, isA<MoviePlaybackHandoff>());
    expect(handoff?.sourceId, 'backup');
  });

  testWidgets('Series detail and episode playback preserve the result source', (
    tester,
  ) async {
    PlaybackHandoff? handoff;
    final data = _SeriesSearchData();
    final loader = _FakeSeriesInfoLoader();
    await tester.pumpWidget(
      _screen(
        data: data,
        seriesInfoLoader: loader,
        onHandoff: (value) => handoff = value,
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('search-field')), 'Cafe');
    await tester.pump(const Duration(milliseconds: 220));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('search-item-series-1')));
    await tester.pumpAndSettle();
    expect(loader.loadedSourceId, 'strong');
    await tester.tap(find.byKey(const ValueKey('series-episode-0')));

    expect(handoff, isA<EpisodePlaybackHandoff>());
    expect(handoff?.sourceId, 'strong');
  });

  testWidgets('a failed next page preserves rows and offers Retry', (
    tester,
  ) async {
    final data = _PagedSearchData();
    await tester.pumpWidget(_screen(data: data));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('search-field')), 'Cafe');
    await tester.pump(const Duration(milliseconds: 220));
    await tester.pumpAndSettle();

    final rowFocus = tester.widget<Focus>(
      find
          .ancestor(
            of: find.byKey(const ValueKey('search-item-live-1')),
            matching: find.byType(Focus),
          )
          .first,
    );
    rowFocus.focusNode!.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();

    expect(find.text('Café Live'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('search-next-page-error')),
      findsOneWidget,
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'search next-page retry',
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('search-next-page-error')), findsNothing);
    expect(find.text('Next café result'), findsOneWidget);
  });

  testWidgets('redacted local failure Retry is remote reachable', (
    tester,
  ) async {
    final data = _FailsThenSucceedsSearchData();
    await tester.pumpWidget(_screen(data: data));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('search-field')), 'Cafe');
    await tester.pump(const Duration(milliseconds: 220));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('search-error')), findsOneWidget);
    expect(find.textContaining('Could not search'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'search retry');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('search-error')), findsNothing);
    expect(find.byKey(const ValueKey('search-results')), findsOneWidget);
    expect(data.searchCalls, 2);
  });

  testWidgets('a stale local failure cannot replace a newer query', (
    tester,
  ) async {
    final data = _ControlledSearchData();
    await tester.pumpWidget(_screen(data: data));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('search-field')), 'Cafe');
    await tester.pump(const Duration(milliseconds: 220));
    expect(data.pending, isNotNull);
    await tester.enterText(find.byKey(const ValueKey('search-field')), 'Other');
    data.pending!.completeError(StateError('must remain redacted'));
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.byKey(const ValueKey('search-error')), findsNothing);
  });

  testWidgets('TV Done and scope Select Escape and Down retain logical focus', (
    tester,
  ) async {
    await tester.pumpWidget(_screen(data: _FakeSearchData()));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('search-field')), 'Cafe');
    await tester.pump(const Duration(milliseconds: 220));
    await tester.pumpAndSettle();

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    for (var index = 0; index < 4; index++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    }
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'tv keyboard Space');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'tv keyboard Done');
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'search live-1');

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'search field');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'search scope');
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(find.text('All sources'), findsAtLeastNWidgets(1));
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'search scope');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'search field');
  });

  testWidgets(
    'same-query remount restores the session while a new query resets it',
    (tester) async {
      final controller = CatalogScopeController(port: _ScopePort());
      await controller.initialize();
      final session = LocalSearchSession()
        ..query = 'Cafe'
        ..scopeId = null
        ..focusedItemId = 'movie-1'
        ..items = _items
        ..total = 3;
      final data = _FakeSearchData();
      await tester.pumpWidget(
        _screen(data: data, controller: controller, session: session),
      );
      await tester.pumpAndSettle();
      expect(data.searchCalls, 0);
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'search movie-1');

      await tester.enterText(
        find.byKey(const ValueKey('search-field')),
        'Other',
      );
      await tester.pump(const Duration(milliseconds: 220));
      await tester.pumpAndSettle();
      expect(data.lastQuery, 'Other');
      expect(session.scrollOffset, 0);
      expect(session.focusedItemId, isNull);
      expect(session.items, _items);
    },
  );

  testWidgets(
    'Search stays inside the content plane at desktop and compact text scale',
    (tester) async {
      for (final size in [const Size(1265, 713), const Size(528, 713)]) {
        await tester.binding.setSurfaceSize(size);
        await tester.pumpWidget(
          _screen(
            data: _FakeSearchData(),
            textScaler: size.width < 600
                ? const TextScaler.linear(1.6)
                : TextScaler.noScaling,
          ),
        );
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const ValueKey('search-field')),
          'A very long Unicode Café series title used to verify constrained search layout',
        );
        await tester.pump(const Duration(milliseconds: 220));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.byKey(const ValueKey('search-results')), findsOneWidget);
      }
      addTearDown(() => tester.binding.setSurfaceSize(null));
    },
  );
  testWidgets('a full local page settles without a render loop', (
    tester,
  ) async {
    final data = _LargeSearchData();
    await tester.pumpWidget(_screen(data: data));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const ValueKey('search-field')),
      'Spider',
    );
    await tester.pump(const Duration(milliseconds: 220));
    await tester.pumpAndSettle();

    expect(data.searchCalls, 1);
    expect(find.byKey(const ValueKey('search-results')), findsOneWidget);
    expect(find.byKey(const ValueKey('search-item-large-0')), findsOneWidget);
  });

  testWidgets('the first result page is usable before its total finishes', (
    tester,
  ) async {
    final data = _DelayedCountSearchData();
    await tester.pumpWidget(_screen(data: data));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const ValueKey('search-field')),
      'Spider',
    );
    await tester.pump(const Duration(milliseconds: 220));
    await tester.pump();

    expect(find.byKey(const ValueKey('search-results')), findsOneWidget);
    expect(find.byKey(const ValueKey('search-item-live-1')), findsOneWidget);
    expect(find.text('Searching local library'), findsOneWidget);

    data.countCompleter.complete(318);
    await tester.pumpAndSettle();
    expect(find.text('318 results'), findsOneWidget);
  });

  testWidgets('a delayed total cannot return as stale remount state', (
    tester,
  ) async {
    final data = _DelayedCountSearchData();
    final session = LocalSearchSession()
      ..query = 'Spider'
      ..scopeId = null
      ..items = _items
      ..total = 999;

    await tester.pumpWidget(_screen(data: data, session: session));
    await tester.pumpAndSettle();
    expect(data.searchCalls, 1);
    expect(session.total, isNull);

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    await tester.pumpWidget(_screen(data: data, session: session));
    await tester.pump();

    expect(find.text('Searching local library'), findsOneWidget);
    expect(find.text('999 results'), findsNothing);
  });
}

Widget _screen({
  required LocalSearchData data,
  CatalogScopeController? controller,
  SearchItemActivated? onActivated,
  ValueChanged<PlaybackHandoff>? onHandoff,
  SeriesInfoLoader? seriesInfoLoader,
  LocalSearchSession? session,
  TextScaler textScaler = TextScaler.noScaling,
}) {
  final scopeController =
      controller ?? CatalogScopeController(port: _ScopePort());
  return MaterialApp(
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(textScaler: textScaler),
      child: child!,
    ),
    home: Scaffold(
      body: LocalSearchScreen(
        scopeController: scopeController,
        initialFocus: FocusNode(debugLabel: 'search field'),
        onContentFocus: (_) {},
        onOpenRail: () {},
        session: session ?? LocalSearchSession(),
        data: data,
        onItemActivated: onActivated,
        onPlaybackHandoff: onHandoff,
        seriesInfoLoader: seriesInfoLoader,
      ),
    ),
  );
}

class _FakeSearchData implements LocalSearchData {
  int searchCalls = 0;
  int countCalls = 0;
  String? lastQuery;
  LibraryScope? lastScope;

  @override
  Future<int> count({
    required String query,
    required LibraryScope scope,
  }) async {
    countCalls++;
    return 3;
  }

  @override
  Future<PersistedSource?> loadReadySourceById(String sourceId) async => null;

  @override
  Future<LibraryPage> searchPage({
    required String query,
    required LibraryScope scope,
    BrowseCursor? cursor,
    int limit = 100,
  }) async {
    searchCalls++;
    lastQuery = query;
    lastScope = scope;
    return LibraryPage(items: _items, nextCursor: null);
  }
}

class _LargeSearchData implements LocalSearchData {
  int searchCalls = 0;

  @override
  Future<int> count({
    required String query,
    required LibraryScope scope,
  }) async => 318;

  @override
  Future<PersistedSource?> loadReadySourceById(String sourceId) async => null;

  @override
  Future<LibraryPage> searchPage({
    required String query,
    required LibraryScope scope,
    BrowseCursor? cursor,
    int limit = 100,
  }) async {
    searchCalls++;
    return LibraryPage(items: _largeItems, nextCursor: null);
  }
}

class _DelayedCountSearchData extends _FakeSearchData {
  final countCompleter = Completer<int>();

  @override
  Future<int> count({required String query, required LibraryScope scope}) =>
      countCompleter.future;
}

final _largeItems = List<LibraryCatalogItem>.generate(
  100,
  (index) => LibraryCatalogItem(
    libraryItemId: 'large-$index',
    catalogItemId: 'large-$index',
    sourceId: 'strong',
    sourceDisplayName: 'Strong',
    kind: SourceMediaKind.movies,
    title: 'Spider fixture $index',
    artworkLocator: null,
    playbackRef: '{"providerId":"$index","kind":"movies"}',
  ),
  growable: false,
);

class _ControlledSearchData implements LocalSearchData {
  Completer<LibraryPage>? pending;

  @override
  Future<int> count({
    required String query,
    required LibraryScope scope,
  }) async => 3;

  @override
  Future<PersistedSource?> loadReadySourceById(String sourceId) async => null;

  @override
  Future<LibraryPage> searchPage({
    required String query,
    required LibraryScope scope,
    BrowseCursor? cursor,
    int limit = 100,
  }) {
    pending = Completer<LibraryPage>();
    return pending!.future;
  }
}

class _SeriesSearchData extends _FakeSearchData {
  @override
  Future<PersistedSource?> loadReadySourceById(String sourceId) async =>
      PersistedSource(
        id: sourceId,
        name: 'Strong',
        credentialKey: 'test-source-$sourceId',
        counts: const {},
      );
}

class _FakeSeriesInfoLoader implements SeriesInfoLoader {
  String? loadedSourceId;

  @override
  void cancel() {}

  @override
  Future<SeriesInfo> load({
    required PersistedSource source,
    required BrowseCatalogItem series,
  }) async {
    loadedSourceId = source.id;
    return const SeriesInfo(
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
    );
  }
}

class _PagedSearchData implements LocalSearchData {
  var _failedOnce = false;

  @override
  Future<int> count({
    required String query,
    required LibraryScope scope,
  }) async => 2;

  @override
  Future<PersistedSource?> loadReadySourceById(String sourceId) async => null;

  @override
  Future<LibraryPage> searchPage({
    required String query,
    required LibraryScope scope,
    BrowseCursor? cursor,
    int limit = 100,
  }) async {
    if (cursor == null) {
      return LibraryPage(
        items: [_items[0]],
        nextCursor: BrowseCursor(normalizedTitle: 'cafe live', id: 'live-1'),
      );
    }
    if (!_failedOnce) {
      _failedOnce = true;
      throw StateError('local page unavailable');
    }
    return const LibraryPage(items: [_nextItem], nextCursor: null);
  }
}

class _FailsThenSucceedsSearchData implements LocalSearchData {
  int searchCalls = 0;

  @override
  Future<int> count({
    required String query,
    required LibraryScope scope,
  }) async => 1;

  @override
  Future<PersistedSource?> loadReadySourceById(String sourceId) async => null;

  @override
  Future<LibraryPage> searchPage({
    required String query,
    required LibraryScope scope,
    BrowseCursor? cursor,
    int limit = 100,
  }) async {
    searchCalls++;
    if (searchCalls == 1) throw StateError('database text must not render');
    return LibraryPage(items: [_items[0]], nextCursor: null);
  }
}

const _items = [
  LibraryCatalogItem(
    libraryItemId: 'live-1',
    catalogItemId: 'live-1',
    sourceId: 'strong',
    sourceDisplayName: 'Strong',
    kind: SourceMediaKind.live,
    title: 'Café Live',
    artworkLocator: null,
    playbackRef: '{"providerId":"1","kind":"live"}',
  ),
  LibraryCatalogItem(
    libraryItemId: 'movie-1',
    catalogItemId: 'movie-1',
    sourceId: 'backup',
    sourceDisplayName: 'M3U backup',
    kind: SourceMediaKind.movies,
    title: 'Café Movie',
    artworkLocator: null,
    playbackRef: '{"providerId":"2","kind":"movies"}',
  ),
  LibraryCatalogItem(
    libraryItemId: 'series-1',
    catalogItemId: 'series-1',
    sourceId: 'strong',
    sourceDisplayName: 'Strong',
    kind: SourceMediaKind.series,
    title: 'Café Series',
    artworkLocator: null,
    playbackRef: '{"providerId":"3","kind":"series"}',
  ),
];

const _nextItem = LibraryCatalogItem(
  libraryItemId: 'live-2',
  catalogItemId: 'live-2',
  sourceId: 'strong',
  sourceDisplayName: 'Strong',
  kind: SourceMediaKind.live,
  title: 'Next café result',
  artworkLocator: null,
  playbackRef: '{"providerId":"4","kind":"live"}',
);

class _ScopePort implements CatalogScopePort {
  LibraryScope _scope = const LibraryScope.all();
  List<SourceRosterEntry> sources = const [
    SourceRosterEntry(
      id: 'strong',
      name: 'Strong',
      kind: 'xtream',
      enabled: true,
      status: 'ready',
      counts: {},
    ),
    SourceRosterEntry(
      id: 'backup',
      name: 'M3U backup',
      kind: 'm3u_url',
      enabled: true,
      status: 'ready',
      counts: {},
    ),
  ];

  @override
  Future<LibraryScope> loadCatalogScope() async => _scope;

  @override
  Future<PersistedSource?> loadReadySourceById(String sourceId) async => null;

  @override
  Future<List<SourceRosterEntry>> loadSourceRoster() async => sources;

  @override
  Future<LibraryScope> saveCatalogScope(LibraryScope scope) async {
    _scope = scope;
    return scope;
  }
}
