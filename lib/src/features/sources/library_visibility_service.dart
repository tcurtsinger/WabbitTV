import 'dart:convert';

import 'library_visibility_screen.dart';
import 'source_catalog_database.dart';
import 'source_models.dart';

/// Production-only adapter for the source-local visibility ledger.
///
/// This deliberately shares the shell's [SourceCatalogDatabase] rather than
/// creating another database owner. It maps the screen's credential-free,
/// string-safe values to the database's local SQLite identities and makes no
/// provider calls.
class DatabaseLibraryVisibilityPort implements LibraryVisibilityPort {
  const DatabaseLibraryVisibilityPort(this.database);

  final SourceCatalogDatabase database;

  @override
  Future<List<LibraryVisibilityCategory>> loadCategories({
    required String sourceId,
    required SourceMediaKind kind,
    required bool hiddenOnly,
  }) async {
    final rows = await database.loadVisibilityCategories(
      sourceId: sourceId,
      kind: kind,
      hiddenOnly: hiddenOnly,
    );
    return List.unmodifiable([
      for (final row in rows)
        LibraryVisibilityCategory(
          ref: _categoryRef(row.selection),
          name: row.name,
          availableItemCount: row.itemCount,
          hidden: row.isHidden,
        ),
    ]);
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
    final page = await database.loadVisibilityItems(
      sourceId: sourceId,
      kind: kind,
      selection: _selection(category),
      hiddenOnly: hiddenOnly,
      cursor: _decodeCursor(cursor),
      limit: limit,
    );
    return LibraryVisibilityItemPage(
      items: List.unmodifiable([
        for (final item in page.items)
          LibraryVisibilityItem(
            catalogItemId: item.catalogItemId,
            title: item.title,
            kind: item.kind,
            hidden: item.isHidden,
          ),
      ]),
      nextCursor: page.nextCursor == null
          ? null
          : _encodeCursor(page.nextCursor!),
    );
  }

  @override
  Future<void> setCategoryHidden({
    required String sourceId,
    required SourceMediaKind kind,
    required LibraryVisibilityCategoryRef category,
    required bool hidden,
  }) {
    final sourceGroupId = int.tryParse(category.sourceGroupId ?? '');
    if (sourceGroupId == null) {
      return Future<void>.error(
        ArgumentError.value(
          category,
          'category',
          'A provider group is required.',
        ),
      );
    }
    return database.setSourceGroupHidden(
      sourceId: sourceId,
      kind: kind,
      sourceGroupId: sourceGroupId,
      hidden: hidden,
    );
  }

  /// Bulk category visibility remains one local database operation; it never
  /// enumerates categories in Dart or contacts the provider.
  @override
  Future<int> setAllCategoriesHidden({
    required String sourceId,
    required SourceMediaKind kind,
    required bool hidden,
  }) => database.setAllCategoriesHidden(
    sourceId: sourceId,
    kind: kind,
    hidden: hidden,
  );

  @override
  Future<void> setItemHidden({
    required String sourceId,
    required String catalogItemId,
    required bool hidden,
  }) => database.setCatalogItemHidden(
    sourceId: sourceId,
    catalogItemId: catalogItemId,
    hidden: hidden,
  );

  LibraryVisibilityCategoryRef _categoryRef(BrowseCategorySelection selection) {
    return switch (selection.kind) {
      BrowseCategorySelectionKind.sourceGroup =>
        LibraryVisibilityCategoryRef.group(selection.sourceGroupId!.toString()),
      BrowseCategorySelectionKind.uncategorized =>
        const LibraryVisibilityCategoryRef.uncategorized(),
      BrowseCategorySelectionKind.all => throw StateError(
        'The visibility directory cannot contain All categories.',
      ),
    };
  }

  BrowseCategorySelection _selection(LibraryVisibilityCategoryRef category) {
    final id = category.sourceGroupId;
    if (id == null) return const BrowseCategorySelection.uncategorized();
    final sourceGroupId = int.tryParse(id);
    if (sourceGroupId == null) {
      throw ArgumentError.value(
        category,
        'category',
        'Invalid provider group.',
      );
    }
    return BrowseCategorySelection.sourceGroup(sourceGroupId);
  }

  // The screen intentionally owns an opaque cursor. JSON avoids assuming any
  // provider title or local item id can safely be split on a delimiter.
  String _encodeCursor(BrowseCursor cursor) =>
      jsonEncode([cursor.normalizedTitle, cursor.id]);

  BrowseCursor? _decodeCursor(String? value) {
    if (value == null) return null;
    try {
      final decoded = jsonDecode(value);
      if (decoded is! List ||
          decoded.length != 2 ||
          decoded[0] is! String ||
          decoded[1] is! String) {
        return null;
      }
      return BrowseCursor(
        normalizedTitle: decoded[0] as String,
        id: decoded[1] as String,
      );
    } on FormatException {
      return null;
    }
  }
}
