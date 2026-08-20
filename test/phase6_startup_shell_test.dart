import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:wabbit_tv/src/app_shell.dart';
import 'package:wabbit_tv/src/features/browse/basic_browse_screen.dart';
import 'package:wabbit_tv/src/features/browse/catalog_scope_controller.dart';
import 'package:wabbit_tv/src/features/browse/playback_handoff.dart';
import 'package:wabbit_tv/src/features/home/home_screen.dart';
import 'package:wabbit_tv/src/features/guide/guide_data.dart';
import 'package:wabbit_tv/src/features/sources/epg_models.dart';
import 'package:wabbit_tv/src/features/playback/multiview_screen.dart';
import 'package:wabbit_tv/src/features/playback/playback_manager.dart';
import 'package:wabbit_tv/src/features/playback/playback_transport.dart';
import 'package:wabbit_tv/src/features/playback/player_screen.dart';
import 'package:wabbit_tv/src/features/settings/startup_preferences_controller.dart';
import 'package:wabbit_tv/src/features/sources/source_catalog_database.dart';
import 'package:wabbit_tv/src/features/sources/source_models.dart';
import 'package:wabbit_tv/src/features/sources/source_management_screen.dart';
import 'package:wabbit_tv/src/features/sources/source_setup_controller.dart';
import 'package:wabbit_tv/src/features/sources/startup_models.dart';
import 'package:wabbit_tv/src/home_fixture_mode.dart';

void main() {
  testWidgets('multiview reports only a newly audible usable Live session', (
    tester,
  ) async {
    final manager = PlaybackManager(
      targetResolver: _Resolver(),
      admissionPort: const _Admission(),
      transportFactory: _TransportFactory().create,
    );
    addTearDown(manager.dispose);
    final first = await manager.start(
      const LivePlaybackHandoff(
        sourceId: 'source',
        title: 'First',
        providerItemId: 'first',
        extension: 'ts',
        libraryItemId: 'library-first',
      ),
    );
    final second = await manager.start(
      const LivePlaybackHandoff(
        sourceId: 'source',
        title: 'Second',
        providerItemId: 'second',
        extension: 'ts',
        libraryItemId: 'library-second',
      ),
      requestAudioFocus: false,
    );
    final firstId = (first as PlaybackStarted).sessionId;
    final secondId = (second as PlaybackStarted).sessionId;
    final reported = <PlaybackSessionId>[];

    await tester.pumpWidget(
      MaterialApp(
        home: MultiviewScreen(
          manager: manager,
          originalSessionId: firstId,
          secondSessionId: secondId,
          onOpenFullPlayer: (_) {},
          onCloseSession: (_) {},
          onCollapse: () {},
          onAudibleUsableVideo: reported.add,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(reported, isEmpty);
    await tester.tap(find.byKey(const ValueKey('multiview-second-tile')));
    await tester.pumpAndSettle();

    expect(reported, [secondId]);
  });

  testWidgets(
    'explicit fixture destination bypasses durable startup behavior',
    (tester) async {
      final startup = _StartupPort(const StartupResolution.home());
      final controller = StartupPreferencesController(port: startup);
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: WabbitShell(
            fixtureMode: HomeFixtureMode.populated,
            initialDestination: ShellDestination.home,
            startupPreferencesController: controller,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('startup-preparing-surface')),
        findsNothing,
      );
      expect(startup.loadCalls, 0);
      expect(startup.resolveCalls, 0);
      expect(find.text('Home'), findsAtLeastNWidgets(1));
    },
  );

  testWidgets('startup preparation blocks background shell semantics', (
    tester,
  ) async {
    final harness = _ShellHarness(resolution: const StartupResolution.home());
    final gate = Completer<void>();
    final semantics = tester.ensureSemantics();
    harness.startup.loadGate = gate;
    addTearDown(harness.dispose);

    await tester.pumpWidget(harness.app());
    await tester.pump();

    expect(
      find.byKey(const ValueKey('startup-preparing-surface')),
      findsOneWidget,
    );
    expect(_semanticsTreeHasLabel(tester, 'Opening Wabbit TV'), isTrue);
    expect(_semanticsTreeHasLabel(tester, 'Home'), isFalse);

    gate.complete();
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('startup-preparing-surface')),
      findsNothing,
    );
    expect(_semanticsTreeHasLabel(tester, 'Home'), isTrue);
    semantics.dispose();
  });

  testWidgets(
    'unavailable Last channel shows one quiet Home notice without playback work',
    (tester) async {
      final harness = _ShellHarness(
        resolution: const StartupResolution.home(),
        preference: const StartupPreference(
          target: StartupTarget.lastChannel,
          previousDestination: StartupDestinationSlug.movies,
          lastLiveLibraryItemId: 'private-library-id',
        ),
      );
      addTearDown(harness.dispose);

      await tester.pumpWidget(harness.app());
      await _pumpUntil(
        tester,
        () => find
            .byKey(const ValueKey('startup-last-channel-unavailable'))
            .evaluate()
            .isNotEmpty,
      );

      expect(
        find.text('Last channel is unavailable. Wabbit opened Home instead.'),
        findsOneWidget,
      );
      expect(find.textContaining('private-library-id'), findsNothing);
      expect(find.byType(PlayerScreen), findsNothing);
      expect(harness.resolver.calls, 0);
      expect(harness.transportFactory.created, 0);
      final focusAfterNotice = FocusManager.instance.primaryFocus;
      await tester.pump(const Duration(milliseconds: 300));
      expect(FocusManager.instance.primaryFocus, same(focusAfterNotice));

      final liveDestination = tester.widget<FocusableActionDetector>(
        find.byKey(const ValueKey('shell-destination-live')),
      );
      liveDestination.focusNode!.requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('startup-last-channel-unavailable')),
        findsNothing,
      );
      expect(find.text('Live'), findsAtLeastNWidgets(1));
    },
  );

  testWidgets(
    'persisted Settings entry reaches startup choices and Sources by D-pad',
    (tester) async {
      final harness = _ShellHarness(
        resolution: const StartupResolution(
          destination: StartupDestinationSlug.settings,
          lastLiveItem: null,
        ),
        preference: const StartupPreference(
          target: StartupTarget.previousScreen,
          previousDestination: StartupDestinationSlug.settings,
          lastLiveLibraryItemId: null,
        ),
      );
      addTearDown(harness.dispose);

      await tester.pumpWidget(harness.app());
      await _pumpUntil(
        tester,
        () =>
            FocusManager.instance.primaryFocus?.debugLabel ==
                'home first item' &&
            find
                .byKey(const ValueKey('source-row-source'))
                .evaluate()
                .isNotEmpty,
      );

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pump();
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'startup previousScreen',
      );

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'startup lastChannel',
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pumpAndSettle();
      expect(harness.startup.savedTargets, [StartupTarget.lastChannel]);
      expect(harness.sourceManagement.selected?.id, 'source');

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      await tester.pump();
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'home first item');
    },
  );

  testWidgets('ordinary Home startup does not show Last-channel recovery', (
    tester,
  ) async {
    final harness = _ShellHarness(resolution: const StartupResolution.home());
    addTearDown(harness.dispose);

    await tester.pumpWidget(harness.app());
    await _pumpUntil(
      tester,
      () => find
          .byKey(const ValueKey('startup-preparing-surface'))
          .evaluate()
          .isEmpty,
    );

    expect(
      find.byKey(const ValueKey('startup-last-channel-unavailable')),
      findsNothing,
    );
    expect(harness.resolver.calls, 0);
    expect(harness.transportFactory.created, 0);
  });

  testWidgets('Previous screen restores the stable Guide destination', (
    tester,
  ) async {
    final harness = _ShellHarness(
      resolution: const StartupResolution(
        destination: StartupDestinationSlug.guide,
        lastLiveItem: null,
      ),
    );
    addTearDown(harness.dispose);

    await tester.pumpWidget(harness.app());
    await _pumpUntil(
      tester,
      () => find
          .byKey(const ValueKey('startup-preparing-surface'))
          .evaluate()
          .isEmpty,
    );
    await tester.pumpAndSettle();

    expect(harness.startup.resolveCalls, 1);
    expect(
      find.byKey(const ValueKey('startup-preparing-surface')),
      findsNothing,
    );
    expect(find.text('Guide needs an Xtream source'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('shell-destination-guide')),
      findsOneWidget,
    );
    expect(find.byType(PlayerScreen), findsNothing);
  });

  testWidgets('Previous screen restores one stable top-level destination', (
    tester,
  ) async {
    final harness = _ShellHarness(
      resolution: const StartupResolution(
        destination: StartupDestinationSlug.live,
        lastLiveItem: null,
      ),
    );
    addTearDown(harness.dispose);

    await tester.pumpWidget(harness.app());
    await _pumpUntil(
      tester,
      () => find
          .byKey(const ValueKey('startup-preparing-surface'))
          .evaluate()
          .isEmpty,
    );

    expect(find.text('Live'), findsAtLeastNWidgets(1));
    expect(find.byType(PlayerScreen), findsNothing);

    await tester.tap(find.byIcon(Icons.movie_outlined));
    await tester.pumpAndSettle();
    expect(
      harness.startup.savedDestinations,
      contains(StartupDestinationSlug.movies),
    );

    await tester.tap(find.byIcon(Icons.view_week_outlined));
    await tester.pumpAndSettle();
    expect(
      harness.startup.savedDestinations,
      contains(StartupDestinationSlug.guide),
    );
    expect(find.text('Guide needs an Xtream source'), findsOneWidget);
  });

  testWidgets('valid Last channel opens full player and Back returns Live', (
    tester,
  ) async {
    final harness = _ShellHarness(
      resolution: const StartupResolution(
        destination: StartupDestinationSlug.live,
        lastLiveItem: _lastLive,
      ),
    );
    addTearDown(harness.dispose);

    await tester.pumpWidget(harness.app());
    await _pumpUntil(
      tester,
      () => find.byType(PlayerScreen).evaluate().isNotEmpty,
    );
    await _pumpUntil(
      tester,
      () => harness.startup.savedLastItems.contains('library-last'),
    );

    expect(find.byType(PlayerScreen), findsOneWidget);
    expect(find.byKey(const ValueKey('live-multiview')), findsNothing);
    expect(find.text('Last News'), findsAtLeastNWidgets(1));

    final player = tester.widget<PlayerScreen>(find.byType(PlayerScreen));
    await tester.runAsync(() async => player.onExit());
    await _pumpUntil(
      tester,
      () => find.byType(PlayerScreen).evaluate().isEmpty,
    );

    expect(find.byType(PlayerScreen), findsNothing);
    expect(find.text('Live'), findsAtLeastNWidgets(1));
  });

  testWidgets('valid last-channel playback failure keeps player recovery', (
    tester,
  ) async {
    final harness = _ShellHarness(
      resolution: const StartupResolution(
        destination: StartupDestinationSlug.live,
        lastLiveItem: _lastLive,
      ),
      failPlayback: true,
    );
    addTearDown(harness.dispose);

    await tester.pumpWidget(harness.app());
    await _pumpUntil(
      tester,
      () => find.byType(PlayerScreen).evaluate().isNotEmpty,
    );
    await tester.runAsync(() async {
      for (var attempt = 0; attempt < 100; attempt++) {
        if (harness.playbackManager.sessions.isNotEmpty &&
            harness.playbackManager.sessions.single.phase ==
                PlaybackSessionPhase.failed) {
          return;
        }
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    });
    await tester.pump();

    expect(find.byType(PlayerScreen), findsOneWidget);
    expect(
      harness.playbackManager.sessions.single.phase,
      PlaybackSessionPhase.failed,
    );
    expect(find.byKey(const ValueKey('player-failure-deck')), findsOneWidget);
    expect(find.text('Playback is unavailable right now.'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
    expect(harness.startup.savedLastItems, isEmpty);
  });
}

bool _semanticsTreeHasLabel(WidgetTester tester, String label) {
  final root = tester
      .binding
      .renderViews
      .single
      .owner!
      .semanticsOwner!
      .rootSemanticsNode!;
  var found = root.label.contains(label);

  void search(SemanticsNode node) {
    node.visitChildren((child) {
      if (child.label.contains(label)) found = true;
      if (!found) search(child);
      return !found;
    });
  }

  if (!found) search(root);
  return found;
}

Future<void> _pumpUntil(WidgetTester tester, bool Function() condition) async {
  for (var attempt = 0; attempt < 100; attempt++) {
    await tester.pump(const Duration(milliseconds: 20));
    if (condition()) return;
  }
  fail('Condition was not reached within the bounded pump window.');
}

const _source = PersistedSource(
  id: 'source',
  name: 'Strong',
  credentialKey: 'source-key',
  counts: {SourceMediaKind.live: 1},
);

const _lastLive = LibraryCatalogItem(
  libraryItemId: 'library-last',
  catalogItemId: 'catalog-last',
  sourceId: 'source',
  sourceDisplayName: 'Strong',
  kind: SourceMediaKind.live,
  title: 'Last News',
  artworkLocator: null,
  playbackRef: '{"providerId":"last","kind":"live","extension":"ts"}',
);

class _ShellHarness {
  _ShellHarness({
    required StartupResolution resolution,
    StartupPreference preference = const StartupPreference.defaults(),
    bool failPlayback = false,
  }) : startup = _StartupPort(resolution, preference: preference),
       scope = CatalogScopeController(port: const _ScopePort()),
       sources = SourceSetupController(service: const _NoopSetupPort()),
       sourceManagement = SourceManagementController(
         port: const _ManagementPort(),
       ),
       home = HomeController(data: const _HomeData()),
       transportFactory = _TransportFactory() {
    startupController = StartupPreferencesController(port: startup);
    resolver = _Resolver();
    playbackManager = PlaybackManager(
      targetResolver: failPlayback ? const _FailResolver() : resolver,
      admissionPort: const _Admission(),
      transportFactory: transportFactory.create,
    );
  }

  final _StartupPort startup;
  final CatalogScopeController scope;
  final SourceSetupController sources;
  final SourceManagementController sourceManagement;
  final HomeController home;
  final _TransportFactory transportFactory;
  late final _Resolver resolver;
  late final StartupPreferencesController startupController;
  late final PlaybackManager playbackManager;

  Widget app() => MaterialApp(
    theme: ThemeData.dark(),
    home: WabbitShell(
      fixtureMode: HomeFixtureMode.runtime,
      catalogScopeController: scope,
      sourceController: sources,
      sourceManagementController: sourceManagement,
      homeController: home,
      scopedBrowseData: const _BrowseData(),
      startupPreferencesController: startupController,
      playbackManager: playbackManager,
      guideData: const _NoGuideData(),
    ),
  );

  void dispose() {
    startupController.dispose();
    playbackManager.dispose();
    scope.dispose();
    sources.dispose();
    sourceManagement.dispose();
    home.dispose();
  }
}

class _NoGuideData implements GuideDataPort {
  const _NoGuideData();

  @override
  Future<void> cancelActiveEpgRefresh() async {}

  @override
  Future<List<SourceRosterEntry>> loadXtreamSources() async => const [];

  @override
  Future<List<BrowseCategorySummary>> loadCategories(String sourceId) async =>
      const [];

  @override
  Future<BrowsePage> loadChannels({
    required String sourceId,
    required BrowseCategorySelection selection,
    BrowseCursor? cursor,
    int limit = guideChannelPageSize,
  }) async => const BrowsePage(items: [], nextCursor: null);

  @override
  Future<List<EpgChannelWindow>> loadEpgWindow({
    required List<String> catalogItemIds,
    required DateTime windowStartUtc,
    required DateTime windowEndUtc,
    required DateTime atUtc,
  }) async => const [];

  @override
  Future<EpgRefreshSummary> refreshCatalogItems(
    Iterable<String> catalogItemIds, {
    bool manualRetry = false,
  }) async => const EpgRefreshSummary.none();
}

class _StartupPort implements StartupPreferencesPort {
  _StartupPort(
    this.resolution, {
    this.preference = const StartupPreference.defaults(),
  });

  final StartupResolution resolution;
  final StartupPreference preference;
  Completer<void>? loadGate;
  int loadCalls = 0;
  int resolveCalls = 0;
  final savedDestinations = <StartupDestinationSlug>[];
  final savedLastItems = <String>[];
  final savedTargets = <StartupTarget>[];

  @override
  Future<StartupPreference> loadStartupPreference() async {
    loadCalls += 1;
    await loadGate?.future;
    return preference;
  }

  @override
  Future<StartupResolution> resolveStartupDestination() async {
    resolveCalls += 1;
    return resolution;
  }

  @override
  Future<bool> saveLastLiveLibraryItem(String libraryItemId) async {
    savedLastItems.add(libraryItemId);
    return true;
  }

  @override
  Future<StartupPreference> savePreviousDestination(
    StartupDestinationSlug destination,
  ) async {
    savedDestinations.add(destination);
    return StartupPreference(
      target: StartupTarget.home,
      previousDestination: destination,
      lastLiveLibraryItemId: null,
    );
  }

  @override
  Future<StartupPreference> saveStartupTarget(StartupTarget target) async {
    savedTargets.add(target);
    return StartupPreference(
      target: target,
      previousDestination: null,
      lastLiveLibraryItemId: null,
    );
  }
}

class _ScopePort implements CatalogScopePort {
  const _ScopePort();

  @override
  Future<LibraryScope> loadCatalogScope() async => const LibraryScope.all();

  @override
  Future<PersistedSource?> loadReadySourceById(String sourceId) async =>
      sourceId == 'source' ? _source : null;

  @override
  Future<List<SourceRosterEntry>> loadSourceRoster() async => const [
    SourceRosterEntry(
      id: 'source',
      name: 'Strong',
      kind: 'xtream',
      enabled: true,
      status: 'ready',
      counts: {SourceMediaKind.live: 1},
    ),
  ];

  @override
  Future<LibraryScope> saveCatalogScope(LibraryScope scope) async => scope;
}

class _BrowseData implements ScopedBrowseData {
  const _BrowseData();

  @override
  Future<LibraryPage> browseLibraryPage({
    required LibraryScope scope,
    required SourceMediaKind kind,
    BrowseCursor? cursor,
    int limit = 100,
  }) async => const LibraryPage(items: [], nextCursor: null);

  @override
  Future<int> countLibraryItems({
    required LibraryScope scope,
    required SourceMediaKind kind,
  }) async => 0;
}

class _HomeData implements HomeData {
  const _HomeData();

  @override
  Future<bool> hasSources() async => true;

  @override
  Future<List<HomePersonalShelf>> loadPinnedShelves({
    required int shelfLimit,
    required int itemLimit,
  }) async => const [];

  @override
  Future<List<RecentlyWatchedItem>> loadRecentlyWatched({
    required int limit,
  }) async => const [];

  @override
  Future<PersistedSource?> loadReadySourceById(String sourceId) async =>
      sourceId == 'source' ? _source : null;
}

class _Resolver implements PlaybackTargetResolverPort {
  int calls = 0;

  @override
  Future<PlaybackResolvedTarget> resolve(PlaybackHandoff handoff) async {
    calls += 1;
    return PlaybackResolvedTarget(
      uri: Uri.parse('https://stream.example/live'),
    );
  }
}

class _FailResolver implements PlaybackTargetResolverPort {
  const _FailResolver();

  @override
  Future<PlaybackResolvedTarget> resolve(PlaybackHandoff handoff) async =>
      throw const PlaybackResolutionException(
        PlaybackSessionFailure.unavailable,
      );
}

class _Admission implements PlaybackAdmissionPort {
  const _Admission();

  @override
  Future<int> effectiveLimitForSource(String sourceId) async => 2;
}

class _TransportFactory {
  int created = 0;

  PlaybackTransport create() {
    created += 1;
    return _Transport();
  }
}

class _Transport implements PlaybackTransport {
  final _states = StreamController<PlaybackTransportState>.broadcast(
    sync: true,
  );

  @override
  Stream<PlaybackTransportState> get states => _states.stream;

  @override
  Widget buildVideo() => const SizedBox(key: ValueKey('startup-video'));

  @override
  Future<void> open(
    Uri uri, {
    Map<String, String> httpHeaders = const {},
  }) async {
    _states.add(
      const PlaybackTransportState(
        hasVideo: true,
        isPlaying: true,
        duration: Duration(hours: 1),
      ),
    );
  }

  @override
  Future<void> dispose() async => _states.close();
  @override
  Future<void> pause() async {}
  @override
  Future<void> play() async {}
  @override
  Future<void> seek(Duration position) async {}
  @override
  Future<void> setMuted(bool muted) async {}
  @override
  Future<void> setVolume(double volume) async {}
}

class _NoopSetupPort implements SourceSetupPort {
  const _NoopSetupPort();

  @override
  Future<SourceReady> commit(
    SourceDefinition source,
    List<ImportedStage> stages,
  ) => throw UnimplementedError();

  @override
  Future<ImportedStage> fetch(SourceDefinition source, SourceMediaKind kind) =>
      throw UnimplementedError();

  @override
  Future<void> remove(String sourceId) async {}
}

class _ManagementPort implements SourceManagementPort {
  const _ManagementPort();

  @override
  Future<void> editAndRefresh(String sourceId) async {}

  @override
  Future<List<SourceRosterEntry>> loadRoster() async => const [
    SourceRosterEntry(
      id: 'source',
      name: 'Strong',
      kind: 'xtream',
      enabled: true,
      status: 'ready',
      counts: {SourceMediaKind.live: 1},
    ),
  ];

  @override
  Future<void> refresh(String sourceId) async {}

  @override
  Future<void> remove(String sourceId) async {}

  @override
  Future<void> rename(String sourceId, String name) async {}

  @override
  Future<void> setEnabled(String sourceId, bool enabled) async {}
}
