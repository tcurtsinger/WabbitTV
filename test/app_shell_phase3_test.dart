import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:wabbit_tv/src/app_shell.dart';
import 'package:wabbit_tv/src/features/browse/catalog_scope_controller.dart';
import 'package:wabbit_tv/src/features/browse/playback_handoff.dart';
import 'package:wabbit_tv/src/features/home/home_screen.dart';
import 'package:wabbit_tv/src/features/library/library_organization_service.dart';
import 'package:wabbit_tv/src/features/library/my_library_screen.dart';
import 'package:wabbit_tv/src/features/playback/playback_transport.dart';
import 'package:wabbit_tv/src/features/playback/player_screen.dart';
import 'package:wabbit_tv/src/features/sources/credential_store.dart';
import 'package:wabbit_tv/src/features/sources/source_catalog_database.dart';
import 'package:wabbit_tv/src/features/sources/source_models.dart';
import 'package:wabbit_tv/src/features/sources/source_setup_controller.dart';
import 'package:wabbit_tv/src/home_fixture_mode.dart';

void main() {
  testWidgets(
    'My Library destination is a real ledger and activates exact Live',
    (tester) async {
      final handoffs = <PlaybackHandoff>[];
      await tester.pumpWidget(
        MaterialApp(
          home: WabbitShell(
            fixtureMode: HomeFixtureMode.populated,
            initialDestination: ShellDestination.library,
            myLibraryData: const _ShellLibraryData(),
            onPlaybackHandoff: handoffs.add,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('My Library'), findsAtLeastNWidgets(1));
      expect(find.text('Favorites'), findsAtLeastNWidgets(1));
      expect(find.text('Local News'), findsOneWidget);
      expect(find.textContaining('scheduled for a later phase'), findsNothing);

      await tester.tap(
        find.byKey(const ValueKey('my-library-item-library-live')),
      );
      await tester.pumpAndSettle();

      expect(handoffs, hasLength(1));
      expect(handoffs.single, isA<LivePlaybackHandoff>());
      expect(handoffs.single.sourceId, 'strong');
      expect(handoffs.single.libraryItemId, 'library-live');
    },
  );

  testWidgets('My Library opens the shared organizer and restores exact row', (
    tester,
  ) async {
    final home = HomeController(data: _ShellHomeData(() async => const []));
    final organization = _ShellOrganizationPort();
    addTearDown(home.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: WabbitShell(
          fixtureMode: HomeFixtureMode.populated,
          initialDestination: ShellDestination.library,
          myLibraryData: const _ShellLibraryData(),
          homeController: home,
          libraryOrganizationPort: organization,
          onPlaybackHandoff: (_) {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      contains('library-live'),
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.contextMenu);
    await tester.pumpAndSettle();
    expect(find.text('Organize item'), findsOneWidget);
    expect(find.text('Local News'), findsAtLeastNWidgets(1));

    for (var index = 0; index < 12; index++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        isNot(contains('navigation')),
      );
    }
    // The expanded rail paints past its collapsed 72 px hit region. Exercise
    // the actual visible Home icon rather than the semantics bounding box.
    await tester.tapAt(const Offset(36, 110));
    await tester.pump();
    expect(find.text('Organize item'), findsOneWidget);
    expect(find.text('My Library'), findsAtLeastNWidgets(1));
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      isNot(contains('navigation')),
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(find.text('Organize item'), findsNothing);
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      contains('library-live'),
    );
  });

  testWidgets('organizer Save refreshes My Library and restores its item row', (
    tester,
  ) async {
    final home = HomeController(data: _ShellHomeData(() async => const []));
    final organization = _ShellOrganizationPort();
    addTearDown(home.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: WabbitShell(
          fixtureMode: HomeFixtureMode.populated,
          initialDestination: ShellDestination.library,
          myLibraryData: const _ShellLibraryData(),
          homeController: home,
          libraryOrganizationPort: organization,
          onPlaybackHandoff: (_) {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.contextMenu);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('organizer-favorite')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('organizer-save')));
    await tester.pumpAndSettle();

    expect(find.text('Organize item'), findsNothing);
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      contains('library-live'),
    );
  });

  testWidgets('Create group runs inside the shell and refreshes My Library', (
    tester,
  ) async {
    final home = HomeController(data: _ShellHomeData(() async => const []));
    final organization = _ShellOrganizationPort();
    addTearDown(home.dispose);
    await tester.binding.setSurfaceSize(const Size(1265, 713));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: WabbitShell(
          fixtureMode: HomeFixtureMode.populated,
          initialDestination: ShellDestination.library,
          myLibraryData: const _ShellLibraryData(),
          homeController: home,
          libraryOrganizationPort: organization,
          onPlaybackHandoff: (_) {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('my-library-create-group')));
    await tester.pumpAndSettle();
    expect(find.text('Name your group'), findsOneWidget);
    for (var index = 0; index < 12; index++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        isNot(contains('navigation')),
      );
    }
    expect(find.text('Name your group'), findsOneWidget);
    await tester.tapAt(const Offset(36, 110));
    await tester.pump();
    expect(find.text('Name your group'), findsOneWidget);
    expect(find.text('My Library'), findsAtLeastNWidgets(1));
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      isNot(contains('navigation')),
    );
    await tester.enterText(
      find.byKey(const ValueKey('group-name-field')),
      'Weekend',
    );
    await tester.pump();
    await tester.tap(find.text('Create'));
    await tester.pumpAndSettle();

    expect(organization.createdName, 'Weekend');
    expect(find.text('Name your group'), findsNothing);
    expect(find.text('My Library'), findsAtLeastNWidgets(1));
  });

  testWidgets(
    'Player exit falls back when a Home refresh removes its origin node',
    (tester) async {
      var history = [_recentLive(0), _recentLive(1)];
      final home = HomeController(data: _ShellHomeData(() async => history));
      final scope = CatalogScopeController(port: const _ShellScopePort());
      final sources = SourceSetupController(service: const _NoopSetupPort());
      final transport = _ShellTransport();
      addTearDown(home.dispose);
      addTearDown(scope.dispose);
      addTearDown(sources.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: WabbitShell(
            fixtureMode: HomeFixtureMode.runtime,
            initialDestination: ShellDestination.home,
            sourceController: sources,
            catalogScopeController: scope,
            homeController: home,
            playbackSourceResolver: (_) async => _playbackSource,
            credentialStore: const _ShellCredentials(),
            playbackTransportFactory: () => transport,
            fullscreenPort: const _ShellFullscreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'home recent item 1',
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pumpAndSettle();
      expect(find.byType(PlayerScreen), findsOneWidget);
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump();

      history = [_recentLive(0)];
      await home.refresh();
      await tester.pump();

      final player = tester.widget<PlayerScreen>(find.byType(PlayerScreen));
      await tester.runAsync(() async => player.onExit());
      await tester.pumpAndSettle();

      expect(find.byType(PlayerScreen), findsNothing);
      expect(FocusManager.instance.primaryFocus?.hasFocus, isTrue);
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'home first item');
    },
  );
}

class _ShellLibraryData implements MyLibraryData {
  const _ShellLibraryData();

  @override
  Future<List<MyLibrarySection>> loadSections({int limit = 100}) async =>
      const [
        MyLibrarySection(
          id: 'favorites',
          name: 'Favorites',
          kind: MyLibrarySectionKind.favorites,
          itemCount: 1,
        ),
      ];

  @override
  Future<MyLibraryPage> loadItems({
    required String sectionId,
    MyLibraryPageCursor? cursor,
    int limit = 100,
  }) async => const MyLibraryPage(
    items: [
      MyLibraryItem(
        id: 'library-live',
        title: 'Local News',
        kind: MyLibraryMediaKind.live,
        sourceName: 'Strong',
      ),
    ],
    nextCursor: null,
    totalCount: 1,
  );

  @override
  Future<LibraryCatalogItem?> resolvePlayableItem(String libraryItemId) async {
    if (libraryItemId != 'library-live') return null;
    return const LibraryCatalogItem(
      libraryItemId: 'library-live',
      catalogItemId: 'catalog-live',
      sourceId: 'strong',
      sourceDisplayName: 'Strong',
      kind: SourceMediaKind.live,
      title: 'Local News',
      artworkLocator: null,
      playbackRef: '{"providerId":"101","kind":"live","extension":"ts"}',
    );
  }

  @override
  Future<PersistedSource?> loadReadySourceById(String sourceId) async => null;
}

class _ShellOrganizationPort implements LibraryOrganizationPort {
  String? createdName;

  @override
  Future<PersonalLibraryOrganization?> loadItem(String libraryItemId) async =>
      PersonalLibraryOrganization(
        libraryItemId: libraryItemId,
        isFavorite: false,
        groups: const [],
      );

  @override
  Future<PersonalLibraryMutationResult> createGroup(String name) async {
    createdName = name;
    return PersonalLibraryMutationResult(
      PersonalLibraryMutationOutcome.changed,
      collection: PersonalLibraryDirectoryEntry(
        kind: PersonalLibraryDirectoryKind.customGroup,
        collectionId: 'weekend',
        name: name,
        itemCount: 0,
        directoryOrdinal: 0,
      ),
    );
  }

  @override
  Future<List<PersonalLibraryDirectoryEntry>> loadDirectory({
    int limit = 200,
  }) async => const [];
  @override
  Future<CustomGroupLibraryPage> loadGroupItems({
    required String groupId,
    CustomGroupPageCursor? cursor,
    int limit = 100,
  }) async => const CustomGroupLibraryPage(items: [], nextCursor: null);
  @override
  Future<List<PersonalLibraryDirectoryEntry>> loadPinned({
    int limit = 24,
  }) async => const [];
  @override
  Future<PersonalLibraryMutationResult> deleteGroup(String groupId) async =>
      const PersonalLibraryMutationResult(
        PersonalLibraryMutationOutcome.changed,
      );
  @override
  Future<PersonalLibraryMutationResult> moveGroup({
    required String groupId,
    required PersonalLibraryMoveDirection direction,
  }) async => const PersonalLibraryMutationResult(
    PersonalLibraryMutationOutcome.changed,
  );
  @override
  Future<PersonalLibraryMutationResult> moveGroupItem({
    required String groupId,
    required String libraryItemId,
    required PersonalLibraryMoveDirection direction,
  }) async => const PersonalLibraryMutationResult(
    PersonalLibraryMutationOutcome.changed,
  );
  @override
  Future<PersonalLibraryMutationResult> movePinned({
    required PersonalLibraryCollectionRef collection,
    required PersonalLibraryMoveDirection direction,
  }) async => const PersonalLibraryMutationResult(
    PersonalLibraryMutationOutcome.changed,
  );
  @override
  Future<PersonalLibraryMutationResult> removeGroupItem({
    required String groupId,
    required String libraryItemId,
  }) async => const PersonalLibraryMutationResult(
    PersonalLibraryMutationOutcome.changed,
  );
  @override
  Future<PersonalLibraryMutationResult> renameGroup({
    required String groupId,
    required String name,
  }) async => const PersonalLibraryMutationResult(
    PersonalLibraryMutationOutcome.changed,
  );
  @override
  Future<PersonalLibraryMutationResult> saveItem({
    required String libraryItemId,
    required bool favorite,
    required Set<String> customGroupIds,
  }) async => const PersonalLibraryMutationResult(
    PersonalLibraryMutationOutcome.changed,
  );
  @override
  Future<PersonalLibraryMutationResult> setPinned({
    required PersonalLibraryCollectionRef collection,
    required bool pinned,
  }) async => const PersonalLibraryMutationResult(
    PersonalLibraryMutationOutcome.changed,
  );
}

const _playbackSource = PersistedSource(
  id: 'source',
  name: 'Strong',
  credentialKey: 'source-key',
  counts: {SourceMediaKind.live: 2},
);

RecentlyWatchedItem _recentLive(int index) => RecentlyWatchedItem(
  item: LibraryCatalogItem(
    libraryItemId: 'library-$index',
    catalogItemId: 'catalog-$index',
    sourceId: 'source',
    sourceDisplayName: 'Strong',
    kind: SourceMediaKind.live,
    title: 'Channel $index',
    artworkLocator: null,
    playbackRef: '{"providerId":"$index","kind":"live","extension":"ts"}',
  ),
  lastPlayedAt: DateTime.utc(
    2026,
    8,
    18,
    12,
  ).subtract(Duration(minutes: index)),
);

class _ShellHomeData implements HomeData {
  const _ShellHomeData(this.history);

  final Future<List<RecentlyWatchedItem>> Function() history;

  @override
  Future<bool> hasSources() async => true;

  @override
  Future<List<RecentlyWatchedItem>> loadRecentlyWatched({required int limit}) =>
      history();

  @override
  Future<List<HomePersonalShelf>> loadPinnedShelves({
    required int shelfLimit,
    required int itemLimit,
  }) async => const [];

  @override
  Future<PersistedSource?> loadReadySourceById(String sourceId) async =>
      sourceId == 'source' ? _playbackSource : null;
}

class _ShellScopePort implements CatalogScopePort {
  const _ShellScopePort();

  @override
  Future<LibraryScope> loadCatalogScope() async => const LibraryScope.all();

  @override
  Future<PersistedSource?> loadReadySourceById(String sourceId) async =>
      sourceId == 'source' ? _playbackSource : null;

  @override
  Future<List<SourceRosterEntry>> loadSourceRoster() async => const [
    SourceRosterEntry(
      id: 'source',
      name: 'Strong',
      kind: 'xtream',
      enabled: true,
      status: 'ready',
      counts: {SourceMediaKind.live: 2},
    ),
  ];

  @override
  Future<LibraryScope> saveCatalogScope(LibraryScope scope) async => scope;
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

class _ShellCredentials implements CredentialStore {
  const _ShellCredentials();

  @override
  Future<void> delete(String key) async {}

  @override
  Future<StoredCredential?> read(String key) async => key == 'source-key'
      ? const StoredCredential(
          username: 'user',
          password: 'secret',
          serverUrl: 'https://strong.example',
        )
      : null;

  @override
  Future<void> write({
    required String key,
    required String username,
    required String password,
    String? serverUrl,
  }) async {}
}

class _ShellTransport implements PlaybackTransport {
  final StreamController<PlaybackTransportState> _states =
      StreamController<PlaybackTransportState>.broadcast(sync: true);

  @override
  Stream<PlaybackTransportState> get states => _states.stream;

  @override
  Widget buildVideo() => const SizedBox.expand();

  @override
  Future<void> dispose() async {
    // The manager cancels its subscription before disposal. The controller is
    // test-only and deliberately left open so disposal itself cannot wait on
    // a synthetic stream lifecycle.
  }

  @override
  Future<void> open(
    Uri uri, {
    Map<String, String> httpHeaders = const {},
  }) async {
    _states.add(const PlaybackTransportState(hasVideo: true, isPlaying: true));
  }

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

class _ShellFullscreen implements FullscreenPort {
  const _ShellFullscreen();

  @override
  Future<bool> get isFullscreen async => false;

  @override
  Future<void> setFullscreen(bool value) async {}
}
