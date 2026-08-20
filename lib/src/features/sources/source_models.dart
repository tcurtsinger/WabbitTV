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

/// A bounded, credential-free summary for source-management callers.
class SourceRosterEntry {
  const SourceRosterEntry({
    required this.id,
    required this.name,
    required this.kind,
    required this.enabled,
    required this.status,
    required this.counts,
  });

  final String id;
  final String name;
  final String kind;
  final bool enabled;
  final String status;
  final Map<SourceMediaKind, int> counts;
}

/// The generation reserved for one in-progress source refresh.
class SourceRefresh {
  const SourceRefresh({required this.sourceId, required this.generation});

  final String sourceId;
  final int generation;
}

/// Fixed, credential-free reasons allowed in persistent refresh state.
enum SourceRefreshFailure {
  authentication,
  unreachable,
  emptyResponse,
  tooLarge,
  timedOut,
  cancelled,
}

/// The library scope is either all active sources or one active source.
class LibraryScope {
  const LibraryScope.all() : sourceId = null;

  const LibraryScope.source(this.sourceId);

  final String? sourceId;

  bool get isAll => sourceId == null;
}

class LibraryCatalogItem {
  const LibraryCatalogItem({
    required this.libraryItemId,
    required this.catalogItemId,
    required this.sourceId,
    required this.sourceDisplayName,
    required this.kind,
    required this.title,
    required this.artworkLocator,
    required this.playbackRef,
  });

  final String libraryItemId;
  final String catalogItemId;
  final String sourceId;
  final String sourceDisplayName;
  final SourceMediaKind kind;
  final String title;
  final String? artworkLocator;
  final String playbackRef;
}

class LibraryPage {
  const LibraryPage({required this.items, required this.nextCursor});

  final List<LibraryCatalogItem> items;
  final BrowseCursor? nextCursor;
}

/// One locally recorded viewing occurrence and the exact currently playable
/// source variant selected for that library identity.
class RecentlyWatchedItem {
  const RecentlyWatchedItem({required this.item, required this.lastPlayedAt});

  final LibraryCatalogItem item;
  final DateTime lastPlayedAt;
}

/// Restart-safe progress for one exact playable Movie or Episode.
///
/// [mediaKey] is a caller-owned opaque local key. It distinguishes episodes
/// inside one stable series identity without persisting a playback locator or
/// creating any title-derived identity relationship.
class PlaybackProgress {
  const PlaybackProgress({
    required this.libraryItemId,
    required this.mediaKey,
    required this.positionMs,
    required this.durationMs,
    this.watchedMs = 0,
    required this.completed,
    required this.updatedAt,
  });

  final String libraryItemId;
  final String mediaKey;
  final int positionMs;
  final int durationMs;
  final int watchedMs;
  final bool completed;
  final DateTime updatedAt;

  /// Resume is based on actual watched time, never a seeked position.
  bool get isResumeEligible =>
      !completed &&
      watchedMs >= 30000 &&
      positionMs > 0 &&
      durationMs - positionMs >= 60000;

  @override
  String toString() =>
      'PlaybackProgress(positionMs: $positionMs, '
      'durationMs: $durationMs, watchedMs: $watchedMs, '
      'completed: $completed, updatedAt: ${updatedAt.toUtc().toIso8601String()})';
}

/// The nonsecret per-source connection allowance used before transport open.
///
/// Automatic mode is represented by a null [overrideLimit]. The effective
/// precedence is local override, provider report, then conservative one.
class SourceConnectionAllowance {
  const SourceConnectionAllowance({
    required this.reportedLimit,
    required this.overrideLimit,
  });

  final int? reportedLimit;
  final int? overrideLimit;

  int get effectiveLimit => overrideLimit ?? reportedLimit ?? 1;

  bool get usesConservativeDefault =>
      overrideLimit == null && reportedLimit == null;

  @override
  String toString() =>
      'SourceConnectionAllowance(reportedLimit: $reportedLimit, '
      'overrideLimit: $overrideLimit, effectiveLimit: $effectiveLimit)';
}

enum PersonalLibraryDirectoryKind { favorites, customGroup }

enum PersonalLibraryMoveDirection { up, down }

enum PersonalLibraryMutationOutcome {
  changed,
  unchanged,
  invalidName,
  duplicateName,
  limitReached,
  missingItem,
  missingGroup,
}

class PersonalLibraryCollectionRef {
  const PersonalLibraryCollectionRef.favorites()
    : kind = PersonalLibraryDirectoryKind.favorites,
      collectionId = null;

  const PersonalLibraryCollectionRef.customGroup(this.collectionId)
    : kind = PersonalLibraryDirectoryKind.customGroup;

  final PersonalLibraryDirectoryKind kind;
  final String? collectionId;

  String get key => kind == PersonalLibraryDirectoryKind.favorites
      ? 'favorites'
      : 'group:$collectionId';
}

/// A bounded, read-only entry in My Library's Favorites/group directory.
class PersonalLibraryDirectoryEntry {
  const PersonalLibraryDirectoryEntry({
    required this.kind,
    required this.collectionId,
    required this.name,
    required this.itemCount,
    this.directoryOrdinal,
    this.homeOrdinal,
  });

  final PersonalLibraryDirectoryKind kind;
  final String? collectionId;
  final String name;
  final int itemCount;
  final int? directoryOrdinal;
  final int? homeOrdinal;

  bool get isPinned => homeOrdinal != null;

  PersonalLibraryCollectionRef get reference =>
      kind == PersonalLibraryDirectoryKind.favorites
      ? const PersonalLibraryCollectionRef.favorites()
      : PersonalLibraryCollectionRef.customGroup(collectionId!);
}

class PersonalLibraryGroupChoice {
  const PersonalLibraryGroupChoice({
    required this.groupId,
    required this.name,
    required this.selected,
  });

  final String groupId;
  final String name;
  final bool selected;
}

class PersonalLibraryOrganization {
  const PersonalLibraryOrganization({
    required this.libraryItemId,
    required this.isFavorite,
    required this.groups,
  });

  final String libraryItemId;
  final bool isFavorite;
  final List<PersonalLibraryGroupChoice> groups;
}

class PersonalLibraryMutationResult {
  const PersonalLibraryMutationResult(this.outcome, {this.collection});

  final PersonalLibraryMutationOutcome outcome;
  final PersonalLibraryDirectoryEntry? collection;

  bool get succeeded =>
      outcome == PersonalLibraryMutationOutcome.changed ||
      outcome == PersonalLibraryMutationOutcome.unchanged;
}

/// A library identity plus its exact currently playable source variant.
///
/// Organization membership remains visible when every source variant is
/// unavailable. In that case the source/playback fields are null and
/// [isAvailable] is false.
class PersonalLibraryItem {
  const PersonalLibraryItem({
    required this.libraryItemId,
    required this.kind,
    required this.title,
    required this.artworkLocator,
    required this.catalogItemId,
    required this.sourceId,
    required this.sourceDisplayName,
    required this.playbackRef,
  });

  final String libraryItemId;
  final SourceMediaKind kind;
  final String title;
  final String? artworkLocator;
  final String? catalogItemId;
  final String? sourceId;
  final String? sourceDisplayName;
  final String? playbackRef;

  bool get isAvailable => catalogItemId != null;

  LibraryCatalogItem? get playableItem {
    if (!isAvailable) return null;
    return LibraryCatalogItem(
      libraryItemId: libraryItemId,
      catalogItemId: catalogItemId!,
      sourceId: sourceId!,
      sourceDisplayName: sourceDisplayName!,
      kind: kind,
      title: title,
      artworkLocator: artworkLocator,
      playbackRef: playbackRef!,
    );
  }
}

class FavoritePageCursor {
  const FavoritePageCursor({
    required this.createdAt,
    required this.libraryItemId,
  });

  final DateTime createdAt;
  final String libraryItemId;
}

class FavoriteLibraryPage {
  const FavoriteLibraryPage({required this.items, required this.nextCursor});

  final List<PersonalLibraryItem> items;
  final FavoritePageCursor? nextCursor;
}

class CustomGroupPageCursor {
  const CustomGroupPageCursor({
    required this.ordinal,
    required this.libraryItemId,
  });

  final int ordinal;
  final String libraryItemId;
}

class CustomGroupLibraryPage {
  const CustomGroupLibraryPage({required this.items, required this.nextCursor});

  final List<PersonalLibraryItem> items;
  final CustomGroupPageCursor? nextCursor;
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

/// A stable position in a title-ordered catalog or library page.
///
/// Library queries place the library identity in [id], not the chosen source
/// variant. Imported provider items deliberately remain separate identities,
/// including when their display titles match, so each cursor addresses exactly
/// one provider-owned item without introducing a merge contract.
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
    this.libraryItemId,
  });

  final String id;
  final String sourceId;
  final SourceMediaKind kind;
  final String title;
  final String? artworkLocator;
  final String playbackRef;
  final String? libraryItemId;
}

class BrowsePage {
  const BrowsePage({required this.items, required this.nextCursor});

  final List<BrowseCatalogItem> items;
  final BrowseCursor? nextCursor;
}

/// A provider category as seen by the local visibility maintenance surface.
///
/// [selection] is deliberately the same local category identity that browse
/// uses.  A null group id therefore represents the truthful Uncategorized
/// slice; it is not a fabricated provider category.
class SourceVisibilityCategory {
  const SourceVisibilityCategory({
    required this.selection,
    required this.name,
    required this.itemCount,
    required this.hiddenItemCount,
    required this.isHidden,
  });

  final BrowseCategorySelection selection;
  final String name;
  final int itemCount;
  final int hiddenItemCount;
  final bool isHidden;
}

/// One bounded page of provider visibility categories. The cursor is based on
/// the same stable sort key and local group id used by the directory query.
class SourceVisibilityCategoryPage {
  const SourceVisibilityCategoryPage({
    required this.categories,
    required this.nextCursor,
  });

  final List<SourceVisibilityCategory> categories;
  final BrowseCursor? nextCursor;
}

/// One imported item and its source-local visibility preference.
class SourceVisibilityItem {
  const SourceVisibilityItem({
    required this.catalogItemId,
    required this.kind,
    required this.title,
    required this.isHidden,
  });

  final String catalogItemId;
  final SourceMediaKind kind;
  final String title;
  final bool isHidden;
}

/// A bounded title-ordered slice of a visibility item ledger.
class SourceVisibilityPage {
  const SourceVisibilityPage({required this.items, required this.nextCursor});

  final List<SourceVisibilityItem> items;
  final BrowseCursor? nextCursor;
}

String playbackReference(Map<String, Object?> value) => jsonEncode(value);

enum M3uSourceKind { m3uUrl, m3uFile }

class M3uSourceInput {
  const M3uSourceInput({
    required this.id,
    required this.name,
    required this.kind,
    required this.locator,
    required this.credentialKey,
    required this.displayEndpoint,
  });

  final String id;
  final String name;
  final M3uSourceKind kind;

  /// Opaque URL or full file path. This never enters SQLite.
  final String locator;
  final String credentialKey;
  final String displayEndpoint;

  String get databaseKind => switch (kind) {
    M3uSourceKind.m3uUrl => 'm3u_url',
    M3uSourceKind.m3uFile => 'm3u_file',
  };
}

/// Private-to-source-management credential routing record; never render it.
class SourceOperationRecord {
  const SourceOperationRecord({
    required this.id,
    required this.kind,
    required this.credentialKey,
  });
  final String id;
  final String kind;
  final String credentialKey;
}
