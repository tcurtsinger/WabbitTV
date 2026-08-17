import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wabbit_tv/src/features/browse/basic_browse_screen.dart';
import 'package:wabbit_tv/src/features/sources/source_catalog_database.dart';
import 'package:wabbit_tv/src/features/sources/source_models.dart';

void main() {
  testWidgets('shows compact categories and title rows for every browse kind', (
    tester,
  ) async {
    for (final kind in SourceMediaKind.values) {
      await tester.pumpWidget(_screen(kind: kind));
      await tester.pumpAndSettle();

      expect(find.text(kind.label), findsAtLeastNWidgets(1));
      expect(find.text('All ${kind.label}'), findsAtLeastNWidgets(1));
      expect(find.text('${kind.label} first'), findsOneWidget);
      expect(find.byKey(ValueKey('browse-items-${kind.name}')), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    }
  });

  testWidgets(
    'category, keyboard, mouse, and bounded next page share one row action',
    (tester) async {
      final data = _FakeData.withItems(SourceMediaKind.live, 101);
      BrowseCatalogItem? activated;
      await tester.pumpWidget(
        _screen(
          kind: SourceMediaKind.live,
          data: data,
          onActivated: (item) => activated = item,
        ),
      );
      await tester.pumpAndSettle();

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pump();
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'browse category 0',
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(find.text('News'), findsAtLeastNWidgets(1));

      await tester.tap(find.byKey(const ValueKey('browse-item-live-0')));
      expect(activated?.id, 'live-0');

      await tester.drag(
        find.byKey(const ValueKey('browse-items-live')),
        const Offset(0, -9000),
      );
      await tester.pumpAndSettle();
      expect(data.pageCalls, greaterThan(1));
    },
  );

  testWidgets('narrow layout uses an Escape-dismissible Categories overlay', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(600, 713));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(_screen(kind: SourceMediaKind.movies));
    await tester.pumpAndSettle();

    expect(find.text('Categories'), findsOneWidget);
    await tester.tap(find.text('Categories'));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('browse-category-overlay')),
      findsOneWidget,
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('browse-category-overlay')), findsNothing);
  });

  testWidgets('no-source and query error states stay redacted and actionable', (
    tester,
  ) async {
    await tester.pumpWidget(
      _screen(kind: SourceMediaKind.series, source: null),
    );
    expect(find.text('No source ready'), findsOneWidget);
    final addSource = find.byKey(const ValueKey('browse-action-Add source'));
    final addSourceDecoration =
        tester.widget<Container>(addSource).decoration! as BoxDecoration;
    expect(addSourceDecoration.color, const Color(0xFFFFB347));
    await tester.pumpWidget(const SizedBox.shrink());

    await tester.pumpWidget(
      _screen(kind: SourceMediaKind.series, data: const _FailingData()),
    );
    await tester.pumpAndSettle();
    expect(find.text('Catalog unavailable'), findsOneWidget);
    expect(find.textContaining('provider.example'), findsNothing);
    final retry = find.byKey(const ValueKey('browse-action-Try again'));
    final retryDecoration =
        tester.widget<Container>(retry).decoration! as BoxDecoration;
    expect(retryDecoration.color, const Color(0xFF191A1A));
  });

  testWidgets('launcher and no-source actions activate through remote keys', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(600, 713));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(_screen(kind: SourceMediaKind.movies));
    await tester.pumpAndSettle();
    final categoryAction = find.byKey(
      const ValueKey('browse-action-Categories'),
    );
    tester
        .widget<Focus>(
          find.ancestor(of: categoryAction, matching: find.byType(Focus)).first,
        )
        .focusNode!
        .requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('browse-category-overlay')),
      findsOneWidget,
    );
    // Flutter's Android test key map has no BrowserBack physical key; Escape
    // exercises the same overlay dismissal path here.
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('browse-category-overlay')), findsNothing);

    var opened = 0;
    await tester.pumpWidget(
      _screen(
        kind: SourceMediaKind.live,
        source: null,
        onOpenSource: () => opened++,
      ),
    );
    final action = find.byKey(const ValueKey('browse-action-Add source'));
    tester
        .widget<Focus>(
          find.ancestor(of: action, matching: find.byType(Focus)).first,
        )
        .focusNode!
        .requestFocus();
    await tester.pump();
    final focusedAddSource =
        tester.widget<Container>(action).decoration! as BoxDecoration;
    expect(
      (focusedAddSource.border! as Border).top.color,
      const Color(0xFFF4F0E7),
    );
    expect((focusedAddSource.border! as Border).top.width, 2);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    expect(opened, 1);
  });

  testWidgets('next-page failure leaves loaded titles visible', (tester) async {
    await tester.pumpWidget(
      _screen(kind: SourceMediaKind.live, data: _FailAfterFirstPageData()),
    );
    await tester.pumpAndSettle();
    await tester.drag(
      find.byKey(const ValueKey('browse-items-live')),
      const Offset(0, -9000),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('browse-items-live')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('browse-next-page-error')),
      findsOneWidget,
    );
  });

  testWidgets('long title and missing art stay in the 1265px directory', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1265, 713));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(_screen(kind: SourceMediaKind.series));
    await tester.pumpAndSettle();
    final row = tester.getRect(
      find.byKey(const ValueKey('browse-item-series-2')),
    );
    expect(row.right, lessThanOrEqualTo(1265));
    expect(find.byIcon(Icons.tv_outlined), findsAtLeastNWidgets(1));
  });

  testWidgets('thumbnails stay fixed, neutral, and code-native', (
    tester,
  ) async {
    await tester.pumpWidget(_screen(kind: SourceMediaKind.movies));
    await tester.pumpAndSettle();

    final artwork = find.byKey(const ValueKey('browse-artwork-movies-0'));
    final missingArtwork = find.byKey(
      const ValueKey('browse-artwork-movies-1'),
    );
    expect(artwork, findsOneWidget);
    expect(missingArtwork, findsOneWidget);
    expect(tester.getSize(artwork), const Size(50, 36));
    expect(tester.getSize(missingArtwork), const Size(50, 36));
    final remoteDecoration =
        tester.widget<Container>(artwork).decoration! as BoxDecoration;
    final missingDecoration =
        tester.widget<Container>(missingArtwork).decoration! as BoxDecoration;
    expect(remoteDecoration.color, const Color(0xFF222321));
    expect(missingDecoration.color, const Color(0xFF222321));
    expect(find.byType(Image), findsNothing);
    expect(find.byIcon(Icons.movie_outlined), findsAtLeastNWidgets(1));
  });

  testWidgets(
    'keyboard title focus scrolls across virtual-list cache boundaries',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(800, 600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        _screen(
          kind: SourceMediaKind.live,
          data: _FakeData.withItems(SourceMediaKind.live, 150),
        ),
      );
      await tester.pumpAndSettle();

      for (var index = 0; index < 16; index++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.pump();
        await tester.pump();
      }

      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'browse live live-16',
      );
      final row = tester.getRect(
        find.byKey(const ValueKey('browse-item-live-16')),
      );
      expect(row.top, greaterThanOrEqualTo(0));
      expect(row.bottom, lessThanOrEqualTo(600));
    },
  );

  testWidgets(
    'wide category focus scrolls across virtual-list cache boundaries',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(800, 600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        _screen(
          kind: SourceMediaKind.live,
          data: _ManyCategoryData(SourceMediaKind.live),
        ),
      );
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pumpAndSettle();

      for (var index = 0; index < 16; index++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.pump();
        await tester.pump();
      }

      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'browse category 16',
      );
      final category = tester.getRect(find.text('Group 16'));
      expect(category.top, greaterThanOrEqualTo(0));
      expect(category.bottom, lessThanOrEqualTo(600));
    },
  );

  testWidgets(
    'narrow category overlay focus scrolls across virtual-list cache boundaries',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(600, 600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        _screen(
          kind: SourceMediaKind.live,
          data: _ManyCategoryData(SourceMediaKind.live),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Categories'));
      await tester.pumpAndSettle();

      for (var index = 0; index < 16; index++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.pump();
        await tester.pump();
      }

      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'browse category 16',
      );
      final category = tester.getRect(find.text('Group 16'));
      expect(category.top, greaterThanOrEqualTo(0));
      expect(category.bottom, lessThanOrEqualTo(600));
    },
  );

  testWidgets('deep browse remount restores its visible late row and focus', (
    tester,
  ) async {
    final session = BasicBrowseSession();
    final data = _FakeData.withItems(SourceMediaKind.live, 150);
    final initialFocus = FocusNode(debugLabel: 'browse restore initial');
    addTearDown(initialFocus.dispose);
    await tester.pumpWidget(
      _screen(
        kind: SourceMediaKind.live,
        data: data,
        session: session,
        initialFocus: initialFocus,
      ),
    );
    await tester.pumpAndSettle();
    final lateRow = find.byKey(const ValueKey('browse-item-live-149'));
    await tester.scrollUntilVisible(
      lateRow,
      420,
      scrollable: find.descendant(
        of: find.byKey(const ValueKey('browse-items-live')),
        matching: find.byType(Scrollable),
      ),
    );
    await tester.tap(lateRow);
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'browse live live-149',
    );
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(
      _screen(
        kind: SourceMediaKind.live,
        data: data,
        session: session,
        initialFocus: initialFocus,
      ),
    );
    await tester.pump();
    await tester.pump();
    await tester.pumpAndSettle();
    expect(lateRow, findsOneWidget);
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'browse live live-149',
    );
  });
}

Widget _screen({
  required SourceMediaKind kind,
  BasicBrowseData? data,
  PersistedSource? source = _source,
  BrowseItemActivated? onActivated,
  VoidCallback? onOpenSource,
  BasicBrowseSession? session,
  FocusNode? initialFocus,
}) {
  final focus = initialFocus ?? FocusNode(debugLabel: 'browse initial');
  return MaterialApp(
    home: Scaffold(
      body: BasicBrowseScreen(
        kind: kind,
        source: source,
        data: data ?? _FakeData.withItems(kind, 3),
        session: session ?? BasicBrowseSession(),
        initialFocus: focus,
        onContentFocus: (_) {},
        onOpenRail: () {},
        onOpenSourceSetup: onOpenSource ?? () {},
        onItemActivated: onActivated,
      ),
    ),
  );
}

const _source = PersistedSource(
  id: 'fixture',
  name: 'Fixture source',
  credentialKey: 'fixture-key',
  counts: {
    SourceMediaKind.live: 101,
    SourceMediaKind.movies: 101,
    SourceMediaKind.series: 101,
  },
);

class _FakeData implements BasicBrowseData {
  _FakeData.withItems(this.kind, int count)
    : _items = [
        for (var index = 0; index < count; index++)
          BrowseCatalogItem(
            id: '${kind.name}-$index',
            sourceId: 'fixture',
            kind: kind,
            title: index == 2
                ? '${kind.label} ${'very long provider title ' * 8}'
                : '${kind.label} ${index == 0 ? 'first' : 'item $index'}',
            artworkLocator: index == 0
                ? 'https://provider.example/poster.jpg'
                : null,
            playbackRef: playbackReference({
              'providerId': '$index',
              'kind': kind.name,
            }),
          ),
      ];

  final SourceMediaKind kind;
  final List<BrowseCatalogItem> _items;
  int pageCalls = 0;

  @override
  Future<List<BrowseCategorySummary>> browseCategories({
    required String sourceId,
    required SourceMediaKind kind,
  }) async => [
    BrowseCategorySummary(
      selection: const BrowseCategorySelection.all(),
      name: 'All ${kind.label}',
      itemCount: _items.length,
    ),
    BrowseCategorySummary(
      selection: const BrowseCategorySelection.sourceGroup(1),
      name: 'News',
      itemCount: _items.length,
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
    pageCalls++;
    final start = cursor == null ? 0 : int.parse(cursor.id.split('-').last) + 1;
    final end = (start + limit).clamp(0, _items.length);
    final page = _items.sublist(start, end);
    return BrowsePage(
      items: page,
      nextCursor: end == _items.length
          ? null
          : BrowseCursor(normalizedTitle: 'fixture', id: _items[end - 1].id),
    );
  }
}

class _FailingData implements BasicBrowseData {
  const _FailingData();

  @override
  Future<List<BrowseCategorySummary>> browseCategories({
    required String sourceId,
    required SourceMediaKind kind,
  }) => Future.error(StateError('https://provider.example/secret'));

  @override
  Future<BrowsePage> browsePage({
    required String sourceId,
    required SourceMediaKind kind,
    required BrowseCategorySelection selection,
    BrowseCursor? cursor,
    int limit = 100,
  }) => Future.error(StateError('https://provider.example/secret'));
}

class _FailAfterFirstPageData extends _FakeData {
  _FailAfterFirstPageData() : super.withItems(SourceMediaKind.live, 101);

  @override
  Future<BrowsePage> browsePage({
    required String sourceId,
    required SourceMediaKind kind,
    required BrowseCategorySelection selection,
    BrowseCursor? cursor,
    int limit = 100,
  }) {
    if (cursor != null) return Future.error(StateError('local query failure'));
    return super.browsePage(
      sourceId: sourceId,
      kind: kind,
      selection: selection,
      cursor: cursor,
      limit: limit,
    );
  }
}

class _ManyCategoryData extends _FakeData {
  _ManyCategoryData(SourceMediaKind kind) : super.withItems(kind, 150);

  @override
  Future<List<BrowseCategorySummary>> browseCategories({
    required String sourceId,
    required SourceMediaKind kind,
  }) async => [
    BrowseCategorySummary(
      selection: const BrowseCategorySelection.all(),
      name: 'All ${kind.label}',
      itemCount: 150,
    ),
    for (var index = 1; index <= 20; index++)
      BrowseCategorySummary(
        selection: BrowseCategorySelection.sourceGroup(index),
        name: 'Group $index',
        itemCount: 150,
      ),
  ];
}
