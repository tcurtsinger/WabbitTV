import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wabbit_tv/src/app_shell.dart';
import 'package:wabbit_tv/src/features/browse/basic_browse_screen.dart';
import 'package:wabbit_tv/src/features/browse/catalog_scope_controller.dart';
import 'package:wabbit_tv/src/features/search/local_search_screen.dart';
import 'package:wabbit_tv/src/features/sources/library_visibility_screen.dart';
import 'package:wabbit_tv/src/features/sources/source_catalog_database.dart';
import 'package:wabbit_tv/src/features/sources/source_management_screen.dart';
import 'package:wabbit_tv/src/features/sources/source_models.dart';
import 'package:wabbit_tv/src/home_fixture_mode.dart';

void main() {
  testWidgets(
    'Settings visibility returns to its source and refreshes Browse and Search',
    (tester) async {
      final visibility = _VisibilityPort();
      final scopePort = _ScopePort();
      final scope = CatalogScopeController(port: scopePort);
      final management = SourceManagementController(port: _ManagementPort());
      addTearDown(scope.dispose);
      await tester.binding.setSurfaceSize(const Size(1265, 713));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      Widget shell(ShellDestination destination) => MaterialApp(
        home: WabbitShell(
          key: ValueKey(destination),
          fixtureMode: HomeFixtureMode.noPersonalization,
          initialDestination: destination,
          sourceManagementController: management,
          catalogScopeController: scope,
          libraryVisibilityPort: visibility,
          scopedBrowseData: _VisibleCatalog(visibility),
          localSearchData: _VisibleCatalog(visibility),
        ),
      );

      await tester.pumpWidget(shell(ShellDestination.settings));
      await tester.pumpAndSettle();

      await tester.tap(
        find.byKey(const ValueKey('source-action-Manage visibility')),
      );
      await tester.pumpAndSettle();
      expect(find.text('Manage visibility'), findsOneWidget);
      expect(
        find.textContaining('Strong · Local visibility only'),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const ValueKey('visibility-item-news-one')));
      await tester.pumpAndSettle();
      expect(visibility.itemChanges, [('strong', 'news-one', true)]);
      expect(visibility.sourceIds, everyElement('strong'));

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'library visibility category 7',
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.text('Sources'), findsOneWidget);
      expect(scopePort.rosterLoads, greaterThanOrEqualTo(2));
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'source management manage visibility',
      );

      await tester.pumpWidget(shell(ShellDestination.live));
      await tester.pumpAndSettle();
      expect(find.text('News One'), findsNothing);
      expect(find.text('News Two'), findsOneWidget);

      await tester.pumpWidget(shell(ShellDestination.search));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('search-field')),
        'News One',
      );
      await tester.pump(const Duration(milliseconds: 240));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('search-no-results')), findsOneWidget);

      await tester.enterText(
        find.byKey(const ValueKey('search-field')),
        'News Two',
      );
      await tester.pump(const Duration(milliseconds: 240));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('search-item-news-two')),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'visibility bulk write blocks rail exit until persistence completes',
    (tester) async {
      final visibility = _GatedVisibilityPort();
      final scopePort = _ScopePort();
      final scope = CatalogScopeController(port: scopePort);
      final management = SourceManagementController(port: _ManagementPort());
      addTearDown(scope.dispose);
      await tester.binding.setSurfaceSize(const Size(1265, 713));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(
        MaterialApp(
          home: WabbitShell(
            fixtureMode: HomeFixtureMode.noPersonalization,
            initialDestination: ShellDestination.settings,
            sourceManagementController: management,
            catalogScopeController: scope,
            libraryVisibilityPort: visibility,
            scopedBrowseData: _VisibleCatalog(visibility),
            localSearchData: _VisibleCatalog(visibility),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final initialRosterLoads = scopePort.rosterLoads;

      await tester.tap(
        find.byKey(const ValueKey('source-action-Manage visibility')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('visibility-bulk-hide')));
      await tester.pump();
      await tester.tap(
        find.byKey(const ValueKey('visibility-bulk-confirm-hide')),
      );
      await tester.pump();
      expect(find.text('Updating categories…'), findsOneWidget);

      // The Live rail target remains clickable, but the shell must not unmount
      // the pending continuation or refresh shared catalog scope pre-commit.
      await tester.tapAt(const Offset(40, 162));
      await tester.pump();
      expect(find.text('Manage visibility'), findsOneWidget);
      expect(scopePort.rosterLoads, initialRosterLoads);

      visibility.completeBulkWrite();
      await tester.pumpAndSettle();
      await tester.tapAt(const Offset(40, 162));
      await tester.pumpAndSettle();

      expect(find.text('Manage visibility'), findsNothing);
      expect(find.byKey(const ValueKey('browse-items-live')), findsOneWidget);
      expect(scopePort.rosterLoads, initialRosterLoads + 1);
    },
  );
}

const _strong = SourceRosterEntry(
  id: 'strong',
  name: 'Strong',
  kind: 'xtream',
  enabled: true,
  status: 'ready',
  counts: {
    SourceMediaKind.live: 2,
    SourceMediaKind.movies: 0,
    SourceMediaKind.series: 0,
  },
);

class _ManagementPort implements SourceManagementPort {
  @override
  Future<List<SourceRosterEntry>> loadRoster() async => const [_strong];

  @override
  Future<void> editAndRefresh(String sourceId) async {}
  @override
  Future<void> refresh(String sourceId) async {}
  @override
  Future<void> remove(String sourceId) async {}
  @override
  Future<void> rename(String sourceId, String name) async {}
  @override
  Future<void> setEnabled(String sourceId, bool enabled) async {}
}

class _ScopePort implements CatalogScopePort {
  int rosterLoads = 0;

  @override
  Future<LibraryScope> loadCatalogScope() async => const LibraryScope.all();

  @override
  Future<PersistedSource?> loadReadySourceById(String sourceId) async => null;

  @override
  Future<List<SourceRosterEntry>> loadSourceRoster() async {
    rosterLoads++;
    return const [_strong];
  }

  @override
  Future<LibraryScope> saveCatalogScope(LibraryScope scope) async => scope;
}

class _VisibilityPort implements LibraryVisibilityPort {
  final hiddenItems = <String>{};
  final itemChanges = <(String, String, bool)>[];
  final sourceIds = <String>[];

  @override
  Future<List<LibraryVisibilityCategory>> loadCategories({
    required String sourceId,
    required SourceMediaKind kind,
    required bool hiddenOnly,
  }) async {
    sourceIds.add(sourceId);
    return const [
      LibraryVisibilityCategory(
        ref: LibraryVisibilityCategoryRef.group('7'),
        name: 'News',
        availableItemCount: 2,
        hidden: false,
      ),
    ];
  }

  @override
  Future<LibraryVisibilityItemPage> loadItems({
    required String sourceId,
    required SourceMediaKind kind,
    required LibraryVisibilityCategoryRef category,
    required bool hiddenOnly,
    String? cursor,
    int limit = 100,
  }) async {
    sourceIds.add(sourceId);
    final all = [
      LibraryVisibilityItem(
        catalogItemId: 'news-one',
        title: 'News One',
        kind: SourceMediaKind.live,
        hidden: hiddenItems.contains('news-one'),
      ),
      const LibraryVisibilityItem(
        catalogItemId: 'news-two',
        title: 'News Two',
        kind: SourceMediaKind.live,
        hidden: false,
      ),
    ];
    return LibraryVisibilityItemPage(
      items: hiddenOnly ? all.where((item) => item.hidden).toList() : all,
      nextCursor: null,
    );
  }

  @override
  Future<void> setCategoryHidden({
    required String sourceId,
    required SourceMediaKind kind,
    required LibraryVisibilityCategoryRef category,
    required bool hidden,
  }) async {
    sourceIds.add(sourceId);
  }

  @override
  Future<int> setAllCategoriesHidden({
    required String sourceId,
    required SourceMediaKind kind,
    required bool hidden,
  }) async {
    sourceIds.add(sourceId);
    return 0;
  }

  @override
  Future<void> setItemHidden({
    required String sourceId,
    required String catalogItemId,
    required bool hidden,
  }) async {
    sourceIds.add(sourceId);
    if (hidden) {
      hiddenItems.add(catalogItemId);
    } else {
      hiddenItems.remove(catalogItemId);
    }
    itemChanges.add((sourceId, catalogItemId, hidden));
  }
}

class _GatedVisibilityPort extends _VisibilityPort {
  final _bulkWrite = Completer<int>();

  @override
  Future<int> setAllCategoriesHidden({
    required String sourceId,
    required SourceMediaKind kind,
    required bool hidden,
  }) {
    sourceIds.add(sourceId);
    return _bulkWrite.future;
  }

  void completeBulkWrite() => _bulkWrite.complete(1);
}

class _VisibleCatalog implements ScopedBrowseData, LocalSearchData {
  _VisibleCatalog(this.visibility);
  final _VisibilityPort visibility;

  List<LibraryCatalogItem> get _items => [
    for (final item in const [
      ('news-one', 'News One'),
      ('news-two', 'News Two'),
    ])
      if (!visibility.hiddenItems.contains(item.$1))
        LibraryCatalogItem(
          libraryItemId: item.$1,
          catalogItemId: item.$1,
          sourceId: 'strong',
          sourceDisplayName: 'Strong',
          kind: SourceMediaKind.live,
          title: item.$2,
          artworkLocator: null,
          playbackRef: '{"providerId":"${item.$1}","kind":"live"}',
        ),
  ];

  @override
  Future<LibraryPage> browseLibraryPage({
    required LibraryScope scope,
    required SourceMediaKind kind,
    BrowseCursor? cursor,
    int limit = 100,
  }) async => LibraryPage(items: _items, nextCursor: null);

  @override
  Future<int> countLibraryItems({
    required LibraryScope scope,
    required SourceMediaKind kind,
  }) async => _items.length;

  @override
  Future<int> count({
    required String query,
    required LibraryScope scope,
  }) async => _matches(query).length;

  @override
  Future<PersistedSource?> loadReadySourceById(String sourceId) async => null;

  @override
  Future<LibraryPage> searchPage({
    required String query,
    required LibraryScope scope,
    BrowseCursor? cursor,
    int limit = 100,
  }) async => LibraryPage(items: _matches(query), nextCursor: null);

  List<LibraryCatalogItem> _matches(String query) {
    final lowered = query.toLowerCase();
    return _items
        .where((item) => item.title.toLowerCase().contains(lowered))
        .toList();
  }
}
