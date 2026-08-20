import '../sources/epg_models.dart';
import '../sources/source_catalog_database.dart';
import '../sources/source_models.dart';
import '../sources/xtream_epg_service.dart';

const guideChannelPageSize = 40;
const guidePresentationEpgLimit = guideChannelPageSize;
const basicBrowseMountedEpgLimit = 20;

/// The shared, presentation-facing seam for bounded cached schedule reads.
///
/// Both Guide and Live browse use this port. Implementations may enqueue a
/// provider refresh, but widgets always render the local cache first and never
/// receive credentials, provider URLs, or raw payloads.
abstract interface class EpgWindowPort {
  Future<List<EpgChannelWindow>> loadEpgWindow({
    required List<String> catalogItemIds,
    required DateTime windowStartUtc,
    required DateTime windowEndUtc,
    required DateTime atUtc,
  });

  Future<EpgRefreshSummary> refreshCatalogItems(
    Iterable<String> catalogItemIds, {
    bool manualRetry = false,
  });
}

/// The additional bounded local queries required by the dedicated Guide.
abstract interface class GuideDataPort implements EpgWindowPort {
  Future<void> cancelActiveEpgRefresh();

  Future<List<SourceRosterEntry>> loadXtreamSources();

  Future<List<BrowseCategorySummary>> loadCategories(String sourceId);

  Future<BrowsePage> loadChannels({
    required String sourceId,
    required BrowseCategorySelection selection,
    BrowseCursor? cursor,
    int limit,
  });
}

/// Optional exact-identity restoration seam. Production reconstructs a
/// bounded, current window around the saved identity and exposes a truthful
/// backward cursor; simple Guide fixtures may omit it.
abstract interface class GuideRestorationDataPort {
  Future<CatalogBrowseWindow?> loadChannelWindow({
    required String sourceId,
    required BrowseCategorySelection selection,
    required String catalogItemId,
    int limit,
  });

  Future<CatalogBrowseWindow> loadPreviousChannels({
    required String sourceId,
    required BrowseCategorySelection selection,
    required BrowseCursor cursor,
    int limit,
  });
}

class DatabaseGuideDataPort implements GuideDataPort, GuideRestorationDataPort {
  const DatabaseGuideDataPort({
    required this.database,
    required this.epgService,
  });

  final SourceCatalogDatabase database;
  final XtreamEpgService epgService;

  @override
  Future<void> cancelActiveEpgRefresh() => epgService.cancelActiveRefresh();

  @override
  Future<List<SourceRosterEntry>> loadXtreamSources() async {
    final sources = await database.loadSourceRoster();
    return List.unmodifiable(
      sources.where(
        (source) =>
            source.kind == 'xtream' &&
            source.enabled &&
            (source.status == 'ready' || source.status == 'refreshing'),
      ),
    );
  }

  @override
  Future<List<BrowseCategorySummary>> loadCategories(String sourceId) =>
      database.browseCategories(sourceId: sourceId, kind: SourceMediaKind.live);

  @override
  Future<BrowsePage> loadChannels({
    required String sourceId,
    required BrowseCategorySelection selection,
    BrowseCursor? cursor,
    int limit = guideChannelPageSize,
  }) => database.browsePage(
    sourceId: sourceId,
    kind: SourceMediaKind.live,
    selection: selection,
    cursor: cursor,
    limit: limit.clamp(1, guideChannelPageSize),
  );

  @override
  Future<CatalogBrowseWindow?> loadChannelWindow({
    required String sourceId,
    required BrowseCategorySelection selection,
    required String catalogItemId,
    int limit = guideChannelPageSize,
  }) => database.browseWindowAroundCatalogItem(
    sourceId: sourceId,
    kind: SourceMediaKind.live,
    selection: selection,
    catalogItemId: catalogItemId,
    limit: limit.clamp(3, guideChannelPageSize),
  );

  @override
  Future<CatalogBrowseWindow> loadPreviousChannels({
    required String sourceId,
    required BrowseCategorySelection selection,
    required BrowseCursor cursor,
    int limit = guideChannelPageSize,
  }) => database.browsePageBefore(
    sourceId: sourceId,
    kind: SourceMediaKind.live,
    selection: selection,
    cursor: cursor,
    limit: limit.clamp(1, guideChannelPageSize),
  );

  @override
  Future<List<EpgChannelWindow>> loadEpgWindow({
    required List<String> catalogItemIds,
    required DateTime windowStartUtc,
    required DateTime windowEndUtc,
    required DateTime atUtc,
  }) => database.loadEpgWindow(
    catalogItemIds: catalogItemIds.take(guidePresentationEpgLimit).toList(),
    windowStartUtc: windowStartUtc,
    windowEndUtc: windowEndUtc,
    atUtc: atUtc,
  );

  @override
  Future<EpgRefreshSummary> refreshCatalogItems(
    Iterable<String> catalogItemIds, {
    bool manualRetry = false,
  }) => epgService.refreshCatalogItems(
    catalogItemIds.take(guidePresentationEpgLimit),
    manualRetry: manualRetry,
  );
}
