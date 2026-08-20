import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wabbit_tv/src/features/artwork/source_artwork.dart';
import 'package:wabbit_tv/src/features/browse/basic_browse_screen.dart';
import 'package:wabbit_tv/src/features/browse/catalog_scope_controller.dart';
import 'package:wabbit_tv/src/features/browse/playback_handoff.dart';
import 'package:wabbit_tv/src/features/browse/series_info_loader.dart';
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
    expect(tester.widget<SourceArtwork>(artwork).loader, isNull);
    expect(tester.widget<SourceArtwork>(missingArtwork).loader, isNull);
    expect(tester.widget<SourceArtwork>(artwork).loadWhenVisible, isTrue);
    expect(
      tester.widget<SourceArtwork>(missingArtwork).loadWhenVisible,
      isTrue,
    );
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

  testWidgets('virtual browse rows retain focus nodes only while mounted', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(800, 520));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final session = BasicBrowseSession();
    await tester.pumpWidget(
      _screen(
        kind: SourceMediaKind.live,
        data: _FakeData.withItems(SourceMediaKind.live, 100),
        session: session,
      ),
    );
    await tester.pumpAndSettle();

    expect(session.mountedItemFocusCount, inInclusiveRange(1, 24));
    await tester.drag(
      find.byKey(const ValueKey('browse-items-live')),
      const Offset(0, -3200),
    );
    await tester.pumpAndSettle();

    expect(session.mountedItemFocusCount, inInclusiveRange(1, 24));
  });

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

  testWidgets(
    'confirmed All sources viewport is full width, counted, and source labeled',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1265, 713));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final fixture = _ScopeFixture(itemCount: 84_129);

      await tester.pumpWidget(_scopedScreen(fixture: fixture));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('catalog-scope-control')),
        findsOneWidget,
      );
      expect(find.text('All sources'), findsOneWidget);
      expect(find.text('84,129 available across 2 sources'), findsOneWidget);
      expect(find.text('Categories'), findsNothing);
      expect(find.text('SOURCE'), findsOneWidget);
      expect(find.text('Harbor North'), findsAtLeastNWidgets(1));
      expect(find.text('Weekend List'), findsAtLeastNWidgets(1));
      expect(fixture.scopedData.pageLimits, everyElement(100));
    },
  );

  testWidgets('named source keeps populated last-good rows while refreshing', (
    tester,
  ) async {
    final fixture = _ScopeFixture(
      initialScope: const LibraryScope.source('harbor'),
    );
    fixture.port.sources = [
      _scopeRoster('harbor', 'Harbor North', status: 'refreshing'),
      _scopeRoster('weekend', 'Weekend List'),
    ];

    await tester.pumpWidget(_scopedScreen(fixture: fixture));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('browse-item-harbor-0')), findsOneWidget);
    expect(
      find.text('Refreshing · showing saved catalog · 3 items · Harbor North'),
      findsOneWidget,
    );
    expect(find.text('Catalog unavailable'), findsNothing);
  });

  testWidgets('All sources quietly reports mixed last-good source status', (
    tester,
  ) async {
    final fixture = _ScopeFixture(itemCount: 150);
    fixture.port.sources = [
      _scopeRoster('harbor', 'Harbor North', status: 'refreshing'),
      _scopeRoster('weekend', 'Weekend List', status: 'refresh_failed'),
    ];

    await tester.pumpWidget(_scopedScreen(fixture: fixture));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('browse-item-library-0')), findsOneWidget);
    expect(
      find.text(
        '1 source refreshing · 1 source refresh failed · saved catalogs remain available · 150 available across 2 sources',
      ),
      findsOneWidget,
    );
    expect(find.text('Catalog unavailable'), findsNothing);
  });

  testWidgets('ready Browse scope does not show a last-good status signal', (
    tester,
  ) async {
    final fixture = _ScopeFixture();

    await tester.pumpWidget(_scopedScreen(fixture: fixture));
    await tester.pumpAndSettle();

    expect(find.textContaining('showing saved catalog'), findsNothing);
    expect(find.textContaining('refresh failed'), findsNothing);
    expect(find.textContaining('remains available'), findsNothing);
  });

  testWidgets('All-sources loading skeleton is one full-width panel', (
    tester,
  ) async {
    final fixture = _ScopeFixture();
    fixture.scopedData.pageGate = Completer<void>();

    await tester.pumpWidget(_scopedScreen(fixture: fixture));
    await tester.pump();
    await tester.pump();

    expect(find.byKey(const ValueKey('browse-skeleton-panel')), findsOneWidget);
    expect(find.text('Categories'), findsNothing);

    fixture.scopedData.pageGate!.complete();
    await tester.pumpAndSettle();
  });

  testWidgets('scope menu supports remote traversal, Escape, and mouse', (
    tester,
  ) async {
    final fixture = _ScopeFixture();
    await tester.pumpWidget(_scopedScreen(fixture: fixture));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('catalog-scope-control')));
    await tester.pump();
    expect(find.byKey(const ValueKey('catalog-scope-menu')), findsOneWidget);
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'catalog scope all');

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'catalog scope harbor',
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(fixture.controller.scope.sourceId, 'harbor');
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'catalog scope');

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(find.byKey(const ValueKey('catalog-scope-menu')), findsNothing);
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'catalog scope');

    await tester.tap(find.byKey(const ValueKey('catalog-scope-control')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('catalog-scope-All sources')));
    await tester.pumpAndSettle();
    expect(fixture.controller.scope.isAll, isTrue);
  });

  testWidgets('remote scope menu reveals sources beyond one viewport', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(800, 500));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final fixture = _ScopeFixture();
    fixture.port.sources = [
      for (var index = 0; index < 14; index++)
        _scopeRoster('source-$index', 'Source $index'),
    ];
    await tester.pumpWidget(_scopedScreen(fixture: fixture));
    await tester.pumpAndSettle();

    FocusManager.instance.primaryFocus?.unfocus();
    final scopeFocus = tester
        .widget<Focus>(
          find
              .ancestor(
                of: find.byKey(const ValueKey('catalog-scope-control')),
                matching: find.byType(Focus),
              )
              .first,
        )
        .focusNode!;
    scopeFocus.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();

    for (var index = 0; index < 10; index++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      await tester.pump();
    }

    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'catalog scope source-9',
    );
    final lateOption = tester.getRect(
      find.byKey(const ValueKey('catalog-scope-Source 9')),
    );
    expect(lateOption.top, greaterThanOrEqualTo(0));
    expect(lateOption.bottom, lessThanOrEqualTo(500));
  });

  testWidgets('remote moves content to scope, through menu, and back', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(800, 600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final fixture = _ScopeFixture();
    await tester.pumpWidget(_scopedScreen(fixture: fixture));
    await tester.pumpAndSettle();
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'scoped browse initial',
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'catalog scope');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(fixture.controller.scope.sourceId, 'harbor');
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'catalog scope');

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'browse category 0');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'scoped browse initial',
    );
  });

  testWidgets(
    'named scope restores categories while unified source labels disappear',
    (tester) async {
      final fixture = _ScopeFixture();
      await tester.pumpWidget(_scopedScreen(fixture: fixture));
      await tester.pumpAndSettle();
      expect(find.text('SOURCE'), findsOneWidget);

      await fixture.controller.select(const LibraryScope.source('harbor'));
      await tester.pumpAndSettle();

      expect(find.text('Categories'), findsOneWidget);
      expect(find.text('News'), findsOneWidget);
      expect(find.text('SOURCE'), findsNothing);
      expect(find.text('3 items · Harbor North'), findsOneWidget);
      expect(find.text('Harbor North'), findsOneWidget);
    },
  );

  testWidgets('named header uses the visibility-aware local library total', (
    tester,
  ) async {
    final fixture = _ScopeFixture();
    fixture.scopedData.namedTotal = 1;
    await tester.pumpWidget(_scopedScreen(fixture: fixture));
    await tester.pumpAndSettle();

    await fixture.controller.select(const LibraryScope.source('harbor'));
    await tester.pumpAndSettle();

    expect(find.text('1 items · Harbor North'), findsOneWidget);
    expect(find.text('3 items · Harbor North'), findsNothing);
  });

  testWidgets('late named-source resolution cannot overwrite a newer scope', (
    tester,
  ) async {
    final fixture = _ScopeFixture(
      initialScope: const LibraryScope.source('harbor'),
    );
    final delayedHarbor = Completer<PersistedSource?>();
    fixture.port.resolveGates['harbor'] = delayedHarbor;
    await tester.pumpWidget(_scopedScreen(fixture: fixture));
    await tester.pump();
    await tester.pump();
    expect(fixture.port.resolveRequests, ['harbor']);

    await fixture.controller.select(const LibraryScope.all());
    await tester.pumpAndSettle();
    expect(find.text('150 available across 2 sources'), findsOneWidget);
    expect(find.text('Unified title 0'), findsOneWidget);
    expect(find.text('Categories'), findsNothing);

    delayedHarbor.complete(fixture.port.readySource('harbor'));
    await tester.pumpAndSettle();

    expect(fixture.controller.scope.isAll, isTrue);
    expect(find.text('150 available across 2 sources'), findsOneWidget);
    expect(find.text('Unified title 0'), findsOneWidget);
    expect(find.text('3 items · Harbor North'), findsNothing);
    expect(find.text('Categories'), findsNothing);
  });

  testWidgets('disabled selected source falls back and announces', (
    tester,
  ) async {
    final fixture = _ScopeFixture(
      initialScope: const LibraryScope.source('harbor'),
    );
    await tester.pumpWidget(_scopedScreen(fixture: fixture));
    await tester.pumpAndSettle();
    expect(find.text('Categories'), findsOneWidget);

    fixture.port
      ..sources = fixture.port.sources
          .where((source) => source.id != 'harbor')
          .toList()
      ..scope = const LibraryScope.all();
    await fixture.controller.refresh();
    await tester.pumpAndSettle();

    expect(fixture.controller.scope.isAll, isTrue);
    expect(
      find.text('Source unavailable. Showing All sources.'),
      findsOneWidget,
    );
    expect(find.text('Categories'), findsNothing);
  });

  testWidgets('All scope refresh replaces cached rows from removed sources', (
    tester,
  ) async {
    final fixture = _ScopeFixture();
    BrowseCatalogItem? activated;
    await tester.pumpWidget(
      _scopedScreen(fixture: fixture, onActivated: (item) => activated = item),
    );
    await tester.pumpAndSettle();
    expect(find.text('Weekend List'), findsAtLeastNWidgets(1));
    final initialPageCalls = fixture.scopedData.pageLimits.length;

    final refreshPage = Completer<void>();
    fixture.scopedData.pageGate = refreshPage;
    fixture.port.sources = fixture.port.sources
        .where((source) => source.id != 'weekend')
        .toList();
    fixture.scopedData.includeWeekend = false;
    await fixture.controller.refresh();
    await tester.pump();
    await tester.pump();

    expect(find.byKey(const ValueKey('browse-skeleton-panel')), findsOneWidget);
    expect(find.text('Weekend List'), findsNothing);
    expect(find.byKey(const ValueKey('browse-item-library-1')), findsNothing);
    expect(activated, isNull);

    refreshPage.complete();
    await tester.pumpAndSettle();

    expect(fixture.controller.scope.isAll, isTrue);
    expect(fixture.scopedData.pageLimits.length, greaterThan(initialPageCalls));
    expect(find.text('Weekend List'), findsNothing);
    expect(find.text('Harbor North'), findsAtLeastNWidgets(1));
  });

  testWidgets('remount refreshes a session bookmark from an older revision', (
    tester,
  ) async {
    final fixture = _ScopeFixture();
    final session = BasicBrowseSession();
    await tester.pumpWidget(_scopedScreen(fixture: fixture, session: session));
    await tester.pumpAndSettle();
    expect(find.text('Weekend List'), findsAtLeastNWidgets(1));

    await tester.pumpWidget(const SizedBox.shrink());
    fixture.port.sources = fixture.port.sources
        .where((source) => source.id != 'weekend')
        .toList();
    fixture.scopedData.includeWeekend = false;
    await fixture.controller.refresh();
    final remountPage = Completer<void>();
    fixture.scopedData.pageGate = remountPage;

    await tester.pumpWidget(_scopedScreen(fixture: fixture, session: session));
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const ValueKey('browse-skeleton-panel')), findsOneWidget);
    expect(find.text('Weekend List'), findsNothing);

    remountPage.complete();
    await tester.pumpAndSettle();
    expect(find.text('Weekend List'), findsNothing);
    expect(find.text('Harbor North'), findsAtLeastNWidgets(1));
  });

  testWidgets('same-revision remount restores its scoped session bookmark', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(800, 600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final fixture = _ScopeFixture(itemCount: 150);
    final session = BasicBrowseSession();
    await tester.pumpWidget(_scopedScreen(fixture: fixture, session: session));
    await tester.pumpAndSettle();
    final lateRow = find.byKey(const ValueKey('browse-item-library-120'));
    await tester.scrollUntilVisible(
      lateRow,
      420,
      scrollable: find.descendant(
        of: find.byKey(const ValueKey('browse-items-live')),
        matching: find.byType(Scrollable),
      ),
    );
    await tester.tap(lateRow);
    final pageCalls = fixture.scopedData.pageLimits.length;

    await tester.pumpWidget(const SizedBox.shrink());
    final unexpectedPage = Completer<void>();
    fixture.scopedData.pageGate = unexpectedPage;
    await tester.pumpWidget(_scopedScreen(fixture: fixture, session: session));
    await tester.pump();
    await tester.pump();
    await tester.pump();

    expect(fixture.scopedData.pageLimits.length, pageCalls);
    expect(lateRow, findsOneWidget);
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'browse live library-120',
    );
    unexpectedPage.complete();
  });

  testWidgets('failed-refresh last-good source remains selectable', (
    tester,
  ) async {
    final fixture = _ScopeFixture();
    fixture.port.sources = [
      _scopeRoster('harbor', 'Harbor North', status: 'refresh_failed'),
    ];
    await tester.pumpWidget(_scopedScreen(fixture: fixture));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('catalog-scope-control')));
    await tester.pump();
    expect(
      find.byKey(const ValueKey('catalog-scope-All sources')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('catalog-scope-Harbor North')),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const ValueKey('catalog-scope-Harbor North')));
    await tester.pumpAndSettle();
    expect(fixture.controller.scope.sourceId, 'harbor');
    expect(find.text('Categories'), findsOneWidget);
    expect(find.byKey(const ValueKey('browse-item-harbor-0')), findsOneWidget);
    expect(
      find.text(
        'Refresh failed · showing saved catalog · 3 items · Harbor North',
      ),
      findsOneWidget,
    );
    expect(find.text('Catalog unavailable'), findsNothing);
  });

  testWidgets('All scope activation carries the selected playable variant', (
    tester,
  ) async {
    final fixture = _ScopeFixture();
    BrowseCatalogItem? activated;
    await tester.pumpWidget(
      _scopedScreen(fixture: fixture, onActivated: (item) => activated = item),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('browse-item-library-0')));

    expect(activated?.sourceId, 'harbor');
    expect(activated?.libraryItemId, 'library-0');
    expect(activated?.playbackRef, contains('providerId'));
  });

  testWidgets('All-sources Series detail resolves the chosen item source', (
    tester,
  ) async {
    final fixture = _ScopeFixture();
    final loader = _CapturingSeriesLoader();
    await tester.pumpWidget(
      _scopedScreen(
        fixture: fixture,
        kind: SourceMediaKind.series,
        seriesInfoLoader: loader,
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('browse-item-library-0')));
    await tester.pumpAndSettle();

    expect(loader.sourceId, 'harbor');
  });

  testWidgets('Series source resolution failure stays actionable', (
    tester,
  ) async {
    final fixture = _ScopeFixture();
    final gate = Completer<PersistedSource?>();
    fixture.port.resolveGates['harbor'] = gate;
    await tester.pumpWidget(
      _scopedScreen(
        fixture: fixture,
        kind: SourceMediaKind.series,
        seriesInfoLoader: _CapturingSeriesLoader(),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('browse-item-library-0')));
    await tester.pump();
    expect(find.text('Loading episodes…'), findsOneWidget);

    gate.complete(null);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('series-error-copy')), findsOneWidget);
    expect(find.byKey(const ValueKey('series-retry')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('continuation-visible-back')),
      findsOneWidget,
    );
  });

  testWidgets('scope header fits a 480px shell content width and large text', (
    tester,
  ) async {
    // WabbitShell reserves its fixed 72 px rail from a 480 px window.
    await tester.binding.setSurfaceSize(const Size(408, 600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final fixture = _ScopeFixture(
      initialScope: const LibraryScope.source('harbor'),
      longNames: true,
    );
    await tester.pumpWidget(
      _scopedScreen(fixture: fixture, textScaler: const TextScaler.linear(1.6)),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('catalog-scope-control')), findsOneWidget);
    expect(find.text('Categories'), findsOneWidget);
    final layoutError = tester.takeException();
    if (layoutError is FlutterError) {
      fail(layoutError.toDiagnosticsNode().toStringDeep());
    }
    expect(layoutError, isNull);
    final scopeRect = tester.getRect(
      find.byKey(const ValueKey('catalog-scope-control')),
    );
    expect(scopeRect.right, lessThanOrEqualTo(408));
  });

  testWidgets('session restores a deep row independently for each scope', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(800, 600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final fixture = _ScopeFixture(itemCount: 150);
    final session = BasicBrowseSession();
    await tester.pumpWidget(_scopedScreen(fixture: fixture, session: session));
    await tester.pumpAndSettle();

    final lateAll = find.byKey(const ValueKey('browse-item-library-120'));
    await tester.scrollUntilVisible(
      lateAll,
      420,
      scrollable: find.descendant(
        of: find.byKey(const ValueKey('browse-items-live')),
        matching: find.byType(Scrollable),
      ),
    );
    await tester.tap(lateAll);

    await fixture.controller.select(const LibraryScope.source('harbor'));
    await tester.pumpAndSettle();
    final namedScrollable = tester.state<ScrollableState>(
      find
          .descendant(
            of: find.byKey(const ValueKey('browse-items-live')),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    expect(namedScrollable.position.pixels, lessThanOrEqualTo(1));
    await fixture.controller.select(const LibraryScope.all());
    await tester.pump();
    await tester.pump();
    await tester.pumpAndSettle();

    expect(lateAll, findsOneWidget);
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'browse live library-120',
    );
  });
}

Widget _scopedScreen({
  required _ScopeFixture fixture,
  BrowseItemActivated? onActivated,
  BasicBrowseSession? session,
  TextScaler textScaler = TextScaler.noScaling,
  SourceMediaKind kind = SourceMediaKind.live,
  SeriesInfoLoader? seriesInfoLoader,
}) {
  final focus = FocusNode(debugLabel: 'scoped browse initial');
  return MaterialApp(
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(textScaler: textScaler),
      child: child!,
    ),
    home: Scaffold(
      body: BasicBrowseScreen(
        kind: kind,
        source: null,
        data: fixture.namedData,
        scopedData: fixture.scopedData,
        scopeController: fixture.controller,
        session: session ?? BasicBrowseSession(),
        initialFocus: focus,
        onContentFocus: (_) {},
        onOpenRail: () {},
        onOpenSourceSetup: () {},
        onItemActivated: onActivated,
        seriesInfoLoader: seriesInfoLoader,
      ),
    ),
  );
}

class _ScopeFixture {
  _ScopeFixture({
    int itemCount = 150,
    LibraryScope initialScope = const LibraryScope.all(),
    bool longNames = false,
  }) : port = _BrowseScopePort(
         scope: initialScope,
         sources: [
           _scopeRoster(
             'harbor',
             longNames
                 ? 'Harbor North ${'Extremely Long Local Source Name ' * 4}'
                 : 'Harbor North',
           ),
           _scopeRoster('weekend', 'Weekend List'),
         ],
       ),
       scopedData = _ScopedData(itemCount),
       namedData = _NamedScopeData() {
    controller = CatalogScopeController(port: port);
  }

  final _BrowseScopePort port;
  final _ScopedData scopedData;
  final _NamedScopeData namedData;
  late final CatalogScopeController controller;
}

SourceRosterEntry _scopeRoster(
  String id,
  String name, {
  String status = 'ready',
}) => SourceRosterEntry(
  id: id,
  name: name,
  kind: 'xtream',
  enabled: true,
  status: status,
  counts: const {
    SourceMediaKind.live: 3,
    SourceMediaKind.movies: 0,
    SourceMediaKind.series: 0,
  },
);

class _BrowseScopePort implements CatalogScopePort {
  _BrowseScopePort({required this.sources, required this.scope});

  List<SourceRosterEntry> sources;
  LibraryScope scope;
  final Map<String, Completer<PersistedSource?>> resolveGates = {};
  final List<String> resolveRequests = [];

  @override
  Future<LibraryScope> loadCatalogScope() async => scope;

  @override
  Future<PersistedSource?> loadReadySourceById(String sourceId) async {
    resolveRequests.add(sourceId);
    final gate = resolveGates[sourceId];
    if (gate != null) return gate.future;
    return readySource(sourceId);
  }

  PersistedSource? readySource(String sourceId) {
    final matches = sources.where((source) => source.id == sourceId);
    if (matches.isEmpty) return null;
    final source = matches.single;
    return PersistedSource(
      id: source.id,
      name: source.name,
      credentialKey: '${source.id}-key',
      counts: source.counts,
    );
  }

  @override
  Future<List<SourceRosterEntry>> loadSourceRoster() async => sources;

  @override
  Future<LibraryScope> saveCatalogScope(LibraryScope requested) async {
    final sourceId = requested.sourceId;
    scope = sourceId == null || sources.any((source) => source.id == sourceId)
        ? requested
        : const LibraryScope.all();
    return scope;
  }
}

class _ScopedData implements ScopedBrowseData {
  _ScopedData(this.total);

  final int total;
  final List<int> pageLimits = [];
  Completer<void>? pageGate;
  int namedTotal = 3;
  bool includeWeekend = true;

  int get materialized => total.clamp(3, 150);

  @override
  Future<LibraryPage> browseLibraryPage({
    required LibraryScope scope,
    required SourceMediaKind kind,
    BrowseCursor? cursor,
    int limit = 100,
  }) async {
    pageLimits.add(limit);
    await pageGate?.future;
    final availableIndexes = [
      for (var index = 0; index < materialized; index++)
        if (includeWeekend || index.isEven) index,
    ];
    final cursorIndex = cursor == null
        ? null
        : int.parse(cursor.id.split('-').last);
    final start = cursorIndex == null
        ? 0
        : availableIndexes.indexWhere((index) => index == cursorIndex) + 1;
    final end = (start + limit).clamp(0, availableIndexes.length);
    final items = [
      for (final index in availableIndexes.sublist(start, end))
        LibraryCatalogItem(
          libraryItemId: 'library-$index',
          catalogItemId: 'catalog-$index',
          sourceId: index.isEven ? 'harbor' : 'weekend',
          sourceDisplayName: index.isEven ? 'Harbor North' : 'Weekend List',
          kind: kind,
          title: 'Unified title $index',
          artworkLocator: null,
          playbackRef: playbackReference({
            'providerId': '$index',
            'kind': kind.name,
          }),
        ),
    ];
    return LibraryPage(
      items: items,
      nextCursor: end >= availableIndexes.length
          ? null
          : BrowseCursor(
              normalizedTitle: 'title ${availableIndexes[end - 1]}',
              id: 'library-${availableIndexes[end - 1]}',
            ),
    );
  }

  @override
  Future<int> countLibraryItems({
    required LibraryScope scope,
    required SourceMediaKind kind,
  }) async => scope.isAll ? total : namedTotal;
}

class _NamedScopeData implements BasicBrowseData {
  @override
  Future<List<BrowseCategorySummary>> browseCategories({
    required String sourceId,
    required SourceMediaKind kind,
  }) async => [
    BrowseCategorySummary(
      selection: const BrowseCategorySelection.all(),
      name: 'All ${kind.label}',
      itemCount: 3,
    ),
    const BrowseCategorySummary(
      selection: BrowseCategorySelection.sourceGroup(1),
      name: 'News',
      itemCount: 3,
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
    items: [
      for (var index = 0; index < 3; index++)
        BrowseCatalogItem(
          id: '$sourceId-$index',
          sourceId: sourceId,
          kind: kind,
          title: 'Named title $index',
          artworkLocator: null,
          playbackRef: playbackReference({
            'providerId': '$index',
            'kind': kind.name,
          }),
        ),
    ],
    nextCursor: null,
  );
}

class _CapturingSeriesLoader implements SeriesInfoLoader {
  String? sourceId;

  @override
  void cancel() {}

  @override
  Future<SeriesInfo> load({
    required PersistedSource source,
    required BrowseCatalogItem series,
  }) async {
    sourceId = source.id;
    return const SeriesInfo(seasons: []);
  }
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
