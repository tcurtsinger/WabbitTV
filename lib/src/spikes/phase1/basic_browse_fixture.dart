import '../../features/browse/basic_browse_screen.dart';
import '../../features/sources/source_catalog_database.dart';
import '../../features/sources/source_models.dart';

/// Synthetic, network-free catalog used only for packaged Basic Browse review.
///
/// It is selected by an explicit compile-time flag and never participates in
/// normal application startup or reads a user's provider data.
class BasicBrowseFixtureData implements BasicBrowseData {
  const BasicBrowseFixtureData();

  static const source = PersistedSource(
    id: 'basic-browse-fixture',
    name: 'Fixture source',
    credentialKey: 'basic-browse-fixture-key',
    counts: {
      SourceMediaKind.live: 36,
      SourceMediaKind.movies: 36,
      SourceMediaKind.series: 36,
    },
  );

  @override
  Future<List<BrowseCategorySummary>> browseCategories({
    required String sourceId,
    required SourceMediaKind kind,
  }) async {
    final catalog = _catalogFor(kind);
    return [
      BrowseCategorySummary(
        selection: const BrowseCategorySelection.all(),
        name: 'All ${kind.label}',
        itemCount: catalog.length,
      ),
      for (var index = 0; index < _categoryNames(kind).length; index++)
        BrowseCategorySummary(
          selection: BrowseCategorySelection.sourceGroup(index + 1),
          name: _categoryNames(kind)[index],
          itemCount: catalog
              .where((entry) => entry.categoryId == index + 1)
              .length,
        ),
    ];
  }

  @override
  Future<BrowsePage> browsePage({
    required String sourceId,
    required SourceMediaKind kind,
    required BrowseCategorySelection selection,
    BrowseCursor? cursor,
    int limit = 100,
  }) async {
    final catalog = _catalogFor(kind)
        .where(
          (entry) =>
              selection.kind == BrowseCategorySelectionKind.all ||
              (selection.kind == BrowseCategorySelectionKind.sourceGroup &&
                  entry.categoryId == selection.sourceGroupId),
        )
        .toList(growable: false);
    final start = cursor == null
        ? 0
        : catalog.indexWhere((entry) => entry.item.id == cursor.id) + 1;
    final safeStart = start < 0 ? 0 : start;
    final end = (safeStart + limit).clamp(0, catalog.length);
    final page = catalog.sublist(safeStart, end);
    final last = page.isEmpty ? null : page.last.item;
    return BrowsePage(
      items: page.map((entry) => entry.item).toList(growable: false),
      nextCursor: end < catalog.length && last != null
          ? BrowseCursor(normalizedTitle: last.title.toLowerCase(), id: last.id)
          : null,
    );
  }
}

List<_FixtureCatalogEntry> _catalogFor(SourceMediaKind kind) {
  final categories = _categoryNames(kind);
  final titles = switch (kind) {
    SourceMediaKind.live => const [
      'City Desk',
      'Coastline Weather',
      'Field Report',
      'Final Whistle',
      'Front Row',
      'Harbor News',
      'Late Edition',
      'Matchday One',
      'Metro Journal',
      'Morning Signal',
      'National Brief',
      'Night Shift',
    ],
    SourceMediaKind.movies => const [
      'After the Rain',
      'Autumn Line',
      'Beyond the Harbor',
      'Blue Mile',
      'First Light',
      'Glass River',
      'Long Way North',
      'Midnight Orchard',
      'Open Country',
      'Paper Moons',
      'Signal Hill',
      'The Quiet Crossing',
    ],
    SourceMediaKind.series => const [
      'Atlas House',
      'Common Ground',
      'Deep Current',
      'Field Notes',
      'Harbor Unit',
      'Longform',
      'Northern Lines',
      'Signal Room',
      'Small Hours',
      'The Dispatch',
      'Threshold',
      'Westward',
    ],
  };
  return [
    for (var repeat = 0; repeat < 3; repeat++)
      for (var index = 0; index < titles.length; index++)
        _FixtureCatalogEntry(
          categoryId: (index % categories.length) + 1,
          item: BrowseCatalogItem(
            id: '${kind.name}-${repeat * titles.length + index}',
            sourceId: BasicBrowseFixtureData.source.id,
            kind: kind,
            title: repeat == 0
                ? titles[index]
                : '${titles[index]} ${repeat + 1}',
            artworkLocator: 'fixture:${kind.name}:$index:$repeat',
            playbackRef: playbackReference({
              'providerId': '${repeat * titles.length + index + 1}',
              'kind': kind.name,
              'extension': kind == SourceMediaKind.live ? 'ts' : 'mp4',
            }),
          ),
        ),
  ];
}

List<String> _categoryNames(SourceMediaKind kind) => switch (kind) {
  SourceMediaKind.live => const [
    'Local',
    'News',
    'Sports',
    'Weather',
    'International',
    'Public Affairs',
  ],
  SourceMediaKind.movies => const [
    'Drama',
    'Comedy',
    'Documentary',
    'Family',
    'Classics',
    'Independent',
  ],
  SourceMediaKind.series => const [
    'Drama',
    'Comedy',
    'Documentary',
    'Crime',
    'Limited Series',
    'International',
  ],
};

class _FixtureCatalogEntry {
  const _FixtureCatalogEntry({required this.categoryId, required this.item});

  final int categoryId;
  final BrowseCatalogItem item;
}
