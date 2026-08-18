import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:wabbit_tv/src/features/sources/library_visibility_service.dart';
import 'package:wabbit_tv/src/features/sources/source_catalog_database.dart';
import 'package:wabbit_tv/src/features/sources/source_models.dart';

void main() {
  test('category and item preferences apply to named, all, search, and count reads', () async {
    final fixture = await _VisibilityFixture.create();
    addTearDown(fixture.dispose);
    await fixture.seed();

    final world = (await fixture.database.loadVisibilityCategories(
      sourceId: 'one',
      kind: SourceMediaKind.live,
    )).singleWhere((category) => category.name == 'World');
    await fixture.database.setSourceGroupHidden(
      sourceId: 'one',
      kind: SourceMediaKind.live,
      sourceGroupId: world.selection.sourceGroupId!,
      hidden: true,
    );
    await fixture.database.setCatalogItemHidden(
      sourceId: 'one',
      catalogItemId: 'one:live:fox-uncategorized',
      hidden: true,
    );
    await fixture.database.setCatalogItemHidden(
      sourceId: 'one',
      catalogItemId: 'one:live:fox-sports',
      hidden: true,
    );

    final namedCategories = await fixture.database.browseCategories(
      sourceId: 'one',
      kind: SourceMediaKind.live,
    );
    expect(namedCategories.map((category) => category.name), [
      'All Live',
      'Sports',
    ]);
    expect(
      namedCategories
          .singleWhere((category) => category.name == 'Sports')
          .itemCount,
      0,
    );
    expect(
      (await fixture.database.browsePage(
        sourceId: 'one',
        kind: SourceMediaKind.live,
      )).items,
      isEmpty,
    );

    final all = await fixture.database.browseLibraryPage(
      scope: const LibraryScope.all(),
      kind: SourceMediaKind.live,
    );
    expect(all.items.map((item) => item.catalogItemId), ['two:live:fox-other']);
    final named = await fixture.database.browseLibraryPage(
      scope: const LibraryScope.source('one'),
      kind: SourceMediaKind.live,
    );
    expect(named.items, isEmpty);
    final search = await fixture.database.searchLibraryPage(
      query: 'Fox',
      scope: const LibraryScope.all(),
      kind: SourceMediaKind.live,
    );
    expect(search.items.map((item) => item.catalogItemId), [
      'two:live:fox-other',
    ]);
    expect(
      await fixture.database.countLibraryItems(
        scope: const LibraryScope.all(),
        kind: SourceMediaKind.live,
        query: 'Fox',
      ),
      1,
    );
  });

  test(
    'hidden-only recovery retains category and individual state independently',
    () async {
      final fixture = await _VisibilityFixture.create();
      addTearDown(fixture.dispose);
      await fixture.seed();
      final categories = await fixture.database.loadVisibilityCategories(
        sourceId: 'one',
        kind: SourceMediaKind.live,
      );
      final world = categories.singleWhere(
        (category) => category.name == 'World',
      );
      await fixture.database.setSourceGroupHidden(
        sourceId: 'one',
        kind: SourceMediaKind.live,
        sourceGroupId: world.selection.sourceGroupId!,
        hidden: true,
      );
      await fixture.database.setCatalogItemHidden(
        sourceId: 'one',
        catalogItemId: 'one:live:fox-world',
        hidden: true,
      );
      await fixture.database.setCatalogItemHidden(
        sourceId: 'one',
        catalogItemId: 'one:live:fox-uncategorized',
        hidden: true,
      );
      await fixture.database.setCatalogItemHidden(
        sourceId: 'one',
        catalogItemId: 'one:live:fox-sports',
        hidden: true,
      );

      final hidden = await fixture.database.loadVisibilityCategories(
        sourceId: 'one',
        kind: SourceMediaKind.live,
        hiddenOnly: true,
      );
      expect(hidden.map((category) => category.name), [
        'Sports',
        'World',
        'Uncategorized',
      ]);
      final hiddenWorldCategory = hidden.singleWhere(
        (category) => category.name == 'World',
      );
      expect(hiddenWorldCategory.isHidden, isTrue);
      expect(hiddenWorldCategory.hiddenItemCount, 1);
      expect(hidden.last.isHidden, isFalse);
      expect(hidden.last.hiddenItemCount, 1);

      final hiddenWorld = await fixture.database.loadVisibilityItems(
        sourceId: 'one',
        kind: SourceMediaKind.live,
        selection: world.selection,
        hiddenOnly: true,
      );
      expect(
        hiddenWorld.items.map((item) => (item.catalogItemId, item.isHidden)),
        [('one:live:fox-world', true)],
      );

      await fixture.database.setSourceGroupHidden(
        sourceId: 'one',
        kind: SourceMediaKind.live,
        sourceGroupId: world.selection.sourceGroupId!,
        hidden: false,
      );
      final restoredCategory = await fixture.database.browsePage(
        sourceId: 'one',
        kind: SourceMediaKind.live,
      );
      // Restoring World exposes its retained included item, but not the item
      // deliberately hidden before the category was restored.
      expect(restoredCategory.items.map((item) => item.id), [
        'one:live:spider-world',
      ]);
    },
  );

  test('refresh preserves preferences, defaults new imports included, and scopes setters', () async {
    final fixture = await _VisibilityFixture.create();
    addTearDown(fixture.dispose);
    await fixture.seed();
    final world = (await fixture.database.loadVisibilityCategories(
      sourceId: 'one',
      kind: SourceMediaKind.live,
    )).singleWhere((category) => category.name == 'World');
    await fixture.database.setSourceGroupHidden(
      sourceId: 'one',
      kind: SourceMediaKind.live,
      sourceGroupId: world.selection.sourceGroupId!,
      hidden: true,
    );
    await fixture.database.setCatalogItemHidden(
      sourceId: 'one',
      catalogItemId: 'one:live:fox-world',
      hidden: true,
    );
    await expectLater(
      fixture.database.setCatalogItemHidden(
        sourceId: 'two',
        catalogItemId: 'one:live:fox-world',
        hidden: true,
      ),
      throwsA(isA<StateError>()),
    );

    final refresh = await fixture.database.beginRefresh('one');
    expect(refresh, isNotNull);
    await fixture.database.commitRefresh(refresh!, [
      const ImportedStage(
        kind: SourceMediaKind.live,
        categories: [
          ImportedCategory(providerKey: 'world', name: 'World renamed'),
        ],
        items: [
          ImportedCatalogItem(
            providerKey: 'fox-world',
            title: 'Fox World refreshed',
            categoryKey: 'world',
            playbackRef: 'new-ref',
          ),
          ImportedCatalogItem(
            providerKey: 'new-world',
            title: 'New World import',
            categoryKey: 'world',
            playbackRef: 'new-ref-2',
          ),
        ],
      ),
    ]);

    final afterRefresh = await fixture.database.loadVisibilityCategories(
      sourceId: 'one',
      kind: SourceMediaKind.live,
    );
    final persistedWorld = afterRefresh.singleWhere(
      (category) => category.name == 'World renamed',
    );
    expect(persistedWorld.name, 'World renamed');
    expect(persistedWorld.isHidden, isTrue);
    final items = await fixture.database.loadVisibilityItems(
      sourceId: 'one',
      kind: SourceMediaKind.live,
      selection: persistedWorld.selection,
    );
    expect(items.items.map((item) => (item.catalogItemId, item.isHidden)), [
      ('one:live:fox-world', true),
      ('one:live:new-world', false),
    ]);
    expect(
      (await fixture.database.browsePage(
        sourceId: 'one',
        kind: SourceMediaKind.live,
      )).items,
      isEmpty,
    );
  });

  test('visibility ledger pages a large category deterministically', () async {
    final fixture = await _VisibilityFixture.create();
    addTearDown(fixture.dispose);
    await fixture.database.commitInitialSource(_source('bulk', 'Bulk'), [
      ImportedStage(
        kind: SourceMediaKind.live,
        categories: const [ImportedCategory(providerKey: 'bulk', name: 'Bulk')],
        items: [
          for (var index = 0; index < 1000; index++)
            ImportedCatalogItem(
              providerKey: '$index',
              title: 'Fixture ${index.toString().padLeft(4, '0')}',
              categoryKey: 'bulk',
              playbackRef: 'ref-$index',
            ),
        ],
      ),
    ]);
    final category = (await fixture.database.loadVisibilityCategories(
      sourceId: 'bulk',
      kind: SourceMediaKind.live,
    )).single;
    final first = await fixture.database.loadVisibilityItems(
      sourceId: 'bulk',
      kind: SourceMediaKind.live,
      selection: category.selection,
      limit: 200,
    );
    final second = await fixture.database.loadVisibilityItems(
      sourceId: 'bulk',
      kind: SourceMediaKind.live,
      selection: category.selection,
      cursor: first.nextCursor,
      limit: 200,
    );
    expect(first.items, hasLength(200));
    expect(first.nextCursor, isNotNull);
    expect(second.items, hasLength(200));
    expect(
      second.items.first.catalogItemId,
      isNot(first.items.last.catalogItemId),
    );
  });

  test('bulk category visibility is source and kind scoped and preserves item state', () async {
    final fixture = await _VisibilityFixture.create();
    addTearDown(fixture.dispose);
    await fixture.database.commitInitialSource(_source('one', 'One'), [
      const ImportedStage(
        kind: SourceMediaKind.live,
        categories: [
          ImportedCategory(providerKey: 'alpha', name: 'Alpha'),
          ImportedCategory(providerKey: 'beta', name: 'Beta'),
        ],
        items: [
          ImportedCatalogItem(
            providerKey: 'alpha-item',
            title: 'Alpha item',
            categoryKey: 'alpha',
            playbackRef: 'alpha-ref',
          ),
          ImportedCatalogItem(
            providerKey: 'beta-item',
            title: 'Beta item',
            categoryKey: 'beta',
            playbackRef: 'beta-ref',
          ),
          ImportedCatalogItem(
            providerKey: 'loose-item',
            title: 'Loose item',
            categoryKey: null,
            playbackRef: 'loose-ref',
          ),
        ],
      ),
      const ImportedStage(
        kind: SourceMediaKind.movies,
        categories: [ImportedCategory(providerKey: 'cinema', name: 'Cinema')],
        items: [
          ImportedCatalogItem(
            providerKey: 'movie-item',
            title: 'Movie item',
            categoryKey: 'cinema',
            playbackRef: 'movie-ref',
          ),
        ],
      ),
    ]);
    await fixture.database.commitInitialSource(_source('two', 'Two'), [
      const ImportedStage(
        kind: SourceMediaKind.live,
        categories: [ImportedCategory(providerKey: 'other', name: 'Other')],
        items: [
          ImportedCatalogItem(
            providerKey: 'other-item',
            title: 'Other item',
            categoryKey: 'other',
            playbackRef: 'other-ref',
          ),
        ],
      ),
    ]);

    final live = await fixture.database.loadVisibilityCategories(
      sourceId: 'one',
      kind: SourceMediaKind.live,
    );
    final alpha = live.singleWhere((category) => category.name == 'Alpha');
    final beta = live.singleWhere((category) => category.name == 'Beta');
    final uncategorized = live.singleWhere(
      (category) => category.name == 'Uncategorized',
    );
    await fixture.database.setSourceGroupHidden(
      sourceId: 'one',
      kind: SourceMediaKind.live,
      sourceGroupId: alpha.selection.sourceGroupId!,
      hidden: true,
    );
    await fixture.database.setCatalogItemHidden(
      sourceId: 'one',
      catalogItemId: 'one:live:beta-item',
      hidden: true,
    );
    await fixture.database.setCatalogItemHidden(
      sourceId: 'one',
      catalogItemId: 'one:live:loose-item',
      hidden: true,
    );

    final port = DatabaseLibraryVisibilityPort(fixture.database);
    expect(
      await port.setAllCategoriesHidden(
        sourceId: 'one',
        kind: SourceMediaKind.live,
        hidden: true,
      ),
      1,
    );
    expect(
      (await fixture.database.loadVisibilityCategories(
            sourceId: 'one',
            kind: SourceMediaKind.live,
          ))
          .where((category) => category.name != 'Uncategorized')
          .every((category) => category.isHidden),
      isTrue,
    );
    expect(
      (await fixture.database.loadVisibilityCategories(
        sourceId: 'one',
        kind: SourceMediaKind.movies,
      )).single.isHidden,
      isFalse,
    );
    expect(
      (await fixture.database.loadVisibilityCategories(
        sourceId: 'two',
        kind: SourceMediaKind.live,
      )).single.isHidden,
      isFalse,
    );
    expect(
      (await fixture.database.loadVisibilityItems(
        sourceId: 'one',
        kind: SourceMediaKind.live,
        selection: beta.selection,
      )).items.single.isHidden,
      isTrue,
    );
    expect(
      (await fixture.database.loadVisibilityItems(
        sourceId: 'one',
        kind: SourceMediaKind.live,
        selection: uncategorized.selection,
      )).items.single.isHidden,
      isTrue,
    );
    expect(
      await port.setAllCategoriesHidden(
        sourceId: 'one',
        kind: SourceMediaKind.live,
        hidden: true,
      ),
      0,
    );
    expect(
      await port.setAllCategoriesHidden(
        sourceId: 'one',
        kind: SourceMediaKind.live,
        hidden: false,
      ),
      2,
    );
    final restored = await fixture.database.loadVisibilityCategories(
      sourceId: 'one',
      kind: SourceMediaKind.live,
    );
    expect(
      restored
          .where((category) => category.name != 'Uncategorized')
          .every((category) => !category.isHidden),
      isTrue,
    );

    expect(
      await port.setAllCategoriesHidden(
        sourceId: 'one',
        kind: SourceMediaKind.live,
        hidden: true,
      ),
      2,
    );
    final refresh = await fixture.database.beginRefresh('one');
    expect(refresh, isNotNull);
    await fixture.database.commitRefresh(refresh!, [
      const ImportedStage(
        kind: SourceMediaKind.live,
        categories: [
          ImportedCategory(providerKey: 'alpha', name: 'Alpha refreshed'),
          ImportedCategory(providerKey: 'beta', name: 'Beta refreshed'),
        ],
        items: [
          ImportedCatalogItem(
            providerKey: 'alpha-item',
            title: 'Alpha item refreshed',
            categoryKey: 'alpha',
            playbackRef: 'alpha-ref-2',
          ),
          ImportedCatalogItem(
            providerKey: 'new-beta-item',
            title: 'New Beta item',
            categoryKey: 'beta',
            playbackRef: 'new-beta-ref',
          ),
        ],
      ),
    ]);
    expect(
      (await fixture.database.loadVisibilityCategories(
        sourceId: 'one',
        kind: SourceMediaKind.live,
      )).every((category) => category.isHidden),
      isTrue,
    );

    expect(
      await port.setAllCategoriesHidden(
        sourceId: 'one',
        kind: SourceMediaKind.series,
        hidden: true,
      ),
      0,
    );
    await expectLater(
      port.setAllCategoriesHidden(
        sourceId: 'missing',
        kind: SourceMediaKind.live,
        hidden: false,
      ),
      throwsA(isA<StateError>()),
    );
    expect(
      (await fixture.database.loadVisibilityCategories(
        sourceId: 'one',
        kind: SourceMediaKind.live,
      )).every((category) => category.isHidden),
      isTrue,
    );
  });
}

class _VisibilityFixture {
  _VisibilityFixture(this.directory)
    : database = SourceCatalogDatabase(
        databasePath:
            '${directory.path}${Platform.pathSeparator}catalog.sqlite',
      );

  final Directory directory;
  final SourceCatalogDatabase database;

  static Future<_VisibilityFixture> create() async => _VisibilityFixture(
    await Directory.systemTemp.createTemp('wabbit-visibility-'),
  );

  Future<void> seed() async {
    await database.commitInitialSource(_source('one', 'One'), [
      const ImportedStage(
        kind: SourceMediaKind.live,
        categories: [
          ImportedCategory(providerKey: 'world', name: 'World'),
          ImportedCategory(providerKey: 'sports', name: 'Sports'),
        ],
        items: [
          ImportedCatalogItem(
            providerKey: 'fox-world',
            title: 'Fox World',
            categoryKey: 'world',
            playbackRef: 'ref-world',
          ),
          ImportedCatalogItem(
            providerKey: 'spider-world',
            title: 'Spider World',
            categoryKey: 'world',
            playbackRef: 'ref-spider',
          ),
          ImportedCatalogItem(
            providerKey: 'fox-sports',
            title: 'Fox Sports',
            categoryKey: 'sports',
            playbackRef: 'ref-sports',
          ),
          ImportedCatalogItem(
            providerKey: 'fox-uncategorized',
            title: 'Fox Uncategorized',
            categoryKey: null,
            playbackRef: 'ref-uncategorized',
          ),
        ],
      ),
    ]);
    await database.commitInitialSource(_source('two', 'Two'), [
      const ImportedStage(
        kind: SourceMediaKind.live,
        categories: [],
        items: [
          ImportedCatalogItem(
            providerKey: 'fox-other',
            title: 'Fox Other',
            categoryKey: null,
            playbackRef: 'ref-other',
          ),
        ],
      ),
    ]);
  }

  Future<void> dispose() => directory.delete(recursive: true);
}

SourceDefinition _source(String id, String name) => SourceDefinition(
  id: id,
  name: name,
  serverUrl: 'https://$id.example',
  username: 'user',
  password: 'password',
  credentialKey: '$id-key',
);
