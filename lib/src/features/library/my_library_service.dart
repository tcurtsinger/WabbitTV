import '../sources/source_catalog_database.dart';
import '../sources/source_models.dart';
import 'my_library_screen.dart';

const _favoritesSectionId = 'favorites';

/// Credential-free adapter from the local organization tables to My Library.
///
/// The presentation layer receives opaque artwork keys only. Raw source
/// artwork locators and playback references remain behind this app-owned
/// boundary until a focused thumbnail or explicit activation resolves them.
class DatabaseMyLibraryData implements MyLibraryData {
  DatabaseMyLibraryData(this.database);

  final SourceCatalogDatabase database;
  final Map<String, PersonalLibraryDirectoryEntry> _sections = {};
  final Map<String, PersonalLibraryItem> _items = {};

  @override
  Future<List<MyLibrarySection>> loadSections({int limit = 100}) async {
    final entries = await database.loadPersonalLibraryDirectory(limit: limit);
    _sections
      ..clear()
      ..addEntries(entries.map((entry) => MapEntry(_sectionId(entry), entry)));
    return List.unmodifiable(entries.map(_presentSection));
  }

  @override
  Future<MyLibraryPage> loadItems({
    required String sectionId,
    MyLibraryPageCursor? cursor,
    int limit = 100,
  }) async {
    final section = _sections[sectionId];
    if (section == null) {
      throw StateError('Personal library section is unavailable.');
    }

    late final List<PersonalLibraryItem> items;
    late final Object? nextCursor;
    if (section.kind == PersonalLibraryDirectoryKind.favorites) {
      final value = cursor?.value;
      if (value != null && value is! FavoritePageCursor) {
        throw StateError('Personal library cursor is invalid.');
      }
      final page = await database.loadFavoriteLibraryPage(
        cursor: value as FavoritePageCursor?,
        limit: limit,
      );
      items = page.items;
      nextCursor = page.nextCursor;
    } else {
      final customGroupId = section.collectionId;
      if (customGroupId == null) {
        throw StateError('Personal library group is unavailable.');
      }
      final value = cursor?.value;
      if (value != null && value is! CustomGroupPageCursor) {
        throw StateError('Personal library cursor is invalid.');
      }
      final page = await database.loadCustomGroupLibraryPage(
        customGroupId: customGroupId,
        cursor: value as CustomGroupPageCursor?,
        limit: limit,
      );
      items = page.items;
      nextCursor = page.nextCursor;
    }

    // Never destructively clear another section's exact-item boundary here.
    // A late completion for an obsolete section may warm this credential-free
    // cache, but it cannot invalidate the active section's artwork/playback.
    for (final item in items) {
      _items[item.libraryItemId] = item;
    }
    return MyLibraryPage(
      items: List.unmodifiable(items.map(_presentItem)),
      nextCursor: nextCursor == null ? null : MyLibraryPageCursor(nextCursor),
      totalCount: section.itemCount,
    );
  }

  @override
  Future<LibraryCatalogItem?> resolvePlayableItem(String libraryItemId) async =>
      _items[libraryItemId]?.playableItem;

  @override
  Future<PersistedSource?> loadReadySourceById(String sourceId) =>
      database.loadReadySourceById(sourceId);

  String? artworkLocatorFor(String libraryItemId) =>
      _items[libraryItemId]?.isAvailable == true
      ? _items[libraryItemId]?.artworkLocator
      : null;

  String _sectionId(PersonalLibraryDirectoryEntry entry) =>
      entry.kind == PersonalLibraryDirectoryKind.favorites
      ? _favoritesSectionId
      : entry.collectionId!;

  MyLibrarySection _presentSection(PersonalLibraryDirectoryEntry entry) =>
      MyLibrarySection(
        id: _sectionId(entry),
        name: entry.name,
        kind: entry.kind == PersonalLibraryDirectoryKind.favorites
            ? MyLibrarySectionKind.favorites
            : MyLibrarySectionKind.customGroup,
        itemCount: entry.itemCount,
        directoryOrdinal: entry.directoryOrdinal,
        homeOrdinal: entry.homeOrdinal,
      );

  MyLibraryItem _presentItem(PersonalLibraryItem item) => MyLibraryItem(
    id: item.libraryItemId,
    title: item.title,
    kind: switch (item.kind) {
      SourceMediaKind.live => MyLibraryMediaKind.live,
      SourceMediaKind.movies => MyLibraryMediaKind.movie,
      SourceMediaKind.series => MyLibraryMediaKind.series,
    },
    sourceName: item.sourceDisplayName,
    artworkKey: item.isAvailable ? item.libraryItemId : null,
    availability: item.isAvailable
        ? MyLibraryItemAvailability.available
        : MyLibraryItemAvailability.sourceUnavailable,
  );
}
