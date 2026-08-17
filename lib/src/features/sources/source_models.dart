import 'dart:convert';

enum SourceMediaKind { live, movies, series }

extension SourceMediaKindLabel on SourceMediaKind {
  String get label => switch (this) {
    SourceMediaKind.live => 'Live',
    SourceMediaKind.movies => 'Movies',
    SourceMediaKind.series => 'Series',
  };

  String get xtreamAction => switch (this) {
    SourceMediaKind.live => 'get_live_streams',
    SourceMediaKind.movies => 'get_vod_streams',
    SourceMediaKind.series => 'get_series',
  };

  String get categoryAction => switch (this) {
    SourceMediaKind.live => 'get_live_categories',
    SourceMediaKind.movies => 'get_vod_categories',
    SourceMediaKind.series => 'get_series_categories',
  };
}

class SourceDefinition {
  const SourceDefinition({
    required this.id,
    required this.name,
    required this.serverUrl,
    required this.username,
    required this.password,
    required this.credentialKey,
  });

  final String id;
  final String name;
  final String serverUrl;
  final String username;
  final String password;
  final String credentialKey;

  String get displayEndpoint => Uri.parse(serverUrl).host;
}

class ImportedCategory {
  const ImportedCategory({required this.providerKey, required this.name});

  final String providerKey;
  final String name;

  Map<String, Object?> toJson() => {'providerKey': providerKey, 'name': name};

  factory ImportedCategory.fromJson(Map<String, Object?> json) =>
      ImportedCategory(
        providerKey: json['providerKey']! as String,
        name: json['name']! as String,
      );
}

class ImportedCatalogItem {
  const ImportedCatalogItem({
    required this.providerKey,
    required this.title,
    required this.categoryKey,
    required this.playbackRef,
    this.artworkLocator,
  });

  final String providerKey;
  final String title;
  final String? categoryKey;
  final String playbackRef;
  final String? artworkLocator;

  Map<String, Object?> toJson() => {
    'providerKey': providerKey,
    'title': title,
    'categoryKey': categoryKey,
    'playbackRef': playbackRef,
    'artworkLocator': artworkLocator,
  };

  factory ImportedCatalogItem.fromJson(Map<String, Object?> json) =>
      ImportedCatalogItem(
        providerKey: json['providerKey']! as String,
        title: json['title']! as String,
        categoryKey: json['categoryKey'] as String?,
        playbackRef: json['playbackRef']! as String,
        artworkLocator: json['artworkLocator'] as String?,
      );
}

class ImportedStage {
  const ImportedStage({
    required this.kind,
    required this.categories,
    required this.items,
  });

  final SourceMediaKind kind;
  final List<ImportedCategory> categories;
  final List<ImportedCatalogItem> items;

  int get itemCount => items.length;

  Map<String, Object?> toJson() => {
    'kind': kind.name,
    'categories': categories.map((category) => category.toJson()).toList(),
    'items': items.map((item) => item.toJson()).toList(),
  };

  factory ImportedStage.fromJson(Map<String, Object?> json) => ImportedStage(
    kind: SourceMediaKind.values.byName(json['kind']! as String),
    categories: (json['categories']! as List<Object?>)
        .cast<Map<Object?, Object?>>()
        .map(
          (entry) => ImportedCategory.fromJson(entry.cast<String, Object?>()),
        )
        .toList(),
    items: (json['items']! as List<Object?>)
        .cast<Map<Object?, Object?>>()
        .map(
          (entry) =>
              ImportedCatalogItem.fromJson(entry.cast<String, Object?>()),
        )
        .toList(),
  );
}

class SourceReady {
  const SourceReady({required this.counts});

  final Map<SourceMediaKind, int> counts;
}

enum BrowseCategorySelectionKind { all, sourceGroup, uncategorized }

/// The category slice requested from one source and media kind.
///
/// A source-group selection deliberately carries the local SQLite group id,
/// not a provider key. It is only meaningful alongside the source and kind
/// passed to the browse query.
class BrowseCategorySelection {
  const BrowseCategorySelection.all()
    : kind = BrowseCategorySelectionKind.all,
      sourceGroupId = null;

  const BrowseCategorySelection.uncategorized()
    : kind = BrowseCategorySelectionKind.uncategorized,
      sourceGroupId = null;

  const BrowseCategorySelection.sourceGroup(this.sourceGroupId)
    : kind = BrowseCategorySelectionKind.sourceGroup;

  final BrowseCategorySelectionKind kind;
  final int? sourceGroupId;
}

class BrowseCategorySummary {
  const BrowseCategorySummary({
    required this.selection,
    required this.name,
    required this.itemCount,
  });

  final BrowseCategorySelection selection;
  final String name;
  final int itemCount;
}

/// A stable position in a title-ordered catalog page.
class BrowseCursor {
  const BrowseCursor({required this.normalizedTitle, required this.id});

  final String normalizedTitle;
  final String id;
}

class BrowseCatalogItem {
  const BrowseCatalogItem({
    required this.id,
    required this.sourceId,
    required this.kind,
    required this.title,
    required this.artworkLocator,
    required this.playbackRef,
  });

  final String id;
  final String sourceId;
  final SourceMediaKind kind;
  final String title;
  final String? artworkLocator;
  final String playbackRef;
}

class BrowsePage {
  const BrowsePage({required this.items, required this.nextCursor});

  final List<BrowseCatalogItem> items;
  final BrowseCursor? nextCursor;
}

String playbackReference(Map<String, Object?> value) => jsonEncode(value);
